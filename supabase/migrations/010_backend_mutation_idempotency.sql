-- ==============================================================================
-- FINTAB ENTERPRISE — MIGRATION 010
-- Phase 6B-3: Backend Mutation Idempotency & Retry Safety
--
-- Baseline: 1.3.0-phase6b2-frozen
-- Migrations 001-009 are immutable.
--
-- Covers:
-- 1. public.idempotency_records centralized table with strict RLS and zero direct client access
-- 2. Concurrency-safe atomic reservation & replay helpers (fn_idempotency_acquire / commit)
-- 3. Deterministic canonical payload hashing
-- 4. Mandatory idempotency key enforcement on all top-level financial/operational mutation RPCs:
--    - rpc_complete_sale
--    - rpc_record_payment
--    - rpc_pay_expense
--    - rpc_open_register_shift
--    - rpc_close_register_shift
--    - rpc_post_bank_transaction
--    - rpc_post_cash_transaction
-- 5. Dual-mode protection for rpc_post_inventory_movement
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. CENTRALIZED IDEMPOTENCY RECORDS TABLE
-- ------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.idempotency_records (
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  idempotency_key UUID NOT NULL,
  operation VARCHAR(64) NOT NULL,
  request_hash VARCHAR(64) NOT NULL,
  user_id UUID NOT NULL REFERENCES auth.users(id),
  status VARCHAR(32) NOT NULL DEFAULT 'started',
  response_payload JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (business_id, idempotency_key),
  CONSTRAINT chk_idempotency_status CHECK (status IN ('started', 'committed'))
);

CREATE INDEX IF NOT EXISTS idx_idempotency_records_lookup 
  ON public.idempotency_records(business_id, operation, created_at);

-- RLS: Table is strictly internal. Direct table mutations/queries from anon/authenticated are forbidden.
ALTER TABLE public.idempotency_records ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.idempotency_records FROM PUBLIC, anon, authenticated;

-- Internal policy for security definer RPCs
DROP POLICY IF EXISTS p_idempotency_records_member_isolation ON public.idempotency_records;
CREATE POLICY p_idempotency_records_member_isolation ON public.idempotency_records
  FOR ALL
  TO authenticated
  USING (
    business_id = ANY (
      SELECT bm.business_id 
      FROM public.business_memberships bm 
      WHERE bm.user_id = auth.uid() AND bm.status = 'active'
    )
  );

-- ------------------------------------------------------------------------------
-- 2. CANONICAL NORMALIZATION & HASHING HELPERS
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_canonicalize_sale_items(p_items JSONB)
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'product_id', LOWER(elem->>'product_id'),
        'location_id', LOWER(elem->>'location_id'),
        'quantity', to_char((elem->>'quantity')::NUMERIC, 'FM999999999999990.0000'),
        'unit_price', CASE 
          WHEN (elem->>'unit_price') IS NOT NULL 
          THEN to_char((elem->>'unit_price')::NUMERIC, 'FM999999999999990.0000') 
          ELSE NULL 
        END,
        'price_tier', CASE
          WHEN (elem->>'price_tier') IS NOT NULL
          THEN LOWER(TRIM(elem->>'price_tier'))
          ELSE NULL
        END,
        'discount_amount', to_char(COALESCE((elem->>'discount_amount')::NUMERIC, 0.0000), 'FM999999999999990.0000'),
        'tax_rate', CASE
          WHEN (elem->>'tax_rate') IS NOT NULL
          THEN to_char((elem->>'tax_rate')::NUMERIC, 'FM999999999999990.0000')
          ELSE NULL
        END,
        'tax_amount', CASE
          WHEN (elem->>'tax_amount') IS NOT NULL
          THEN to_char((elem->>'tax_amount')::NUMERIC, 'FM999999999999990.0000')
          ELSE NULL
        END,
        'notes', TRIM(COALESCE(elem->>'notes', ''))
      )
      ORDER BY (elem->>'product_id')::UUID ASC, (elem->>'location_id')::UUID ASC, (elem->>'quantity')::NUMERIC ASC, TRIM(COALESCE(elem->>'price_tier', '')) ASC
    ),
    '[]'::jsonb
  )
  FROM jsonb_array_elements(p_items) AS elem;
$$;

CREATE OR REPLACE FUNCTION public.fn_canonicalize_payments(p_payments JSONB)
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'payment_method', LOWER(TRIM(elem->>'payment_method')),
        'amount', to_char((elem->>'amount')::NUMERIC, 'FM999999999999990.0000'),
        'bank_account_id', LOWER(COALESCE(elem->>'bank_account_id', '')),
        'reference_number', TRIM(COALESCE(elem->>'reference_number', '')),
        'notes', TRIM(COALESCE(elem->>'notes', ''))
      )
      ORDER BY LOWER(TRIM(elem->>'payment_method')) ASC, (elem->>'amount')::NUMERIC ASC, COALESCE(elem->>'bank_account_id', '') ASC, TRIM(COALESCE(elem->>'reference_number', '')) ASC
    ),
    '[]'::jsonb
  )
  FROM jsonb_array_elements(p_payments) AS elem;
$$;

-- ------------------------------------------------------------------------------
-- 3. CORE ATOMIC ACQUIRE & COMMIT HELPERS
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_idempotency_acquire(
  p_business_id UUID,
  p_idempotency_key UUID,
  p_operation VARCHAR,
  p_request_hash VARCHAR,
  p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rec RECORD;
  v_caller_id UUID;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_user_id IS NOT NULL AND p_user_id <> v_caller_id THEN
    RAISE EXCEPTION 'USER_MISMATCH: Cannot acquire idempotency record for another user';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for %', p_operation;
  END IF;

  -- 1. Atomic reservation via INSERT ... ON CONFLICT DO NOTHING
  INSERT INTO public.idempotency_records (
    business_id,
    idempotency_key,
    operation,
    request_hash,
    user_id,
    status,
    created_at,
    updated_at
  ) VALUES (
    p_business_id,
    p_idempotency_key,
    p_operation,
    p_request_hash,
    v_caller_id,
    'started',
    NOW(),
    NOW()
  )
  ON CONFLICT (business_id, idempotency_key) DO NOTHING;

  -- 2. Lock the row FOR UPDATE to synchronize concurrent attempts
  SELECT * INTO v_rec
  FROM public.idempotency_records
  WHERE business_id = p_business_id AND idempotency_key = p_idempotency_key
  FOR UPDATE;

  -- 3. Validate operation matches (key reuse across operations rejected)
  IF v_rec.operation <> p_operation THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED_ACROSS_OPERATIONS: Key % was registered for % but submitted for %',
      p_idempotency_key, v_rec.operation, p_operation;
  END IF;

  -- 4. Check status
  IF v_rec.status = 'committed' THEN
    -- Check payload conflict
    IF v_rec.request_hash <> p_request_hash THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: Idempotency key % has already been used with different request parameters',
        p_idempotency_key;
    END IF;

    -- Actor permission check on replay
    IF v_rec.user_id <> v_caller_id THEN
      IF NOT (
        public.is_business_owner(p_business_id) 
        OR public.has_permission(p_business_id, 'sales:manage')
        OR public.has_permission(p_business_id, 'financials:view')
        OR public.has_permission(p_business_id, 'registers:manage')
      ) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: Idempotency key belongs to another user.';
      END IF;
    END IF;

    RETURN jsonb_build_object(
      'action', 'replay',
      'payload', COALESCE(v_rec.response_payload, '{}'::jsonb) || jsonb_build_object('is_replay', true)
    );
  END IF;

  -- Status is 'started': we hold the lock for initial execution
  IF v_rec.user_id <> v_caller_id THEN
    RAISE EXCEPTION 'USER_MISMATCH: Idempotency record is in progress by another user';
  END IF;

  RETURN jsonb_build_object('action', 'execute');
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_idempotency_commit(
  p_business_id UUID,
  p_idempotency_key UUID,
  p_payload JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  -- Ensure caller owns the idempotency record being committed
  IF NOT EXISTS (
    SELECT 1 FROM public.idempotency_records
    WHERE business_id = p_business_id AND idempotency_key = p_idempotency_key AND user_id = v_caller_id
  ) THEN
    RAISE EXCEPTION 'USER_MISMATCH: Cannot commit idempotency record owned by another user';
  END IF;

  UPDATE public.idempotency_records
  SET
    status = 'committed',
    response_payload = p_payload,
    updated_at = NOW()
  WHERE business_id = p_business_id AND idempotency_key = p_idempotency_key;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_idempotency_acquire(UUID, UUID, VARCHAR, VARCHAR, UUID) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.fn_idempotency_commit(UUID, UUID, JSONB) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------------------------
-- 4. DROP OBSOLETE NON-IDEMPOTENT OVERLOADS
-- ------------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.rpc_complete_sale(UUID, UUID, UUID, UUID, JSONB, JSONB, UUID, TEXT, JSONB);
DROP FUNCTION IF EXISTS public.rpc_record_payment(UUID, UUID, TEXT, NUMERIC, UUID, UUID, UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.rpc_pay_expense(UUID, UUID, TEXT, UUID, UUID, UUID, TEXT);
DROP FUNCTION IF EXISTS public.rpc_open_register_shift(UUID, UUID, UUID, NUMERIC, TEXT);
DROP FUNCTION IF EXISTS public.rpc_close_register_shift(UUID, UUID, NUMERIC, TEXT);
DROP FUNCTION IF EXISTS public.rpc_post_bank_transaction(UUID, UUID, TEXT, TEXT, NUMERIC, TEXT, TEXT, UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.rpc_post_cash_transaction(UUID, UUID, UUID, UUID, TEXT, NUMERIC, TEXT, TEXT, UUID, TEXT);
DROP FUNCTION IF EXISTS public.rpc_post_inventory_movement(UUID, UUID, UUID, UUID, TEXT, NUMERIC, NUMERIC, TEXT, UUID, TEXT, BOOLEAN);
DROP FUNCTION IF EXISTS public.rpc_post_inventory_movement(UUID, UUID, UUID, UUID, TEXT, NUMERIC, NUMERIC, TEXT, UUID, TEXT, BOOLEAN, UUID);

-- ------------------------------------------------------------------------------
-- 4B. INTERNAL AUTHORITATIVE INVENTORY PRIMITIVE (NOT EXECUTABLE VIA CLIENT API)
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_post_inventory_movement_internal(
  p_business_id UUID,
  p_branch_id UUID,
  p_location_id UUID,
  p_product_id UUID,
  p_movement_type TEXT,
  p_quantity NUMERIC,
  p_unit_cost NUMERIC DEFAULT 0.0000,
  p_reference_type TEXT DEFAULT 'adjustment',
  p_reference_id UUID DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_allow_negative BOOLEAN DEFAULT FALSE,
  p_caller_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_balance_id UUID;
  v_current_on_hand NUMERIC(15, 4);
  v_current_reserved NUMERIC(15, 4);
  v_current_avg_cost NUMERIC(15, 4);
  v_new_on_hand NUMERIC(15, 4);
  v_new_avg_cost NUMERIC(15, 4);
  v_movement_id UUID;
  v_product_exists BOOLEAN;
  v_location_branch_match BOOLEAN;
BEGIN
  -- Validate Product
  SELECT EXISTS (
    SELECT 1 FROM public.products
    WHERE id = p_product_id AND business_id = p_business_id AND is_active = true AND deleted_at IS NULL
  ) INTO v_product_exists;

  IF NOT v_product_exists THEN
    RAISE EXCEPTION 'INVALID_PRODUCT: Product % does not exist or is inactive in business %', p_product_id, p_business_id;
  END IF;

  -- Validate Location
  SELECT EXISTS (
    SELECT 1 FROM public.inventory_locations
    WHERE id = p_location_id AND branch_id = p_branch_id AND business_id = p_business_id AND is_active = true AND deleted_at IS NULL
  ) INTO v_location_branch_match;

  IF NOT v_location_branch_match THEN
    RAISE EXCEPTION 'INVALID_LOCATION: Location % does not belong to branch % in business %', p_location_id, p_branch_id, p_business_id;
  END IF;

  -- Atomic Concurrency Lock on inventory_balances
  INSERT INTO public.inventory_balances (
    business_id, branch_id, location_id, product_id,
    on_hand_quantity, reserved_quantity, average_unit_cost, updated_at
  ) VALUES (
    p_business_id, p_branch_id, p_location_id, p_product_id,
    0.0000, 0.0000, GREATEST(COALESCE(p_unit_cost, 0.0000), 0.0000), NOW()
  )
  ON CONFLICT (business_id, location_id, product_id) DO NOTHING;

  SELECT id, on_hand_quantity, reserved_quantity, average_unit_cost
  INTO v_balance_id, v_current_on_hand, v_current_reserved, v_current_avg_cost
  FROM public.inventory_balances
  WHERE business_id = p_business_id AND location_id = p_location_id AND product_id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONCURRENCY_ERROR: Failed to acquire lock on inventory balance';
  END IF;

  v_new_on_hand := v_current_on_hand + p_quantity;

  IF NOT p_allow_negative THEN
    IF v_new_on_hand < 0 THEN
      RAISE EXCEPTION 'INSUFFICIENT_STOCK: Current on hand: %, requested change: %',
        v_current_on_hand, p_quantity;
    END IF;

    IF (v_new_on_hand - v_current_reserved) < 0 THEN
      RAISE EXCEPTION 'INSUFFICIENT_AVAILABLE_STOCK: Available stock (%) insufficient for requested change (%)',
        (v_current_on_hand - v_current_reserved), p_quantity;
    END IF;
  END IF;

  -- WAC Algorithm
  IF p_quantity > 0 AND p_unit_cost > 0 THEN
    IF v_current_on_hand <= 0 THEN
      v_new_avg_cost := p_unit_cost;
    ELSE
      v_new_avg_cost := ROUND(
        ((v_current_on_hand * v_current_avg_cost) + (p_quantity * p_unit_cost)) / v_new_on_hand,
        4
      );
    END IF;
  ELSE
    v_new_avg_cost := v_current_avg_cost;
  END IF;

  -- Append to Movement Ledger
  INSERT INTO public.inventory_movements (
    business_id, branch_id, location_id, product_id,
    movement_type, quantity, unit_cost, reference_type,
    reference_id, notes, actor_id, created_at
  ) VALUES (
    p_business_id, p_branch_id, p_location_id, p_product_id,
    p_movement_type, p_quantity, p_unit_cost, p_reference_type,
    p_reference_id, p_notes, p_caller_id, NOW()
  ) RETURNING id INTO v_movement_id;

  -- Update Balance
  UPDATE public.inventory_balances
  SET
    on_hand_quantity = v_new_on_hand,
    average_unit_cost = v_new_avg_cost,
    updated_at = NOW()
  WHERE id = v_balance_id;

  RETURN jsonb_build_object(
    'success', true,
    'movement_id', v_movement_id,
    'balance_id', v_balance_id,
    'previous_on_hand', v_current_on_hand,
    'new_on_hand', v_new_on_hand,
    'average_unit_cost', v_new_avg_cost
  );
END;
$$;

-- STRICT PRIVILEGE HARDENING: Not executable by authenticated, anon, or PUBLIC
REVOKE ALL ON FUNCTION public.fn_post_inventory_movement_internal(UUID, UUID, UUID, UUID, TEXT, NUMERIC, NUMERIC, TEXT, UUID, TEXT, BOOLEAN, UUID) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------------------------
-- 5. UPGRADE: rpc_complete_sale (MANDATORY IDEMPOTENCY)
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_complete_sale(
  p_business_id UUID,
  p_branch_id UUID,
  p_register_id UUID,
  p_shift_id UUID,
  p_idempotency_key UUID,
  p_items JSONB,
  p_payments JSONB DEFAULT '[]'::jsonb,
  p_customer_id UUID DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_biz_currency VARCHAR(3);
  v_branch_active BOOLEAN;

  v_reg_status TEXT;
  v_reg_branch_id UUID;
  v_shift_status TEXT;
  v_shift_branch_id UUID;
  v_shift_register_id UUID;

  v_item_count INT := 0;
  v_subtotal NUMERIC(15, 4) := 0.0000;
  v_discount_total NUMERIC(15, 4) := 0.0000;
  v_tax_total NUMERIC(15, 4) := 0.0000;
  v_total_amount NUMERIC(15, 4) := 0.0000;

  v_total_tender NUMERIC(15, 4) := 0.0000;
  v_proposed_balance_due NUMERIC(15, 4) := 0.0000;
  v_cust_id UUID;
  v_cust_credit_limit NUMERIC(15, 4);
  v_cust_status TEXT;
  v_cust_deleted_at TIMESTAMPTZ;
  v_current_outstanding NUMERIC(15, 4) := 0.0000;

  v_txn_number TEXT;
  v_txn_id UUID;
  v_item RECORD;
  v_pay RECORD;
  v_pay_res JSONB;
  v_recorded_payments JSONB := '[]'::jsonb;

  r_agg RECORD;
  v_bal_id UUID;
  v_bal_avail NUMERIC(15, 4);
  v_bal_avg_cost NUMERIC(15, 4);
  v_prod_cost NUMERIC(15, 4);
  v_prod_active BOOLEAN;
  v_prod_deleted TIMESTAMPTZ;
  v_loc_active BOOLEAN;
  v_loc_deleted TIMESTAMPTZ;
  v_loc_branch_id UUID;
  v_item_cost NUMERIC(15, 4);
  v_item_idx INT := 0;
  v_pay_idx INT := 0;

  v_is_owner BOOLEAN := FALSE;
  v_can_discount BOOLEAN := FALSE;

  v_tier TEXT;
  v_prod_total_qty NUMERIC(15, 4);
  v_canonical_price NUMERIC(15, 4);
  v_unit_price NUMERIC(15, 4);
  v_item_qty NUMERIC(15, 4);
  v_item_disc NUMERIC(15, 4);
  v_tax_rate NUMERIC(15, 4);
  v_item_tax NUMERIC(15, 4);
  v_line_subtotal NUMERIC(15, 4);
  v_line_total NUMERIC(15, 4);
  v_resolved_items JSONB := '[]'::jsonb;

  v_final_amount_paid NUMERIC(15, 4);
  v_final_balance_due NUMERIC(15, 4);
  v_final_status TEXT;

  -- Idempotency variables
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_idem_res JSONB;
  v_result JSONB;
BEGIN
  -- 1. Validate Caller Authentication
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  -- 2. Validate Mandatory Idempotency Key
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_complete_sale';
  END IF;

  -- 3. Calculate Deterministic Request Fingerprint
  v_canonical_hash_input := jsonb_build_object(
    'branch_id', LOWER(p_branch_id::text),
    'register_id', LOWER(p_register_id::text),
    'shift_id', LOWER(p_shift_id::text),
    'customer_id', LOWER(COALESCE(p_customer_id::text, '__NULL__')),
    'notes', TRIM(COALESCE(p_notes, '')),
    'metadata', COALESCE(p_metadata, '{}'::jsonb),
    'items', public.fn_canonicalize_sale_items(p_items),
    'payments', public.fn_canonicalize_payments(COALESCE(p_payments, '[]'::jsonb))
  )::text;

  v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');

  -- 4. Acquire Idempotency Reservation
  v_idem_res := public.fn_idempotency_acquire(
    p_business_id,
    p_idempotency_key,
    'complete_sale',
    v_request_hash,
    v_caller_id
  );

  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN (v_idem_res->'payload');
  END IF;

  -- 5. Business Validation & Tenancy
  SELECT currency INTO v_biz_currency
  FROM public.businesses
  WHERE id = p_business_id AND status = 'active' AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'BUSINESS_NOT_FOUND: Active business % not found', p_business_id;
  END IF;

  -- 6. Branch Validation
  SELECT (status = 'active' AND deleted_at IS NULL) INTO v_branch_active
  FROM public.branches
  WHERE id = p_branch_id AND business_id = p_business_id;

  IF v_branch_active IS NULL OR NOT v_branch_active THEN
    RAISE EXCEPTION 'BRANCH_NOT_ACTIVE: Branch % not found or inactive in business %',
      p_branch_id, p_business_id;
  END IF;

  -- 7. Register & Shift Validation
  SELECT status, branch_id INTO v_reg_status, v_reg_branch_id
  FROM public.registers
  WHERE id = p_register_id AND business_id = p_business_id;

  IF v_reg_status IS NULL THEN
    RAISE EXCEPTION 'INVALID_REGISTER: Register % does not exist in business %',
      p_register_id, p_business_id;
  END IF;
  IF v_reg_branch_id <> p_branch_id THEN
    RAISE EXCEPTION 'BRANCH_MISMATCH: Register % belongs to branch %, not transaction branch %',
      p_register_id, v_reg_branch_id, p_branch_id;
  END IF;
  IF v_reg_status <> 'active' THEN
    RAISE EXCEPTION 'INACTIVE_REGISTER: Register % is not active (status: %)',
      p_register_id, v_reg_status;
  END IF;

  SELECT status, branch_id, register_id INTO v_shift_status, v_shift_branch_id, v_shift_register_id
  FROM public.register_shifts
  WHERE id = p_shift_id AND business_id = p_business_id;

  IF NOT FOUND OR v_shift_status <> 'open' OR v_shift_branch_id <> p_branch_id OR v_shift_register_id <> p_register_id THEN
    RAISE EXCEPTION 'INVALID_SHIFT: Shift % is not open or does not match register %', p_shift_id, p_register_id;
  END IF;

  -- 8. Authorization Checks
  v_is_owner := public.is_business_owner(p_business_id);
  IF NOT (
    v_is_owner 
    OR public.has_permission_in_scope(p_business_id, 'sales:create', p_branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks sales:create on branch % in business %',
      v_caller_id, p_branch_id, p_business_id;
  END IF;

  v_can_discount := v_is_owner OR public.has_permission_in_scope(p_business_id, 'sales:discount', p_branch_id);

  -- 9. Cart Validation & Pricing Resolution
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'EMPTY_CART: Sale must contain at least one line item';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_item_idx := v_item_idx + 1;
    v_item_qty := ((v_item.value->>'quantity')::NUMERIC);

    IF v_item_qty IS NULL OR v_item_qty <= 0 THEN
      RAISE EXCEPTION 'INVALID_QUANTITY: Item #% quantity must be greater than zero', v_item_idx;
    END IF;

    -- Validate Product
    SELECT is_active, deleted_at, cost_price INTO v_prod_active, v_prod_deleted, v_prod_cost
    FROM public.products
    WHERE id = (v_item.value->>'product_id')::UUID AND business_id = p_business_id;

    IF NOT FOUND OR v_prod_deleted IS NOT NULL OR NOT v_prod_active THEN
      RAISE EXCEPTION 'INVALID_PRODUCT: Product % not found or inactive', (v_item.value->>'product_id');
    END IF;

    -- Validate Location
    SELECT is_active, deleted_at, branch_id INTO v_loc_active, v_loc_deleted, v_loc_branch_id
    FROM public.inventory_locations
    WHERE id = (v_item.value->>'location_id')::UUID AND business_id = p_business_id;

    IF NOT FOUND OR v_loc_deleted IS NOT NULL OR NOT v_loc_active OR v_loc_branch_id <> p_branch_id THEN
      RAISE EXCEPTION 'INVALID_LOCATION: Location % does not belong to branch %', (v_item.value->>'location_id'), p_branch_id;
    END IF;

    -- Price Resolution
    IF (v_item.value->>'unit_price') IS NOT NULL THEN
      IF NOT v_can_discount THEN
        RAISE EXCEPTION 'DISCOUNT_FORBIDDEN: Manual price override not authorized for caller';
      END IF;
      v_unit_price := ((v_item.value->>'unit_price')::NUMERIC);
    ELSE
      -- Resolve Tier / Canonical Price
      v_tier := COALESCE(v_item.value->>'price_tier', 'retail');
      SELECT price INTO v_canonical_price
      FROM public.product_prices
      WHERE business_id = p_business_id 
        AND product_id = (v_item.value->>'product_id')::UUID
        AND price_tier = v_tier
        AND is_active = true
      LIMIT 1;

      IF v_canonical_price IS NULL THEN
        RAISE EXCEPTION 'PRICE_NOT_FOUND: No active % price for product %', v_tier, (v_item.value->>'product_id');
      END IF;
      v_unit_price := v_canonical_price;
    END IF;

    v_item_disc := COALESCE(((v_item.value->>'discount_amount')::NUMERIC), 0.0000);
    IF v_item_disc > 0 AND NOT v_can_discount THEN
      RAISE EXCEPTION 'DISCOUNT_FORBIDDEN: Discounts require sales:discount permission';
    END IF;

    v_line_subtotal := ROUND(v_unit_price * v_item_qty, 4);

    -- 8.7 Tax Validation & Calculation
    IF (v_item.value->>'tax_amount') IS NOT NULL AND (v_item.value->>'tax_rate') IS NOT NULL THEN
      RAISE EXCEPTION 'INVALID_TAX_INPUT: Provide tax_amount or tax_rate, not both.';
    ELSIF (v_item.value->>'tax_amount') IS NOT NULL THEN
      v_item_tax := ((v_item.value->>'tax_amount')::NUMERIC);
      IF v_item_tax < 0 THEN
        RAISE EXCEPTION 'INVALID_CART_ITEM: Item #% tax_amount cannot be negative', v_item_idx;
      END IF;
    ELSIF (v_item.value->>'tax_rate') IS NOT NULL THEN
      v_tax_rate := ((v_item.value->>'tax_rate')::NUMERIC);
      IF v_tax_rate < 0 THEN
        RAISE EXCEPTION 'INVALID_CART_ITEM: Item #% tax_rate cannot be negative', v_item_idx;
      END IF;
      v_item_tax := ROUND((v_line_subtotal - v_item_disc) * (v_tax_rate / 100.0), 4);
    ELSE
      v_item_tax := 0.0000;
    END IF;

    v_line_total := v_line_subtotal - v_item_disc + v_item_tax;

    v_subtotal := v_subtotal + v_line_subtotal;
    v_discount_total := v_discount_total + v_item_disc;
    v_tax_total := v_tax_total + v_item_tax;
    v_total_amount := v_total_amount + v_line_total;

    v_resolved_items := v_resolved_items || jsonb_build_array(
      jsonb_build_object(
        'product_id', (v_item.value->>'product_id')::UUID,
        'location_id', (v_item.value->>'location_id')::UUID,
        'quantity', v_item_qty,
        'unit_price', v_unit_price,
        'discount_amount', v_item_disc,
        'tax_amount', v_item_tax,
        'line_total', v_line_total,
        'notes', v_item.value->>'notes'
      )
    );
    v_item_count := v_item_count + 1;
  END LOOP;

  -- 10. Concurrency Lock & Stock Sufficiency
  FOR r_agg IN 
    SELECT 
      (elem->>'location_id')::UUID AS location_id,
      (elem->>'product_id')::UUID AS product_id,
      SUM((elem->>'quantity')::NUMERIC) AS total_quantity
    FROM jsonb_array_elements(v_resolved_items) AS elem
    GROUP BY (elem->>'location_id')::UUID, (elem->>'product_id')::UUID
  LOOP
    SELECT id, (on_hand_quantity - reserved_quantity)
    INTO v_bal_id, v_bal_avail
    FROM public.inventory_balances
    WHERE business_id = p_business_id
      AND location_id = r_agg.location_id
      AND product_id = r_agg.product_id
    FOR UPDATE;

    IF NOT FOUND OR v_bal_id IS NULL THEN
      RAISE EXCEPTION 'INVENTORY_BALANCE_NOT_FOUND: Product % at location % has no inventory record',
        r_agg.product_id, r_agg.location_id;
    END IF;

    IF v_bal_avail < r_agg.total_quantity THEN
      RAISE EXCEPTION 'INSUFFICIENT_STOCK: Product % requires %, only % available',
        r_agg.product_id, r_agg.total_quantity, v_bal_avail;
    END IF;
  END LOOP;

  -- 11. Payments & Tender Validation
  IF p_payments IS NOT NULL THEN
    FOR v_pay IN SELECT * FROM jsonb_array_elements(p_payments)
    LOOP
      v_pay_idx := v_pay_idx + 1;
      IF ((v_pay.value->>'amount')::NUMERIC) <= 0 THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_AMOUNT: Payment #% amount must be > 0', v_pay_idx;
      END IF;
      v_total_tender := v_total_tender + ((v_pay.value->>'amount')::NUMERIC);
    END LOOP;
  END IF;

  IF v_total_tender > v_total_amount THEN
    RAISE EXCEPTION 'OVERPAYMENT_NOT_ALLOWED: Tender (%) exceeds sale amount (%)', v_total_tender, v_total_amount;
  END IF;

  v_proposed_balance_due := v_total_amount - v_total_tender;
  IF v_proposed_balance_due > 0 THEN
    IF p_customer_id IS NULL THEN
      RAISE EXCEPTION 'CUSTOMER_REQUIRED: Credit sale with balance due requires customer';
    END IF;

    SELECT id, credit_limit, status, deleted_at
    INTO v_cust_id, v_cust_credit_limit, v_cust_status, v_cust_deleted_at
    FROM public.customers
    WHERE id = p_customer_id AND business_id = p_business_id
    FOR UPDATE;

    IF v_cust_id IS NULL OR v_cust_deleted_at IS NOT NULL OR v_cust_status <> 'active' THEN
      RAISE EXCEPTION 'INVALID_CUSTOMER: Customer % inactive or not found', p_customer_id;
    END IF;

    SELECT COALESCE(SUM(balance_due), 0.0000) INTO v_current_outstanding
    FROM public.sales_transactions
    WHERE customer_id = p_customer_id AND business_id = p_business_id AND balance_due > 0;

    IF (v_current_outstanding + v_proposed_balance_due) > v_cust_credit_limit THEN
      RAISE EXCEPTION 'CREDIT_LIMIT_EXCEEDED: Customer credit limit exceeded';
    END IF;
  END IF;

  -- 12. Create Sales Transaction Header
  v_txn_number := public.rpc_next_document_number(p_business_id, 'sale', 'TXN');

  INSERT INTO public.sales_transactions (
    business_id, branch_id, register_id, shift_id,
    cashier_user_id, customer_id, transaction_number,
    transaction_type, status,
    subtotal, discount_total, tax_total, total_amount,
    amount_paid, balance_due, currency,
    notes, occurred_at, created_at, updated_at, metadata
  ) VALUES (
    p_business_id, p_branch_id, p_register_id, p_shift_id,
    v_caller_id, p_customer_id, v_txn_number,
    'sale', 'pending_payment',
    v_subtotal, v_discount_total, v_tax_total, v_total_amount,
    0.0000, v_total_amount, v_biz_currency,
    p_notes, NOW(), NOW(), NOW(), COALESCE(p_metadata, '{}'::jsonb)
  ) RETURNING id INTO v_txn_id;

  -- 13. Insert Line Items
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_resolved_items)
  LOOP
    SELECT average_unit_cost INTO v_item_cost
    FROM public.inventory_balances
    WHERE business_id = p_business_id
      AND location_id = (v_item.value->>'location_id')::UUID
      AND product_id = (v_item.value->>'product_id')::UUID;

    v_item_cost := COALESCE(v_item_cost, 0.0000);

    INSERT INTO public.sales_transaction_items (
      business_id, transaction_id, product_id, inventory_location_id,
      quantity, unit_price, discount_amount, tax_amount, line_total,
      cost_price, notes, created_at
    ) VALUES (
      p_business_id, v_txn_id, (v_item.value->>'product_id')::UUID, (v_item.value->>'location_id')::UUID,
      (v_item.value->>'quantity')::NUMERIC, (v_item.value->>'unit_price')::NUMERIC,
      (v_item.value->>'discount_amount')::NUMERIC, (v_item.value->>'tax_amount')::NUMERIC,
      (v_item.value->>'line_total')::NUMERIC, v_item_cost, v_item.value->>'notes', NOW()
    );

    -- 14. Post Movement via trusted internal primitive (authoritative parent execution)
    PERFORM public.fn_post_inventory_movement_internal(
      p_business_id := p_business_id,
      p_branch_id := p_branch_id,
      p_location_id := (v_item.value->>'location_id')::UUID,
      p_product_id := (v_item.value->>'product_id')::UUID,
      p_movement_type := 'SALE',
      p_quantity := -((v_item.value->>'quantity')::NUMERIC),
      p_unit_cost := v_item_cost,
      p_reference_type := 'sale',
      p_reference_id := v_txn_id,
      p_notes := 'Sale ' || v_txn_number,
      p_allow_negative := false,
      p_caller_id := v_caller_id
    );
  END LOOP;

  -- 15. Record Payments & Tender
  IF p_payments IS NOT NULL THEN
    FOR v_pay IN SELECT * FROM jsonb_array_elements(p_payments)
    LOOP
      v_pay_res := public.rpc_record_payment(
        p_business_id := p_business_id,
        p_transaction_id := v_txn_id,
        p_payment_method := v_pay.value->>'payment_method',
        p_amount := (v_pay.value->>'amount')::NUMERIC,
        p_idempotency_key := gen_random_uuid(), -- Derived internal payment key
        p_bank_account_id := CASE WHEN (v_pay.value->>'bank_account_id') IS NOT NULL THEN (v_pay.value->>'bank_account_id')::UUID ELSE NULL END,
        p_register_id := p_register_id,
        p_shift_id := p_shift_id,
        p_reference_number := v_pay.value->>'reference_number',
        p_notes := 'Checkout tender for ' || v_txn_number
      );
      v_recorded_payments := v_recorded_payments || jsonb_build_array(v_pay_res);
    END LOOP;
  END IF;

  -- 16. Verify Final State
  SELECT amount_paid, balance_due, status 
  INTO v_final_amount_paid, v_final_balance_due, v_final_status
  FROM public.sales_transactions
  WHERE id = v_txn_id;

  -- 17. Commit Idempotency Record & Build Authoritative Receipt
  v_result := jsonb_build_object(
    'success', true,
    'transaction_id', v_txn_id,
    'transaction_number', v_txn_number,
    'total_amount', v_total_amount,
    'amount_paid', v_final_amount_paid,
    'balance_due', v_final_balance_due,
    'status', v_final_status,
    'items_count', v_item_count,
    'payments_count', jsonb_array_length(v_recorded_payments)
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_complete_sale(UUID, UUID, UUID, UUID, UUID, JSONB, JSONB, UUID, TEXT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_complete_sale(UUID, UUID, UUID, UUID, UUID, JSONB, JSONB, UUID, TEXT, JSONB) TO authenticated;

-- ------------------------------------------------------------------------------
-- 6. UPGRADE: rpc_record_payment (MANDATORY IDEMPOTENCY)
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_record_payment(
  p_business_id UUID,
  p_transaction_id UUID,
  p_payment_method TEXT,
  p_amount NUMERIC,
  p_idempotency_key UUID,
  p_bank_account_id UUID DEFAULT NULL,
  p_register_id UUID DEFAULT NULL,
  p_shift_id UUID DEFAULT NULL,
  p_reference_number TEXT DEFAULT NULL,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_trans RECORD;
  v_pay_num TEXT;
  v_pay_id UUID;
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_idem_res JSONB;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_record_payment';
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT: Payment amount must be greater than zero';
  END IF;

  -- Request hash
  v_canonical_hash_input := jsonb_build_object(
    'transaction_id', LOWER(p_transaction_id::text),
    'payment_method', LOWER(p_payment_method),
    'amount', to_char(p_amount, 'FM999999999999990.0000'),
    'bank_account_id', LOWER(COALESCE(p_bank_account_id::text, '__NULL__')),
    'register_id', LOWER(COALESCE(p_register_id::text, '__NULL__')),
    'shift_id', LOWER(COALESCE(p_shift_id::text, '__NULL__')),
    'reference_number', TRIM(COALESCE(p_reference_number, ''))
  )::text;

  v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(
    p_business_id,
    p_idempotency_key,
    'record_payment',
    v_request_hash,
    v_caller_id
  );

  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN (v_idem_res->'payload');
  END IF;

  -- Lock Sales Transaction row
  SELECT * INTO v_trans
  FROM public.sales_transactions
  WHERE id = p_transaction_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TRANSACTION_NOT_FOUND: Sales transaction % not found in business %',
      p_transaction_id, p_business_id;
  END IF;

  IF v_trans.status IN ('cancelled', 'voided') THEN
    RAISE EXCEPTION 'INVALID_STATUS: Cannot record payment for % transaction', v_trans.status;
  END IF;

  IF (v_trans.amount_paid + p_amount) > v_trans.total_amount THEN
    RAISE EXCEPTION 'OVERPAYMENT_NOT_ALLOWED: Payment amount % exceeds remaining balance %',
      p_amount, v_trans.balance_due;
  END IF;

  IF p_payment_method = 'bank_transfer' THEN
    IF p_bank_account_id IS NULL THEN
      RAISE EXCEPTION 'BANK_ACCOUNT_REQUIRED: Bank transfer requires bank_account_id';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.bank_accounts
      WHERE id = p_bank_account_id AND business_id = p_business_id AND status = 'active' AND deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'INVALID_BANK_ACCOUNT: Bank account % not found or inactive in business %',
        p_bank_account_id, p_business_id;
    END IF;
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(p_business_id, 'payments:record', v_trans.branch_id)
    OR public.has_permission_in_scope(p_business_id, 'sales:create', v_trans.branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot record payments for branch %',
      v_caller_id, v_trans.branch_id;
  END IF;

  v_pay_num := public.rpc_next_document_number(p_business_id, 'payment', 'PAY');

  INSERT INTO public.payments (
    business_id, branch_id, transaction_id, payment_number,
    payment_method, amount, currency, status,
    bank_account_id, register_id, shift_id, reference_number,
    notes, actor_user_id, occurred_at
  ) VALUES (
    p_business_id, v_trans.branch_id, p_transaction_id, v_pay_num,
    p_payment_method, p_amount, v_trans.currency, 'completed',
    p_bank_account_id, p_register_id, p_shift_id, p_reference_number,
    p_notes, v_caller_id, NOW()
  ) RETURNING id INTO v_pay_id;

  -- Post cash transaction if cash
  IF p_payment_method = 'cash' AND p_register_id IS NOT NULL THEN
    INSERT INTO public.cash_transactions (
      business_id, branch_id, register_id, shift_id,
      direction, amount, currency, source_type, source_id,
      description, actor_user_id, occurred_at
    ) VALUES (
      p_business_id, v_trans.branch_id, p_register_id, p_shift_id,
      'in', p_amount, v_trans.currency, 'cash_sale', v_pay_id,
      'Payment for ' || v_trans.transaction_number, v_caller_id, NOW()
    );
  END IF;

  -- Post bank transaction if bank transfer
  IF p_payment_method = 'bank_transfer' AND p_bank_account_id IS NOT NULL THEN
    INSERT INTO public.bank_transactions (
      business_id, bank_account_id, transaction_type, direction,
      amount, currency, source_type, source_id, reference_number,
      description, actor_user_id, occurred_at
    ) VALUES (
      p_business_id, p_bank_account_id, 'payment_settlement', 'credit',
      p_amount, v_trans.currency, 'payment', v_pay_id, p_reference_number,
      'Payment for ' || v_trans.transaction_number, v_caller_id, NOW()
    );
  END IF;

  v_result := jsonb_build_object(
    'success', true,
    'payment_id', v_pay_id,
    'payment_number', v_pay_num,
    'transaction_id', p_transaction_id,
    'amount', p_amount,
    'payment_method', p_payment_method
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_record_payment(UUID, UUID, TEXT, NUMERIC, UUID, UUID, UUID, UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_record_payment(UUID, UUID, TEXT, NUMERIC, UUID, UUID, UUID, UUID, TEXT, TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- 7. UPGRADE: rpc_pay_expense (MANDATORY IDEMPOTENCY)
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_pay_expense(
  p_business_id UUID,
  p_expense_id UUID,
  p_payment_method TEXT,
  p_idempotency_key UUID,
  p_bank_account_id UUID DEFAULT NULL,
  p_register_id UUID DEFAULT NULL,
  p_shift_id UUID DEFAULT NULL,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_exp RECORD;
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_idem_res JSONB;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_pay_expense';
  END IF;

  v_canonical_hash_input := jsonb_build_object(
    'expense_id', LOWER(p_expense_id::text),
    'payment_method', LOWER(p_payment_method),
    'bank_account_id', LOWER(COALESCE(p_bank_account_id::text, '__NULL__')),
    'register_id', LOWER(COALESCE(p_register_id::text, '__NULL__')),
    'shift_id', LOWER(COALESCE(p_shift_id::text, '__NULL__')),
    'notes', TRIM(COALESCE(p_notes, ''))
  )::text;

  v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(
    p_business_id,
    p_idempotency_key,
    'pay_expense',
    v_request_hash,
    v_caller_id
  );

  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN (v_idem_res->'payload');
  END IF;

  -- Lock Expense row
  SELECT * INTO v_exp
  FROM public.expenses
  WHERE id = p_expense_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EXPENSE_NOT_FOUND: Expense % not found in business %', p_expense_id, p_business_id;
  END IF;

  IF v_exp.status = 'paid' THEN
    RAISE EXCEPTION 'EXPENSE_ALREADY_PAID: Expense % is already paid', p_expense_id;
  END IF;

  IF v_exp.status <> 'approved' THEN
    RAISE EXCEPTION 'INVALID_STATUS: Expense % has status %; only approved expenses can be paid',
      p_expense_id, v_exp.status;
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'expenses:pay')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot pay expenses for business %',
      v_caller_id, p_business_id;
  END IF;

  IF p_payment_method = 'bank_transfer' THEN
    IF p_bank_account_id IS NULL THEN
      RAISE EXCEPTION 'BANK_ACCOUNT_REQUIRED: Bank transfer expenses require bank_account_id';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.bank_accounts
      WHERE id = p_bank_account_id AND business_id = p_business_id AND status = 'active' AND deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'INVALID_BANK_ACCOUNT: Bank account % not found or inactive in business %',
        p_bank_account_id, p_business_id;
    END IF;
  END IF;

  UPDATE public.expenses
  SET
    status = 'paid',
    payment_method = p_payment_method,
    bank_account_id = p_bank_account_id,
    register_id = p_register_id,
    shift_id = p_shift_id,
    paid_by = v_caller_id,
    paid_at = NOW(),
    updated_at = NOW()
  WHERE id = p_expense_id;

  IF p_payment_method = 'cash' AND v_exp.branch_id IS NOT NULL THEN
    INSERT INTO public.cash_transactions (
      business_id, branch_id, register_id, shift_id, direction,
      amount, currency, source_type, source_id,
      description, actor_user_id, occurred_at
    ) VALUES (
      p_business_id, v_exp.branch_id, p_register_id, p_shift_id, 'out',
      v_exp.amount, v_exp.currency, 'expense', p_expense_id,
      'Disbursement for ' || v_exp.expense_number || ': ' || v_exp.description,
      v_caller_id, NOW()
    );
  END IF;

  IF p_payment_method = 'bank_transfer' AND p_bank_account_id IS NOT NULL THEN
    INSERT INTO public.bank_transactions (
      business_id, bank_account_id, transaction_type, direction,
      amount, currency, source_type, source_id,
      description, actor_user_id, occurred_at
    ) VALUES (
      p_business_id, p_bank_account_id, 'expense_payment', 'debit',
      v_exp.amount, v_exp.currency, 'expense', p_expense_id,
      'Bank disbursement for ' || v_exp.expense_number || ': ' || v_exp.description,
      v_caller_id, NOW()
    );
  END IF;

  v_result := jsonb_build_object(
    'success', true,
    'expense_id', p_expense_id,
    'expense_number', v_exp.expense_number,
    'status', 'paid',
    'amount', v_exp.amount,
    'currency', v_exp.currency,
    'payment_method', p_payment_method
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_pay_expense(UUID, UUID, TEXT, UUID, UUID, UUID, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_pay_expense(UUID, UUID, TEXT, UUID, UUID, UUID, UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- 8. UPGRADE: rpc_open_register_shift (MANDATORY IDEMPOTENCY)
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_open_register_shift(
  p_business_id UUID,
  p_branch_id UUID,
  p_register_id UUID,
  p_opening_float NUMERIC,
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
  v_currency VARCHAR(3);
  v_shift_num TEXT;
  v_shift_id UUID;
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_idem_res JSONB;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_open_register_shift';
  END IF;

  v_canonical_hash_input := jsonb_build_object(
    'branch_id', LOWER(p_branch_id::text),
    'register_id', LOWER(p_register_id::text),
    'opening_float', to_char(COALESCE(p_opening_float, 0.0000), 'FM999999999999990.0000'),
    'notes', TRIM(COALESCE(p_notes, ''))
  )::text;

  v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(
    p_business_id,
    p_idempotency_key,
    'open_register_shift',
    v_request_hash,
    v_caller_id
  );

  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN (v_idem_res->'payload');
  END IF;

  SELECT currency INTO v_currency
  FROM public.businesses
  WHERE id = p_business_id AND status = 'active' AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'BUSINESS_NOT_FOUND: Active business % not found', p_business_id;
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(p_business_id, 'registers:manage', p_branch_id)
    OR public.has_permission_in_scope(p_business_id, 'cash:manage', p_branch_id)
    OR public.has_permission_in_scope(p_business_id, 'sales:create', p_branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot open shift for register % in branch %',
      v_caller_id, p_register_id, p_branch_id;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.register_shifts
    WHERE business_id = p_business_id AND register_id = p_register_id AND status = 'open'
  ) THEN
    RAISE EXCEPTION 'SHIFT_ALREADY_OPEN: Register % already has an open active shift', p_register_id;
  END IF;

  v_shift_num := public.rpc_next_document_number(p_business_id, 'shift', 'SH');

  INSERT INTO public.register_shifts (
    business_id, branch_id, register_id, shift_number,
    opened_by, opened_at, opening_float, status, notes
  ) VALUES (
    p_business_id, p_branch_id, p_register_id, v_shift_num,
    v_caller_id, NOW(), COALESCE(p_opening_float, 0.0000), 'open', p_notes
  ) RETURNING id INTO v_shift_id;

  IF p_opening_float > 0 THEN
    INSERT INTO public.cash_transactions (
      business_id, branch_id, register_id, shift_id,
      direction, amount, currency, source_type, source_id,
      description, actor_user_id, occurred_at
    ) VALUES (
      p_business_id, p_branch_id, p_register_id, v_shift_id,
      'in', p_opening_float, v_currency, 'opening_float', v_shift_id,
      'Opening drawer float for shift ' || v_shift_num, v_caller_id, NOW()
    );
  END IF;

  v_result := jsonb_build_object(
    'success', true,
    'shift_id', v_shift_id,
    'shift_number', v_shift_num,
    'opening_float', p_opening_float,
    'status', 'open'
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_open_register_shift(UUID, UUID, UUID, NUMERIC, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_open_register_shift(UUID, UUID, UUID, NUMERIC, UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- 9. UPGRADE: rpc_close_register_shift (MANDATORY IDEMPOTENCY)
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_close_register_shift(
  p_business_id UUID,
  p_shift_id UUID,
  p_counted_cash NUMERIC,
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
  v_shift RECORD;
  v_cash_in NUMERIC(15, 4);
  v_cash_out NUMERIC(15, 4);
  v_expected_cash NUMERIC(15, 4);
  v_variance NUMERIC(15, 4);
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_idem_res JSONB;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_close_register_shift';
  END IF;

  v_canonical_hash_input := jsonb_build_object(
    'shift_id', LOWER(p_shift_id::text),
    'counted_cash', to_char(p_counted_cash, 'FM999999999999990.0000'),
    'notes', TRIM(COALESCE(p_notes, ''))
  )::text;

  v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(
    p_business_id,
    p_idempotency_key,
    'close_register_shift',
    v_request_hash,
    v_caller_id
  );

  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN (v_idem_res->'payload');
  END IF;

  SELECT * INTO v_shift
  FROM public.register_shifts
  WHERE id = p_shift_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SHIFT_NOT_FOUND: Shift % not found in business %', p_shift_id, p_business_id;
  END IF;

  IF v_shift.status <> 'open' THEN
    RAISE EXCEPTION 'SHIFT_ALREADY_CLOSED: Shift % is already % and cannot be closed', p_shift_id, v_shift.status;
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR v_shift.opened_by = v_caller_id
    OR public.has_permission_in_scope(p_business_id, 'registers:manage', v_shift.branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot close shift %', v_caller_id, p_shift_id;
  END IF;

  SELECT COALESCE(SUM(amount), 0.0000) INTO v_cash_in
  FROM public.cash_transactions
  WHERE shift_id = p_shift_id AND business_id = p_business_id AND direction = 'in';

  SELECT COALESCE(SUM(amount), 0.0000) INTO v_cash_out
  FROM public.cash_transactions
  WHERE shift_id = p_shift_id AND business_id = p_business_id AND direction = 'out';

  -- Exactly-once opening float: rpc_open_register_shift creates an 'in' cash_transaction for opening float,
  -- so v_cash_in already includes opening_float.
  v_expected_cash := v_cash_in - v_cash_out;
  v_variance := p_counted_cash - v_expected_cash;

  UPDATE public.register_shifts
  SET
    status = 'closed',
    closed_by = v_caller_id,
    closed_at = NOW(),
    counted_cash = p_counted_cash,
    expected_cash = v_expected_cash,
    variance = v_variance,
    notes = CASE WHEN p_notes IS NOT NULL THEN COALESCE(notes || E'\n' || p_notes, p_notes) ELSE notes END
  WHERE id = p_shift_id;

  v_result := jsonb_build_object(
    'success', true,
    'shift_id', p_shift_id,
    'shift_number', v_shift.shift_number,
    'status', 'closed',
    'counted_cash', p_counted_cash,
    'expected_cash', v_expected_cash,
    'variance', v_variance,
    'closed_at', NOW()
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_close_register_shift(UUID, UUID, NUMERIC, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_close_register_shift(UUID, UUID, NUMERIC, UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- 10. UPGRADE: rpc_post_bank_transaction (MANDATORY IDEMPOTENCY)
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_post_bank_transaction(
  p_business_id UUID,
  p_bank_account_id UUID,
  p_transaction_type TEXT,
  p_direction TEXT,
  p_amount NUMERIC,
  p_currency TEXT,
  p_source_type TEXT,
  p_idempotency_key UUID,
  p_source_id UUID DEFAULT NULL,
  p_reference_number TEXT DEFAULT NULL,
  p_description TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_account_biz UUID;
  v_tx_id UUID;
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_idem_res JSONB;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_post_bank_transaction';
  END IF;

  v_canonical_hash_input := jsonb_build_object(
    'bank_account_id', LOWER(p_bank_account_id::text),
    'transaction_type', LOWER(p_transaction_type),
    'direction', LOWER(p_direction),
    'amount', to_char(p_amount, 'FM999999999999990.0000'),
    'currency', UPPER(TRIM(p_currency)),
    'source_type', LOWER(p_source_type),
    'source_id', LOWER(COALESCE(p_source_id::text, '__NULL__')),
    'reference_number', TRIM(COALESCE(p_reference_number, ''))
  )::text;

  v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(
    p_business_id,
    p_idempotency_key,
    'post_bank_transaction',
    v_request_hash,
    v_caller_id
  );

  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN (v_idem_res->'payload');
  END IF;

  SELECT business_id INTO v_account_biz
  FROM public.bank_accounts
  WHERE id = p_bank_account_id AND status = 'active' AND deleted_at IS NULL;

  IF NOT FOUND OR v_account_biz <> p_business_id THEN
    RAISE EXCEPTION 'BANK_ACCOUNT_INVALID: Bank account % not found or inactive', p_bank_account_id;
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'bank:manage')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot execute bank transactions', v_caller_id;
  END IF;

  INSERT INTO public.bank_transactions (
    business_id, bank_account_id, transaction_type, direction,
    amount, currency, source_type, source_id, reference_number,
    description, actor_user_id, occurred_at
  ) VALUES (
    p_business_id, p_bank_account_id, p_transaction_type, p_direction,
    p_amount, p_currency, p_source_type, p_source_id, p_reference_number,
    p_description, v_caller_id, NOW()
  ) RETURNING id INTO v_tx_id;

  v_result := jsonb_build_object(
    'success', true,
    'bank_transaction_id', v_tx_id,
    'bank_account_id', p_bank_account_id,
    'amount', p_amount,
    'direction', p_direction
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_post_bank_transaction(UUID, UUID, TEXT, TEXT, NUMERIC, TEXT, TEXT, UUID, UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_post_bank_transaction(UUID, UUID, TEXT, TEXT, NUMERIC, TEXT, TEXT, UUID, UUID, TEXT, TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- 11. UPGRADE: rpc_post_cash_transaction (MANDATORY IDEMPOTENCY)
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_post_cash_transaction(
  p_business_id UUID,
  p_branch_id UUID,
  p_register_id UUID,
  p_shift_id UUID,
  p_direction TEXT,
  p_amount NUMERIC,
  p_currency TEXT,
  p_source_type TEXT,
  p_idempotency_key UUID,
  p_source_id UUID DEFAULT NULL,
  p_description TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_tx_id UUID;
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_idem_res JSONB;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_post_cash_transaction';
  END IF;

  v_canonical_hash_input := jsonb_build_object(
    'branch_id', LOWER(p_branch_id::text),
    'register_id', LOWER(p_register_id::text),
    'shift_id', LOWER(p_shift_id::text),
    'direction', LOWER(p_direction),
    'amount', to_char(p_amount, 'FM999999999999990.0000'),
    'currency', UPPER(TRIM(p_currency)),
    'source_type', LOWER(p_source_type),
    'source_id', LOWER(COALESCE(p_source_id::text, '__NULL__'))
  )::text;

  v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(
    p_business_id,
    p_idempotency_key,
    'post_cash_transaction',
    v_request_hash,
    v_caller_id
  );

  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN (v_idem_res->'payload');
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(p_business_id, 'cash:manage', p_branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot execute cash adjustments for branch %',
      v_caller_id, p_branch_id;
  END IF;

  INSERT INTO public.cash_transactions (
    business_id, branch_id, register_id, shift_id,
    direction, amount, currency, source_type, source_id,
    description, actor_user_id, occurred_at
  ) VALUES (
    p_business_id, p_branch_id, p_register_id, p_shift_id,
    p_direction, p_amount, p_currency, p_source_type, p_source_id,
    p_description, v_caller_id, NOW()
  ) RETURNING id INTO v_tx_id;

  v_result := jsonb_build_object(
    'success', true,
    'cash_transaction_id', v_tx_id,
    'amount', p_amount,
    'direction', p_direction
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_post_cash_transaction(UUID, UUID, UUID, UUID, TEXT, NUMERIC, TEXT, TEXT, UUID, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_post_cash_transaction(UUID, UUID, UUID, UUID, TEXT, NUMERIC, TEXT, TEXT, UUID, UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- 12. UPGRADE: AUTHORITATIVE PARENT RPCS CALLING TRUSTED INTERNAL INVENTORY PRIMITIVE
-- ------------------------------------------------------------------------------

-- 12A. rpc_approve_inventory_adjustment
CREATE OR REPLACE FUNCTION public.rpc_approve_inventory_adjustment(
  p_business_id UUID,
  p_adjustment_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_adj RECORD;
  v_item RECORD;
  v_items_processed INT := 0;
  v_res JSONB;
BEGIN
  -- 1. Authenticate caller
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: Authentication required to approve adjustments.';
  END IF;

  -- 2. Lock adjustment header
  SELECT * INTO v_adj
  FROM public.inventory_adjustments
  WHERE id = p_adjustment_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ADJUSTMENT_NOT_FOUND: Adjustment % does not exist in business %', p_adjustment_id, p_business_id;
  END IF;

  -- 3. Authorize caller via Scoped Permission Architecture
  IF NOT (
    public.is_business_owner(p_business_id) 
    OR public.has_permission_in_scope(p_business_id, 'inventory:adjust', v_adj.branch_id)
    OR public.has_permission_in_scope(p_business_id, 'catalog:manage', v_adj.branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot approve adjustments for branch % in business %', 
      v_caller_id, v_adj.branch_id, p_business_id;
  END IF;

  -- 4. Idempotency Check: Already approved cannot be approved twice or post duplicate movements
  IF v_adj.status = 'approved' THEN
    RETURN jsonb_build_object(
      'success', true,
      'adjustment_id', p_adjustment_id,
      'items_processed', 0,
      'status', 'already_approved'
    );
  END IF;

  IF v_adj.status <> 'draft' AND v_adj.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'INVALID_STATUS: Adjustment % is in status % and cannot be approved', p_adjustment_id, v_adj.status;
  END IF;

  -- 5. Process line items atomically via trusted internal primitive
  FOR v_item IN 
    SELECT * FROM public.inventory_adjustment_items
    WHERE adjustment_id = p_adjustment_id AND business_id = p_business_id
  LOOP
    IF v_item.variance_quantity <> 0 THEN
      v_res := public.fn_post_inventory_movement_internal(
        p_business_id := p_business_id,
        p_branch_id := v_adj.branch_id,
        p_location_id := v_adj.location_id,
        p_product_id := v_item.product_id,
        p_movement_type := CASE WHEN v_item.variance_quantity > 0 THEN 'ADJUSTMENT_IN' ELSE 'ADJUSTMENT_OUT' END,
        p_quantity := v_item.variance_quantity,
        p_unit_cost := v_item.unit_cost,
        p_reference_type := 'adjustment',
        p_reference_id := p_adjustment_id,
        p_notes := COALESCE(v_item.reason, v_adj.reason),
        p_allow_negative := false,
        p_caller_id := v_caller_id
      );
      v_items_processed := v_items_processed + 1;
    END IF;
  END LOOP;

  -- 6. Finalize adjustment status
  UPDATE public.inventory_adjustments
  SET 
    status = 'approved',
    approved_by = v_caller_id,
    approved_at = NOW(),
    updated_at = NOW()
  WHERE id = p_adjustment_id;

  RETURN jsonb_build_object(
    'success', true,
    'adjustment_id', p_adjustment_id,
    'items_processed', v_items_processed,
    'status', 'approved'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_approve_inventory_adjustment(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_approve_inventory_adjustment(UUID, UUID) TO authenticated;

-- 12B. rpc_dispatch_inventory_transfer
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

    -- Decrement Source Stock & Append TRANSFER_OUT to Append-Only Ledger via trusted internal primitive
    PERFORM public.fn_post_inventory_movement_internal(
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
      p_allow_negative := FALSE,
      p_caller_id := v_caller_id
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

REVOKE ALL ON FUNCTION public.rpc_dispatch_inventory_transfer(UUID, UUID, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_dispatch_inventory_transfer(UUID, UUID, UUID, TEXT) TO authenticated;

-- 12C. rpc_receive_inventory_transfer
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
      RAISE EXCEPTION 'TRANSFER_ALREADY_RECEIVED: Transfer % is already received under receive key %',
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

    -- Increment Destination Stock & Append TRANSFER_IN to Append-Only Ledger via trusted internal primitive
    PERFORM public.fn_post_inventory_movement_internal(
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
      p_allow_negative := FALSE,
      p_caller_id := v_caller_id
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

REVOKE ALL ON FUNCTION public.rpc_receive_inventory_transfer(UUID, UUID, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_receive_inventory_transfer(UUID, UUID, UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- 13. UPGRADE: rpc_post_inventory_movement (MANDATORY IDEMPOTENCY KEY, NO BYPASS)
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_post_inventory_movement(
  p_business_id UUID,
  p_branch_id UUID,
  p_location_id UUID,
  p_product_id UUID,
  p_movement_type TEXT,
  p_quantity NUMERIC,
  p_idempotency_key UUID,
  p_unit_cost NUMERIC DEFAULT 0.0000,
  p_reference_type TEXT DEFAULT 'adjustment',
  p_reference_id UUID DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_allow_negative BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_perm_required TEXT;
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_idem_res JSONB;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: Authentication required to post inventory movements.';
  END IF;

  -- STRICT MANDATORY KEY: Zero NULL bypass. Fake reference_type/id CANNOT bypass key requirement.
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_post_inventory_movement';
  END IF;

  v_canonical_hash_input := jsonb_build_object(
    'branch_id', LOWER(p_branch_id::text),
    'location_id', LOWER(p_location_id::text),
    'product_id', LOWER(p_product_id::text),
    'movement_type', UPPER(p_movement_type),
    'quantity', to_char(p_quantity, 'FM999999999999990.0000'),
    'unit_cost', to_char(COALESCE(p_unit_cost, 0.0000), 'FM999999999999990.0000')
  )::text;

  v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(
    p_business_id,
    p_idempotency_key,
    'post_inventory_movement',
    v_request_hash,
    v_caller_id
  );

  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN (v_idem_res->'payload');
  END IF;

  -- Permission Evaluation
  IF p_movement_type IN ('INITIAL_STOCK', 'PURCHASE_RECEIPT') THEN
    v_perm_required := 'catalog:manage';
  ELSIF p_movement_type IN ('ADJUSTMENT_IN', 'ADJUSTMENT_OUT') THEN
    v_perm_required := 'inventory:adjust';
  ELSIF p_movement_type IN ('TRANSFER_IN', 'TRANSFER_OUT') THEN
    v_perm_required := 'inventory:transfer';
  ELSIF p_movement_type IN ('SALE', 'RETURN') THEN
    v_perm_required := 'sales:create';
  ELSE
    v_perm_required := 'inventory:adjust';
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id) 
    OR public.has_permission_in_scope(p_business_id, v_perm_required, p_branch_id)
    OR public.has_permission_in_scope(p_business_id, 'inventory:adjust', p_branch_id)
    OR public.has_permission_in_scope(p_business_id, 'catalog:manage', p_branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: User % lacks % permission for branch % in business %', 
      v_caller_id, v_perm_required, p_branch_id, p_business_id;
  END IF;

  -- Execute Trusted Internal Primitive
  v_result := public.fn_post_inventory_movement_internal(
    p_business_id := p_business_id,
    p_branch_id := p_branch_id,
    p_location_id := p_location_id,
    p_product_id := p_product_id,
    p_movement_type := p_movement_type,
    p_quantity := p_quantity,
    p_unit_cost := COALESCE(p_unit_cost, 0.0000),
    p_reference_type := p_reference_type,
    p_reference_id := p_reference_id,
    p_notes := p_notes,
    p_allow_negative := p_allow_negative,
    p_caller_id := v_caller_id
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_post_inventory_movement(UUID, UUID, UUID, UUID, TEXT, NUMERIC, UUID, NUMERIC, TEXT, UUID, TEXT, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_post_inventory_movement(UUID, UUID, UUID, UUID, TEXT, NUMERIC, UUID, NUMERIC, TEXT, UUID, TEXT, BOOLEAN) TO authenticated;
