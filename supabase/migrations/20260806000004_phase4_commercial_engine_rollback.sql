-- ============================================================================
-- FinTab Enterprise OS — Phase 4 Rollback Migration
-- Module: Enterprise Commercial Engine Rollback
-- ============================================================================

DROP TABLE IF EXISTS public.commercial_audit_logs CASCADE;
DROP TABLE IF EXISTS public.manager_approvals CASCADE;
DROP TABLE IF EXISTS public.payments CASCADE;
DROP TABLE IF EXISTS public.sales_transaction_items CASCADE;
DROP TABLE IF EXISTS public.sales_transactions CASCADE;
DROP TABLE IF EXISTS public.promotions CASCADE;
DROP TABLE IF EXISTS public.customer_price_agreements CASCADE;
DROP TABLE IF EXISTS public.price_list_items CASCADE;
DROP TABLE IF EXISTS public.price_lists CASCADE;
DROP TABLE IF EXISTS public.customer_documents CASCADE;
DROP TABLE IF EXISTS public.customers CASCADE;
DROP TABLE IF EXISTS public.register_shifts CASCADE;
DROP TABLE IF EXISTS public.registers CASCADE;
