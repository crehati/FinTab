-- ============================================================================
-- FinTab Enterprise OS — Phase 1 Seed Data for Testing
-- Date: 2026-08-06
-- Purpose: Seeds test accounts, sample business, main branch, memberships,
--          pending invitation, and initial capital contributions.
-- ============================================================================

-- 1. SEED TEST USER PROFILES
-- Note: Replace these UUIDs or let Auth trigger create profiles upon sign-up during runtime UAT.
INSERT INTO public.user_profiles (id, email, full_name, phone, status)
VALUES 
    ('00000000-0000-0000-0000-000000000001', 'owner@fintab.app', 'Jean-Luc Dessalines (Owner)', '+509 3700 1111', 'active'),
    ('00000000-0000-0000-0000-000000000002', 'manager@fintab.app', 'Marie-Claire Heurtelou (Manager)', '+509 3700 2222', 'active'),
    ('00000000-0000-0000-0000-000000000003', 'investor@fintab.app', 'Alexandre Pétion (Investor)', '+509 3700 3333', 'active')
ON CONFLICT (id) DO UPDATE SET
    full_name = EXCLUDED.full_name,
    email = EXCLUDED.email;

-- 2. SEED SAMPLE TEST BUSINESS
INSERT INTO public.businesses (id, legal_name, trade_name, tax_id, currency, timezone, status, owner_id)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    'FinTab Enterprise Test Co.',
    'FinTab Commerce',
    'HT-99887766-5',
    'USD',
    'America/Port-au-Prince',
    'active',
    '00000000-0000-0000-0000-000000000001'
)
ON CONFLICT (id) DO NOTHING;

-- Set Default Business for Owner
UPDATE public.user_profiles
SET default_business_id = '11111111-1111-1111-1111-111111111111'
WHERE id = '00000000-0000-0000-0000-000000000001';

-- 3. SEED MAIN BRANCH
INSERT INTO public.branches (id, business_id, name, code, is_main, status)
VALUES (
    '22222222-2222-2222-2222-222222222222',
    '11111111-1111-1111-1111-111111111111',
    'Port-au-Prince HQ',
    'PAP-HQ-01',
    true,
    'active'
)
ON CONFLICT (id) DO NOTHING;

-- 4. SEED BUSINESS MEMBERSHIPS
INSERT INTO public.business_memberships (business_id, user_id, role, status)
VALUES 
    ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000001', 'Owner', 'active'),
    ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000002', 'Manager', 'active'),
    ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000003', 'Investor', 'active')
ON CONFLICT (business_id, user_id) DO UPDATE SET role = EXCLUDED.role;

-- 5. SEED PENDING INVITATION
INSERT INTO public.business_invitations (
    business_id, email, role, token, invited_by, status
)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    'cashier.test@fintab.app',
    'Cashier',
    'test-invitation-token-12345',
    '00000000-0000-0000-0000-000000000001',
    'pending'
)
ON CONFLICT (token) DO NOTHING;

-- 6. SEED INITIAL OWNER CAPITAL INVESTMENT & ADDITIONAL INVESTOR CONTRIBUTION
-- Initial Owner Capital Contribution: $10,000 USD
INSERT INTO public.investor_investments (
    business_id, investor_user_id, amount, currency, investment_type, notes, created_by
)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    '00000000-0000-0000-0000-000000000001',
    10000.00,
    'USD',
    'initial_owner_capital',
    'Initial owner founding equity contribution',
    '00000000-0000-0000-0000-000000000001'
);

-- External Investor Contribution: $2,500 USD (Calculates to 20% ownership dynamically)
INSERT INTO public.investor_investments (
    business_id, investor_user_id, amount, currency, investment_type, notes, created_by
)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    '00000000-0000-0000-0000-000000000003',
    2500.00,
    'USD',
    'additional_equity',
    'Angel investor initial capital contribution',
    '00000000-0000-0000-0000-000000000001'
);
