-- =============================================================================
-- MIGRATION 003: OPERATIONAL DATA FOUNDATION — CATALOG & INVENTORY
-- =============================================================================
-- Enterprise multi-tenant database migration establishing the authoritative
-- catalog, product taxonomy, pricing, physical inventory locations, immutable
-- inventory movements ledger, and concurrency-controlled inventory balance projections.
--
-- Prerequisite baselines (IMMUTABLE):
--   - Migration 001: 001_foundation_identity_and_tenancy.sql
--   - Migration 002: 002_roles_workforce_capital.sql
--
-- Safety Guarantees:
--   - Strictly tenant-isolated via business_id composite foreign keys.
--   - Append-only immutable inventory ledger (inventory_movements).
--   - Real-time stock concurrency projection (inventory_balances) with pessimistic row locking.
--   - Branch-scope RBAC enforcement (has_permission_in_scope) for localized stock control.
--   - Weighted-average cost calculation (WAC) enforced in database transactions.
--   - Direct client writes completely blocked via both Table Grants & Row Level Security.
--   - No redefinition of Migration 001's trigger_set_updated_at; reuses existing function.
--   - Fully idempotent and rerun-safe.
-- =============================================================================

-- =============================================================================
-- 1. EXTEND RBAC SYSTEM PERMISSIONS & ROLE MAPPINGS
-- =============================================================================

-- 1.1 Ensure all catalog and inventory permission codes are registered
INSERT INTO public.permissions (key, module, description) VALUES
  -- Catalog Management
  ('catalog:view', 'catalog', 'View product catalog, pricing tiers, and categories'),
  ('catalog:create', 'catalog', 'Create new products, categories, and pricing schedules'),
  ('catalog:update', 'catalog', 'Update product attributes, prices, and suppliers'),
  ('catalog:delete', 'catalog', 'Archive or soft-delete products and categories'),
  ('catalog:manage', 'catalog', 'Full administrative control over product catalog and suppliers'),

  -- Inventory & Stock Logistics
  ('inventory:view', 'inventory', 'View real-time stock balances across locations and branches'),
  ('inventory:adjust', 'inventory', 'Initiate, count, or approve physical stock adjustments'),
  ('inventory:transfer', 'inventory', 'Initiate or receive inter-branch inventory transfers'),
  ('inventory:audit', 'inventory', 'Conduct formal stock audit cycles and cycle count reconciliations')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module,
  description = EXCLUDED.description;

-- 1.2 Map catalog and inventory permissions to standard system roles
DO $$
DECLARE
  v_role_id UUID;
BEGIN
  -- PrimaryOwner receives ALL newly added permissions
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'PrimaryOwner' AND is_system = true;
  IF v_role_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id FROM public.permissions p
    WHERE p.key IN (
      'catalog:view', 'catalog:create', 'catalog:update', 'catalog:delete', 'catalog:manage',
      'inventory:view', 'inventory:adjust', 'inventory:transfer', 'inventory:audit'
    )
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END IF;

  -- SuperAdmin
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'SuperAdmin' AND is_system = true;
  IF v_role_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id FROM public.permissions p
    WHERE p.key IN (
      'catalog:view', 'catalog:create', 'catalog:update', 'catalog:delete', 'catalog:manage',
      'inventory:view', 'inventory:adjust', 'inventory:transfer', 'inventory:audit'
    )
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END IF;

  -- GeneralManager
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'GeneralManager' AND is_system = true;
  IF v_role_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id FROM public.permissions p
    WHERE p.key IN (
      'catalog:view', 'catalog:create', 'catalog:update', 'catalog:delete', 'catalog:manage',
      'inventory:view', 'inventory:adjust', 'inventory:transfer', 'inventory:audit'
    )
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END IF;

  -- BranchManager
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'BranchManager' AND is_system = true;
  IF v_role_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id FROM public.permissions p
    WHERE p.key IN (
      'catalog:view', 'catalog:create', 'catalog:update',
      'inventory:view', 'inventory:adjust', 'inventory:transfer'
    )
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END IF;

  -- StockManager
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'StockManager' AND is_system = true;
  IF v_role_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id FROM public.permissions p
    WHERE p.key IN (
      'catalog:view', 'catalog:create', 'catalog:update',
      'inventory:view', 'inventory:adjust', 'inventory:transfer', 'inventory:audit'
    )
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END IF;

  -- StockStaff
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'StockStaff' AND is_system = true;
  IF v_role_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id FROM public.permissions p
    WHERE p.key IN (
      'catalog:view',
      'inventory:view', 'inventory:adjust'
    )
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END IF;

  -- Salesperson & Cashier (View-only catalog and inventory availability)
  FOR v_role_id IN SELECT id FROM public.roles WHERE code IN ('Salesperson', 'Cashier', 'Viewer') AND is_system = true
  LOOP
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id FROM public.permissions p
    WHERE p.key IN ('catalog:view', 'inventory:view')
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END LOOP;
END $$;

-- =============================================================================
-- 2. CATALOG DOMAIN TABLES (TABLES 1 - 4)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2.1 Table 1: public.product_categories
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  parent_id UUID,
  name TEXT NOT NULL,
  slug TEXT,
  description TEXT,
  display_order INT NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  updated_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Composite unique key to support tenant-safe composite foreign keys
  CONSTRAINT uq_product_categories_business_id_id UNIQUE (business_id, id),
  -- Self-referential tenant-safe parent hierarchy
  CONSTRAINT fk_product_categories_parent 
    FOREIGN KEY (business_id, parent_id) 
    REFERENCES public.product_categories(business_id, id) 
    ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_product_categories_biz ON public.product_categories (business_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_product_categories_parent ON public.product_categories (business_id, parent_id);

-- -----------------------------------------------------------------------------
-- 2.2 Table 2: public.suppliers
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.suppliers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  contact_person TEXT,
  email TEXT,
  phone TEXT,
  address JSONB DEFAULT '{}'::jsonb,
  tax_id TEXT,
  payment_terms TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  updated_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Composite unique key for tenant-safe foreign references
  CONSTRAINT uq_suppliers_business_id_id UNIQUE (business_id, id)
);

CREATE INDEX IF NOT EXISTS idx_suppliers_biz ON public.suppliers (business_id) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 2.3 Table 3: public.products (Catalog Identity Only — NO Authoritative Stock)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  category_id UUID,
  primary_supplier_id UUID,
  name TEXT NOT NULL,
  sku TEXT,
  barcode TEXT,
  description TEXT,
  product_type TEXT NOT NULL DEFAULT 'standard' CHECK (product_type IN ('standard', 'service')),
  unit_of_measure TEXT NOT NULL DEFAULT 'unit',
  cost_price NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (cost_price >= 0),
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  updated_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Composite unique key to support tenant-safe composite foreign keys
  CONSTRAINT uq_products_business_id_id UNIQUE (business_id, id),

  -- Tenant-safe composite foreign keys
  CONSTRAINT fk_products_category 
    FOREIGN KEY (business_id, category_id) 
    REFERENCES public.product_categories(business_id, id) 
    ON DELETE SET NULL,

  CONSTRAINT fk_products_supplier 
    FOREIGN KEY (business_id, primary_supplier_id) 
    REFERENCES public.suppliers(business_id, id) 
    ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_products_biz ON public.products (business_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_products_category ON public.products (business_id, category_id);

-- SKU uniqueness per active business (allows SKU reuse if old product was soft-deleted)
CREATE UNIQUE INDEX IF NOT EXISTS uq_products_biz_sku 
ON public.products (business_id, sku) 
WHERE deleted_at IS NULL AND sku IS NOT NULL AND sku <> '';

-- Barcode index per active business
CREATE INDEX IF NOT EXISTS idx_products_biz_barcode 
ON public.products (business_id, barcode) 
WHERE deleted_at IS NULL AND barcode IS NOT NULL AND barcode <> '';

-- -----------------------------------------------------------------------------
-- 2.4 Table 4: public.product_prices (Multi-Tier Currency-Aware Pricing)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_prices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  product_id UUID NOT NULL,
  price_tier TEXT NOT NULL DEFAULT 'Retail',
  price NUMERIC(15, 4) NOT NULL CHECK (price >= 0),
  currency TEXT NOT NULL DEFAULT 'HTG',
  min_quantity NUMERIC(15, 4) NOT NULL DEFAULT 1.0000 CHECK (min_quantity > 0),
  valid_from TIMESTAMPTZ,
  valid_to TIMESTAMPTZ,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  updated_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,

  -- Composite foreign key enforcing tenant match
  CONSTRAINT fk_product_prices_product 
    FOREIGN KEY (business_id, product_id) 
    REFERENCES public.products(business_id, id) 
    ON DELETE CASCADE,

  -- Composite unique key
  CONSTRAINT uq_product_prices_business_id_id UNIQUE (business_id, id),
  CONSTRAINT uq_product_prices_tier UNIQUE (business_id, product_id, price_tier, currency)
);

CREATE INDEX IF NOT EXISTS idx_product_prices_product ON public.product_prices (business_id, product_id) WHERE deleted_at IS NULL;

-- =============================================================================
-- 3. INVENTORY DOMAIN TABLES (TABLES 5 - 9)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3.1 Table 5: public.inventory_locations (Physical Stock Locations Scoped to Branches)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  branch_id UUID NOT NULL,
  name TEXT NOT NULL,
  code TEXT,
  location_type TEXT NOT NULL DEFAULT 'sales_floor' 
    CHECK (location_type IN ('sales_floor', 'stockroom', 'warehouse', 'receiving', 'quarantine')),
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  updated_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Composite unique key for tenant-safe child references
  CONSTRAINT uq_inventory_locations_business_id_id UNIQUE (business_id, id),

  -- Explicit tenant-safe foreign key linking location strictly to a branch of the SAME business
  CONSTRAINT fk_inventory_locations_branch 
    FOREIGN KEY (business_id, branch_id) 
    REFERENCES public.branches(business_id, id) 
    ON DELETE RESTRICT,

  CONSTRAINT uq_inventory_locations_branch_code UNIQUE (business_id, branch_id, code)
);

CREATE INDEX IF NOT EXISTS idx_inventory_locations_biz ON public.inventory_locations (business_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_inventory_locations_branch ON public.inventory_locations (business_id, branch_id);

-- -----------------------------------------------------------------------------
-- 3.2 Table 6: public.inventory_balances (Current Stock State & Concurrency Anchor)
-- -----------------------------------------------------------------------------
-- Maintained exclusively via database transactions and RPCs.
-- Direct client INSERT/UPDATE/DELETE is strictly forbidden via Table Privileges and RLS.
CREATE TABLE IF NOT EXISTS public.inventory_balances (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  branch_id UUID NOT NULL,
  location_id UUID NOT NULL,
  product_id UUID NOT NULL,
  on_hand_quantity NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
  reserved_quantity NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (reserved_quantity >= 0),
  available_quantity NUMERIC(15, 4) GENERATED ALWAYS AS (on_hand_quantity - reserved_quantity) STORED,
  average_unit_cost NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (average_unit_cost >= 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Quantity sanity constraints:
  -- 1. Unauthorized negative physical stock prohibited at database level
  CONSTRAINT chk_inventory_balances_on_hand CHECK (on_hand_quantity >= 0),
  -- 2. Reserved stock cannot exceed on-hand stock (guaranteeing available_quantity >= 0)
  CONSTRAINT chk_inventory_balances_available CHECK (on_hand_quantity >= reserved_quantity),

  -- Strict unique key: one balance record per business, location, and product
  CONSTRAINT uq_inventory_balances_product_loc UNIQUE (business_id, location_id, product_id),

  -- Composite unique key for tenant safety
  CONSTRAINT uq_inventory_balances_business_id_id UNIQUE (business_id, id),

  -- Composite foreign keys
  CONSTRAINT fk_inventory_balances_branch 
    FOREIGN KEY (business_id, branch_id) 
    REFERENCES public.branches(business_id, id) 
    ON DELETE CASCADE,

  CONSTRAINT fk_inventory_balances_location 
    FOREIGN KEY (business_id, location_id) 
    REFERENCES public.inventory_locations(business_id, id) 
    ON DELETE CASCADE,

  CONSTRAINT fk_inventory_balances_product 
    FOREIGN KEY (business_id, product_id) 
    REFERENCES public.products(business_id, id) 
    ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_inventory_balances_biz ON public.inventory_balances (business_id);
CREATE INDEX IF NOT EXISTS idx_inventory_balances_product ON public.inventory_balances (business_id, product_id);
CREATE INDEX IF NOT EXISTS idx_inventory_balances_location ON public.inventory_balances (business_id, location_id);

-- -----------------------------------------------------------------------------
-- 3.3 Table 7: public.inventory_movements (Authoritative Immutable Stock Ledger)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  branch_id UUID NOT NULL,
  location_id UUID NOT NULL,
  product_id UUID NOT NULL,
  movement_type TEXT NOT NULL CHECK (
    movement_type IN (
      'INITIAL_STOCK',
      'PURCHASE_RECEIPT',
      'SALE',
      'ADJUSTMENT_IN',
      'ADJUSTMENT_OUT',
      'TRANSFER_IN',
      'TRANSFER_OUT',
      'RETURN'
    )
  ),
  quantity NUMERIC(15, 4) NOT NULL CHECK (quantity <> 0),
  unit_cost NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (unit_cost >= 0),
  reference_type TEXT NOT NULL CHECK (
    reference_type IN ('initial', 'purchase_order', 'sale', 'adjustment', 'transfer', 'return', 'manual')
  ),
  reference_id UUID,
  notes TEXT,
  actor_id UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Strict sign semantics per movement type (No ambiguous signs)
  CONSTRAINT chk_inventory_movements_sign CHECK (
    (movement_type IN ('INITIAL_STOCK', 'PURCHASE_RECEIPT', 'ADJUSTMENT_IN', 'TRANSFER_IN', 'RETURN') AND quantity > 0)
    OR
    (movement_type IN ('SALE', 'ADJUSTMENT_OUT', 'TRANSFER_OUT') AND quantity < 0)
  ),

  -- Composite unique key
  CONSTRAINT uq_inventory_movements_business_id_id UNIQUE (business_id, id),

  -- Composite tenant foreign keys
  CONSTRAINT fk_inventory_movements_branch 
    FOREIGN KEY (business_id, branch_id) 
    REFERENCES public.branches(business_id, id) 
    ON DELETE RESTRICT,

  CONSTRAINT fk_inventory_movements_location 
    FOREIGN KEY (business_id, location_id) 
    REFERENCES public.inventory_locations(business_id, id) 
    ON DELETE RESTRICT,

  CONSTRAINT fk_inventory_movements_product 
    FOREIGN KEY (business_id, product_id) 
    REFERENCES public.products(business_id, id) 
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_inventory_movements_biz ON public.inventory_movements (business_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_inventory_movements_product ON public.inventory_movements (business_id, product_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_inventory_movements_location ON public.inventory_movements (business_id, location_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_inventory_movements_ref ON public.inventory_movements (business_id, reference_type, reference_id);

-- -----------------------------------------------------------------------------
-- 3.4 Table 8: public.inventory_adjustments (Stock Audit Document Header)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_adjustments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  branch_id UUID NOT NULL,
  location_id UUID NOT NULL,
  adjustment_number TEXT NOT NULL,
  reason TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'pending_approval', 'approved', 'rejected', 'cancelled')),
  approved_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  approved_at TIMESTAMPTZ,
  notes TEXT,
  created_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  updated_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  CONSTRAINT uq_inventory_adjustments_num UNIQUE (business_id, adjustment_number),
  CONSTRAINT uq_inventory_adjustments_business_id_id UNIQUE (business_id, id),

  CONSTRAINT fk_inventory_adjustments_branch 
    FOREIGN KEY (business_id, branch_id) 
    REFERENCES public.branches(business_id, id) 
    ON DELETE RESTRICT,

  CONSTRAINT fk_inventory_adjustments_location 
    FOREIGN KEY (business_id, location_id) 
    REFERENCES public.inventory_locations(business_id, id) 
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_inventory_adjustments_biz ON public.inventory_adjustments (business_id) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 3.5 Table 9: public.inventory_adjustment_items (Stock Audit Line Items)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_adjustment_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  adjustment_id UUID NOT NULL,
  product_id UUID NOT NULL,
  system_quantity NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
  counted_quantity NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
  variance_quantity NUMERIC(15, 4) GENERATED ALWAYS AS (counted_quantity - system_quantity) STORED,
  unit_cost NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (unit_cost >= 0),
  reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_inventory_adj_items_product UNIQUE (business_id, adjustment_id, product_id),
  CONSTRAINT fk_inventory_adj_items_parent 
    FOREIGN KEY (business_id, adjustment_id) 
    REFERENCES public.inventory_adjustments(business_id, id) 
    ON DELETE CASCADE,

  CONSTRAINT fk_inventory_adj_items_product 
    FOREIGN KEY (business_id, product_id) 
    REFERENCES public.products(business_id, id) 
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_inventory_adj_items_adj ON public.inventory_adjustment_items (adjustment_id);

-- =============================================================================
-- 4. IMMUTABILITY & DOCUMENT INTEGRITY TRIGGERS
-- =============================================================================

-- 4.1 Immutability Trigger for public.inventory_movements
CREATE OR REPLACE FUNCTION public.trg_protect_inventory_movements_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'CRITICAL INTEGRITY VIOLATION: public.inventory_movements is an immutable audit ledger. Updates and deletions are strictly prohibited. Use compensating adjustment movements.';
END;
$$;

DROP TRIGGER IF EXISTS trg_inventory_movements_immutable ON public.inventory_movements;
CREATE TRIGGER trg_inventory_movements_immutable
BEFORE UPDATE OR DELETE ON public.inventory_movements
FOR EACH ROW
EXECUTE FUNCTION public.trg_protect_inventory_movements_immutability();

-- 4.2 Prevent Modification of Line Items on Approved Adjustments
CREATE OR REPLACE FUNCTION public.trg_protect_inventory_adjustment_items()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_status TEXT;
BEGIN
  SELECT status INTO v_status
  FROM public.inventory_adjustments
  WHERE id = COALESCE(OLD.adjustment_id, NEW.adjustment_id);

  IF v_status = 'approved' THEN
    RAISE EXCEPTION 'LOCKED_RECORD: Cannot insert, update, or delete line items of an approved inventory adjustment.';
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_inventory_adj_items_lock ON public.inventory_adjustment_items;
CREATE TRIGGER trg_inventory_adj_items_lock
BEFORE INSERT OR UPDATE OR DELETE ON public.inventory_adjustment_items
FOR EACH ROW
EXECUTE FUNCTION public.trg_protect_inventory_adjustment_items();

-- 4.3 Attach Existing Canonical updated_at Triggers (From Migration 001)
-- Note: Reuses public.trigger_set_updated_at() defined in Migration 001 without redefining it.
DROP TRIGGER IF EXISTS trg_product_categories_updated_at ON public.product_categories;
CREATE TRIGGER trg_product_categories_updated_at
BEFORE UPDATE ON public.product_categories
FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_suppliers_updated_at ON public.suppliers;
CREATE TRIGGER trg_suppliers_updated_at
BEFORE UPDATE ON public.suppliers
FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_products_updated_at ON public.products;
CREATE TRIGGER trg_products_updated_at
BEFORE UPDATE ON public.products
FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_product_prices_updated_at ON public.product_prices;
CREATE TRIGGER trg_product_prices_updated_at
BEFORE UPDATE ON public.product_prices
FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_inventory_locations_updated_at ON public.inventory_locations;
CREATE TRIGGER trg_inventory_locations_updated_at
BEFORE UPDATE ON public.inventory_locations
FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_inventory_adjustments_updated_at ON public.inventory_adjustments;
CREATE TRIGGER trg_inventory_adjustments_updated_at
BEFORE UPDATE ON public.inventory_adjustments
FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- =============================================================================
-- 5. CANONICAL DATABASE INVENTORY POSTING ENGINE (RPC)
-- =============================================================================

-- Function: public.rpc_post_inventory_movement
-- Authoritative entry point for all stock mutations.
-- Executes within one atomic database transaction:
--   1. Authenticates auth.uid()
--   2. Authorizes caller via Migration 002 Scoped RBAC (has_permission_in_scope)
--   3. Validates business, branch, location, and product tenant relationships
--   4. Atomically locates or seeds inventory_balances row
--   5. Locks balance row FOR UPDATE (pessimistic concurrency control)
--   6. Computes resulting stock and protects reserved stock / non-negative constraints
--   7. Calculates weighted-average cost (WAC) for incoming stock
--   8. Appends immutable record into public.inventory_movements
--   9. Mutates public.inventory_balances atomically
--   10. Returns authoritative resulting stock state
CREATE OR REPLACE FUNCTION public.rpc_post_inventory_movement(
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
  p_allow_negative BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_balance_id UUID;
  v_current_on_hand NUMERIC(15, 4);
  v_current_reserved NUMERIC(15, 4);
  v_current_avg_cost NUMERIC(15, 4);
  v_new_on_hand NUMERIC(15, 4);
  v_new_avg_cost NUMERIC(15, 4);
  v_movement_id UUID;
  v_product_exists BOOLEAN;
  v_location_branch_match BOOLEAN;
  v_perm_required TEXT;
BEGIN
  -- 1. Authenticate caller
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: Authentication required to post inventory movements.';
  END IF;

  -- 2. Determine required RBAC permission based on movement type
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

  -- 2.1 Authorize caller using Migration 002 Scoped Permission architecture
  -- PrimaryOwner is sovereign; Branch/Business scopes are strictly enforced
  IF NOT (
    public.is_business_owner(p_business_id) 
    OR public.has_permission_in_scope(p_business_id, v_perm_required, p_branch_id)
    OR public.has_permission_in_scope(p_business_id, 'inventory:adjust', p_branch_id)
    OR public.has_permission_in_scope(p_business_id, 'catalog:manage', p_branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: User % lacks % permission for branch % in business %', 
      v_caller_id, v_perm_required, p_branch_id, p_business_id;
  END IF;

  -- 3. Validate Tenant Relationships
  -- Verify Product belongs to business, is active, and not deleted
  SELECT EXISTS (
    SELECT 1 FROM public.products
    WHERE id = p_product_id AND business_id = p_business_id AND is_active = true AND deleted_at IS NULL
  ) INTO v_product_exists;

  IF NOT v_product_exists THEN
    RAISE EXCEPTION 'INVALID_PRODUCT: Product % does not exist or is inactive in business %', p_product_id, p_business_id;
  END IF;

  -- Verify Location belongs to Business AND specified Branch
  SELECT EXISTS (
    SELECT 1 FROM public.inventory_locations
    WHERE id = p_location_id AND branch_id = p_branch_id AND business_id = p_business_id AND is_active = true AND deleted_at IS NULL
  ) INTO v_location_branch_match;

  IF NOT v_location_branch_match THEN
    RAISE EXCEPTION 'INVALID_LOCATION: Location % does not belong to branch % in business %', p_location_id, p_branch_id, p_business_id;
  END IF;

  -- 4. Atomic Concurrency Lock: Ensure inventory_balances row exists, then lock it FOR UPDATE
  INSERT INTO public.inventory_balances (
    business_id,
    branch_id,
    location_id,
    product_id,
    on_hand_quantity,
    reserved_quantity,
    average_unit_cost,
    updated_at
  )
  VALUES (
    p_business_id,
    p_branch_id,
    p_location_id,
    p_product_id,
    0.0000,
    0.0000,
    GREATEST(COALESCE(p_unit_cost, 0.0000), 0.0000),
    NOW()
  )
  ON CONFLICT (business_id, location_id, product_id) DO NOTHING;

  -- Pessimistic row locking: guarantees single-threaded sequential execution on this product/location
  SELECT 
    id, on_hand_quantity, reserved_quantity, average_unit_cost
  INTO 
    v_balance_id, v_current_on_hand, v_current_reserved, v_current_avg_cost
  FROM public.inventory_balances
  WHERE business_id = p_business_id 
    AND location_id = p_location_id 
    AND product_id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONCURRENCY_ERROR: Failed to acquire lock on inventory balance for product % at location %',
      p_product_id, p_location_id;
  END IF;

  -- 5. Calculate resulting quantity & prevent unauthorized negative physical or available stock
  v_new_on_hand := v_current_on_hand + p_quantity;

  IF NOT p_allow_negative THEN
    IF v_new_on_hand < 0 THEN
      RAISE EXCEPTION 'INSUFFICIENT_STOCK: Transaction rejected. Current on hand: %, requested change: %, resulting quantity: %',
        v_current_on_hand, p_quantity, v_new_on_hand;
    END IF;

    -- Normal stock mutations cannot consume reserved stock
    IF (v_new_on_hand - v_current_reserved) < 0 THEN
      RAISE EXCEPTION 'INSUFFICIENT_AVAILABLE_STOCK: Transaction rejected. Available stock (%) is insufficient for requested change (%) with reserved stock (%)',
        (v_current_on_hand - v_current_reserved), p_quantity, v_current_reserved;
    END IF;
  END IF;

  -- 6. Weighted-Average Cost (WAC) Algorithm:
  -- Incoming stock with cost: blend old cost and incoming cost
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
    -- Outgoing stock (sales, transfers out) or zero-cost adjustments retain existing average unit cost
    -- If stock reached zero, old average cost is retained until new stock arrives
    v_new_avg_cost := v_current_avg_cost;
  END IF;

  -- 7. Insert into immutable inventory movements ledger
  INSERT INTO public.inventory_movements (
    business_id,
    branch_id,
    location_id,
    product_id,
    movement_type,
    quantity,
    unit_cost,
    reference_type,
    reference_id,
    notes,
    actor_id,
    created_at
  )
  VALUES (
    p_business_id,
    p_branch_id,
    p_location_id,
    p_product_id,
    p_movement_type,
    p_quantity,
    CASE WHEN p_unit_cost > 0 THEN p_unit_cost ELSE v_current_avg_cost END,
    p_reference_type,
    p_reference_id,
    p_notes,
    v_caller_id,
    NOW()
  )
  RETURNING id INTO v_movement_id;

  -- 8. Mutate inventory_balances in the exact same transaction
  UPDATE public.inventory_balances
  SET 
    on_hand_quantity = v_new_on_hand,
    average_unit_cost = v_new_avg_cost,
    updated_at = NOW()
  WHERE id = v_balance_id;

  -- 9. Return authoritative receipt
  RETURN jsonb_build_object(
    'success', true,
    'movement_id', v_movement_id,
    'product_id', p_product_id,
    'location_id', p_location_id,
    'branch_id', p_branch_id,
    'previous_on_hand', v_current_on_hand,
    'quantity_delta', p_quantity,
    'new_on_hand', v_new_on_hand,
    'reserved_quantity', v_current_reserved,
    'available_quantity', (v_new_on_hand - v_current_reserved),
    'average_unit_cost', v_new_avg_cost,
    'movement_type', p_movement_type
  );
END;
$$;

-- =============================================================================
-- 6. CANONICAL INVENTORY ADJUSTMENT APPROVAL RPC
-- =============================================================================

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

  -- 5. Process line items atomically
  FOR v_item IN 
    SELECT * FROM public.inventory_adjustment_items
    WHERE adjustment_id = p_adjustment_id AND business_id = p_business_id
  LOOP
    IF v_item.variance_quantity <> 0 THEN
      v_res := public.rpc_post_inventory_movement(
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
        p_allow_negative := false
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

-- =============================================================================
-- 7. ROW LEVEL SECURITY (RLS) POLICIES & PRIVILEGE HARDENING
-- =============================================================================

-- Enable RLS on all operational foundation tables
ALTER TABLE public.product_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_adjustment_items ENABLE ROW LEVEL SECURITY;

-- -----------------------------------------------------------------------------
-- 7.1 product_categories RLS
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "policy_product_categories_select" ON public.product_categories;
CREATE POLICY "policy_product_categories_select" ON public.product_categories
FOR SELECT USING (
  public.is_member_of_business(business_id)
);

DROP POLICY IF EXISTS "policy_product_categories_insert" ON public.product_categories;
CREATE POLICY "policy_product_categories_insert" ON public.product_categories
FOR INSERT WITH CHECK (
  public.is_business_owner(business_id) 
  OR public.has_permission(business_id, 'catalog:create')
  OR public.has_permission(business_id, 'catalog:manage')
);

DROP POLICY IF EXISTS "policy_product_categories_update" ON public.product_categories;
CREATE POLICY "policy_product_categories_update" ON public.product_categories
FOR UPDATE USING (
  public.is_business_owner(business_id) 
  OR public.has_permission(business_id, 'catalog:update')
  OR public.has_permission(business_id, 'catalog:manage')
);

DROP POLICY IF EXISTS "policy_product_categories_delete" ON public.product_categories;
CREATE POLICY "policy_product_categories_delete" ON public.product_categories
FOR DELETE USING (
  public.is_business_owner(business_id) 
  OR public.has_permission(business_id, 'catalog:delete')
  OR public.has_permission(business_id, 'catalog:manage')
);

-- -----------------------------------------------------------------------------
-- 7.2 suppliers RLS
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "policy_suppliers_select" ON public.suppliers;
CREATE POLICY "policy_suppliers_select" ON public.suppliers
FOR SELECT USING (
  public.is_member_of_business(business_id)
);

DROP POLICY IF EXISTS "policy_suppliers_all_write" ON public.suppliers;
CREATE POLICY "policy_suppliers_all_write" ON public.suppliers
FOR ALL USING (
  public.is_business_owner(business_id) 
  OR public.has_permission(business_id, 'catalog:manage')
  OR public.has_permission(business_id, 'catalog:update')
);

-- -----------------------------------------------------------------------------
-- 7.3 products RLS
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "policy_products_select" ON public.products;
CREATE POLICY "policy_products_select" ON public.products
FOR SELECT USING (
  public.is_member_of_business(business_id)
);

DROP POLICY IF EXISTS "policy_products_insert" ON public.products;
CREATE POLICY "policy_products_insert" ON public.products
FOR INSERT WITH CHECK (
  public.is_business_owner(business_id) 
  OR public.has_permission(business_id, 'catalog:create')
  OR public.has_permission(business_id, 'catalog:manage')
);

DROP POLICY IF EXISTS "policy_products_update" ON public.products;
CREATE POLICY "policy_products_update" ON public.products
FOR UPDATE USING (
  public.is_business_owner(business_id) 
  OR public.has_permission(business_id, 'catalog:update')
  OR public.has_permission(business_id, 'catalog:manage')
);

DROP POLICY IF EXISTS "policy_products_delete" ON public.products;
CREATE POLICY "policy_products_delete" ON public.products
FOR DELETE USING (
  public.is_business_owner(business_id) 
  OR public.has_permission(business_id, 'catalog:delete')
  OR public.has_permission(business_id, 'catalog:manage')
);

-- -----------------------------------------------------------------------------
-- 7.4 product_prices RLS
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "policy_product_prices_select" ON public.product_prices;
CREATE POLICY "policy_product_prices_select" ON public.product_prices
FOR SELECT USING (
  public.is_member_of_business(business_id)
);

DROP POLICY IF EXISTS "policy_product_prices_write" ON public.product_prices;
CREATE POLICY "policy_product_prices_write" ON public.product_prices
FOR ALL USING (
  public.is_business_owner(business_id) 
  OR public.has_permission(business_id, 'catalog:update')
  OR public.has_permission(business_id, 'catalog:manage')
);

-- -----------------------------------------------------------------------------
-- 7.5 inventory_locations RLS (Scope-Aware)
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "policy_inventory_locations_select" ON public.inventory_locations;
CREATE POLICY "policy_inventory_locations_select" ON public.inventory_locations
FOR SELECT USING (
  public.is_member_of_business(business_id)
);

DROP POLICY IF EXISTS "policy_inventory_locations_write" ON public.inventory_locations;
CREATE POLICY "policy_inventory_locations_write" ON public.inventory_locations
FOR ALL USING (
  public.is_business_owner(business_id) 
  OR public.has_permission_in_scope(business_id, 'inventory:adjust', branch_id)
  OR public.has_permission(business_id, 'catalog:manage')
);

-- -----------------------------------------------------------------------------
-- 7.6 inventory_balances RLS & Table Grants (Direct Write Blocked)
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "policy_inventory_balances_select" ON public.inventory_balances;
CREATE POLICY "policy_inventory_balances_select" ON public.inventory_balances
FOR SELECT USING (
  public.is_member_of_business(business_id)
);

-- Defense-in-depth: Revoke all table-level write privileges from non-superusers
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.inventory_balances FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.inventory_balances TO authenticated;

-- -----------------------------------------------------------------------------
-- 7.7 inventory_movements RLS & Table Grants (Direct Write Blocked)
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "policy_inventory_movements_select" ON public.inventory_movements;
CREATE POLICY "policy_inventory_movements_select" ON public.inventory_movements
FOR SELECT USING (
  public.is_member_of_business(business_id)
);

-- Defense-in-depth: Revoke all table-level write privileges from non-superusers
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.inventory_movements FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.inventory_movements TO authenticated;

-- -----------------------------------------------------------------------------
-- 7.8 inventory_adjustments & items RLS (Scope-Aware)
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "policy_inventory_adjustments_select" ON public.inventory_adjustments;
CREATE POLICY "policy_inventory_adjustments_select" ON public.inventory_adjustments
FOR SELECT USING (
  public.is_member_of_business(business_id)
);

DROP POLICY IF EXISTS "policy_inventory_adjustments_insert" ON public.inventory_adjustments;
CREATE POLICY "policy_inventory_adjustments_insert" ON public.inventory_adjustments
FOR INSERT WITH CHECK (
  public.is_business_owner(business_id) 
  OR public.has_permission_in_scope(business_id, 'inventory:adjust', branch_id)
);

DROP POLICY IF EXISTS "policy_inventory_adjustments_update" ON public.inventory_adjustments;
CREATE POLICY "policy_inventory_adjustments_update" ON public.inventory_adjustments
FOR UPDATE USING (
  (public.is_business_owner(business_id) OR public.has_permission_in_scope(business_id, 'inventory:adjust', branch_id))
  AND status IN ('draft', 'pending_approval')
);

DROP POLICY IF EXISTS "policy_inventory_adj_items_select" ON public.inventory_adjustment_items;
CREATE POLICY "policy_inventory_adj_items_select" ON public.inventory_adjustment_items
FOR SELECT USING (
  public.is_member_of_business(business_id)
);

DROP POLICY IF EXISTS "policy_inventory_adj_items_write" ON public.inventory_adjustment_items;
CREATE POLICY "policy_inventory_adj_items_write" ON public.inventory_adjustment_items
FOR ALL USING (
  public.is_business_owner(business_id) 
  OR public.has_permission(business_id, 'inventory:adjust')
);

-- -----------------------------------------------------------------------------
-- 7.9 RPC Execution Privileges
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.rpc_post_inventory_movement FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_post_inventory_movement TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_approve_inventory_adjustment FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_approve_inventory_adjustment TO authenticated;

-- =============================================================================
-- 8. COMPREHENSIVE POST-DEPLOYMENT VERIFICATION SCRIPT (READ-ONLY)
-- =============================================================================
/*
-- =============================================================================
-- VERIFICATION CHECKPOINT 1: Exactly 9 Core Operational Tables Exist
-- =============================================================================
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' 
  AND table_name IN (
    'product_categories',
    'suppliers',
    'products',
    'product_prices',
    'inventory_locations',
    'inventory_balances',
    'inventory_movements',
    'inventory_adjustments',
    'inventory_adjustment_items'
  )
ORDER BY table_name;

-- =============================================================================
-- VERIFICATION CHECKPOINT 2: Row Level Security (RLS) Enabled on All 9 Tables
-- =============================================================================
SELECT tablename, rowsecurity 
FROM pg_tables 
WHERE schemaname = 'public' 
  AND tablename IN (
    'product_categories',
    'suppliers',
    'products',
    'product_prices',
    'inventory_locations',
    'inventory_balances',
    'inventory_movements',
    'inventory_adjustments',
    'inventory_adjustment_items'
  )
ORDER BY tablename;

-- =============================================================================
-- VERIFICATION CHECKPOINT 3: Tenant-Safe Composite Foreign Keys
-- =============================================================================
SELECT
    tc.table_name,
    kcu.column_name,
    ccu.table_name AS foreign_table_name,
    ccu.column_name AS foreign_column_name,
    tc.constraint_name
FROM information_schema.table_constraints AS tc
JOIN information_schema.key_column_usage AS kcu
  ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.constraint_column_usage AS ccu
  ON ccu.constraint_name = tc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_name IN (
    'product_categories',
    'products',
    'product_prices',
    'inventory_locations',
    'inventory_balances',
    'inventory_movements',
    'inventory_adjustments',
    'inventory_adjustment_items'
  )
ORDER BY tc.table_name, tc.constraint_name;

-- =============================================================================
-- VERIFICATION CHECKPOINT 4: Check Constraints on Quantities and Movement Signs
-- =============================================================================
SELECT conname, relname, pg_get_constraintdef(c.oid)
FROM pg_constraint c
JOIN pg_class r ON c.conrelid = r.oid
WHERE relname IN ('inventory_balances', 'inventory_movements', 'products', 'product_prices')
  AND contype = 'c';

-- =============================================================================
-- VERIFICATION CHECKPOINT 5: Partial Unique SKU Index
-- =============================================================================
SELECT indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'public' 
  AND tablename = 'products'
  AND indexname = 'uq_products_biz_sku';

-- =============================================================================
-- VERIFICATION CHECKPOINT 6: Permission Registration in public.permissions
-- =============================================================================
SELECT key, module, description
FROM public.permissions
WHERE key IN (
  'catalog:view', 'catalog:create', 'catalog:update', 'catalog:delete', 'catalog:manage',
  'inventory:view', 'inventory:adjust', 'inventory:transfer', 'inventory:audit'
)
ORDER BY module, key;

-- =============================================================================
-- VERIFICATION CHECKPOINT 7: RPC Functions Security Definition & Search Path
-- =============================================================================
SELECT 
  routine_name, 
  routine_type, 
  security_type,
  prosecdef,
  proconfig
FROM information_schema.routines r
JOIN pg_proc p ON p.proname = r.routine_name
WHERE routine_schema = 'public'
  AND routine_name IN ('rpc_post_inventory_movement', 'rpc_approve_inventory_adjustment');

-- =============================================================================
-- VERIFICATION CHECKPOINT 8: RPC Execute Privileges
-- =============================================================================
SELECT grantee, routine_name, privilege_type
FROM information_schema.routine_privileges
WHERE routine_schema = 'public'
  AND routine_name IN ('rpc_post_inventory_movement', 'rpc_approve_inventory_adjustment')
ORDER BY routine_name, grantee;

-- =============================================================================
-- VERIFICATION CHECKPOINT 9: Table Write Privilege Lockdown on Balances & Ledger
-- =============================================================================
SELECT grantee, table_name, privilege_type
FROM information_schema.table_privileges
WHERE table_schema = 'public'
  AND table_name IN ('inventory_balances', 'inventory_movements')
ORDER BY table_name, grantee, privilege_type;

-- =============================================================================
-- VERIFICATION CHECKPOINT 10: Immutability Triggers
-- =============================================================================
SELECT event_object_table, trigger_name, event_manipulation, action_statement
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN ('inventory_movements', 'inventory_adjustment_items')
ORDER BY event_object_table, trigger_name;
*/
