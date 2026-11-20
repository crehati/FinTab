-- ============================================================================
-- FinTab Enterprise OS — Phase 4 Supabase Migration
-- Module: Enterprise Commercial Engine
-- Tables:
--   1. registers (POS Registers & Training Registers)
--   2. register_shifts (Register Shifts, Opening/Closing Cash, Cash Variance)
--   3. customers (Customer CRM, Individuals & Businesses, Credit Limits, Loyalty)
--   4. customer_documents (Customer Notes, Documents, Communication Log)
--   5. price_lists (Retail, Wholesale, VIP, Restaurant, Delivery, Online, Employee)
--   6. price_list_items (Product-level prices per price list)
--   7. customer_price_agreements (Contract prices per customer)
--   8. promotions (Promotions & Promotional Discounts)
--   9. sales_transactions (Header for Sales, Quotes, Proformas, Invoices, Returns, Voids)
--  10. sales_transaction_items (Line items with Batch/Serial/Cost tracking)
--  11. payments (Split Payment processing across Cash, Cards, MonCash, NatCash, etc.)
--  12. manager_approvals (Audit log for PIN/Manager Overrides)
--  13. commercial_audit_logs (Commercial action audit trail)
-- Date: 2026-08-06
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ----------------------------------------------------------------------------
-- 1. REGISTERS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.registers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    branch_id UUID REFERENCES public.inventory_locations(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    code TEXT NOT NULL,
    is_training_mode BOOLEAN NOT NULL DEFAULT false,
    status TEXT NOT NULL DEFAULT 'closed' CHECK (status IN ('open', 'closed', 'maintenance')),
    assigned_cashier_id UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_registers_updated_at
    BEFORE UPDATE ON public.registers
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 2. REGISTER SHIFTS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.register_shifts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    register_id UUID NOT NULL REFERENCES public.registers(id) ON DELETE CASCADE,
    cashier_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
    opened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at TIMESTAMPTZ,
    opening_cash NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    closing_cash NUMERIC(15, 4) DEFAULT NULL,
    expected_cash NUMERIC(15, 4) DEFAULT NULL,
    actual_cash NUMERIC(15, 4) DEFAULT NULL,
    cash_variance NUMERIC(15, 4) DEFAULT NULL,
    variance_reason TEXT,
    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'reopened')),
    approved_by UUID REFERENCES public.user_profiles(id),
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_register_shifts_updated_at
    BEFORE UPDATE ON public.register_shifts
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 3. CUSTOMERS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.customers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    customer_type TEXT NOT NULL DEFAULT 'individual' CHECK (customer_type IN ('individual', 'business')),
    company_name TEXT,
    first_name TEXT,
    last_name TEXT,
    email TEXT,
    primary_phone TEXT,
    secondary_phone TEXT,
    whatsapp_number TEXT,
    tax_id TEXT,
    price_list_id UUID,
    customer_group TEXT DEFAULT 'standard',
    addresses JSONB NOT NULL DEFAULT '[]'::jsonb,
    tags JSONB NOT NULL DEFAULT '[]'::jsonb,
    loyalty_points NUMERIC(15, 2) NOT NULL DEFAULT 0.00,
    credit_limit NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    outstanding_balance NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    is_active BOOLEAN NOT NULL DEFAULT true,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_customers_updated_at
    BEFORE UPDATE ON public.customers
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 4. CUSTOMER DOCUMENTS & COMMUNICATIONS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.customer_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK (type IN ('note', 'document', 'communication')),
    title TEXT NOT NULL,
    content TEXT,
    channel TEXT CHECK (channel IN ('whatsapp', 'email', 'sms', 'in_person', 'phone')),
    file_url TEXT,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_customer_documents_updated_at
    BEFORE UPDATE ON public.customer_documents
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 5. PRICE LISTS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.price_lists (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    code TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('retail', 'wholesale', 'vip', 'restaurant', 'delivery', 'online', 'employee', 'promotional', 'contract')),
    currency TEXT NOT NULL DEFAULT 'HTG',
    is_default BOOLEAN NOT NULL DEFAULT false,
    priority INT NOT NULL DEFAULT 10,
    valid_from TIMESTAMPTZ,
    valid_to TIMESTAMPTZ,
    is_active BOOLEAN NOT NULL DEFAULT true,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_price_lists_updated_at
    BEFORE UPDATE ON public.price_lists
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 6. PRICE LIST ITEMS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.price_list_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    price_list_id UUID NOT NULL REFERENCES public.price_lists(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    price NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    min_quantity NUMERIC(15, 4) NOT NULL DEFAULT 1.0000,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_price_list_items_updated_at
    BEFORE UPDATE ON public.price_list_items
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 7. CUSTOMER PRICE AGREEMENTS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.customer_price_agreements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    contract_price NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    valid_from TIMESTAMPTZ,
    valid_to TIMESTAMPTZ,
    is_active BOOLEAN NOT NULL DEFAULT true,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_customer_price_agreements_updated_at
    BEFORE UPDATE ON public.customer_price_agreements
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 8. PROMOTIONS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.promotions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    code TEXT,
    discount_type TEXT NOT NULL CHECK (discount_type IN ('percentage', 'fixed_amount')),
    discount_value NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    applies_to TEXT NOT NULL DEFAULT 'all' CHECK (applies_to IN ('all', 'product', 'category')),
    product_id UUID REFERENCES public.products(id) ON DELETE CASCADE,
    category_id UUID REFERENCES public.product_categories(id) ON DELETE CASCADE,
    min_spend NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    start_date TIMESTAMPTZ,
    end_date TIMESTAMPTZ,
    is_active BOOLEAN NOT NULL DEFAULT true,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_promotions_updated_at
    BEFORE UPDATE ON public.promotions
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 9. SALES TRANSACTIONS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sales_transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    register_id UUID REFERENCES public.registers(id) ON DELETE SET NULL,
    shift_id UUID REFERENCES public.register_shifts(id) ON DELETE SET NULL,
    cashier_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
    customer_id UUID REFERENCES public.customers(id) ON DELETE SET NULL,
    location_id UUID REFERENCES public.inventory_locations(id) ON DELETE RESTRICT,
    transaction_type TEXT NOT NULL CHECK (transaction_type IN ('sale', 'quote', 'proforma', 'invoice', 'delivery_note', 'return', 'refund', 'exchange', 'void', 'credit_sale')),
    transaction_number TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'completed' CHECK (status IN ('draft', 'held', 'completed', 'cancelled', 'voided', 'refunded')),
    is_training_mode BOOLEAN NOT NULL DEFAULT false,
    currency TEXT NOT NULL DEFAULT 'HTG',
    subtotal NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    discount_amount NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    tax_amount NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    total_amount NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    paid_amount NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    balance_due NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    manager_approved_by UUID REFERENCES public.user_profiles(id),
    notes TEXT,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_sales_transactions_updated_at
    BEFORE UPDATE ON public.sales_transactions
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 10. SALES TRANSACTION ITEMS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sales_transaction_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    transaction_id UUID NOT NULL REFERENCES public.sales_transactions(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
    batch_id UUID REFERENCES public.inventory_batches(id) ON DELETE SET NULL,
    serial_number_id UUID REFERENCES public.serial_numbers(id) ON DELETE SET NULL,
    quantity NUMERIC(15, 4) NOT NULL DEFAULT 1.0000,
    unit_price NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    cost_price NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    discount_amount NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    tax_amount NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    subtotal NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    total NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    pricing_source TEXT DEFAULT 'default',
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_sales_transaction_items_updated_at
    BEFORE UPDATE ON public.sales_transaction_items
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 11. PAYMENTS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    transaction_id UUID NOT NULL REFERENCES public.sales_transactions(id) ON DELETE CASCADE,
    payment_method TEXT NOT NULL CHECK (payment_method IN ('cash', 'debit_card', 'credit_card', 'bank_transfer', 'moncash', 'natcash', 'stripe', 'paypal', 'gift_card', 'store_credit')),
    amount NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    status TEXT NOT NULL DEFAULT 'completed' CHECK (status IN ('pending', 'completed', 'failed', 'refunded')),
    reference_number TEXT,
    treasury_account_id UUID,
    notes TEXT,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_payments_updated_at
    BEFORE UPDATE ON public.payments
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 12. MANAGER APPROVALS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.manager_approvals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    action_type TEXT NOT NULL CHECK (action_type IN ('price_override', 'discount_override', 'refund', 'return', 'void_sale', 'register_reopen', 'credit_sale', 'cash_variance_approval')),
    manager_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
    cashier_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
    reference_type TEXT,
    reference_id UUID,
    reason TEXT NOT NULL,
    approved_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

-- ----------------------------------------------------------------------------
-- 13. COMMERCIAL AUDIT LOGS
-- ----------------------------------------------------------------------------
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

-- ============================================================================
-- INDEXES FOR TENANT ISOLATION & OPTIMIZED COMMERCIAL LOOKUPS
-- ============================================================================

CREATE INDEX idx_registers_biz ON public.registers(business_id, deleted_at);
CREATE INDEX idx_register_shifts_biz ON public.register_shifts(business_id, register_id, status);
CREATE INDEX idx_customers_biz ON public.customers(business_id, deleted_at);
CREATE INDEX idx_customer_docs_biz ON public.customer_documents(business_id, customer_id);
CREATE INDEX idx_price_lists_biz ON public.price_lists(business_id, deleted_at);
CREATE INDEX idx_price_items_list ON public.price_list_items(price_list_id, product_id);
CREATE INDEX idx_sales_trans_biz ON public.sales_transactions(business_id, transaction_type, status);
CREATE INDEX idx_sales_trans_num ON public.sales_transactions(business_id, transaction_number);
CREATE INDEX idx_sales_trans_cust ON public.sales_transactions(customer_id);
CREATE INDEX idx_sales_items_trans ON public.sales_transaction_items(transaction_id);
CREATE INDEX idx_payments_trans ON public.payments(transaction_id);
CREATE INDEX idx_manager_approvals_biz ON public.manager_approvals(business_id, action_type);
CREATE INDEX idx_commercial_audit_biz ON public.commercial_audit_logs(business_id, action);

-- ============================================================================
-- SUPABASE ROW LEVEL SECURITY (RLS) POLICIES
-- ============================================================================

DO $$
DECLARE
    tbl text;
    tables text[] := ARRAY[
        'registers',
        'register_shifts',
        'customers',
        'customer_documents',
        'price_lists',
        'price_list_items',
        'customer_price_agreements',
        'promotions',
        'sales_transactions',
        'sales_transaction_items',
        'payments',
        'manager_approvals',
        'commercial_audit_logs'
    ];
BEGIN
    FOREACH tbl IN ARRAY tables LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', tbl);
        
        EXECUTE format('
            CREATE POLICY %I_tenant_isolation ON public.%I
                FOR ALL
                USING (
                    business_id IN (
                        SELECT business_id FROM public.business_memberships
                        WHERE user_id = auth.uid() AND status = ''active''
                    )
                )
                WITH CHECK (
                    business_id IN (
                        SELECT business_id FROM public.business_memberships
                        WHERE user_id = auth.uid() AND status = ''active''
                    )
                );
        ', tbl, tbl);
    END LOOP;
END $$;
