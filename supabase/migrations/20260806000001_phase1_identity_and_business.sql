-- ============================================================================
-- FinTab Enterprise OS — Phase 1 Supabase Migration
-- Module: Identity, User Profiles, Businesses, Branches, Memberships,
--         Invitations, and Initial Owner Investment Ledger.
-- Date: 2026-08-06
-- ============================================================================

-- 1. EXTENSIONS & BASE SETUP
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Function to handle updated_at timestamps automatically
CREATE OR REPLACE FUNCTION public.trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. USER PROFILES TABLE (Linked directly to auth.users)
CREATE TABLE IF NOT EXISTS public.user_profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT NOT NULL UNIQUE,
    full_name TEXT NOT NULL,
    phone TEXT,
    avatar_url TEXT,
    default_business_id UUID,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'deactivated')),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Trigger for user_profiles updated_at
CREATE TRIGGER trg_user_profiles_updated_at
    BEFORE UPDATE ON public.user_profiles
    FOR EACH ROW
    EXECUTE FUNCTION public.trigger_set_updated_at();

-- 3. BUSINESSES TABLE
CREATE TABLE IF NOT EXISTS public.businesses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legal_name TEXT NOT NULL,
    trade_name TEXT,
    tax_id TEXT,
    currency TEXT NOT NULL DEFAULT 'USD',
    timezone TEXT NOT NULL DEFAULT 'UTC',
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'archived')),
    owner_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
    logo_url TEXT,
    settings JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Foreign Key from user_profiles to businesses for default_business_id
ALTER TABLE public.user_profiles 
    DROP CONSTRAINT IF EXISTS fk_user_profiles_default_business;

ALTER TABLE public.user_profiles 
    ADD CONSTRAINT fk_user_profiles_default_business 
    FOREIGN KEY (default_business_id) REFERENCES public.businesses(id) ON DELETE SET NULL;

-- Trigger for businesses updated_at
CREATE TRIGGER trg_businesses_updated_at
    BEFORE UPDATE ON public.businesses
    FOR EACH ROW
    EXECUTE FUNCTION public.trigger_set_updated_at();

-- 4. BRANCHES TABLE
CREATE TABLE IF NOT EXISTS public.branches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    code TEXT,
    address TEXT,
    phone TEXT,
    is_main BOOLEAN NOT NULL DEFAULT false,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Trigger for branches updated_at
CREATE TRIGGER trg_branches_updated_at
    BEFORE UPDATE ON public.branches
    FOR EACH ROW
    EXECUTE FUNCTION public.trigger_set_updated_at();

-- 5. BUSINESS MEMBERSHIPS TABLE
CREATE TABLE IF NOT EXISTS public.business_memberships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('Owner', 'Admin', 'Manager', 'Cashier', 'StockManager', 'Employee', 'Investor')),
    assigned_branch_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'revoked')),
    invited_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_business_membership UNIQUE (business_id, user_id)
);

-- Trigger for business_memberships updated_at
CREATE TRIGGER trg_business_memberships_updated_at
    BEFORE UPDATE ON public.business_memberships
    FOR EACH ROW
    EXECUTE FUNCTION public.trigger_set_updated_at();

-- 6. BUSINESS INVITATIONS TABLE
CREATE TABLE IF NOT EXISTS public.business_invitations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('Owner', 'Admin', 'Manager', 'Cashier', 'StockManager', 'Employee', 'Investor')),
    assigned_branch_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
    token TEXT NOT NULL UNIQUE DEFAULT gen_random_uuid()::text,
    invited_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined', 'expired', 'cancelled')),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '7 days'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Trigger for business_invitations updated_at
CREATE TRIGGER trg_business_invitations_updated_at
    BEFORE UPDATE ON public.business_invitations
    FOR EACH ROW
    EXECUTE FUNCTION public.trigger_set_updated_at();

-- 7. INVESTOR INVESTMENTS TABLE (Immutable Capital Contribution Ledger)
CREATE TABLE IF NOT EXISTS public.investor_investments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    investor_user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
    amount NUMERIC(15,2) NOT NULL CHECK (amount > 0),
    currency TEXT NOT NULL DEFAULT 'USD',
    investment_type TEXT NOT NULL CHECK (investment_type IN ('initial_owner_capital', 'additional_equity', 'convertible_note', 'debt_capital')),
    notes TEXT,
    effective_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 8. INDEXES FOR PERFORMANCE & FAST LOOKUPS
CREATE INDEX IF NOT EXISTS idx_user_profiles_email ON public.user_profiles(email);
CREATE INDEX IF NOT EXISTS idx_businesses_owner ON public.businesses(owner_id);
CREATE INDEX IF NOT EXISTS idx_branches_business ON public.branches(business_id);
CREATE INDEX IF NOT EXISTS idx_memberships_user ON public.business_memberships(user_id);
CREATE INDEX IF NOT EXISTS idx_memberships_business ON public.business_memberships(business_id);
CREATE INDEX IF NOT EXISTS idx_memberships_user_biz ON public.business_memberships(user_id, business_id);
CREATE INDEX IF NOT EXISTS idx_invitations_email ON public.business_invitations(email);
CREATE INDEX IF NOT EXISTS idx_invitations_token ON public.business_invitations(token);
CREATE INDEX IF NOT EXISTS idx_invitations_business ON public.business_invitations(business_id);
CREATE INDEX IF NOT EXISTS idx_investments_business ON public.investor_investments(business_id);
CREATE INDEX IF NOT EXISTS idx_investments_investor ON public.investor_investments(business_id, investor_user_id);

-- 9. SECURITY HELPER FUNCTIONS & BUSINESS LOGIC
CREATE OR REPLACE FUNCTION public.is_business_member(p_business_id UUID, p_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 
        FROM public.business_memberships 
        WHERE business_id = p_business_id 
          AND user_id = p_user_id 
          AND status = 'active'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.is_business_owner(p_business_id UUID, p_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 
        FROM public.businesses b
        LEFT JOIN public.business_memberships m ON b.id = m.business_id AND m.user_id = p_user_id
        WHERE b.id = p_business_id 
          AND (b.owner_id = p_user_id OR (m.role = 'Owner' AND m.status = 'active'))
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.get_business_total_capital(p_business_id UUID)
RETURNS NUMERIC AS $$
DECLARE
    v_total NUMERIC;
BEGIN
    SELECT COALESCE(SUM(amount), 0)
    INTO v_total
    FROM public.investor_investments
    WHERE business_id = p_business_id;
    RETURN v_total;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.get_investor_total_investment(p_business_id UUID, p_investor_id UUID)
RETURNS NUMERIC AS $$
DECLARE
    v_total NUMERIC;
BEGIN
    SELECT COALESCE(SUM(amount), 0)
    INTO v_total
    FROM public.investor_investments
    WHERE business_id = p_business_id AND investor_user_id = p_investor_id;
    RETURN v_total;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- View for dynamic investor ownership percentages (Calculated on-the-fly)
CREATE OR REPLACE VIEW public.v_investor_ownership_summary AS
SELECT 
    i.business_id,
    i.investor_user_id,
    u.full_name AS investor_name,
    u.email AS investor_email,
    SUM(i.amount) AS total_invested,
    public.get_business_total_capital(i.business_id) AS total_business_capital,
    CASE 
        WHEN public.get_business_total_capital(i.business_id) > 0 THEN
            ROUND((SUM(i.amount) / public.get_business_total_capital(i.business_id)) * 100, 4)
        ELSE 0
    END AS ownership_percentage,
    COUNT(i.id) AS investment_count,
    MAX(i.effective_date) AS latest_investment_date
FROM public.investor_investments i
JOIN public.user_profiles u ON i.investor_user_id = u.id
GROUP BY i.business_id, i.investor_user_id, u.full_name, u.email;

-- Atomic helper procedure: Onboarding a new business with initial owner investment
CREATE OR REPLACE FUNCTION public.create_business_with_owner_investment(
    p_legal_name TEXT,
    p_trade_name TEXT,
    p_currency TEXT,
    p_timezone TEXT,
    p_initial_investment_amount NUMERIC,
    p_owner_id UUID DEFAULT auth.uid()
)
RETURNS JSONB AS $$
DECLARE
    v_business_id UUID;
    v_branch_id UUID;
    v_investment_id UUID;
    v_result JSONB;
BEGIN
    -- 1. Insert Business
    INSERT INTO public.businesses (legal_name, trade_name, currency, timezone, owner_id)
    VALUES (p_legal_name, COALESCE(p_trade_name, p_legal_name), COALESCE(p_currency, 'USD'), COALESCE(p_timezone, 'UTC'), p_owner_id)
    RETURNING id INTO v_business_id;

    -- 2. Insert Main Branch
    INSERT INTO public.branches (business_id, name, is_main)
    VALUES (v_business_id, 'Main Branch', true)
    RETURNING id INTO v_branch_id;

    -- 3. Insert Owner Membership
    INSERT INTO public.business_memberships (business_id, user_id, role, status)
    VALUES (v_business_id, p_owner_id, 'Owner', 'active');

    -- 4. Update user default_business_id if null
    UPDATE public.user_profiles
    SET default_business_id = v_business_id
    WHERE id = p_owner_id AND default_business_id IS NULL;

    -- 5. Insert Initial Owner Capital Contribution Ledger Entry
    IF p_initial_investment_amount > 0 THEN
        INSERT INTO public.investor_investments (
            business_id,
            investor_user_id,
            amount,
            currency,
            investment_type,
            notes,
            created_by
        ) VALUES (
            v_business_id,
            p_owner_id,
            p_initial_investment_amount,
            COALESCE(p_currency, 'USD'),
            'initial_owner_capital',
            'Initial owner capital contribution upon business onboarding',
            p_owner_id
        ) RETURNING id INTO v_investment_id;
    END IF;

    SELECT jsonb_build_object(
        'business_id', v_business_id,
        'main_branch_id', v_branch_id,
        'owner_id', p_owner_id,
        'initial_investment_id', v_investment_id,
        'initial_capital', p_initial_investment_amount
    ) INTO v_result;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger Function: Sync auth.users to public.user_profiles on new sign up
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.user_profiles (id, email, full_name, avatar_url)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data->>'full_name', SPLIT_PART(NEW.email, '@', 1)),
        NEW.raw_user_meta_data->>'avatar_url'
    )
    ON CONFLICT (id) DO UPDATE SET
        email = EXCLUDED.email,
        full_name = EXCLUDED.full_name;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Bind Auth Trigger
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- 10. ROW LEVEL SECURITY (RLS) POLICIES

-- Enable RLS on all tables
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.businesses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.investor_investments ENABLE ROW LEVEL SECURITY;

-- 10.1 user_profiles Policies
CREATE POLICY "Users can view own profile or colleague profiles" ON public.user_profiles
    FOR SELECT USING (
        auth.uid() = id OR
        EXISTS (
            SELECT 1 FROM public.business_memberships m1
            JOIN public.business_memberships m2 ON m1.business_id = m2.business_id
            WHERE m1.user_id = auth.uid() AND m2.user_id = user_profiles.id
        )
    );

CREATE POLICY "Users can update own profile" ON public.user_profiles
    FOR UPDATE USING (auth.uid() = id);

-- 10.2 businesses Policies
CREATE POLICY "Members can view their businesses" ON public.businesses
    FOR SELECT USING (public.is_business_member(id, auth.uid()));

CREATE POLICY "Owners and Admins can update business details" ON public.businesses
    FOR UPDATE USING (public.is_business_owner(id, auth.uid()));

CREATE POLICY "Authenticated users can insert new business" ON public.businesses
    FOR INSERT WITH CHECK (auth.uid() = owner_id);

-- 10.3 branches Policies
CREATE POLICY "Business members can view branches" ON public.branches
    FOR SELECT USING (public.is_business_member(business_id, auth.uid()));

CREATE POLICY "Owners and Admins can manage branches" ON public.branches
    FOR ALL USING (public.is_business_owner(business_id, auth.uid()));

-- 10.4 business_memberships Policies
CREATE POLICY "Business members can view memberships" ON public.business_memberships
    FOR SELECT USING (public.is_business_member(business_id, auth.uid()));

CREATE POLICY "Owners and Admins can manage memberships" ON public.business_memberships
    FOR ALL USING (public.is_business_owner(business_id, auth.uid()));

-- 10.5 business_invitations Policies
CREATE POLICY "Owners and Admins can manage invitations" ON public.business_invitations
    FOR ALL USING (public.is_business_owner(business_id, auth.uid()));

CREATE POLICY "Invited users can view their invitation" ON public.business_invitations
    FOR SELECT USING (
        email = (SELECT email FROM public.user_profiles WHERE id = auth.uid()) OR
        status = 'pending'
    );

-- 10.6 investor_investments Policies
CREATE POLICY "Owners and respective investors can view investment entries" ON public.investor_investments
    FOR SELECT USING (
        public.is_business_owner(business_id, auth.uid()) OR
        investor_user_id = auth.uid()
    );

CREATE POLICY "Owners can insert investment entries" ON public.investor_investments
    FOR INSERT WITH CHECK (
        public.is_business_owner(business_id, auth.uid())
    );
