-- =============================================================================
-- FinTab Enterprise OS - Migration 014A: Financial Privacy Additive Security Layer
-- Candidate Migration Script (STAGING / PRE-PRODUCTION ONLY - DO NOT APPLY TO PRODUCTION)
--
-- Phase S3-B1: Controlled Financial Privacy Implementation (Additive Layer)
-- Baseline: Frozen Migrations 001–013 (Unmodified)
--
-- Summary of Additive Security Objects:
-- 1. Seeds the exact 13 new financial/compliance permission keys into public.permissions
--    with ZERO automatic role_permissions grants to non-owner roles (fail-closed by default).
--    (Reuses existing 'treasury:balance:view' from Migration 013 for treasury balances).
-- 2. Creates public.can_view_financial_metric(p_business_id, p_permission_key, p_branch_id)
--    with a strict 14-key allowlist (13 new keys + existing 'treasury:balance:view').
-- 3. Creates restricted schema app_private and 10 row-anchored, self-defending
--    SECURITY DEFINER field accessors (app_private.sec_*). Every accessor independently
--    verifies auth.uid(), active business membership, authoritative row tenancy,
--    authoritative branch scope, and its hardcoded financial permission key.
-- 4. Creates 8 security_invoker = true compatibility views (public.v_*_secure)
--    that project public columns directly and mask sensitive columns to NULL when
--    unauthorized (never coercing unauthorized NULL to 0.0000).
-- 5. Hardens existing analytical views (v_inventory_stock_valuation,
--    v_daily_sales_analytics, v_customer_receivables, v_cash_register_balances)
--    and RPC public.rpc_get_operational_dashboard_metrics with per-KPI permission gating.
-- 6. Creates public.get_pos_sale_receipt(p_business_id, p_sale_id) for least-privilege
--    single-transaction POS receipt lookup without exposing cost_price or bulk history.
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. SEED EXACT 13 NEW FINANCIAL & COMPLIANCE PERMISSION KEYS (ZERO AUTO-GRANTS)
-- =============================================================================
-- Reconciled 1-to-1 against FinancialVisibilityService.ts and src/types/domain/identity.ts.
-- Note: 'treasury:balance:view' already exists in public.permissions (Migration 013).
-- Zero non-owner role_permissions rows are inserted here; PrimaryOwner is authorized
-- via public.is_business_owner(p_business_id) and explicit PrimaryOwner role mapping.

INSERT INTO public.permissions (key, module, description)
VALUES
  ('inventory:cost:view',               'inventory', 'View product unit cost, landed cost, weighted-average cost, and historical COGS snapshots'),
  ('inventory:valuation:view',          'inventory', 'View total inventory cost valuation, retail valuation, and stock loss valuation'),
  ('inventory:margin:view',             'inventory', 'View product and transaction gross margin percentages'),
  ('financials:gross_profit:view',      'reports',   'View gross profit totals and business profit summaries'),
  ('financials:net_profit:view',        'reports',   'View net profit and bottom-line earnings'),
  ('financials:revenue:view',           'reports',   'View gross merchandise value, net sales revenue, discounts, and average ticket KPIs'),
  ('financials:expenses:view',          'expenses',  'View aggregate pending and paid expense totals across branch and business scopes'),
  ('customers:sales_amount:view',       'customers', 'View customer purchase history amounts, total sales, and revenue rankings'),
  ('customers:credit_balance:view',     'customers', 'View customer outstanding receivable balances and aging totals'),
  ('customers:credit_limit:view',       'customers', 'View customer commercial credit limits'),
  ('compliance:tax_id:view',            'customers', 'View customer tax identification numbers (NIF/TIN)'),
  ('cash_verification:expected_cash:view', 'registers', 'View system expected cash on register shifts (disables blind close when granted)'),
  ('cash_verification:variance:view',   'registers', 'View register shift over/short cash reconciliation variance')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module,
  description = EXCLUDED.description;

-- ZERO AUTOMATIC ROLE_PERMISSIONS GRANTS:
-- PrimaryOwner sovereignty is evaluated authoritatively via public.is_business_owner(p_business_id).
-- All non-owner system roles (CoOwner, SuperAdmin, GeneralManager, FinanceManager,
-- BranchManager, SalesManager, Salesperson, Cashier, StockManager, StockStaff,
-- Investor, Viewer) receive ZERO automatic grants in public.role_permissions.


-- =============================================================================
-- 2. AUTHORITATIVE FINANCIAL METRIC GUARD: public.can_view_financial_metric
-- =============================================================================
-- Evaluates whether the authenticated caller holds a specific financial/compliance
-- permission key within p_business_id and optional p_branch_id scope.
-- Fails closed (FALSE) for unauthenticated callers, inactive members, revoked roles,
-- out-of-scope branches, or any key outside the 14-key financial privacy allowlist.

CREATE OR REPLACE FUNCTION public.can_view_financial_metric(
  p_business_id UUID,
  p_permission_key TEXT,
  p_branch_id UUID DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL OR p_business_id IS NULL OR p_permission_key IS NULL THEN
    RETURN FALSE;
  END IF;

  -- Strict allowlist of the 13 new financial/compliance keys + existing treasury:balance:view
  IF p_permission_key NOT IN (
    'inventory:cost:view',
    'inventory:valuation:view',
    'inventory:margin:view',
    'financials:gross_profit:view',
    'financials:net_profit:view',
    'financials:revenue:view',
    'financials:expenses:view',
    'customers:sales_amount:view',
    'customers:credit_balance:view',
    'customers:credit_limit:view',
    'compliance:tax_id:view',
    'cash_verification:expected_cash:view',
    'cash_verification:variance:view',
    'treasury:balance:view'
  ) THEN
    RETURN FALSE;
  END IF;

  -- Verify active business and active membership (or sovereign PrimaryOwner)
  IF NOT (
    public.is_business_owner(p_business_id)
    OR EXISTS (
      SELECT 1
      FROM public.business_memberships bm
      JOIN public.businesses b ON b.id = bm.business_id
      WHERE bm.business_id = p_business_id
        AND bm.user_id = v_caller_id
        AND bm.status = 'active'
        AND b.status = 'active'
        AND b.deleted_at IS NULL
    )
  ) THEN
    RETURN FALSE;
  END IF;

  -- Sovereign PrimaryOwner bypass (verified against businesses.owner_user_id + active membership)
  IF public.is_business_owner(p_business_id) THEN
    RETURN TRUE;
  END IF;

  -- Scope-aware RBAC evaluation via authoritative public.has_permission_in_scope / public.has_permission
  IF p_branch_id IS NULL THEN
    RETURN public.has_permission_in_scope(p_business_id, p_permission_key, NULL);
  ELSE
    RETURN public.has_permission_in_scope(p_business_id, p_permission_key, p_branch_id);
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.can_view_financial_metric(UUID, TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_view_financial_metric(UUID, TEXT, UUID) TO authenticated;

-- =============================================================================
-- 3. PRIVATE SCHEMA & ROW-ANCHORED SELF-DEFENDING ACCESSORS (app_private.sec_*)
-- =============================================================================
-- app_private is never exposed in PostgREST db-schemas.
-- Every accessor is row-anchored (takes p_business_id and p_row_id) and independently
-- verifies auth.uid(), active membership, row tenancy, branch access, and its
-- hardcoded financial permission key before returning the sensitive scalar value.

CREATE SCHEMA IF NOT EXISTS app_private;
REVOKE ALL ON SCHEMA app_private FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA app_private TO authenticated;

-- 3.1 Product Cost Price Accessor (public.products.cost_price)
CREATE OR REPLACE FUNCTION app_private.sec_product_cost_price(
  p_business_id UUID,
  p_product_id UUID
)
RETURNS NUMERIC(15, 4)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_cost NUMERIC(15, 4);
  v_row_biz_id UUID;
BEGIN
  IF auth.uid() IS NULL OR p_business_id IS NULL OR p_product_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT p.business_id, p.cost_price
  INTO v_row_biz_id, v_cost
  FROM public.products p
  WHERE p.id = p_product_id
    AND p.business_id = p_business_id
    AND p.deleted_at IS NULL;

  IF NOT FOUND OR v_row_biz_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT public.can_view_financial_metric(v_row_biz_id, 'inventory:cost:view', NULL) THEN
    RETURN NULL;
  END IF;

  RETURN v_cost;
END;
$$;

-- 3.2 Inventory Balance Average Unit Cost Accessor (public.inventory_balances.average_unit_cost)
CREATE OR REPLACE FUNCTION app_private.sec_inventory_average_unit_cost(
  p_business_id UUID,
  p_balance_id UUID
)
RETURNS NUMERIC(15, 4)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row_biz_id UUID;
  v_row_branch_id UUID;
  v_avg_cost NUMERIC(15, 4);
BEGIN
  IF auth.uid() IS NULL OR p_business_id IS NULL OR p_balance_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT ib.business_id, ib.branch_id, ib.average_unit_cost
  INTO v_row_biz_id, v_row_branch_id, v_avg_cost
  FROM public.inventory_balances ib
  WHERE ib.id = p_balance_id
    AND ib.business_id = p_business_id;

  IF NOT FOUND OR v_row_biz_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT public.can_view_financial_metric(v_row_biz_id, 'inventory:cost:view', v_row_branch_id) THEN
    RETURN NULL;
  END IF;

  RETURN v_avg_cost;
END;
$$;

-- 3.3 Inventory Movement Unit Cost Accessor (public.inventory_movements.unit_cost)
CREATE OR REPLACE FUNCTION app_private.sec_movement_unit_cost(
  p_business_id UUID,
  p_movement_id UUID
)
RETURNS NUMERIC(15, 4)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row_biz_id UUID;
  v_row_branch_id UUID;
  v_unit_cost NUMERIC(15, 4);
BEGIN
  IF auth.uid() IS NULL OR p_business_id IS NULL OR p_movement_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT im.business_id, im.branch_id, im.unit_cost
  INTO v_row_biz_id, v_row_branch_id, v_unit_cost
  FROM public.inventory_movements im
  WHERE im.id = p_movement_id
    AND im.business_id = p_business_id;

  IF NOT FOUND OR v_row_biz_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT public.can_view_financial_metric(v_row_biz_id, 'inventory:cost:view', v_row_branch_id) THEN
    RETURN NULL;
  END IF;

  RETURN v_unit_cost;
END;
$$;

-- 3.4 Inventory Adjustment Item Unit Cost Accessor (public.inventory_adjustment_items.unit_cost)
CREATE OR REPLACE FUNCTION app_private.sec_adjustment_item_unit_cost(
  p_business_id UUID,
  p_item_id UUID
)
RETURNS NUMERIC(15, 4)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row_biz_id UUID;
  v_row_branch_id UUID;
  v_unit_cost NUMERIC(15, 4);
BEGIN
  IF auth.uid() IS NULL OR p_business_id IS NULL OR p_item_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT iai.business_id, ia.branch_id, iai.unit_cost
  INTO v_row_biz_id, v_row_branch_id, v_unit_cost
  FROM public.inventory_adjustment_items iai
  JOIN public.inventory_adjustments ia
    ON ia.id = iai.adjustment_id AND ia.business_id = iai.business_id
  WHERE iai.id = p_item_id
    AND iai.business_id = p_business_id
    AND ia.deleted_at IS NULL;

  IF NOT FOUND OR v_row_biz_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT public.can_view_financial_metric(v_row_biz_id, 'inventory:cost:view', v_row_branch_id) THEN
    RETURN NULL;
  END IF;

  RETURN v_unit_cost;
END;
$$;

-- 3.5 Inventory Transfer Item Unit Cost Accessor (public.inventory_transfer_items.unit_cost_at_dispatch)
CREATE OR REPLACE FUNCTION app_private.sec_transfer_item_unit_cost(
  p_business_id UUID,
  p_item_id UUID
)
RETURNS NUMERIC(15, 4)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row_biz_id UUID;
  v_from_branch_id UUID;
  v_to_branch_id UUID;
  v_unit_cost NUMERIC(15, 4);
BEGIN
  IF auth.uid() IS NULL OR p_business_id IS NULL OR p_item_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT iti.business_id, it.from_branch_id, it.to_branch_id, iti.unit_cost_at_dispatch
  INTO v_row_biz_id, v_from_branch_id, v_to_branch_id, v_unit_cost
  FROM public.inventory_transfer_items iti
  JOIN public.inventory_transfers it
    ON it.id = iti.transfer_id AND it.business_id = iti.business_id
  WHERE iti.id = p_item_id
    AND iti.business_id = p_business_id;

  IF NOT FOUND OR v_row_biz_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT (
    public.can_view_financial_metric(v_row_biz_id, 'inventory:cost:view', v_from_branch_id)
    OR public.can_view_financial_metric(v_row_biz_id, 'inventory:cost:view', v_to_branch_id)
  ) THEN
    RETURN NULL;
  END IF;

  RETURN v_unit_cost;
END;
$$;

-- 3.6 Sales Transaction Item Cost Price Accessor (public.sales_transaction_items.cost_price)
CREATE OR REPLACE FUNCTION app_private.sec_sale_item_unit_cost(
  p_business_id UUID,
  p_item_id UUID
)
RETURNS NUMERIC(15, 4)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row_biz_id UUID;
  v_row_branch_id UUID;
  v_cost_price NUMERIC(15, 4);
BEGIN
  IF auth.uid() IS NULL OR p_business_id IS NULL OR p_item_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT sti.business_id, st.branch_id, sti.cost_price
  INTO v_row_biz_id, v_row_branch_id, v_cost_price
  FROM public.sales_transaction_items sti
  JOIN public.sales_transactions st
    ON st.id = sti.transaction_id AND st.business_id = sti.business_id
  WHERE sti.id = p_item_id
    AND sti.business_id = p_business_id;

  IF NOT FOUND OR v_row_biz_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT public.can_view_financial_metric(v_row_biz_id, 'inventory:cost:view', v_row_branch_id) THEN
    RETURN NULL;
  END IF;

  RETURN v_cost_price;
END;
$$;

-- 3.7 Customer Credit Limit Accessor (public.customers.credit_limit)
CREATE OR REPLACE FUNCTION app_private.sec_customer_credit_limit(
  p_business_id UUID,
  p_customer_id UUID
)
RETURNS NUMERIC(15, 4)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row_biz_id UUID;
  v_credit_limit NUMERIC(15, 4);
BEGIN
  IF auth.uid() IS NULL OR p_business_id IS NULL OR p_customer_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT c.business_id, c.credit_limit
  INTO v_row_biz_id, v_credit_limit
  FROM public.customers c
  WHERE c.id = p_customer_id
    AND c.business_id = p_business_id
    AND c.deleted_at IS NULL;

  IF NOT FOUND OR v_row_biz_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT public.can_view_financial_metric(v_row_biz_id, 'customers:credit_limit:view', NULL) THEN
    RETURN NULL;
  END IF;

  RETURN v_credit_limit;
END;
$$;

-- 3.8 Customer Tax ID Accessor (public.customers.tax_id)
CREATE OR REPLACE FUNCTION app_private.sec_customer_tax_id(
  p_business_id UUID,
  p_customer_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row_biz_id UUID;
  v_tax_id TEXT;
BEGIN
  IF auth.uid() IS NULL OR p_business_id IS NULL OR p_customer_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT c.business_id, c.tax_id
  INTO v_row_biz_id, v_tax_id
  FROM public.customers c
  WHERE c.id = p_customer_id
    AND c.business_id = p_business_id
    AND c.deleted_at IS NULL;

  IF NOT FOUND OR v_row_biz_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT public.can_view_financial_metric(v_row_biz_id, 'compliance:tax_id:view', NULL) THEN
    RETURN NULL;
  END IF;

  RETURN v_tax_id;
END;
$$;

-- 3.9 Register Shift Expected Cash Accessor (public.register_shifts.expected_cash)
-- Enforces blind cash close: returns NULL unless caller holds cash_verification:expected_cash:view.
CREATE OR REPLACE FUNCTION app_private.sec_register_shift_expected_cash(
  p_business_id UUID,
  p_shift_id UUID
)
RETURNS NUMERIC(15, 4)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row_biz_id UUID;
  v_row_branch_id UUID;
  v_expected_cash NUMERIC(15, 4);
BEGIN
  IF auth.uid() IS NULL OR p_business_id IS NULL OR p_shift_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT rs.business_id, rs.branch_id, rs.expected_cash
  INTO v_row_biz_id, v_row_branch_id, v_expected_cash
  FROM public.register_shifts rs
  WHERE rs.id = p_shift_id
    AND rs.business_id = p_business_id;

  IF NOT FOUND OR v_row_biz_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT public.can_view_financial_metric(v_row_biz_id, 'cash_verification:expected_cash:view', v_row_branch_id) THEN
    RETURN NULL;
  END IF;

  RETURN v_expected_cash;
END;
$$;

-- 3.10 Register Shift Variance Accessor (public.register_shifts.variance)
-- Enforces blind cash close: returns NULL unless caller holds cash_verification:variance:view.
CREATE OR REPLACE FUNCTION app_private.sec_register_shift_variance(
  p_business_id UUID,
  p_shift_id UUID
)
RETURNS NUMERIC(15, 4)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row_biz_id UUID;
  v_row_branch_id UUID;
  v_variance NUMERIC(15, 4);
BEGIN
  IF auth.uid() IS NULL OR p_business_id IS NULL OR p_shift_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT rs.business_id, rs.branch_id, rs.variance
  INTO v_row_biz_id, v_row_branch_id, v_variance
  FROM public.register_shifts rs
  WHERE rs.id = p_shift_id
    AND rs.business_id = p_business_id;

  IF NOT FOUND OR v_row_biz_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT public.can_view_financial_metric(v_row_biz_id, 'cash_verification:variance:view', v_row_branch_id) THEN
    RETURN NULL;
  END IF;

  RETURN v_variance;
END;
$$;

-- Restrict execution on all app_private functions strictly to authenticated
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app_private FROM PUBLIC, anon;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA app_private TO authenticated;

-- =============================================================================
-- 4. SECURITY_INVOKER = TRUE COMPATIBILITY VIEWS (public.v_*_secure)
-- =============================================================================
-- Each view selects only public columns directly from the base table (so caller RLS
-- and 014B column-level grants apply) and projects sensitive columns through
-- the self-defending app_private.sec_* accessors.

-- 4.1 public.v_products_secure
CREATE OR REPLACE VIEW public.v_products_secure
WITH (security_invoker = true) AS
SELECT
  p.id,
  p.business_id,
  p.category_id,
  p.primary_supplier_id,
  p.name,
  p.sku,
  p.barcode,
  p.description,
  p.product_type,
  p.unit_of_measure,
  app_private.sec_product_cost_price(p.business_id, p.id) AS cost_price,
  p.is_active,
  p.created_by,
  p.updated_by,
  p.created_at,
  p.updated_at,
  p.deleted_at,
  p.metadata
FROM public.products p;

REVOKE ALL ON public.v_products_secure FROM PUBLIC, anon;
GRANT SELECT ON public.v_products_secure TO authenticated;

-- 4.2 public.v_inventory_balances_secure
CREATE OR REPLACE VIEW public.v_inventory_balances_secure
WITH (security_invoker = true) AS
SELECT
  ib.id,
  ib.business_id,
  ib.branch_id,
  ib.location_id,
  ib.product_id,
  ib.on_hand_quantity,
  ib.reserved_quantity,
  ib.available_quantity,
  app_private.sec_inventory_average_unit_cost(ib.business_id, ib.id) AS average_unit_cost,
  ib.updated_at
FROM public.inventory_balances ib;

REVOKE ALL ON public.v_inventory_balances_secure FROM PUBLIC, anon;
GRANT SELECT ON public.v_inventory_balances_secure TO authenticated;

-- 4.3 public.v_inventory_movements_secure
CREATE OR REPLACE VIEW public.v_inventory_movements_secure
WITH (security_invoker = true) AS
SELECT
  im.id,
  im.business_id,
  im.branch_id,
  im.location_id,
  im.product_id,
  im.movement_type,
  im.quantity,
  app_private.sec_movement_unit_cost(im.business_id, im.id) AS unit_cost,
  im.reference_type,
  im.reference_id,
  im.notes,
  im.actor_id,
  im.created_at,
  im.metadata
FROM public.inventory_movements im;

REVOKE ALL ON public.v_inventory_movements_secure FROM PUBLIC, anon;
GRANT SELECT ON public.v_inventory_movements_secure TO authenticated;

-- 4.4 public.v_inventory_adjustment_items_secure
CREATE OR REPLACE VIEW public.v_inventory_adjustment_items_secure
WITH (security_invoker = true) AS
SELECT
  iai.id,
  iai.business_id,
  iai.adjustment_id,
  iai.product_id,
  iai.system_quantity,
  iai.counted_quantity,
  iai.variance_quantity,
  app_private.sec_adjustment_item_unit_cost(iai.business_id, iai.id) AS unit_cost,
  iai.reason,
  iai.created_at
FROM public.inventory_adjustment_items iai;

REVOKE ALL ON public.v_inventory_adjustment_items_secure FROM PUBLIC, anon;
GRANT SELECT ON public.v_inventory_adjustment_items_secure TO authenticated;

-- 4.5 public.v_inventory_transfer_items_secure
CREATE OR REPLACE VIEW public.v_inventory_transfer_items_secure
WITH (security_invoker = true) AS
SELECT
  iti.id,
  iti.business_id,
  iti.transfer_id,
  iti.product_id,
  iti.quantity_requested,
  iti.quantity_shipped,
  iti.quantity_received,
  app_private.sec_transfer_item_unit_cost(iti.business_id, iti.id) AS unit_cost_at_dispatch,
  iti.created_at
FROM public.inventory_transfer_items iti;

REVOKE ALL ON public.v_inventory_transfer_items_secure FROM PUBLIC, anon;
GRANT SELECT ON public.v_inventory_transfer_items_secure TO authenticated;

-- 4.6 public.v_sales_transaction_items_secure
CREATE OR REPLACE VIEW public.v_sales_transaction_items_secure
WITH (security_invoker = true) AS
SELECT
  sti.id,
  sti.business_id,
  sti.transaction_id,
  sti.product_id,
  sti.inventory_location_id,
  sti.salesperson_user_id,
  sti.quantity,
  sti.unit_price,
  sti.discount_amount,
  sti.tax_amount,
  sti.line_total,
  app_private.sec_sale_item_unit_cost(sti.business_id, sti.id) AS cost_price,
  sti.notes,
  sti.created_at
FROM public.sales_transaction_items sti;

REVOKE ALL ON public.v_sales_transaction_items_secure FROM PUBLIC, anon;
GRANT SELECT ON public.v_sales_transaction_items_secure TO authenticated;

-- 4.7 public.v_customers_secure
CREATE OR REPLACE VIEW public.v_customers_secure
WITH (security_invoker = true) AS
SELECT
  c.id,
  c.business_id,
  c.customer_number,
  c.full_name,
  c.phone,
  c.email,
  c.address,
  app_private.sec_customer_tax_id(c.business_id, c.id) AS tax_id,
  app_private.sec_customer_credit_limit(c.business_id, c.id) AS credit_limit,
  c.status,
  c.notes,
  c.created_at,
  c.updated_at,
  c.deleted_at,
  c.metadata
FROM public.customers c;

REVOKE ALL ON public.v_customers_secure FROM PUBLIC, anon;
GRANT SELECT ON public.v_customers_secure TO authenticated;

-- 4.8 public.v_register_shifts_secure
CREATE OR REPLACE VIEW public.v_register_shifts_secure
WITH (security_invoker = true) AS
SELECT
  rs.id,
  rs.business_id,
  rs.branch_id,
  rs.register_id,
  rs.shift_number,
  rs.opened_by,
  rs.opened_at,
  rs.opening_float,
  rs.closed_by,
  rs.closed_at,
  app_private.sec_register_shift_expected_cash(rs.business_id, rs.id) AS expected_cash,
  rs.counted_cash,
  app_private.sec_register_shift_variance(rs.business_id, rs.id) AS variance,
  rs.status,
  rs.notes,
  rs.created_at,
  rs.updated_at
FROM public.register_shifts rs;

REVOKE ALL ON public.v_register_shifts_secure FROM PUBLIC, anon;
GRANT SELECT ON public.v_register_shifts_secure TO authenticated;

-- =============================================================================
-- 5. HARDENED ANALYTICAL VIEWS (NULL MASKING — NEVER COALESCE UNAUTHORIZED TO 0)
-- =============================================================================

-- 5.1 public.v_inventory_stock_valuation
-- Preserves exact view columns from Migration 005 while gating average_unit_cost
-- on 'inventory:cost:view' and total_inventory_value on 'inventory:valuation:view'.
CREATE OR REPLACE VIEW public.v_inventory_stock_valuation
WITH (security_invoker = true) AS
SELECT
  ib.business_id,
  ib.branch_id,
  ib.location_id,
  ib.product_id,
  p.sku,
  p.name AS product_name,
  ib.on_hand_quantity,
  ib.reserved_quantity,
  ib.available_quantity,
  app_private.sec_inventory_average_unit_cost(ib.business_id, ib.id) AS average_unit_cost,
  CASE
    WHEN public.can_view_financial_metric(ib.business_id, 'inventory:valuation:view', ib.branch_id)
      AND public.can_view_financial_metric(ib.business_id, 'inventory:cost:view', ib.branch_id)
    THEN ROUND(ib.on_hand_quantity * app_private.sec_inventory_average_unit_cost(ib.business_id, ib.id), 4)
    ELSE NULL::NUMERIC(15, 4)
  END AS total_inventory_value
FROM public.inventory_balances ib
JOIN public.products p ON ib.product_id = p.id AND ib.business_id = p.business_id
JOIN public.inventory_locations il ON ib.location_id = il.id AND ib.business_id = il.business_id
JOIN public.branches b ON ib.branch_id = b.id AND ib.business_id = b.business_id
WHERE p.deleted_at IS NULL
  AND il.deleted_at IS NULL
  AND b.deleted_at IS NULL;

REVOKE ALL ON public.v_inventory_stock_valuation FROM PUBLIC, anon;
GRANT SELECT ON public.v_inventory_stock_valuation TO authenticated;

-- 5.2 public.v_daily_sales_analytics
-- Uses app_private.sec_sale_item_unit_cost so it does not require direct SELECT on
-- sales_transaction_items.cost_price after 014B revocation, and gates revenue, COGS,
-- gross_profit, and gross_margin_pct independently by their respective permissions.
CREATE OR REPLACE VIEW public.v_daily_sales_analytics
WITH (security_invoker = true) AS
WITH item_cogs_per_txn AS (
  SELECT
    sti.transaction_id,
    SUM(sti.quantity * app_private.sec_sale_item_unit_cost(sti.business_id, sti.id)) AS items_cogs
  FROM public.sales_transaction_items sti
  GROUP BY sti.transaction_id
)
SELECT
  st.business_id,
  st.branch_id,
  (st.occurred_at AT TIME ZONE 'UTC')::date AS sale_date,
  st.currency,
  CASE
    WHEN public.can_view_financial_metric(st.business_id, 'financials:revenue:view', st.branch_id)
    THEN SUM(st.subtotal)
    ELSE NULL::NUMERIC(15, 4)
  END AS gross_merchandise_value,
  CASE
    WHEN public.can_view_financial_metric(st.business_id, 'financials:revenue:view', st.branch_id)
    THEN SUM(st.discount_total)
    ELSE NULL::NUMERIC(15, 4)
  END AS discounts_total,
  CASE
    WHEN public.can_view_financial_metric(st.business_id, 'financials:revenue:view', st.branch_id)
    THEN SUM(st.subtotal - st.discount_total)
    ELSE NULL::NUMERIC(15, 4)
  END AS net_sales,
  CASE
    WHEN public.can_view_financial_metric(st.business_id, 'financials:revenue:view', st.branch_id)
    THEN SUM(st.tax_total)
    ELSE NULL::NUMERIC(15, 4)
  END AS sales_tax_collected,
  CASE
    WHEN public.can_view_financial_metric(st.business_id, 'inventory:cost:view', st.branch_id)
    THEN COALESCE(SUM(ic.items_cogs), 0.0000)
    ELSE NULL::NUMERIC(15, 4)
  END AS cogs,
  CASE
    WHEN public.can_view_financial_metric(st.business_id, 'financials:gross_profit:view', st.branch_id)
      AND public.can_view_financial_metric(st.business_id, 'inventory:cost:view', st.branch_id)
      AND public.can_view_financial_metric(st.business_id, 'financials:revenue:view', st.branch_id)
    THEN SUM(st.subtotal - st.discount_total) - COALESCE(SUM(ic.items_cogs), 0.0000)
    ELSE NULL::NUMERIC(15, 4)
  END AS gross_profit,
  CASE
    WHEN public.can_view_financial_metric(st.business_id, 'inventory:margin:view', st.branch_id)
      AND public.can_view_financial_metric(st.business_id, 'financials:gross_profit:view', st.branch_id)
      AND public.can_view_financial_metric(st.business_id, 'inventory:cost:view', st.branch_id)
      AND public.can_view_financial_metric(st.business_id, 'financials:revenue:view', st.branch_id)
    THEN
      CASE
        WHEN SUM(st.subtotal - st.discount_total) > 0 THEN
          ROUND(
            ((SUM(st.subtotal - st.discount_total) - COALESCE(SUM(ic.items_cogs), 0.0000)) / SUM(st.subtotal - st.discount_total)) * 100.0,
            4
          )
        ELSE 0.0000
      END
    ELSE NULL::NUMERIC(15, 4)
  END AS gross_margin_pct,
  COUNT(st.id) AS transaction_count,
  CASE
    WHEN public.can_view_financial_metric(st.business_id, 'financials:revenue:view', st.branch_id)
    THEN
      CASE
        WHEN COUNT(st.id) > 0 THEN
          ROUND(SUM(st.subtotal - st.discount_total) / COUNT(st.id), 4)
        ELSE 0.0000
      END
    ELSE NULL::NUMERIC(15, 4)
  END AS average_ticket
FROM public.sales_transactions st
LEFT JOIN item_cogs_per_txn ic ON st.id = ic.transaction_id
WHERE st.status IN ('pending_payment', 'partially_paid', 'completed')
GROUP BY st.business_id, st.branch_id, (st.occurred_at AT TIME ZONE 'UTC')::date, st.currency;

REVOKE ALL ON public.v_daily_sales_analytics FROM PUBLIC, anon;
GRANT SELECT ON public.v_daily_sales_analytics TO authenticated;

-- 5.3 public.v_customer_receivables
-- Masks credit_limit unless caller holds customers:credit_limit:view,
-- total_invoiced / total_paid unless caller holds customers:sales_amount:view,
-- and total_outstanding_balance unless caller holds customers:credit_balance:view.
CREATE OR REPLACE VIEW public.v_customer_receivables
WITH (security_invoker = true) AS
SELECT
  c.business_id,
  c.id AS customer_id,
  c.customer_number,
  c.full_name,
  app_private.sec_customer_credit_limit(c.business_id, c.id) AS credit_limit,
  c.currency_ref,
  CASE
    WHEN public.can_view_financial_metric(c.business_id, 'customers:sales_amount:view', NULL)
    THEN COALESCE(st.total_invoiced, 0.0000)
    ELSE NULL::NUMERIC(15, 4)
  END AS total_invoiced,
  CASE
    WHEN public.can_view_financial_metric(c.business_id, 'customers:sales_amount:view', NULL)
    THEN COALESCE(st.total_paid, 0.0000)
    ELSE NULL::NUMERIC(15, 4)
  END AS total_paid,
  CASE
    WHEN public.can_view_financial_metric(c.business_id, 'customers:credit_balance:view', NULL)
    THEN COALESCE(st.total_outstanding, 0.0000)
    ELSE NULL::NUMERIC(15, 4)
  END AS total_outstanding_balance,
  CASE
    WHEN public.can_view_financial_metric(c.business_id, 'customers:credit_balance:view', NULL)
    THEN st.oldest_open_invoice_date
    ELSE NULL::TIMESTAMPTZ
  END AS oldest_open_invoice_date
FROM (
  SELECT
    cust.business_id,
    cust.id,
    cust.customer_number,
    cust.full_name,
    b.currency AS currency_ref
  FROM public.customers cust
  JOIN public.businesses b ON cust.business_id = b.id
  WHERE cust.deleted_at IS NULL
) c
LEFT JOIN (
  SELECT
    customer_id,
    business_id,
    SUM(total_amount) AS total_invoiced,
    SUM(amount_paid) AS total_paid,
    SUM(balance_due) AS total_outstanding,
    MIN(occurred_at) FILTER (WHERE balance_due > 0) AS oldest_open_invoice_date
  FROM public.sales_transactions
  WHERE status IN ('pending_payment', 'partially_paid', 'completed')
  GROUP BY customer_id, business_id
) st ON c.id = st.customer_id AND c.business_id = st.business_id;

REVOKE ALL ON public.v_customer_receivables FROM PUBLIC, anon;
GRANT SELECT ON public.v_customer_receivables TO authenticated;

-- 5.4 public.v_cash_register_balances
-- Masks current_cash_on_hand unless caller holds treasury:balance:view (or is owner).
CREATE OR REPLACE VIEW public.v_cash_register_balances
WITH (security_invoker = true) AS
SELECT
  ct.business_id,
  ct.branch_id,
  ct.register_id,
  ct.currency,
  CASE
    WHEN public.can_view_financial_metric(ct.business_id, 'treasury:balance:view', ct.branch_id)
    THEN COALESCE(SUM(CASE WHEN ct.direction = 'in' THEN ct.amount ELSE -ct.amount END), 0.0000)
    ELSE NULL::NUMERIC(15, 4)
  END AS current_cash_on_hand,
  MAX(ct.occurred_at) AS last_cash_movement_at
FROM public.cash_transactions ct
GROUP BY ct.business_id, ct.branch_id, ct.register_id, ct.currency;

REVOKE ALL ON public.v_cash_register_balances FROM PUBLIC, anon;
GRANT SELECT ON public.v_cash_register_balances TO authenticated;

-- 5.5 public.v_bank_account_balances
-- Upgrades Migration 013 view to use scope-aware public.can_view_financial_metric
-- with 'treasury:balance:view' (enterprise-level NULL branch scope).
CREATE OR REPLACE VIEW public.v_bank_account_balances
WITH (security_invoker = true) AS
SELECT
  ba.business_id,
  ba.id AS bank_account_id,
  ba.account_name,
  ba.bank_name,
  ba.account_number_masked,
  ba.currency,
  ba.status,
  CASE
    WHEN public.can_view_financial_metric(ba.business_id, 'treasury:balance:view', NULL)
    THEN COALESCE(SUM(CASE WHEN bt.direction = 'credit' THEN bt.amount ELSE -bt.amount END), 0.0000)
    ELSE NULL::NUMERIC(15, 4)
  END AS calculated_balance,
  MAX(bt.occurred_at) AS last_activity_at
FROM public.bank_accounts ba
LEFT JOIN public.bank_transactions bt ON ba.id = bt.bank_account_id AND ba.business_id = bt.business_id
WHERE ba.deleted_at IS NULL
GROUP BY ba.business_id, ba.id, ba.account_name, ba.bank_name, ba.account_number_masked, ba.currency, ba.status;

REVOKE ALL ON public.v_bank_account_balances FROM PUBLIC, anon;
GRANT SELECT ON public.v_bank_account_balances TO authenticated;

-- 5.6 public.v_authoritative_financial_account_balances
-- Upgrades Migration 013 view to enforce branch-scope-aware 'treasury:balance:view'
-- on cash vaults (v.branch_id) and petty cash boxes (pca.branch_id) and enterprise
-- scope on bank accounts and mobile money wallets.
CREATE OR REPLACE VIEW public.v_authoritative_financial_account_balances
WITH (security_invoker = true) AS
SELECT
  ba.id AS account_id,
  ba.business_id,
  'bank'::TEXT AS account_type,
  ba.account_name AS account_name,
  'Bank: ' || ba.bank_name || ' (' || ba.account_number_masked || ')' AS display_label,
  ba.currency,
  ba.status,
  CASE
    WHEN public.can_view_financial_metric(ba.business_id, 'treasury:balance:view', NULL)
    THEN COALESCE(SUM(CASE WHEN bt.direction = 'credit' THEN bt.amount ELSE -bt.amount END), 0.0000)
    ELSE NULL::NUMERIC(15, 4)
  END AS cleared_balance,
  0.0000 AS daily_limit,
  NULL::TEXT AS provider,
  NOW() AS as_of_time
FROM public.bank_accounts ba
LEFT JOIN public.bank_transactions bt ON bt.business_id = ba.business_id AND bt.bank_account_id = ba.id
WHERE ba.deleted_at IS NULL
GROUP BY ba.id, ba.business_id, ba.account_name, ba.bank_name, ba.account_number_masked, ba.currency, ba.status

UNION ALL

SELECT
  v.id AS account_id,
  v.business_id,
  'business_cash'::TEXT AS account_type,
  v.vault_name AS account_name,
  'Cash Vault: ' || v.vault_name || ' [' || v.vault_code || ']' AS display_label,
  v.currency,
  v.status,
  CASE
    WHEN public.can_view_financial_metric(v.business_id, 'treasury:balance:view', v.branch_id)
    THEN COALESCE(SUM(CASE WHEN vt.direction = 'in' THEN vt.amount ELSE -vt.amount END), 0.0000)
    ELSE NULL::NUMERIC(15, 4)
  END AS cleared_balance,
  0.0000 AS daily_limit,
  NULL::TEXT AS provider,
  NOW() AS as_of_time
FROM public.business_cash_vaults v
LEFT JOIN public.vault_transactions vt ON vt.business_id = v.business_id AND vt.vault_id = v.id
WHERE v.deleted_at IS NULL
GROUP BY v.id, v.business_id, v.branch_id, v.vault_name, v.vault_code, v.currency, v.status

UNION ALL

SELECT
  pca.id AS account_id,
  pca.business_id,
  'petty_cash'::TEXT AS account_type,
  pca.box_name AS account_name,
  'Petty Cash: ' || pca.box_name || ' [' || pca.box_code || ']' AS display_label,
  pca.currency,
  pca.status,
  CASE
    WHEN public.can_view_financial_metric(pca.business_id, 'treasury:balance:view', pca.branch_id)
    THEN COALESCE(SUM(CASE WHEN pct.direction = 'in' THEN pct.amount ELSE -pct.amount END), 0.0000)
    ELSE NULL::NUMERIC(15, 4)
  END AS cleared_balance,
  pca.max_float_limit AS daily_limit,
  NULL::TEXT AS provider,
  NOW() AS as_of_time
FROM public.petty_cash_accounts pca
LEFT JOIN public.petty_cash_transactions pct ON pct.business_id = pca.business_id AND pct.petty_cash_account_id = pca.id
WHERE pca.deleted_at IS NULL
GROUP BY pca.id, pca.business_id, pca.branch_id, pca.box_name, pca.box_code, pca.currency, pca.status, pca.max_float_limit

UNION ALL

SELECT
  w.id AS account_id,
  w.business_id,
  LOWER(w.provider)::TEXT AS account_type,
  w.account_name AS account_name,
  w.provider || ': ' || w.account_name || ' (***' || RIGHT(w.phone_number, 4) || ')' AS display_label,
  w.currency,
  w.status,
  CASE
    WHEN public.can_view_financial_metric(w.business_id, 'treasury:balance:view', NULL)
    THEN COALESCE(SUM(CASE WHEN mmt.direction = 'in' THEN mmt.amount ELSE -(mmt.amount + mmt.fee_amount) END), 0.0000)
    ELSE NULL::NUMERIC(15, 4)
  END AS cleared_balance,
  w.daily_disbursement_limit AS daily_limit,
  w.provider AS provider,
  NOW() AS as_of_time
FROM public.mobile_money_wallets w
LEFT JOIN public.mobile_money_transactions mmt ON mmt.business_id = w.business_id AND mmt.wallet_id = w.id
WHERE w.deleted_at IS NULL
GROUP BY w.id, w.business_id, w.provider, w.account_name, w.phone_number, w.currency, w.status, w.daily_disbursement_limit;

REVOKE ALL ON public.v_authoritative_financial_account_balances FROM PUBLIC, anon;
GRANT SELECT ON public.v_authoritative_financial_account_balances TO authenticated;

-- =============================================================================
-- 6. HARDENED EXECUTIVE DASHBOARD RPC: public.rpc_get_operational_dashboard_metrics
-- =============================================================================
-- Enforces granular per-KPI financial visibility via public.can_view_financial_metric
-- while preserving operational count visibility (transaction_count, active_sku_count,
-- open_shift_count) for operational roles. Never coerces unauthorized NULL to 0.

CREATE OR REPLACE FUNCTION public.rpc_get_operational_dashboard_metrics(
  p_business_id UUID,
  p_branch_id UUID DEFAULT NULL,
  p_start_date TIMESTAMPTZ DEFAULT (CURRENT_DATE - INTERVAL '30 days'),
  p_end_date TIMESTAMPTZ DEFAULT NOW()
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
  v_is_owner BOOLEAN := FALSE;

  -- Operational count permissions
  v_can_view_sales_ops BOOLEAN := FALSE;
  v_can_view_inventory_qty BOOLEAN := FALSE;
  v_can_view_registers BOOLEAN := FALSE;

  -- Granular financial metric permissions (Phase S3-B1)
  v_can_view_revenue BOOLEAN := FALSE;
  v_can_view_cogs BOOLEAN := FALSE;
  v_can_view_gross_profit BOOLEAN := FALSE;
  v_can_view_margin BOOLEAN := FALSE;
  v_can_view_inventory_val BOOLEAN := FALSE;
  v_can_view_treasury_bal BOOLEAN := FALSE;
  v_can_view_receivables BOOLEAN := FALSE;
  v_can_view_expenses BOOLEAN := FALSE;

  -- Date Bounds Temp
  v_tmp_date TIMESTAMPTZ;

  -- Raw computed sales aggregates
  v_raw_gmv NUMERIC(15, 4);
  v_raw_discounts NUMERIC(15, 4);
  v_raw_net_sales NUMERIC(15, 4);
  v_raw_tax_collected NUMERIC(15, 4);
  v_raw_cogs NUMERIC(15, 4);

  -- Output KPIs (NULL when unauthorized)
  v_gmv NUMERIC(15, 4) := NULL;
  v_discounts NUMERIC(15, 4) := NULL;
  v_net_sales NUMERIC(15, 4) := NULL;
  v_tax_collected NUMERIC(15, 4) := NULL;
  v_cogs NUMERIC(15, 4) := NULL;
  v_gross_profit NUMERIC(15, 4) := NULL;
  v_gross_margin_pct NUMERIC(15, 4) := NULL;
  v_txn_count BIGINT := NULL;
  v_avg_ticket NUMERIC(15, 4) := NULL;

  v_inventory_val NUMERIC(15, 4) := NULL;
  v_active_skus BIGINT := NULL;

  v_open_shifts BIGINT := NULL;
  v_cash_on_hand NUMERIC(15, 4) := NULL;
  v_bank_balance NUMERIC(15, 4) := NULL;

  v_receivables NUMERIC(15, 4) := NULL;
  v_pending_expenses NUMERIC(15, 4) := NULL;
  v_paid_expenses NUMERIC(15, 4) := NULL;
BEGIN
  -- 1. Caller Authentication
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'INVALID_ARGUMENT: business_id is required';
  END IF;

  -- 2. Business Tenancy & Currency
  SELECT currency INTO v_biz_currency
  FROM public.businesses
  WHERE id = p_business_id AND status = 'active' AND deleted_at IS NULL;

  IF v_biz_currency IS NULL THEN
    RAISE EXCEPTION 'INVALID_BUSINESS: Business % does not exist or is inactive', p_business_id;
  END IF;

  -- 3. Membership & Branch Scope Verification
  v_is_owner := public.is_business_owner(p_business_id);

  IF NOT v_is_owner THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.business_memberships
      WHERE business_id = p_business_id AND user_id = v_caller_id AND status = 'active'
    ) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: Caller % is not an active member of business %',
        v_caller_id, p_business_id;
    END IF;
  END IF;

  IF p_branch_id IS NOT NULL THEN
    SELECT is_active INTO v_branch_active
    FROM public.branches
    WHERE id = p_branch_id AND business_id = p_business_id AND deleted_at IS NULL;

    IF v_branch_active IS NULL OR NOT v_branch_active THEN
      RAISE EXCEPTION 'INVALID_BRANCH: Branch % does not exist or is inactive in business %',
        p_branch_id, p_business_id;
    END IF;
  END IF;

  -- 4. Operational Count Permissions vs. Financial Metric Permissions
  v_can_view_sales_ops := v_is_owner
    OR public.has_permission_in_scope(p_business_id, 'reports:view_operational', p_branch_id)
    OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', p_branch_id)
    OR public.has_permission_in_scope(p_business_id, 'sales:view', p_branch_id);

  v_can_view_inventory_qty := v_is_owner
    OR public.has_permission_in_scope(p_business_id, 'reports:view_operational', p_branch_id)
    OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', p_branch_id)
    OR public.has_permission_in_scope(p_business_id, 'inventory:view', p_branch_id);

  v_can_view_registers := v_is_owner
    OR public.has_permission_in_scope(p_business_id, 'reports:view_operational', p_branch_id)
    OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', p_branch_id)
    OR public.has_permission_in_scope(p_business_id, 'registers:view', p_branch_id);

  v_can_view_revenue := public.can_view_financial_metric(p_business_id, 'financials:revenue:view', p_branch_id);
  v_can_view_cogs := public.can_view_financial_metric(p_business_id, 'inventory:cost:view', p_branch_id);
  v_can_view_gross_profit := public.can_view_financial_metric(p_business_id, 'financials:gross_profit:view', p_branch_id);
  v_can_view_margin := public.can_view_financial_metric(p_business_id, 'inventory:margin:view', p_branch_id);
  v_can_view_inventory_val := public.can_view_financial_metric(p_business_id, 'inventory:valuation:view', p_branch_id);
  v_can_view_treasury_bal := public.can_view_financial_metric(p_business_id, 'treasury:balance:view', p_branch_id);
  v_can_view_receivables := public.can_view_financial_metric(p_business_id, 'customers:credit_balance:view', p_branch_id);
  v_can_view_expenses := public.can_view_financial_metric(p_business_id, 'financials:expenses:view', p_branch_id);

  IF NOT (
    v_can_view_sales_ops
    OR v_can_view_inventory_qty
    OR v_can_view_registers
    OR v_can_view_revenue
    OR v_can_view_cogs
    OR v_can_view_gross_profit
    OR v_can_view_margin
    OR v_can_view_inventory_val
    OR v_can_view_treasury_bal
    OR v_can_view_receivables
    OR v_can_view_expenses
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks reporting permissions in scope for business %',
      v_caller_id, p_business_id;
  END IF;

  -- 5. Date Bounds Sanity Check
  IF p_start_date > p_end_date THEN
    v_tmp_date := p_start_date;
    p_start_date := p_end_date;
    p_end_date := v_tmp_date;
  END IF;

  -- 6. Sales, Revenue, COGS & Profit Evaluation
  IF v_can_view_sales_ops OR v_can_view_revenue OR v_can_view_cogs OR v_can_view_gross_profit OR v_can_view_margin THEN
    WITH txn_cogs AS (
      SELECT
        sti.transaction_id,
        SUM(sti.quantity * sti.cost_price) AS cogs
      FROM public.sales_transaction_items sti
      WHERE sti.business_id = p_business_id
      GROUP BY sti.transaction_id
    )
    SELECT
      COALESCE(SUM(st.subtotal), 0.0000),
      COALESCE(SUM(st.discount_total), 0.0000),
      COALESCE(SUM(st.subtotal - st.discount_total), 0.0000),
      COALESCE(SUM(st.tax_total), 0.0000),
      COALESCE(SUM(tc.cogs), 0.0000),
      COUNT(st.id)
    INTO
      v_raw_gmv, v_raw_discounts, v_raw_net_sales, v_raw_tax_collected, v_raw_cogs, v_txn_count
    FROM public.sales_transactions st
    LEFT JOIN txn_cogs tc ON st.id = tc.transaction_id
    WHERE st.business_id = p_business_id
      AND (p_branch_id IS NULL OR st.branch_id = p_branch_id)
      AND st.occurred_at >= p_start_date
      AND st.occurred_at <= p_end_date
      AND st.status IN ('pending_payment', 'partially_paid', 'completed');

    IF v_can_view_revenue THEN
      v_gmv := v_raw_gmv;
      v_discounts := v_raw_discounts;
      v_net_sales := v_raw_net_sales;
      v_tax_collected := v_raw_tax_collected;
      IF v_txn_count > 0 THEN
        v_avg_ticket := ROUND(v_raw_net_sales / v_txn_count, 4);
      ELSE
        v_avg_ticket := 0.0000;
      END IF;
    END IF;

    IF v_can_view_cogs THEN
      v_cogs := v_raw_cogs;
    END IF;

    IF v_can_view_gross_profit AND v_can_view_cogs AND v_can_view_revenue THEN
      v_gross_profit := v_raw_net_sales - v_raw_cogs;
    END IF;

    IF v_can_view_margin AND v_can_view_gross_profit AND v_can_view_cogs AND v_can_view_revenue THEN
      IF v_raw_net_sales > 0 THEN
        v_gross_margin_pct := ROUND(((v_raw_net_sales - v_raw_cogs) / v_raw_net_sales) * 100.0, 4);
      ELSE
        v_gross_margin_pct := 0.0000;
      END IF;
    END IF;
  END IF;

  -- 7. Inventory Valuation & Active SKU Count
  IF v_can_view_inventory_val AND v_can_view_cogs THEN
    SELECT COALESCE(SUM(ROUND(ib.on_hand_quantity * ib.average_unit_cost, 4)), 0.0000)
    INTO v_inventory_val
    FROM public.inventory_balances ib
    JOIN public.products p ON ib.product_id = p.id AND ib.business_id = p.business_id
    JOIN public.inventory_locations il ON ib.location_id = il.id AND ib.business_id = il.business_id
    JOIN public.branches b ON ib.branch_id = b.id AND ib.business_id = b.business_id
    WHERE ib.business_id = p_business_id
      AND (p_branch_id IS NULL OR ib.branch_id = p_branch_id)
      AND p.deleted_at IS NULL
      AND il.deleted_at IS NULL
      AND b.deleted_at IS NULL;
  END IF;

  IF v_can_view_inventory_qty THEN
    SELECT COUNT(DISTINCT ib.product_id)
    INTO v_active_skus
    FROM public.inventory_balances ib
    JOIN public.products p ON ib.product_id = p.id AND ib.business_id = p.business_id
    JOIN public.inventory_locations il ON ib.location_id = il.id AND ib.business_id = il.business_id
    JOIN public.branches b ON ib.branch_id = b.id AND ib.business_id = b.business_id
    WHERE ib.business_id = p_business_id
      AND (p_branch_id IS NULL OR ib.branch_id = p_branch_id)
      AND p.deleted_at IS NULL
      AND il.deleted_at IS NULL
      AND b.deleted_at IS NULL;
  END IF;

  -- 8. Register Shifts & Treasury Balances
  IF v_can_view_registers THEN
    SELECT COUNT(*)
    INTO v_open_shifts
    FROM public.register_shifts
    WHERE business_id = p_business_id
      AND (p_branch_id IS NULL OR branch_id = p_branch_id)
      AND status = 'open';
  END IF;

  IF v_can_view_treasury_bal THEN
    SELECT COALESCE(SUM(CASE WHEN ct.direction = 'in' THEN ct.amount ELSE -ct.amount END), 0.0000)
    INTO v_cash_on_hand
    FROM public.cash_transactions ct
    WHERE ct.business_id = p_business_id
      AND (p_branch_id IS NULL OR ct.branch_id = p_branch_id);

    IF p_branch_id IS NULL THEN
      SELECT COALESCE(SUM(CASE WHEN bt.direction = 'credit' THEN bt.amount ELSE -bt.amount END), 0.0000)
      INTO v_bank_balance
      FROM public.bank_accounts ba
      LEFT JOIN public.bank_transactions bt ON ba.id = bt.bank_account_id AND ba.business_id = bt.business_id
      WHERE ba.business_id = p_business_id
        AND ba.deleted_at IS NULL;
    ELSE
      v_bank_balance := NULL;
    END IF;
  END IF;

  -- 9. Outstanding Customer Receivables
  IF v_can_view_receivables THEN
    SELECT COALESCE(SUM(balance_due), 0.0000)
    INTO v_receivables
    FROM public.sales_transactions
    WHERE business_id = p_business_id
      AND (p_branch_id IS NULL OR branch_id = p_branch_id)
      AND balance_due > 0
      AND status IN ('pending_payment', 'partially_paid');
  END IF;

  -- 10. Operational Expenses
  IF v_can_view_expenses THEN
    SELECT
      COALESCE(SUM(amount) FILTER (WHERE status IN ('draft', 'pending_approval')), 0.0000),
      COALESCE(SUM(amount) FILTER (WHERE status = 'paid' AND expense_date >= p_start_date::date AND expense_date <= p_end_date::date), 0.0000)
    INTO
      v_pending_expenses, v_paid_expenses
    FROM public.expenses
    WHERE business_id = p_business_id
      AND (p_branch_id IS NULL OR branch_id = p_branch_id)
      AND deleted_at IS NULL;
  END IF;

  RETURN jsonb_build_object(
    'currency', v_biz_currency,
    'start_date', p_start_date,
    'end_date', p_end_date,
    'branch_id', p_branch_id,
    'gross_merchandise_value', v_gmv,
    'discounts_total', v_discounts,
    'net_sales', v_net_sales,
    'sales_tax_collected', v_tax_collected,
    'cogs', v_cogs,
    'gross_profit', v_gross_profit,
    'gross_margin_pct', v_gross_margin_pct,
    'transaction_count', v_txn_count,
    'average_ticket', v_avg_ticket,
    'inventory_value', v_inventory_val,
    'active_sku_count', v_active_skus,
    'open_shift_count', v_open_shifts,
    'cash_on_hand', v_cash_on_hand,
    'enterprise_bank_balance', v_bank_balance,
    'bank_balance', v_bank_balance,
    'outstanding_receivables', v_receivables,
    'pending_expense_amount', v_pending_expenses,
    'paid_expense_amount', v_paid_expenses
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_get_operational_dashboard_metrics(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_operational_dashboard_metrics(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;

-- =============================================================================
-- 7. SINGLE-TRANSACTION POS RECEIPT RPC: public.get_pos_sale_receipt
-- =============================================================================
-- Allows POS cashiers, salespersons, and refund supervisors to fetch a single
-- sale receipt by UUID (header, non-cost line items, and payments) without
-- requiring unrestricted bulk SELECT on historical sales_transactions.
-- Line-item cost_price is masked to NULL unless caller holds inventory:cost:view.

CREATE OR REPLACE FUNCTION public.get_pos_sale_receipt(
  p_business_id UUID,
  p_sale_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_sale RECORD;
  v_items JSONB;
  v_payments JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_business_id IS NULL OR p_sale_id IS NULL THEN
    RAISE EXCEPTION 'INVALID_ARGUMENT: business_id and sale_id are required';
  END IF;

  SELECT *
  INTO v_sale
  FROM public.sales_transactions st
  WHERE st.id = p_sale_id
    AND st.business_id = p_business_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Verify active business membership and branch access
  IF NOT (
    public.is_business_owner(p_business_id)
    OR (
      EXISTS (
        SELECT 1 FROM public.business_memberships bm
        WHERE bm.business_id = p_business_id
          AND bm.user_id = v_caller_id
          AND bm.status = 'active'
      )
      AND (
        v_sale.cashier_user_id = v_caller_id
        OR public.has_permission_in_scope(p_business_id, 'sales:view', v_sale.branch_id)
        OR public.has_permission_in_scope(p_business_id, 'sales:refund', v_sale.branch_id)
        OR public.has_permission_in_scope(p_business_id, 'sales:void', v_sale.branch_id)
        OR public.can_view_financial_metric(p_business_id, 'financials:revenue:view', v_sale.branch_id)
        OR public.can_view_financial_metric(p_business_id, 'customers:sales_amount:view', v_sale.branch_id)
      )
    )
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % is not authorized to view receipt %', v_caller_id, p_sale_id;
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', sti.id,
        'business_id', sti.business_id,
        'transaction_id', sti.transaction_id,
        'product_id', sti.product_id,
        'inventory_location_id', sti.inventory_location_id,
        'salesperson_user_id', sti.salesperson_user_id,
        'quantity', sti.quantity,
        'unit_price', sti.unit_price,
        'discount_amount', sti.discount_amount,
        'tax_amount', sti.tax_amount,
        'line_total', sti.line_total,
        'notes', sti.notes,
        'created_at', sti.created_at
      )
      ORDER BY sti.created_at ASC, sti.id ASC
    ),
    '[]'::jsonb
  )
  INTO v_items
  FROM public.sales_transaction_items sti
  WHERE sti.transaction_id = v_sale.id
    AND sti.business_id = p_business_id;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', p.id,
        'business_id', p.business_id,
        'branch_id', p.branch_id,
        'transaction_id', p.transaction_id,
        'payment_number', p.payment_number,
        'payment_method', p.payment_method,
        'amount', p.amount,
        'currency', p.currency,
        'bank_account_id', p.bank_account_id,
        'register_id', p.register_id,
        'shift_id', p.shift_id,
        'reference_number', p.reference_number,
        'status', p.status,
        'received_by', p.received_by,
        'occurred_at', p.occurred_at,
        'created_at', p.created_at
      )
      ORDER BY p.occurred_at ASC, p.id ASC
    ),
    '[]'::jsonb
  )
  INTO v_payments
  FROM public.payments p
  WHERE p.transaction_id = v_sale.id
    AND p.business_id = p_business_id;

  RETURN jsonb_build_object(
    'id', v_sale.id,
    'business_id', v_sale.business_id,
    'branch_id', v_sale.branch_id,
    'register_id', v_sale.register_id,
    'shift_id', v_sale.shift_id,
    'cashier_user_id', v_sale.cashier_user_id,
    'salesperson_user_id', v_sale.salesperson_user_id,
    'customer_id', v_sale.customer_id,
    'transaction_number', v_sale.transaction_number,
    'transaction_type', v_sale.transaction_type,
    'status', v_sale.status,
    'subtotal', v_sale.subtotal,
    'discount_total', v_sale.discount_total,
    'tax_total', v_sale.tax_total,
    'total_amount', v_sale.total_amount,
    'amount_paid', v_sale.amount_paid,
    'balance_due', v_sale.balance_due,
    'currency', v_sale.currency,
    'notes', v_sale.notes,
    'occurred_at', v_sale.occurred_at,
    'created_at', v_sale.created_at,
    'updated_at', v_sale.updated_at,
    'metadata', v_sale.metadata,
    'items', v_items,
    'payments', v_payments
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_pos_sale_receipt(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_pos_sale_receipt(UUID, UUID) TO authenticated;

-- =============================================================================
-- 8. BLIND CASH CLOSE RPC & IDEMPOTENCY REPLAY HARDENING:
--    public.rpc_close_register_shift
-- =============================================================================
-- Remediates Migration 010 leak where rpc_close_register_shift returned
-- expected_cash and variance unconditionally and persisted them in
-- public.idempotency_records.response_payload.

DROP FUNCTION IF EXISTS public.rpc_close_register_shift(UUID, UUID, NUMERIC, TEXT);

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
  v_closed_at TIMESTAMPTZ;
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_idem_res JSONB;
  v_idem_payload JSONB;
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
    -- Re-evaluate expected_cash and variance visibility dynamically on replay
    RETURN (v_idem_res->'payload') || jsonb_build_object(
      'expected_cash', app_private.sec_register_shift_expected_cash(p_business_id, p_shift_id),
      'variance', app_private.sec_register_shift_variance(p_business_id, p_shift_id),
      'is_replay', true
    );
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

  v_expected_cash := v_cash_in - v_cash_out;
  v_variance := p_counted_cash - v_expected_cash;
  v_closed_at := NOW();

  UPDATE public.register_shifts
  SET
    status = 'closed',
    closed_by = v_caller_id,
    closed_at = v_closed_at,
    counted_cash = p_counted_cash,
    expected_cash = v_expected_cash,
    variance = v_variance,
    notes = CASE WHEN p_notes IS NOT NULL THEN COALESCE(notes || E'\n' || p_notes, p_notes) ELSE notes END,
    updated_at = v_closed_at
  WHERE id = p_shift_id;

  -- Store only non-sensitive confirmation fields in idempotency_records
  v_idem_payload := jsonb_build_object(
    'success', true,
    'shift_id', p_shift_id,
    'shift_number', v_shift.shift_number,
    'status', 'closed',
    'counted_cash', p_counted_cash,
    'closed_at', v_closed_at
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_idem_payload);

  v_result := v_idem_payload || jsonb_build_object(
    'expected_cash', CASE
      WHEN public.can_view_financial_metric(p_business_id, 'cash_verification:expected_cash:view', v_shift.branch_id)
      THEN v_expected_cash
      ELSE NULL::NUMERIC(15, 4)
    END,
    'variance', CASE
      WHEN public.can_view_financial_metric(p_business_id, 'cash_verification:variance:view', v_shift.branch_id)
      THEN v_variance
      ELSE NULL::NUMERIC(15, 4)
    END,
    'is_replay', false
  );

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_close_register_shift(UUID, UUID, NUMERIC, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_close_register_shift(UUID, UUID, NUMERIC, UUID, TEXT) TO authenticated;

-- =============================================================================
-- 9. INVENTORY TRANSFER DISPATCH & RECEIVE RPC COST REDACTION:
--    public.rpc_dispatch_inventory_transfer & public.rpc_receive_inventory_transfer
-- =============================================================================
-- Remediates Migration 008/010 leak where rpc_dispatch_inventory_transfer and
-- rpc_receive_inventory_transfer returned unit_cost_at_dispatch unconditionally
-- in the items array of the JSONB receipt.

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
  v_can_view_cost BOOLEAN := FALSE;
  v_dispatched_items JSONB := '[]'::jsonb;
  v_result JSONB;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for dispatch.';
  END IF;

  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: Active authenticated session required to dispatch transfer.';
  END IF;

  SELECT * INTO v_transfer
  FROM public.inventory_transfers
  WHERE id = p_transfer_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TRANSFER_NOT_FOUND: Transfer % does not exist in business %', p_transfer_id, p_business_id;
  END IF;

  IF v_transfer.status = 'in_transit' THEN
    IF v_transfer.dispatch_idempotency_key = p_idempotency_key THEN
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

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(p_business_id, 'inventory:transfer', v_transfer.from_branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks inventory:transfer on origin branch %', v_caller_id, v_transfer.from_branch_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.inventory_transfer_items
    WHERE transfer_id = p_transfer_id
  ) THEN
    RAISE EXCEPTION 'NO_ITEMS: Transfer % has no line items to dispatch.', p_transfer_id;
  END IF;

  v_can_view_cost := public.can_view_financial_metric(p_business_id, 'inventory:cost:view', v_transfer.from_branch_id);

  FOR v_item IN
    SELECT ti.*
    FROM public.inventory_transfer_items ti
    WHERE ti.transfer_id = p_transfer_id
    ORDER BY ti.product_id ASC
  LOOP
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

    v_avail_qty := v_bal.on_hand_quantity - v_bal.reserved_quantity;
    IF v_item.quantity_requested > v_avail_qty THEN
      RAISE EXCEPTION 'INSUFFICIENT_AVAILABLE_STOCK: Product % requires % units, but only % available (on_hand: %, reserved: %)',
        v_item.product_id, v_item.quantity_requested, v_avail_qty, v_bal.on_hand_quantity, v_bal.reserved_quantity;
    END IF;

    UPDATE public.inventory_transfer_items
    SET
      quantity_shipped = v_item.quantity_requested,
      unit_cost_at_dispatch = COALESCE(v_bal.average_unit_cost, 0.0000)
    WHERE id = v_item.id;

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
      'unit_cost_at_dispatch', CASE
        WHEN v_can_view_cost THEN COALESCE(v_bal.average_unit_cost, 0.0000)
        ELSE NULL::NUMERIC(15, 4)
      END
    );
  END LOOP;

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
  v_can_view_cost BOOLEAN := FALSE;
  v_received_items JSONB := '[]'::jsonb;
  v_result JSONB;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for receive.';
  END IF;

  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: Active authenticated session required to receive transfer.';
  END IF;

  SELECT * INTO v_transfer
  FROM public.inventory_transfers
  WHERE id = p_transfer_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TRANSFER_NOT_FOUND: Transfer % does not exist in business %', p_transfer_id, p_business_id;
  END IF;

  IF v_transfer.status = 'received' THEN
    IF v_transfer.receive_idempotency_key = p_idempotency_key THEN
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

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(p_business_id, 'inventory:transfer', v_transfer.to_branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks inventory:transfer on destination branch %', v_caller_id, v_transfer.to_branch_id;
  END IF;

  v_can_view_cost := public.can_view_financial_metric(p_business_id, 'inventory:cost:view', v_transfer.to_branch_id)
    OR public.can_view_financial_metric(p_business_id, 'inventory:cost:view', v_transfer.from_branch_id);

  FOR v_item IN
    SELECT ti.*
    FROM public.inventory_transfer_items ti
    WHERE ti.transfer_id = p_transfer_id
    ORDER BY ti.product_id ASC
  LOOP
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

    UPDATE public.inventory_transfer_items
    SET quantity_received = v_item.quantity_shipped
    WHERE id = v_item.id;

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
      'unit_cost_at_dispatch', CASE
        WHEN v_can_view_cost THEN v_item.unit_cost_at_dispatch
        ELSE NULL::NUMERIC(15, 4)
      END
    );
  END LOOP;

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

-- =============================================================================
-- 10. INVENTORY MOVEMENT RPC COST & IDEMPOTENCY REDACTION:
--     public.rpc_post_inventory_movement
-- =============================================================================
-- Remediates Migration 010 leak where rpc_post_inventory_movement returned
-- average_unit_cost unconditionally and stored it in idempotency_records.

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
  v_idem_payload JSONB;
  v_raw_result JSONB;
  v_balance_id UUID;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: Authentication required to post inventory movements.';
  END IF;

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
    v_balance_id := NULLIF(v_idem_res->'payload'->>'balance_id', '')::UUID;
    RETURN (v_idem_res->'payload') || jsonb_build_object(
      'average_unit_cost', CASE
        WHEN v_balance_id IS NOT NULL THEN app_private.sec_inventory_average_unit_cost(p_business_id, v_balance_id)
        ELSE NULL::NUMERIC(15, 4)
      END,
      'is_replay', true
    );
  END IF;

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

  v_raw_result := public.fn_post_inventory_movement_internal(
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

  -- Strip average_unit_cost before committing to idempotency_records
  v_idem_payload := v_raw_result - 'average_unit_cost';
  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_idem_payload);

  RETURN v_idem_payload || jsonb_build_object(
    'average_unit_cost', CASE
      WHEN public.can_view_financial_metric(p_business_id, 'inventory:cost:view', p_branch_id)
      THEN (v_raw_result->>'average_unit_cost')::NUMERIC(15, 4)
      ELSE NULL::NUMERIC(15, 4)
    END,
    'is_replay', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_post_inventory_movement(UUID, UUID, UUID, UUID, TEXT, NUMERIC, UUID, NUMERIC, TEXT, UUID, TEXT, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_post_inventory_movement(UUID, UUID, UUID, UUID, TEXT, NUMERIC, UUID, NUMERIC, TEXT, UUID, TEXT, BOOLEAN) TO authenticated;

-- =============================================================================
-- 11. IDEMPOTENCY REPLAY ISOLATION & TREASURY RPC SANITIZATION:
--     public.fn_idempotency_acquire, public.rpc_approve_and_pay_expense,
--     and public.rpc_fund_petty_cash_account
-- =============================================================================

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

  SELECT * INTO v_rec
  FROM public.idempotency_records
  WHERE business_id = p_business_id AND idempotency_key = p_idempotency_key
  FOR UPDATE;

  IF v_rec.operation <> p_operation THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED_ACROSS_OPERATIONS: Key % was registered for % but submitted for %',
      p_idempotency_key, v_rec.operation, p_operation;
  END IF;

  IF v_rec.status = 'committed' THEN
    IF v_rec.request_hash <> p_request_hash THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: Idempotency key % has already been used with different request parameters',
        p_idempotency_key;
    END IF;

    -- Strict actor isolation on replay: only the original actor or business owner may replay
    IF v_rec.user_id <> v_caller_id AND NOT public.is_business_owner(p_business_id) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: Idempotency key belongs to another user.';
    END IF;

    RETURN jsonb_build_object(
      'action', 'replay',
      'payload', COALESCE(v_rec.response_payload, '{}'::jsonb) || jsonb_build_object('is_replay', true)
    );
  END IF;

  IF v_rec.user_id <> v_caller_id THEN
    RAISE EXCEPTION 'USER_MISMATCH: Idempotency record is in progress by another user';
  END IF;

  RETURN jsonb_build_object('action', 'execute');
END;
$$;

REVOKE ALL ON FUNCTION public.fn_idempotency_acquire(UUID, UUID, VARCHAR, VARCHAR, UUID) FROM PUBLIC, anon, authenticated;

-- Fix Migration 013 rpc_approve_and_pay_expense idempotency helper calls
CREATE OR REPLACE FUNCTION public.rpc_approve_and_pay_expense(
  p_business_id UUID,
  p_expense_id UUID,
  p_financial_account_type TEXT,
  p_financial_account_id UUID,
  p_payment_method TEXT,
  p_idempotency_key UUID,
  p_reference_number TEXT DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_recipient_phone TEXT DEFAULT NULL,
  p_fee_amount NUMERIC DEFAULT 0.0000
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_exp RECORD;
  v_vault RECORD;
  v_petty_acc RECORD;
  v_wallet RECORD;
  v_budget RECORD;
  v_available_balance NUMERIC(15, 4);
  v_remaining_budget NUMERIC(15, 4);
  v_today_disbursements NUMERIC(15, 4);
  v_fee_to_charge NUMERIC(15, 4);
  v_biz_timezone TEXT;
  v_tx_id UUID;
  v_idem_res JSONB;
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_approve_and_pay_expense';
  END IF;

  IF p_financial_account_type IS NULL OR p_financial_account_id IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Both financial_account_type and financial_account_id are required to approve and pay an expense';
  END IF;

  IF p_financial_account_type NOT IN ('bank', 'business_cash', 'petty_cash', 'moncash', 'natcash') THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Unsupported financial account type %', p_financial_account_type;
  END IF;

  v_fee_to_charge := COALESCE(p_fee_amount, 0.0000);
  IF v_fee_to_charge < 0 THEN
    RAISE EXCEPTION 'INVALID_FEE_AMOUNT: Fee amount cannot be negative';
  END IF;

  IF p_financial_account_type = 'bank' AND p_payment_method NOT IN ('bank', 'bank_transfer', 'check', 'debit_card', 'credit_card') THEN
    RAISE EXCEPTION 'PAYMENT_METHOD_MISMATCH: Bank financial account requires bank payment method (received: %)', p_payment_method;
  ELSIF p_financial_account_type = 'business_cash' AND p_payment_method NOT IN ('cash', 'business_cash') THEN
    RAISE EXCEPTION 'PAYMENT_METHOD_MISMATCH: Business cash vault requires cash payment method (received: %)', p_payment_method;
  ELSIF p_financial_account_type = 'petty_cash' AND p_payment_method NOT IN ('cash', 'petty_cash') THEN
    RAISE EXCEPTION 'PAYMENT_METHOD_MISMATCH: Petty cash account requires cash or petty_cash payment method (received: %)', p_payment_method;
  ELSIF p_financial_account_type = 'moncash' AND p_payment_method NOT IN ('moncash', 'mobile_money') THEN
    RAISE EXCEPTION 'PAYMENT_METHOD_MISMATCH: MonCash wallet requires moncash or mobile_money payment method (received: %)', p_payment_method;
  ELSIF p_financial_account_type = 'natcash' AND p_payment_method NOT IN ('natcash', 'mobile_money') THEN
    RAISE EXCEPTION 'PAYMENT_METHOD_MISMATCH: NatCash wallet requires natcash or mobile_money payment method (received: %)', p_payment_method;
  END IF;

  v_canonical_hash_input := jsonb_build_object(
    'business_id', LOWER(p_business_id::text),
    'expense_id', LOWER(p_expense_id::text),
    'financial_account_type', LOWER(p_financial_account_type),
    'financial_account_id', LOWER(p_financial_account_id::text),
    'payment_method', LOWER(p_payment_method),
    'fee_amount', to_char(v_fee_to_charge, 'FM999999999999990.0000'),
    'reference_number', CASE WHEN p_reference_number IS NOT NULL THEN TRIM(p_reference_number) ELSE NULL END,
    'recipient_phone', CASE WHEN p_recipient_phone IS NOT NULL THEN TRIM(p_recipient_phone) ELSE NULL END
  )::text;
  v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(
    p_business_id,
    p_idempotency_key,
    'rpc_approve_and_pay_expense',
    v_request_hash,
    v_caller_id
  );

  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN v_idem_res->'payload';
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR (
      public.has_permission(p_business_id, 'expenses:approve')
      AND public.has_permission(p_business_id, 'expenses:pay')
    )
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % does not possess authoritative approval and payment permissions for business %',
      v_caller_id, p_business_id;
  END IF;

  SELECT * INTO v_exp
  FROM public.expenses
  WHERE id = p_expense_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND OR v_exp.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: Expense % not found in business %', p_expense_id, p_business_id;
  END IF;

  IF v_exp.status = 'paid' THEN
    RAISE EXCEPTION 'INVALID_STATUS: Expense % is already paid', p_expense_id;
  END IF;

  IF v_exp.status <> 'pending_approval' AND v_exp.status <> 'approved' THEN
    RAISE EXCEPTION 'INVALID_STATUS: Expense % is in status %; only pending_approval or approved requests can be settled',
      p_expense_id, v_exp.status;
  END IF;

  IF v_exp.created_by = v_caller_id THEN
    RAISE EXCEPTION 'SELF_APPROVAL_PROHIBITED: Requester/creator cannot approve or pay their own expense request';
  END IF;

  IF v_exp.financial_account_type IS NOT NULL AND v_exp.financial_account_type <> p_financial_account_type THEN
    RAISE EXCEPTION 'ACCOUNT_MISMATCH: Settlement account type % does not match submitted expense account type %',
      p_financial_account_type, v_exp.financial_account_type;
  END IF;

  IF v_exp.financial_account_id IS NOT NULL AND v_exp.financial_account_id <> p_financial_account_id THEN
    RAISE EXCEPTION 'ACCOUNT_MISMATCH: Settlement account ID % does not match submitted expense account ID %',
      p_financial_account_id, v_exp.financial_account_id;
  END IF;

  IF p_financial_account_type = 'bank' THEN
    v_tx_id := public.fn_post_bank_transaction_internal(
      p_business_id,
      p_financial_account_id,
      'expense_payment',
      'debit',
      v_exp.amount,
      v_exp.currency,
      'expense',
      p_expense_id,
      p_reference_number,
      'Expense payout: ' || v_exp.description,
      v_caller_id,
      jsonb_build_object(
        'payment_method', p_payment_method,
        'approved_by', v_caller_id,
        'notes', p_notes
      )
    );

  ELSIF p_financial_account_type = 'business_cash' THEN
    SELECT * INTO v_vault
    FROM public.business_cash_vaults
    WHERE id = p_financial_account_id AND business_id = p_business_id
    FOR UPDATE;

    IF NOT FOUND OR v_vault.status <> 'active' OR v_vault.deleted_at IS NOT NULL THEN
      RAISE EXCEPTION 'INVALID_ACCOUNT: Cash vault % is invalid, inactive, or belongs to another business', p_financial_account_id;
    END IF;

    IF v_vault.currency <> v_exp.currency THEN
      RAISE EXCEPTION 'CURRENCY_MISMATCH: Expense currency % does not match cash vault currency %', v_exp.currency, v_vault.currency;
    END IF;

    SELECT COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE -amount END), 0.0000)
    INTO v_available_balance
    FROM public.vault_transactions
    WHERE business_id = p_business_id AND vault_id = p_financial_account_id;

    IF v_available_balance < v_exp.amount THEN
      RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Cash vault has insufficient cleared balance';
    END IF;

    INSERT INTO public.vault_transactions (
      business_id, vault_id, direction, amount, currency, transaction_type,
      expense_id, description, actor_user_id, idempotency_key, occurred_at
    ) VALUES (
      p_business_id, p_financial_account_id, 'out', v_exp.amount, v_exp.currency, 'expense_payout',
      p_expense_id, 'Expense payout: ' || v_exp.description, v_caller_id, p_idempotency_key, NOW()
    )
    RETURNING id INTO v_tx_id;

  ELSIF p_financial_account_type = 'petty_cash' THEN
    SELECT * INTO v_petty_acc
    FROM public.petty_cash_accounts
    WHERE id = p_financial_account_id AND business_id = p_business_id
    FOR UPDATE;

    IF NOT FOUND OR v_petty_acc.status <> 'active' OR v_petty_acc.deleted_at IS NOT NULL THEN
      RAISE EXCEPTION 'INVALID_ACCOUNT: Petty cash account % is invalid, inactive, or belongs to another business', p_financial_account_id;
    END IF;

    IF v_petty_acc.currency <> v_exp.currency THEN
      RAISE EXCEPTION 'CURRENCY_MISMATCH: Expense currency % does not match petty cash account currency %', v_exp.currency, v_petty_acc.currency;
    END IF;

    SELECT COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE -amount END), 0.0000)
    INTO v_available_balance
    FROM public.petty_cash_transactions
    WHERE business_id = p_business_id AND petty_cash_account_id = p_financial_account_id;

    IF v_available_balance < v_exp.amount THEN
      RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Petty cash box has insufficient physical cash';
    END IF;

    IF v_exp.petty_cash_budget_id IS NULL THEN
      SELECT id INTO v_exp.petty_cash_budget_id
      FROM public.petty_cash_budgets
      WHERE business_id = p_business_id
        AND petty_cash_account_id = p_financial_account_id
        AND status = 'active'
        AND v_exp.expense_date BETWEEN start_date AND end_date
      ORDER BY created_at DESC
      LIMIT 1;
    END IF;

    IF v_exp.petty_cash_budget_id IS NOT NULL THEN
      SELECT * INTO v_budget
      FROM public.petty_cash_budgets
      WHERE id = v_exp.petty_cash_budget_id AND business_id = p_business_id
      FOR UPDATE;

      SELECT ((v_budget.allocated_budget + COALESCE(SUM(adj.amount), 0.0000)) - COALESCE(spent.total_spent, 0.0000))
      INTO v_remaining_budget
      FROM public.petty_cash_budgets pb
      LEFT JOIN public.petty_cash_budget_adjustments adj ON adj.budget_id = pb.id AND adj.business_id = pb.business_id
      LEFT JOIN (
        SELECT petty_cash_budget_id, SUM(amount) AS total_spent
        FROM public.expenses
        WHERE status = 'paid' AND petty_cash_budget_id = v_budget.id AND business_id = p_business_id AND deleted_at IS NULL
        GROUP BY petty_cash_budget_id
      ) spent ON spent.petty_cash_budget_id = pb.id
      WHERE pb.id = v_budget.id
      GROUP BY pb.id, pb.allocated_budget, spent.total_spent;

      IF v_remaining_budget < v_exp.amount THEN
        RAISE EXCEPTION 'BUDGET_EXCEEDED: Expense amount exceeds remaining allocated petty cash budget';
      END IF;
    END IF;

    INSERT INTO public.petty_cash_transactions (
      business_id, petty_cash_account_id, direction, amount, currency, transaction_type,
      expense_id, notes, actor_user_id, idempotency_key, occurred_at
    ) VALUES (
      p_business_id, p_financial_account_id, 'out', v_exp.amount, v_exp.currency, 'expense_disbursement',
      p_expense_id, 'Expense payout: ' || v_exp.description, v_caller_id, p_idempotency_key, NOW()
    )
    RETURNING id INTO v_tx_id;

  ELSIF p_financial_account_type IN ('moncash', 'natcash') THEN
    SELECT * INTO v_wallet
    FROM public.mobile_money_wallets
    WHERE id = p_financial_account_id AND business_id = p_business_id
    FOR UPDATE;

    IF NOT FOUND OR v_wallet.status <> 'active' OR v_wallet.deleted_at IS NOT NULL THEN
      RAISE EXCEPTION 'INVALID_ACCOUNT: Mobile money wallet % is invalid, inactive, or belongs to another business', p_financial_account_id;
    END IF;

    IF v_wallet.currency <> v_exp.currency THEN
      RAISE EXCEPTION 'CURRENCY_MISMATCH: Expense currency % does not match mobile money wallet currency %', v_exp.currency, v_wallet.currency;
    END IF;

    IF (p_financial_account_type = 'moncash' AND v_wallet.provider <> 'MonCash') OR
       (p_financial_account_type = 'natcash' AND v_wallet.provider <> 'NatCash') THEN
      RAISE EXCEPTION 'ACCOUNT_TYPE_MISMATCH: Account provider does not match payment method';
    END IF;

    IF COALESCE(TRIM(p_recipient_phone), TRIM(v_exp.recipient_phone), '') = '' THEN
      RAISE EXCEPTION 'RECIPIENT_PHONE_REQUIRED: Recipient phone number is mandatory for mobile money payouts';
    END IF;

    SELECT COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE -(amount + fee_amount) END), 0.0000)
    INTO v_available_balance
    FROM public.mobile_money_transactions
    WHERE business_id = p_business_id AND wallet_id = p_financial_account_id;

    IF v_available_balance < (v_exp.amount + v_fee_to_charge) THEN
      RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Mobile money wallet has insufficient cleared funds';
    END IF;

    SELECT COALESCE(timezone, 'UTC') INTO v_biz_timezone FROM public.businesses WHERE id = p_business_id;

    SELECT COALESCE(SUM(amount + fee_amount), 0.0000)
    INTO v_today_disbursements
    FROM public.mobile_money_transactions
    WHERE business_id = p_business_id
      AND wallet_id = p_financial_account_id
      AND direction = 'out'
      AND transaction_type = 'payout'
      AND (occurred_at AT TIME ZONE v_biz_timezone)::date = (NOW() AT TIME ZONE v_biz_timezone)::date;

    IF (v_today_disbursements + v_exp.amount + v_fee_to_charge) > v_wallet.daily_disbursement_limit THEN
      RAISE EXCEPTION 'DAILY_LIMIT_EXCEEDED: Disbursement exceeds configured daily limit';
    END IF;

    INSERT INTO public.mobile_money_transactions (
      business_id, wallet_id, direction, amount, fee_amount, currency, transaction_type,
      telecom_reference, recipient_phone, expense_id, description, actor_user_id, idempotency_key, occurred_at
    ) VALUES (
      p_business_id, p_financial_account_id, 'out', v_exp.amount, v_fee_to_charge, v_exp.currency, 'payout',
      p_reference_number, COALESCE(TRIM(p_recipient_phone), TRIM(v_exp.recipient_phone)), p_expense_id,
      'Expense payout: ' || v_exp.description, v_caller_id, p_idempotency_key, NOW()
    )
    RETURNING id INTO v_tx_id;
  END IF;

  UPDATE public.expenses
  SET
    status = 'paid',
    payment_method = p_payment_method,
    financial_account_type = p_financial_account_type,
    financial_account_id = p_financial_account_id,
    petty_cash_budget_id = v_exp.petty_cash_budget_id,
    paid_at = NOW(),
    paid_by = v_caller_id,
    approved_by = v_caller_id,
    approved_at = NOW(),
    updated_at = NOW()
  WHERE id = p_expense_id AND business_id = p_business_id;

  INSERT INTO public.commercial_audit_logs (
    business_id, actor_id, action, target_type, target_id, details
  ) VALUES (
    p_business_id, v_caller_id, 'expense:approved_and_paid', 'expense', p_expense_id,
    jsonb_build_object(
      'amount', v_exp.amount,
      'currency', v_exp.currency,
      'account_type', p_financial_account_type,
      'account_id', p_financial_account_id,
      'transaction_id', v_tx_id,
      'fee_amount', v_fee_to_charge
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'expense_id', p_expense_id,
    'status', 'paid',
    'financial_account_type', p_financial_account_type,
    'financial_account_id', p_financial_account_id,
    'transaction_id', v_tx_id,
    'settled_at', NOW()
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_approve_and_pay_expense(UUID, UUID, TEXT, UUID, TEXT, UUID, TEXT, TEXT, TEXT, NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_approve_and_pay_expense(UUID, UUID, TEXT, UUID, TEXT, UUID, TEXT, TEXT, TEXT, NUMERIC) TO authenticated;

-- Sanitize rpc_fund_petty_cash_account exception & balance return
CREATE OR REPLACE FUNCTION public.rpc_fund_petty_cash_account(
  p_business_id UUID,
  p_petty_cash_account_id UUID,
  p_amount NUMERIC,
  p_currency VARCHAR,
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
  v_account RECORD;
  v_tx_id UUID;
  v_current_balance NUMERIC(15, 4);
  v_new_balance NUMERIC(15, 4);
  v_idem_res JSONB;
  v_idem_payload JSONB;
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_fund_petty_cash_account';
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'treasury:petty_cash:manage')
    OR public.has_permission(p_business_id, 'cash:manage')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot replenish petty cash in business %', v_caller_id, p_business_id;
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Funding amount must be greater than zero';
  END IF;

  v_canonical_hash_input := jsonb_build_object(
    'business_id', LOWER(p_business_id::text),
    'petty_cash_account_id', LOWER(p_petty_cash_account_id::text),
    'amount', to_char(p_amount, 'FM999999999999990.0000'),
    'currency', UPPER(TRIM(p_currency))
  )::text;
  v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(
    p_business_id,
    p_idempotency_key,
    'rpc_fund_petty_cash_account',
    v_request_hash,
    v_caller_id
  );
  IF (v_idem_res->>'action') = 'replay' THEN
    SELECT branch_id INTO v_account
    FROM public.petty_cash_accounts
    WHERE id = p_petty_cash_account_id AND business_id = p_business_id;

    IF public.can_view_financial_metric(p_business_id, 'treasury:balance:view', v_account.branch_id) THEN
      SELECT COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE -amount END), 0.0000)
      INTO v_new_balance
      FROM public.petty_cash_transactions
      WHERE business_id = p_business_id AND petty_cash_account_id = p_petty_cash_account_id;
    ELSE
      v_new_balance := NULL;
    END IF;

    RETURN (v_idem_res->'payload') || jsonb_build_object(
      'balance', v_new_balance,
      'is_replay', true
    );
  END IF;

  SELECT * INTO v_account
  FROM public.petty_cash_accounts
  WHERE id = p_petty_cash_account_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND OR v_account.status <> 'active' OR v_account.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'INVALID_ACCOUNT: Petty cash account % does not exist, is inactive, or deleted', p_petty_cash_account_id;
  END IF;

  IF v_account.currency <> UPPER(TRIM(p_currency)) THEN
    RAISE EXCEPTION 'CURRENCY_MISMATCH: Funding currency % does not match petty cash account currency %',
      UPPER(TRIM(p_currency)), v_account.currency;
  END IF;

  SELECT COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE -amount END), 0.0000)
  INTO v_current_balance
  FROM public.petty_cash_transactions
  WHERE business_id = p_business_id AND petty_cash_account_id = p_petty_cash_account_id;

  -- SANITIZED: Never leak v_current_balance in exception message
  IF (v_current_balance + p_amount) > v_account.max_float_limit THEN
    RAISE EXCEPTION 'FLOAT_LIMIT_EXCEEDED: Replenishment would exceed configured petty cash float limit';
  END IF;

  v_new_balance := v_current_balance + p_amount;

  INSERT INTO public.petty_cash_transactions (
    business_id,
    petty_cash_account_id,
    budget_id,
    direction,
    amount,
    currency,
    transaction_type,
    notes,
    actor_user_id,
    idempotency_key,
    occurred_at,
    created_at,
    metadata
  ) VALUES (
    p_business_id,
    p_petty_cash_account_id,
    NULL,
    'in',
    p_amount,
    v_account.currency,
    'float_replenishment',
    COALESCE(TRIM(p_notes), 'Petty cash float replenishment'),
    v_caller_id,
    p_idempotency_key,
    NOW(),
    NOW(),
    jsonb_build_object('replenished_by', v_caller_id)
  )
  RETURNING id INTO v_tx_id;

  INSERT INTO public.commercial_audit_logs (
    business_id,
    actor_id,
    action,
    target_type,
    target_id,
    details
  ) VALUES (
    p_business_id,
    v_caller_id,
    'PETTY_CASH_REPLENISHED',
    'petty_cash_account',
    p_petty_cash_account_id,
    jsonb_build_object(
      'transaction_id', v_tx_id,
      'amount', p_amount,
      'currency', v_account.currency
    )
  );

  -- Omit balance from idempotency_records payload
  v_idem_payload := jsonb_build_object(
    'success', true,
    'petty_cash_account_id', p_petty_cash_account_id,
    'transaction_id', v_tx_id,
    'amount', p_amount,
    'currency', v_account.currency
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_idem_payload);

  RETURN v_idem_payload || jsonb_build_object(
    'balance', CASE
      WHEN public.can_view_financial_metric(p_business_id, 'treasury:balance:view', v_account.branch_id)
      THEN v_new_balance
      ELSE NULL::NUMERIC(15, 4)
    END,
    'is_replay', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_fund_petty_cash_account(UUID, UUID, NUMERIC, VARCHAR, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_fund_petty_cash_account(UUID, UUID, NUMERIC, VARCHAR, UUID, TEXT) TO authenticated;

-- =============================================================================
-- 12. SECONDARY DASHBOARD RPC ALIGNMENT: public.get_dashboard_analytics
-- =============================================================================
-- Hardens Migration 013 get_dashboard_analytics so it enforces the exact same
-- granular financial permission checks as rpc_get_operational_dashboard_metrics
-- and never leaks revenue, valuation, receivables, or expenses via sales:view
-- or reports:view_operational.

CREATE OR REPLACE FUNCTION public.get_dashboard_analytics(
  p_business_id UUID,
  p_branch_id UUID DEFAULT NULL,
  p_start_date TIMESTAMPTZ DEFAULT NULL,
  p_end_date TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_metrics JSONB;
BEGIN
  v_metrics := public.rpc_get_operational_dashboard_metrics(
    p_business_id := p_business_id,
    p_branch_id := p_branch_id,
    p_start_date := COALESCE(p_start_date, (CURRENT_DATE - INTERVAL '30 days')),
    p_end_date := COALESCE(p_end_date, NOW())
  );

  RETURN jsonb_build_object(
    'currency', v_metrics->'currency',
    'start_date', v_metrics->'start_date',
    'end_date', v_metrics->'end_date',
    'sales', jsonb_build_object(
      'net_sales', v_metrics->'net_sales',
      'gross_sales', v_metrics->'gross_merchandise_value',
      'discounts_total', v_metrics->'discounts_total',
      'orders_count', v_metrics->'transaction_count',
      'average_order_value', v_metrics->'average_ticket'
    ),
    'inventory', jsonb_build_object(
      'active_sku_count', v_metrics->'active_sku_count',
      'cost_value', v_metrics->'inventory_value'
    ),
    'operations', jsonb_build_object(
      'open_shifts_count', v_metrics->'open_shift_count',
      'cash_on_hand', v_metrics->'cash_on_hand',
      'bank_balance', v_metrics->'bank_balance',
      'receivables_outstanding', v_metrics->'outstanding_receivables',
      'pending_expenses', v_metrics->'pending_expense_amount',
      'paid_expenses', v_metrics->'paid_expense_amount'
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_dashboard_analytics(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_dashboard_analytics(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;

COMMIT;
