-- =============================================================================
-- FinTab Enterprise OS - Migration 013: Treasury Balance Privacy & Account-Usage Separation
-- Candidate Migration Script (PRE-DEPLOYMENT CANDIDATE ONLY - DO NOT DEPLOY WITHOUT AUTHORIZATION)
--
-- Objective:
-- Forward-only remediation of financial balance privacy gap.
-- Enforces strict backend separation between:
-- 1. Account selection & usage in authorized workflows (directory visibility)
-- 2. Sensitive account balance, reserve, and ledger visibility (balance privacy)
-- 3. Account management, approval, and settlement execution authority
--
-- Mandatory Design Rules Enforced:
-- 1. Unauthorized balance redaction MUST return NULL (never 0.0000).
-- 2. reports:view_financial alone MUST NOT authorize access to live treasury balances.
--    Requires treasury:balance:view or authoritative PrimaryOwner/business-owner authority.
-- 3. Account directory exposes only minimum safe identity attributes (no credentials/balances).
-- 4. Transaction RPC exceptions sanitized to eliminate balance leak vectors.
-- 5. Backward compatibility for v_authoritative_financial_accounts maintained with NULL redaction.
-- =============================================================================

-- =============================================================================
-- 1. AUTHORITATIVE PERMISSION: treasury:balance:view
-- =============================================================================

INSERT INTO public.permissions (key, module, description)
VALUES (
  'treasury:balance:view',
  'treasury',
  'View sensitive authoritative account balances, ledger totals, and financial reserves.'
)
ON CONFLICT (key) DO UPDATE SET
  description = EXCLUDED.description;

-- Grant by default strictly to appropriate administrative/finance system roles:
-- PrimaryOwner, CoOwner, SuperAdmin, GeneralManager, FinanceManager
-- Explicitly NOT granted by default to:
-- BranchManager, DepartmentManager, SalesManager, Salesperson, Cashier,
-- StockManager, StockStaff, Employee, Investor, Viewer.
DO $$
DECLARE
  v_perm_id UUID;
BEGIN
  SELECT id INTO v_perm_id FROM public.permissions WHERE key = 'treasury:balance:view';
  IF v_perm_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT r.id, v_perm_id
    FROM public.roles r
    WHERE r.is_system = true
      AND r.code IN ('PrimaryOwner', 'CoOwner', 'SuperAdmin', 'GeneralManager', 'FinanceManager')
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END IF;
END $$;

-- =============================================================================
-- 2. SAFE FINANCIAL ACCOUNT DIRECTORY (v_authoritative_financial_account_directory)
-- =============================================================================
-- Minimum safe identity fields for account selection across workflows (POS, Expenses, Disbursements).
-- Excludes cleared_balance, daily_limit, routing_number, full account/phone credentials.
-- security_invoker = true ensures caller RLS policies apply.

CREATE OR REPLACE VIEW public.v_authoritative_financial_account_directory
WITH (security_invoker = true) AS

-- 1. Commercial Bank Accounts
SELECT
  ba.id AS account_id,
  ba.business_id,
  'bank'::TEXT AS account_type,
  ba.account_name AS account_name,
  'Bank: ' || ba.bank_name || ' (' || ba.account_number_masked || ')' AS display_label,
  ba.currency,
  ba.status,
  NULL::TEXT AS provider
FROM public.bank_accounts ba
WHERE ba.deleted_at IS NULL

UNION ALL

-- 2. Business Cash Vaults
SELECT
  v.id AS account_id,
  v.business_id,
  'business_cash'::TEXT AS account_type,
  v.vault_name AS account_name,
  'Cash Vault: ' || v.vault_name || ' [' || v.vault_code || ']' AS display_label,
  v.currency,
  v.status,
  NULL::TEXT AS provider
FROM public.business_cash_vaults v
WHERE v.deleted_at IS NULL

UNION ALL

-- 3. Petty Cash Accounts
SELECT
  pca.id AS account_id,
  pca.business_id,
  'petty_cash'::TEXT AS account_type,
  pca.box_name AS account_name,
  'Petty Cash: ' || pca.box_name || ' [' || pca.box_code || ']' AS display_label,
  pca.currency,
  pca.status,
  NULL::TEXT AS provider
FROM public.petty_cash_accounts pca
WHERE pca.deleted_at IS NULL

UNION ALL

-- 4. Mobile Money Wallets (Masked phone credentials)
SELECT
  w.id AS account_id,
  w.business_id,
  LOWER(w.provider)::TEXT AS account_type,
  w.account_name AS account_name,
  w.provider || ': ' || w.account_name || ' (***' || RIGHT(w.phone_number, 4) || ')' AS display_label,
  w.currency,
  w.status,
  w.provider AS provider
FROM public.mobile_money_wallets w
WHERE w.deleted_at IS NULL;

-- =============================================================================
-- 3. PROTECTED FINANCIAL ACCOUNT BALANCES (v_authoritative_financial_account_balances)
-- =============================================================================
-- Returns live calculated cleared_balance ONLY if caller is business owner or has treasury:balance:view.
-- Unauthorized balance redaction returns NULL (never 0.0000).

CREATE OR REPLACE VIEW public.v_authoritative_financial_account_balances
WITH (security_invoker = true) AS

-- 1. Commercial Bank Accounts
SELECT
  ba.id AS account_id,
  ba.business_id,
  'bank'::TEXT AS account_type,
  ba.account_name AS account_name,
  'Bank: ' || ba.bank_name || ' (' || ba.account_number_masked || ')' AS display_label,
  ba.currency,
  ba.status,
  CASE
    WHEN (public.is_business_owner(ba.business_id) OR public.has_permission(ba.business_id, 'treasury:balance:view'))
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

-- 2. Business Cash Vaults
SELECT
  v.id AS account_id,
  v.business_id,
  'business_cash'::TEXT AS account_type,
  v.vault_name AS account_name,
  'Cash Vault: ' || v.vault_name || ' [' || v.vault_code || ']' AS display_label,
  v.currency,
  v.status,
  CASE
    WHEN (public.is_business_owner(v.business_id) OR public.has_permission(v.business_id, 'treasury:balance:view'))
    THEN COALESCE(SUM(CASE WHEN vt.direction = 'in' THEN vt.amount ELSE -vt.amount END), 0.0000)
    ELSE NULL::NUMERIC(15, 4)
  END AS cleared_balance,
  0.0000 AS daily_limit,
  NULL::TEXT AS provider,
  NOW() AS as_of_time
FROM public.business_cash_vaults v
LEFT JOIN public.vault_transactions vt ON vt.business_id = v.business_id AND vt.vault_id = v.id
WHERE v.deleted_at IS NULL
GROUP BY v.id, v.business_id, v.vault_name, v.vault_code, v.currency, v.status

UNION ALL

-- 3. Petty Cash Accounts
SELECT
  pca.id AS account_id,
  pca.business_id,
  'petty_cash'::TEXT AS account_type,
  pca.box_name AS account_name,
  'Petty Cash: ' || pca.box_name || ' [' || pca.box_code || ']' AS display_label,
  pca.currency,
  pca.status,
  CASE
    WHEN (public.is_business_owner(pca.business_id) OR public.has_permission(pca.business_id, 'treasury:balance:view'))
    THEN COALESCE(SUM(CASE WHEN pct.direction = 'in' THEN pct.amount ELSE -pct.amount END), 0.0000)
    ELSE NULL::NUMERIC(15, 4)
  END AS cleared_balance,
  pca.max_float_limit AS daily_limit,
  NULL::TEXT AS provider,
  NOW() AS as_of_time
FROM public.petty_cash_accounts pca
LEFT JOIN public.petty_cash_transactions pct ON pct.business_id = pca.business_id AND pct.petty_cash_account_id = pca.id
WHERE pca.deleted_at IS NULL
GROUP BY pca.id, pca.business_id, pca.box_name, pca.box_code, pca.currency, pca.status, pca.max_float_limit

UNION ALL

-- 4. Mobile Money Wallets
SELECT
  w.id AS account_id,
  w.business_id,
  LOWER(w.provider)::TEXT AS account_type,
  w.account_name AS account_name,
  w.provider || ': ' || w.account_name || ' (***' || RIGHT(w.phone_number, 4) || ')' AS display_label,
  w.currency,
  w.status,
  CASE
    WHEN (public.is_business_owner(w.business_id) OR public.has_permission(w.business_id, 'treasury:balance:view'))
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

-- =============================================================================
-- 4. BACKWARD COMPATIBILITY: v_authoritative_financial_accounts
-- =============================================================================
-- Preserves column contract for legacy consumers, but redacts cleared_balance to NULL
-- if the caller does not hold treasury:balance:view.

CREATE OR REPLACE VIEW public.v_authoritative_financial_accounts
WITH (security_invoker = true) AS
SELECT
  account_id,
  business_id,
  account_type,
  account_name,
  display_label,
  currency,
  status,
  cleared_balance,
  daily_limit,
  provider
FROM public.v_authoritative_financial_account_balances;

-- =============================================================================
-- 5. BANK ACCOUNT BALANCES VIEW HARDENING: v_bank_account_balances
-- =============================================================================
-- Preserves schema but redacts calculated_balance to NULL if unauthorized.

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
    WHEN (public.is_business_owner(ba.business_id) OR public.has_permission(ba.business_id, 'treasury:balance:view'))
    THEN COALESCE(SUM(CASE WHEN bt.direction = 'credit' THEN bt.amount ELSE -bt.amount END), 0.0000)
    ELSE NULL::NUMERIC(15, 4)
  END AS calculated_balance,
  MAX(bt.occurred_at) AS last_activity_at
FROM public.bank_accounts ba
LEFT JOIN public.bank_transactions bt ON ba.id = bt.bank_account_id AND ba.business_id = bt.business_id
WHERE ba.deleted_at IS NULL
GROUP BY ba.business_id, ba.id, ba.account_name, ba.bank_name, ba.account_number_masked, ba.currency, ba.status;

-- =============================================================================
-- 6. PETTY CASH BUDGET SUMMARY VIEW HARDENING: v_authoritative_petty_cash_budgets
-- =============================================================================
-- Redacts monetary budget fields to NULL for callers lacking treasury:balance:view.

CREATE OR REPLACE VIEW public.v_authoritative_petty_cash_budgets
WITH (security_invoker = true) AS
SELECT
  b.id AS budget_id,
  b.business_id,
  b.petty_cash_account_id,
  pca.box_name,
  pca.currency,
  b.period_name,
  b.start_date,
  b.end_date,
  CASE
    WHEN (public.is_business_owner(b.business_id) OR public.has_permission(b.business_id, 'treasury:balance:view'))
    THEN b.allocated_budget
    ELSE NULL::NUMERIC(15, 4)
  END AS allocated_budget,
  CASE
    WHEN (public.is_business_owner(b.business_id) OR public.has_permission(b.business_id, 'treasury:balance:view'))
    THEN COALESCE(SUM(adj.amount), 0.0000)
    ELSE NULL::NUMERIC(15, 4)
  END AS net_adjustments,
  CASE
    WHEN (public.is_business_owner(b.business_id) OR public.has_permission(b.business_id, 'treasury:balance:view'))
    THEN (b.allocated_budget + COALESCE(SUM(adj.amount), 0.0000))
    ELSE NULL::NUMERIC(15, 4)
  END AS effective_budget,
  CASE
    WHEN (public.is_business_owner(b.business_id) OR public.has_permission(b.business_id, 'treasury:balance:view'))
    THEN COALESCE(spent.total_spent, 0.0000)
    ELSE NULL::NUMERIC(15, 4)
  END AS total_spent,
  CASE
    WHEN (public.is_business_owner(b.business_id) OR public.has_permission(b.business_id, 'treasury:balance:view'))
    THEN ((b.allocated_budget + COALESCE(SUM(adj.amount), 0.0000)) - COALESCE(spent.total_spent, 0.0000))
    ELSE NULL::NUMERIC(15, 4)
  END AS remaining_budget,
  b.status
FROM public.petty_cash_budgets b
JOIN public.petty_cash_accounts pca ON pca.id = b.petty_cash_account_id AND pca.business_id = b.business_id
LEFT JOIN public.petty_cash_budget_adjustments adj ON adj.budget_id = b.id AND adj.business_id = b.business_id
LEFT JOIN (
  SELECT
    petty_cash_budget_id,
    SUM(amount) AS total_spent
  FROM public.expenses
  WHERE status = 'paid'
    AND petty_cash_budget_id IS NOT NULL
    AND deleted_at IS NULL
  GROUP BY petty_cash_budget_id
) spent ON spent.petty_cash_budget_id = b.id
WHERE b.deleted_at IS NULL
GROUP BY b.id, b.business_id, b.petty_cash_account_id, pca.box_name, pca.currency, b.period_name,
         b.start_date, b.end_date, b.allocated_budget, spent.total_spent, b.status;

-- =============================================================================
-- 7. RLS POLICIES: ACCOUNT DIRECTORY SELECTION VS. LEDGER VISIBILITY
-- =============================================================================

-- 7.1 Bank Accounts: Strict channel-aware access for banking, treasury, and payment execution
DROP POLICY IF EXISTS "bank_accounts_select" ON public.bank_accounts;
CREATE POLICY "bank_accounts_select" ON public.bank_accounts
FOR SELECT TO authenticated
USING (
  deleted_at IS NULL
  AND (public.is_business_owner(business_id) OR public.is_member_of_business(business_id))
  AND (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'bank:view')
    OR public.has_permission(business_id, 'bank:manage')
    OR public.has_permission(business_id, 'treasury:view')
    OR public.has_permission(business_id, 'treasury:balance:view')
    OR public.has_permission(business_id, 'expenses:pay')
    OR public.has_permission(business_id, 'disbursements:create')
    OR public.has_permission(business_id, 'disbursements:pay')
    OR public.has_permission(business_id, 'payroll:run')
  )
);

-- 7.2 Cash Vaults: Strict channel-aware access for vault custodians, cash management, and disbursements
DROP POLICY IF EXISTS business_cash_vaults_select ON public.business_cash_vaults;
CREATE POLICY business_cash_vaults_select ON public.business_cash_vaults
FOR SELECT TO authenticated
USING (
  deleted_at IS NULL
  AND (public.is_business_owner(business_id) OR public.is_member_of_business(business_id))
  AND (
    public.is_business_owner(business_id)
    OR custodian_user_id = auth.uid()
    OR public.has_permission(business_id, 'treasury:vault:manage')
    OR public.has_permission(business_id, 'treasury:view')
    OR public.has_permission(business_id, 'treasury:balance:view')
    OR public.has_permission(business_id, 'cash:manage')
    OR public.has_permission(business_id, 'expenses:pay')
    OR public.has_permission(business_id, 'disbursements:create')
    OR public.has_permission(business_id, 'disbursements:pay')
  )
);

-- 7.3 Petty Cash: Channel-aware access for petty cash custodians, branch cashiers, and expense payout
DROP POLICY IF EXISTS petty_cash_accounts_select ON public.petty_cash_accounts;
CREATE POLICY petty_cash_accounts_select ON public.petty_cash_accounts
FOR SELECT TO authenticated
USING (
  deleted_at IS NULL
  AND (public.is_business_owner(business_id) OR public.is_member_of_business(business_id))
  AND (
    public.is_business_owner(business_id)
    OR custodian_user_id = auth.uid()
    OR public.has_permission(business_id, 'treasury:petty_cash:manage')
    OR public.has_permission(business_id, 'treasury:view')
    OR public.has_permission(business_id, 'treasury:balance:view')
    OR public.has_permission(business_id, 'cash:manage')
    OR public.has_permission(business_id, 'cash:view')
    OR public.has_permission(business_id, 'expenses:pay')
    OR public.has_permission(business_id, 'disbursements:create')
    OR public.has_permission(business_id, 'disbursements:pay')
  )
);

-- 7.4 Mobile Money Wallets: Channel-aware access for wallet managers, POS payment receipt, and disbursements
DROP POLICY IF EXISTS mobile_money_wallets_select ON public.mobile_money_wallets;
CREATE POLICY mobile_money_wallets_select ON public.mobile_money_wallets
FOR SELECT TO authenticated
USING (
  deleted_at IS NULL
  AND (public.is_business_owner(business_id) OR public.is_member_of_business(business_id))
  AND (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'treasury:mobile_money:manage')
    OR public.has_permission(business_id, 'treasury:view')
    OR public.has_permission(business_id, 'treasury:balance:view')
    OR public.has_permission(business_id, 'bank:manage')
    OR public.has_permission(business_id, 'bank:view')
    OR public.has_permission(business_id, 'expenses:pay')
    OR public.has_permission(business_id, 'disbursements:create')
    OR public.has_permission(business_id, 'disbursements:pay')
    OR public.has_permission(business_id, 'payments:record')
  )
);

-- 7.5 Ledger Isolation: Bank Transactions Ledger strictly requires treasury:balance:view or owner
DROP POLICY IF EXISTS "bank_transactions_select" ON public.bank_transactions;
CREATE POLICY "bank_transactions_select" ON public.bank_transactions
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'treasury:balance:view')
);

-- 7.6 Vault Transactions Ledger strictly requires treasury:balance:view or owner
DROP POLICY IF EXISTS vault_transactions_select ON public.vault_transactions;
CREATE POLICY vault_transactions_select ON public.vault_transactions
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'treasury:balance:view')
);

-- 7.7 Petty Cash Transactions Ledger strictly requires treasury:balance:view or owner
DROP POLICY IF EXISTS petty_cash_transactions_select ON public.petty_cash_transactions;
CREATE POLICY petty_cash_transactions_select ON public.petty_cash_transactions
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'treasury:balance:view')
);

-- 7.8 Mobile Money Transactions Ledger strictly requires treasury:balance:view or owner
DROP POLICY IF EXISTS mobile_money_transactions_select ON public.mobile_money_transactions;
CREATE POLICY mobile_money_transactions_select ON public.mobile_money_transactions
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'treasury:balance:view')
);

-- =============================================================================
-- 8. SANITIZED TRANSACTION RPCS (NO BALANCE LEAK VIA EXCEPTIONS)
-- =============================================================================

-- 8.1 Sanitized Bank Posting Primitive (Replaces fn_post_bank_transaction_internal)
CREATE OR REPLACE FUNCTION public.fn_post_bank_transaction_internal(
  p_business_id UUID,
  p_bank_account_id UUID,
  p_transaction_type TEXT,
  p_direction TEXT,
  p_amount NUMERIC,
  p_currency TEXT,
  p_source_type TEXT,
  p_source_id UUID,
  p_reference_number TEXT DEFAULT NULL,
  p_description TEXT DEFAULT '',
  p_caller_id UUID DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bank_acc RECORD;
  v_available_balance NUMERIC(15, 4);
  v_tx_id UUID;
  v_actor_id UUID;
BEGIN
  v_actor_id := COALESCE(p_caller_id, auth.uid());
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Actor user ID is required for bank transaction posting';
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT: Bank transaction amount must be greater than zero';
  END IF;

  IF p_direction NOT IN ('debit', 'credit') THEN
    RAISE EXCEPTION 'INVALID_DIRECTION: Direction must be debit or credit';
  END IF;

  SELECT * INTO v_bank_acc
  FROM public.bank_accounts
  WHERE id = p_bank_account_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND OR v_bank_acc.status <> 'active' OR v_bank_acc.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'INVALID_BANK_ACCOUNT: Bank account % not found or inactive in business %',
      p_bank_account_id, p_business_id;
  END IF;

  IF UPPER(TRIM(v_bank_acc.currency)) <> UPPER(TRIM(p_currency)) THEN
    RAISE EXCEPTION 'CURRENCY_MISMATCH: Currency % does not match bank account currency %',
      p_currency, v_bank_acc.currency;
  END IF;

  IF p_source_type IS NOT NULL AND p_source_id IS NOT NULL THEN
    SELECT id INTO v_tx_id
    FROM public.bank_transactions
    WHERE business_id = p_business_id
      AND bank_account_id = p_bank_account_id
      AND source_type = p_source_type
      AND source_id = p_source_id
      AND direction = p_direction
      AND transaction_type = p_transaction_type;

    IF v_tx_id IS NOT NULL THEN
      RETURN v_tx_id;
    END IF;
  END IF;

  IF p_direction = 'debit' THEN
    SELECT COALESCE(SUM(CASE WHEN direction = 'credit' THEN amount ELSE -amount END), 0.0000)
    INTO v_available_balance
    FROM public.bank_transactions
    WHERE business_id = p_business_id AND bank_account_id = p_bank_account_id;

    -- SANITIZED: Never leak v_available_balance in exception payload
    IF v_available_balance < p_amount THEN
      RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Bank account has insufficient cleared balance';
    END IF;
  END IF;

  INSERT INTO public.bank_transactions (
    business_id,
    bank_account_id,
    transaction_type,
    direction,
    amount,
    currency,
    source_type,
    source_id,
    reference_number,
    description,
    actor_user_id,
    occurred_at,
    metadata
  ) VALUES (
    p_business_id,
    p_bank_account_id,
    p_transaction_type,
    p_direction,
    p_amount,
    p_currency,
    p_source_type,
    p_source_id,
    p_reference_number,
    p_description,
    v_actor_id,
    NOW(),
    p_metadata
  )
  RETURNING id INTO v_tx_id;

  RETURN v_tx_id;
END;
$$;

-- 8.2 Sanitized Multi-Channel Expense Settlement (Replaces rpc_approve_and_pay_expense)
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

  -- 1. Idempotency Check
  v_canonical_hash_input := jsonb_build_object(
    'business_id', LOWER(p_business_id::text),
    'expense_id', LOWER(p_expense_id::text),
    'financial_account_type', LOWER(p_financial_account_type),
    'financial_account_id', LOWER(p_financial_account_id::text),
    'payment_method', LOWER(p_payment_method),
    'fee_amount', v_fee_to_charge
  )::text;
  v_request_hash := encode(digest(v_canonical_hash_input, 'sha256'), 'hex');

  v_idem_res := public.fn_reserve_idempotency_key(
    p_business_id,
    p_idempotency_key,
    'rpc_approve_and_pay_expense',
    v_request_hash,
    v_caller_id
  );

  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN v_idem_res->'response';
  END IF;

  -- 2. Authorization Verification
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'expenses:pay')
    OR public.has_permission(p_business_id, 'treasury:payout')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks expenses:pay or treasury:payout permission for business %',
      v_caller_id, p_business_id;
  END IF;

  -- 3. Row-level locking on target expense
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

  -- 4. Channel Settlement with Sanitized Balance Checks
  IF p_financial_account_type = 'bank' THEN
    v_tx_id := public.fn_post_bank_transaction_internal(
      p_business_id,
      p_financial_account_id,
      'expense',
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

    -- SANITIZED: Never leak v_available_balance
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

    -- SANITIZED: Never leak physical cash balance
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

      -- SANITIZED: Never leak internal remaining budget value
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

    -- SANITIZED: Never leak cleared balance
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
      RAISE EXCEPTION 'DAILY_LIMIT_EXCEEDED: Disbursement exceeds daily limit of %', v_wallet.daily_disbursement_limit;
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

  -- 5. Mark Expense Paid
  UPDATE public.expenses
  SET
    status = 'paid',
    payment_method = p_payment_method,
    financial_account_type = p_financial_account_type,
    financial_account_id = p_financial_account_id,
    petty_cash_budget_id = v_exp.petty_cash_budget_id,
    paid_at = NOW(),
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

  PERFORM public.fn_store_idempotency_response(
    p_business_id,
    p_idempotency_key,
    200,
    v_result
  );

  RETURN v_result;
END;
$$;

-- 8.3 Sanitized Payment Center Posting Primitive (Replaces fn_post_disbursement_treasury_internal)
CREATE OR REPLACE FUNCTION public.fn_post_disbursement_treasury_internal(
  p_business_id UUID,
  p_disbursement_id UUID,
  p_disbursement_number TEXT,
  p_financial_account_type TEXT,
  p_financial_account_id UUID,
  p_amount NUMERIC(15, 4),
  p_currency TEXT,
  p_fee_amount NUMERIC(15, 4),
  p_recipient_phone TEXT,
  p_carrier_reference TEXT,
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
  v_ledger_idempotency_key := public.fn_derive_deterministic_uuid(
    p_business_id::text,
    p_disbursement_id::text,
    p_financial_account_type || ':settlement'
  );

  IF p_financial_account_type = 'bank_account' THEN
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

    -- SANITIZED: Never leak vault balance in exception
    IF v_avail IS NULL OR v_avail < p_amount THEN
      RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Cash vault has insufficient cleared balance';
    END IF;

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

    -- SANITIZED: Never leak petty cash balance in exception
    IF v_avail IS NULL OR v_avail < p_amount THEN
      RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Petty cash has insufficient physical cash';
    END IF;

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

    -- SANITIZED: Never leak mobile wallet balance in exception
    IF v_avail IS NULL OR v_avail < (p_amount + COALESCE(p_fee_amount, 0)) THEN
      RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Mobile money wallet has insufficient cleared funds';
    END IF;

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
      p_carrier_reference, p_recipient_phone, 'Payment Center disbursement ' || p_disbursement_number,
      p_caller_id, v_ledger_idempotency_key, NOW(),
      jsonb_build_object(
        'source_domain', 'payment_center',
        'disbursement_id', p_disbursement_id,
        'disbursement_number', p_disbursement_number,
        'operation', 'settlement'
      )
    ) RETURNING id INTO v_tx_id;
    RETURN v_tx_id;
  END IF;

  RETURN NULL;
END;
$$;

-- 8.4 Operational Dashboard Analytics Hardening (Replaces get_dashboard_analytics)
-- Strictly requires treasury:balance:view or owner for live bank & cash balance visibility.
-- reports:view_financial ALONE DOES NOT grant live treasury reserve visibility.
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
  v_caller_id UUID;
  v_is_owner BOOLEAN;
  v_biz_currency VARCHAR(3);
  v_biz_timezone TEXT;
  v_branch_active BOOLEAN;

  -- Granular viewing authorities
  v_can_view_sales BOOLEAN := false;
  v_can_view_inventory_qty BOOLEAN := false;
  v_can_view_inventory_val BOOLEAN := false;
  v_can_view_registers BOOLEAN := false;
  v_can_view_cash BOOLEAN := false;
  v_can_view_bank BOOLEAN := false;
  v_can_view_receivables BOOLEAN := false;
  v_can_view_expenses BOOLEAN := false;

  -- Metric accumulators
  v_net_sales NUMERIC(15, 4) := 0.0000;
  v_gross_sales NUMERIC(15, 4) := 0.0000;
  v_discounts_total NUMERIC(15, 4) := 0.0000;
  v_refunds_total NUMERIC(15, 4) := 0.0000;
  v_orders_count INT := 0;
  v_avg_order_value NUMERIC(15, 4) := 0.0000;
  v_stock_units_on_hand NUMERIC(15, 4) := NULL;
  v_low_stock_count INT := NULL;
  v_inventory_cost_value NUMERIC(15, 4) := NULL;
  v_inventory_retail_value NUMERIC(15, 4) := NULL;
  v_open_shifts_count INT := NULL;
  v_cash_on_hand NUMERIC(15, 4) := NULL;
  v_bank_balance NUMERIC(15, 4) := NULL;
  v_receivables NUMERIC(15, 4) := NULL;
  v_pending_expenses NUMERIC(15, 4) := NULL;
  v_paid_expenses NUMERIC(15, 4) := NULL;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  SELECT currency, COALESCE(timezone, 'UTC')
  INTO v_biz_currency, v_biz_timezone
  FROM public.businesses
  WHERE id = p_business_id AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_FOUND: Business % does not exist or has been deleted', p_business_id;
  END IF;

  v_is_owner := public.is_business_owner(p_business_id);

  IF p_start_date IS NULL THEN
    p_start_date := DATE_TRUNC('month', NOW() AT TIME ZONE v_biz_timezone) AT TIME ZONE v_biz_timezone;
  END IF;
  IF p_end_date IS NULL THEN
    p_end_date := NOW();
  END IF;

  IF p_branch_id IS NULL THEN
    v_can_view_sales := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_operational', NULL)
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', NULL)
      OR public.has_permission_in_scope(p_business_id, 'sales:view', NULL);

    v_can_view_inventory_qty := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_operational', NULL)
      OR public.has_permission_in_scope(p_business_id, 'inventory:view', NULL);

    v_can_view_inventory_val := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', NULL)
      OR public.has_permission_in_scope(p_business_id, 'inventory:audit', NULL);

    v_can_view_registers := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_operational', NULL)
      OR public.has_permission_in_scope(p_business_id, 'registers:view', NULL);

    -- Cash & Bank Balances strictly require treasury:balance:view or owner
    v_can_view_cash := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'treasury:balance:view', NULL);

    v_can_view_bank := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'treasury:balance:view', NULL);

    v_can_view_receivables := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', NULL)
      OR public.has_permission_in_scope(p_business_id, 'payments:view', NULL);

    v_can_view_expenses := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', NULL)
      OR public.has_permission_in_scope(p_business_id, 'expenses:view', NULL);

    IF NOT (
      v_can_view_sales
      OR v_can_view_inventory_qty
      OR v_can_view_inventory_val
      OR v_can_view_registers
      OR v_can_view_cash
      OR v_can_view_bank
      OR v_can_view_receivables
      OR v_can_view_expenses
    ) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks reporting permissions for business %',
        v_caller_id, p_business_id;
    END IF;
  ELSE
    SELECT is_active INTO v_branch_active
    FROM public.branches
    WHERE id = p_branch_id AND business_id = p_business_id AND deleted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'NOT_FOUND: Branch % not found in business %', p_branch_id, p_business_id;
    END IF;

    v_can_view_sales := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_operational', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'sales:view', p_branch_id);

    v_can_view_inventory_qty := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_operational', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'inventory:view', p_branch_id);

    v_can_view_inventory_val := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'inventory:audit', p_branch_id);

    v_can_view_registers := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_operational', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'registers:view', p_branch_id);

    v_can_view_cash := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'treasury:balance:view', p_branch_id);

    v_can_view_receivables := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'payments:view', p_branch_id);

    v_can_view_expenses := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'expenses:view', p_branch_id);

    v_can_view_bank := false; -- Bank accounts are tenant-wide
  END IF;

  IF v_can_view_sales THEN
    SELECT
      COALESCE(SUM(total_amount) FILTER (WHERE status = 'completed'), 0.0000),
      COALESCE(SUM(subtotal) FILTER (WHERE status = 'completed'), 0.0000),
      COALESCE(SUM(discount_amount) FILTER (WHERE status = 'completed'), 0.0000),
      COALESCE(SUM(total_amount) FILTER (WHERE status = 'refunded'), 0.0000),
      COUNT(*) FILTER (WHERE status = 'completed')
    INTO
      v_net_sales, v_gross_sales, v_discounts_total, v_refunds_total, v_orders_count
    FROM public.sales_transactions
    WHERE business_id = p_business_id
      AND (p_branch_id IS NULL OR branch_id = p_branch_id)
      AND created_at >= p_start_date
      AND created_at <= p_end_date;

    IF v_orders_count > 0 THEN
      v_avg_order_value := ROUND(v_net_sales / v_orders_count, 4);
    END IF;
  END IF;

  IF v_can_view_inventory_qty THEN
    SELECT
      COALESCE(SUM(quantity_on_hand), 0.0000),
      COUNT(*) FILTER (WHERE quantity_on_hand <= reorder_point)
    INTO
      v_stock_units_on_hand, v_low_stock_count
    FROM public.inventory_items
    WHERE business_id = p_business_id
      AND (p_branch_id IS NULL OR branch_id = p_branch_id);
  END IF;

  IF v_can_view_inventory_val THEN
    SELECT
      COALESCE(SUM(total_cost_value), 0.0000),
      COALESCE(SUM(total_retail_value), 0.0000)
    INTO
      v_inventory_cost_value, v_inventory_retail_value
    FROM public.v_inventory_valuation
    WHERE business_id = p_business_id
      AND (p_branch_id IS NULL OR branch_id = p_branch_id);
  END IF;

  IF v_can_view_registers THEN
    SELECT COUNT(*)
    INTO v_open_shifts_count
    FROM public.register_shifts
    WHERE business_id = p_business_id
      AND (p_branch_id IS NULL OR branch_id = p_branch_id)
      AND status = 'open';
  END IF;

  IF v_can_view_cash THEN
    SELECT COALESCE(SUM(current_cash_on_hand), 0.0000)
    INTO v_cash_on_hand
    FROM public.v_cash_register_balances
    WHERE business_id = p_business_id
      AND (p_branch_id IS NULL OR branch_id = p_branch_id);
  END IF;

  IF p_branch_id IS NULL AND v_can_view_bank THEN
    SELECT COALESCE(SUM(calculated_balance), 0.0000)
    INTO v_bank_balance
    FROM public.v_bank_account_balances
    WHERE business_id = p_business_id;
  ELSE
    v_bank_balance := NULL;
  END IF;

  IF v_can_view_receivables THEN
    IF p_branch_id IS NULL THEN
      SELECT COALESCE(SUM(total_outstanding_balance), 0.0000)
      INTO v_receivables
      FROM public.v_customer_receivables
      WHERE business_id = p_business_id;
    ELSE
      SELECT COALESCE(SUM(balance_due), 0.0000)
      INTO v_receivables
      FROM public.sales_transactions
      WHERE business_id = p_business_id
        AND branch_id = p_branch_id
        AND balance_due > 0
        AND status IN ('pending_payment', 'partially_paid');
    END IF;
  END IF;

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
    'sales', jsonb_build_object(
      'net_sales', v_net_sales,
      'gross_sales', v_gross_sales,
      'discounts_total', v_discounts_total,
      'refunds_total', v_refunds_total,
      'orders_count', v_orders_count,
      'average_order_value', v_avg_order_value
    ),
    'inventory', jsonb_build_object(
      'units_on_hand', v_stock_units_on_hand,
      'low_stock_items_count', v_low_stock_count,
      'cost_value', v_inventory_cost_value,
      'retail_value', v_inventory_retail_value
    ),
    'operations', jsonb_build_object(
      'open_shifts_count', v_open_shifts_count,
      'cash_on_hand', v_cash_on_hand,
      'bank_balance', v_bank_balance,
      'receivables_outstanding', v_receivables,
      'pending_expenses', v_pending_expenses,
      'paid_expenses', v_paid_expenses
    )
  );
END;
$$;

-- =============================================================================
-- 9. ACCESS GRANTS ON DIRECTORY AND BALANCES VIEWS
-- =============================================================================

GRANT SELECT ON public.v_authoritative_financial_account_directory TO authenticated;
GRANT SELECT ON public.v_authoritative_financial_account_balances TO authenticated;
GRANT SELECT ON public.v_authoritative_financial_accounts TO authenticated;
GRANT SELECT ON public.v_bank_account_balances TO authenticated;
GRANT SELECT ON public.v_authoritative_petty_cash_budgets TO authenticated;

-- =============================================================================
-- End of Migration 013 Candidate
-- =============================================================================
