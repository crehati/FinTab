-- =============================================================================
-- FIN_TAB ENTERPRISE — MIGRATION 004: COMMERCIAL & TREASURY FOUNDATION
-- File: supabase/migrations/004_commercial_and_treasury.sql
-- 
-- DESCRIPTION:
-- Authoritative operational foundation for Commercial (POS Registers, Shifts,
-- Customers, Sales Transactions, Line Items, Payments) and Treasury (Bank
-- Accounts, Immutable Bank Ledger, Immutable Cash Ledger, Expense Categories,
-- Expenses).
--
-- INTEGRATION BASELINE:
-- - Extends Migration 001 (Identity, Businesses, Branches, Memberships, updated_at).
-- - Extends Migration 002 (Roles, Permissions, Scoped RBAC, Capital Engine).
-- - Extends Migration 003 (Catalog, Products, Prices, Inventory Locations, Balances, Movements).
--
-- CORE ARCHITECTURAL INVARIANTS:
-- 1. All monetary tables carry business_id and enforce composite tenant-safety FKs.
-- 2. bank_transactions and cash_transactions are append-only immutable ledgers.
-- 3. Completed sales transaction items and historical costs are locked against mutation.
-- 4. Customer outstanding balance is NEVER a manual column; derived from commercial ledger.
-- 5. Cash balances and Bank balances derive from immutable ledger entries, not client updates.
-- 6. Register shifts do NOT post closing counts as cash movements (reconciliation only).
-- 7. Expense approval and expense payment are distinct states with treasury gating.
-- 8. Concurrency-safe server-side sequence numbering for all commercial documents.
-- 9. Zero destructive operations on completed financial history.
-- =============================================================================

-- =============================================================================
-- 1. PERMISSIONS & ROLE ASSIGNMENTS
-- =============================================================================

-- 1.1 Seed Commercial & Treasury Permissions
INSERT INTO public.permissions (key, module, description)
VALUES
  -- Sales & POS
  ('sales:view', 'sales', 'View sales transactions, receipts, and order histories'),
  ('sales:create', 'sales', 'Create sales orders, quotes, invoices, and process checkout'),
  ('sales:void', 'sales', 'Void unpaid or error-recorded sales transactions'),
  ('sales:refund', 'sales', 'Issue customer refunds and return authorizations'),

  -- Payments & Receivables
  ('payments:view', 'payments', 'View payment receipts, split tender, and transaction settlements'),
  ('payments:record', 'payments', 'Record customer payments against open sales invoices'),

  -- Customer CRM
  ('customers:view', 'customers', 'View customer directory, credit terms, and contact profiles'),
  ('customers:manage', 'customers', 'Create, update, and manage customer accounts and credit limits'),

  -- POS Registers & Cash Shifts
  ('registers:view', 'registers', 'View POS terminals, configurations, and shift histories'),
  ('registers:manage', 'registers', 'Open/close registers, configure hardware, and manage shift lifecycles'),

  -- Cash Operations & Petty Cash
  ('cash:view', 'cash', 'View branch cash registers, petty cash balances, and shift totals'),
  ('cash:manage', 'cash', 'Execute cash adjustments, safe drops, drawer float, and petty cash payouts'),

  -- Bank Accounts & Treasury
  ('bank:view', 'banking', 'View business bank accounts, statements, and transaction ledgers'),
  ('bank:manage', 'banking', 'Manage bank accounts, record manual bank entries, and reconcile accounts'),

  -- Expense Management
  ('expenses:view', 'expenses', 'View operational expenses, expense categories, and disbursement logs'),
  ('expenses:create', 'expenses', 'Create and submit operational expense requests and bills'),
  ('expenses:approve', 'expenses', 'Approve pending expense requests prior to treasury payout'),
  ('expenses:pay', 'expenses', 'Execute treasury disbursement and settle approved expenses')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module,
  description = EXCLUDED.description;

-- 1.2 Map Commercial & Treasury Permissions to System Roles
DO $$
DECLARE
  v_role_id UUID;
BEGIN
  -- PrimaryOwner: Holds universal access to all commercial and treasury features
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'PrimaryOwner' AND is_system = true;
  IF v_role_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id FROM public.permissions p
    WHERE p.key IN (
      'sales:view', 'sales:create', 'sales:void', 'sales:refund',
      'payments:view', 'payments:record',
      'customers:view', 'customers:manage',
      'registers:view', 'registers:manage',
      'cash:view', 'cash:manage',
      'bank:view', 'bank:manage',
      'expenses:view', 'expenses:create', 'expenses:approve', 'expenses:pay'
    )
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END IF;

  -- SuperAdmin: Comprehensive administrative access
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'SuperAdmin' AND is_system = true;
  IF v_role_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id FROM public.permissions p
    WHERE p.key IN (
      'sales:view', 'sales:create', 'sales:void', 'sales:refund',
      'payments:view', 'payments:record',
      'customers:view', 'customers:manage',
      'registers:view', 'registers:manage',
      'cash:view', 'cash:manage',
      'bank:view', 'bank:manage',
      'expenses:view', 'expenses:create', 'expenses:approve', 'expenses:pay'
    )
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END IF;

  -- GeneralManager: Full operational commercial and treasury execution
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'GeneralManager' AND is_system = true;
  IF v_role_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id FROM public.permissions p
    WHERE p.key IN (
      'sales:view', 'sales:create', 'sales:void', 'sales:refund',
      'payments:view', 'payments:record',
      'customers:view', 'customers:manage',
      'registers:view', 'registers:manage',
      'cash:view', 'cash:manage',
      'bank:view', 'bank:manage',
      'expenses:view', 'expenses:create', 'expenses:approve', 'expenses:pay'
    )
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END IF;

  -- BranchManager: Scoped operational authority within branch
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'BranchManager' AND is_system = true;
  IF v_role_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id FROM public.permissions p
    WHERE p.key IN (
      'sales:view', 'sales:create', 'sales:void', 'sales:refund',
      'payments:view', 'payments:record',
      'customers:view', 'customers:manage',
      'registers:view', 'registers:manage',
      'cash:view', 'cash:manage',
      'expenses:view', 'expenses:create', 'expenses:approve'
    )
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END IF;

  -- FinanceManager: Full treasury, banking, expenses, receivables, and read access to commercial
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'FinanceManager' AND is_system = true;
  IF v_role_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id FROM public.permissions p
    WHERE p.key IN (
      'sales:view',
      'payments:view', 'payments:record',
      'customers:view',
      'cash:view', 'cash:manage',
      'bank:view', 'bank:manage',
      'expenses:view', 'expenses:create', 'expenses:approve', 'expenses:pay'
    )
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END IF;

  -- SalesManager: Commercial sales, customer management, void/refund approvals, registers view
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'SalesManager' AND is_system = true;
  IF v_role_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id FROM public.permissions p
    WHERE p.key IN (
      'sales:view', 'sales:create', 'sales:void', 'sales:refund',
      'payments:view', 'payments:record',
      'customers:view', 'customers:manage',
      'registers:view'
    )
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END IF;

  -- Salesperson: Create sales, view customers, record initial payments
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'Salesperson' AND is_system = true;
  IF v_role_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id FROM public.permissions p
    WHERE p.key IN (
      'sales:view', 'sales:create',
      'payments:view', 'payments:record',
      'customers:view', 'customers:manage',
      'registers:view'
    )
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END IF;

  -- Cashier: Operate POS checkout, record tender payments, view registers and drawer
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'Cashier' AND is_system = true;
  IF v_role_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id FROM public.permissions p
    WHERE p.key IN (
      'sales:view', 'sales:create',
      'payments:view', 'payments:record',
      'registers:view',
      'customers:view',
      'cash:view'
    )
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END IF;

  -- Viewer: Read-only access to sales and customers
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'Viewer' AND is_system = true;
  IF v_role_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id FROM public.permissions p
    WHERE p.key IN ('sales:view', 'customers:view')
    ON CONFLICT (role_id, permission_id) DO NOTHING;
  END IF;
END $$;

-- =============================================================================
-- 2. SERVER-SIDE DOCUMENT SEQUENCING INFRASTRUCTURE
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.document_sequences (
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  doc_type TEXT NOT NULL,
  current_val BIGINT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT pk_document_sequences PRIMARY KEY (business_id, doc_type)
);

CREATE INDEX IF NOT EXISTS idx_document_sequences_biz ON public.document_sequences(business_id);

-- Hardened concurrency-safe sequencer
CREATE OR REPLACE FUNCTION public.rpc_next_document_number(
  p_business_id UUID,
  p_doc_type TEXT,
  p_prefix TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_val BIGINT;
  v_prefix TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_business_id IS NULL OR p_doc_type IS NULL THEN
    RAISE EXCEPTION 'INVALID_ARGUMENT: business_id and doc_type are required';
  END IF;

  -- Validate caller has access to business
  IF NOT (
    public.is_business_owner(p_business_id)
    OR EXISTS (
      SELECT 1 FROM public.business_memberships
      WHERE business_id = p_business_id AND user_id = auth.uid() AND status = 'active'
    )
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % does not belong to business %', auth.uid(), p_business_id;
  END IF;

  -- Default prefixes
  IF p_prefix IS NOT NULL THEN
    v_prefix := p_prefix;
  ELSE
    v_prefix := CASE p_doc_type
      WHEN 'sale' THEN 'TXN'
      WHEN 'shift' THEN 'SH'
      WHEN 'customer' THEN 'CUST'
      WHEN 'payment' THEN 'PAY'
      WHEN 'expense' THEN 'EXP'
      WHEN 'bank_ref' THEN 'BNK'
      ELSE UPPER(p_doc_type)
    END;
  END IF;

  INSERT INTO public.document_sequences (business_id, doc_type, current_val, updated_at)
  VALUES (p_business_id, p_doc_type, 1, NOW())
  ON CONFLICT (business_id, doc_type)
  DO UPDATE SET
    current_val = document_sequences.current_val + 1,
    updated_at = NOW()
  RETURNING current_val INTO v_val;

  RETURN v_prefix || '-' || LPAD(v_val::TEXT, 6, '0');
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_next_document_number(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_next_document_number(UUID, TEXT, TEXT) TO authenticated;

-- =============================================================================
-- 3. COMMERCIAL REGISTERS & CASHIER SHIFTS (TABLES 1 - 2)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3.1 Table 1: public.registers (POS Hardware / Workstations)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.registers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  branch_id UUID NOT NULL,
  inventory_location_id UUID,
  name TEXT NOT NULL,
  code TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'maintenance', 'retired')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Composite unique keys
  CONSTRAINT uq_registers_business_id_id UNIQUE (business_id, id),
  CONSTRAINT uq_registers_branch_code UNIQUE (business_id, branch_id, code),

  -- Composite tenant foreign keys
  CONSTRAINT fk_registers_branch
    FOREIGN KEY (business_id, branch_id)
    REFERENCES public.branches(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_registers_inventory_location
    FOREIGN KEY (business_id, inventory_location_id)
    REFERENCES public.inventory_locations(business_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_registers_biz ON public.registers (business_id);
CREATE INDEX IF NOT EXISTS idx_registers_branch ON public.registers (business_id, branch_id);

-- -----------------------------------------------------------------------------
-- 3.2 Table 2: public.register_shifts (Shift Lifecycle & Float Reconciliations)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.register_shifts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  branch_id UUID NOT NULL,
  register_id UUID NOT NULL,
  shift_number TEXT NOT NULL,
  opened_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  opened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  opening_float NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (opening_float >= 0),
  closed_by UUID REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  closed_at TIMESTAMPTZ,
  expected_cash NUMERIC(15, 4) CHECK (expected_cash IS NULL OR expected_cash >= 0),
  counted_cash NUMERIC(15, 4) CHECK (counted_cash IS NULL OR counted_cash >= 0),
  variance NUMERIC(15, 4),
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'cancelled', 'audited')),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Composite unique keys
  CONSTRAINT uq_register_shifts_business_id_id UNIQUE (business_id, id),
  CONSTRAINT uq_register_shifts_biz_number UNIQUE (business_id, shift_number),

  -- Composite tenant foreign keys
  CONSTRAINT fk_register_shifts_branch
    FOREIGN KEY (business_id, branch_id)
    REFERENCES public.branches(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_register_shifts_register
    FOREIGN KEY (business_id, register_id)
    REFERENCES public.registers(business_id, id)
    ON DELETE RESTRICT,

  -- Sanity checks
  CONSTRAINT chk_register_shifts_closed
    CHECK (status <> 'closed' OR (closed_by IS NOT NULL AND closed_at IS NOT NULL AND counted_cash IS NOT NULL))
);

-- At most one active open shift per physical register
CREATE UNIQUE INDEX IF NOT EXISTS uq_register_shifts_single_open
  ON public.register_shifts (business_id, register_id)
  WHERE status = 'open';

CREATE INDEX IF NOT EXISTS idx_register_shifts_biz ON public.register_shifts (business_id);
CREATE INDEX IF NOT EXISTS idx_register_shifts_branch ON public.register_shifts (business_id, branch_id);
CREATE INDEX IF NOT EXISTS idx_register_shifts_register ON public.register_shifts (register_id);

-- =============================================================================
-- 4. CUSTOMER CRM & RECEIVABLES PROFILE (TABLE 3)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.customers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  customer_number TEXT NOT NULL,
  full_name TEXT NOT NULL,
  phone TEXT,
  email TEXT,
  address JSONB DEFAULT '{}'::jsonb,
  tax_id TEXT,
  credit_limit NUMERIC(15, 4) DEFAULT 0.0000 CHECK (credit_limit >= 0),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'suspended', 'archived')),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Composite unique keys
  CONSTRAINT uq_customers_business_id_id UNIQUE (business_id, id),
  CONSTRAINT uq_customers_biz_number UNIQUE (business_id, customer_number)
);

CREATE INDEX IF NOT EXISTS idx_customers_biz ON public.customers (business_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_customers_phone ON public.customers (business_id, phone) WHERE deleted_at IS NULL;

-- =============================================================================
-- 5. CANONICAL SALES TRANSACTIONS & LINE ITEMS (TABLES 4 - 5)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 5.1 Table 4: public.sales_transactions
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sales_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  branch_id UUID NOT NULL,
  register_id UUID,
  shift_id UUID,
  cashier_user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  customer_id UUID,
  transaction_number TEXT NOT NULL,
  transaction_type TEXT NOT NULL DEFAULT 'sale' CHECK (
    transaction_type IN ('sale', 'return', 'exchange', 'estimate', 'void')
  ),
  status TEXT NOT NULL DEFAULT 'completed' CHECK (
    status IN ('draft', 'pending_payment', 'partially_paid', 'completed', 'cancelled', 'voided', 'refunded')
  ),
  subtotal NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (subtotal >= 0),
  discount_total NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (discount_total >= 0),
  tax_total NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (tax_total >= 0),
  total_amount NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (total_amount >= 0),
  amount_paid NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (amount_paid >= 0),
  balance_due NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (balance_due >= 0),
  currency VARCHAR(3) NOT NULL,
  notes TEXT,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Math integrity checks
  CONSTRAINT chk_sales_trans_math
    CHECK (total_amount = (subtotal - discount_total + tax_total)),

  CONSTRAINT chk_sales_trans_no_overpayment
    CHECK (amount_paid <= total_amount),

  CONSTRAINT chk_sales_trans_balance
    CHECK (balance_due = (total_amount - amount_paid)),

  -- Composite unique keys
  CONSTRAINT uq_sales_transactions_business_id_id UNIQUE (business_id, id),
  CONSTRAINT uq_sales_transactions_biz_number UNIQUE (business_id, transaction_number),

  -- Composite tenant foreign keys
  CONSTRAINT fk_sales_transactions_branch
    FOREIGN KEY (business_id, branch_id)
    REFERENCES public.branches(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_sales_transactions_register
    FOREIGN KEY (business_id, register_id)
    REFERENCES public.registers(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_sales_transactions_shift
    FOREIGN KEY (business_id, shift_id)
    REFERENCES public.register_shifts(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_sales_transactions_customer
    FOREIGN KEY (business_id, customer_id)
    REFERENCES public.customers(business_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_sales_trans_biz_date ON public.sales_transactions (business_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_sales_trans_customer ON public.sales_transactions (business_id, customer_id) WHERE customer_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sales_trans_status ON public.sales_transactions (business_id, status);
CREATE INDEX IF NOT EXISTS idx_sales_trans_shift ON public.sales_transactions (shift_id) WHERE shift_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 5.2 Table 5: public.sales_transaction_items (Historical Line Snapshots)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sales_transaction_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  transaction_id UUID NOT NULL,
  product_id UUID NOT NULL,
  inventory_location_id UUID,
  quantity NUMERIC(15, 4) NOT NULL CHECK (quantity > 0),
  unit_price NUMERIC(15, 4) NOT NULL CHECK (unit_price >= 0),
  discount_amount NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (discount_amount >= 0),
  tax_amount NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (tax_amount >= 0),
  line_total NUMERIC(15, 4) NOT NULL CHECK (line_total >= 0),
  cost_price NUMERIC(15, 4) NOT NULL DEFAULT 0.0000 CHECK (cost_price >= 0),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Mathematical consistency
  CONSTRAINT chk_sales_item_math
    CHECK (line_total = ((quantity * unit_price) - discount_amount + tax_amount)),

  -- Composite unique key
  CONSTRAINT uq_sales_transaction_items_business_id_id UNIQUE (business_id, id),

  -- Composite tenant foreign keys (No destructive cascade on completed sales items)
  CONSTRAINT fk_sales_trans_items_parent
    FOREIGN KEY (business_id, transaction_id)
    REFERENCES public.sales_transactions(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_sales_trans_items_product
    FOREIGN KEY (business_id, product_id)
    REFERENCES public.products(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_sales_trans_items_location
    FOREIGN KEY (business_id, inventory_location_id)
    REFERENCES public.inventory_locations(business_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_sales_trans_items_parent ON public.sales_transaction_items (transaction_id);
CREATE INDEX IF NOT EXISTS idx_sales_trans_items_product ON public.sales_transaction_items (business_id, product_id);

-- =============================================================================
-- 6. TREASURY: BANK ACCOUNTS & IMMUTABLE BANK LEDGER (TABLES 6 - 7)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 6.1 Table 6: public.bank_accounts
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.bank_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  account_name TEXT NOT NULL,
  bank_name TEXT NOT NULL,
  account_number_masked TEXT NOT NULL,
  account_type TEXT NOT NULL DEFAULT 'checking' CHECK (
    account_type IN ('checking', 'savings', 'money_market', 'credit', 'other')
  ),
  currency VARCHAR(3) NOT NULL,
  routing_number TEXT,
  swift_bic TEXT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'frozen', 'closed')),
  is_primary BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Composite unique key
  CONSTRAINT uq_bank_accounts_business_id_id UNIQUE (business_id, id)
);

CREATE INDEX IF NOT EXISTS idx_bank_accounts_biz ON public.bank_accounts (business_id) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 6.2 Table 7: public.bank_transactions (Authoritative Immutable Bank Ledger)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.bank_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  bank_account_id UUID NOT NULL,
  transaction_type TEXT NOT NULL CHECK (
    transaction_type IN (
      'deposit', 'withdrawal', 'transfer_in', 'transfer_out',
      'fee', 'interest', 'adjustment', 'payment_settlement', 'expense_payment'
    )
  ),
  direction TEXT NOT NULL CHECK (direction IN ('credit', 'debit')),
  amount NUMERIC(15, 4) NOT NULL CHECK (amount > 0),
  currency VARCHAR(3) NOT NULL,
  source_type TEXT NOT NULL CHECK (
    source_type IN ('payment', 'expense', 'transfer', 'manual', 'opening_balance', 'reconciliation')
  ),
  source_id UUID,
  reference_number TEXT,
  description TEXT NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  actor_user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Composite unique key
  CONSTRAINT uq_bank_transactions_business_id_id UNIQUE (business_id, id),

  -- Composite tenant foreign key
  CONSTRAINT fk_bank_transactions_account
    FOREIGN KEY (business_id, bank_account_id)
    REFERENCES public.bank_accounts(business_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_bank_trans_biz ON public.bank_transactions (business_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_bank_trans_account ON public.bank_transactions (bank_account_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_bank_trans_source ON public.bank_transactions (business_id, source_type, source_id);

-- =============================================================================
-- 7. TREASURY: IMMUTABLE CASH LEDGER (TABLE 8)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.cash_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  branch_id UUID NOT NULL,
  register_id UUID,
  shift_id UUID,
  direction TEXT NOT NULL CHECK (direction IN ('in', 'out')),
  amount NUMERIC(15, 4) NOT NULL CHECK (amount > 0),
  currency VARCHAR(3) NOT NULL,
  source_type TEXT NOT NULL CHECK (
    source_type IN (
      'opening_float', 'cash_sale', 'refund', 'expense',
      'withdrawal', 'deposit', 'adjustment', 'manual'
    )
  ),
  source_id UUID,
  description TEXT NOT NULL,
  actor_user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Composite unique key
  CONSTRAINT uq_cash_transactions_business_id_id UNIQUE (business_id, id),

  -- Composite tenant foreign keys
  CONSTRAINT fk_cash_transactions_branch
    FOREIGN KEY (business_id, branch_id)
    REFERENCES public.branches(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_cash_transactions_register
    FOREIGN KEY (business_id, register_id)
    REFERENCES public.registers(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_cash_transactions_shift
    FOREIGN KEY (business_id, shift_id)
    REFERENCES public.register_shifts(business_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_cash_trans_biz ON public.cash_transactions (business_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_cash_trans_branch ON public.cash_transactions (business_id, branch_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_cash_trans_shift ON public.cash_transactions (shift_id) WHERE shift_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_cash_trans_source ON public.cash_transactions (business_id, source_type, source_id);

-- =============================================================================
-- 8. COMMERCIAL PAYMENTS (TABLE 9)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  branch_id UUID NOT NULL,
  transaction_id UUID NOT NULL,
  payment_number TEXT NOT NULL,
  payment_method TEXT NOT NULL CHECK (
    payment_method IN ('cash', 'bank_transfer', 'debit_card', 'credit_card', 'mobile_money', 'store_credit', 'other')
  ),
  amount NUMERIC(15, 4) NOT NULL CHECK (amount > 0),
  currency VARCHAR(3) NOT NULL,
  bank_account_id UUID,
  register_id UUID,
  shift_id UUID,
  reference_number TEXT,
  status TEXT NOT NULL DEFAULT 'completed' CHECK (
    status IN ('pending', 'completed', 'failed', 'refunded', 'voided')
  ),
  received_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Composite unique keys
  CONSTRAINT uq_payments_business_id_id UNIQUE (business_id, id),
  CONSTRAINT uq_payments_biz_number UNIQUE (business_id, payment_number),

  -- Composite tenant foreign keys
  CONSTRAINT fk_payments_branch
    FOREIGN KEY (business_id, branch_id)
    REFERENCES public.branches(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_payments_transaction
    FOREIGN KEY (business_id, transaction_id)
    REFERENCES public.sales_transactions(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_payments_bank_account
    FOREIGN KEY (business_id, bank_account_id)
    REFERENCES public.bank_accounts(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_payments_register
    FOREIGN KEY (business_id, register_id)
    REFERENCES public.registers(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_payments_shift
    FOREIGN KEY (business_id, shift_id)
    REFERENCES public.register_shifts(business_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_payments_biz ON public.payments (business_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_payments_trans ON public.payments (transaction_id);
CREATE INDEX IF NOT EXISTS idx_payments_method ON public.payments (business_id, payment_method);

-- =============================================================================
-- 9. EXPENSE MANAGEMENT (TABLES 10 - 11)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 9.1 Table 10: public.expense_categories
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.expense_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  code TEXT,
  description TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,

  -- Composite unique key
  CONSTRAINT uq_expense_categories_business_id_id UNIQUE (business_id, id),
  CONSTRAINT uq_expense_categories_biz_name UNIQUE (business_id, name)
);

CREATE INDEX IF NOT EXISTS idx_expense_categories_biz ON public.expense_categories (business_id) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 9.2 Table 11: public.expenses
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.expenses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  branch_id UUID,
  category_id UUID NOT NULL,
  expense_number TEXT NOT NULL,
  description TEXT NOT NULL,
  amount NUMERIC(15, 4) NOT NULL CHECK (amount > 0),
  currency VARCHAR(3) NOT NULL,
  expense_date DATE NOT NULL DEFAULT CURRENT_DATE,
  status TEXT NOT NULL DEFAULT 'draft' CHECK (
    status IN ('draft', 'pending_approval', 'approved', 'paid', 'voided')
  ),
  payment_method TEXT CHECK (
    payment_method IS NULL OR payment_method IN ('cash', 'bank_transfer', 'check', 'credit_card', 'debit_card', 'mobile_money', 'other')
  ),
  bank_account_id UUID,
  register_id UUID,
  shift_id UUID,
  created_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  approved_by UUID REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  approved_at TIMESTAMPTZ,
  paid_by UUID REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  paid_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Approval and Settlement gating
  CONSTRAINT chk_expenses_approved
    CHECK (status NOT IN ('approved', 'paid') OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),

  CONSTRAINT chk_expenses_paid
    CHECK (status <> 'paid' OR (paid_at IS NOT NULL AND paid_by IS NOT NULL AND payment_method IS NOT NULL)),

  -- Composite unique keys
  CONSTRAINT uq_expenses_business_id_id UNIQUE (business_id, id),
  CONSTRAINT uq_expenses_biz_number UNIQUE (business_id, expense_number),

  -- Composite tenant foreign keys
  CONSTRAINT fk_expenses_branch
    FOREIGN KEY (business_id, branch_id)
    REFERENCES public.branches(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_expenses_category
    FOREIGN KEY (business_id, category_id)
    REFERENCES public.expense_categories(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_expenses_bank_account
    FOREIGN KEY (business_id, bank_account_id)
    REFERENCES public.bank_accounts(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_expenses_register
    FOREIGN KEY (business_id, register_id)
    REFERENCES public.registers(business_id, id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_expenses_shift
    FOREIGN KEY (business_id, shift_id)
    REFERENCES public.register_shifts(business_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_expenses_biz ON public.expenses (business_id, expense_date DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_expenses_status ON public.expenses (business_id, status);
CREATE INDEX IF NOT EXISTS idx_expenses_category ON public.expenses (business_id, category_id);

-- =============================================================================
-- 10. RECONCILIATION PROJECTIONS & AGGREGATE VIEWS
-- =============================================================================

-- 10.1 Real-Time Bank Account Balances
CREATE OR REPLACE VIEW public.v_bank_account_balances
WITH (security_invoker = true)
AS
SELECT
  ba.business_id,
  ba.id AS bank_account_id,
  ba.account_name,
  ba.bank_name,
  ba.account_number_masked,
  ba.currency,
  ba.status,
  COALESCE(
    SUM(CASE WHEN bt.direction = 'credit' THEN bt.amount ELSE -bt.amount END),
    0.0000
  ) AS calculated_balance,
  MAX(bt.occurred_at) AS last_activity_at
FROM public.bank_accounts ba
LEFT JOIN public.bank_transactions bt ON ba.id = bt.bank_account_id AND ba.business_id = bt.business_id
WHERE ba.deleted_at IS NULL
GROUP BY ba.business_id, ba.id, ba.account_name, ba.bank_name, ba.account_number_masked, ba.currency, ba.status;

-- 10.2 Real-Time Cash Balances per Register / Branch
CREATE OR REPLACE VIEW public.v_cash_register_balances
WITH (security_invoker = true)
AS
SELECT
  ct.business_id,
  ct.branch_id,
  ct.register_id,
  ct.currency,
  COALESCE(
    SUM(CASE WHEN ct.direction = 'in' THEN ct.amount ELSE -ct.amount END),
    0.0000
  ) AS current_cash_on_hand,
  MAX(ct.occurred_at) AS last_cash_movement_at
FROM public.cash_transactions ct
GROUP BY ct.business_id, ct.branch_id, ct.register_id, ct.currency;

-- 10.3 Authoritative Customer Receivables
CREATE OR REPLACE VIEW public.v_customer_receivables
WITH (security_invoker = true)
AS
SELECT
  c.business_id,
  c.id AS customer_id,
  c.customer_number,
  c.full_name,
  c.credit_limit,
  c.currency_ref,
  COALESCE(st.total_invoiced, 0.0000) AS total_invoiced,
  COALESCE(st.total_paid, 0.0000) AS total_paid,
  COALESCE(st.total_outstanding, 0.0000) AS total_outstanding_balance,
  st.oldest_open_invoice_date
FROM (
  SELECT
    cust.business_id,
    cust.id,
    cust.customer_number,
    cust.full_name,
    cust.credit_limit,
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

-- =============================================================================
-- 11. IMMUTABILITY, TIMESTAMPS & DOCUMENT INTEGRITY TRIGGERS
-- =============================================================================

-- 11.1 Immutable Bank Ledger Trigger
CREATE OR REPLACE FUNCTION public.trg_protect_bank_transactions_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'IMMUTABLE_RECORD: bank_transactions is an append-only audit ledger. UPDATE and DELETE are prohibited.';
END;
$$;

DROP TRIGGER IF EXISTS trg_bank_transactions_immutable ON public.bank_transactions;
CREATE TRIGGER trg_bank_transactions_immutable
BEFORE UPDATE OR DELETE ON public.bank_transactions
FOR EACH ROW EXECUTE FUNCTION public.trg_protect_bank_transactions_immutability();

-- 11.2 Immutable Cash Ledger Trigger
CREATE OR REPLACE FUNCTION public.trg_protect_cash_transactions_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'IMMUTABLE_RECORD: cash_transactions is an append-only audit ledger. UPDATE and DELETE are prohibited.';
END;
$$;

DROP TRIGGER IF EXISTS trg_cash_transactions_immutable ON public.cash_transactions;
CREATE TRIGGER trg_cash_transactions_immutable
BEFORE UPDATE OR DELETE ON public.cash_transactions
FOR EACH ROW EXECUTE FUNCTION public.trg_protect_cash_transactions_immutability();

-- 11.3 Protect Sales Transaction Items from Post-Completion Alterations
CREATE OR REPLACE FUNCTION public.trg_protect_sales_transaction_items()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_status TEXT;
BEGIN
  SELECT status INTO v_status
  FROM public.sales_transactions
  WHERE id = COALESCE(OLD.transaction_id, NEW.transaction_id);

  IF v_status IN ('completed', 'voided', 'refunded') THEN
    RAISE EXCEPTION 'LOCKED_RECORD: Cannot modify line items of a finalized sales transaction (status: %).', v_status;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_trans_items_lock ON public.sales_transaction_items;
CREATE TRIGGER trg_sales_trans_items_lock
BEFORE INSERT OR UPDATE OR DELETE ON public.sales_transaction_items
FOR EACH ROW EXECUTE FUNCTION public.trg_protect_sales_transaction_items();

-- 11.4 Payment Sync Trigger (Maintains sales_transactions amount_paid and balance_due)
CREATE OR REPLACE FUNCTION public.trg_sync_payment_to_transaction()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_trans_id UUID;
  v_total_paid NUMERIC(15, 4);
  v_total_amount NUMERIC(15, 4);
  v_new_balance NUMERIC(15, 4);
  v_current_status TEXT;
BEGIN
  v_trans_id := COALESCE(NEW.transaction_id, OLD.transaction_id);

  SELECT total_amount, status INTO v_total_amount, v_current_status
  FROM public.sales_transactions
  WHERE id = v_trans_id;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  -- Calculate total completed payments
  SELECT COALESCE(SUM(amount), 0.0000) INTO v_total_paid
  FROM public.payments
  WHERE transaction_id = v_trans_id AND status = 'completed';

  v_new_balance := GREATEST(0.0000, v_total_amount - v_total_paid);

  UPDATE public.sales_transactions
  SET
    amount_paid = v_total_paid,
    balance_due = v_new_balance,
    status = CASE
      WHEN v_new_balance = 0.0000 THEN 'completed'
      WHEN v_total_paid > 0.0000 AND v_new_balance > 0.0000 THEN 'partially_paid'
      ELSE 'pending_payment'
    END,
    updated_at = NOW()
  WHERE id = v_trans_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_payments_sync_balance ON public.payments;
CREATE TRIGGER trg_payments_sync_balance
AFTER INSERT OR UPDATE OR DELETE ON public.payments
FOR EACH ROW EXECUTE FUNCTION public.trg_sync_payment_to_transaction();

-- 11.5 Protect Sales Transactions Immutability
CREATE OR REPLACE FUNCTION public.trg_protect_sales_transactions_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'IMMUTABLE_RECORD: Sales transactions cannot be deleted. Use status voided or cancelled.';
  END IF;

  IF OLD.status IN ('completed', 'voided', 'cancelled') THEN
    IF NEW.business_id <> OLD.business_id OR
       NEW.branch_id <> OLD.branch_id OR
       NEW.transaction_number <> OLD.transaction_number OR
       NEW.subtotal <> OLD.subtotal OR
       NEW.discount_total <> OLD.discount_total OR
       NEW.tax_total <> OLD.tax_total OR
       NEW.total_amount <> OLD.total_amount OR
       NEW.currency <> OLD.currency OR
       NEW.occurred_at <> OLD.occurred_at THEN
      RAISE EXCEPTION 'LOCKED_RECORD: Cannot modify finalized sales transaction % (status: %)', OLD.transaction_number, OLD.status;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_trans_lock ON public.sales_transactions;
CREATE TRIGGER trg_sales_trans_lock
BEFORE UPDATE OR DELETE ON public.sales_transactions
FOR EACH ROW EXECUTE FUNCTION public.trg_protect_sales_transactions_immutability();

-- 11.6 Protect Payments Immutability
CREATE OR REPLACE FUNCTION public.trg_protect_payments_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'IMMUTABLE_RECORD: Payments cannot be deleted. Void or issue refund instead.';
  END IF;

  IF OLD.status = 'completed' THEN
    IF NEW.business_id <> OLD.business_id OR
       NEW.branch_id <> OLD.branch_id OR
       NEW.transaction_id <> OLD.transaction_id OR
       NEW.amount <> OLD.amount OR
       NEW.currency <> OLD.currency OR
       NEW.payment_method <> OLD.payment_method OR
       NEW.bank_account_id IS DISTINCT FROM OLD.bank_account_id OR
       NEW.occurred_at <> OLD.occurred_at THEN
      RAISE EXCEPTION 'LOCKED_RECORD: Cannot modify settled payment % (status: completed)', OLD.payment_number;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_payments_lock ON public.payments;
CREATE TRIGGER trg_payments_lock
BEFORE UPDATE OR DELETE ON public.payments
FOR EACH ROW EXECUTE FUNCTION public.trg_protect_payments_immutability();

-- 11.7 Cross-Entity Integrity: Register inventory location must belong to same branch
CREATE OR REPLACE FUNCTION public.trg_validate_register_location_branch()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_loc_branch_id UUID;
BEGIN
  IF NEW.inventory_location_id IS NOT NULL THEN
    SELECT branch_id INTO v_loc_branch_id
    FROM public.inventory_locations
    WHERE id = NEW.inventory_location_id AND business_id = NEW.business_id;

    IF v_loc_branch_id IS DISTINCT FROM NEW.branch_id THEN
      RAISE EXCEPTION 'BRANCH_MISMATCH: Register branch (%) does not match inventory location branch (%)',
        NEW.branch_id, v_loc_branch_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_registers_location_branch_check ON public.registers;
CREATE TRIGGER trg_registers_location_branch_check
BEFORE INSERT OR UPDATE OF branch_id, inventory_location_id ON public.registers
FOR EACH ROW EXECUTE FUNCTION public.trg_validate_register_location_branch();

-- 11.8 Cross-Entity Integrity: Sales transaction register and shift must match branch and each other
CREATE OR REPLACE FUNCTION public.trg_validate_sales_transaction_register_shift()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_reg_branch_id UUID;
  v_shift_reg_id UUID;
  v_shift_branch_id UUID;
BEGIN
  IF NEW.register_id IS NOT NULL THEN
    SELECT branch_id INTO v_reg_branch_id
    FROM public.registers
    WHERE id = NEW.register_id AND business_id = NEW.business_id;

    IF v_reg_branch_id IS DISTINCT FROM NEW.branch_id THEN
      RAISE EXCEPTION 'BRANCH_MISMATCH: Sales transaction branch (%) does not match register branch (%)',
        NEW.branch_id, v_reg_branch_id;
    END IF;
  END IF;

  IF NEW.shift_id IS NOT NULL THEN
    SELECT register_id, branch_id INTO v_shift_reg_id, v_shift_branch_id
    FROM public.register_shifts
    WHERE id = NEW.shift_id AND business_id = NEW.business_id;

    IF v_shift_branch_id IS DISTINCT FROM NEW.branch_id THEN
      RAISE EXCEPTION 'BRANCH_MISMATCH: Sales transaction branch (%) does not match shift branch (%)',
        NEW.branch_id, v_shift_branch_id;
    END IF;

    IF NEW.register_id IS NOT NULL AND v_shift_reg_id IS DISTINCT FROM NEW.register_id THEN
      RAISE EXCEPTION 'REGISTER_MISMATCH: Sales transaction register (%) does not match shift register (%)',
        NEW.register_id, v_shift_reg_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_trans_reg_shift_check ON public.sales_transactions;
CREATE TRIGGER trg_sales_trans_reg_shift_check
BEFORE INSERT OR UPDATE OF branch_id, register_id, shift_id ON public.sales_transactions
FOR EACH ROW EXECUTE FUNCTION public.trg_validate_sales_transaction_register_shift();

-- 11.9 Cross-Entity Integrity: Sales line item location must match transaction branch
CREATE OR REPLACE FUNCTION public.trg_validate_sales_item_location_branch()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_trans_branch_id UUID;
  v_loc_branch_id UUID;
BEGIN
  IF NEW.inventory_location_id IS NOT NULL THEN
    SELECT branch_id INTO v_trans_branch_id
    FROM public.sales_transactions
    WHERE id = NEW.transaction_id AND business_id = NEW.business_id;

    SELECT branch_id INTO v_loc_branch_id
    FROM public.inventory_locations
    WHERE id = NEW.inventory_location_id AND business_id = NEW.business_id;

    IF v_loc_branch_id IS DISTINCT FROM v_trans_branch_id THEN
      RAISE EXCEPTION 'BRANCH_MISMATCH: Sales line item location branch (%) does not match transaction branch (%)',
        v_loc_branch_id, v_trans_branch_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_item_loc_branch_check ON public.sales_transaction_items;
CREATE TRIGGER trg_sales_item_loc_branch_check
BEFORE INSERT OR UPDATE OF inventory_location_id ON public.sales_transaction_items
FOR EACH ROW EXECUTE FUNCTION public.trg_validate_sales_item_location_branch();

-- 11.10 Business Currency Policy Enforcement
CREATE OR REPLACE FUNCTION public.trg_enforce_business_currency()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_biz_currency VARCHAR(3);
BEGIN
  SELECT currency INTO v_biz_currency
  FROM public.businesses
  WHERE id = NEW.business_id;

  IF NEW.currency IS NULL OR NEW.currency <> v_biz_currency THEN
    RAISE EXCEPTION 'CURRENCY_MISMATCH: Operational currency (%) must match business default currency (%)',
      NEW.currency, v_biz_currency;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_trans_currency_check ON public.sales_transactions;
CREATE TRIGGER trg_sales_trans_currency_check
BEFORE INSERT OR UPDATE OF currency ON public.sales_transactions
FOR EACH ROW EXECUTE FUNCTION public.trg_enforce_business_currency();

DROP TRIGGER IF EXISTS trg_cash_trans_currency_check ON public.cash_transactions;
CREATE TRIGGER trg_cash_trans_currency_check
BEFORE INSERT OR UPDATE OF currency ON public.cash_transactions
FOR EACH ROW EXECUTE FUNCTION public.trg_enforce_business_currency();

DROP TRIGGER IF EXISTS trg_expenses_currency_check ON public.expenses;
CREATE TRIGGER trg_expenses_currency_check
BEFORE INSERT OR UPDATE OF currency ON public.expenses
FOR EACH ROW EXECUTE FUNCTION public.trg_enforce_business_currency();

DROP TRIGGER IF EXISTS trg_payments_currency_check ON public.payments;
CREATE TRIGGER trg_payments_currency_check
BEFORE INSERT OR UPDATE OF currency ON public.payments
FOR EACH ROW EXECUTE FUNCTION public.trg_enforce_business_currency();

-- 11.11 Attach Canonical updated_at Triggers (Defined in Migration 001)
DROP TRIGGER IF EXISTS trg_registers_updated_at ON public.registers;
CREATE TRIGGER trg_registers_updated_at
BEFORE UPDATE ON public.registers
FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_register_shifts_updated_at ON public.register_shifts;
CREATE TRIGGER trg_register_shifts_updated_at
BEFORE UPDATE ON public.register_shifts
FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_customers_updated_at ON public.customers;
CREATE TRIGGER trg_customers_updated_at
BEFORE UPDATE ON public.customers
FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_sales_trans_updated_at ON public.sales_transactions;
CREATE TRIGGER trg_sales_trans_updated_at
BEFORE UPDATE ON public.sales_transactions
FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_bank_accounts_updated_at ON public.bank_accounts;
CREATE TRIGGER trg_bank_accounts_updated_at
BEFORE UPDATE ON public.bank_accounts
FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_payments_updated_at ON public.payments;
CREATE TRIGGER trg_payments_updated_at
BEFORE UPDATE ON public.payments
FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_expense_categories_updated_at ON public.expense_categories;
CREATE TRIGGER trg_expense_categories_updated_at
BEFORE UPDATE ON public.expense_categories
FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_expenses_updated_at ON public.expenses;
CREATE TRIGGER trg_expenses_updated_at
BEFORE UPDATE ON public.expenses
FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- =============================================================================
-- 12. HARDENED SECURITY DEFINER TRANSACTIONAL RPCS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 12.1 rpc_open_register_shift
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_open_register_shift(
  p_business_id UUID,
  p_branch_id UUID,
  p_register_id UUID,
  p_opening_float NUMERIC,
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
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  -- 1. Validate Business
  SELECT currency INTO v_currency
  FROM public.businesses
  WHERE id = p_business_id AND status = 'active' AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'BUSINESS_NOT_FOUND: Active business % not found', p_business_id;
  END IF;

  -- 2. Validate Authorization
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(p_business_id, 'registers:manage', p_branch_id)
    OR public.has_permission_in_scope(p_business_id, 'cash:manage', p_branch_id)
    OR public.has_permission_in_scope(p_business_id, 'sales:create', p_branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot open shift for register % in branch %',
      v_caller_id, p_register_id, p_branch_id;
  END IF;

  -- 3. Check for existing open shift on this register
  IF EXISTS (
    SELECT 1 FROM public.register_shifts
    WHERE business_id = p_business_id AND register_id = p_register_id AND status = 'open'
  ) THEN
    RAISE EXCEPTION 'SHIFT_ALREADY_OPEN: Register % already has an open active shift', p_register_id;
  END IF;

  -- 4. Generate Shift Number
  v_shift_num := public.rpc_next_document_number(p_business_id, 'shift', 'SH');

  -- 5. Create Shift Record
  INSERT INTO public.register_shifts (
    business_id, branch_id, register_id, shift_number,
    opened_by, opened_at, opening_float, status, notes
  ) VALUES (
    p_business_id, p_branch_id, p_register_id, v_shift_num,
    v_caller_id, NOW(), COALESCE(p_opening_float, 0.0000), 'open', p_notes
  ) RETURNING id INTO v_shift_id;

  -- 6. Post Opening Float to Cash Ledger if greater than zero
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

  RETURN jsonb_build_object(
    'success', true,
    'shift_id', v_shift_id,
    'shift_number', v_shift_num,
    'opening_float', p_opening_float,
    'status', 'open'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_open_register_shift(UUID, UUID, UUID, NUMERIC, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_open_register_shift(UUID, UUID, UUID, NUMERIC, TEXT) TO authenticated;

-- -----------------------------------------------------------------------------
-- 12.2 rpc_close_register_shift
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_close_register_shift(
  p_business_id UUID,
  p_shift_id UUID,
  p_counted_cash NUMERIC,
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
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  -- 1. Lock shift record for update
  SELECT * INTO v_shift
  FROM public.register_shifts
  WHERE id = p_shift_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SHIFT_NOT_FOUND: Shift % not found in business %', p_shift_id, p_business_id;
  END IF;

  IF v_shift.status <> 'open' THEN
    RAISE EXCEPTION 'INVALID_STATUS: Shift % is already % and cannot be closed', p_shift_id, v_shift.status;
  END IF;

  -- 2. Validate Authorization
  IF NOT (
    public.is_business_owner(p_business_id)
    OR v_shift.opened_by = v_caller_id
    OR public.has_permission_in_scope(p_business_id, 'registers:manage', v_shift.branch_id)
    OR public.has_permission_in_scope(p_business_id, 'cash:manage', v_shift.branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot close shift %', v_caller_id, p_shift_id;
  END IF;

  -- 3. Calculate expected cash from immutable cash ledger
  SELECT
    COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE 0 END), 0.0000),
    COALESCE(SUM(CASE WHEN direction = 'out' THEN amount ELSE 0 END), 0.0000)
  INTO v_cash_in, v_cash_out
  FROM public.cash_transactions
  WHERE shift_id = p_shift_id AND business_id = p_business_id;

  v_expected_cash := (v_cash_in - v_cash_out);
  v_variance := (p_counted_cash - v_expected_cash);

  -- 4. Close Shift Record (Reconciliation only - No artificial cash transaction)
  UPDATE public.register_shifts
  SET
    status = 'closed',
    closed_by = v_caller_id,
    closed_at = NOW(),
    expected_cash = v_expected_cash,
    counted_cash = p_counted_cash,
    variance = v_variance,
    notes = COALESCE(p_notes, notes),
    updated_at = NOW()
  WHERE id = p_shift_id;

  RETURN jsonb_build_object(
    'success', true,
    'shift_id', p_shift_id,
    'shift_number', v_shift.shift_number,
    'expected_cash', v_expected_cash,
    'counted_cash', p_counted_cash,
    'variance', v_variance,
    'status', 'closed'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_close_register_shift(UUID, UUID, NUMERIC, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_close_register_shift(UUID, UUID, NUMERIC, TEXT) TO authenticated;

-- -----------------------------------------------------------------------------
-- 12.3 rpc_post_bank_transaction
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_post_bank_transaction(
  p_business_id UUID,
  p_bank_account_id UUID,
  p_transaction_type TEXT,
  p_direction TEXT,
  p_amount NUMERIC,
  p_currency TEXT,
  p_source_type TEXT,
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
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  -- 1. Validate Bank Account Tenancy
  SELECT business_id INTO v_account_biz
  FROM public.bank_accounts
  WHERE id = p_bank_account_id AND status = 'active' AND deleted_at IS NULL;

  IF NOT FOUND OR v_account_biz <> p_business_id THEN
    RAISE EXCEPTION 'BANK_ACCOUNT_INVALID: Bank account % does not belong to business % or is inactive',
      p_bank_account_id, p_business_id;
  END IF;

  -- 2. Authorization
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'bank:manage')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot execute bank transactions for business %',
      v_caller_id, p_business_id;
  END IF;

  -- 3. Append to Immutable Bank Ledger
  INSERT INTO public.bank_transactions (
    business_id, bank_account_id, transaction_type, direction,
    amount, currency, source_type, source_id, reference_number,
    description, actor_user_id, occurred_at
  ) VALUES (
    p_business_id, p_bank_account_id, p_transaction_type, p_direction,
    p_amount, p_currency, p_source_type, p_source_id, p_reference_number,
    p_description, v_caller_id, NOW()
  ) RETURNING id INTO v_tx_id;

  RETURN jsonb_build_object(
    'success', true,
    'bank_transaction_id', v_tx_id,
    'bank_account_id', p_bank_account_id,
    'amount', p_amount,
    'direction', p_direction
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_post_bank_transaction(UUID, UUID, TEXT, TEXT, NUMERIC, TEXT, TEXT, UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_post_bank_transaction(UUID, UUID, TEXT, TEXT, NUMERIC, TEXT, TEXT, UUID, TEXT, TEXT) TO authenticated;

-- -----------------------------------------------------------------------------
-- 12.4 rpc_post_cash_transaction
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_post_cash_transaction(
  p_business_id UUID,
  p_branch_id UUID,
  p_register_id UUID,
  p_shift_id UUID,
  p_direction TEXT,
  p_amount NUMERIC,
  p_currency TEXT,
  p_source_type TEXT,
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
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  -- 1. Authorization
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(p_business_id, 'cash:manage', p_branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot execute cash adjustments for branch %',
      v_caller_id, p_branch_id;
  END IF;

  -- 2. Append to Immutable Cash Ledger
  INSERT INTO public.cash_transactions (
    business_id, branch_id, register_id, shift_id,
    direction, amount, currency, source_type, source_id,
    description, actor_user_id, occurred_at
  ) VALUES (
    p_business_id, p_branch_id, p_register_id, p_shift_id,
    p_direction, p_amount, p_currency, p_source_type, p_source_id,
    p_description, v_caller_id, NOW()
  ) RETURNING id INTO v_tx_id;

  RETURN jsonb_build_object(
    'success', true,
    'cash_transaction_id', v_tx_id,
    'amount', p_amount,
    'direction', p_direction
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_post_cash_transaction(UUID, UUID, UUID, UUID, TEXT, NUMERIC, TEXT, TEXT, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_post_cash_transaction(UUID, UUID, UUID, UUID, TEXT, NUMERIC, TEXT, TEXT, UUID, TEXT) TO authenticated;

-- -----------------------------------------------------------------------------
-- 12.5 rpc_record_payment
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_record_payment(
  p_business_id UUID,
  p_transaction_id UUID,
  p_payment_method TEXT,
  p_amount NUMERIC,
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
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT: Payment amount must be greater than zero';
  END IF;

  -- 1. Lock Sales Transaction row
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

  -- 1b. Validate Overpayment Prevention
  IF (v_trans.amount_paid + p_amount) > v_trans.total_amount THEN
    RAISE EXCEPTION 'OVERPAYMENT_NOT_ALLOWED: Payment amount % exceeds remaining balance %',
      p_amount, v_trans.balance_due;
  END IF;

  -- 1c. Validate Bank Account Tenancy if Bank Transfer
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

  -- 2. Authorization
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(p_business_id, 'payments:record', v_trans.branch_id)
    OR public.has_permission_in_scope(p_business_id, 'sales:create', v_trans.branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot record payments for branch %',
      v_caller_id, v_trans.branch_id;
  END IF;

  -- 3. Generate Payment Number
  v_pay_num := public.rpc_next_document_number(p_business_id, 'payment', 'PAY');

  -- 4. Record Payment
  INSERT INTO public.payments (
    business_id, branch_id, transaction_id, payment_number,
    payment_method, amount, currency, bank_account_id,
    register_id, shift_id, reference_number, status,
    received_by, occurred_at, metadata
  ) VALUES (
    p_business_id, v_trans.branch_id, p_transaction_id, v_pay_num,
    p_payment_method, p_amount, v_trans.currency, p_bank_account_id,
    COALESCE(p_register_id, v_trans.register_id),
    COALESCE(p_shift_id, v_trans.shift_id),
    p_reference_number, 'completed',
    v_caller_id, NOW(),
    CASE WHEN p_notes IS NOT NULL THEN jsonb_build_object('notes', p_notes) ELSE '{}'::jsonb END
  ) RETURNING id INTO v_pay_id;

  -- Note: Trigger trg_payments_sync_balance automatically updates transaction balance & status.

  -- 5. Treasury Integration: Cash Movement
  IF p_payment_method = 'cash' THEN
    INSERT INTO public.cash_transactions (
      business_id, branch_id, register_id, shift_id,
      direction, amount, currency, source_type, source_id,
      description, actor_user_id, occurred_at
    ) VALUES (
      p_business_id, v_trans.branch_id,
      COALESCE(p_register_id, v_trans.register_id),
      COALESCE(p_shift_id, v_trans.shift_id),
      'in', p_amount, v_trans.currency, 'cash_sale', v_pay_id,
      'Cash tender for transaction ' || v_trans.transaction_number, v_caller_id, NOW()
    );
  END IF;

  -- 6. Treasury Integration: Bank Movement (Direct Bank Transfer / Settled Deposit)
  IF p_payment_method = 'bank_transfer' AND p_bank_account_id IS NOT NULL THEN
    INSERT INTO public.bank_transactions (
      business_id, bank_account_id, transaction_type, direction,
      amount, currency, source_type, source_id, reference_number,
      description, actor_user_id, occurred_at
    ) VALUES (
      p_business_id, p_bank_account_id, 'payment_settlement', 'credit',
      p_amount, v_trans.currency, 'payment', v_pay_id, p_reference_number,
      'Bank payment settlement for ' || v_trans.transaction_number, v_caller_id, NOW()
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'payment_id', v_pay_id,
    'payment_number', v_pay_num,
    'transaction_id', p_transaction_id,
    'amount', p_amount,
    'payment_method', p_payment_method
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_record_payment(UUID, UUID, TEXT, NUMERIC, UUID, UUID, UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_record_payment(UUID, UUID, TEXT, NUMERIC, UUID, UUID, UUID, TEXT, TEXT) TO authenticated;

-- -----------------------------------------------------------------------------
-- 12.6 rpc_pay_expense
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_pay_expense(
  p_business_id UUID,
  p_expense_id UUID,
  p_payment_method TEXT,
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
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  -- 1. Lock Expense row
  SELECT * INTO v_exp
  FROM public.expenses
  WHERE id = p_expense_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EXPENSE_NOT_FOUND: Expense % not found in business %', p_expense_id, p_business_id;
  END IF;

  IF v_exp.status <> 'approved' THEN
    RAISE EXCEPTION 'INVALID_STATUS: Expense % has status %; only approved expenses can be paid',
      p_expense_id, v_exp.status;
  END IF;

  -- 2. Authorization
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'expenses:pay')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % cannot pay expenses for business %',
      v_caller_id, p_business_id;
  END IF;

  -- 3. Validate Treasury Target
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

  -- 4. Mark Expense as Paid
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

  -- 5. Post to Cash Ledger if paid in cash
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

  -- 6. Post to Bank Ledger if paid from bank
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

  RETURN jsonb_build_object(
    'success', true,
    'expense_id', p_expense_id,
    'expense_number', v_exp.expense_number,
    'amount', v_exp.amount,
    'status', 'paid'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_pay_expense(UUID, UUID, TEXT, UUID, UUID, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_pay_expense(UUID, UUID, TEXT, UUID, UUID, UUID, TEXT) TO authenticated;

-- =============================================================================
-- 13. ROW LEVEL SECURITY (RLS) POLICIES & ACCESS HARDENING
-- =============================================================================

ALTER TABLE public.document_sequences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.registers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.register_shifts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_transaction_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;

-- -----------------------------------------------------------------------------
-- 13.1 public.document_sequences
-- -----------------------------------------------------------------------------
CREATE POLICY "document_sequences_select" ON public.document_sequences
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'sales:view')
);

-- -----------------------------------------------------------------------------
-- 13.2 public.registers
-- -----------------------------------------------------------------------------
CREATE POLICY "registers_select" ON public.registers
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'registers:view')
  OR public.has_permission(business_id, 'sales:create')
);

CREATE POLICY "registers_insert" ON public.registers
FOR INSERT TO authenticated
WITH CHECK (
  public.is_business_owner(business_id)
  OR public.has_permission_in_scope(business_id, 'registers:manage', branch_id)
);

CREATE POLICY "registers_update" ON public.registers
FOR UPDATE TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission_in_scope(business_id, 'registers:manage', branch_id)
);

CREATE POLICY "registers_delete" ON public.registers
FOR DELETE TO authenticated
USING (false);

-- -----------------------------------------------------------------------------
-- 13.3 public.register_shifts
-- -----------------------------------------------------------------------------
CREATE POLICY "register_shifts_select" ON public.register_shifts
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR opened_by = auth.uid()
  OR public.has_permission_in_scope(business_id, 'registers:view', branch_id)
);

CREATE POLICY "register_shifts_insert" ON public.register_shifts
FOR INSERT TO authenticated
WITH CHECK (
  public.is_business_owner(business_id)
  OR public.has_permission_in_scope(business_id, 'registers:manage', branch_id)
  OR public.has_permission_in_scope(business_id, 'sales:create', branch_id)
);

CREATE POLICY "register_shifts_update" ON public.register_shifts
FOR UPDATE TO authenticated
USING (
  public.is_business_owner(business_id)
  OR opened_by = auth.uid()
  OR public.has_permission_in_scope(business_id, 'registers:manage', branch_id)
);

CREATE POLICY "register_shifts_delete" ON public.register_shifts
FOR DELETE TO authenticated
USING (false);

-- -----------------------------------------------------------------------------
-- 13.4 public.customers
-- -----------------------------------------------------------------------------
CREATE POLICY "customers_select" ON public.customers
FOR SELECT TO authenticated
USING (
  (deleted_at IS NULL OR public.is_business_owner(business_id))
  AND (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'customers:view')
    OR public.has_permission(business_id, 'sales:create')
  )
);

CREATE POLICY "customers_insert" ON public.customers
FOR INSERT TO authenticated
WITH CHECK (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'customers:manage')
  OR public.has_permission(business_id, 'sales:create')
);

CREATE POLICY "customers_update" ON public.customers
FOR UPDATE TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'customers:manage')
);

CREATE POLICY "customers_delete" ON public.customers
FOR DELETE TO authenticated
USING (false);

-- -----------------------------------------------------------------------------
-- 13.5 public.sales_transactions
-- -----------------------------------------------------------------------------
CREATE POLICY "sales_trans_select" ON public.sales_transactions
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission_in_scope(business_id, 'sales:view', branch_id)
  OR cashier_user_id = auth.uid()
);

CREATE POLICY "sales_trans_insert" ON public.sales_transactions
FOR INSERT TO authenticated
WITH CHECK (
  cashier_user_id = auth.uid()
  AND (
    public.is_business_owner(business_id)
    OR public.has_permission_in_scope(business_id, 'sales:create', branch_id)
  )
);

CREATE POLICY "sales_trans_update" ON public.sales_transactions
FOR UPDATE TO authenticated
USING (
  public.is_business_owner(business_id)
  OR (status IN ('draft', 'pending_payment') AND public.has_permission_in_scope(business_id, 'sales:create', branch_id))
  OR public.has_permission_in_scope(business_id, 'sales:void', branch_id)
);

CREATE POLICY "sales_trans_delete" ON public.sales_transactions
FOR DELETE TO authenticated
USING (false);

-- -----------------------------------------------------------------------------
-- 13.6 public.sales_transaction_items
-- -----------------------------------------------------------------------------
CREATE POLICY "sales_trans_items_select" ON public.sales_transaction_items
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'sales:view')
);

CREATE POLICY "sales_trans_items_insert" ON public.sales_transaction_items
FOR INSERT TO authenticated
WITH CHECK (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'sales:create')
);

CREATE POLICY "sales_trans_items_update" ON public.sales_transaction_items
FOR UPDATE TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'sales:create')
);

CREATE POLICY "sales_trans_items_delete" ON public.sales_transaction_items
FOR DELETE TO authenticated
USING (false);

-- -----------------------------------------------------------------------------
-- 13.7 public.bank_accounts
-- -----------------------------------------------------------------------------
CREATE POLICY "bank_accounts_select" ON public.bank_accounts
FOR SELECT TO authenticated
USING (
  deleted_at IS NULL
  AND (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'bank:view')
  )
);

CREATE POLICY "bank_accounts_insert" ON public.bank_accounts
FOR INSERT TO authenticated
WITH CHECK (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'bank:manage')
);

CREATE POLICY "bank_accounts_update" ON public.bank_accounts
FOR UPDATE TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'bank:manage')
);

CREATE POLICY "bank_accounts_delete" ON public.bank_accounts
FOR DELETE TO authenticated
USING (false);

-- -----------------------------------------------------------------------------
-- 13.8 public.bank_transactions (Authoritative Immutable Ledger)
-- -----------------------------------------------------------------------------
CREATE POLICY "bank_transactions_select" ON public.bank_transactions
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'bank:view')
);

CREATE POLICY "bank_transactions_insert" ON public.bank_transactions
FOR INSERT TO authenticated
WITH CHECK (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'bank:manage')
);

CREATE POLICY "bank_transactions_update" ON public.bank_transactions
FOR UPDATE TO authenticated
USING (false);

CREATE POLICY "bank_transactions_delete" ON public.bank_transactions
FOR DELETE TO authenticated
USING (false);

-- -----------------------------------------------------------------------------
-- 13.9 public.cash_transactions (Authoritative Immutable Ledger)
-- -----------------------------------------------------------------------------
CREATE POLICY "cash_transactions_select" ON public.cash_transactions
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission_in_scope(business_id, 'cash:view', branch_id)
);

CREATE POLICY "cash_transactions_insert" ON public.cash_transactions
FOR INSERT TO authenticated
WITH CHECK (
  public.is_business_owner(business_id)
  OR public.has_permission_in_scope(business_id, 'cash:manage', branch_id)
);

CREATE POLICY "cash_transactions_update" ON public.cash_transactions
FOR UPDATE TO authenticated
USING (false);

CREATE POLICY "cash_transactions_delete" ON public.cash_transactions
FOR DELETE TO authenticated
USING (false);

-- -----------------------------------------------------------------------------
-- 13.10 public.payments
-- -----------------------------------------------------------------------------
CREATE POLICY "payments_select" ON public.payments
FOR SELECT TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission_in_scope(business_id, 'payments:view', branch_id)
  OR received_by = auth.uid()
);

CREATE POLICY "payments_insert" ON public.payments
FOR INSERT TO authenticated
WITH CHECK (
  public.is_business_owner(business_id)
  OR public.has_permission_in_scope(business_id, 'payments:record', branch_id)
  OR public.has_permission_in_scope(business_id, 'sales:create', branch_id)
);

CREATE POLICY "payments_update" ON public.payments
FOR UPDATE TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'sales:refund')
);

CREATE POLICY "payments_delete" ON public.payments
FOR DELETE TO authenticated
USING (false);

-- -----------------------------------------------------------------------------
-- 13.11 public.expense_categories
-- -----------------------------------------------------------------------------
CREATE POLICY "expense_categories_select" ON public.expense_categories
FOR SELECT TO authenticated
USING (
  deleted_at IS NULL
  AND (
    public.is_business_owner(business_id)
    OR public.has_permission(business_id, 'expenses:view')
    OR public.has_permission(business_id, 'expenses:create')
  )
);

CREATE POLICY "expense_categories_insert" ON public.expense_categories
FOR INSERT TO authenticated
WITH CHECK (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'expenses:create')
);

CREATE POLICY "expense_categories_update" ON public.expense_categories
FOR UPDATE TO authenticated
USING (
  public.is_business_owner(business_id)
  OR public.has_permission(business_id, 'expenses:create')
);

CREATE POLICY "expense_categories_delete" ON public.expense_categories
FOR DELETE TO authenticated
USING (false);

-- -----------------------------------------------------------------------------
-- 13.12 public.expenses
-- -----------------------------------------------------------------------------
CREATE POLICY "expenses_select" ON public.expenses
FOR SELECT TO authenticated
USING (
  deleted_at IS NULL
  AND (
    public.is_business_owner(business_id)
    OR created_by = auth.uid()
    OR public.has_permission_in_scope(business_id, 'expenses:view', branch_id)
  )
);

CREATE POLICY "expenses_insert" ON public.expenses
FOR INSERT TO authenticated
WITH CHECK (
  created_by = auth.uid()
  AND (
    public.is_business_owner(business_id)
    OR public.has_permission_in_scope(business_id, 'expenses:create', branch_id)
  )
);

CREATE POLICY "expenses_update" ON public.expenses
FOR UPDATE TO authenticated
USING (
  deleted_at IS NULL
  AND (
    public.is_business_owner(business_id)
    OR (status = 'draft' AND created_by = auth.uid())
    OR public.has_permission(business_id, 'expenses:approve')
    OR public.has_permission(business_id, 'expenses:pay')
  )
);

CREATE POLICY "expenses_delete" ON public.expenses
FOR DELETE TO authenticated
USING (false);

-- =============================================================================
-- 14. TABLE PRIVILEGE HARDENING & REVOCATIONS
-- =============================================================================

-- Deny all access to unauthenticated public and anon roles
REVOKE ALL ON public.document_sequences FROM PUBLIC, anon;
REVOKE ALL ON public.registers FROM PUBLIC, anon;
REVOKE ALL ON public.register_shifts FROM PUBLIC, anon;
REVOKE ALL ON public.customers FROM PUBLIC, anon;
REVOKE ALL ON public.sales_transactions FROM PUBLIC, anon;
REVOKE ALL ON public.sales_transaction_items FROM PUBLIC, anon;
REVOKE ALL ON public.bank_accounts FROM PUBLIC, anon;
REVOKE ALL ON public.bank_transactions FROM PUBLIC, anon;
REVOKE ALL ON public.cash_transactions FROM PUBLIC, anon;
REVOKE ALL ON public.payments FROM PUBLIC, anon;
REVOKE ALL ON public.expense_categories FROM PUBLIC, anon;
REVOKE ALL ON public.expenses FROM PUBLIC, anon;

-- Explicitly revoke direct client mutation on immutable ledgers
REVOKE INSERT, UPDATE, DELETE ON public.bank_transactions FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.cash_transactions FROM authenticated;
REVOKE DELETE ON public.sales_transactions FROM authenticated;
REVOKE DELETE ON public.sales_transaction_items FROM authenticated;
REVOKE UPDATE, DELETE ON public.payments FROM authenticated;
REVOKE DELETE ON public.register_shifts FROM authenticated;
REVOKE DELETE ON public.registers FROM authenticated;
REVOKE DELETE ON public.customers FROM authenticated;
REVOKE DELETE ON public.bank_accounts FROM authenticated;
REVOKE DELETE ON public.expenses FROM authenticated;
REVOKE DELETE ON public.expense_categories FROM authenticated;

-- Grant standard DML for operational tables under RLS
GRANT SELECT, INSERT, UPDATE ON public.registers TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.register_shifts TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.customers TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.sales_transactions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.sales_transaction_items TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.bank_accounts TO authenticated;
GRANT SELECT ON public.bank_transactions TO authenticated;
GRANT SELECT ON public.cash_transactions TO authenticated;
GRANT SELECT, INSERT ON public.payments TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.expense_categories TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.expenses TO authenticated;
GRANT SELECT ON public.document_sequences TO authenticated;
