-- ============================================================================
-- FinTab Enterprise OS — Forward Migration 008
-- Module: Authoritative Inter-Branch Inventory Transfers (Phase 6B-1)
--
-- Objective:
--   Implements physical stock transfers between branches within the same business
--   under a strict Dispatch / Receive (Model B) lifecycle:
--     DRAFT -> IN_TRANSIT -> RECEIVED
--     (or DRAFT -> CANCELLED)
--
-- Architectural Guarantees:
--   1. Location / Branch Structural Integrity via Composite Foreign Keys:
--      (business_id, from_branch_id, from_location_id) -> inventory_locations
--      (business_id, to_branch_id, to_location_id) -> inventory_locations
--   2. Direct Client Mutation Lockdown:
--      All direct INSERT, UPDATE, DELETE on inventory_transfers and
--      inventory_transfer_items are revoked. Mutations execute solely through
--      hardened SECURITY DEFINER RPCs.
--   3. Server-Authoritative Sequence Numbering:
--      Generated via rpc_next_document_number(p_business_id, 'inventory_transfer', 'TRF').
--   4. Typed Operation Idempotency:
--      Dedicated dispatch_idempotency_key and receive_idempotency_key columns
--      with tenant-scoped partial uniqueness prevent duplicate movements.
--   5. Append-Only Inventory Ledger & WAC Preservation:
--      Dispatch creates TRANSFER_OUT (negative quantity) at source average unit cost.
--      Receive creates TRANSFER_IN (positive quantity) blending destination WAC.
--   6. Full Receipt Only (Phase 6B-1):
--      Partial receipts are prohibited; received quantity equals shipped quantity.
--   7. Pure Domain Scope:
--      Zero Realtime publication, zero notify triggers, zero offline queues.
-- ============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Structural Prerequisite: Composite Unique Key on inventory_locations
-- -----------------------------------------------------------------------------
-- Allows declarative composite foreign keys guaranteeing that locations belong
-- strictly to their declared branches without procedural triggers.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'uq_inventory_locations_biz_branch_id'
  ) THEN
    ALTER TABLE public.inventory_locations
      ADD CONSTRAINT uq_inventory_locations_biz_branch_id UNIQUE (business_id, branch_id, id);
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. Table: public.inventory_transfers (Transfer Header)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_transfers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  transfer_number TEXT NOT NULL,
  from_branch_id UUID NOT NULL,
  to_branch_id UUID NOT NULL,
  from_location_id UUID NOT NULL,
  to_location_id UUID NOT NULL,
  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'in_transit', 'received', 'cancelled')),
  notes TEXT,
  created_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  shipped_by UUID REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  shipped_at TIMESTAMPTZ,
  received_by UUID REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  received_at TIMESTAMPTZ,
  dispatch_idempotency_key UUID,
  receive_idempotency_key UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Tenant composite key for child references
  CONSTRAINT uq_inventory_transfers_biz_id UNIQUE (business_id, id),
  -- Tenant-unique transfer document number
  CONSTRAINT uq_transfers_number UNIQUE (business_id, transfer_number),

  -- Branch segregation: source and destination branches must differ
  CONSTRAINT chk_transfers_different_branches CHECK (from_branch_id <> to_branch_id),
  -- Location segregation: source and destination locations must differ
  CONSTRAINT chk_transfers_different_locations CHECK (from_location_id <> to_location_id),

  -- Declarative tenant-safe foreign keys for branches
  CONSTRAINT fk_transfers_from_branch
    FOREIGN KEY (business_id, from_branch_id)
    REFERENCES public.branches(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_transfers_to_branch
    FOREIGN KEY (business_id, to_branch_id)
    REFERENCES public.branches(business_id, id)
    ON DELETE RESTRICT,

  -- Declarative tenant-safe foreign keys guaranteeing location belongs to matching branch
  CONSTRAINT fk_transfers_from_location
    FOREIGN KEY (business_id, from_branch_id, from_location_id)
    REFERENCES public.inventory_locations(business_id, branch_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_transfers_to_location
    FOREIGN KEY (business_id, to_branch_id, to_location_id)
    REFERENCES public.inventory_locations(business_id, branch_id, id)
    ON DELETE RESTRICT,

  -- Typed operation idempotency keys (unique within business tenant when present)
  CONSTRAINT uq_transfers_dispatch_idempotency UNIQUE (business_id, dispatch_idempotency_key),
  CONSTRAINT uq_transfers_receive_idempotency UNIQUE (business_id, receive_idempotency_key)
);

-- -----------------------------------------------------------------------------
-- 3. Table: public.inventory_transfer_items (Transfer Line Items)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_transfer_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  transfer_id UUID NOT NULL,
  product_id UUID NOT NULL,
  quantity_requested NUMERIC(15, 4) NOT NULL,
  quantity_shipped NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
  quantity_received NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
  unit_cost_at_dispatch NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Prevent duplicate product entries on same transfer
  CONSTRAINT uq_transfer_items_transfer_product UNIQUE (transfer_id, product_id),

  -- Declarative tenant-safe composite foreign key to parent transfer
  CONSTRAINT fk_transfer_items_parent
    FOREIGN KEY (business_id, transfer_id)
    REFERENCES public.inventory_transfers(business_id, id)
    ON DELETE RESTRICT,

  -- Declarative tenant-safe foreign key to product catalog
  CONSTRAINT fk_transfer_items_product
    FOREIGN KEY (business_id, product_id)
    REFERENCES public.products(business_id, id)
    ON DELETE RESTRICT,

  -- Quantity lifecycle check invariants
  CONSTRAINT chk_transfer_items_requested_positive CHECK (quantity_requested > 0),
  CONSTRAINT chk_transfer_items_shipped_non_negative CHECK (quantity_shipped >= 0),
  CONSTRAINT chk_transfer_items_received_non_negative CHECK (quantity_received >= 0),
  CONSTRAINT chk_transfer_items_cost_non_negative CHECK (unit_cost_at_dispatch >= 0)
);

-- -----------------------------------------------------------------------------
-- 4. Indexes (Targeted, non-redundant)
-- -----------------------------------------------------------------------------
-- Query by status across business
CREATE INDEX IF NOT EXISTS idx_transfers_biz_status
  ON public.inventory_transfers (business_id, status);

-- Origin branch dashboard queries
CREATE INDEX IF NOT EXISTS idx_transfers_biz_from_branch
  ON public.inventory_transfers (business_id, from_branch_id, created_at DESC);

-- Destination branch receiving dashboard queries
CREATE INDEX IF NOT EXISTS idx_transfers_biz_to_branch
  ON public.inventory_transfers (business_id, to_branch_id, created_at DESC);

-- Cross-tenant product movement audit
CREATE INDEX IF NOT EXISTS idx_transfer_items_product
  ON public.inventory_transfer_items (business_id, product_id);

-- Note: No redundant idx_transfer_items_transfer index created, as
-- uq_transfer_items_transfer_product provides a B-tree index leading with transfer_id.

-- -----------------------------------------------------------------------------
-- 5. Row-Level Security & Privilege Lockdown
-- -----------------------------------------------------------------------------
ALTER TABLE public.inventory_transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_transfer_items ENABLE ROW LEVEL SECURITY;

-- Complete lockdown of direct client mutations
REVOKE ALL ON public.inventory_transfers FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.inventory_transfer_items FROM PUBLIC, anon, authenticated;

-- Allow SELECT only to authenticated users (evaluated via RLS)
GRANT SELECT ON public.inventory_transfers TO authenticated;
GRANT SELECT ON public.inventory_transfer_items TO authenticated;

-- RLS: Transfers visible if user is business owner or holds inventory permissions on either branch
DROP POLICY IF EXISTS "policy_inventory_transfers_select" ON public.inventory_transfers;
CREATE POLICY "policy_inventory_transfers_select" ON public.inventory_transfers
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission_in_scope(business_id, 'inventory:view', from_branch_id)
  OR public.has_permission_in_scope(business_id, 'inventory:view', to_branch_id)
  OR public.has_permission_in_scope(business_id, 'inventory:transfer', from_branch_id)
  OR public.has_permission_in_scope(business_id, 'inventory:transfer', to_branch_id)
);

-- RLS: Transfer items visible if parent transfer is visible
DROP POLICY IF EXISTS "policy_inventory_transfer_items_select" ON public.inventory_transfer_items;
CREATE POLICY "policy_inventory_transfer_items_select" ON public.inventory_transfer_items
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.inventory_transfers t
    WHERE t.id = inventory_transfer_items.transfer_id
      AND t.business_id = inventory_transfer_items.business_id
  )
);

-- -----------------------------------------------------------------------------
-- 6. RPC: public.rpc_create_inventory_transfer_draft
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_inventory_transfer_draft(
  p_business_id UUID,
  p_from_branch_id UUID,
  p_to_branch_id UUID,
  p_from_location_id UUID,
  p_to_location_id UUID,
  p_items JSONB,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_transfer_number TEXT;
  v_transfer_id UUID;
  v_item RECORD;
  v_item_count INT := 0;
  v_prod_id UUID;
  v_qty NUMERIC(15, 4);
  v_seen_products UUID[] := '{}';
  v_result JSONB;
BEGIN
  -- 1. Authentication & Tenant Membership
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: Active authenticated session required to create transfer draft.';
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.is_member_of_business(p_business_id)
  ) THEN
    RAISE EXCEPTION 'TENANT_MISMATCH: Caller % is not an active member of business %', v_caller_id, p_business_id;
  END IF;

  -- 2. Authorization: inventory:transfer on origin branch
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(p_business_id, 'inventory:transfer', p_from_branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks inventory:transfer on origin branch %', v_caller_id, p_from_branch_id;
  END IF;

  -- 3. Branch & Location Invariants
  IF p_from_branch_id = p_to_branch_id THEN
    RAISE EXCEPTION 'INVALID_BRANCHES: Origin branch and destination branch must differ.';
  END IF;

  IF p_from_location_id = p_to_location_id THEN
    RAISE EXCEPTION 'INVALID_LOCATIONS: Origin location and destination location must differ.';
  END IF;

  -- Validate origin location belongs to origin branch
  IF NOT EXISTS (
    SELECT 1 FROM public.inventory_locations
    WHERE id = p_from_location_id
      AND branch_id = p_from_branch_id
      AND business_id = p_business_id
      AND is_active = true
      AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'INVALID_ORIGIN_LOCATION: Location % does not belong to origin branch %', p_from_location_id, p_from_branch_id;
  END IF;

  -- Validate destination location belongs to destination branch
  IF NOT EXISTS (
    SELECT 1 FROM public.inventory_locations
    WHERE id = p_to_location_id
      AND branch_id = p_to_branch_id
      AND business_id = p_business_id
      AND is_active = true
      AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'INVALID_DESTINATION_LOCATION: Location % does not belong to destination branch %', p_to_location_id, p_to_branch_id;
  END IF;

  -- 4. Item Payload Validation
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'INVALID_ITEMS: Transfer draft requires at least one line item.';
  END IF;

  -- 5. Generate Server-Authoritative Transfer Number
  v_transfer_number := public.rpc_next_document_number(p_business_id, 'inventory_transfer', 'TRF');

  -- 6. Insert Transfer Header (moves zero stock)
  INSERT INTO public.inventory_transfers (
    business_id,
    transfer_number,
    from_branch_id,
    to_branch_id,
    from_location_id,
    to_location_id,
    status,
    notes,
    created_by,
    created_at,
    updated_at
  ) VALUES (
    p_business_id,
    v_transfer_number,
    p_from_branch_id,
    p_to_branch_id,
    p_from_location_id,
    p_to_location_id,
    'draft',
    p_notes,
    v_caller_id,
    NOW(),
    NOW()
  )
  RETURNING id INTO v_transfer_id;

  -- 7. Insert Child Items
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_prod_id := (v_item.value->>'product_id')::UUID;
    v_qty := (v_item.value->>'quantity_requested')::NUMERIC;

    IF v_prod_id IS NULL THEN
      RAISE EXCEPTION 'INVALID_ITEM: product_id must not be null.';
    END IF;

    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'INVALID_QUANTITY: quantity_requested must be greater than zero for product %', v_prod_id;
    END IF;

    -- Reject duplicate products on same transfer
    IF v_prod_id = ANY(v_seen_products) THEN
      RAISE EXCEPTION 'DUPLICATE_PRODUCT: Product % appears multiple times in transfer payload.', v_prod_id;
    END IF;
    v_seen_products := array_append(v_seen_products, v_prod_id);

    -- Verify product belongs to business and is active
    IF NOT EXISTS (
      SELECT 1 FROM public.products
      WHERE id = v_prod_id
        AND business_id = p_business_id
        AND is_active = true
        AND deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'PRODUCT_NOT_FOUND: Product % does not exist or is inactive in business %', v_prod_id, p_business_id;
    END IF;

    INSERT INTO public.inventory_transfer_items (
      business_id,
      transfer_id,
      product_id,
      quantity_requested,
      quantity_shipped,
      quantity_received,
      unit_cost_at_dispatch,
      created_at
    ) VALUES (
      p_business_id,
      v_transfer_id,
      v_prod_id,
      v_qty,
      0.0000,
      0.0000,
      0.0000,
      NOW()
    );

    v_item_count := v_item_count + 1;
  END LOOP;

  -- 8. Return Authoritative Transfer
  SELECT jsonb_build_object(
    'id', t.id,
    'business_id', t.business_id,
    'transfer_number', t.transfer_number,
    'from_branch_id', t.from_branch_id,
    'to_branch_id', t.to_branch_id,
    'from_location_id', t.from_location_id,
    'to_location_id', t.to_location_id,
    'status', t.status,
    'notes', t.notes,
    'created_by', t.created_by,
    'created_at', t.created_at,
    'updated_at', t.updated_at,
    'item_count', v_item_count
  ) INTO v_result
  FROM public.inventory_transfers t
  WHERE t.id = v_transfer_id;

  RETURN v_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 7. RPC: public.rpc_update_inventory_transfer_draft
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_update_inventory_transfer_draft(
  p_business_id UUID,
  p_transfer_id UUID,
  p_to_branch_id UUID DEFAULT NULL,
  p_to_location_id UUID DEFAULT NULL,
  p_items JSONB DEFAULT NULL,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_transfer RECORD;
  v_dest_branch_id UUID;
  v_dest_location_id UUID;
  v_item RECORD;
  v_prod_id UUID;
  v_qty NUMERIC(15, 4);
  v_seen_products UUID[] := '{}';
  v_item_count INT := 0;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: Active authenticated session required to update transfer draft.';
  END IF;

  -- Lock transfer FOR UPDATE
  SELECT * INTO v_transfer
  FROM public.inventory_transfers
  WHERE id = p_transfer_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TRANSFER_NOT_FOUND: Transfer % does not exist in business %', p_transfer_id, p_business_id;
  END IF;

  IF v_transfer.status <> 'draft' THEN
    RAISE EXCEPTION 'INVALID_STATUS: Only draft transfers can be edited. Current status is %', v_transfer.status;
  END IF;

  -- Authorization: origin branch authority
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(p_business_id, 'inventory:transfer', v_transfer.from_branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks inventory:transfer on origin branch %', v_caller_id, v_transfer.from_branch_id;
  END IF;

  v_dest_branch_id := COALESCE(p_to_branch_id, v_transfer.to_branch_id);
  v_dest_location_id := COALESCE(p_to_location_id, v_transfer.to_location_id);

  IF v_dest_branch_id = v_transfer.from_branch_id THEN
    RAISE EXCEPTION 'INVALID_BRANCHES: Origin branch and destination branch must differ.';
  END IF;

  IF v_dest_location_id = v_transfer.from_location_id THEN
    RAISE EXCEPTION 'INVALID_LOCATIONS: Origin location and destination location must differ.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.inventory_locations
    WHERE id = v_dest_location_id
      AND branch_id = v_dest_branch_id
      AND business_id = p_business_id
      AND is_active = true
      AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'INVALID_DESTINATION_LOCATION: Location % does not belong to destination branch %', v_dest_location_id, v_dest_branch_id;
  END IF;

  -- Update header
  UPDATE public.inventory_transfers
  SET
    to_branch_id = v_dest_branch_id,
    to_location_id = v_dest_location_id,
    notes = COALESCE(p_notes, notes),
    updated_at = NOW()
  WHERE id = p_transfer_id;

  -- If items array provided, replace child items
  IF p_items IS NOT NULL THEN
    IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
      RAISE EXCEPTION 'INVALID_ITEMS: Transfer draft requires at least one line item.';
    END IF;

    DELETE FROM public.inventory_transfer_items
    WHERE transfer_id = p_transfer_id;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
      v_prod_id := (v_item.value->>'product_id')::UUID;
      v_qty := (v_item.value->>'quantity_requested')::NUMERIC;

      IF v_prod_id IS NULL OR v_qty IS NULL OR v_qty <= 0 THEN
        RAISE EXCEPTION 'INVALID_ITEM: product_id and quantity_requested (>0) are required.';
      END IF;

      IF v_prod_id = ANY(v_seen_products) THEN
        RAISE EXCEPTION 'DUPLICATE_PRODUCT: Product % appears multiple times in transfer payload.', v_prod_id;
      END IF;
      v_seen_products := array_append(v_seen_products, v_prod_id);

      IF NOT EXISTS (
        SELECT 1 FROM public.products
        WHERE id = v_prod_id
          AND business_id = p_business_id
          AND is_active = true
          AND deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND: Product % does not exist or is inactive in business %', v_prod_id, p_business_id;
      END IF;

      INSERT INTO public.inventory_transfer_items (
        business_id,
        transfer_id,
        product_id,
        quantity_requested,
        quantity_shipped,
        quantity_received,
        unit_cost_at_dispatch,
        created_at
      ) VALUES (
        p_business_id,
        p_transfer_id,
        v_prod_id,
        v_qty,
        0.0000,
        0.0000,
        0.0000,
        NOW()
      );

      v_item_count := v_item_count + 1;
    END LOOP;
  ELSE
    SELECT COUNT(*) INTO v_item_count
    FROM public.inventory_transfer_items
    WHERE transfer_id = p_transfer_id;
  END IF;

  SELECT jsonb_build_object(
    'id', t.id,
    'business_id', t.business_id,
    'transfer_number', t.transfer_number,
    'from_branch_id', t.from_branch_id,
    'to_branch_id', t.to_branch_id,
    'from_location_id', t.from_location_id,
    'to_location_id', t.to_location_id,
    'status', t.status,
    'notes', t.notes,
    'updated_at', t.updated_at,
    'item_count', v_item_count
  ) INTO v_result
  FROM public.inventory_transfers t
  WHERE t.id = p_transfer_id;

  RETURN v_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 8. RPC: public.rpc_cancel_inventory_transfer
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_cancel_inventory_transfer(
  p_business_id UUID,
  p_transfer_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_transfer RECORD;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: Active authenticated session required to cancel transfer.';
  END IF;

  SELECT * INTO v_transfer
  FROM public.inventory_transfers
  WHERE id = p_transfer_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TRANSFER_NOT_FOUND: Transfer % does not exist in business %', p_transfer_id, p_business_id;
  END IF;

  -- Idempotency check: already cancelled returns state safely
  IF v_transfer.status = 'cancelled' THEN
    SELECT jsonb_build_object(
      'id', t.id,
      'transfer_number', t.transfer_number,
      'status', t.status,
      'notes', t.notes,
      'updated_at', t.updated_at
    ) INTO v_result
    FROM public.inventory_transfers t
    WHERE t.id = p_transfer_id;
    RETURN v_result;
  END IF;

  IF v_transfer.status <> 'draft' THEN
    RAISE EXCEPTION 'CANNOT_CANCEL_TRANSFER: Only draft transfers can be cancelled. Current status is %', v_transfer.status;
  END IF;

  -- Authorization: origin branch authority
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(p_business_id, 'inventory:transfer', v_transfer.from_branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks inventory:transfer on origin branch %', v_caller_id, v_transfer.from_branch_id;
  END IF;

  -- Transition draft -> cancelled (moves ZERO inventory)
  UPDATE public.inventory_transfers
  SET
    status = 'cancelled',
    notes = CASE
      WHEN p_reason IS NOT NULL AND p_reason <> '' THEN COALESCE(notes || E'\n', '') || 'Cancelled: ' || p_reason
      ELSE notes
    END,
    updated_at = NOW()
  WHERE id = p_transfer_id;

  SELECT jsonb_build_object(
    'id', t.id,
    'transfer_number', t.transfer_number,
    'status', t.status,
    'notes', t.notes,
    'updated_at', t.updated_at
  ) INTO v_result
  FROM public.inventory_transfers t
  WHERE t.id = p_transfer_id;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_cancel_inventory_transfer_draft(
  p_business_id UUID,
  p_transfer_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public.rpc_cancel_inventory_transfer(p_business_id, p_transfer_id, p_reason);
END;
$$;

-- -----------------------------------------------------------------------------
-- 9. RPC: public.rpc_dispatch_inventory_transfer
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_dispatch_inventory_transfer(
  p_business_id UUID,
  p_transfer_id UUID,
  p_idempotency_key UUID,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_transfer RECORD;
  v_item RECORD;
  v_bal RECORD;
  v_avail_qty NUMERIC(15, 4);
  v_dispatched_items JSONB := '[]'::jsonb;
  v_result JSONB;
BEGIN
  -- 1. Validate Input & Required Idempotency Key
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for dispatch.';
  END IF;

  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: Active authenticated session required to dispatch transfer.';
  END IF;

  -- 2. Lock Transfer Header FOR UPDATE
  SELECT * INTO v_transfer
  FROM public.inventory_transfers
  WHERE id = p_transfer_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TRANSFER_NOT_FOUND: Transfer % does not exist in business %', p_transfer_id, p_business_id;
  END IF;

  -- 3. Idempotent Retry Evaluation
  IF v_transfer.status = 'in_transit' THEN
    IF v_transfer.dispatch_idempotency_key = p_idempotency_key THEN
      -- Identical key replay: return authoritative committed receipt without repeating movements
      SELECT jsonb_build_object(
        'id', t.id,
        'transfer_number', t.transfer_number,
        'status', t.status,
        'shipped_at', t.shipped_at,
        'shipped_by', t.shipped_by,
        'dispatch_idempotency_key', t.dispatch_idempotency_key,
        'is_replay', true
      ) INTO v_result
      FROM public.inventory_transfers t
      WHERE t.id = p_transfer_id;
      RETURN v_result;
    ELSE
      RAISE EXCEPTION 'TRANSFER_ALREADY_DISPATCHED: Transfer % is already in transit under dispatch key %',
        p_transfer_id, v_transfer.dispatch_idempotency_key;
    END IF;
  END IF;

  IF v_transfer.status <> 'draft' THEN
    RAISE EXCEPTION 'INVALID_STATUS: Transfer % cannot be dispatched from status %', p_transfer_id, v_transfer.status;
  END IF;

  -- 4. Scope Authorization on origin branch
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(p_business_id, 'inventory:transfer', v_transfer.from_branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks inventory:transfer on origin branch %', v_caller_id, v_transfer.from_branch_id;
  END IF;

  -- 5. Validate Line Items Exist
  IF NOT EXISTS (
    SELECT 1 FROM public.inventory_transfer_items
    WHERE transfer_id = p_transfer_id
  ) THEN
    RAISE EXCEPTION 'NO_ITEMS: Transfer % has no line items to dispatch.', p_transfer_id;
  END IF;

  -- 6. Process Transfer Line Items with Deterministic Lock Ordering (product_id ASC)
  FOR v_item IN
    SELECT ti.*
    FROM public.inventory_transfer_items ti
    WHERE ti.transfer_id = p_transfer_id
    ORDER BY ti.product_id ASC
  LOOP
    -- Pessimistic Lock on Source Balance Row
    SELECT id, on_hand_quantity, reserved_quantity, average_unit_cost
    INTO v_bal
    FROM public.inventory_balances
    WHERE business_id = p_business_id
      AND location_id = v_transfer.from_location_id
      AND product_id = v_item.product_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'INVENTORY_BALANCE_NOT_FOUND: Source location % has no initialized inventory record for product %',
        v_transfer.from_location_id, v_item.product_id;
    END IF;

    -- Validate Available Stock (prohibits touching reserved stock or going negative)
    v_avail_qty := v_bal.on_hand_quantity - v_bal.reserved_quantity;
    IF v_item.quantity_requested > v_avail_qty THEN
      RAISE EXCEPTION 'INSUFFICIENT_AVAILABLE_STOCK: Product % requires % units, but only % available (on_hand: %, reserved: %)',
        v_item.product_id, v_item.quantity_requested, v_avail_qty, v_bal.on_hand_quantity, v_bal.reserved_quantity;
    END IF;

    -- Capture Authoritative Source WAC
    UPDATE public.inventory_transfer_items
    SET
      quantity_shipped = v_item.quantity_requested,
      unit_cost_at_dispatch = COALESCE(v_bal.average_unit_cost, 0.0000)
    WHERE id = v_item.id;

    -- Decrement Source Stock & Append TRANSFER_OUT to Append-Only Ledger
    PERFORM public.rpc_post_inventory_movement(
      p_business_id := p_business_id,
      p_branch_id := v_transfer.from_branch_id,
      p_location_id := v_transfer.from_location_id,
      p_product_id := v_item.product_id,
      p_movement_type := 'TRANSFER_OUT',
      p_quantity := -ABS(v_item.quantity_requested),
      p_unit_cost := COALESCE(v_bal.average_unit_cost, 0.0000),
      p_reference_type := 'transfer',
      p_reference_id := p_transfer_id,
      p_notes := 'Transfer Out ' || v_transfer.transfer_number,
      p_allow_negative := FALSE
    );

    v_dispatched_items := v_dispatched_items || jsonb_build_object(
      'product_id', v_item.product_id,
      'quantity_shipped', v_item.quantity_requested,
      'unit_cost_at_dispatch', COALESCE(v_bal.average_unit_cost, 0.0000)
    );
  END LOOP;

  -- 7. Update Transfer Header to in_transit
  UPDATE public.inventory_transfers
  SET
    status = 'in_transit',
    shipped_by = v_caller_id,
    shipped_at = NOW(),
    dispatch_idempotency_key = p_idempotency_key,
    notes = CASE
      WHEN p_notes IS NOT NULL AND p_notes <> '' THEN COALESCE(notes || E'\n', '') || 'Dispatch: ' || p_notes
      ELSE notes
    END,
    updated_at = NOW()
  WHERE id = p_transfer_id;

  -- 8. Return Authoritative Receipt
  SELECT jsonb_build_object(
    'id', t.id,
    'transfer_number', t.transfer_number,
    'from_branch_id', t.from_branch_id,
    'to_branch_id', t.to_branch_id,
    'from_location_id', t.from_location_id,
    'to_location_id', t.to_location_id,
    'status', t.status,
    'shipped_at', t.shipped_at,
    'shipped_by', t.shipped_by,
    'dispatch_idempotency_key', t.dispatch_idempotency_key,
    'items', v_dispatched_items,
    'is_replay', false
  ) INTO v_result
  FROM public.inventory_transfers t
  WHERE t.id = p_transfer_id;

  RETURN v_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 10. RPC: public.rpc_receive_inventory_transfer
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_receive_inventory_transfer(
  p_business_id UUID,
  p_transfer_id UUID,
  p_idempotency_key UUID,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_transfer RECORD;
  v_item RECORD;
  v_received_items JSONB := '[]'::jsonb;
  v_result JSONB;
BEGIN
  -- 1. Validate Input & Required Idempotency Key
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for receive.';
  END IF;

  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: Active authenticated session required to receive transfer.';
  END IF;

  -- 2. Lock Transfer Header FOR UPDATE
  SELECT * INTO v_transfer
  FROM public.inventory_transfers
  WHERE id = p_transfer_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TRANSFER_NOT_FOUND: Transfer % does not exist in business %', p_transfer_id, p_business_id;
  END IF;

  -- 3. Idempotent Retry Evaluation
  IF v_transfer.status = 'received' THEN
    IF v_transfer.receive_idempotency_key = p_idempotency_key THEN
      -- Identical key replay: return authoritative committed receipt without repeating movements
      SELECT jsonb_build_object(
        'id', t.id,
        'transfer_number', t.transfer_number,
        'status', t.status,
        'received_at', t.received_at,
        'received_by', t.received_by,
        'receive_idempotency_key', t.receive_idempotency_key,
        'is_replay', true
      ) INTO v_result
      FROM public.inventory_transfers t
      WHERE t.id = p_transfer_id;
      RETURN v_result;
    ELSE
      RAISE EXCEPTION 'TRANSFER_ALREADY_RECEIVED: Transfer % is already received under key %',
        p_transfer_id, v_transfer.receive_idempotency_key;
    END IF;
  END IF;

  IF v_transfer.status <> 'in_transit' THEN
    RAISE EXCEPTION 'INVALID_STATUS: Transfer % cannot be received from status %', p_transfer_id, v_transfer.status;
  END IF;

  -- 4. Scope Authorization on destination branch
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(p_business_id, 'inventory:transfer', v_transfer.to_branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks inventory:transfer on destination branch %', v_caller_id, v_transfer.to_branch_id;
  END IF;

  -- 5. Process Transfer Line Items with Deterministic Lock Ordering (product_id ASC)
  FOR v_item IN
    SELECT ti.*
    FROM public.inventory_transfer_items ti
    WHERE ti.transfer_id = p_transfer_id
    ORDER BY ti.product_id ASC
  LOOP
    -- Concurrency-safe initialization of missing destination balance row
    INSERT INTO public.inventory_balances (
      business_id,
      branch_id,
      location_id,
      product_id,
      on_hand_quantity,
      reserved_quantity,
      average_unit_cost,
      updated_at
    ) VALUES (
      p_business_id,
      v_transfer.to_branch_id,
      v_transfer.to_location_id,
      v_item.product_id,
      0.0000,
      0.0000,
      GREATEST(COALESCE(v_item.unit_cost_at_dispatch, 0.0000), 0.0000),
      NOW()
    )
    ON CONFLICT (business_id, location_id, product_id) DO NOTHING;

    -- Update Item: Full Receipt Invariant (quantity_received = quantity_shipped)
    UPDATE public.inventory_transfer_items
    SET quantity_received = v_item.quantity_shipped
    WHERE id = v_item.id;

    -- Increment Destination Stock & Append TRANSFER_IN to Append-Only Ledger
    -- rpc_post_inventory_movement locks row FOR UPDATE and blends WAC mathematically
    PERFORM public.rpc_post_inventory_movement(
      p_business_id := p_business_id,
      p_branch_id := v_transfer.to_branch_id,
      p_location_id := v_transfer.to_location_id,
      p_product_id := v_item.product_id,
      p_movement_type := 'TRANSFER_IN',
      p_quantity := ABS(v_item.quantity_shipped),
      p_unit_cost := COALESCE(v_item.unit_cost_at_dispatch, 0.0000),
      p_reference_type := 'transfer',
      p_reference_id := p_transfer_id,
      p_notes := 'Transfer In ' || v_transfer.transfer_number,
      p_allow_negative := FALSE
    );

    v_received_items := v_received_items || jsonb_build_object(
      'product_id', v_item.product_id,
      'quantity_received', v_item.quantity_shipped,
      'unit_cost_at_dispatch', v_item.unit_cost_at_dispatch
    );
  END LOOP;

  -- 6. Update Transfer Header to received
  UPDATE public.inventory_transfers
  SET
    status = 'received',
    received_by = v_caller_id,
    received_at = NOW(),
    receive_idempotency_key = p_idempotency_key,
    notes = CASE
      WHEN p_notes IS NOT NULL AND p_notes <> '' THEN COALESCE(notes || E'\n', '') || 'Receive: ' || p_notes
      ELSE notes
    END,
    updated_at = NOW()
  WHERE id = p_transfer_id;

  -- 7. Return Authoritative Receipt
  SELECT jsonb_build_object(
    'id', t.id,
    'transfer_number', t.transfer_number,
    'from_branch_id', t.from_branch_id,
    'to_branch_id', t.to_branch_id,
    'from_location_id', t.from_location_id,
    'to_location_id', t.to_location_id,
    'status', t.status,
    'received_at', t.received_at,
    'received_by', t.received_by,
    'receive_idempotency_key', t.receive_idempotency_key,
    'items', v_received_items,
    'is_replay', false
  ) INTO v_result
  FROM public.inventory_transfers t
  WHERE t.id = p_transfer_id;

  RETURN v_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 11. Grant Execute Privileges on Transfer RPCs strictly to authenticated
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.rpc_create_inventory_transfer_draft FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_update_inventory_transfer_draft FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_cancel_inventory_transfer FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_cancel_inventory_transfer_draft FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_dispatch_inventory_transfer FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_receive_inventory_transfer FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.rpc_create_inventory_transfer_draft TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_update_inventory_transfer_draft TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_cancel_inventory_transfer TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_cancel_inventory_transfer_draft TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_dispatch_inventory_transfer TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_receive_inventory_transfer TO authenticated;

COMMIT;
