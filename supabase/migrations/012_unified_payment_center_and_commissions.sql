-- ==============================================================================
-- FinTab Enterprise OS — Migration 012
-- Unified Payment Center, Authoritative Commission Engine & Capital Governance
-- ==============================================================================
-- Baseline: Builds strictly on top of frozen Migrations 001-011.
-- Authoritative Outgoing Business Disbursements: Payroll, Commissions, Dividends,
-- Capital Returns, and Verified Expense Reimbursements.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. EXTEND EXISTING SALES TABLES (SALESPERSON ATTRIBUTION)
-- ------------------------------------------------------------------------------

ALTER TABLE public.sales_transactions
  ADD COLUMN IF NOT EXISTS salesperson_user_id UUID REFERENCES public.user_profiles(id) ON DELETE RESTRICT;

ALTER TABLE public.sales_transaction_items
  ADD COLUMN IF NOT EXISTS salesperson_user_id UUID REFERENCES public.user_profiles(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS idx_sales_trans_salesperson
  ON public.sales_transactions (business_id, salesperson_user_id)
  WHERE salesperson_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_sales_items_salesperson
  ON public.sales_transaction_items (business_id, salesperson_user_id)
  WHERE salesperson_user_id IS NOT NULL;

-- ------------------------------------------------------------------------------
-- 1.1 EXTEND TREASURY CHECK CONSTRAINTS (FORWARD COMPATIBILITY)
-- ------------------------------------------------------------------------------

-- Bank Transactions: Add 'disbursement' and 'disbursement_reversal' while preserving all frozen values
ALTER TABLE public.bank_transactions
  DROP CONSTRAINT IF EXISTS bank_transactions_transaction_type_check;

ALTER TABLE public.bank_transactions
  ADD CONSTRAINT bank_transactions_transaction_type_check
  CHECK (
    transaction_type IN (
      'deposit', 'withdrawal', 'transfer_in', 'transfer_out',
      'fee', 'interest', 'adjustment', 'payment_settlement', 'expense_payment',
      'disbursement', 'disbursement_reversal'
    )
  );

ALTER TABLE public.bank_transactions
  DROP CONSTRAINT IF EXISTS bank_transactions_source_type_check;

ALTER TABLE public.bank_transactions
  ADD CONSTRAINT bank_transactions_source_type_check
  CHECK (
    source_type IN (
      'payment', 'expense', 'transfer', 'manual', 'opening_balance', 'reconciliation',
      'disbursement', 'disbursement_reversal'
    )
  );

-- Vault Transactions: Add 'disbursement' while preserving all frozen values
ALTER TABLE public.vault_transactions
  DROP CONSTRAINT IF EXISTS vault_transactions_transaction_type_check;

ALTER TABLE public.vault_transactions
  ADD CONSTRAINT vault_transactions_transaction_type_check
  CHECK (
    transaction_type IN (
      'opening_balance', 'deposit', 'withdrawal', 'expense_payout', 'transfer_in', 'transfer_out',
      'reversal', 'adjustment', 'disbursement'
    )
  );

-- Petty Cash Transactions: Add 'disbursement' while preserving all frozen values
ALTER TABLE public.petty_cash_transactions
  DROP CONSTRAINT IF EXISTS petty_cash_transactions_transaction_type_check;

ALTER TABLE public.petty_cash_transactions
  ADD CONSTRAINT petty_cash_transactions_transaction_type_check
  CHECK (
    transaction_type IN (
      'float_replenishment', 'expense_disbursement', 'reversal', 'audit_adjustment', 'disbursement'
    )
  );

-- Deterministic Ledger Idempotency Helper
CREATE OR REPLACE FUNCTION public.fn_derive_deterministic_uuid(
  p_namespace TEXT,
  p_identifier TEXT,
  p_operation TEXT
)
RETURNS UUID
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT md5(p_namespace || ':' || p_identifier || ':' || p_operation)::uuid;
$$;

REVOKE ALL ON FUNCTION public.fn_derive_deterministic_uuid(TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------------------------
-- 2. TABLE 1: public.payees (PAYEE MASTER DIRECTORY)
-- ------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.payees (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  payee_type TEXT NOT NULL CHECK (payee_type IN ('internal', 'external')),
  
  -- Internal: Anchors to canonical user_profiles. One human = one user_profiles.id
  payee_user_id UUID REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  
  -- Optional entity links (allows a user to be staff, investor, or both without duplicate payees)
  staff_profile_id UUID REFERENCES public.staff_profiles(id) ON DELETE SET NULL,
  investor_id UUID REFERENCES public.investors(id) ON DELETE SET NULL,
  
  display_name TEXT NOT NULL,
  phone TEXT,
  email TEXT,
  national_id TEXT,
  tax_identifier TEXT,
  
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'archived')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_payees_biz_id UNIQUE (business_id, id),
  CONSTRAINT uq_payees_internal_user UNIQUE (business_id, payee_user_id),
  CONSTRAINT chk_payees_internal_integrity CHECK (
    (payee_type = 'internal' AND payee_user_id IS NOT NULL) OR
    (payee_type = 'external' AND payee_user_id IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_payees_biz_status ON public.payees (business_id, status);
CREATE INDEX IF NOT EXISTS idx_payees_user ON public.payees (payee_user_id) WHERE payee_user_id IS NOT NULL;

-- ------------------------------------------------------------------------------
-- 3. TABLE 2: public.payee_payment_destinations (PROTECTED FINANCIAL DESTINATIONS)
-- ------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.payee_payment_destinations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  payee_id UUID NOT NULL REFERENCES public.payees(id) ON DELETE CASCADE,
  destination_type TEXT NOT NULL CHECK (
    destination_type IN ('bank_account', 'moncash', 'natcash', 'cash_pickup')
  ),
  account_holder_name TEXT NOT NULL,
  bank_name TEXT,
  account_number_masked TEXT,
  routing_number TEXT,
  phone_number TEXT,
  is_default BOOLEAN NOT NULL DEFAULT false,
  verified BOOLEAN NOT NULL DEFAULT false, -- Must be verified via authoritative verification workflow, never self-assigned
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_payee_destinations_biz_id UNIQUE (business_id, id)
);

CREATE INDEX IF NOT EXISTS idx_payee_dest_biz_payee ON public.payee_payment_destinations (business_id, payee_id);

-- ------------------------------------------------------------------------------
-- 4. TABLE 3: public.product_commission_rules (VERSIONED COMMISSION RULES)
-- ------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.product_commission_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  commission_percentage NUMERIC(5, 2) NOT NULL CHECK (
    commission_percentage >= 0.00 AND commission_percentage <= 100.00
  ),
  effective_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  effective_to TIMESTAMPTZ,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'superseded', 'cancelled')),
  notes TEXT,
  created_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_commission_rule_period CHECK (effective_to IS NULL OR effective_to > effective_from),
  CONSTRAINT uq_product_commission_rules_id_biz UNIQUE (business_id, id)
);

-- Exactly one indefinite active rule per product at any given moment
CREATE UNIQUE INDEX IF NOT EXISTS uq_product_commission_current_active
  ON public.product_commission_rules (business_id, product_id)
  WHERE status = 'active' AND effective_to IS NULL;

CREATE INDEX IF NOT EXISTS idx_prod_comm_rules_lookup
  ON public.product_commission_rules (business_id, product_id, status, effective_from);

-- Concurrency-Safe Temporal Overlap Prevention for Commission Rules
CREATE OR REPLACE FUNCTION public.fn_validate_commission_rule_overlap()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_lock_key BIGINT;
  v_new_lower TIMESTAMPTZ;
  v_new_upper TIMESTAMPTZ;
  v_conflict_id UUID;
  v_conflict_from TIMESTAMPTZ;
  v_conflict_to TIMESTAMPTZ;
BEGIN
  IF NEW.status NOT IN ('active', 'superseded') THEN
    RETURN NEW;
  END IF;

  -- 1. Advisory Serialization on (business_id, product_id)
  v_lock_key := ('x' || substr(md5(NEW.business_id::text || ':' || NEW.product_id::text), 1, 16))::bit(64)::bigint;
  PERFORM pg_advisory_xact_lock(v_lock_key);

  -- 2. Validate Boundary Logic
  v_new_lower := NEW.effective_from;
  v_new_upper := COALESCE(NEW.effective_to, 'infinity'::timestamptz);

  IF v_new_lower >= v_new_upper THEN
    RAISE EXCEPTION 'INVALID_DATE_RANGE: effective_from (%) must be strictly before effective_to (%)',
      NEW.effective_from, NEW.effective_to;
  END IF;

  -- 3. Half-Open [from, to) Overlap Detection
  SELECT id, effective_from, effective_to
  INTO v_conflict_id, v_conflict_from, v_conflict_to
  FROM public.product_commission_rules
  WHERE business_id = NEW.business_id
    AND product_id = NEW.product_id
    AND status IN ('active', 'superseded')
    AND id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid)
    AND (
      v_new_lower < COALESCE(effective_to, 'infinity'::timestamptz)
      AND v_new_upper > effective_from
    )
  LIMIT 1;

  IF v_conflict_id IS NOT NULL THEN
    RAISE EXCEPTION 'COMMISSION_RULE_OVERLAP: Commission rule for product % [% to %] overlaps with existing rule % [% to %]',
      NEW.product_id, v_new_lower, v_new_upper, v_conflict_id, v_conflict_from, v_conflict_to;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_validate_commission_rule_overlap() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_validate_commission_rule_overlap ON public.product_commission_rules;
CREATE TRIGGER trg_validate_commission_rule_overlap
  BEFORE INSERT OR UPDATE ON public.product_commission_rules
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_validate_commission_rule_overlap();

-- ------------------------------------------------------------------------------
-- 5. TABLE 4: public.commission_earnings (IMMUTABLE EARNED COMMISSION LOG)
-- ------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.commission_earnings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  transaction_id UUID NOT NULL REFERENCES public.sales_transactions(id) ON DELETE RESTRICT,
  transaction_item_id UUID NOT NULL REFERENCES public.sales_transaction_items(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  salesperson_user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  staff_profile_id UUID NOT NULL REFERENCES public.staff_profiles(id) ON DELETE RESTRICT,
  payee_id UUID NOT NULL REFERENCES public.payees(id) ON DELETE RESTRICT,
  
  -- Calculation Snapshot
  quantity NUMERIC(15, 4) NOT NULL CHECK (quantity > 0.0000),
  regular_unit_price NUMERIC(15, 4) NOT NULL,
  authoritative_unit_selling_price NUMERIC(15, 4) NOT NULL,
  commission_percentage_applied NUMERIC(5, 2) NOT NULL,
  commission_per_unit NUMERIC(15, 4) NOT NULL,
  total_commission_earned NUMERIC(15, 4) NOT NULL CHECK (total_commission_earned >= 0.0000),
  currency VARCHAR(3) NOT NULL,
  
  status TEXT NOT NULL DEFAULT 'earned' CHECK (status IN ('earned', 'settled')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_commission_line_item UNIQUE (transaction_item_id),
  CONSTRAINT uq_commission_earnings_biz_id UNIQUE (business_id, id)
);

CREATE INDEX IF NOT EXISTS idx_comm_earnings_salesperson
  ON public.commission_earnings (business_id, salesperson_user_id, status);
CREATE INDEX IF NOT EXISTS idx_comm_earnings_payee
  ON public.commission_earnings (business_id, payee_id, status);
CREATE INDEX IF NOT EXISTS idx_comm_earnings_txn
  ON public.commission_earnings (transaction_id);

-- ------------------------------------------------------------------------------
-- 6. TABLE 5: public.commission_adjustments (APPEND-ONLY COMPENSATING ADJUSTMENTS)
-- ------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.commission_adjustments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  salesperson_user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  staff_profile_id UUID NOT NULL REFERENCES public.staff_profiles(id) ON DELETE RESTRICT,
  payee_id UUID NOT NULL REFERENCES public.payees(id) ON DELETE RESTRICT,
  
  adjustment_type TEXT NOT NULL CHECK (
    adjustment_type IN ('refund_clawback', 'sale_void', 'return_adjustment', 'manual_correction')
  ),
  reference_earning_id UUID REFERENCES public.commission_earnings(id) ON DELETE RESTRICT,
  reference_transaction_id UUID REFERENCES public.sales_transactions(id) ON DELETE RESTRICT,
  
  amount NUMERIC(15, 4) NOT NULL, -- Negative for clawbacks/reductions, e.g. -50.0000
  currency VARCHAR(3) NOT NULL,
  reason TEXT NOT NULL,
  created_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_commission_adjustments_biz_id UNIQUE (business_id, id)
);

CREATE INDEX IF NOT EXISTS idx_comm_adj_salesperson
  ON public.commission_adjustments (business_id, salesperson_user_id);
CREATE INDEX IF NOT EXISTS idx_comm_adj_earning
  ON public.commission_adjustments (reference_earning_id) WHERE reference_earning_id IS NOT NULL;

-- ------------------------------------------------------------------------------
-- 7. TABLE 6: public.payroll_obligations (AUTHORITATIVE PAYROLL RUNS)
-- ------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.payroll_obligations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  payroll_number TEXT NOT NULL,
  staff_profile_id UUID NOT NULL REFERENCES public.staff_profiles(id) ON DELETE RESTRICT,
  payee_id UUID NOT NULL REFERENCES public.payees(id) ON DELETE RESTRICT,
  
  pay_period_start DATE NOT NULL,
  pay_period_end DATE NOT NULL,
  payment_due_date DATE NOT NULL,
  
  compensation_snapshot JSONB NOT NULL,
  base_amount NUMERIC(15, 4) NOT NULL CHECK (base_amount >= 0.0000),
  allowances NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (allowances >= 0.0000),
  deductions NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (deductions >= 0.0000),
  net_payable NUMERIC(15, 4) NOT NULL CHECK (net_payable >= 0.0000),
  currency VARCHAR(3) NOT NULL,
  
  status TEXT NOT NULL DEFAULT 'draft' CHECK (
    status IN ('draft', 'approved', 'settled', 'cancelled')
  ),
  
  created_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  approved_by UUID REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  approved_at TIMESTAMPTZ,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_payroll_period CHECK (pay_period_end >= pay_period_start),
  CONSTRAINT chk_payroll_net_math CHECK (net_payable = (base_amount + allowances - deductions)),
  CONSTRAINT uq_payroll_staff_period UNIQUE (business_id, staff_profile_id, pay_period_start, pay_period_end),
  CONSTRAINT uq_payroll_biz_number UNIQUE (business_id, payroll_number),
  CONSTRAINT uq_payroll_obligations_biz_id UNIQUE (business_id, id)
);

CREATE INDEX IF NOT EXISTS idx_payroll_biz_status ON public.payroll_obligations (business_id, status);

-- ------------------------------------------------------------------------------
-- 8. TABLE 7: public.capital_returns (APPEND-ONLY CAPITAL REDEMPTION LEDGER)
-- ------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.capital_returns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  investor_id UUID NOT NULL REFERENCES public.investors(id) ON DELETE RESTRICT,
  entry_number INT NOT NULL,
  entry_type TEXT NOT NULL DEFAULT 'return' CHECK (entry_type IN ('return', 'reversal')),
  return_amount NUMERIC(15, 4) NOT NULL CHECK (return_amount > 0.0000),
  effective_date DATE NOT NULL DEFAULT CURRENT_DATE,
  disbursement_id UUID, -- Will point to disbursements(id)
  reversal_of_entry_id UUID REFERENCES public.capital_returns(id),
  notes TEXT,
  created_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_capital_returns_seq UNIQUE (business_id, entry_number),
  CONSTRAINT uq_capital_returns_biz_id UNIQUE (business_id, id)
);

CREATE INDEX IF NOT EXISTS idx_cap_returns_investor ON public.capital_returns (business_id, investor_id);

-- ------------------------------------------------------------------------------
-- 9. TABLE 8: public.disbursements (AUTHORITATIVE OUTGOING PAYMENTS)
-- ------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.disbursements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  disbursement_number TEXT NOT NULL,
  
  disbursement_category TEXT NOT NULL CHECK (
    disbursement_category IN (
      'payroll',
      'commission',
      'dividend',
      'capital_return',
      'expense_reimbursement',
      'vendor_payment',
      'other'
    )
  ),
  payee_id UUID NOT NULL REFERENCES public.payees(id) ON DELETE RESTRICT,
  
  amount NUMERIC(15, 4) NOT NULL CHECK (amount > 0.0000),
  currency VARCHAR(3) NOT NULL,
  
  payment_method TEXT NOT NULL CHECK (
    payment_method IN ('bank_transfer', 'vault_cash', 'petty_cash', 'moncash', 'natcash')
  ),
  financial_account_type TEXT NOT NULL CHECK (
    financial_account_type IN ('bank_account', 'vault', 'petty_cash', 'mobile_money')
  ),
  financial_account_id UUID NOT NULL,
  
  fee_amount NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (fee_amount >= 0.0000),
  carrier_reference TEXT,
  telecom_reference TEXT,
  recipient_phone TEXT,
  
  status TEXT NOT NULL DEFAULT 'draft' CHECK (
    status IN ('draft', 'pending_approval', 'approved', 'disbursed', 'rejected', 'cancelled', 'reversed')
  ),
  
  created_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  approved_by UUID REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  approved_at TIMESTAMPTZ,
  disbursed_by UUID REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  disbursed_at TIMESTAMPTZ,
  rejection_reason TEXT,
  cancellation_reason TEXT,
  reversal_reason TEXT,
  reversed_by UUID REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  reversed_at TIMESTAMPTZ,
  settlement_treasury_tx_id UUID,
  
  description TEXT NOT NULL,
  notes TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_disbursements_anti_self_approval
    CHECK (approved_by IS NULL OR approved_by <> created_by),
  CONSTRAINT uq_disbursements_biz_number UNIQUE (business_id, disbursement_number),
  CONSTRAINT uq_disbursements_biz_id UNIQUE (business_id, id)
);

CREATE INDEX IF NOT EXISTS idx_disb_biz_status ON public.disbursements (business_id, status);
CREATE INDEX IF NOT EXISTS idx_disb_payee ON public.disbursements (business_id, payee_id);
CREATE INDEX IF NOT EXISTS idx_disb_category ON public.disbursements (business_id, disbursement_category);

-- Add foreign key constraint from capital_returns to disbursements
ALTER TABLE public.capital_returns
  ADD CONSTRAINT fk_capital_returns_disbursement
  FOREIGN KEY (business_id, disbursement_id)
  REFERENCES public.disbursements(business_id, id)
  ON DELETE RESTRICT;

-- ------------------------------------------------------------------------------
-- 10. TABLE 9: public.disbursement_settlement_allocations (SETTLEMENT ALLOCATIONS)
-- ------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.disbursement_settlement_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  disbursement_id UUID NOT NULL REFERENCES public.disbursements(id) ON DELETE RESTRICT,
  obligation_type TEXT NOT NULL CHECK (
    obligation_type IN ('commission', 'payroll', 'dividend', 'capital_return', 'expense')
  ),
  obligation_id UUID NOT NULL,
  amount_allocated NUMERIC(15, 4) NOT NULL CHECK (amount_allocated > 0.0000),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_alloc_disb_obligation UNIQUE (disbursement_id, obligation_type, obligation_id),
  CONSTRAINT uq_disbursement_alloc_biz_id UNIQUE (business_id, id)
);

CREATE INDEX IF NOT EXISTS idx_disb_alloc_lookup
  ON public.disbursement_settlement_allocations (business_id, obligation_type, obligation_id);

-- ------------------------------------------------------------------------------
-- 11. PERMISSIONS & ROLE BINDINGS
-- ------------------------------------------------------------------------------

INSERT INTO public.permissions (key, module, description)
VALUES
  ('disbursements:view', 'disbursements', 'View payment center disbursements, status, and history'),
  ('disbursements:create', 'disbursements', 'Create draft outgoing disbursement vouchers'),
  ('disbursements:approve', 'disbursements', 'Approve pending disbursement vouchers prior to treasury settlement'),
  ('disbursements:pay', 'disbursements', 'Execute authoritative multi-channel disbursement settlements'),
  ('disbursements:cancel', 'disbursements', 'Cancel unapproved draft or pending disbursement vouchers'),
  ('disbursements:reverse', 'disbursements', 'Authoritatively reverse settled disbursements with compensating ledger entries'),
  ('commissions:view_all', 'commissions', 'View organization-wide commission ledgers and calculations'),
  ('commissions:view_own', 'commissions', 'View personal commission earnings and settlement statements'),
  ('commissions:manage', 'commissions', 'Configure product-level commission percentage rules'),
  ('payroll:view', 'payroll', 'View organization-wide payroll schedules and obligations'),
  ('payroll:run', 'payroll', 'Generate and calculate payroll compensation runs')
ON CONFLICT (key) DO UPDATE
SET
  description = EXCLUDED.description,
  module = EXCLUDED.module;

DO $$
DECLARE
  v_role RECORD;
  v_perm RECORD;
BEGIN
  -- Administrative Roles: PrimaryOwner, CoOwner, SuperAdmin, GeneralManager
  FOR v_role IN
    SELECT id, code
    FROM public.roles
    WHERE code IN ('PrimaryOwner', 'CoOwner', 'SuperAdmin', 'GeneralManager')
  LOOP
    FOR v_perm IN
      SELECT id
      FROM public.permissions
      WHERE key IN (
        'disbursements:view',
        'disbursements:create',
        'disbursements:approve',
        'disbursements:pay',
        'disbursements:cancel',
        'disbursements:reverse',
        'commissions:view_all',
        'commissions:view_own',
        'commissions:manage',
        'payroll:view',
        'payroll:run'
      )
    LOOP
      INSERT INTO public.role_permissions (role_id, permission_id)
      VALUES (v_role.id, v_perm.id)
      ON CONFLICT DO NOTHING;
    END LOOP;
  END LOOP;

  -- FinanceManager Role: Operational financial settlement, but cannot reverse alone
  FOR v_role IN
    SELECT id, code
    FROM public.roles
    WHERE code = 'FinanceManager'
  LOOP
    FOR v_perm IN
      SELECT id
      FROM public.permissions
      WHERE key IN (
        'disbursements:view',
        'disbursements:create',
        'disbursements:approve',
        'disbursements:pay',
        'disbursements:cancel',
        'commissions:view_all',
        'commissions:view_own',
        'payroll:view',
        'payroll:run'
      )
    LOOP
      INSERT INTO public.role_permissions (role_id, permission_id)
      VALUES (v_role.id, v_perm.id)
      ON CONFLICT DO NOTHING;
    END LOOP;
  END LOOP;

  -- All other staff roles: Can only view their own commissions if authenticated
  FOR v_role IN
    SELECT id, code
    FROM public.roles
    WHERE code NOT IN ('PrimaryOwner', 'CoOwner', 'SuperAdmin', 'GeneralManager', 'FinanceManager')
  LOOP
    FOR v_perm IN
      SELECT id
      FROM public.permissions
      WHERE key IN ('commissions:view_own')
    LOOP
      INSERT INTO public.role_permissions (role_id, permission_id)
      VALUES (v_role.id, v_perm.id)
      ON CONFLICT DO NOTHING;
    END LOOP;
  END LOOP;
END;
$$;

-- ------------------------------------------------------------------------------
-- 12. ROW LEVEL SECURITY (RLS) POLICIES
-- ------------------------------------------------------------------------------

ALTER TABLE public.payees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payee_payment_destinations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_commission_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commission_earnings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commission_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_obligations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.capital_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.disbursements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.disbursement_settlement_allocations ENABLE ROW LEVEL SECURITY;

-- 12.1 payees
CREATE POLICY "payees_select_policy" ON public.payees
  FOR SELECT TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'disbursements:view')
    OR payee_user_id = auth.uid()
  );

-- 12.2 payee_payment_destinations (High Privacy)
CREATE POLICY "payee_destinations_select_policy" ON public.payee_payment_destinations
  FOR SELECT TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'disbursements:view')
    OR payee_id IN (SELECT p.id FROM public.payees p WHERE p.payee_user_id = auth.uid() AND p.business_id = business_id)
  );

-- 12.3 product_commission_rules
CREATE POLICY "commission_rules_select_policy" ON public.product_commission_rules
  FOR SELECT TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'commissions:view_all')
    OR public.has_permission(business_id, 'sales:view')
  );

-- 12.4 commission_earnings
CREATE POLICY "commission_earnings_select_policy" ON public.commission_earnings
  FOR SELECT TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'commissions:view_all')
    OR (
      salesperson_user_id = auth.uid()
      AND public.has_permission(business_id, 'commissions:view_own')
    )
  );

-- 12.5 commission_adjustments
CREATE POLICY "commission_adjustments_select_policy" ON public.commission_adjustments
  FOR SELECT TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'commissions:view_all')
    OR (
      salesperson_user_id = auth.uid()
      AND public.has_permission(business_id, 'commissions:view_own')
    )
  );

-- 12.6 payroll_obligations
CREATE POLICY "payroll_obligations_select_policy" ON public.payroll_obligations
  FOR SELECT TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'payroll:view')
    OR payee_id IN (SELECT p.id FROM public.payees p WHERE p.payee_user_id = auth.uid() AND p.business_id = business_id)
  );

-- 12.7 capital_returns
CREATE POLICY "capital_returns_select_policy" ON public.capital_returns
  FOR SELECT TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'legal_ownership:edit')
    OR public.has_permission(business_id, 'investor:view')
    OR investor_id IN (SELECT inv.id FROM public.investors inv WHERE inv.user_id = auth.uid() AND inv.business_id = business_id)
  );

-- 12.8 disbursements
CREATE POLICY "disbursements_select_policy" ON public.disbursements
  FOR SELECT TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'disbursements:view')
    OR payee_id IN (SELECT p.id FROM public.payees p WHERE p.payee_user_id = auth.uid() AND p.business_id = business_id)
  );

-- 12.9 disbursement_settlement_allocations
CREATE POLICY "disbursement_allocations_select_policy" ON public.disbursement_settlement_allocations
  FOR SELECT TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'disbursements:view')
  );

-- Block direct client INSERT/UPDATE/DELETE on financial ledgers
REVOKE INSERT, UPDATE, DELETE ON public.disbursements FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.disbursement_settlement_allocations FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.commission_earnings FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.commission_adjustments FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.capital_returns FROM authenticated;

-- Enforce append-only immutability triggers on financial ledgers
DROP TRIGGER IF EXISTS trg_capital_returns_immutable ON public.capital_returns;
CREATE TRIGGER trg_capital_returns_immutable
  BEFORE UPDATE OR DELETE ON public.capital_returns
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_protect_ledger_immutability();

DROP TRIGGER IF EXISTS trg_commission_earnings_immutable ON public.commission_earnings;
CREATE TRIGGER trg_commission_earnings_immutable
  BEFORE UPDATE OR DELETE ON public.commission_earnings
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_protect_ledger_immutability();

DROP TRIGGER IF EXISTS trg_commission_adjustments_immutable ON public.commission_adjustments;
CREATE TRIGGER trg_commission_adjustments_immutable
  BEFORE UPDATE OR DELETE ON public.commission_adjustments
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_protect_ledger_immutability();

DROP TRIGGER IF EXISTS trg_disb_alloc_immutable ON public.disbursement_settlement_allocations;
CREATE TRIGGER trg_disb_alloc_immutable
  BEFORE UPDATE OR DELETE ON public.disbursement_settlement_allocations
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_protect_ledger_immutability();

-- ------------------------------------------------------------------------------
-- 13. INTERNAL HELPER PRIMITIVES (STRICTLY REVOKED PRIVILEGES)
-- ------------------------------------------------------------------------------

-- Helper 13.0: Validate Payment Method, Financial Account Type, Ownership, Currency & Status
CREATE OR REPLACE FUNCTION public.fn_validate_payment_financial_account_internal(
  p_business_id UUID,
  p_payment_method TEXT,
  p_financial_account_type TEXT,
  p_financial_account_id UUID,
  p_expected_currency VARCHAR(3)
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_curr VARCHAR(3);
  v_stat TEXT;
  v_del TIMESTAMPTZ;
BEGIN
  IF p_financial_account_id IS NULL THEN
    RAISE EXCEPTION 'ACCOUNT_REQUIRED: financial_account_id is required';
  END IF;

  -- 1. Validate payment_method <-> financial_account_type binding
  IF p_payment_method = 'bank_transfer' AND p_financial_account_type <> 'bank_account' THEN
    RAISE EXCEPTION 'ACCOUNT_TYPE_MISMATCH: Payment method % requires financial_account_type bank_account', p_payment_method;
  ELSIF p_payment_method = 'vault_cash' AND p_financial_account_type <> 'vault' THEN
    RAISE EXCEPTION 'ACCOUNT_TYPE_MISMATCH: Payment method % requires financial_account_type vault', p_payment_method;
  ELSIF p_payment_method = 'petty_cash' AND p_financial_account_type <> 'petty_cash' THEN
    RAISE EXCEPTION 'ACCOUNT_TYPE_MISMATCH: Payment method % requires financial_account_type petty_cash', p_payment_method;
  ELSIF p_payment_method IN ('moncash', 'natcash') AND p_financial_account_type <> 'mobile_money' THEN
    RAISE EXCEPTION 'ACCOUNT_TYPE_MISMATCH: Payment method % requires financial_account_type mobile_money', p_payment_method;
  END IF;

  -- 2. Verify account ownership, business tenancy, currency, and status
  IF p_financial_account_type = 'bank_account' THEN
    SELECT currency, status, deleted_at INTO v_curr, v_stat, v_del
    FROM public.bank_accounts
    WHERE id = p_financial_account_id AND business_id = p_business_id;

    IF NOT FOUND OR v_del IS NOT NULL THEN
      RAISE EXCEPTION 'ACCOUNT_NOT_FOUND: Bank account % not found in business %', p_financial_account_id, p_business_id;
    END IF;
    IF v_stat <> 'active' THEN
      RAISE EXCEPTION 'ACCOUNT_INACTIVE: Bank account % is in status %', p_financial_account_id, v_stat;
    END IF;
    IF p_expected_currency IS NOT NULL AND v_curr <> p_expected_currency THEN
      RAISE EXCEPTION 'CURRENCY_MISMATCH: Bank account currency % does not match required %', v_curr, p_expected_currency;
    END IF;

  ELSIF p_financial_account_type = 'vault' THEN
    SELECT currency, status INTO v_curr, v_stat
    FROM public.vaults
    WHERE id = p_financial_account_id AND business_id = p_business_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'ACCOUNT_NOT_FOUND: Vault % not found in business %', p_financial_account_id, p_business_id;
    END IF;
    IF v_stat <> 'active' THEN
      RAISE EXCEPTION 'ACCOUNT_INACTIVE: Vault % is in status %', p_financial_account_id, v_stat;
    END IF;
    IF p_expected_currency IS NOT NULL AND v_curr <> p_expected_currency THEN
      RAISE EXCEPTION 'CURRENCY_MISMATCH: Vault currency % does not match required %', v_curr, p_expected_currency;
    END IF;

  ELSIF p_financial_account_type = 'petty_cash' THEN
    SELECT currency, status INTO v_curr, v_stat
    FROM public.petty_cash_boxes
    WHERE id = p_financial_account_id AND business_id = p_business_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'ACCOUNT_NOT_FOUND: Petty cash box % not found in business %', p_financial_account_id, p_business_id;
    END IF;
    IF v_stat <> 'active' THEN
      RAISE EXCEPTION 'ACCOUNT_INACTIVE: Petty cash box % is in status %', p_financial_account_id, v_stat;
    END IF;
    IF p_expected_currency IS NOT NULL AND v_curr <> p_expected_currency THEN
      RAISE EXCEPTION 'CURRENCY_MISMATCH: Petty cash currency % does not match required %', v_curr, p_expected_currency;
    END IF;

  ELSIF p_financial_account_type = 'mobile_money' THEN
    SELECT currency, status INTO v_curr, v_stat
    FROM public.mobile_money_wallets
    WHERE id = p_financial_account_id AND business_id = p_business_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'ACCOUNT_NOT_FOUND: Mobile money wallet % not found in business %', p_financial_account_id, p_business_id;
    END IF;
    IF v_stat <> 'active' THEN
      RAISE EXCEPTION 'ACCOUNT_INACTIVE: Mobile money wallet % is in status %', p_financial_account_id, v_stat;
    END IF;
    IF p_expected_currency IS NOT NULL AND v_curr <> p_expected_currency THEN
      RAISE EXCEPTION 'CURRENCY_MISMATCH: Mobile money wallet currency % does not match required %', v_curr, p_expected_currency;
    END IF;

  ELSE
    RAISE EXCEPTION 'INVALID_FINANCIAL_ACCOUNT_TYPE: Unrecognized type %', p_financial_account_type;
  END IF;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_validate_payment_financial_account_internal(UUID, TEXT, TEXT, UUID, VARCHAR) FROM PUBLIC, anon, authenticated;

-- Helper 13.1: Validate Salesperson Tenancy & Active Staff Status
CREATE OR REPLACE FUNCTION public.fn_validate_salesperson_internal(
  p_business_id UUID,
  p_user_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_is_active BOOLEAN;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT (employment_status = 'Active') INTO v_is_active
  FROM public.staff_profiles
  WHERE business_id = p_business_id
    AND user_id = p_user_id;

  RETURN COALESCE(v_is_active, FALSE);
END;
$$;

REVOKE ALL ON FUNCTION public.fn_validate_salesperson_internal(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- Helper 13.2: Generate Sale Line Commissions (Only from Authoritative Completed Sales)
CREATE OR REPLACE FUNCTION public.fn_generate_sale_commissions_internal(
  p_business_id UUID,
  p_transaction_id UUID,
  p_caller_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_txn RECORD;
  v_item RECORD;
  v_comm_rule RECORD;
  v_staff_id UUID;
  v_payee_id UUID;
  v_line_net_revenue NUMERIC(15, 4);
  v_unit_net_price NUMERIC(15, 4);
  v_comm_per_unit NUMERIC(15, 4);
  v_comm_total NUMERIC(15, 4);
  v_salesperson_id UUID;
BEGIN
  SELECT * INTO v_txn
  FROM public.sales_transactions
  WHERE id = p_transaction_id AND business_id = p_business_id;

  IF NOT FOUND OR v_txn.status <> 'completed' OR v_txn.transaction_type <> 'sale' THEN
    RETURN; -- Only authoritative completed sales qualify for commission generation
  END IF;

  FOR v_item IN
    SELECT *
    FROM public.sales_transaction_items
    WHERE transaction_id = p_transaction_id AND business_id = p_business_id
  LOOP
    v_salesperson_id := COALESCE(v_item.salesperson_user_id, v_txn.salesperson_user_id);
    IF v_salesperson_id IS NULL THEN
      CONTINUE; -- No commission without explicit salesperson attribution
    END IF;

    -- Verify active staff profile
    SELECT id INTO v_staff_id
    FROM public.staff_profiles
    WHERE business_id = p_business_id AND user_id = v_salesperson_id AND employment_status = 'Active';

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    -- Resolve or create internal payee anchor
    SELECT id INTO v_payee_id
    FROM public.payees
    WHERE business_id = p_business_id AND payee_user_id = v_salesperson_id;

    IF NOT FOUND THEN
      INSERT INTO public.payees (
        business_id, payee_type, payee_user_id, staff_profile_id, display_name
      )
      SELECT p_business_id, 'internal', v_salesperson_id, v_staff_id, COALESCE(full_name, 'Staff Member')
      FROM public.user_profiles
      WHERE id = v_salesperson_id
      RETURNING id INTO v_payee_id;
    END IF;

    -- Query temporal commission percentage in effect at transaction timestamp
    SELECT commission_percentage INTO v_comm_rule
    FROM public.product_commission_rules
    WHERE business_id = p_business_id
      AND product_id = v_item.product_id
      AND status IN ('active', 'superseded')
      AND v_txn.occurred_at >= effective_from
      AND (effective_to IS NULL OR v_txn.occurred_at < effective_to)
    ORDER BY effective_from DESC
    LIMIT 1;

    IF FOUND AND v_comm_rule.commission_percentage > 0.00 THEN
      -- Authoritative pre-tax sale line economics
      v_line_net_revenue := ROUND((v_item.quantity * v_item.unit_price) - v_item.discount_amount, 4);
      IF v_line_net_revenue <= 0.0000 THEN
        CONTINUE; -- 100% discount produces 0 commission
      END IF;

      v_unit_net_price := ROUND(v_line_net_revenue / v_item.quantity, 4);
      v_comm_per_unit := ROUND(v_unit_net_price * (v_comm_rule.commission_percentage / 100.0), 4);
      v_comm_total := ROUND(v_line_net_revenue * (v_comm_rule.commission_percentage / 100.0), 4);

      INSERT INTO public.commission_earnings (
        business_id, transaction_id, transaction_item_id, product_id,
        salesperson_user_id, staff_profile_id, payee_id,
        quantity, regular_unit_price, authoritative_unit_selling_price,
        commission_percentage_applied, commission_per_unit, total_commission_earned,
        currency, status, created_at
      ) VALUES (
        p_business_id, p_transaction_id, v_item.id, v_item.product_id,
        v_salesperson_id, v_staff_id, v_payee_id,
        v_item.quantity, v_item.unit_price, v_unit_net_price,
        v_comm_rule.commission_percentage, v_comm_per_unit, v_comm_total,
        v_txn.currency, 'earned', NOW()
      ) ON CONFLICT (transaction_item_id) DO NOTHING;
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_generate_sale_commissions_internal(UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;

-- Helper 13.3: Post Outgoing Treasury Channel Deduction
CREATE OR REPLACE FUNCTION public.fn_post_disbursement_treasury_internal(
  p_business_id UUID,
  p_disbursement_id UUID,
  p_payment_method TEXT,
  p_financial_account_type TEXT,
  p_financial_account_id UUID,
  p_amount NUMERIC,
  p_fee_amount NUMERIC,
  p_currency VARCHAR,
  p_disbursement_number TEXT,
  p_carrier_reference TEXT,
  p_recipient_phone TEXT,
  p_caller_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tx_id UUID;
  v_avail NUMERIC(15, 4);
  v_ledger_idempotency_key UUID;
BEGIN
  -- Derive deterministic ledger idempotency key
  v_ledger_idempotency_key := public.fn_derive_deterministic_uuid(
    p_business_id::text,
    p_disbursement_id::text,
    p_financial_account_type || ':settlement'
  );

  IF p_financial_account_type = 'bank_account' THEN
    -- Reuse authoritative frozen bank primitive from Migration 011
    v_tx_id := public.fn_post_bank_transaction_internal(
      p_business_id := p_business_id,
      p_bank_account_id := p_financial_account_id,
      p_transaction_type := 'disbursement',
      p_direction := 'debit',
      p_amount := p_amount,
      p_currency := p_currency,
      p_source_type := 'disbursement',
      p_source_id := p_disbursement_id,
      p_reference_number := p_disbursement_number,
      p_description := 'Payment Center disbursement ' || p_disbursement_number,
      p_caller_id := p_caller_id,
      p_metadata := jsonb_build_object(
        'source_domain', 'payment_center',
        'disbursement_id', p_disbursement_id,
        'disbursement_number', p_disbursement_number,
        'operation', 'settlement',
        'carrier_reference', p_carrier_reference
      )
    );
    RETURN v_tx_id;

  ELSIF p_financial_account_type = 'vault' THEN
    SELECT COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE -amount END), 0.0000)
    INTO v_avail
    FROM public.vault_transactions
    WHERE business_id = p_business_id AND vault_id = p_financial_account_id;

    IF v_avail IS NULL OR v_avail < p_amount THEN
      RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Vault has balance %, requires %', COALESCE(v_avail, 0), p_amount;
    END IF;

    -- Idempotent deduplication check
    SELECT id INTO v_tx_id
    FROM public.vault_transactions
    WHERE business_id = p_business_id AND idempotency_key = v_ledger_idempotency_key;

    IF v_tx_id IS NOT NULL THEN
      RETURN v_tx_id;
    END IF;

    INSERT INTO public.vault_transactions (
      business_id, vault_id, direction, amount, currency, transaction_type,
      description, actor_user_id, idempotency_key, occurred_at, metadata
    ) VALUES (
      p_business_id, p_financial_account_id, 'out', p_amount, p_currency, 'disbursement',
      'Vault cash disbursement ' || p_disbursement_number, p_caller_id, v_ledger_idempotency_key, NOW(),
      jsonb_build_object(
        'source_domain', 'payment_center',
        'disbursement_id', p_disbursement_id,
        'disbursement_number', p_disbursement_number,
        'operation', 'settlement'
      )
    ) RETURNING id INTO v_tx_id;
    RETURN v_tx_id;

  ELSIF p_financial_account_type = 'petty_cash' THEN
    SELECT COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE -amount END), 0.0000)
    INTO v_avail
    FROM public.petty_cash_transactions
    WHERE business_id = p_business_id AND petty_cash_account_id = p_financial_account_id;

    IF v_avail IS NULL OR v_avail < p_amount THEN
      RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Petty cash has balance %, requires %', COALESCE(v_avail, 0), p_amount;
    END IF;

    -- Idempotent deduplication check
    SELECT id INTO v_tx_id
    FROM public.petty_cash_transactions
    WHERE business_id = p_business_id AND idempotency_key = v_ledger_idempotency_key;

    IF v_tx_id IS NOT NULL THEN
      RETURN v_tx_id;
    END IF;

    INSERT INTO public.petty_cash_transactions (
      business_id, petty_cash_account_id, direction, amount, currency, transaction_type,
      notes, actor_user_id, idempotency_key, occurred_at, metadata
    ) VALUES (
      p_business_id, p_financial_account_id, 'out', p_amount, p_currency, 'disbursement',
      'Petty cash disbursement ' || p_disbursement_number, p_caller_id, v_ledger_idempotency_key, NOW(),
      jsonb_build_object(
        'source_domain', 'payment_center',
        'disbursement_id', p_disbursement_id,
        'disbursement_number', p_disbursement_number,
        'operation', 'settlement'
      )
    ) RETURNING id INTO v_tx_id;
    RETURN v_tx_id;

  ELSIF p_financial_account_type = 'mobile_money' THEN
    SELECT COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE -(amount + fee_amount) END), 0.0000)
    INTO v_avail
    FROM public.mobile_money_transactions
    WHERE business_id = p_business_id AND wallet_id = p_financial_account_id;

    IF v_avail IS NULL OR v_avail < (p_amount + COALESCE(p_fee_amount, 0)) THEN
      RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Mobile money wallet has balance %, requires %',
        COALESCE(v_avail, 0), (p_amount + COALESCE(p_fee_amount, 0));
    END IF;

    -- Idempotent deduplication check
    SELECT id INTO v_tx_id
    FROM public.mobile_money_transactions
    WHERE business_id = p_business_id AND idempotency_key = v_ledger_idempotency_key;

    IF v_tx_id IS NOT NULL THEN
      RETURN v_tx_id;
    END IF;

    INSERT INTO public.mobile_money_transactions (
      business_id, wallet_id, direction, amount, fee_amount, currency, transaction_type,
      telecom_reference, recipient_phone, description, actor_user_id, idempotency_key, occurred_at, metadata
    ) VALUES (
      p_business_id, p_financial_account_id, 'out', p_amount, COALESCE(p_fee_amount, 0), p_currency, 'payout',
      p_carrier_reference, p_recipient_phone, 'Mobile money payout ' || p_disbursement_number, p_caller_id, v_ledger_idempotency_key, NOW(),
      jsonb_build_object(
        'source_domain', 'payment_center',
        'disbursement_id', p_disbursement_id,
        'disbursement_number', p_disbursement_number,
        'operation', 'settlement'
      )
    ) RETURNING id INTO v_tx_id;
    RETURN v_tx_id;

  ELSE
    RAISE EXCEPTION 'INVALID_FINANCIAL_ACCOUNT_TYPE: % is not a recognized treasury account type', p_financial_account_type;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_post_disbursement_treasury_internal(UUID, UUID, TEXT, TEXT, UUID, NUMERIC, NUMERIC, VARCHAR, TEXT, TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------------------------
-- 14. AUTHORITATIVE RPCS (PUBLIC API)
-- ------------------------------------------------------------------------------

-- RPC 1: rpc_set_product_commission
CREATE OR REPLACE FUNCTION public.rpc_set_product_commission(
  p_business_id UUID,
  p_product_id UUID,
  p_percentage NUMERIC,
  p_effective_from TIMESTAMPTZ DEFAULT NOW(),
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_now TIMESTAMPTZ := COALESCE(p_effective_from, NOW());
  v_rule_id UUID;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'commissions:manage')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller lacks commissions:manage on business %', p_business_id;
  END IF;

  IF p_percentage < 0.00 OR p_percentage > 100.00 THEN
    RAISE EXCEPTION 'INVALID_PERCENTAGE: Commission percentage must be between 0.00 and 100.00';
  END IF;

  -- Supersede existing open-ended active rule
  UPDATE public.product_commission_rules
  SET effective_to = v_now,
      status = 'superseded'
  WHERE business_id = p_business_id
    AND product_id = p_product_id
    AND status = 'active'
    AND effective_to IS NULL;

  -- Insert new active versioned rule
  INSERT INTO public.product_commission_rules (
    business_id, product_id, commission_percentage, effective_from, effective_to,
    status, notes, created_by, created_at
  ) VALUES (
    p_business_id, p_product_id, p_percentage, v_now, NULL,
    'active', p_notes, v_caller_id, NOW()
  ) RETURNING id INTO v_rule_id;

  -- Record Commercial Audit Event
  INSERT INTO public.commercial_audit_logs (
    business_id, actor_id, action, target_type, target_id, details
  ) VALUES (
    p_business_id, v_caller_id, 'set_product_commission', 'product_commission_rules', v_rule_id,
    jsonb_build_object('product_id', p_product_id, 'percentage', p_percentage, 'effective_from', v_now)
  );

  RETURN jsonb_build_object('success', true, 'rule_id', v_rule_id, 'percentage', p_percentage);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_set_product_commission(UUID, UUID, NUMERIC, TIMESTAMPTZ, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_product_commission(UUID, UUID, NUMERIC, TIMESTAMPTZ, TEXT) TO authenticated;

-- RPC 2: rpc_create_or_update_payee
CREATE OR REPLACE FUNCTION public.rpc_create_or_update_payee(
  p_business_id UUID,
  p_payee_type TEXT,
  p_user_id UUID DEFAULT NULL,
  p_display_name TEXT DEFAULT NULL,
  p_phone TEXT DEFAULT NULL,
  p_email TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_payee_id UUID;
  v_staff_id UUID;
  v_inv_id UUID;
  v_name TEXT := TRIM(p_display_name);
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'disbursements:create')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller lacks disbursements:create on business %', p_business_id;
  END IF;

  IF p_payee_type = 'internal' THEN
    IF p_user_id IS NULL THEN
      RAISE EXCEPTION 'USER_REQUIRED: Internal payees require a canonical user_id';
    END IF;

    SELECT id INTO v_staff_id FROM public.staff_profiles WHERE business_id = p_business_id AND user_id = p_user_id;
    SELECT id INTO v_inv_id FROM public.investors WHERE business_id = p_business_id AND user_id = p_user_id;

    IF v_name IS NULL OR v_name = '' THEN
      SELECT full_name INTO v_name FROM public.user_profiles WHERE id = p_user_id;
    END IF;

    INSERT INTO public.payees (
      business_id, payee_type, payee_user_id, staff_profile_id, investor_id,
      display_name, phone, email, status, updated_at
    ) VALUES (
      p_business_id, 'internal', p_user_id, v_staff_id, v_inv_id,
      COALESCE(v_name, 'Internal User'), p_phone, p_email, 'active', NOW()
    )
    ON CONFLICT (business_id, payee_user_id) DO UPDATE SET
      staff_profile_id = EXCLUDED.staff_profile_id,
      investor_id = EXCLUDED.investor_id,
      display_name = COALESCE(EXCLUDED.display_name, payees.display_name),
      phone = COALESCE(EXCLUDED.phone, payees.phone),
      email = COALESCE(EXCLUDED.email, payees.email),
      status = 'active',
      updated_at = NOW()
    RETURNING id INTO v_payee_id;

  ELSIF p_payee_type = 'external' THEN
    IF v_name IS NULL OR v_name = '' THEN
      RAISE EXCEPTION 'NAME_REQUIRED: External payees require a display_name';
    END IF;

    INSERT INTO public.payees (
      business_id, payee_type, payee_user_id, display_name, phone, email, status, updated_at
    ) VALUES (
      p_business_id, 'external', NULL, v_name, p_phone, p_email, 'active', NOW()
    ) RETURNING id INTO v_payee_id;
  ELSE
    RAISE EXCEPTION 'INVALID_PAYEE_TYPE: Must be internal or external';
  END IF;

  RETURN jsonb_build_object('success', true, 'payee_id', v_payee_id, 'display_name', v_name);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_create_or_update_payee(UUID, TEXT, UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_or_update_payee(UUID, TEXT, UUID, TEXT, TEXT, TEXT) TO authenticated;

-- RPC 3: rpc_set_payee_payment_destination
CREATE OR REPLACE FUNCTION public.rpc_set_payee_payment_destination(
  p_business_id UUID,
  p_payee_id UUID,
  p_destination_type TEXT,
  p_account_holder_name TEXT,
  p_bank_name TEXT DEFAULT NULL,
  p_account_number TEXT DEFAULT NULL,
  p_routing_number TEXT DEFAULT NULL,
  p_phone_number TEXT DEFAULT NULL,
  p_is_default BOOLEAN DEFAULT false
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_payee RECORD;
  v_masked TEXT;
  v_dest_id UUID;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  SELECT * INTO v_payee
  FROM public.payees
  WHERE id = p_payee_id AND business_id = p_business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PAYEE_NOT_FOUND: Payee % not found in business %', p_payee_id, p_business_id;
  END IF;

  -- Security Policy: Must be Owner/Finance OR the payee managing their own destination
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'disbursements:create')
    OR v_payee.payee_user_id = v_caller_id
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Not authorized to manage destinations for payee %', p_payee_id;
  END IF;

  -- Masking Strategy: preserve only last 4 digits
  IF p_account_number IS NOT NULL AND length(trim(p_account_number)) >= 4 THEN
    v_masked := '****' || substring(trim(p_account_number) from length(trim(p_account_number)) - 3);
  ELSE
    v_masked := '****';
  END IF;

  IF p_is_default THEN
    UPDATE public.payee_payment_destinations
    SET is_default = false
    WHERE business_id = p_business_id AND payee_id = p_payee_id;
  END IF;

  INSERT INTO public.payee_payment_destinations (
    business_id, payee_id, destination_type, account_holder_name,
    bank_name, account_number_masked, routing_number, phone_number, is_default, verified, updated_at
  ) VALUES (
    p_business_id, p_payee_id, p_destination_type, p_account_holder_name,
    p_bank_name, v_masked, p_routing_number, p_phone_number, p_is_default, false, NOW()
  ) RETURNING id INTO v_dest_id;

  INSERT INTO public.commercial_audit_logs (
    business_id, actor_id, action, target_type, target_id, details
  ) VALUES (
    p_business_id, v_caller_id, 'set_payee_destination', 'payee_payment_destinations', v_dest_id,
    jsonb_build_object('payee_id', p_payee_id, 'destination_type', p_destination_type, 'masked', v_masked)
  );

  RETURN jsonb_build_object('success', true, 'destination_id', v_dest_id, 'masked', v_masked);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_set_payee_payment_destination(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_payee_payment_destination(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN) TO authenticated;

-- RPC 4: rpc_generate_salary_payroll_run (MANDATORY IDEMPOTENCY)
CREATE OR REPLACE FUNCTION public.rpc_generate_salary_payroll_run(
  p_business_id UUID,
  p_pay_period_start DATE,
  p_pay_period_end DATE,
  p_payment_due_date DATE,
  p_idempotency_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_biz_currency VARCHAR(3);
  v_request_hash VARCHAR(64);
  v_idem_res JSONB;
  v_staff RECORD;
  v_payee_id UUID;
  v_payroll_num TEXT;
  v_count INT := 0;
  v_total NUMERIC(15, 4) := 0.0000;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_generate_salary_payroll_run';
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'payroll:run')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller lacks payroll:run on business %', p_business_id;
  END IF;

  -- 1. Idempotency Check
  v_request_hash := encode(sha256(jsonb_build_object(
    'action', 'generate_salary_payroll_run',
    'business_id', p_business_id,
    'start', p_pay_period_start,
    'end', p_pay_period_end,
    'due', p_payment_due_date
  )::text::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(p_business_id, p_idempotency_key, 'generate_payroll_run', v_request_hash, v_caller_id);
  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN (v_idem_res->'payload');
  END IF;

  SELECT currency INTO v_biz_currency FROM public.businesses WHERE id = p_business_id;

  -- Query active staff with fixed salary compensation
  FOR v_staff IN
    SELECT sp.id AS staff_profile_id, sp.user_id, sc.base_rate, sc.compensation_type, sc.id AS comp_id
    FROM public.staff_profiles sp
    JOIN public.staff_compensation sc ON sc.staff_profile_id = sp.id AND sc.business_id = p_business_id
    WHERE sp.business_id = p_business_id
      AND sp.employment_status = 'Active'
      AND sc.status = 'active'
      AND sc.compensation_type = 'Salary'
  LOOP
    -- Resolve payee
    SELECT id INTO v_payee_id FROM public.payees WHERE business_id = p_business_id AND payee_user_id = v_staff.user_id;
    IF NOT FOUND THEN
      INSERT INTO public.payees (
        business_id, payee_type, payee_user_id, staff_profile_id, display_name
      )
      SELECT p_business_id, 'internal', v_staff.user_id, v_staff.staff_profile_id, full_name
      FROM public.user_profiles WHERE id = v_staff.user_id
      RETURNING id INTO v_payee_id;
    END IF;

    -- Avoid duplicate period run for staff
    IF NOT EXISTS (
      SELECT 1 FROM public.payroll_obligations
      WHERE business_id = p_business_id
        AND staff_profile_id = v_staff.staff_profile_id
        AND pay_period_start = p_pay_period_start
        AND pay_period_end = p_pay_period_end
    ) THEN
      v_payroll_num := public.rpc_next_document_number(p_business_id, 'payroll', 'PAY');

      INSERT INTO public.payroll_obligations (
        business_id, payroll_number, staff_profile_id, payee_id,
        pay_period_start, pay_period_end, payment_due_date,
        compensation_snapshot, base_amount, allowances, deductions, net_payable,
        currency, status, created_by, created_at, updated_at
      ) VALUES (
        p_business_id, v_payroll_num, v_staff.staff_profile_id, v_payee_id,
        p_pay_period_start, p_pay_period_end, p_payment_due_date,
        jsonb_build_object('comp_id', v_staff.comp_id, 'base_rate', v_staff.base_rate, 'type', v_staff.compensation_type),
        v_staff.base_rate, 0.0000, 0.0000, v_staff.base_rate,
        v_biz_currency, 'approved', v_caller_id, NOW(), NOW()
      );

      v_count := v_count + 1;
      v_total := v_total + v_staff.base_rate;
    END IF;
  END LOOP;

  v_result := jsonb_build_object(
    'success', true,
    'generated_count', v_count,
    'total_payroll_amount', v_total,
    'currency', v_biz_currency
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);
  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_generate_salary_payroll_run(UUID, DATE, DATE, DATE, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_generate_salary_payroll_run(UUID, DATE, DATE, DATE, UUID) TO authenticated;

-- RPC 5: rpc_submit_disbursement_request (MANDATORY IDEMPOTENCY)
CREATE OR REPLACE FUNCTION public.rpc_submit_disbursement_request(
  p_business_id UUID,
  p_disbursement_category TEXT,
  p_payee_id UUID,
  p_amount NUMERIC,
  p_currency VARCHAR,
  p_payment_method TEXT,
  p_financial_account_type TEXT,
  p_financial_account_id UUID,
  p_allocations JSONB, -- Array of {obligation_type, obligation_id, amount}
  p_description TEXT,
  p_idempotency_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_request_hash VARCHAR(64);
  v_idem_res JSONB;
  v_payee RECORD;
  v_disb_number TEXT;
  v_disb_id UUID;
  v_elem RECORD;
  v_alloc_amount NUMERIC(15, 4);
  v_obligation_id UUID;
  v_obligation_type TEXT;
  v_alloc_total NUMERIC(15, 4) := 0.0000;
  
  -- Capital return reservation variables
  v_gross_cap NUMERIC(15, 4);
  v_ret_cap NUMERIC(15, 4);
  v_res_cap NUMERIC(15, 4);
  v_avail_cap NUMERIC(15, 4);

  -- Commission pool verification
  v_comm_earned NUMERIC(15, 4);
  v_comm_adj NUMERIC(15, 4);
  v_comm_settled NUMERIC(15, 4);
  v_comm_avail NUMERIC(15, 4);

  -- Obligation validation variables
  v_payroll_rec RECORD;
  v_div_rec RECORD;
  v_comm_rec RECORD;
  v_orig_cap_rec RECORD;
  v_already_allocated NUMERIC(15, 4);
  v_remaining_unpaid NUMERIC(15, 4);
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_submit_disbursement_request';
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'disbursements:create')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller lacks disbursements:create on business %', p_business_id;
  END IF;

  IF p_amount <= 0.0000 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT: Disbursement amount must be greater than zero';
  END IF;

  -- 1. Idempotency Check
  v_request_hash := encode(sha256(jsonb_build_object(
    'business_id', p_business_id,
    'category', p_disbursement_category,
    'payee_id', p_payee_id,
    'amount', p_amount,
    'currency', p_currency,
    'account_type', p_financial_account_type,
    'account_id', p_financial_account_id,
    'allocations', COALESCE(p_allocations, '[]'::jsonb)
  )::text::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(p_business_id, p_idempotency_key, 'submit_disbursement', v_request_hash, v_caller_id);
  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN (v_idem_res->'payload');
  END IF;

  SELECT * INTO v_payee FROM public.payees WHERE id = p_payee_id AND business_id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PAYEE_NOT_FOUND: Payee % not found in business %', p_payee_id, p_business_id;
  END IF;

  -- Validate Account Binding, Ownership, Currency and Status
  PERFORM public.fn_validate_payment_financial_account_internal(
    p_business_id,
    p_payment_method,
    p_financial_account_type,
    p_financial_account_id,
    p_currency
  );

  -- 2. Validate Allocations Rigorously Server-Side
  IF p_allocations IS NOT NULL AND jsonb_typeof(p_allocations) = 'array' AND jsonb_array_length(p_allocations) > 0 THEN
    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
      v_obligation_type := v_elem.value->>'obligation_type';
      v_obligation_id := (v_elem.value->>'obligation_id')::UUID;
      v_alloc_amount := ((v_elem.value->>'amount')::NUMERIC);

      IF v_obligation_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_ALLOCATION: obligation_id cannot be null';
      END IF;

      IF v_alloc_amount IS NULL OR v_alloc_amount <= 0.0000 THEN
        RAISE EXCEPTION 'INVALID_ALLOCATION: Allocation amount must be positive';
      END IF;

      -- Check category matching
      IF v_obligation_type <> p_disbursement_category THEN
        RAISE EXCEPTION 'OBLIGATION_CATEGORY_MISMATCH: Allocation obligation_type % does not match disbursement category %',
          v_obligation_type, p_disbursement_category;
      END IF;

      -- Validate against specific authoritative obligation record
      IF v_obligation_type = 'payroll' THEN
        SELECT * INTO v_payroll_rec
        FROM public.payroll_obligations
        WHERE id = v_obligation_id AND business_id = p_business_id;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'OBLIGATION_NOT_FOUND: Payroll obligation % not found in business %', v_obligation_id, p_business_id;
        END IF;

        IF v_payroll_rec.payee_id <> p_payee_id THEN
          RAISE EXCEPTION 'PAYEE_MISMATCH: Payroll obligation % belongs to payee %, not voucher payee %',
            v_obligation_id, v_payroll_rec.payee_id, p_payee_id;
        END IF;

        IF v_payroll_rec.currency <> p_currency THEN
          RAISE EXCEPTION 'CURRENCY_MISMATCH: Payroll obligation currency % does not match voucher currency %',
            v_payroll_rec.currency, p_currency;
        END IF;

        IF v_payroll_rec.status NOT IN ('approved', 'draft') THEN
          RAISE EXCEPTION 'OBLIGATION_INVALID_STATUS: Payroll obligation % is in status %', v_obligation_id, v_payroll_rec.status;
        END IF;

        -- Calculate cumulative allocated across non-reversed disbursements
        SELECT COALESCE(SUM(dsa.amount_allocated), 0.0000) INTO v_already_allocated
        FROM public.disbursement_settlement_allocations dsa
        JOIN public.disbursements d ON d.id = dsa.disbursement_id
        WHERE d.business_id = p_business_id
          AND dsa.obligation_type = 'payroll'
          AND dsa.obligation_id = v_obligation_id
          AND d.status NOT IN ('cancelled', 'reversed', 'rejected');

        v_remaining_unpaid := v_payroll_rec.net_payable - v_already_allocated;
        IF v_alloc_amount > v_remaining_unpaid THEN
          RAISE EXCEPTION 'ALLOCATION_EXCEEDS_UNPAID: Allocation % exceeds remaining unpaid amount % on payroll %',
            v_alloc_amount, v_remaining_unpaid, v_payroll_rec.payroll_number;
        END IF;

      ELSIF v_obligation_type = 'dividend' THEN
        IF v_payee.investor_id IS NULL THEN
          RAISE EXCEPTION 'INVALID_INVESTOR: Payee % is not linked to an investor profile', p_payee_id;
        END IF;

        SELECT * INTO v_div_rec
        FROM public.dividend_payouts
        WHERE id = v_obligation_id AND business_id = p_business_id;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'OBLIGATION_NOT_FOUND: Dividend payout % not found in business %', v_obligation_id, p_business_id;
        END IF;

        IF v_div_rec.investor_id <> v_payee.investor_id THEN
          RAISE EXCEPTION 'INVESTOR_MISMATCH: Dividend payout % belongs to investor %, not voucher payee investor %',
            v_obligation_id, v_div_rec.investor_id, v_payee.investor_id;
        END IF;

        IF v_div_rec.currency <> p_currency THEN
          RAISE EXCEPTION 'CURRENCY_MISMATCH: Dividend payout currency % does not match voucher currency %',
            v_div_rec.currency, p_currency;
        END IF;

        IF v_div_rec.status <> 'approved' THEN
          RAISE EXCEPTION 'OBLIGATION_INVALID_STATUS: Dividend payout % is in status %', v_obligation_id, v_div_rec.status;
        END IF;

        SELECT COALESCE(SUM(dsa.amount_allocated), 0.0000) INTO v_already_allocated
        FROM public.disbursement_settlement_allocations dsa
        JOIN public.disbursements d ON d.id = dsa.disbursement_id
        WHERE d.business_id = p_business_id
          AND dsa.obligation_type = 'dividend'
          AND dsa.obligation_id = v_obligation_id
          AND d.status NOT IN ('cancelled', 'reversed', 'rejected');

        v_remaining_unpaid := v_div_rec.net_amount - v_already_allocated;
        IF v_alloc_amount > v_remaining_unpaid THEN
          RAISE EXCEPTION 'ALLOCATION_EXCEEDS_UNPAID: Allocation % exceeds remaining unpaid amount % on dividend %',
            v_alloc_amount, v_remaining_unpaid, v_obligation_id;
        END IF;

      ELSIF v_obligation_type = 'commission' THEN
        SELECT * INTO v_comm_rec
        FROM public.commission_earnings
        WHERE id = v_obligation_id AND business_id = p_business_id;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'OBLIGATION_NOT_FOUND: Commission earning % not found in business %', v_obligation_id, p_business_id;
        END IF;

        IF v_comm_rec.payee_id <> p_payee_id THEN
          RAISE EXCEPTION 'PAYEE_MISMATCH: Commission earning % belongs to payee %, not voucher payee %',
            v_obligation_id, v_comm_rec.payee_id, p_payee_id;
        END IF;

        IF v_comm_rec.currency <> p_currency THEN
          RAISE EXCEPTION 'CURRENCY_MISMATCH: Commission earning currency % does not match voucher currency %',
            v_comm_rec.currency, p_currency;
        END IF;

        SELECT COALESCE(SUM(dsa.amount_allocated), 0.0000) INTO v_already_allocated
        FROM public.disbursement_settlement_allocations dsa
        JOIN public.disbursements d ON d.id = dsa.disbursement_id
        WHERE d.business_id = p_business_id
          AND dsa.obligation_type = 'commission'
          AND dsa.obligation_id = v_obligation_id
          AND d.status NOT IN ('cancelled', 'reversed', 'rejected');

        v_remaining_unpaid := v_comm_rec.total_commission_earned - v_already_allocated;
        IF v_alloc_amount > v_remaining_unpaid THEN
          RAISE EXCEPTION 'ALLOCATION_EXCEEDS_UNPAID: Allocation % exceeds remaining unpaid amount % on earning %',
            v_alloc_amount, v_remaining_unpaid, v_obligation_id;
        END IF;

      ELSIF v_obligation_type = 'capital_return' THEN
        IF v_payee.investor_id IS NULL THEN
          RAISE EXCEPTION 'INVALID_INVESTOR: Payee % is not an investor for capital return', p_payee_id;
        END IF;

        SELECT * INTO v_orig_cap_rec
        FROM public.capital_contributions
        WHERE id = v_obligation_id AND business_id = p_business_id;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'OBLIGATION_NOT_FOUND: Capital contribution % not found in business %', v_obligation_id, p_business_id;
        END IF;

        IF v_orig_cap_rec.investor_id <> v_payee.investor_id THEN
          RAISE EXCEPTION 'INVESTOR_MISMATCH: Capital contribution % belongs to investor %, not voucher payee investor %',
            v_obligation_id, v_orig_cap_rec.investor_id, v_payee.investor_id;
        END IF;
      END IF;

      v_alloc_total := v_alloc_total + v_alloc_amount;
    END LOOP;

    -- Allocation totals must equal the voucher amount exactly
    IF v_alloc_total <> p_amount THEN
      RAISE EXCEPTION 'ALLOCATION_TOTAL_MISMATCH: Total allocations (%) must equal voucher amount (%)',
        v_alloc_total, p_amount;
    END IF;
  END IF;

  -- 3. Category-Specific Reservoir & Concurrency Locks
  IF p_disbursement_category = 'capital_return' THEN
    IF v_payee.investor_id IS NULL THEN
      RAISE EXCEPTION 'INVALID_INVESTOR: Payee % is not an investor for capital return', p_payee_id;
    END IF;

    -- Concurrency Lock on Investor
    PERFORM id FROM public.investors WHERE id = v_payee.investor_id AND business_id = p_business_id FOR UPDATE;

    SELECT COALESCE(SUM(amount), 0.0000) INTO v_gross_cap
    FROM public.capital_contributions WHERE business_id = p_business_id AND investor_id = v_payee.investor_id;

    SELECT COALESCE(SUM(CASE WHEN entry_type = 'return' THEN return_amount ELSE -return_amount END), 0.0000) INTO v_ret_cap
    FROM public.capital_returns WHERE business_id = p_business_id AND investor_id = v_payee.investor_id;

    SELECT COALESCE(SUM(amount), 0.0000) INTO v_res_cap
    FROM public.disbursements
    WHERE business_id = p_business_id AND payee_id = p_payee_id AND disbursement_category = 'capital_return'
      AND status IN ('pending_approval', 'approved');

    v_avail_cap := v_gross_cap - v_ret_cap - v_res_cap;
    IF p_amount > v_avail_cap THEN
      RAISE EXCEPTION 'INSUFFICIENT_RETURNABLE_CAPITAL: Requested return % exceeds available net capital %', p_amount, v_avail_cap;
    END IF;

  ELSIF p_disbursement_category = 'commission' THEN
    -- Verify Net Commission Balance
    SELECT COALESCE(SUM(total_commission_earned), 0.0000) INTO v_comm_earned
    FROM public.commission_earnings WHERE business_id = p_business_id AND payee_id = p_payee_id;

    SELECT COALESCE(SUM(amount), 0.0000) INTO v_comm_adj
    FROM public.commission_adjustments WHERE business_id = p_business_id AND payee_id = p_payee_id;

    SELECT COALESCE(SUM(dsa.amount_allocated), 0.0000) INTO v_comm_settled
    FROM public.disbursement_settlement_allocations dsa
    JOIN public.disbursements d ON d.id = dsa.disbursement_id
    WHERE d.business_id = p_business_id AND d.payee_id = p_payee_id
      AND dsa.obligation_type = 'commission' AND d.status NOT IN ('cancelled', 'reversed', 'rejected');

    v_comm_avail := v_comm_earned + v_comm_adj - v_comm_settled;
    IF p_amount > v_comm_avail THEN
      RAISE EXCEPTION 'INSUFFICIENT_COMMISSION_BALANCE: Requested % exceeds net available commission %', p_amount, v_comm_avail;
    END IF;
  END IF;

  -- 4. Create Disbursement Voucher
  v_disb_number := public.rpc_next_document_number(p_business_id, 'disbursement', 'DISB');

  INSERT INTO public.disbursements (
    business_id, disbursement_number, disbursement_category, payee_id,
    amount, currency, payment_method, financial_account_type, financial_account_id,
    status, created_by, description, notes, created_at, updated_at
  ) VALUES (
    p_business_id, v_disb_number, p_disbursement_category, p_payee_id,
    p_amount, p_currency, p_payment_method, p_financial_account_type, p_financial_account_id,
    'pending_approval', v_caller_id, COALESCE(p_description, 'Outgoing Disbursement'), '', NOW(), NOW()
  ) RETURNING id INTO v_disb_id;

  -- 5. Record Validated Settlement Allocations
  IF p_allocations IS NOT NULL AND jsonb_typeof(p_allocations) = 'array' THEN
    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
      v_obligation_type := v_elem.value->>'obligation_type';
      v_obligation_id := (v_elem.value->>'obligation_id')::UUID;
      v_alloc_amount := ((v_elem.value->>'amount')::NUMERIC);

      IF v_alloc_amount > 0 THEN
        INSERT INTO public.disbursement_settlement_allocations (
          business_id, disbursement_id, obligation_type, obligation_id, amount_allocated, created_at
        ) VALUES (
          p_business_id, v_disb_id, v_obligation_type, v_obligation_id, v_alloc_amount, NOW()
        ) ON CONFLICT (disbursement_id, obligation_type, obligation_id) DO NOTHING;
      END IF;
    END LOOP;
  END IF;

  v_result := jsonb_build_object(
    'success', true,
    'disbursement_id', v_disb_id,
    'disbursement_number', v_disb_number,
    'status', 'pending_approval',
    'amount', p_amount
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);
  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_submit_disbursement_request(UUID, TEXT, UUID, NUMERIC, VARCHAR, TEXT, TEXT, UUID, JSONB, TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_submit_disbursement_request(UUID, TEXT, UUID, NUMERIC, VARCHAR, TEXT, TEXT, UUID, JSONB, TEXT, UUID) TO authenticated;

-- RPC 5.1: rpc_approve_disbursement_request (SEPARATION OF APPROVAL & EXECUTION)
CREATE OR REPLACE FUNCTION public.rpc_approve_disbursement_request(
  p_business_id UUID,
  p_disbursement_id UUID,
  p_idempotency_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_request_hash VARCHAR(64);
  v_idem_res JSONB;
  v_disb RECORD;
  v_payee RECORD;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_approve_disbursement_request';
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'disbursements:approve')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller lacks disbursements:approve on business %', p_business_id;
  END IF;

  v_request_hash := encode(sha256(jsonb_build_object(
    'action', 'approve_disbursement',
    'business_id', p_business_id,
    'disbursement_id', p_disbursement_id
  )::text::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(p_business_id, p_idempotency_key, 'approve_disbursement', v_request_hash, v_caller_id);
  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN (v_idem_res->'payload');
  END IF;

  SELECT * INTO v_disb
  FROM public.disbursements
  WHERE id = p_disbursement_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DISBURSEMENT_NOT_FOUND: Voucher % not found in business %', p_disbursement_id, p_business_id;
  END IF;

  IF v_disb.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'INVALID_STATUS: Voucher % is in status %; only pending_approval vouchers can be approved',
      p_disbursement_id, v_disb.status;
  END IF;

  SELECT * INTO v_payee FROM public.payees WHERE id = v_disb.payee_id;

  -- Anti-Self-Approval: Creator cannot approve, payee cannot approve
  IF v_caller_id = v_disb.created_by THEN
    RAISE EXCEPTION 'SELF_APPROVAL_PROHIBITED: Creator % cannot approve their own disbursement voucher', v_caller_id;
  END IF;

  IF v_caller_id = v_payee.payee_user_id THEN
    RAISE EXCEPTION 'SELF_APPROVAL_PROHIBITED: Payee % cannot approve their own disbursement voucher', v_caller_id;
  END IF;

  UPDATE public.disbursements
  SET status = 'approved',
      approved_by = v_caller_id,
      approved_at = NOW(),
      updated_at = NOW()
  WHERE id = v_disb.id;

  INSERT INTO public.commercial_audit_logs (
    business_id, actor_id, action, target_type, target_id, details
  ) VALUES (
    p_business_id, v_caller_id, 'approve_disbursement', 'disbursements', v_disb.id,
    jsonb_build_object('disbursement_number', v_disb.disbursement_number, 'amount', v_disb.amount)
  );

  v_result := jsonb_build_object(
    'success', true,
    'disbursement_id', v_disb.id,
    'status', 'approved',
    'approved_by', v_caller_id
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);
  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_approve_disbursement_request(UUID, UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_approve_disbursement_request(UUID, UUID, UUID) TO authenticated;

-- RPC 6: rpc_approve_and_disburse (MANDATORY IDEMPOTENCY)
CREATE OR REPLACE FUNCTION public.rpc_approve_and_disburse(
  p_business_id UUID,
  p_disbursement_id UUID,
  p_payment_method TEXT,
  p_financial_account_type TEXT,
  p_financial_account_id UUID,
  p_carrier_reference TEXT DEFAULT NULL,
  p_recipient_phone TEXT DEFAULT NULL,
  p_idempotency_key UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_request_hash VARCHAR(64);
  v_idem_res JSONB;
  v_disb RECORD;
  v_payee RECORD;
  v_tx_id UUID;
  v_cap_entry_num INT;
  v_alloc RECORD;
  v_total_effective_settled NUMERIC(15, 4);
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_approve_and_disburse';
  END IF;

  -- 1. Idempotency Check
  v_request_hash := encode(sha256(jsonb_build_object(
    'action', 'approve_and_disburse',
    'business_id', p_business_id,
    'disbursement_id', p_disbursement_id,
    'account_id', p_financial_account_id,
    'payment_method', p_payment_method
  )::text::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(p_business_id, p_idempotency_key, 'settle_disbursement', v_request_hash, v_caller_id);
  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN (v_idem_res->'payload');
  END IF;

  -- 2. Lock & Retrieve Disbursement Voucher
  SELECT * INTO v_disb
  FROM public.disbursements
  WHERE id = p_disbursement_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DISBURSEMENT_NOT_FOUND: Voucher % not found in business %', p_disbursement_id, p_business_id;
  END IF;

  -- True Separation of Approval & Execution: Voucher MUST be in 'approved' status
  IF v_disb.status <> 'approved' THEN
    RAISE EXCEPTION 'UNAPPROVED_VOUCHER: Disbursement % is in status %; voucher must be explicitly approved by an authorized manager before execution',
      p_disbursement_id, v_disb.status;
  END IF;

  -- 3. Authorization & Anti-Self-Execution
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'disbursements:pay')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller lacks disbursements:pay on business %', p_business_id;
  END IF;

  SELECT * INTO v_payee FROM public.payees WHERE id = v_disb.payee_id;

  -- Creator cannot execute, payee cannot execute
  IF v_caller_id = v_disb.created_by THEN
    RAISE EXCEPTION 'SELF_EXECUTION_PROHIBITED: Creator % cannot execute payment for their own voucher', v_caller_id;
  END IF;

  IF v_caller_id = v_payee.payee_user_id THEN
    RAISE EXCEPTION 'SELF_EXECUTION_PROHIBITED: Payee % cannot execute payment for their own voucher', v_caller_id;
  END IF;

  -- Validate Account Binding, Ownership, Currency and Status at Execution
  PERFORM public.fn_validate_payment_financial_account_internal(
    p_business_id,
    p_payment_method,
    p_financial_account_type,
    p_financial_account_id,
    v_disb.currency
  );

  -- 4. Deduct Treasury Funds via Authoritative Internal Primitive
  v_tx_id := public.fn_post_disbursement_treasury_internal(
    p_business_id := p_business_id,
    p_disbursement_id := v_disb.id,
    p_payment_method := p_payment_method,
    p_financial_account_type := p_financial_account_type,
    p_financial_account_id := p_financial_account_id,
    p_amount := v_disb.amount,
    p_fee_amount := v_disb.fee_amount,
    p_currency := v_disb.currency,
    p_disbursement_number := v_disb.disbursement_number,
    p_carrier_reference := p_carrier_reference,
    p_recipient_phone := p_recipient_phone,
    p_caller_id := v_caller_id
  );

  -- 5. Category-Specific Settlement Finalization with Partial Settlement Semantics
  IF v_disb.disbursement_category = 'capital_return' THEN
    -- Serialize entry numbering across business
    PERFORM pg_advisory_xact_lock(('x' || substr(md5(p_business_id::text || ':capital_returns'), 1, 16))::bit(64)::bigint);

    SELECT COALESCE(MAX(entry_number), 0) + 1 INTO v_cap_entry_num
    FROM public.capital_returns WHERE business_id = p_business_id;

    INSERT INTO public.capital_returns (
      business_id, investor_id, entry_number, entry_type, return_amount, effective_date,
      disbursement_id, notes, created_by, created_at
    ) VALUES (
      p_business_id, v_payee.investor_id, v_cap_entry_num, 'return', v_disb.amount, CURRENT_DATE,
      v_disb.id, 'Capital redemption via disbursement ' || v_disb.disbursement_number, v_caller_id, NOW()
    );

  ELSIF v_disb.disbursement_category = 'commission' THEN
    -- For each allocated commission earning: only mark 'settled' if cumulative effective allocations == total_commission_earned
    FOR v_alloc IN
      SELECT dsa.obligation_id, ce.total_commission_earned
      FROM public.disbursement_settlement_allocations dsa
      JOIN public.commission_earnings ce ON ce.id = dsa.obligation_id
      WHERE dsa.disbursement_id = v_disb.id AND dsa.obligation_type = 'commission'
    LOOP
      SELECT COALESCE(SUM(dsa2.amount_allocated), 0.0000) INTO v_total_effective_settled
      FROM public.disbursement_settlement_allocations dsa2
      JOIN public.disbursements d2 ON d2.id = dsa2.disbursement_id
      WHERE d2.business_id = p_business_id
        AND dsa2.obligation_type = 'commission'
        AND dsa2.obligation_id = v_alloc.obligation_id
        AND d2.status IN ('disbursed', 'approved');

      IF v_total_effective_settled >= v_alloc.total_commission_earned THEN
        UPDATE public.commission_earnings
        SET status = 'settled'
        WHERE id = v_alloc.obligation_id AND business_id = p_business_id;
      END IF;
    END LOOP;

  ELSIF v_disb.disbursement_category = 'payroll' THEN
    -- For each allocated payroll obligation: only mark 'settled' if cumulative effective allocations == net_payable
    FOR v_alloc IN
      SELECT dsa.obligation_id, po.net_payable
      FROM public.disbursement_settlement_allocations dsa
      JOIN public.payroll_obligations po ON po.id = dsa.obligation_id
      WHERE dsa.disbursement_id = v_disb.id AND dsa.obligation_type = 'payroll'
    LOOP
      SELECT COALESCE(SUM(dsa2.amount_allocated), 0.0000) INTO v_total_effective_settled
      FROM public.disbursement_settlement_allocations dsa2
      JOIN public.disbursements d2 ON d2.id = dsa2.disbursement_id
      WHERE d2.business_id = p_business_id
        AND dsa2.obligation_type = 'payroll'
        AND dsa2.obligation_id = v_alloc.obligation_id
        AND d2.status IN ('disbursed', 'approved');

      IF v_total_effective_settled >= v_alloc.net_payable THEN
        UPDATE public.payroll_obligations
        SET status = 'settled',
            updated_at = NOW()
        WHERE id = v_alloc.obligation_id AND business_id = p_business_id;
      END IF;
    END LOOP;

  ELSIF v_disb.disbursement_category = 'dividend' THEN
    -- Transition linked dividend_payouts record only if fully settled
    FOR v_alloc IN
      SELECT dsa.obligation_id, dp.net_amount
      FROM public.disbursement_settlement_allocations dsa
      JOIN public.dividend_payouts dp ON dp.id = dsa.obligation_id
      WHERE dsa.disbursement_id = v_disb.id AND dsa.obligation_type = 'dividend'
    LOOP
      SELECT COALESCE(SUM(dsa2.amount_allocated), 0.0000) INTO v_total_effective_settled
      FROM public.disbursement_settlement_allocations dsa2
      JOIN public.disbursements d2 ON d2.id = dsa2.disbursement_id
      WHERE d2.business_id = p_business_id
        AND dsa2.obligation_type = 'dividend'
        AND dsa2.obligation_id = v_alloc.obligation_id
        AND d2.status IN ('disbursed', 'approved');

      IF v_total_effective_settled >= v_alloc.net_amount THEN
        UPDATE public.dividend_payouts
        SET status = 'paid',
            disbursement_date = CURRENT_DATE,
            payment_method = p_payment_method,
            reference_identifier = v_disb.disbursement_number,
            updated_at = NOW()
        WHERE id = v_alloc.obligation_id AND business_id = p_business_id AND status = 'approved';
      END IF;
    END LOOP;
  END IF;

  -- 6. Mark Disbursement Completed
  UPDATE public.disbursements
  SET status = 'disbursed',
      settlement_treasury_tx_id = v_tx_id,
      payment_method = p_payment_method,
      financial_account_type = p_financial_account_type,
      financial_account_id = p_financial_account_id,
      carrier_reference = p_carrier_reference,
      recipient_phone = p_recipient_phone,
      disbursed_by = v_caller_id,
      disbursed_at = NOW(),
      updated_at = NOW()
  WHERE id = v_disb.id;

  -- 7. Audit Event
  INSERT INTO public.commercial_audit_logs (
    business_id, actor_id, action, target_type, target_id, details
  ) VALUES (
    p_business_id, v_caller_id, 'settle_disbursement', 'disbursements', v_disb.id,
    jsonb_build_object(
      'amount', v_disb.amount,
      'category', v_disb.disbursement_category,
      'treasury_tx_id', v_tx_id,
      'disbursement_number', v_disb.disbursement_number
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'disbursement_id', v_disb.id,
    'status', 'disbursed',
    'treasury_tx_id', v_tx_id,
    'amount', v_disb.amount
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);
  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_approve_and_disburse(UUID, UUID, TEXT, TEXT, UUID, TEXT, TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_approve_and_disburse(UUID, UUID, TEXT, TEXT, UUID, TEXT, TEXT, UUID) TO authenticated;

-- RPC 7: rpc_reverse_disbursement (MANDATORY IDEMPOTENCY)
CREATE OR REPLACE FUNCTION public.rpc_reverse_disbursement(
  p_business_id UUID,
  p_disbursement_id UUID,
  p_reversal_reason TEXT,
  p_idempotency_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_request_hash VARCHAR(64);
  v_idem_res JSONB;
  v_disb RECORD;
  v_original_treasury_tx_id UUID;
  v_reversal_tx_id UUID;
  v_reversal_idempotency_key UUID;
  v_orig_cap_id UUID;
  v_cap_entry_num INT;
  v_payee RECORD;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_reverse_disbursement';
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'disbursements:reverse')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller lacks disbursements:reverse on business %', p_business_id;
  END IF;

  v_request_hash := encode(sha256(jsonb_build_object(
    'action', 'reverse_disbursement',
    'business_id', p_business_id,
    'disbursement_id', p_disbursement_id,
    'reason', p_reversal_reason
  )::text::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(p_business_id, p_idempotency_key, 'reverse_disbursement', v_request_hash, v_caller_id);
  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN (v_idem_res->'payload');
  END IF;

  SELECT * INTO v_disb
  FROM public.disbursements
  WHERE id = p_disbursement_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DISBURSEMENT_NOT_FOUND: Disbursement % not found in business %', p_disbursement_id, p_business_id;
  END IF;

  SELECT * INTO v_payee
  FROM public.payees
  WHERE id = v_disb.payee_id;

  IF v_disb.status <> 'disbursed' THEN
    RAISE EXCEPTION 'CANNOT_REVERSE: Disbursement % is in status %; only disbursed vouchers can be reversed',
      p_disbursement_id, v_disb.status;
  END IF;

  v_original_treasury_tx_id := v_disb.settlement_treasury_tx_id;
  IF v_original_treasury_tx_id IS NULL THEN
    RAISE EXCEPTION 'ORIGINAL_TREASURY_TRANSACTION_MISSING: Settlement treasury transaction ID not recorded for %', p_disbursement_id;
  END IF;

  -- Derive deterministic reversal idempotency key
  v_reversal_idempotency_key := public.fn_derive_deterministic_uuid(
    p_business_id::text,
    p_disbursement_id::text,
    v_disb.financial_account_type || ':reversal'
  );

  -- Compensating Ledger Credit
  IF v_disb.financial_account_type = 'bank_account' THEN
    v_reversal_tx_id := public.fn_post_bank_transaction_internal(
      p_business_id := p_business_id,
      p_bank_account_id := v_disb.financial_account_id,
      p_transaction_type := 'disbursement_reversal',
      p_direction := 'credit',
      p_amount := v_disb.amount,
      p_currency := v_disb.currency,
      p_source_type := 'disbursement_reversal',
      p_source_id := v_disb.id,
      p_reference_number := 'REV-' || v_disb.disbursement_number,
      p_description := 'Reversal of disbursement ' || v_disb.disbursement_number,
      p_caller_id := v_caller_id,
      p_metadata := jsonb_build_object(
        'source_domain', 'payment_center',
        'disbursement_id', v_disb.id,
        'disbursement_number', v_disb.disbursement_number,
        'operation', 'reversal',
        'reversal_of_transaction_id', v_original_treasury_tx_id,
        'reversal_reason', p_reversal_reason
      )
    );

  ELSIF v_disb.financial_account_type = 'vault' THEN
    -- Check if reversal already posted (deduplication)
    SELECT id INTO v_reversal_tx_id
    FROM public.vault_transactions
    WHERE business_id = p_business_id AND idempotency_key = v_reversal_idempotency_key;

    IF v_reversal_tx_id IS NULL THEN
      INSERT INTO public.vault_transactions (
        business_id, vault_id, direction, amount, currency, transaction_type,
        reversal_of_transaction_id, description, actor_user_id, idempotency_key, occurred_at, metadata
      ) VALUES (
        p_business_id, v_disb.financial_account_id, 'in', v_disb.amount, v_disb.currency, 'reversal',
        v_original_treasury_tx_id, 'Reversal of vault disbursement ' || v_disb.disbursement_number,
        v_caller_id, v_reversal_idempotency_key, NOW(),
        jsonb_build_object(
          'source_domain', 'payment_center',
          'disbursement_id', v_disb.id,
          'disbursement_number', v_disb.disbursement_number,
          'operation', 'reversal',
          'reversal_of_transaction_id', v_original_treasury_tx_id,
          'reversal_reason', p_reversal_reason
        )
      ) RETURNING id INTO v_reversal_tx_id;
    END IF;

  ELSIF v_disb.financial_account_type = 'petty_cash' THEN
    SELECT id INTO v_reversal_tx_id
    FROM public.petty_cash_transactions
    WHERE business_id = p_business_id AND idempotency_key = v_reversal_idempotency_key;

    IF v_reversal_tx_id IS NULL THEN
      INSERT INTO public.petty_cash_transactions (
        business_id, petty_cash_account_id, direction, amount, currency, transaction_type,
        reversal_of_transaction_id, notes, actor_user_id, idempotency_key, occurred_at, metadata
      ) VALUES (
        p_business_id, v_disb.financial_account_id, 'in', v_disb.amount, v_disb.currency, 'reversal',
        v_original_treasury_tx_id, 'Reversal of petty cash disbursement ' || v_disb.disbursement_number,
        v_caller_id, v_reversal_idempotency_key, NOW(),
        jsonb_build_object(
          'source_domain', 'payment_center',
          'disbursement_id', v_disb.id,
          'disbursement_number', v_disb.disbursement_number,
          'operation', 'reversal',
          'reversal_of_transaction_id', v_original_treasury_tx_id,
          'reversal_reason', p_reversal_reason
        )
      ) RETURNING id INTO v_reversal_tx_id;
    END IF;

  ELSIF v_disb.financial_account_type = 'mobile_money' THEN
    SELECT id INTO v_reversal_tx_id
    FROM public.mobile_money_transactions
    WHERE business_id = p_business_id AND idempotency_key = v_reversal_idempotency_key;

    IF v_reversal_tx_id IS NULL THEN
      -- FinTab Policy: Principal only is returned; carrier fee remains charged
      INSERT INTO public.mobile_money_transactions (
        business_id, wallet_id, direction, amount, fee_amount, currency, transaction_type,
        reversal_of_transaction_id, description, actor_user_id, idempotency_key, occurred_at, metadata
      ) VALUES (
        p_business_id, v_disb.financial_account_id, 'in', v_disb.amount, 0.0000, v_disb.currency, 'reversal',
        v_original_treasury_tx_id, 'Reversal of mobile payout ' || v_disb.disbursement_number,
        v_caller_id, v_reversal_idempotency_key, NOW(),
        jsonb_build_object(
          'source_domain', 'payment_center',
          'disbursement_id', v_disb.id,
          'disbursement_number', v_disb.disbursement_number,
          'operation', 'reversal',
          'reversal_of_transaction_id', v_original_treasury_tx_id,
          'reversal_reason', p_reversal_reason
        )
      ) RETURNING id INTO v_reversal_tx_id;
    END IF;
  END IF;

  -- Revert linked obligations
  IF v_disb.disbursement_category = 'commission' THEN
    -- If any allocated commission earnings were marked 'settled', transition them back to 'earned'
    UPDATE public.commission_earnings
    SET status = 'earned'
    WHERE business_id = p_business_id
      AND id IN (
        SELECT obligation_id FROM public.disbursement_settlement_allocations
        WHERE disbursement_id = v_disb.id AND obligation_type = 'commission'
      );

  ELSIF v_disb.disbursement_category = 'payroll' THEN
    -- Mark obligation as approved for settlement once again
    UPDATE public.payroll_obligations
    SET status = 'approved',
        updated_at = NOW()
    WHERE business_id = p_business_id
      AND id IN (
        SELECT obligation_id FROM public.disbursement_settlement_allocations
        WHERE disbursement_id = v_disb.id AND obligation_type = 'payroll'
      );

  ELSIF v_disb.disbursement_category = 'dividend' THEN
    -- Frozen Migration 002 strictly prohibits updating paid dividend_payouts.
    -- The payment reversal is recorded authoritatively in disbursements, allocations, and treasury.
    NULL;

  ELSIF v_disb.disbursement_category = 'capital_return' THEN
    -- Concurrency serialize capital return entry numbering
    PERFORM pg_advisory_xact_lock(('x' || substr(md5(p_business_id::text || ':capital_returns'), 1, 16))::bit(64)::bigint);

    -- Find original capital return entry; fail closed if missing
    SELECT id INTO v_orig_cap_id
    FROM public.capital_returns
    WHERE business_id = p_business_id AND disbursement_id = v_disb.id AND entry_type = 'return'
    LIMIT 1;

    IF v_orig_cap_id IS NULL THEN
      RAISE EXCEPTION 'ORIGINAL_CAPITAL_RETURN_NOT_FOUND: Original capital return entry for disbursement % not found in business %',
        p_disbursement_id, p_business_id;
    END IF;

    SELECT COALESCE(MAX(entry_number), 0) + 1 INTO v_cap_entry_num
    FROM public.capital_returns WHERE business_id = p_business_id;

    INSERT INTO public.capital_returns (
      business_id, investor_id, entry_number, entry_type, return_amount, effective_date,
      disbursement_id, reversal_of_entry_id, notes, created_by, created_at
    ) VALUES (
      p_business_id, v_payee.investor_id, v_cap_entry_num, 'reversal', v_disb.amount, CURRENT_DATE,
      v_disb.id, v_orig_cap_id, 'Compensating reversal of capital return for disbursement ' || v_disb.disbursement_number,
      v_caller_id, NOW()
    );
  END IF;

  UPDATE public.disbursements
  SET status = 'reversed',
      reversal_reason = p_reversal_reason,
      reversed_by = v_caller_id,
      reversed_at = NOW(),
      updated_at = NOW()
  WHERE id = v_disb.id;

  INSERT INTO public.commercial_audit_logs (
    business_id, actor_id, action, target_type, target_id, details
  ) VALUES (
    p_business_id, v_caller_id, 'reverse_disbursement', 'disbursements', v_disb.id,
    jsonb_build_object(
      'reason', p_reversal_reason,
      'amount', v_disb.amount,
      'original_treasury_tx_id', v_original_treasury_tx_id,
      'reversal_treasury_tx_id', v_reversal_tx_id
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'disbursement_id', v_disb.id,
    'status', 'reversed',
    'reversal_treasury_tx_id', v_reversal_tx_id
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);
  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_reverse_disbursement(UUID, UUID, TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_reverse_disbursement(UUID, UUID, TEXT, UUID) TO authenticated;

-- RPC 8: rpc_process_sale_refund (MANDATORY IDEMPOTENCY)
CREATE OR REPLACE FUNCTION public.rpc_process_sale_refund(
  p_business_id UUID,
  p_original_transaction_id UUID,
  p_items JSONB, -- Array of {transaction_item_id, quantity, reason}
  p_payment_method TEXT,
  p_financial_account_type TEXT,
  p_financial_account_id UUID,
  p_notes TEXT,
  p_idempotency_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_request_hash VARCHAR(64);
  v_idem_res JSONB;
  v_orig_txn RECORD;
  v_elem RECORD;
  v_line RECORD;
  v_comm_earn RECORD;
  v_ref_qty NUMERIC(15, 4);
  v_prior_ref_qty NUMERIC(15, 4);
  v_prior_clawback_qty NUMERIC(15, 4);
  v_remaining_refundable_qty NUMERIC(15, 4);
  v_refundable_clawback_qty NUMERIC(15, 4);
  
  -- Economics per line
  v_line_subtotal NUMERIC(15, 4);
  v_line_discount NUMERIC(15, 4);
  v_line_tax NUMERIC(15, 4);
  v_line_total NUMERIC(15, 4);
  
  v_refund_subtotal NUMERIC(15, 4) := 0.0000;
  v_refund_discount NUMERIC(15, 4) := 0.0000;
  v_refund_tax NUMERIC(15, 4) := 0.0000;
  v_total_refund NUMERIC(15, 4) := 0.0000;
  
  v_comm_reversal NUMERIC(15, 4);
  v_ref_txn_number TEXT;
  v_return_txn_id UUID;
  v_item_idx INT := 0;
  v_items_count INT := 0;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_process_sale_refund';
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'sales:refund')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller lacks sales:refund on business %', p_business_id;
  END IF;

  v_request_hash := encode(sha256(jsonb_build_object(
    'action', 'process_sale_refund',
    'business_id', p_business_id,
    'original_txn_id', p_original_transaction_id,
    'items', p_items,
    'payment_method', p_payment_method,
    'account_id', p_financial_account_id
  )::text::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(p_business_id, p_idempotency_key, 'process_sale_refund', v_request_hash, v_caller_id);
  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN (v_idem_res->'payload');
  END IF;

  -- Lock and retrieve original sale
  SELECT * INTO v_orig_txn
  FROM public.sales_transactions
  WHERE id = p_original_transaction_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND OR v_orig_txn.status <> 'completed' THEN
    RAISE EXCEPTION 'INVALID_TRANSACTION: Original sale % not found or not completed', p_original_transaction_id;
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'EMPTY_REFUND_ITEMS: At least one refund line item is required';
  END IF;

  -- Validate Account Binding, Ownership, Currency and Status
  PERFORM public.fn_validate_payment_financial_account_internal(
    p_business_id,
    p_payment_method,
    p_financial_account_type,
    p_financial_account_id,
    v_orig_txn.currency
  );

  -- 1. Create Authoritative Return Sales Transaction Header
  v_ref_txn_number := public.rpc_next_document_number(p_business_id, 'refund', 'REF');

  INSERT INTO public.sales_transactions (
    business_id, branch_id, register_id, shift_id,
    cashier_user_id, customer_id, transaction_number,
    transaction_type, status,
    subtotal, discount_total, tax_total, total_amount,
    amount_paid, balance_due, currency,
    notes, occurred_at, created_at, updated_at, metadata,
    salesperson_user_id
  ) VALUES (
    p_business_id, v_orig_txn.branch_id, v_orig_txn.register_id, v_orig_txn.shift_id,
    v_caller_id, v_orig_txn.customer_id, v_ref_txn_number,
    'return', 'completed',
    0.0000, 0.0000, 0.0000, 0.0000,
    0.0000, 0.0000, v_orig_txn.currency,
    'Refund for sale ' || v_orig_txn.transaction_number || ' (' || p_original_transaction_id::text || '). Notes: ' || COALESCE(p_notes, ''),
    NOW(), NOW(), NOW(),
    jsonb_build_object(
      'original_transaction_id', p_original_transaction_id,
      'original_transaction_number', v_orig_txn.transaction_number,
      'refund_reason', p_notes
    ),
    v_orig_txn.salesperson_user_id
  ) RETURNING id INTO v_return_txn_id;

  -- 2. Process Each Refund Line
  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_item_idx := v_item_idx + 1;
    v_ref_qty := ((v_elem.value->>'quantity')::NUMERIC);

    IF v_ref_qty IS NULL OR v_ref_qty <= 0.0000 THEN
      RAISE EXCEPTION 'INVALID_REFUND_QUANTITY: Item #% quantity must be > 0', v_item_idx;
    END IF;

    -- Concurrency lock on original line item
    SELECT * INTO v_line
    FROM public.sales_transaction_items
    WHERE id = (v_elem.value->>'transaction_item_id')::UUID
      AND transaction_id = p_original_transaction_id
      AND business_id = p_business_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'LINE_NOT_FOUND: Sale line % not found in transaction %',
        (v_elem.value->>'transaction_item_id'), p_original_transaction_id;
    END IF;

    -- Cumulative Refund Quantity Protection PER ORIGINAL LINE
    -- Stored in metadata of refund sales_transaction_items
    SELECT COALESCE(SUM(sti.quantity), 0.0000) INTO v_prior_ref_qty
    FROM public.sales_transaction_items sti
    JOIN public.sales_transactions st ON st.id = sti.transaction_id
    WHERE st.business_id = p_business_id
      AND st.transaction_type = 'return'
      AND (sti.notes LIKE '%' || v_line.id::text || '%' OR (sti.notes IS NULL AND st.notes LIKE '%' || p_original_transaction_id::text || '%' AND sti.product_id = v_line.product_id));

    v_remaining_refundable_qty := v_line.quantity - v_prior_ref_qty;
    IF v_ref_qty > v_remaining_refundable_qty THEN
      RAISE EXCEPTION 'OVER_REFUND_BLOCKED: Refund quantity % exceeds remaining refundable quantity % for line %',
        v_ref_qty, v_remaining_refundable_qty, v_line.id;
    END IF;

    -- Calculate Proportional Economics
    -- unit economics from original line
    v_line_subtotal := ROUND(v_line.unit_price * v_ref_qty, 4);
    v_line_discount := ROUND((v_line.discount_amount / v_line.quantity) * v_ref_qty, 4);
    v_line_tax := ROUND((v_line.tax_amount / v_line.quantity) * v_ref_qty, 4);
    v_line_total := v_line_subtotal - v_line_discount + v_line_tax;

    v_refund_subtotal := v_refund_subtotal + v_line_subtotal;
    v_refund_discount := v_refund_discount + v_line_discount;
    v_refund_tax := v_refund_tax + v_line_tax;
    v_total_refund := v_total_refund + v_line_total;

    -- Insert Refund Sales Transaction Line Item
    INSERT INTO public.sales_transaction_items (
      business_id, transaction_id, product_id, inventory_location_id,
      quantity, unit_price, discount_amount, tax_amount, line_total,
      cost_price, notes, created_at, salesperson_user_id
    ) VALUES (
      p_business_id, v_return_txn_id, v_line.product_id, v_line.inventory_location_id,
      v_ref_qty, v_line.unit_price, v_line_discount, v_line_tax, v_line_total,
      v_line.cost_price, 'Refund for line ' || v_line.id::text, NOW(), v_line.salesperson_user_id
    );

    -- Proportional Commission Clawback Adjustment (Prevent Duplicate Clawbacks)
    SELECT * INTO v_comm_earn
    FROM public.commission_earnings
    WHERE transaction_item_id = v_line.id AND business_id = p_business_id;

    IF FOUND THEN
      -- Calculate prior clawbacks on this earning
      SELECT COALESCE(SUM(-amount), 0.0000) INTO v_prior_clawback_qty
      FROM public.commission_adjustments
      WHERE business_id = p_business_id
        AND reference_earning_id = v_comm_earn.id
        AND adjustment_type = 'refund_clawback';

      -- Remaining commission that can be clawed back
      v_remaining_refundable_qty := v_comm_earn.total_commission_earned - v_prior_clawback_qty;
      v_comm_reversal := ROUND(v_comm_earn.commission_per_unit * v_ref_qty, 4);

      IF v_comm_reversal > v_remaining_refundable_qty THEN
        v_comm_reversal := v_remaining_refundable_qty;
      END IF;

      IF v_comm_reversal > 0.0000 THEN
        INSERT INTO public.commission_adjustments (
          business_id, salesperson_user_id, staff_profile_id, payee_id,
          adjustment_type, reference_earning_id, reference_transaction_id,
          amount, currency, reason, created_by, created_at
        ) VALUES (
          p_business_id, v_comm_earn.salesperson_user_id, v_comm_earn.staff_profile_id, v_comm_earn.payee_id,
          'refund_clawback', v_comm_earn.id, v_return_txn_id,
          -v_comm_reversal, v_comm_earn.currency, 'Refund on line ' || v_line.id::text || ' via refund ' || v_ref_txn_number,
          v_caller_id, NOW()
        );
      END IF;
    END IF;

    -- Restore Inventory with Unique Event ID
    IF v_line.inventory_location_id IS NOT NULL THEN
      PERFORM public.fn_post_inventory_movement_internal(
        p_business_id := p_business_id,
        p_branch_id := v_orig_txn.branch_id,
        p_location_id := v_line.inventory_location_id,
        p_product_id := v_line.product_id,
        p_movement_type := 'RETURN',
        p_quantity := v_ref_qty,
        p_unit_cost := v_line.cost_price,
        p_reference_type := 'refund',
        p_reference_id := v_return_txn_id,
        p_notes := 'Refund ' || v_ref_txn_number,
        p_allow_negative := false,
        p_caller_id := v_caller_id
      );
    END IF;

    v_items_count := v_items_count + 1;
  END LOOP;

  -- Update return header totals
  UPDATE public.sales_transactions
  SET subtotal = v_refund_subtotal,
      discount_total = v_refund_discount,
      tax_total = v_refund_tax,
      total_amount = v_total_refund,
      amount_paid = v_total_refund,
      balance_due = 0.0000,
      updated_at = NOW()
  WHERE id = v_return_txn_id;

  -- Treasury Outflow for Refund Tender using unique v_return_txn_id
  PERFORM public.fn_post_disbursement_treasury_internal(
    p_business_id := p_business_id,
    p_disbursement_id := v_return_txn_id,
    p_payment_method := p_payment_method,
    p_financial_account_type := p_financial_account_type,
    p_financial_account_id := p_financial_account_id,
    p_amount := v_total_refund,
    p_fee_amount := 0.0000,
    p_currency := v_orig_txn.currency,
    p_disbursement_number := v_ref_txn_number,
    p_carrier_reference := NULL,
    p_recipient_phone := NULL,
    p_caller_id := v_caller_id
  );

  INSERT INTO public.commercial_audit_logs (
    business_id, actor_id, action, target_type, target_id, details
  ) VALUES (
    p_business_id, v_caller_id, 'process_sale_refund', 'sales_transactions', v_return_txn_id,
    jsonb_build_object(
      'original_transaction_id', p_original_transaction_id,
      'refund_total', v_total_refund,
      'refund_number', v_ref_txn_number
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'refund_transaction_id', v_return_txn_id,
    'refund_number', v_ref_txn_number,
    'total_refunded', v_total_refund,
    'items_count', v_items_count,
    'currency', v_orig_txn.currency
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);
  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_process_sale_refund(UUID, UUID, JSONB, TEXT, TEXT, UUID, TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_process_sale_refund(UUID, UUID, JSONB, TEXT, TEXT, UUID, TEXT, UUID) TO authenticated;


-- ------------------------------------------------------------------------------
-- 15. REPLACEMENT: rpc_complete_sale (MINIMAL SURGICAL EXTENSION OF MIGRATION 010)
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

  -- Salesperson Attribution variables
  v_header_salesperson_id UUID;
  v_line_salesperson_id UUID;
  v_allow_cashier_default BOOLEAN := FALSE;

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

  -- 8.1 Resolve Header Salesperson Attribution
  IF (p_metadata->>'salesperson_user_id') IS NOT NULL THEN
    v_header_salesperson_id := (p_metadata->>'salesperson_user_id')::UUID;
    IF NOT public.fn_validate_salesperson_internal(p_business_id, v_header_salesperson_id) THEN
      RAISE EXCEPTION 'INVALID_SALESPERSON: Salesperson % is not an active staff member in business %',
        v_header_salesperson_id, p_business_id;
    END IF;
  ELSE
    SELECT COALESCE((metadata->'commission_settings'->>'allow_cashier_as_salesperson_default')::BOOLEAN, false)
    INTO v_allow_cashier_default
    FROM public.businesses
    WHERE id = p_business_id;

    IF v_allow_cashier_default AND public.fn_validate_salesperson_internal(p_business_id, v_caller_id) THEN
      v_header_salesperson_id := v_caller_id;
    ELSE
      v_header_salesperson_id := NULL;
    END IF;
  END IF;

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

    -- Tax Validation & Calculation
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

    -- Resolve Line Salesperson Override
    IF (v_item.value->>'salesperson_user_id') IS NOT NULL THEN
      v_line_salesperson_id := (v_item.value->>'salesperson_user_id')::UUID;
      IF NOT public.fn_validate_salesperson_internal(p_business_id, v_line_salesperson_id) THEN
        RAISE EXCEPTION 'INVALID_SALESPERSON: Line salesperson % is not an active staff member in business %',
          v_line_salesperson_id, p_business_id;
      END IF;
    ELSE
      v_line_salesperson_id := v_header_salesperson_id;
    END IF;

    v_resolved_items := v_resolved_items || jsonb_build_array(
      jsonb_build_object(
        'product_id', (v_item.value->>'product_id')::UUID,
        'location_id', (v_item.value->>'location_id')::UUID,
        'quantity', v_item_qty,
        'unit_price', v_unit_price,
        'discount_amount', v_item_disc,
        'tax_amount', v_item_tax,
        'line_total', v_line_total,
        'notes', v_item.value->>'notes',
        'salesperson_user_id', v_line_salesperson_id
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
    notes, occurred_at, created_at, updated_at, metadata,
    salesperson_user_id
  ) VALUES (
    p_business_id, p_branch_id, p_register_id, p_shift_id,
    v_caller_id, p_customer_id, v_txn_number,
    'sale', 'pending_payment',
    v_subtotal, v_discount_total, v_tax_total, v_total_amount,
    0.0000, v_total_amount, v_biz_currency,
    p_notes, NOW(), NOW(), NOW(), COALESCE(p_metadata, '{}'::jsonb),
    v_header_salesperson_id
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
      cost_price, notes, created_at, salesperson_user_id
    ) VALUES (
      p_business_id, v_txn_id, (v_item.value->>'product_id')::UUID, (v_item.value->>'location_id')::UUID,
      (v_item.value->>'quantity')::NUMERIC, (v_item.value->>'unit_price')::NUMERIC,
      (v_item.value->>'discount_amount')::NUMERIC, (v_item.value->>'tax_amount')::NUMERIC,
      (v_item.value->>'line_total')::NUMERIC, v_item_cost, v_item.value->>'notes', NOW(),
      CASE WHEN (v_item.value->>'salesperson_user_id') IS NOT NULL THEN (v_item.value->>'salesperson_user_id')::UUID ELSE NULL END
    );

    -- 14. Post Movement via trusted internal primitive
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
        p_idempotency_key := gen_random_uuid(),
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

  -- 16.1 Authoritative Commission Generation (Only on Authoritative Completed Sales)
  IF v_final_status = 'completed' THEN
    PERFORM public.fn_generate_sale_commissions_internal(p_business_id, v_txn_id, v_caller_id);
  END IF;

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
