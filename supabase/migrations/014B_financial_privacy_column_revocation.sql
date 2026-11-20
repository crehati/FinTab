-- =============================================================================
-- FinTab Enterprise OS - Migration 014B: Financial Privacy Column Revocation & Sales History Hardening
-- Candidate Migration Script (STAGING / PRE-PRODUCTION ONLY - DO NOT APPLY TO PRODUCTION)
--
-- Phase S3-B1: Controlled Financial Privacy Implementation (Enforcement Layer)
-- Prerequisite: Migration 014A_financial_privacy_additive_security_layer.sql applied
--               and application repositories verified against v_*_secure / public projections.
--
-- Summary of Enforcement Actions:
-- 1. Revokes table-wide SELECT from PUBLIC, anon, and authenticated on the 8 base
--    tables containing sensitive cost, credit, tax ID, and cash reconciliation columns,
--    and re-grants SELECT strictly on non-sensitive public columns to authenticated:
--      - public.products (revokes cost_price)
--      - public.inventory_balances (revokes average_unit_cost)
--      - public.inventory_movements (revokes unit_cost)
--      - public.inventory_adjustment_items (revokes unit_cost)
--      - public.inventory_transfer_items (revokes unit_cost_at_dispatch)
--      - public.sales_transaction_items (revokes cost_price)
--      - public.customers (revokes tax_id, credit_limit)
--      - public.register_shifts (revokes expected_cash, variance)
-- 2. Replaces permissive SELECT RLS policies on public.sales_transactions,
--    public.sales_transaction_items, and public.payments with least-privilege
--    policies that block bulk historical revenue scraping by unauthorized roles
--    while preserving POS checkout, single-sale receipt lookup (get_pos_sale_receipt),
--    own-shift recent transactions (24h window), and authorized refund/void workflows.
--
-- SAFE FAIL-CLOSED ROLLBACK POLICY (CHECKPOINT 1 BLOCKER 4):
-- - NEVER execute table-wide `GRANT SELECT ON TABLE ... TO authenticated` on the 8
--   base tables as a rollback mechanism; doing so would re-expose cost, credit,
--   tax ID, and blind-close columns to direct PostgREST queries.
-- - If an emergency rollback of 014A/014B view or accessor logic is required,
--   keep sensitive base-table columns REVOKED and replace `v_*_secure` sensitive
--   column expressions with `NULL::NUMERIC(15,4)` / `NULL::TEXT` fail-closed constants.
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. BASE TABLE SENSITIVE COLUMN REVOCATION (8 TABLES)
-- =============================================================================

-- 1.1 public.products — Revoke cost_price; grant only non-cost catalog columns
REVOKE SELECT ON TABLE public.products FROM PUBLIC, anon, authenticated;
GRANT SELECT (
  id,
  business_id,
  category_id,
  primary_supplier_id,
  name,
  sku,
  barcode,
  description,
  product_type,
  unit_of_measure,
  is_active,
  created_by,
  updated_by,
  created_at,
  updated_at,
  deleted_at,
  metadata
) ON TABLE public.products TO authenticated;

-- 1.2 public.inventory_balances — Revoke average_unit_cost; grant only quantity & scope columns
REVOKE SELECT ON TABLE public.inventory_balances FROM PUBLIC, anon, authenticated;
GRANT SELECT (
  id,
  business_id,
  branch_id,
  location_id,
  product_id,
  on_hand_quantity,
  reserved_quantity,
  available_quantity,
  updated_at
) ON TABLE public.inventory_balances TO authenticated;

-- 1.3 public.inventory_movements — Revoke unit_cost; grant only operational ledger columns
REVOKE SELECT ON TABLE public.inventory_movements FROM PUBLIC, anon, authenticated;
GRANT SELECT (
  id,
  business_id,
  branch_id,
  location_id,
  product_id,
  movement_type,
  quantity,
  reference_type,
  reference_id,
  notes,
  actor_id,
  created_at,
  metadata
) ON TABLE public.inventory_movements TO authenticated;

-- 1.4 public.inventory_adjustment_items — Revoke unit_cost; grant only audit count columns
REVOKE SELECT ON TABLE public.inventory_adjustment_items FROM PUBLIC, anon, authenticated;
GRANT SELECT (
  id,
  business_id,
  adjustment_id,
  product_id,
  system_quantity,
  counted_quantity,
  variance_quantity,
  reason,
  created_at
) ON TABLE public.inventory_adjustment_items TO authenticated;

-- 1.5 public.inventory_transfer_items — Revoke unit_cost_at_dispatch; grant only transfer quantity columns
REVOKE SELECT ON TABLE public.inventory_transfer_items FROM PUBLIC, anon, authenticated;
GRANT SELECT (
  id,
  business_id,
  transfer_id,
  product_id,
  quantity_requested,
  quantity_shipped,
  quantity_received,
  created_at
) ON TABLE public.inventory_transfer_items TO authenticated;

-- 1.6 public.sales_transaction_items — Revoke cost_price; grant only commercial line columns
REVOKE SELECT ON TABLE public.sales_transaction_items FROM PUBLIC, anon, authenticated;
GRANT SELECT (
  id,
  business_id,
  transaction_id,
  product_id,
  inventory_location_id,
  salesperson_user_id,
  quantity,
  unit_price,
  discount_amount,
  tax_amount,
  line_total,
  notes,
  created_at
) ON TABLE public.sales_transaction_items TO authenticated;

-- 1.7 public.customers — Revoke tax_id and credit_limit; grant only directory & CRM contact columns
REVOKE SELECT ON TABLE public.customers FROM PUBLIC, anon, authenticated;
GRANT SELECT (
  id,
  business_id,
  customer_number,
  full_name,
  phone,
  email,
  address,
  status,
  notes,
  created_at,
  updated_at,
  deleted_at,
  metadata
) ON TABLE public.customers TO authenticated;

-- 1.8 public.register_shifts — Revoke expected_cash and variance (enforces blind cash close);
--     grant only operational shift & counted_cash columns
REVOKE SELECT ON TABLE public.register_shifts FROM PUBLIC, anon, authenticated;
GRANT SELECT (
  id,
  business_id,
  branch_id,
  register_id,
  shift_number,
  opened_by,
  opened_at,
  opening_float,
  closed_by,
  closed_at,
  counted_cash,
  status,
  notes,
  created_at,
  updated_at
) ON TABLE public.register_shifts TO authenticated;

-- =============================================================================
-- 2. LEAST-PRIVILEGE SALES & PAYMENT HISTORY RLS POLICIES
-- =============================================================================
-- Prevents bulk historical revenue reconstruction by unauthorized operational
-- roles while preserving:
--   (a) Authorized revenue / customer-sales viewers (financials:revenue:view,
--       customers:sales_amount:view)
--   (b) Authorized refund / void / receivables collection workflows (sales:refund,
--       sales:void, payments:record on open invoices)
--   (c) Cashier's own recent transactions (last 24 hours) for active shift operations
--   (d) Single-sale receipt lookup via public.get_pos_sale_receipt(p_business_id, p_sale_id)

-- Drop both legacy Migration 004 policy names ("sales_trans_select") and canonical names
DROP POLICY IF EXISTS "sales_trans_select" ON public.sales_transactions;
DROP POLICY IF EXISTS "sales_transactions_select" ON public.sales_transactions;
DROP POLICY IF EXISTS "p_sales_transactions_select" ON public.sales_transactions;
DROP POLICY IF EXISTS "sales_transactions_LeastPrivilege_select" ON public.sales_transactions;

CREATE POLICY "sales_transactions_select" ON public.sales_transactions
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR (
    EXISTS (
      SELECT 1 FROM public.business_memberships bm
      WHERE bm.business_id = sales_transactions.business_id
        AND bm.user_id = auth.uid()
        AND bm.status = 'active'
    )
    AND (
      -- 1. Authorized financial revenue or customer sales amount visibility in branch scope
      public.can_view_financial_metric(business_id, 'financials:revenue:view', branch_id)
      OR public.can_view_financial_metric(business_id, 'customers:sales_amount:view', branch_id)
      -- 2. Authorized refund / void supervisors in branch scope
      OR public.has_permission_in_scope(business_id, 'sales:refund', branch_id)
      OR public.has_permission_in_scope(business_id, 'sales:void', branch_id)
      -- 3. Open credit invoice settlement (balance_due > 0) for authorized payment collectors in branch scope
      OR (
        balance_due > 0
        AND status IN ('pending_payment', 'partially_paid')
        AND public.has_permission_in_scope(business_id, 'payments:record', branch_id)
      )
      -- 4. Cashier's own recent POS transactions (24-hour operational shift window)
      OR (
        cashier_user_id = auth.uid()
        AND occurred_at >= (NOW() - INTERVAL '24 hours')
        AND public.has_permission_in_scope(business_id, 'sales:view', branch_id)
      )
    )
  )
);

-- Child line items inherit parent sales_transactions visibility automatically via EXISTS
DROP POLICY IF EXISTS "sales_trans_items_select" ON public.sales_transaction_items;
DROP POLICY IF EXISTS "sales_transaction_items_select" ON public.sales_transaction_items;
DROP POLICY IF EXISTS "p_sales_transaction_items_select" ON public.sales_transaction_items;

CREATE POLICY "sales_transaction_items_select" ON public.sales_transaction_items
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.sales_transactions st
    WHERE st.id = sales_transaction_items.transaction_id
      AND st.business_id = sales_transaction_items.business_id
  )
);

-- Child payments inherit parent sales_transactions visibility automatically via EXISTS
DROP POLICY IF EXISTS "payments_select" ON public.payments;
DROP POLICY IF EXISTS "p_payments_select" ON public.payments;

CREATE POLICY "payments_select" ON public.payments
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.sales_transactions st
    WHERE st.id = payments.transaction_id
      AND st.business_id = payments.business_id
  )
);

-- =============================================================================
-- 3. CASH LEDGER, TREASURY LEDGER & AUDIT LOG SELECT RLS HARDENING
-- =============================================================================
-- Prevents cashiers with operational 'cash:view' from querying public.cash_transactions
-- directly to sum shift cash movements and defeat blind cash close or v_cash_register_balances.
DROP POLICY IF EXISTS "cash_transactions_select" ON public.cash_transactions;

CREATE POLICY "cash_transactions_select" ON public.cash_transactions
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.can_view_financial_metric(business_id, 'treasury:balance:view', branch_id)
);

-- Upgrades Migration 013 treasury transaction ledger policies from unscoped
-- has_permission(business_id, 'treasury:balance:view') to scope-aware
-- can_view_financial_metric(business_id, 'treasury:balance:view', branch_id).
DROP POLICY IF EXISTS "bank_transactions_select" ON public.bank_transactions;

CREATE POLICY "bank_transactions_select" ON public.bank_transactions
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.can_view_financial_metric(business_id, 'treasury:balance:view', NULL)
);

DROP POLICY IF EXISTS vault_transactions_select ON public.vault_transactions;
DROP POLICY IF EXISTS "vault_transactions_select" ON public.vault_transactions;

CREATE POLICY "vault_transactions_select" ON public.vault_transactions
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR EXISTS (
    SELECT 1
    FROM public.business_cash_vaults v
    WHERE v.id = vault_transactions.vault_id
      AND v.business_id = vault_transactions.business_id
      AND public.can_view_financial_metric(v.business_id, 'treasury:balance:view', v.branch_id)
  )
);

DROP POLICY IF EXISTS petty_cash_transactions_select ON public.petty_cash_transactions;
DROP POLICY IF EXISTS "petty_cash_transactions_select" ON public.petty_cash_transactions;

CREATE POLICY "petty_cash_transactions_select" ON public.petty_cash_transactions
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR EXISTS (
    SELECT 1
    FROM public.petty_cash_accounts pca
    WHERE pca.id = petty_cash_transactions.petty_cash_account_id
      AND pca.business_id = petty_cash_transactions.business_id
      AND public.can_view_financial_metric(pca.business_id, 'treasury:balance:view', pca.branch_id)
  )
);

DROP POLICY IF EXISTS mobile_money_transactions_select ON public.mobile_money_transactions;
DROP POLICY IF EXISTS "mobile_money_transactions_select" ON public.mobile_money_transactions;

CREATE POLICY "mobile_money_transactions_select" ON public.mobile_money_transactions
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.can_view_financial_metric(business_id, 'treasury:balance:view', NULL)
);

-- Restricts commercial_audit_logs SELECT to owner or audit:view_logs (removes expenses:view)
DROP POLICY IF EXISTS "commercial_audit_logs_select" ON public.commercial_audit_logs;
DROP POLICY IF EXISTS commercial_audit_logs_select ON public.commercial_audit_logs;

CREATE POLICY "commercial_audit_logs_select" ON public.commercial_audit_logs
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'audit:view_logs')
);

COMMIT;

