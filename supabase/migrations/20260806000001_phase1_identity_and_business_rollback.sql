-- ============================================================================
-- FinTab Enterprise OS — Phase 1 Rollback Script
-- Module: Identity, User Profiles, Businesses, Branches, Memberships,
--         Invitations, and Investor Investment Ledger Rollback.
-- Date: 2026-08-06
-- ============================================================================

BEGIN;

-- 1. DROP TRIGGERS
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
DROP TRIGGER IF EXISTS trg_investor_investments_updated_at ON public.investor_investments;
DROP TRIGGER IF EXISTS trg_business_invitations_updated_at ON public.business_invitations;
DROP TRIGGER IF EXISTS trg_business_memberships_updated_at ON public.business_memberships;
DROP TRIGGER IF EXISTS trg_branches_updated_at ON public.branches;
DROP TRIGGER IF EXISTS trg_businesses_updated_at ON public.businesses;
DROP TRIGGER IF EXISTS trg_user_profiles_updated_at ON public.user_profiles;

-- 2. DROP VIEWS & FUNCTIONS
DROP VIEW IF EXISTS public.v_investor_ownership_summary CASCADE;
DROP FUNCTION IF EXISTS public.handle_new_user() CASCADE;
DROP FUNCTION IF EXISTS public.create_business_with_owner_investment(TEXT, TEXT, TEXT, TEXT, NUMERIC, UUID) CASCADE;
DROP FUNCTION IF EXISTS public.get_investor_total_investment(UUID, UUID) CASCADE;
DROP FUNCTION IF EXISTS public.get_business_total_capital(UUID) CASCADE;
DROP FUNCTION IF EXISTS public.is_business_owner(UUID, UUID) CASCADE;
DROP FUNCTION IF EXISTS public.is_business_member(UUID, UUID) CASCADE;
DROP FUNCTION IF EXISTS public.trigger_set_updated_at() CASCADE;

-- 3. REMOVE CONSTRAINTS & TABLES IN REVERSE DEPENDENCY ORDER
ALTER TABLE IF EXISTS public.user_profiles DROP CONSTRAINT IF EXISTS fk_user_profiles_default_business;

DROP TABLE IF EXISTS public.investor_investments CASCADE;
DROP TABLE IF EXISTS public.business_invitations CASCADE;
DROP TABLE IF EXISTS public.business_memberships CASCADE;
DROP TABLE IF EXISTS public.branches CASCADE;
DROP TABLE IF EXISTS public.businesses CASCADE;
DROP TABLE IF EXISTS public.user_profiles CASCADE;

COMMIT;
