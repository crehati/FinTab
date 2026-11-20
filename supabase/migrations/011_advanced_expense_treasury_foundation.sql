-- ==============================================================================
-- FINTAB ENTERPRISE — MIGRATION 011
-- Advanced Expense Management, Multi-Channel Treasury & Dual-Approval Controls
--
-- Baseline: 1.5.0-phase6b4a-frozen
-- Migrations 001-010 are immutable.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. EXTEND PUBLIC.EXPENSES LIFECYCLE & METADATA
-- ------------------------------------------------------------------------------

ALTER TABLE public.expenses DROP CONSTRAINT IF EXISTS chk_expenses_status;
ALTER TABLE public.expenses DROP CONSTRAINT IF EXISTS expenses_status_check;
ALTER TABLE public.expenses ADD CONSTRAINT chk_expenses_status
  CHECK (status IN ('draft', 'submitted', 'pending_approval', 'approved', 'paid', 'returned', 'rejected', 'cancelled', 'reversed', 'voided'));

ALTER TABLE public.expenses
  ADD COLUMN IF NOT EXISTS supplier_name TEXT,
  ADD COLUMN IF NOT EXISTS tax_id TEXT,
  ADD COLUMN IF NOT EXISTS invoice_reference TEXT,
  ADD COLUMN IF NOT EXISTS recipient_phone TEXT,
  ADD COLUMN IF NOT EXISTS financial_account_type TEXT CHECK (
    financial_account_type IS NULL OR financial_account_type IN ('bank', 'business_cash', 'petty_cash', 'moncash', 'natcash')
  ),
  ADD COLUMN IF NOT EXISTS financial_account_id UUID,
  ADD COLUMN IF NOT EXISTS petty_cash_budget_id UUID,
  ADD COLUMN IF NOT EXISTS rejection_reason TEXT,
  ADD COLUMN IF NOT EXISTS rejected_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS rejected_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS return_reason TEXT,
  ADD COLUMN IF NOT EXISTS returned_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS returned_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS cancellation_reason TEXT,
  ADD COLUMN IF NOT EXISTS cancelled_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS reversal_reason TEXT,
  ADD COLUMN IF NOT EXISTS reversed_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS reversed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS reversal_transaction_id UUID;

-- Safe normalization for existing legacy rows before adding constraints
UPDATE public.expenses
SET status = 'pending_approval'
WHERE status = 'pending';

-- Backfill legacy paid expenses from bank accounts
UPDATE public.expenses
SET
  financial_account_type = 'bank',
  financial_account_id = bank_account_id
WHERE financial_account_type IS NULL
  AND bank_account_id IS NOT NULL;

-- Normalize payment method for backfilled bank expenses
UPDATE public.expenses
SET payment_method = 'bank_transfer'
WHERE financial_account_type = 'bank'
  AND payment_method NOT IN ('bank', 'bank_transfer', 'check', 'debit_card', 'credit_card');

-- Server-side Anti-Self-Approval constraint
ALTER TABLE public.expenses DROP CONSTRAINT IF EXISTS chk_expenses_anti_self_approval;
ALTER TABLE public.expenses ADD CONSTRAINT chk_expenses_anti_self_approval
  CHECK (
    (approved_by IS NULL OR approved_by <> created_by)
    AND (paid_by IS NULL OR paid_by <> created_by)
    AND (rejected_by IS NULL OR rejected_by <> created_by)
    AND (returned_by IS NULL OR returned_by <> created_by)
  );

-- Financial account pair consistency
ALTER TABLE public.expenses DROP CONSTRAINT IF EXISTS chk_expenses_account_pair;
ALTER TABLE public.expenses ADD CONSTRAINT chk_expenses_account_pair
  CHECK (
    (financial_account_type IS NULL AND financial_account_id IS NULL)
    OR (financial_account_type IS NOT NULL AND financial_account_id IS NOT NULL)
  );

-- Paid/Reversed lifecycle constraint (compatible with historical legacy cash expenses)
ALTER TABLE public.expenses DROP CONSTRAINT IF EXISTS chk_expenses_paid_account;
ALTER TABLE public.expenses ADD CONSTRAINT chk_expenses_paid_account
  CHECK (
    status NOT IN ('paid', 'reversed')
    OR (financial_account_type IS NOT NULL AND financial_account_id IS NOT NULL)
    OR (payment_method IN ('cash', 'other') AND financial_account_type IS NULL)
  );

-- Payment Method <-> Financial Account Type strict contract
-- Strictly prevents cross-provider mixing: MonCash cannot be NatCash and vice versa
ALTER TABLE public.expenses DROP CONSTRAINT IF EXISTS chk_expenses_method_account_match;
ALTER TABLE public.expenses ADD CONSTRAINT chk_expenses_method_account_match
  CHECK (
    financial_account_type IS NULL
    OR (financial_account_type = 'bank' AND payment_method IN ('bank', 'bank_transfer', 'check', 'debit_card', 'credit_card'))
    OR (financial_account_type = 'business_cash' AND payment_method IN ('cash', 'business_cash'))
    OR (financial_account_type = 'petty_cash' AND payment_method IN ('cash', 'petty_cash'))
    OR (financial_account_type = 'moncash' AND payment_method IN ('moncash', 'mobile_money'))
    OR (financial_account_type = 'natcash' AND payment_method IN ('natcash', 'mobile_money'))
  );

CREATE INDEX IF NOT EXISTS idx_expenses_biz_status ON public.expenses (business_id, status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_expenses_fin_acc ON public.expenses (business_id, financial_account_type, financial_account_id);
CREATE INDEX IF NOT EXISTS idx_expenses_petty_budget ON public.expenses (petty_cash_budget_id);

-- ------------------------------------------------------------------------------
-- 1.1 BANK ACCOUNT SERIALIZATION & AUTHORITATIVE BANK POSTING PRIMITIVE
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.trg_serialize_bank_account_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bank_acc_id UUID;
  v_biz_id UUID;
BEGIN
  v_bank_acc_id := COALESCE(NEW.bank_account_id, OLD.bank_account_id);
  v_biz_id := COALESCE(NEW.business_id, OLD.business_id);
  IF v_bank_acc_id IS NOT NULL THEN
    PERFORM 1
    FROM public.bank_accounts
    WHERE id = v_bank_acc_id AND business_id = v_biz_id
    FOR UPDATE;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_bank_transactions_serialize_balance ON public.bank_transactions;
CREATE TRIGGER trg_bank_transactions_serialize_balance
  BEFORE INSERT OR UPDATE OR DELETE ON public.bank_transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_serialize_bank_account_balance();

REVOKE ALL ON FUNCTION public.trg_serialize_bank_account_balance() FROM PUBLIC, anon, authenticated;

-- Authoritative Internal Bank Posting Primitive
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

  -- 1. Lock and validate bank account
  SELECT * INTO v_bank_acc
  FROM public.bank_accounts
  WHERE id = p_bank_account_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND OR v_bank_acc.status <> 'active' OR v_bank_acc.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'INVALID_BANK_ACCOUNT: Bank account % not found or inactive in business %',
      p_bank_account_id, p_business_id;
  END IF;

  -- 2. Strict Currency Equality
  IF UPPER(TRIM(v_bank_acc.currency)) <> UPPER(TRIM(p_currency)) THEN
    RAISE EXCEPTION 'CURRENCY_MISMATCH: Expense currency % does not match bank account currency %',
      p_currency, v_bank_acc.currency;
  END IF;

  -- 3. Idempotent Deduplication Check
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

  -- 4. Balance verification on debit
  IF p_direction = 'debit' THEN
    SELECT COALESCE(SUM(CASE WHEN direction = 'credit' THEN amount ELSE -amount END), 0.0000)
    INTO v_available_balance
    FROM public.bank_transactions
    WHERE business_id = p_business_id AND bank_account_id = p_bank_account_id;

    IF v_available_balance < p_amount THEN
      RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Bank account has insufficient cleared balance (Available: %, Required: %)',
        v_available_balance, p_amount;
    END IF;
  END IF;

  -- 5. Immutable Append-Only Ledger Insertion
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
    UPPER(TRIM(p_currency)),
    p_source_type,
    p_source_id,
    p_reference_number,
    p_description,
    v_actor_id,
    NOW(),
    COALESCE(p_metadata, '{}'::jsonb)
  )
  RETURNING id INTO v_tx_id;

  RETURN v_tx_id;
END;
$$;

-- Explicitly revoke execute access on internal primitive from PUBLIC, anon, and authenticated
REVOKE ALL ON FUNCTION public.fn_post_bank_transaction_internal(
  UUID, UUID, TEXT, TEXT, NUMERIC, TEXT, TEXT, UUID, TEXT, TEXT, UUID, JSONB
) FROM PUBLIC, anon, authenticated;

-- Database partial unique indexes to guarantee exactly-once posting conforming to frozen source_type ('expense')
CREATE UNIQUE INDEX IF NOT EXISTS uq_bank_transactions_expense_payout
  ON public.bank_transactions (business_id, source_id)
  WHERE source_type = 'expense' AND transaction_type = 'expense_payment' AND direction = 'debit';

CREATE UNIQUE INDEX IF NOT EXISTS uq_bank_transactions_expense_reversal
  ON public.bank_transactions (business_id, source_id)
  WHERE source_type = 'expense' AND transaction_type = 'adjustment' AND direction = 'credit';

-- ------------------------------------------------------------------------------
-- 1.2 HARDEN AND DEPRECATE LEGACY rpc_pay_expense
-- Prevents bypass of anti-self-approval, balance checks, and commercial audit trail
-- ------------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.rpc_pay_expense(UUID, UUID, TEXT, UUID, UUID, UUID, TEXT);

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
BEGIN
  RAISE EXCEPTION 'DEPRECATED_ENDPOINT: rpc_pay_expense has been deprecated and disabled in Migration 011. Use rpc_approve_and_pay_expense for authoritative multi-channel treasury settlement.';
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_pay_expense(UUID, UUID, TEXT, UUID, UUID, UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------------------------
-- 2. BUSINESS CASH VAULTS (Office Safes & Reserves)
-- ------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.business_cash_vaults (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  branch_id UUID,
  vault_name TEXT NOT NULL,
  vault_code TEXT NOT NULL,
  currency VARCHAR(3) NOT NULL DEFAULT 'USD',
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'locked')),
  custodian_user_id UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,

  CONSTRAINT uq_business_cash_vaults_biz_id UNIQUE (business_id, id),
  CONSTRAINT uq_business_cash_vaults_biz_code UNIQUE (business_id, vault_code),
  CONSTRAINT fk_business_cash_vaults_branch
    FOREIGN KEY (business_id, branch_id)
    REFERENCES public.branches(business_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_vaults_biz ON public.business_cash_vaults (business_id) WHERE deleted_at IS NULL;

-- Append-only Ledger for Business Cash Vaults
CREATE TABLE IF NOT EXISTS public.vault_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  vault_id UUID NOT NULL,
  direction TEXT NOT NULL CHECK (direction IN ('in', 'out')),
  amount NUMERIC(15, 4) NOT NULL CHECK (amount > 0),
  currency VARCHAR(3) NOT NULL DEFAULT 'USD',
  transaction_type TEXT NOT NULL CHECK (
    transaction_type IN ('opening_balance', 'deposit', 'withdrawal', 'expense_payout', 'transfer_in', 'transfer_out', 'reversal', 'adjustment')
  ),
  expense_id UUID,
  reversal_of_transaction_id UUID,
  description TEXT NOT NULL DEFAULT '',
  actor_user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  idempotency_key UUID NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  CONSTRAINT uq_vault_transactions_biz_id UNIQUE (business_id, id),
  CONSTRAINT uq_vault_transactions_biz_idem UNIQUE (business_id, idempotency_key),
  CONSTRAINT fk_vault_transactions_vault
    FOREIGN KEY (business_id, vault_id)
    REFERENCES public.business_cash_vaults(business_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT fk_vault_transactions_expense
    FOREIGN KEY (business_id, expense_id)
    REFERENCES public.expenses(business_id, id)
    ON DELETE SET NULL,
  CONSTRAINT fk_vault_transactions_reversal
    FOREIGN KEY (business_id, reversal_of_transaction_id)
    REFERENCES public.vault_transactions(business_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_vault_tx_lookup ON public.vault_transactions (business_id, vault_id, occurred_at DESC);

-- ------------------------------------------------------------------------------
-- 3. PETTY CASH ACCOUNTS, BUDGETS, ADJUSTMENTS & LEDGER
-- ------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.petty_cash_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  branch_id UUID,
  box_name TEXT NOT NULL,
  box_code TEXT NOT NULL,
  custodian_user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  currency VARCHAR(3) NOT NULL DEFAULT 'USD',
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'frozen', 'closed')),
  max_float_limit NUMERIC(15, 4) NOT NULL DEFAULT 1000.0000 CHECK (max_float_limit >= 0),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,

  CONSTRAINT uq_petty_cash_accounts_biz_id UNIQUE (business_id, id),
  CONSTRAINT uq_petty_cash_accounts_biz_code UNIQUE (business_id, box_code),
  CONSTRAINT fk_petty_cash_accounts_branch
    FOREIGN KEY (business_id, branch_id)
    REFERENCES public.branches(business_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_petty_accounts_biz ON public.petty_cash_accounts (business_id) WHERE deleted_at IS NULL;

-- Periodic Petty Cash Budgets
CREATE TABLE IF NOT EXISTS public.petty_cash_budgets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  petty_cash_account_id UUID NOT NULL,
  period_name TEXT NOT NULL,
  start_date DATE NOT NULL,
  end_date DATE NOT NULL,
  allocated_budget NUMERIC(15, 4) NOT NULL CHECK (allocated_budget >= 0),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'closed', 'exhausted')),
  created_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,

  CONSTRAINT uq_petty_cash_budgets_biz_id UNIQUE (business_id, id),
  CONSTRAINT fk_petty_budgets_account
    FOREIGN KEY (business_id, petty_cash_account_id)
    REFERENCES public.petty_cash_accounts(business_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT chk_petty_budget_dates CHECK (end_date >= start_date)
);

CREATE INDEX IF NOT EXISTS idx_petty_budgets_acc ON public.petty_cash_budgets (business_id, petty_cash_account_id, status);

-- Immutable Petty Cash Budget Adjustments
CREATE TABLE IF NOT EXISTS public.petty_cash_budget_adjustments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  budget_id UUID NOT NULL,
  amount NUMERIC(15, 4) NOT NULL CHECK (amount <> 0),
  reason TEXT NOT NULL,
  approved_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  approved_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  CONSTRAINT uq_petty_budget_adjustments_biz_id UNIQUE (business_id, id),
  CONSTRAINT fk_petty_budget_adjustments_budget
    FOREIGN KEY (business_id, budget_id)
    REFERENCES public.petty_cash_budgets(business_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_petty_adjustments_budget ON public.petty_cash_budget_adjustments (budget_id);

-- Append-only Ledger for Petty Cash
CREATE TABLE IF NOT EXISTS public.petty_cash_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  petty_cash_account_id UUID NOT NULL,
  budget_id UUID,
  direction TEXT NOT NULL CHECK (direction IN ('in', 'out')),
  amount NUMERIC(15, 4) NOT NULL CHECK (amount > 0),
  currency VARCHAR(3) NOT NULL DEFAULT 'USD',
  transaction_type TEXT NOT NULL CHECK (
    transaction_type IN ('float_replenishment', 'expense_disbursement', 'reversal', 'audit_adjustment')
  ),
  expense_id UUID,
  reversal_of_transaction_id UUID,
  notes TEXT NOT NULL DEFAULT '',
  actor_user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  idempotency_key UUID NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  CONSTRAINT uq_petty_cash_transactions_biz_id UNIQUE (business_id, id),
  CONSTRAINT uq_petty_cash_transactions_biz_idem UNIQUE (business_id, idempotency_key),
  CONSTRAINT fk_petty_tx_account
    FOREIGN KEY (business_id, petty_cash_account_id)
    REFERENCES public.petty_cash_accounts(business_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT fk_petty_tx_budget
    FOREIGN KEY (business_id, budget_id)
    REFERENCES public.petty_cash_budgets(business_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT fk_petty_cash_tx_expense
    FOREIGN KEY (business_id, expense_id)
    REFERENCES public.expenses(business_id, id)
    ON DELETE SET NULL,
  CONSTRAINT fk_petty_cash_tx_reversal
    FOREIGN KEY (business_id, reversal_of_transaction_id)
    REFERENCES public.petty_cash_transactions(business_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_petty_tx_lookup ON public.petty_cash_transactions (business_id, petty_cash_account_id, occurred_at DESC);

-- ------------------------------------------------------------------------------
-- 4. MOBILE MONEY WALLETS & TRANSACTIONS (MonCash & NatCash)
-- ------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.mobile_money_wallets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  provider TEXT NOT NULL CHECK (provider IN ('MonCash', 'NatCash')),
  account_name TEXT NOT NULL,
  phone_number TEXT NOT NULL,
  merchant_id TEXT,
  currency VARCHAR(3) NOT NULL DEFAULT 'HTG',
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'closed')),
  daily_disbursement_limit NUMERIC(15, 4) NOT NULL DEFAULT 100000.0000 CHECK (daily_disbursement_limit >= 0),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,

  CONSTRAINT uq_mobile_money_wallets_biz_id UNIQUE (business_id, id),
  CONSTRAINT uq_mobile_money_wallets_biz_provider_phone UNIQUE (business_id, provider, phone_number)
);

CREATE INDEX IF NOT EXISTS idx_mobile_wallets_biz ON public.mobile_money_wallets (business_id) WHERE deleted_at IS NULL;

-- Append-only Ledger for Mobile Money Wallets
CREATE TABLE IF NOT EXISTS public.mobile_money_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  wallet_id UUID NOT NULL,
  direction TEXT NOT NULL CHECK (direction IN ('in', 'out')),
  amount NUMERIC(15, 4) NOT NULL CHECK (amount > 0),
  fee_amount NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (fee_amount >= 0),
  currency VARCHAR(3) NOT NULL DEFAULT 'HTG',
  transaction_type TEXT NOT NULL CHECK (
    transaction_type IN ('payout', 'collection', 'fee', 'reversal', 'transfer', 'opening_balance', 'cash_in')
  ),
  telecom_reference TEXT,
  recipient_phone TEXT,
  expense_id UUID,
  reversal_of_transaction_id UUID,
  description TEXT NOT NULL DEFAULT '',
  actor_user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  idempotency_key UUID NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  CONSTRAINT uq_mobile_money_transactions_biz_id UNIQUE (business_id, id),
  CONSTRAINT uq_mobile_money_transactions_biz_idem UNIQUE (business_id, idempotency_key),
  CONSTRAINT fk_mobile_money_tx_wallet
    FOREIGN KEY (business_id, wallet_id)
    REFERENCES public.mobile_money_wallets(business_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT fk_mobile_money_tx_expense
    FOREIGN KEY (business_id, expense_id)
    REFERENCES public.expenses(business_id, id)
    ON DELETE SET NULL,
  CONSTRAINT fk_mobile_money_tx_reversal
    FOREIGN KEY (business_id, reversal_of_transaction_id)
    REFERENCES public.mobile_money_transactions(business_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_mobile_tx_lookup ON public.mobile_money_transactions (business_id, wallet_id, occurred_at DESC);

-- ------------------------------------------------------------------------------
-- 5. AUTHORITATIVE MULTI-DOCUMENT ATTACHMENTS (expense_documents)
-- ------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.expense_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL,
  expense_id UUID NOT NULL,
  document_type TEXT NOT NULL CHECK (
    document_type IN ('invoice', 'supplier_receipt', 'payment_proof', 'supporting_document', 'payment_voucher', 'other')
  ),
  storage_path TEXT NOT NULL,
  file_name TEXT NOT NULL,
  file_size INT NOT NULL CHECK (file_size > 0),
  mime_type TEXT NOT NULL CHECK (mime_type IN ('image/jpeg', 'image/png', 'image/webp', 'application/pdf')),
  uploaded_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  uploaded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  CONSTRAINT uq_expense_documents_biz_id UNIQUE (business_id, id),
  CONSTRAINT fk_expense_documents_expense_same_biz
    FOREIGN KEY (business_id, expense_id)
    REFERENCES public.expenses(business_id, id)
    ON DELETE CASCADE,
  CONSTRAINT chk_expense_documents_path_consistency
    CHECK (storage_path LIKE (business_id::text || '/' || expense_id::text || '/%'))
);

CREATE INDEX IF NOT EXISTS idx_expense_docs_expense ON public.expense_documents (business_id, expense_id);

-- ------------------------------------------------------------------------------
-- 5.1 COMMERCIAL AUDIT LOGS (Immutable Action Audit Trail)
-- ------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.commercial_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  actor_id UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  action TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id UUID,
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  ip_address TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_commercial_audit_biz ON public.commercial_audit_logs (business_id, action);

-- ------------------------------------------------------------------------------
-- 6. UNIFIED FINANCIAL ACCOUNTS VIEW & BUDGET SUMMARY VIEW
-- ------------------------------------------------------------------------------

CREATE OR REPLACE VIEW public.v_authoritative_financial_accounts WITH (security_invoker = true) AS
-- 1. Commercial Bank Accounts (Uses frozen column: account_number_masked)
SELECT
  ba.id AS account_id,
  ba.business_id,
  'bank'::TEXT AS account_type,
  ba.account_name AS account_name,
  'Bank: ' || ba.bank_name || ' (' || ba.account_number_masked || ')' AS display_label,
  ba.currency,
  ba.status,
  COALESCE(SUM(CASE WHEN bt.direction = 'credit' THEN bt.amount ELSE -bt.amount END), 0.0000) AS cleared_balance,
  0.0000 AS daily_limit,
  NULL::TEXT AS provider
FROM public.bank_accounts ba
LEFT JOIN public.bank_transactions bt ON bt.business_id = ba.business_id AND bt.bank_account_id = ba.id
WHERE ba.deleted_at IS NULL
GROUP BY ba.id, ba.business_id, ba.account_name, ba.bank_name, ba.account_number_masked, ba.currency, ba.status

UNION ALL

-- 2. Business Cash Vaults (Office Safes & Reserves)
SELECT
  v.id AS account_id,
  v.business_id,
  'business_cash'::TEXT AS account_type,
  v.vault_name AS account_name,
  'Cash Vault: ' || v.vault_name || ' [' || v.vault_code || ']' AS display_label,
  v.currency,
  v.status,
  COALESCE(SUM(CASE WHEN vt.direction = 'in' THEN vt.amount ELSE -vt.amount END), 0.0000) AS cleared_balance,
  0.0000 AS daily_limit,
  NULL::TEXT AS provider
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
  COALESCE(SUM(CASE WHEN pct.direction = 'in' THEN pct.amount ELSE -pct.amount END), 0.0000) AS cleared_balance,
  pca.max_float_limit AS daily_limit,
  NULL::TEXT AS provider
FROM public.petty_cash_accounts pca
LEFT JOIN public.petty_cash_transactions pct ON pct.business_id = pca.business_id AND pct.petty_cash_account_id = pca.id
WHERE pca.deleted_at IS NULL
GROUP BY pca.id, pca.business_id, pca.box_name, pca.box_code, pca.currency, pca.status, pca.max_float_limit

UNION ALL

-- 4. Mobile Money Wallets (MonCash & NatCash)
SELECT
  w.id AS account_id,
  w.business_id,
  LOWER(w.provider)::TEXT AS account_type,
  w.account_name AS account_name,
  w.provider || ': ' || w.account_name || ' (' || w.phone_number || ')' AS display_label,
  w.currency,
  w.status,
  COALESCE(SUM(CASE WHEN mmt.direction = 'in' THEN mmt.amount ELSE -(mmt.amount + mmt.fee_amount) END), 0.0000) AS cleared_balance,
  w.daily_disbursement_limit AS daily_limit,
  w.provider AS provider
FROM public.mobile_money_wallets w
LEFT JOIN public.mobile_money_transactions mmt ON mmt.business_id = w.business_id AND mmt.wallet_id = w.id
WHERE w.deleted_at IS NULL
GROUP BY w.id, w.business_id, w.provider, w.account_name, w.phone_number, w.currency, w.status, w.daily_disbursement_limit;

-- Active Petty Cash Budget Summary View
CREATE OR REPLACE VIEW public.v_authoritative_petty_cash_budgets WITH (security_invoker = true) AS
SELECT
  b.id AS budget_id,
  b.business_id,
  b.petty_cash_account_id,
  pca.box_name,
  pca.currency,
  b.period_name,
  b.start_date,
  b.end_date,
  b.allocated_budget,
  COALESCE(SUM(adj.amount), 0.0000) AS net_adjustments,
  (b.allocated_budget + COALESCE(SUM(adj.amount), 0.0000)) AS effective_budget,
  COALESCE(spent.total_spent, 0.0000) AS total_spent,
  ((b.allocated_budget + COALESCE(SUM(adj.amount), 0.0000)) - COALESCE(spent.total_spent, 0.0000)) AS remaining_budget,
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
GROUP BY
  b.id,
  b.business_id,
  b.petty_cash_account_id,
  pca.box_name,
  pca.currency,
  b.period_name,
  b.start_date,
  b.end_date,
  b.allocated_budget,
  spent.total_spent,
  b.status;

-- ------------------------------------------------------------------------------
-- 7. PERMISSIONS REGISTRATION
-- ------------------------------------------------------------------------------

INSERT INTO public.permissions (key, module, description)
VALUES
  ('expenses:submit', 'expenses', 'Submit expense reimbursement or payment requests'),
  ('expenses:approve', 'expenses', 'Authoritatively approve pending expense requests'),
  ('expenses:pay', 'expenses', 'Authoritatively disburse and settle approved expenses'),
  ('expenses:reject', 'expenses', 'Reject submitted expense requests with documented reason'),
  ('expenses:return', 'expenses', 'Return expense requests to submitter for correction'),
  ('expenses:cancel', 'expenses', 'Cancel draft, pending, or returned expense requests'),
  ('expenses:reverse', 'expenses', 'Authoritatively reverse settled expense payouts with ledger rollback'),
  ('treasury:vault:manage', 'treasury', 'Manage business cash vaults, custodians, and disbursements'),
  ('treasury:petty_cash:manage', 'treasury', 'Manage petty cash boxes, float limits, and budget allocations'),
  ('treasury:mobile_money:manage', 'treasury', 'Manage mobile money accounts and disbursement thresholds')
ON CONFLICT (key) DO UPDATE
SET
  description = EXCLUDED.description,
  module = EXCLUDED.module;

DO $$
DECLARE
  v_role RECORD;
  v_perm RECORD;
BEGIN
  FOR v_role IN
    SELECT id, code
    FROM public.roles
    WHERE code IN ('PrimaryOwner', 'CoOwner', 'SuperAdmin', 'GeneralManager', 'FinanceManager')
  LOOP
    FOR v_perm IN
      SELECT id
      FROM public.permissions
      WHERE key IN (
        'expenses:submit',
        'expenses:approve',
        'expenses:pay',
        'expenses:reject',
        'expenses:return',
        'expenses:cancel',
        'expenses:reverse',
        'treasury:vault:manage',
        'treasury:petty_cash:manage',
        'treasury:mobile_money:manage'
      )
    LOOP
      INSERT INTO public.role_permissions (role_id, permission_id)
      VALUES (v_role.id, v_perm.id)
      ON CONFLICT (role_id, permission_id) DO NOTHING;
    END LOOP;
  END LOOP;
END;
$$;

-- ------------------------------------------------------------------------------
-- 8. STORAGE CONFIGURATION & HARDENED RLS POLICIES
-- Regex pattern strictly prevents invalid UUID-cast errors on non-UUID paths
-- ------------------------------------------------------------------------------

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'expense-documents',
  'expense-documents',
  false,
  10485760,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
)
ON CONFLICT (id) DO UPDATE
SET
  public = false,
  file_size_limit = 10485760,
  allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf'];

DROP POLICY IF EXISTS expense_docs_storage_select ON storage.objects;
CREATE POLICY expense_docs_storage_select ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'expense-documents'
  AND name ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/.+$'
  AND EXISTS (
    SELECT 1 FROM public.expenses e
    WHERE e.id = (storage.foldername(name))[2]::UUID
      AND e.business_id = (storage.foldername(name))[1]::UUID
      AND (
        e.created_by = auth.uid()
        OR public.is_business_owner(e.business_id)
        OR public.has_permission(e.business_id, 'expenses:view')
        OR public.has_permission(e.business_id, 'expenses:approve')
        OR public.has_permission(e.business_id, 'expenses:pay')
      )
  )
);

DROP POLICY IF EXISTS expense_docs_storage_insert ON storage.objects;
CREATE POLICY expense_docs_storage_insert ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'expense-documents'
  AND name ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/.+$'
  AND EXISTS (
    SELECT 1 FROM public.expenses e
    WHERE e.id = (storage.foldername(name))[2]::UUID
      AND e.business_id = (storage.foldername(name))[1]::UUID
      AND (
        (e.created_by = auth.uid() AND e.status IN ('draft', 'returned', 'pending_approval'))
        OR public.is_business_owner(e.business_id)
        OR public.has_permission(e.business_id, 'expenses:submit')
        OR public.has_permission(e.business_id, 'expenses:create')
        OR public.has_permission(e.business_id, 'expenses:approve')
        OR public.has_permission(e.business_id, 'expenses:pay')
      )
  )
);

DROP POLICY IF EXISTS expense_docs_storage_delete ON storage.objects;
CREATE POLICY expense_docs_storage_delete ON storage.objects
FOR DELETE TO authenticated
USING (
  bucket_id = 'expense-documents'
  AND name ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/.+$'
  AND EXISTS (
    SELECT 1 FROM public.expenses e
    WHERE e.id = (storage.foldername(name))[2]::UUID
      AND e.business_id = (storage.foldername(name))[1]::UUID
      AND (
        (e.created_by = auth.uid() AND e.status IN ('draft', 'returned'))
        OR public.is_business_owner(e.business_id)
        OR public.has_permission(e.business_id, 'expenses:delete')
      )
  )
);

-- ------------------------------------------------------------------------------
-- 9. ROW-LEVEL SECURITY (RLS) POLICIES FOR NEW TABLES
-- ------------------------------------------------------------------------------

ALTER TABLE public.business_cash_vaults ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vault_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.petty_cash_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.petty_cash_budgets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.petty_cash_budget_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.petty_cash_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mobile_money_wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mobile_money_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commercial_audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS business_cash_vaults_select ON public.business_cash_vaults;
CREATE POLICY business_cash_vaults_select ON public.business_cash_vaults
FOR SELECT TO authenticated
USING (
  deleted_at IS NULL
  AND (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'treasury:vault:manage')
    OR public.has_permission(business_id, 'cash:manage')
    OR public.has_permission(business_id, 'cash:view')
    OR custodian_user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS vault_transactions_select ON public.vault_transactions;
CREATE POLICY vault_transactions_select ON public.vault_transactions
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'treasury:vault:manage')
  OR public.has_permission(business_id, 'cash:manage')
  OR public.has_permission(business_id, 'cash:view')
  OR actor_user_id = auth.uid()
);

DROP POLICY IF EXISTS petty_cash_accounts_select ON public.petty_cash_accounts;
CREATE POLICY petty_cash_accounts_select ON public.petty_cash_accounts
FOR SELECT TO authenticated
USING (
  deleted_at IS NULL
  AND (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'treasury:petty_cash:manage')
    OR public.has_permission(business_id, 'cash:manage')
    OR public.has_permission(business_id, 'cash:view')
    OR custodian_user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS petty_cash_budgets_select ON public.petty_cash_budgets;
CREATE POLICY petty_cash_budgets_select ON public.petty_cash_budgets
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'treasury:petty_cash:manage')
  OR public.has_permission(business_id, 'cash:manage')
  OR public.has_permission(business_id, 'cash:view')
  OR public.has_permission(business_id, 'expenses:submit')
  OR public.has_permission(business_id, 'expenses:approve')
  OR public.has_permission(business_id, 'expenses:pay')
  OR created_by = auth.uid()
);

DROP POLICY IF EXISTS petty_cash_budget_adjustments_select ON public.petty_cash_budget_adjustments;
CREATE POLICY petty_cash_budget_adjustments_select ON public.petty_cash_budget_adjustments
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'treasury:petty_cash:manage')
  OR public.has_permission(business_id, 'cash:manage')
  OR public.has_permission(business_id, 'cash:view')
  OR approved_by = auth.uid()
);

DROP POLICY IF EXISTS petty_cash_transactions_select ON public.petty_cash_transactions;
CREATE POLICY petty_cash_transactions_select ON public.petty_cash_transactions
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'treasury:petty_cash:manage')
  OR public.has_permission(business_id, 'cash:manage')
  OR public.has_permission(business_id, 'cash:view')
  OR actor_user_id = auth.uid()
);

DROP POLICY IF EXISTS mobile_money_wallets_select ON public.mobile_money_wallets;
CREATE POLICY mobile_money_wallets_select ON public.mobile_money_wallets
FOR SELECT TO authenticated
USING (
  deleted_at IS NULL
  AND (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'treasury:mobile_money:manage')
    OR public.has_permission(business_id, 'bank:manage')
    OR public.has_permission(business_id, 'bank:view')
  )
);

DROP POLICY IF EXISTS mobile_money_transactions_select ON public.mobile_money_transactions;
CREATE POLICY mobile_money_transactions_select ON public.mobile_money_transactions
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'treasury:mobile_money:manage')
  OR public.has_permission(business_id, 'bank:manage')
  OR public.has_permission(business_id, 'bank:view')
  OR actor_user_id = auth.uid()
);

DROP POLICY IF EXISTS expense_documents_select ON public.expense_documents;
CREATE POLICY expense_documents_select ON public.expense_documents
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR uploaded_by = auth.uid()
  OR public.has_permission(business_id, 'expenses:view')
  OR public.has_permission(business_id, 'expenses:approve')
  OR public.has_permission(business_id, 'expenses:pay')
  OR EXISTS (
    SELECT 1 FROM public.expenses e
    WHERE e.id = expense_documents.expense_id
      AND e.business_id = expense_documents.business_id
      AND e.created_by = auth.uid()
  )
);

DROP POLICY IF EXISTS expense_documents_insert ON public.expense_documents;
CREATE POLICY expense_documents_insert ON public.expense_documents
FOR INSERT TO authenticated
WITH CHECK (
  uploaded_by = auth.uid()
  AND (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'expenses:submit')
    OR public.has_permission(business_id, 'expenses:create')
    OR public.has_permission(business_id, 'expenses:approve')
    OR public.has_permission(business_id, 'expenses:pay')
    OR EXISTS (
      SELECT 1 FROM public.expenses e
      WHERE e.id = expense_documents.expense_id
        AND e.business_id = expense_documents.business_id
        AND e.created_by = auth.uid()
        AND e.status IN ('draft', 'returned', 'pending_approval')
    )
  )
);

DROP POLICY IF EXISTS expense_documents_delete ON public.expense_documents;
CREATE POLICY expense_documents_delete ON public.expense_documents
FOR DELETE TO authenticated
USING (false);

DROP POLICY IF EXISTS commercial_audit_logs_select ON public.commercial_audit_logs;
CREATE POLICY commercial_audit_logs_select ON public.commercial_audit_logs
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'audit:view_logs')
  OR public.has_permission(business_id, 'expenses:view')
);

DROP POLICY IF EXISTS expenses_update ON public.expenses;
CREATE POLICY expenses_update ON public.expenses
FOR UPDATE TO authenticated
USING (
  deleted_at IS NULL
  AND created_by = auth.uid()
  AND status IN ('draft', 'returned')
)
WITH CHECK (
  deleted_at IS NULL
  AND created_by = auth.uid()
  AND status IN ('draft', 'returned')
  AND approved_by IS NULL
  AND approved_at IS NULL
  AND paid_by IS NULL
  AND paid_at IS NULL
  AND rejected_by IS NULL
  AND rejected_at IS NULL
  AND returned_by IS NULL
  AND returned_at IS NULL
  AND cancelled_by IS NULL
  AND cancelled_at IS NULL
  AND reversed_by IS NULL
  AND reversed_at IS NULL
  AND reversal_transaction_id IS NULL
);

REVOKE INSERT, UPDATE, DELETE ON public.vault_transactions FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.petty_cash_transactions FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.petty_cash_budget_adjustments FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.mobile_money_transactions FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.commercial_audit_logs FROM authenticated;

-- Append-only immutability triggers
CREATE OR REPLACE FUNCTION public.trg_protect_ledger_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'IMMUTABLE_RECORD: % is an append-only ledger. UPDATE and DELETE operations are strictly prohibited.', TG_TABLE_NAME;
END;
$$;

DROP TRIGGER IF EXISTS trg_vault_transactions_immutable ON public.vault_transactions;
CREATE TRIGGER trg_vault_transactions_immutable
BEFORE UPDATE OR DELETE ON public.vault_transactions
FOR EACH ROW EXECUTE FUNCTION public.trg_protect_ledger_immutability();

DROP TRIGGER IF EXISTS trg_petty_cash_transactions_immutable ON public.petty_cash_transactions;
CREATE TRIGGER trg_petty_cash_transactions_immutable
BEFORE UPDATE OR DELETE ON public.petty_cash_transactions
FOR EACH ROW EXECUTE FUNCTION public.trg_protect_ledger_immutability();

DROP TRIGGER IF EXISTS trg_petty_budget_adj_immutable ON public.petty_cash_budget_adjustments;
CREATE TRIGGER trg_petty_budget_adj_immutable
BEFORE UPDATE OR DELETE ON public.petty_cash_budget_adjustments
FOR EACH ROW EXECUTE FUNCTION public.trg_protect_ledger_immutability();

DROP TRIGGER IF EXISTS trg_mobile_money_tx_immutable ON public.mobile_money_transactions;
CREATE TRIGGER trg_mobile_money_tx_immutable
BEFORE UPDATE OR DELETE ON public.mobile_money_transactions
FOR EACH ROW EXECUTE FUNCTION public.trg_protect_ledger_immutability();

DROP TRIGGER IF EXISTS trg_commercial_audit_logs_immutable ON public.commercial_audit_logs;
CREATE TRIGGER trg_commercial_audit_logs_immutable
BEFORE UPDATE OR DELETE ON public.commercial_audit_logs
FOR EACH ROW EXECUTE FUNCTION public.trg_protect_ledger_immutability();

REVOKE ALL ON FUNCTION public.trg_protect_ledger_immutability() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------------------------
-- 10. AUTHORITATIVE RPC: rpc_submit_expense_request
-- Category B: Optional but implemented idempotency
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_submit_expense_request(
  p_business_id UUID,
  p_branch_id UUID,
  p_category_id UUID,
  p_amount NUMERIC,
  p_currency VARCHAR,
  p_description TEXT,
  p_supplier_name TEXT DEFAULT NULL,
  p_tax_id TEXT DEFAULT NULL,
  p_invoice_reference TEXT DEFAULT NULL,
  p_payment_method TEXT DEFAULT 'cash',
  p_financial_account_type TEXT DEFAULT NULL,
  p_financial_account_id UUID DEFAULT NULL,
  p_petty_cash_budget_id UUID DEFAULT NULL,
  p_idempotency_key UUID DEFAULT NULL,
  p_recipient_phone TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_exp_id UUID;
  v_exp_number TEXT;
  v_idem_res JSONB;
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  -- Authorization Check
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(p_business_id, 'expenses:submit', p_branch_id)
    OR public.has_permission_in_scope(p_business_id, 'expenses:create', p_branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot create expense requests in business %', v_caller_id, p_business_id;
  END IF;

  -- Validation
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Amount must be greater than zero';
  END IF;

  IF TRIM(COALESCE(p_description, '')) = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Description is required';
  END IF;

  -- Category validation
  IF p_category_id IS NULL THEN
    RAISE EXCEPTION 'EXPENSE_CATEGORY_REQUIRED: p_category_id is mandatory for expense requests';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.expense_categories
    WHERE id = p_category_id AND business_id = p_business_id AND is_active = true AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Invalid, inactive, or deleted expense category %', p_category_id;
  END IF;

  -- Financial account validation
  IF p_payment_method IS NULL OR TRIM(p_payment_method) = '' THEN
    RAISE EXCEPTION 'PAYMENT_METHOD_REQUIRED: payment_method is mandatory for expense requests';
  END IF;

  IF (p_financial_account_type IS NOT NULL AND p_financial_account_id IS NULL)
     OR (p_financial_account_type IS NULL AND p_financial_account_id IS NOT NULL) THEN
    RAISE EXCEPTION 'ACCOUNT_PAIR_REQUIRED: Both financial_account_type and financial_account_id must be provided together';
  END IF;

  -- Payment Method <-> Financial Account Type strict match
  IF p_financial_account_type IS NOT NULL AND p_payment_method IS NOT NULL THEN
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
  END IF;

  -- Account validation if specified
  IF p_financial_account_type IS NOT NULL THEN
    IF p_financial_account_type = 'bank' THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.bank_accounts
        WHERE id = p_financial_account_id AND business_id = p_business_id AND status = 'active' AND deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'INVALID_BANK_ACCOUNT: Bank account % is invalid, inactive, or belongs to another business', p_financial_account_id;
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM public.bank_accounts
        WHERE id = p_financial_account_id AND business_id = p_business_id AND currency = UPPER(TRIM(p_currency))
      ) THEN
        RAISE EXCEPTION 'CURRENCY_MISMATCH: Expense currency % does not match bank account currency', p_currency;
      END IF;
    ELSIF p_financial_account_type = 'business_cash' THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.business_cash_vaults
        WHERE id = p_financial_account_id AND business_id = p_business_id AND status = 'active' AND deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'INVALID_ACCOUNT: Business cash vault % is invalid, inactive, or belongs to another business', p_financial_account_id;
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM public.business_cash_vaults
        WHERE id = p_financial_account_id AND business_id = p_business_id AND currency = UPPER(TRIM(p_currency))
      ) THEN
        RAISE EXCEPTION 'CURRENCY_MISMATCH: Expense currency % does not match cash vault currency', p_currency;
      END IF;
    ELSIF p_financial_account_type = 'petty_cash' THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.petty_cash_accounts
        WHERE id = p_financial_account_id AND business_id = p_business_id AND status = 'active' AND deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'INVALID_ACCOUNT: Petty cash account % is invalid, inactive, or belongs to another business', p_financial_account_id;
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM public.petty_cash_accounts
        WHERE id = p_financial_account_id AND business_id = p_business_id AND currency = UPPER(TRIM(p_currency))
      ) THEN
        RAISE EXCEPTION 'CURRENCY_MISMATCH: Expense currency % does not match petty cash account currency', p_currency;
      END IF;
    ELSIF p_financial_account_type = 'moncash' THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.mobile_money_wallets
        WHERE id = p_financial_account_id AND business_id = p_business_id AND status = 'active' AND deleted_at IS NULL AND provider = 'MonCash'
      ) THEN
        RAISE EXCEPTION 'INVALID_ACCOUNT: Mobile money wallet % is invalid, inactive, or provider is not MonCash', p_financial_account_id;
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM public.mobile_money_wallets
        WHERE id = p_financial_account_id AND business_id = p_business_id AND currency = UPPER(TRIM(p_currency))
      ) THEN
        RAISE EXCEPTION 'CURRENCY_MISMATCH: Expense currency % does not match mobile money wallet currency', p_currency;
      END IF;
    ELSIF p_financial_account_type = 'natcash' THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.mobile_money_wallets
        WHERE id = p_financial_account_id AND business_id = p_business_id AND status = 'active' AND deleted_at IS NULL AND provider = 'NatCash'
      ) THEN
        RAISE EXCEPTION 'INVALID_ACCOUNT: Mobile money wallet % is invalid, inactive, or provider is not NatCash', p_financial_account_id;
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM public.mobile_money_wallets
        WHERE id = p_financial_account_id AND business_id = p_business_id AND currency = UPPER(TRIM(p_currency))
      ) THEN
        RAISE EXCEPTION 'CURRENCY_MISMATCH: Expense currency % does not match mobile money wallet currency', p_currency;
      END IF;
    ELSE
      RAISE EXCEPTION 'VALIDATION_ERROR: Unsupported financial account type %', p_financial_account_type;
    END IF;
  END IF;

  -- Petty Cash Budget Validation
  IF p_petty_cash_budget_id IS NOT NULL THEN
    IF p_financial_account_type IS NOT NULL AND p_financial_account_type <> 'petty_cash' THEN
      RAISE EXCEPTION 'VALIDATION_ERROR: petty_cash_budget_id may only be specified for petty_cash financial account type';
    END IF;
    IF p_financial_account_id IS NULL THEN
      SELECT petty_cash_account_id INTO p_financial_account_id
      FROM public.petty_cash_budgets
      WHERE id = p_petty_cash_budget_id AND business_id = p_business_id;
      p_financial_account_type := 'petty_cash';
      IF p_payment_method NOT IN ('cash', 'petty_cash') THEN
        p_payment_method := 'petty_cash';
      END IF;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.petty_cash_budgets b
      WHERE b.id = p_petty_cash_budget_id
        AND b.business_id = p_business_id
        AND b.status = 'active'
        AND CURRENT_DATE BETWEEN b.start_date AND b.end_date
        AND (p_financial_account_id IS NULL OR b.petty_cash_account_id = p_financial_account_id)
    ) THEN
      RAISE EXCEPTION 'INVALID_BUDGET: Attached petty cash budget is inactive, expired, or belongs to another account/business';
    END IF;
  END IF;

  -- Idempotency Handling
  IF p_idempotency_key IS NOT NULL THEN
    v_canonical_hash_input := jsonb_build_object(
      'business_id', LOWER(p_business_id::text),
      'branch_id', CASE WHEN p_branch_id IS NOT NULL THEN LOWER(p_branch_id::text) ELSE NULL END,
      'category_id', LOWER(p_category_id::text),
      'amount', to_char(p_amount, 'FM999999999999990.0000'),
      'currency', UPPER(TRIM(p_currency)),
      'description', TRIM(p_description),
      'payment_method', LOWER(TRIM(COALESCE(p_payment_method, ''))),
      'financial_account_type', CASE WHEN p_financial_account_type IS NOT NULL THEN LOWER(TRIM(p_financial_account_type)) ELSE NULL END,
      'financial_account_id', CASE WHEN p_financial_account_id IS NOT NULL THEN LOWER(p_financial_account_id::text) ELSE NULL END
    )::text;
    v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');
    v_idem_res := public.fn_idempotency_acquire(
      p_business_id,
      p_idempotency_key,
      'rpc_submit_expense_request',
      v_request_hash,
      v_caller_id
    );
    IF v_idem_res->>'action' = 'replay' THEN
      RETURN v_idem_res->'payload';
    END IF;
  END IF;

  -- Document Sequence
  v_exp_number := public.rpc_next_document_number(p_business_id, 'expense', 'EXP');

  -- Insert Expense
  INSERT INTO public.expenses (
    business_id,
    branch_id,
    category_id,
    expense_number,
    description,
    amount,
    currency,
    expense_date,
    status,
    payment_method,
    financial_account_type,
    financial_account_id,
    petty_cash_budget_id,
    supplier_name,
    tax_id,
    invoice_reference,
    recipient_phone,
    created_by,
    created_at,
    updated_at
  ) VALUES (
    p_business_id,
    p_branch_id,
    p_category_id,
    v_exp_number,
    TRIM(p_description),
    p_amount,
    UPPER(TRIM(p_currency)),
    CURRENT_DATE,
    'pending_approval',
    p_payment_method,
    p_financial_account_type,
    p_financial_account_id,
    p_petty_cash_budget_id,
    TRIM(p_supplier_name),
    TRIM(p_tax_id),
    TRIM(p_invoice_reference),
    TRIM(p_recipient_phone),
    v_caller_id,
    NOW(),
    NOW()
  )
  RETURNING id INTO v_exp_id;

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
    'EXPENSE_SUBMITTED',
    'expense',
    v_exp_id,
    jsonb_build_object(
      'expense_number', v_exp_number,
      'amount', p_amount,
      'currency', p_currency,
      'category_id', p_category_id,
      'status', 'pending_approval'
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'expense_id', v_exp_id,
    'expense_number', v_exp_number,
    'status', 'pending_approval'
  );

  IF p_idempotency_key IS NOT NULL THEN
    PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);
  END IF;

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

-- ------------------------------------------------------------------------------
-- 11. AUTHORITATIVE RPC: rpc_approve_and_pay_expense (ATOMIC SETTLEMENT)
-- Category A: Mandatory idempotency
-- ------------------------------------------------------------------------------

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

  -- Payment Method <-> Financial Account Type strict match
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

  -- 1. Idempotency Reservation
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
  IF v_idem_res->>'action' = 'replay' THEN
    RETURN v_idem_res->'payload';
  END IF;

  -- 2. Authorization Check
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

  -- 3. Lock Expense Header FOR UPDATE
  SELECT * INTO v_exp
  FROM public.expenses
  WHERE id = p_expense_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EXPENSE_NOT_FOUND: Expense % does not exist in business %', p_expense_id, p_business_id;
  END IF;

  -- 4. Status Check
  IF v_exp.status = 'paid' THEN
    RAISE EXCEPTION 'INVALID_STATUS: Expense % is already paid', p_expense_id;
  END IF;

  IF v_exp.status <> 'pending_approval' AND v_exp.status <> 'approved' THEN
    RAISE EXCEPTION 'INVALID_STATUS: Expense % is in status %; only pending_approval or approved requests can be settled',
      p_expense_id, v_exp.status;
  END IF;

  -- 5. Anti-Self-Approval Enforcement
  IF v_exp.created_by = v_caller_id THEN
    RAISE EXCEPTION 'SELF_APPROVAL_PROHIBITED: Requester/creator cannot approve or pay their own expense request';
  END IF;

  -- 5.1 Account Immutability Enforcement
  -- Approver cannot silently alter submitter-designated financial account
  IF v_exp.financial_account_type IS NOT NULL AND v_exp.financial_account_type <> p_financial_account_type THEN
    RAISE EXCEPTION 'ACCOUNT_MISMATCH: Settlement account type % does not match submitted expense account type %',
      p_financial_account_type, v_exp.financial_account_type;
  END IF;

  IF v_exp.financial_account_id IS NOT NULL AND v_exp.financial_account_id <> p_financial_account_id THEN
    RAISE EXCEPTION 'ACCOUNT_MISMATCH: Settlement account ID % does not match submitted expense account ID %',
      p_financial_account_id, v_exp.financial_account_id;
  END IF;

  -- 6. Settlement by Funding Channel
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
      COALESCE(p_reference_number, v_exp.expense_number),
      'Expense payout: ' || v_exp.description,
      v_caller_id,
      jsonb_build_object('expense_id', p_expense_id, 'expense_number', v_exp.expense_number)
    );

  ELSIF p_financial_account_type = 'business_cash' THEN
    SELECT * INTO v_vault
    FROM public.business_cash_vaults
    WHERE id = p_financial_account_id AND business_id = p_business_id
    FOR UPDATE;

    IF NOT FOUND OR v_vault.status <> 'active' OR v_vault.deleted_at IS NOT NULL THEN
      RAISE EXCEPTION 'INVALID_ACCOUNT: Business cash vault % is invalid, inactive, or belongs to another business', p_financial_account_id;
    END IF;

    IF v_vault.currency <> v_exp.currency THEN
      RAISE EXCEPTION 'CURRENCY_MISMATCH: Expense currency % does not match cash vault currency %', v_exp.currency, v_vault.currency;
    END IF;

    SELECT COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE -amount END), 0.0000)
    INTO v_available_balance
    FROM public.vault_transactions
    WHERE business_id = p_business_id AND vault_id = p_financial_account_id;

    IF v_available_balance < v_exp.amount THEN
      RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Cash vault has insufficient cleared balance (Available: %, Required: %)',
        v_available_balance, v_exp.amount;
    END IF;

    INSERT INTO public.vault_transactions (
      business_id,
      vault_id,
      direction,
      amount,
      currency,
      transaction_type,
      expense_id,
      description,
      actor_user_id,
      idempotency_key,
      occurred_at
    ) VALUES (
      p_business_id,
      p_financial_account_id,
      'out',
      v_exp.amount,
      v_exp.currency,
      'expense_payout',
      p_expense_id,
      'Expense payout: ' || v_exp.description,
      v_caller_id,
      p_idempotency_key,
      NOW()
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
      RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Petty cash box has insufficient physical cash (Available: %, Required: %)',
        v_available_balance, v_exp.amount;
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

      IF v_exp.petty_cash_budget_id IS NOT NULL THEN
        UPDATE public.expenses
        SET petty_cash_budget_id = v_exp.petty_cash_budget_id
        WHERE id = p_expense_id;
      END IF;
    END IF;

    IF v_exp.petty_cash_budget_id IS NOT NULL THEN
      SELECT * INTO v_budget
      FROM public.petty_cash_budgets
      WHERE id = v_exp.petty_cash_budget_id AND business_id = p_business_id
      FOR UPDATE;

      IF NOT FOUND OR v_budget.status <> 'active' THEN
        RAISE EXCEPTION 'INVALID_BUDGET: Attached petty cash budget is inactive or invalid';
      END IF;

      IF v_budget.petty_cash_account_id <> p_financial_account_id THEN
        RAISE EXCEPTION 'BUDGET_ACCOUNT_MISMATCH: Attached petty cash budget belongs to account %, not %',
          v_budget.petty_cash_account_id, p_financial_account_id;
      END IF;

      IF v_exp.expense_date < v_budget.start_date OR v_exp.expense_date > v_budget.end_date THEN
        RAISE EXCEPTION 'BUDGET_PERIOD_EXPIRED: Expense date % is outside the budget period (% to %)',
          v_exp.expense_date, v_budget.start_date, v_budget.end_date;
      END IF;

      SELECT ((b.allocated_budget + COALESCE(SUM(adj.amount), 0.0000)) - COALESCE(spent.total_spent, 0.0000))
      INTO v_remaining_budget
      FROM public.petty_cash_budgets b
      LEFT JOIN public.petty_cash_budget_adjustments adj ON adj.budget_id = b.id AND adj.business_id = b.business_id
      LEFT JOIN (
        SELECT petty_cash_budget_id, SUM(amount) AS total_spent
        FROM public.expenses
        WHERE status = 'paid' AND petty_cash_budget_id = v_exp.petty_cash_budget_id AND deleted_at IS NULL
        GROUP BY petty_cash_budget_id
      ) spent ON spent.petty_cash_budget_id = b.id
      WHERE b.id = v_budget.id
      GROUP BY b.id, b.allocated_budget, spent.total_spent;

      IF v_remaining_budget < v_exp.amount THEN
        RAISE EXCEPTION 'EXCEEDED_PETTY_CASH_BUDGET: Expense exceeds authorized remaining budget for period (Remaining: %, Required: %)',
          v_remaining_budget, v_exp.amount;
      END IF;
    END IF;

    INSERT INTO public.petty_cash_transactions (
      business_id,
      petty_cash_account_id,
      budget_id,
      direction,
      amount,
      currency,
      transaction_type,
      expense_id,
      notes,
      actor_user_id,
      idempotency_key,
      occurred_at
    ) VALUES (
      p_business_id,
      p_financial_account_id,
      v_exp.petty_cash_budget_id,
      'out',
      v_exp.amount,
      v_exp.currency,
      'expense_disbursement',
      p_expense_id,
      'Expense payout: ' || v_exp.description,
      v_caller_id,
      p_idempotency_key,
      NOW()
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

    -- Cleared funds balance check
    SELECT COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE -(amount + fee_amount) END), 0.0000)
    INTO v_available_balance
    FROM public.mobile_money_transactions
    WHERE business_id = p_business_id AND wallet_id = p_financial_account_id;

    IF v_available_balance < (v_exp.amount + v_fee_to_charge) THEN
      RAISE EXCEPTION 'INSUFFICIENT_FUNDS: Mobile money wallet has insufficient cleared funds (Available: %, Required: %)',
        v_available_balance, (v_exp.amount + v_fee_to_charge);
    END IF;

    -- Authoritative business timezone
    SELECT COALESCE(timezone, 'UTC') INTO v_biz_timezone
    FROM public.businesses
    WHERE id = p_business_id;

    IF v_biz_timezone IS NULL OR TRIM(v_biz_timezone) = '' THEN
      v_biz_timezone := 'UTC';
    END IF;

    -- Daily disbursement limit enforcement under business timezone day boundary
    SELECT COALESCE(SUM(amount + fee_amount), 0.0000)
    INTO v_today_disbursements
    FROM public.mobile_money_transactions
    WHERE business_id = p_business_id
      AND wallet_id = p_financial_account_id
      AND direction = 'out'
      AND occurred_at >= (DATE_TRUNC('day', NOW() AT TIME ZONE v_biz_timezone) AT TIME ZONE v_biz_timezone);

    IF (v_today_disbursements + v_exp.amount + v_fee_to_charge) > v_wallet.daily_disbursement_limit THEN
      RAISE EXCEPTION 'DAILY_LIMIT_EXCEEDED: Transaction exceeds daily disbursement limit of % (Disbursed today: %, Attempted: %)',
        v_wallet.daily_disbursement_limit, v_today_disbursements, (v_exp.amount + v_fee_to_charge);
    END IF;

    INSERT INTO public.mobile_money_transactions (
      business_id,
      wallet_id,
      direction,
      amount,
      fee_amount,
      currency,
      transaction_type,
      telecom_reference,
      recipient_phone,
      expense_id,
      description,
      actor_user_id,
      idempotency_key,
      occurred_at
    ) VALUES (
      p_business_id,
      p_financial_account_id,
      'out',
      v_exp.amount,
      v_fee_to_charge,
      v_exp.currency,
      'payout',
      p_reference_number,
      COALESCE(TRIM(p_recipient_phone), v_exp.recipient_phone),
      p_expense_id,
      'Expense payout: ' || v_exp.description,
      v_caller_id,
      p_idempotency_key,
      NOW()
    )
    RETURNING id INTO v_tx_id;

  ELSE
    RAISE EXCEPTION 'UNSUPPORTED_OPERATION: Unsupported financial account type %', p_financial_account_type;
  END IF;

  -- 7. Update Expense Status to Paid
  UPDATE public.expenses
  SET
    status = 'paid',
    approved_by = v_caller_id,
    approved_at = NOW(),
    paid_by = v_caller_id,
    paid_at = NOW(),
    payment_method = p_payment_method,
    financial_account_type = p_financial_account_type,
    financial_account_id = p_financial_account_id,
    recipient_phone = COALESCE(TRIM(p_recipient_phone), v_exp.recipient_phone),
    updated_at = NOW()
  WHERE id = p_expense_id;

  -- 8. Audit Event
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
    'EXPENSE_APPROVED_AND_PAID',
    'expense',
    p_expense_id,
    jsonb_build_object(
      'expense_number', v_exp.expense_number,
      'amount', v_exp.amount,
      'fee_amount', v_fee_to_charge,
      'currency', v_exp.currency,
      'previous_status', v_exp.status,
      'new_status', 'paid',
      'financial_account_type', p_financial_account_type,
      'financial_account_id', p_financial_account_id,
      'ledger_transaction_id', v_tx_id,
      'payment_method', p_payment_method
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'expense_id', p_expense_id,
    'status', 'paid',
    'financial_account_type', p_financial_account_type,
    'financial_account_id', p_financial_account_id,
    'ledger_transaction_id', v_tx_id,
    'fee_amount', v_fee_to_charge,
    'paid_at', NOW()
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

-- ------------------------------------------------------------------------------
-- 12. AUTHORITATIVE RPC: rpc_reject_expense
-- Category B: Optional but implemented idempotency
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_reject_expense(
  p_business_id UUID,
  p_expense_id UUID,
  p_reason TEXT,
  p_idempotency_key UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_exp RECORD;
  v_idem_res JSONB;
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF TRIM(COALESCE(p_reason, '')) = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Rejection reason is required';
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    v_canonical_hash_input := jsonb_build_object(
      'business_id', LOWER(p_business_id::text),
      'expense_id', LOWER(p_expense_id::text),
      'reason', TRIM(p_reason)
    )::text;
    v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');
    v_idem_res := public.fn_idempotency_acquire(
      p_business_id,
      p_idempotency_key,
      'rpc_reject_expense',
      v_request_hash,
      v_caller_id
    );
    IF v_idem_res->>'action' = 'replay' THEN
      RETURN v_idem_res->'payload';
    END IF;
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'expenses:reject')
    OR public.has_permission(p_business_id, 'expenses:approve')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot reject expenses in business %', v_caller_id, p_business_id;
  END IF;

  SELECT * INTO v_exp
  FROM public.expenses
  WHERE id = p_expense_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EXPENSE_NOT_FOUND: Expense % does not exist in business %', p_expense_id, p_business_id;
  END IF;

  IF v_exp.created_by = v_caller_id THEN
    RAISE EXCEPTION 'SELF_REJECT_PROHIBITED: Requester/creator cannot reject their own expense request';
  END IF;

  IF v_exp.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'INVALID_STATUS: Only pending_approval expenses can be rejected (Current: %)', v_exp.status;
  END IF;

  UPDATE public.expenses
  SET
    status = 'rejected',
    rejection_reason = TRIM(p_reason),
    rejected_by = v_caller_id,
    rejected_at = NOW(),
    updated_at = NOW()
  WHERE id = p_expense_id;

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
    'EXPENSE_REJECTED',
    'expense',
    p_expense_id,
    jsonb_build_object(
      'previous_status', v_exp.status,
      'new_status', 'rejected',
      'reason', TRIM(p_reason)
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'expense_id', p_expense_id,
    'status', 'rejected',
    'rejected_by', v_caller_id,
    'rejected_at', NOW()
  );

  IF p_idempotency_key IS NOT NULL THEN
    PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);
  END IF;

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

-- ------------------------------------------------------------------------------
-- 13. AUTHORITATIVE RPC: rpc_return_expense_for_correction
-- Category B: Optional but implemented idempotency
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_return_expense_for_correction(
  p_business_id UUID,
  p_expense_id UUID,
  p_reason TEXT,
  p_idempotency_key UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_exp RECORD;
  v_idem_res JSONB;
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF TRIM(COALESCE(p_reason, '')) = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Return reason is required';
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    v_canonical_hash_input := jsonb_build_object(
      'business_id', LOWER(p_business_id::text),
      'expense_id', LOWER(p_expense_id::text),
      'reason', TRIM(p_reason)
    )::text;
    v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');
    v_idem_res := public.fn_idempotency_acquire(
      p_business_id,
      p_idempotency_key,
      'rpc_return_expense_for_correction',
      v_request_hash,
      v_caller_id
    );
    IF v_idem_res->>'action' = 'replay' THEN
      RETURN v_idem_res->'payload';
    END IF;
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'expenses:return')
    OR public.has_permission(p_business_id, 'expenses:approve')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot return expenses for correction in business %', v_caller_id, p_business_id;
  END IF;

  SELECT * INTO v_exp
  FROM public.expenses
  WHERE id = p_expense_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EXPENSE_NOT_FOUND: Expense % does not exist in business %', p_expense_id, p_business_id;
  END IF;

  IF v_exp.created_by = v_caller_id THEN
    RAISE EXCEPTION 'SELF_RETURN_PROHIBITED: Requester/creator cannot return their own expense request';
  END IF;

  IF v_exp.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'INVALID_STATUS: Only pending_approval expenses can be returned for correction (Current: %)', v_exp.status;
  END IF;

  UPDATE public.expenses
  SET
    status = 'returned',
    return_reason = TRIM(p_reason),
    returned_by = v_caller_id,
    returned_at = NOW(),
    updated_at = NOW()
  WHERE id = p_expense_id;

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
    'EXPENSE_RETURNED_FOR_CORRECTION',
    'expense',
    p_expense_id,
    jsonb_build_object(
      'previous_status', v_exp.status,
      'new_status', 'returned',
      'reason', TRIM(p_reason)
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'expense_id', p_expense_id,
    'status', 'returned',
    'returned_by', v_caller_id,
    'returned_at', NOW()
  );

  IF p_idempotency_key IS NOT NULL THEN
    PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);
  END IF;

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

-- ------------------------------------------------------------------------------
-- 14. AUTHORITATIVE RPC: rpc_cancel_expense
-- Category B: Optional but implemented idempotency
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_cancel_expense(
  p_business_id UUID,
  p_expense_id UUID,
  p_reason TEXT,
  p_idempotency_key UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_exp RECORD;
  v_idem_res JSONB;
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    v_canonical_hash_input := jsonb_build_object(
      'business_id', LOWER(p_business_id::text),
      'expense_id', LOWER(p_expense_id::text),
      'reason', TRIM(p_reason)
    )::text;
    v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');
    v_idem_res := public.fn_idempotency_acquire(
      p_business_id,
      p_idempotency_key,
      'rpc_cancel_expense',
      v_request_hash,
      v_caller_id
    );
    IF v_idem_res->>'action' = 'replay' THEN
      RETURN v_idem_res->'payload';
    END IF;
  END IF;

  SELECT * INTO v_exp
  FROM public.expenses
  WHERE id = p_expense_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EXPENSE_NOT_FOUND: Expense % does not exist in business %', p_expense_id, p_business_id;
  END IF;

  IF NOT (
    (v_exp.created_by = v_caller_id AND v_exp.status IN ('draft', 'pending_approval', 'returned'))
    OR public.is_business_owner(p_business_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot cancel expense %', v_caller_id, p_expense_id;
  END IF;

  IF v_exp.status IN ('paid', 'reversed', 'cancelled', 'rejected') THEN
    RAISE EXCEPTION 'INVALID_STATUS: Cannot cancel an expense in status %', v_exp.status;
  END IF;

  UPDATE public.expenses
  SET
    status = 'cancelled',
    cancellation_reason = TRIM(p_reason),
    cancelled_by = v_caller_id,
    cancelled_at = NOW(),
    updated_at = NOW()
  WHERE id = p_expense_id;

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
    'EXPENSE_CANCELLED',
    'expense',
    p_expense_id,
    jsonb_build_object(
      'previous_status', v_exp.status,
      'new_status', 'cancelled',
      'reason', TRIM(p_reason)
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'expense_id', p_expense_id,
    'status', 'cancelled',
    'cancelled_by', v_caller_id,
    'cancelled_at', NOW()
  );

  IF p_idempotency_key IS NOT NULL THEN
    PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);
  END IF;

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

-- ------------------------------------------------------------------------------
-- 15. AUTHORITATIVE RPC: rpc_reverse_paid_expense
-- Category A: Mandatory idempotency & Structural Reversal Linkage
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_reverse_paid_expense(
  p_business_id UUID,
  p_expense_id UUID,
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
  v_exp RECORD;
  v_original_tx_id UUID;
  v_reversal_tx_id UUID;
  v_orig_wallet_tx RECORD;
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
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_reverse_paid_expense';
  END IF;

  IF TRIM(COALESCE(p_reversal_reason, '')) = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Reversal reason is required';
  END IF;

  v_canonical_hash_input := jsonb_build_object(
    'business_id', LOWER(p_business_id::text),
    'expense_id', LOWER(p_expense_id::text),
    'reason', TRIM(p_reversal_reason)
  )::text;
  v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');
  v_idem_res := public.fn_idempotency_acquire(
    p_business_id,
    p_idempotency_key,
    'rpc_reverse_paid_expense',
    v_request_hash,
    v_caller_id
  );
  IF v_idem_res->>'action' = 'replay' THEN
    RETURN v_idem_res->'payload';
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'expenses:reverse')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot reverse expenses in business %', v_caller_id, p_business_id;
  END IF;

  SELECT * INTO v_exp
  FROM public.expenses
  WHERE id = p_expense_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EXPENSE_NOT_FOUND: Expense % does not exist in business %', p_expense_id, p_business_id;
  END IF;

  IF v_exp.status = 'reversed' THEN
    RAISE EXCEPTION 'INVALID_STATUS: Expense % is already reversed', p_expense_id;
  END IF;

  IF v_exp.status <> 'paid' THEN
    RAISE EXCEPTION 'INVALID_STATUS: Only paid expenses can be reversed (Current: %)', v_exp.status;
  END IF;

  -- Authoritative settlement check: legacy cash/other expenses without account or transaction fail closed
  IF v_exp.financial_account_type IS NULL OR v_exp.financial_account_id IS NULL THEN
    RAISE EXCEPTION 'LEGACY_TREASURY_SOURCE_UNKNOWN: Expense % cannot be reversed because it has no authoritative treasury account record', p_expense_id;
  END IF;

  -- Post Opposite Movement with Structural Linkage
  IF v_exp.financial_account_type = 'bank' THEN
    SELECT id INTO v_original_tx_id
    FROM public.bank_transactions
    WHERE business_id = p_business_id
      AND bank_account_id = v_exp.financial_account_id
      AND source_type = 'expense'
      AND transaction_type = 'expense_payment'
      AND direction = 'debit'
      AND source_id = p_expense_id
    ORDER BY occurred_at DESC
    LIMIT 1;

    IF v_original_tx_id IS NULL THEN
      RAISE EXCEPTION 'ORIGINAL_TRANSACTION_NOT_FOUND: Original bank transaction for expense % not found in business %',
        p_expense_id, p_business_id;
    END IF;

    -- Conforms to frozen source_type ('expense'), transaction_type ('adjustment'), direction ('credit')
    v_reversal_tx_id := public.fn_post_bank_transaction_internal(
      p_business_id,
      v_exp.financial_account_id,
      'adjustment',
      'credit',
      v_exp.amount,
      v_exp.currency,
      'expense',
      p_expense_id,
      v_exp.expense_number || '-REV',
      'Reversal of expense payout ' || v_exp.expense_number || ': ' || v_exp.description,
      v_caller_id,
      jsonb_build_object('reversal_of_transaction_id', v_original_tx_id, 'reversal_reason', TRIM(p_reversal_reason))
    );

  ELSIF v_exp.financial_account_type = 'business_cash' THEN
    SELECT id INTO v_original_tx_id
    FROM public.vault_transactions
    WHERE business_id = p_business_id
      AND vault_id = v_exp.financial_account_id
      AND expense_id = p_expense_id
      AND direction = 'out'
    ORDER BY occurred_at DESC
    LIMIT 1;

    IF v_original_tx_id IS NULL THEN
      RAISE EXCEPTION 'ORIGINAL_TRANSACTION_NOT_FOUND: Original cash vault transaction for expense % not found in business %',
        p_expense_id, p_business_id;
    END IF;

    INSERT INTO public.vault_transactions (
      business_id,
      vault_id,
      direction,
      amount,
      currency,
      transaction_type,
      expense_id,
      reversal_of_transaction_id,
      description,
      actor_user_id,
      idempotency_key,
      occurred_at
    ) VALUES (
      p_business_id,
      v_exp.financial_account_id,
      'in',
      v_exp.amount,
      v_exp.currency,
      'reversal',
      p_expense_id,
      v_original_tx_id,
      'Reversal of expense payout ' || v_exp.expense_number || ': ' || v_exp.description,
      v_caller_id,
      p_idempotency_key,
      NOW()
    )
    RETURNING id INTO v_reversal_tx_id;

  ELSIF v_exp.financial_account_type = 'petty_cash' THEN
    SELECT id INTO v_original_tx_id
    FROM public.petty_cash_transactions
    WHERE business_id = p_business_id
      AND petty_cash_account_id = v_exp.financial_account_id
      AND expense_id = p_expense_id
      AND direction = 'out'
    ORDER BY occurred_at DESC
    LIMIT 1;

    IF v_original_tx_id IS NULL THEN
      RAISE EXCEPTION 'ORIGINAL_TRANSACTION_NOT_FOUND: Original petty cash transaction for expense % not found in business %',
        p_expense_id, p_business_id;
    END IF;

    INSERT INTO public.petty_cash_transactions (
      business_id,
      petty_cash_account_id,
      budget_id,
      direction,
      amount,
      currency,
      transaction_type,
      expense_id,
      reversal_of_transaction_id,
      notes,
      actor_user_id,
      idempotency_key,
      occurred_at
    ) VALUES (
      p_business_id,
      v_exp.financial_account_id,
      v_exp.petty_cash_budget_id,
      'in',
      v_exp.amount,
      v_exp.currency,
      'reversal',
      p_expense_id,
      v_original_tx_id,
      'Reversal of expense disbursement ' || v_exp.expense_number || ': ' || v_exp.description,
      v_caller_id,
      p_idempotency_key,
      NOW()
    )
    RETURNING id INTO v_reversal_tx_id;

  ELSIF v_exp.financial_account_type IN ('moncash', 'natcash') THEN
    SELECT id, fee_amount INTO v_orig_wallet_tx
    FROM public.mobile_money_transactions
    WHERE business_id = p_business_id
      AND wallet_id = v_exp.financial_account_id
      AND expense_id = p_expense_id
      AND direction = 'out'
    ORDER BY occurred_at DESC
    LIMIT 1;

    IF v_orig_wallet_tx.id IS NULL THEN
      RAISE EXCEPTION 'ORIGINAL_TRANSACTION_NOT_FOUND: Original mobile money transaction for expense % not found in business %',
        p_expense_id, p_business_id;
    END IF;

    INSERT INTO public.mobile_money_transactions (
      business_id,
      wallet_id,
      direction,
      amount,
      fee_amount,
      currency,
      transaction_type,
      recipient_phone,
      expense_id,
      reversal_of_transaction_id,
      description,
      actor_user_id,
      idempotency_key,
      occurred_at
    ) VALUES (
      p_business_id,
      v_exp.financial_account_id,
      'in',
      v_exp.amount,
      0.0000,
      v_exp.currency,
      'reversal',
      v_exp.recipient_phone,
      p_expense_id,
      v_orig_wallet_tx.id,
      'Reversal of mobile money payout ' || v_exp.expense_number || ': ' || v_exp.description,
      v_caller_id,
      p_idempotency_key,
      NOW()
    )
    RETURNING id INTO v_reversal_tx_id;

  ELSE
    RAISE EXCEPTION 'UNSUPPORTED_REVERSAL_CHANNEL: Cannot reverse expense % with unsupported financial account type %',
      p_expense_id, v_exp.financial_account_type;
  END IF;

  IF v_reversal_tx_id IS NULL THEN
    RAISE EXCEPTION 'REVERSAL_FAILED: Authoritative reversal ledger movement was not created';
  END IF;

  UPDATE public.expenses
  SET
    status = 'reversed',
    reversal_reason = TRIM(p_reversal_reason),
    reversed_by = v_caller_id,
    reversed_at = NOW(),
    reversal_transaction_id = v_reversal_tx_id,
    updated_at = NOW()
  WHERE id = p_expense_id;

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
    'EXPENSE_REVERSED',
    'expense',
    p_expense_id,
    jsonb_build_object(
      'expense_number', v_exp.expense_number,
      'amount', v_exp.amount,
      'currency', v_exp.currency,
      'previous_status', 'paid',
      'new_status', 'reversed',
      'financial_account_type', v_exp.financial_account_type,
      'financial_account_id', v_exp.financial_account_id,
      'original_transaction_id', v_original_tx_id,
      'reversal_transaction_id', v_reversal_tx_id,
      'reason', TRIM(p_reversal_reason)
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'expense_id', p_expense_id,
    'status', 'reversed',
    'reversal_transaction_id', v_reversal_tx_id,
    'reversed_by', v_caller_id,
    'reversed_at', NOW()
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

-- ------------------------------------------------------------------------------
-- 16. AUTHORITATIVE RPC: rpc_allocate_petty_cash_budget
-- Category A: Mandatory idempotency
-- ------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_allocate_petty_cash_budget(
  p_business_id UUID,
  p_petty_cash_account_id UUID,
  p_period_name TEXT,
  p_start_date DATE,
  p_end_date DATE,
  p_allocated_budget NUMERIC,
  p_idempotency_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_budget_id UUID;
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
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_allocate_petty_cash_budget';
  END IF;

  -- Consistent permission key: treasury:petty_cash:manage
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'treasury:petty_cash:manage')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot allocate petty cash budgets in business %', v_caller_id, p_business_id;
  END IF;

  IF p_allocated_budget < 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Allocated budget cannot be negative';
  END IF;

  IF p_end_date < p_start_date THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Period end date must be on or after start date';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.petty_cash_accounts
    WHERE id = p_petty_cash_account_id AND business_id = p_business_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'INVALID_ACCOUNT: Petty cash account is inactive or not found';
  END IF;

  v_canonical_hash_input := jsonb_build_object(
    'business_id', LOWER(p_business_id::text),
    'petty_cash_account_id', LOWER(p_petty_cash_account_id::text),
    'period_name', TRIM(p_period_name),
    'start_date', p_start_date::text,
    'end_date', p_end_date::text,
    'allocated_budget', to_char(p_allocated_budget, 'FM999999999999990.0000')
  )::text;
  v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');
  v_idem_res := public.fn_idempotency_acquire(
    p_business_id,
    p_idempotency_key,
    'rpc_allocate_petty_cash_budget',
    v_request_hash,
    v_caller_id
  );
  IF v_idem_res->>'action' = 'replay' THEN
    RETURN v_idem_res->'payload';
  END IF;

  INSERT INTO public.petty_cash_budgets (
    business_id,
    petty_cash_account_id,
    period_name,
    start_date,
    end_date,
    allocated_budget,
    status,
    created_by,
    created_at,
    updated_at
  ) VALUES (
    p_business_id,
    p_petty_cash_account_id,
    TRIM(p_period_name),
    p_start_date,
    p_end_date,
    p_allocated_budget,
    'active',
    v_caller_id,
    NOW(),
    NOW()
  )
  RETURNING id INTO v_budget_id;

  INSERT INTO public.commercial_audit_logs (
    business_id, actor_id, action, target_type, target_id, details
  ) VALUES (
    p_business_id, v_caller_id, 'PETTY_CASH_BUDGET_ALLOCATED', 'petty_cash_budget', v_budget_id,
    jsonb_build_object('period_name', TRIM(p_period_name), 'allocated_budget', p_allocated_budget, 'start_date', p_start_date, 'end_date', p_end_date)
  );

  v_result := jsonb_build_object(
    'success', true,
    'budget_id', v_budget_id,
    'period_name', TRIM(p_period_name),
    'allocated_budget', p_allocated_budget
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

-- ------------------------------------------------------------------------------

-- ----------------------------------------------------------------------------------
-- 17. AUTHORITATIVE TREASURY ACCOUNT MANAGEMENT RPCS
-- Controlled, permission-enforced management path for new treasury entities
-- ---------------------------------------------------------------------------------

-- Business Cash Vault Creation
CREATE OR REPLACE FUNCTION public.rpc_create_business_cash_vault(
  p_business_id UUID,
  p_branch_id UUID,
  p_vault_name TEXT,
  p_vault_code TEXT,
  p_currency VARCHAR DEFAULT 'USD',
  p_custodian_user_id UUID DEFAULT NULL,
  p_idempotency_key UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_vault_id UUID;
  v_idem_res JSONB;
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    v_canonical_hash_input := jsonb_build_object(
      'business_id', LOWER(p_business_id::text),
      'vault_name', TRIM(p_vault_name),
      'vault_code', UPPER(TRIM(p_vault_code)),
      'currency', UPPER(TRIM(p_currency))
    )::text;
    v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');
    v_idem_res := public.fn_idempotency_acquire(
      p_business_id,
      p_idempotency_key,
      'rpc_create_business_cash_vault',
      v_request_hash,
      v_caller_id
    );
    IF (v_idem_res->>'action') = 'replay' THEN
      RETURN v_idem_res->'payload';
    END IF;
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'treasury:vault:manage')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot manage business cash vaults', v_caller_id;
  END IF;

  -- Authoritative branch validation: belongs to business, active, not deleted
  IF p_branch_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.branches
      WHERE id = p_branch_id AND business_id = p_business_id AND status = 'active' AND deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'INVALID_BRANCH: Branch % does not exist, is inactive, or belongs to another business', p_branch_id;
    END IF;
  END IF;

  -- Custodian validation: active member of the business
  IF p_custodian_user_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.business_memberships
      WHERE business_id = p_business_id AND user_id = p_custodian_user_id AND status = 'active'
    ) THEN
      RAISE EXCEPTION 'INVALID_CUSTODIAN: Custodian % is not an active member of business %', p_custodian_user_id, p_business_id;
    END IF;
  END IF;

  INSERT INTO public.business_cash_vaults (
    business_id, branch_id, vault_name, vault_code, currency, custodian_user_id
  ) VALUES (
    p_business_id, p_branch_id, TRIM(p_vault_name), UPPER(TRIM(p_vault_code)), UPPER(TRIM(p_currency)), p_custodian_user_id
  ) RETURNING id INTO v_vault_id;

  INSERT INTO public.commercial_audit_logs (
    business_id, actor_id, action, target_type, target_id, details
  ) VALUES (
    p_business_id, v_caller_id, 'VAULT_CREATED', 'business_cash_vault', v_vault_id,
    jsonb_build_object('vault_name', TRIM(p_vault_name), 'vault_code', UPPER(TRIM(p_vault_code)), 'currency', UPPER(TRIM(p_currency)))
  );

  v_result := jsonb_build_object('success', true, 'vault_id', v_vault_id);

  IF p_idempotency_key IS NOT NULL THEN
    PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);
  END IF;

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

-- Business Cash Vault Status & Lifecycle Update
CREATE OR REPLACE FUNCTION public.rpc_update_business_cash_vault_status(
  p_business_id UUID,
  p_vault_id UUID,
  p_status TEXT
)
RETURNS JSONB
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

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'treasury:vault:manage')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot manage business cash vaults', v_caller_id;
  END IF;

  IF p_status NOT IN ('active', 'inactive', 'locked') THEN
    RAISE EXCEPTION 'INVALID_STATUS: Status must be active, inactive, or locked';
  END IF;

  UPDATE public.business_cash_vaults
  SET status = p_status, updated_at = NOW()
  WHERE id = p_vault_id AND business_id = p_business_id AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'VAULT_NOT_FOUND: Cash vault % not found in business %', p_vault_id, p_business_id;
  END IF;

  INSERT INTO public.commercial_audit_logs (
    business_id, actor_id, action, target_type, target_id, details
  ) VALUES (
    p_business_id, v_caller_id, 'VAULT_STATUS_UPDATED', 'business_cash_vault', p_vault_id,
    jsonb_build_object('status', p_status)
  );

  RETURN jsonb_build_object('success', true, 'vault_id', p_vault_id, 'status', p_status);
END;
$$;

-- Petty Cash Account Creation
CREATE OR REPLACE FUNCTION public.rpc_create_petty_cash_account(
  p_business_id UUID,
  p_branch_id UUID,
  p_box_name TEXT,
  p_box_code TEXT,
  p_custodian_user_id UUID,
  p_currency VARCHAR DEFAULT 'USD',
  p_max_float_limit NUMERIC DEFAULT 1000.0000,
  p_idempotency_key UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_account_id UUID;
  v_idem_res JSONB;
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    v_canonical_hash_input := jsonb_build_object(
      'business_id', LOWER(p_business_id::text),
      'box_name', TRIM(p_box_name),
      'box_code', UPPER(TRIM(p_box_code)),
      'custodian_user_id', LOWER(p_custodian_user_id::text),
      'currency', UPPER(TRIM(p_currency))
    )::text;
    v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');
    v_idem_res := public.fn_idempotency_acquire(
      p_business_id,
      p_idempotency_key,
      'rpc_create_petty_cash_account',
      v_request_hash,
      v_caller_id
    );
    IF (v_idem_res->>'action') = 'replay' THEN
      RETURN v_idem_res->'payload';
    END IF;
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'treasury:petty_cash:manage')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot manage petty cash accounts', v_caller_id;
  END IF;

  -- Authoritative branch validation: belongs to business, active, not deleted
  IF p_branch_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.branches
      WHERE id = p_branch_id AND business_id = p_business_id AND status = 'active' AND deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'INVALID_BRANCH: Branch % does not exist, is inactive, or belongs to another business', p_branch_id;
    END IF;
  END IF;

  -- Custodian validation: active member of the business
  IF NOT EXISTS (
    SELECT 1 FROM public.business_memberships
    WHERE business_id = p_business_id AND user_id = p_custodian_user_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'INVALID_CUSTODIAN: Custodian % is not an active member of business %', p_custodian_user_id, p_business_id;
  END IF;

  IF p_max_float_limit < 0 THEN
    RAISE EXCEPTION 'INVALID_FLOAT: Float limit cannot be negative';
  END IF;

  INSERT INTO public.petty_cash_accounts (
    business_id, branch_id, box_name, box_code, custodian_user_id, currency, max_float_limit
  ) VALUES (
    p_business_id, p_branch_id, TRIM(p_box_name), UPPER(TRIM(p_box_code)), p_custodian_user_id, UPPER(TRIM(p_currency)), p_max_float_limit
  ) RETURNING id INTO v_account_id;

  INSERT INTO public.commercial_audit_logs (
    business_id, actor_id, action, target_type, target_id, details
  ) VALUES (
    p_business_id, v_caller_id, 'PETTY_CASH_ACCOUNT_CREATED', 'petty_cash_account', v_account_id,
    jsonb_build_object('box_name', TRIM(p_box_name), 'box_code', UPPER(TRIM(p_box_code)), 'currency', UPPER(TRIM(p_currency)), 'max_float_limit', p_max_float_limit)
  );

  v_result := jsonb_build_object('success', true, 'petty_cash_account_id', v_account_id);

  IF p_idempotency_key IS NOT NULL THEN
    PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);
  END IF;

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

-- Petty Cash Account Status & Float Limit Update
CREATE OR REPLACE FUNCTION public.rpc_update_petty_cash_account(
  p_business_id UUID,
  p_account_id UUID,
  p_status TEXT DEFAULT NULL,
  p_max_float_limit NUMERIC DEFAULT NULL
)
RETURNS JSONB
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

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'treasury:petty_cash:manage')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot manage petty cash accounts', v_caller_id;
  END IF;

  IF p_status IS NOT NULL AND p_status NOT IN ('active', 'frozen', 'closed') THEN
    RAISE EXCEPTION 'INVALID_STATUS: Petty cash status must be active, frozen, or closed';
  END IF;

  IF p_max_float_limit IS NOT NULL AND p_max_float_limit < 0 THEN
    RAISE EXCEPTION 'INVALID_FLOAT: Float limit cannot be negative';
  END IF;

  UPDATE public.petty_cash_accounts
  SET
    status = COALESCE(p_status, status),
    max_float_limit = COALESCE(p_max_float_limit, max_float_limit),
    updated_at = NOW()
  WHERE id = p_account_id AND business_id = p_business_id AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ACCOUNT_NOT_FOUND: Petty cash account % not found in business %', p_account_id, p_business_id;
  END IF;

  INSERT INTO public.commercial_audit_logs (
    business_id, actor_id, action, target_type, target_id, details
  ) VALUES (
    p_business_id, v_caller_id, 'PETTY_CASH_ACCOUNT_UPDATED', 'petty_cash_account', p_account_id,
    jsonb_build_object('status', p_status, 'max_float_limit', p_max_float_limit)
  );

  RETURN jsonb_build_object('success', true, 'petty_cash_account_id', p_account_id);
END;
$$;

-- Mobile Money Wallet Creation
CREATE OR REPLACE FUNCTION public.rpc_create_mobile_money_wallet(
  p_business_id UUID,
  p_provider TEXT,
  p_account_name TEXT,
  p_phone_number TEXT,
  p_merchant_id TEXT DEFAULT NULL,
  p_currency VARCHAR DEFAULT 'HTG',
  p_daily_limit NUMERIC DEFAULT 100000.0000,
  p_idempotency_key UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_wallet_id UUID;
  v_idem_res JSONB;
  v_request_hash VARCHAR(64);
  v_canonical_hash_input TEXT;
  v_result JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    v_canonical_hash_input := jsonb_build_object(
      'business_id', LOWER(p_business_id::text),
      'provider', TRIM(p_provider),
      'phone_number', TRIM(p_phone_number),
      'currency', UPPER(TRIM(p_currency))
    )::text;
    v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');
    v_idem_res := public.fn_idempotency_acquire(
      p_business_id,
      p_idempotency_key,
      'rpc_create_mobile_money_wallet',
      v_request_hash,
      v_caller_id
    );
    IF (v_idem_res->>'action') = 'replay' THEN
      RETURN v_idem_res->'payload';
    END IF;
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'treasury:mobile_money:manage')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot manage mobile money accounts', v_caller_id;
  END IF;

  IF p_provider NOT IN ('MonCash', 'NatCash') THEN
    RAISE EXCEPTION 'INVALID_PROVIDER: Mobile money provider must be MonCash or NatCash';
  END IF;

  IF p_daily_limit < 0 THEN
    RAISE EXCEPTION 'INVALID_LIMIT: Daily disbursement limit cannot be negative';
  END IF;

  INSERT INTO public.mobile_money_wallets (
    business_id, provider, account_name, phone_number, merchant_id, currency, daily_disbursement_limit
  ) VALUES (
    p_business_id, p_provider, TRIM(p_account_name), TRIM(p_phone_number), p_merchant_id, UPPER(TRIM(p_currency)), p_daily_limit
  ) RETURNING id INTO v_wallet_id;

  INSERT INTO public.commercial_audit_logs (
    business_id, actor_id, action, target_type, target_id, details
  ) VALUES (
    p_business_id, v_caller_id, 'WALLET_CREATED', 'mobile_money_wallet', v_wallet_id,
    jsonb_build_object('provider', TRIM(p_provider), 'phone_number', TRIM(p_phone_number), 'currency', UPPER(TRIM(p_currency)), 'daily_limit', p_daily_limit)
  );

  v_result := jsonb_build_object('success', true, 'wallet_id', v_wallet_id);

  IF p_idempotency_key IS NOT NULL THEN
    PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);
  END IF;

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

-- Mobile Money Wallet Status & Daily Limit Update
CREATE OR REPLACE FUNCTION public.rpc_update_mobile_money_wallet(
  p_business_id UUID,
  p_wallet_id UUID,
  p_status TEXT DEFAULT NULL,
  p_daily_disbursement_limit NUMERIC DEFAULT NULL
)
RETURNS JSONB
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

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'treasury:mobile_money:manage')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot manage mobile money accounts', v_caller_id;
  END IF;

  IF p_status IS NOT NULL AND p_status NOT IN ('active', 'inactive', 'suspended', 'closed') THEN
    RAISE EXCEPTION 'INVALID_STATUS: Status must be active, inactive, suspended, or closed';
  END IF;

  IF p_daily_disbursement_limit IS NOT NULL AND p_daily_disbursement_limit < 0 THEN
    RAISE EXCEPTION 'INVALID_LIMIT: Daily disbursement limit cannot be negative';
  END IF;

  UPDATE public.mobile_money_wallets
  SET
    status = COALESCE(p_status, status),
    daily_disbursement_limit = COALESCE(p_daily_disbursement_limit, daily_disbursement_limit),
    updated_at = NOW()
  WHERE id = p_wallet_id AND business_id = p_business_id AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'WALLET_NOT_FOUND: Mobile money wallet % not found in business %', p_wallet_id, p_business_id;
  END IF;

  INSERT INTO public.commercial_audit_logs (
    business_id, actor_id, action, target_type, target_id, details
  ) VALUES (
    p_business_id, v_caller_id, 'WALLET_UPDATED', 'mobile_money_wallet', p_wallet_id,
    jsonb_build_object('status', p_status, 'daily_disbursement_limit', p_daily_disbursement_limit)
  );

  RETURN jsonb_build_object('success', true, 'wallet_id', p_wallet_id);
END;
$$;

-- ----------------------------------------------------------------------------------
-- 18. AUTHORITATIVE TREASURY FUNDING WORKFLOW RPCS
-- Authoritative, append-only, idempotent ledger funding for new treasury channels
-- ---------------------------------------------------------------------------------

-- 18.1 Business Cash Vault Funding (Opening Balance & Cash Deposits)
CREATE OR REPLACE FUNCTION public.rpc_fund_business_cash_vault(
  p_business_id UUID,
  p_vault_id UUID,
  p_amount NUMERIC,
  p_currency VARCHAR,
  p_transaction_type TEXT,
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
  v_vault RECORD;
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
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_fund_business_cash_vault';
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'treasury:vault:manage')
    OR public.has_permission(p_business_id, 'cash:manage')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot fund business cash vaults in business %', v_caller_id, p_business_id;
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Funding amount must be greater than zero';
  END IF;

  IF p_transaction_type NOT IN ('opening_balance', 'deposit') THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Funding transaction type must be opening_balance or deposit';
  END IF;

  v_canonical_hash_input := jsonb_build_object(
    'business_id', LOWER(p_business_id::text),
    'vault_id', LOWER(p_vault_id::text),
    'amount', to_char(p_amount, 'FM999999999999990.0000'),
    'currency', UPPER(TRIM(p_currency)),
    'transaction_type', p_transaction_type
  )::text;
  v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(
    p_business_id,
    p_idempotency_key,
    'rpc_fund_business_cash_vault',
    v_request_hash,
    v_caller_id
  );
  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN v_idem_res->'payload';
  END IF;

  SELECT * INTO v_vault
  FROM public.business_cash_vaults
  WHERE id = p_vault_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND OR v_vault.status <> 'active' OR v_vault.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'INVALID_ACCOUNT: Business cash vault % does not exist, is inactive, or deleted', p_vault_id;
  END IF;

  IF v_vault.currency <> UPPER(TRIM(p_currency)) THEN
    RAISE EXCEPTION 'CURRENCY_MISMATCH: Funding currency % does not match vault currency %',
      UPPER(TRIM(p_currency)), v_vault.currency;
  END IF;

  INSERT INTO public.vault_transactions (
    business_id,
    vault_id,
    direction,
    amount,
    currency,
    transaction_type,
    description,
    actor_user_id,
    idempotency_key,
    occurred_at,
    created_at,
    metadata
  ) VALUES (
    p_business_id,
    p_vault_id,
    'in',
    p_amount,
    v_vault.currency,
    p_transaction_type,
    COALESCE(TRIM(p_notes), 'Vault funding: ' || p_transaction_type),
    v_caller_id,
    p_idempotency_key,
    NOW(),
    NOW(),
    jsonb_build_object('funded_by', v_caller_id, 'funding_type', p_transaction_type)
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
    'VAULT_FUNDED',
    'business_cash_vault',
    p_vault_id,
    jsonb_build_object(
      'transaction_id', v_tx_id,
      'amount', p_amount,
      'currency', v_vault.currency,
      'transaction_type', p_transaction_type
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'vault_id', p_vault_id,
    'transaction_id', v_tx_id,
    'amount', p_amount,
    'currency', v_vault.currency,
    'transaction_type', p_transaction_type
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

-- 18.2 Petty Cash Account Float Funding / Replenishment
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
    RETURN v_idem_res->'payload';
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

  IF (v_current_balance + p_amount) > v_account.max_float_limit THEN
    RAISE EXCEPTION 'FLOAT_LIMIT_EXCEEDED: Replenishment would cause balance (% + %) to exceed max float limit (%)',
      v_current_balance, p_amount, v_account.max_float_limit;
  END IF;

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
      'currency', v_account.currency,
      'new_balance', v_current_balance + p_amount
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'petty_cash_account_id', p_petty_cash_account_id,
    'transaction_id', v_tx_id,
    'amount', p_amount,
    'currency', v_account.currency,
    'balance', v_current_balance + p_amount
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

-- 18.3 Mobile Money Wallet Opening Balance / Cash-In
CREATE OR REPLACE FUNCTION public.rpc_fund_mobile_money_wallet(
  p_business_id UUID,
  p_wallet_id UUID,
  p_amount NUMERIC,
  p_currency VARCHAR,
  p_transaction_type TEXT,
  p_idempotency_key UUID,
  p_telecom_reference TEXT DEFAULT NULL,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_wallet RECORD;
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
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: p_idempotency_key is mandatory for rpc_fund_mobile_money_wallet';
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'treasury:mobile_money:manage')
    OR public.has_permission(p_business_id, 'bank:manage')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot fund mobile money wallets in business %', v_caller_id, p_business_id;
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Funding amount must be greater than zero';
  END IF;

  IF p_transaction_type NOT IN ('opening_balance', 'collection', 'cash_in') THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Funding transaction type must be opening_balance, collection, or cash_in';
  END IF;

  v_canonical_hash_input := jsonb_build_object(
    'business_id', LOWER(p_business_id::text),
    'wallet_id', LOWER(p_wallet_id::text),
    'amount', to_char(p_amount, 'FM999999999999990.0000'),
    'currency', UPPER(TRIM(p_currency)),
    'transaction_type', p_transaction_type
  )::text;
  v_request_hash := encode(sha256(v_canonical_hash_input::bytea), 'hex');

  v_idem_res := public.fn_idempotency_acquire(
    p_business_id,
    p_idempotency_key,
    'rpc_fund_mobile_money_wallet',
    v_request_hash,
    v_caller_id
  );
  IF (v_idem_res->>'action') = 'replay' THEN
    RETURN v_idem_res->'payload';
  END IF;

  SELECT * INTO v_wallet
  FROM public.mobile_money_wallets
  WHERE id = p_wallet_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND OR v_wallet.status <> 'active' OR v_wallet.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'INVALID_ACCOUNT: Mobile money wallet % does not exist, is inactive, or deleted', p_wallet_id;
  END IF;

  IF v_wallet.currency <> UPPER(TRIM(p_currency)) THEN
    RAISE EXCEPTION 'CURRENCY_MISMATCH: Funding currency % does not match wallet currency %',
      UPPER(TRIM(p_currency)), v_wallet.currency;
  END IF;

  INSERT INTO public.mobile_money_transactions (
    business_id,
    wallet_id,
    direction,
    amount,
    fee_amount,
    currency,
    transaction_type,
    telecom_reference,
    description,
    actor_user_id,
    idempotency_key,
    occurred_at,
    created_at,
    metadata
  ) VALUES (
    p_business_id,
    p_wallet_id,
    'in',
    p_amount,
    0.0000,
    v_wallet.currency,
    p_transaction_type,
    p_telecom_reference,
    COALESCE(TRIM(p_notes), 'Mobile money cash-in: ' || p_transaction_type),
    v_caller_id,
    p_idempotency_key,
    NOW(),
    NOW(),
    jsonb_build_object('funded_by', v_caller_id, 'funding_type', p_transaction_type)
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
    'WALLET_CASH_IN',
    'mobile_money_wallet',
    p_wallet_id,
    jsonb_build_object(
      'transaction_id', v_tx_id,
      'amount', p_amount,
      'currency', v_wallet.currency,
      'transaction_type', p_transaction_type,
      'telecom_reference', p_telecom_reference
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'wallet_id', p_wallet_id,
    'transaction_id', v_tx_id,
    'amount', p_amount,
    'currency', v_wallet.currency,
    'transaction_type', p_transaction_type
  );

  PERFORM public.fn_idempotency_commit(p_business_id, p_idempotency_key, v_result);

  RETURN v_result || jsonb_build_object('is_replay', false);
END;
$$;

-- ----------------------------------------------------------------------------------
-- 19. PERMISSIONS GRANT FOR MANAGEMENT & FUNDING RPCS
-- ---------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.rpc_create_business_cash_vault FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_business_cash_vault TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_update_business_cash_vault_status FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_update_business_cash_vault_status TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_create_petty_cash_account FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_petty_cash_account TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_update_petty_cash_account FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_update_petty_cash_account TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_create_mobile_money_wallet FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_mobile_money_wallet TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_update_mobile_money_wallet FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_update_mobile_money_wallet TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_fund_business_cash_vault FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_fund_business_cash_vault TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_fund_petty_cash_account FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_fund_petty_cash_account TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_fund_mobile_money_wallet FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_fund_mobile_money_wallet TO authenticated;

-- ----------------------------------------------------------------------------------
-- 20. WORKFLOW RPCS REVOKES & GRANTS
-- ---------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.rpc_submit_expense_request FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_submit_expense_request TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_approve_and_pay_expense FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_approve_and_pay_expense TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_reject_expense FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_reject_expense TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_return_expense_for_correction FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_return_expense_for_correction TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_cancel_expense FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_cancel_expense TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_reverse_paid_expense FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_reverse_paid_expense TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_allocate_petty_cash_budget FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_allocate_petty_cash_budget TO authenticated;
