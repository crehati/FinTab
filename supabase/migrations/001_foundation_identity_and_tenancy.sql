-- ============================================================================
-- FIN_TAB ENTERPRISE — PHASE 001: FOUNDATION, IDENTITY & TENANCY (HARDENED)
-- File: supabase/migrations/001_foundation_identity_and_tenancy.sql
-- 
-- DESCRIPTION:
-- Bootstraps the foundational multi-tenant identity schema, extensions,
-- user profiles, businesses, branches, departments, memberships, invitations,
-- hardened zero-recursion SECURITY DEFINER functions, idempotent triggers,
-- composite tenant-safety foreign keys, and strictly scoped RLS policies.
-- 
-- SECURITY SPECIFICATIONS ENFORCED:
-- - Zero recursive RLS loops via dedicated SECURITY DEFINER predicates.
-- - No cross-tenant relational links via composite (business_id, id) unique & FK keys.
-- - Targeted ON DELETE SET NULL (column) prevents tenant key business_id from being nulled.
-- - Bootstrap deadlock prevention: Initial business owner can insert business,
--   main branch, and founding owner membership atomically without prior membership.
-- - Strictly immutable ownership invariant: is_owner = true is ONLY insertable by businesses.owner_user_id.
-- - Safe, idempotent backfill for existing Supabase Auth users.
-- - No DROP TABLE, TRUNCATE, or data-destroying resets.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. EXTENSIONS & GLOBAL UTILITIES
-- ----------------------------------------------------------------------------

-- pgcrypto provides gen_random_uuid(), digest(), and cryptographic hashing
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Shared trigger function to automatically update updated_at timestamps
CREATE OR REPLACE FUNCTION public.trigger_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.trigger_set_updated_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trigger_set_updated_at() FROM anon;
GRANT EXECUTE ON FUNCTION public.trigger_set_updated_at() TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. PUBLIC.USER_PROFILES (Created WITHOUT circular default_business_id FK)
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.user_profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE RESTRICT,
  email TEXT NOT NULL UNIQUE,
  full_name TEXT NOT NULL,
  avatar_url TEXT,
  phone_number TEXT,
  default_business_id UUID, -- FK added after public.businesses exists
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'deactivated')),
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Note: email has an automatic unique index. Only index status here.
CREATE INDEX IF NOT EXISTS idx_user_profiles_status ON public.user_profiles (status);

-- ----------------------------------------------------------------------------
-- 3. PUBLIC.BUSINESSES (Master Tenant Entity)
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.businesses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  legal_name TEXT NOT NULL,
  trade_name TEXT,
  tax_identifier TEXT,
  currency TEXT NOT NULL DEFAULT 'USD',
  timezone TEXT NOT NULL DEFAULT 'UTC',
  fiscal_year_start_month SMALLINT NOT NULL DEFAULT 1 CHECK (fiscal_year_start_month BETWEEN 1 AND 12),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'archived')),
  logo_url TEXT,
  contact_email TEXT,
  contact_phone TEXT,
  address JSONB DEFAULT '{}'::jsonb,
  settings JSONB DEFAULT '{}'::jsonb,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_businesses_owner ON public.businesses (owner_user_id);
CREATE INDEX IF NOT EXISTS idx_businesses_status ON public.businesses (status) WHERE deleted_at IS NULL;

-- ----------------------------------------------------------------------------
-- 4. PUBLIC.BRANCHES (Physical Outlets / Locations)
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.branches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  name TEXT NOT NULL,
  code TEXT,
  is_main BOOLEAN NOT NULL DEFAULT false,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  phone TEXT,
  email TEXT,
  address JSONB DEFAULT '{}'::jsonb,
  settings JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,
  CONSTRAINT uq_business_branch_code UNIQUE (business_id, code),
  -- Composite unique key to enforce tenant-safe composite foreign keys
  CONSTRAINT uq_branches_business_id_id UNIQUE (business_id, id)
);

CREATE INDEX IF NOT EXISTS idx_branches_business ON public.branches (business_id);

-- Enforce AT MOST ONE active main branch per business
-- (Main branch status must be active and not soft-deleted)
CREATE UNIQUE INDEX IF NOT EXISTS uq_branches_single_main_per_business 
ON public.branches (business_id) 
WHERE is_main = true AND status = 'active' AND deleted_at IS NULL;

-- ----------------------------------------------------------------------------
-- 5. RESOLVE CIRCULAR REFERENCE ON USER_PROFILES
-- ----------------------------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint 
    WHERE conname = 'fk_user_profiles_default_business'
      AND conrelid = 'public.user_profiles'::regclass
  ) THEN
    ALTER TABLE public.user_profiles
      ADD CONSTRAINT fk_user_profiles_default_business
      FOREIGN KEY (default_business_id)
      REFERENCES public.businesses(id)
      ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_user_profiles_default_business ON public.user_profiles (default_business_id);

-- ----------------------------------------------------------------------------
-- 6. PUBLIC.DEPARTMENTS (Organizational Units)
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.departments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  branch_id UUID,
  name TEXT NOT NULL,
  code TEXT,
  description TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,
  CONSTRAINT uq_business_dept_code UNIQUE (business_id, code),
  -- Composite unique key to enforce tenant-safe composite foreign keys
  CONSTRAINT uq_departments_business_id_id UNIQUE (business_id, id),
  -- CROSS-TENANT INTEGRITY CONSTRAINT:
  -- Guarantees branch_id belongs strictly to the SAME business_id.
  -- ON DELETE SET NULL (branch_id) ensures business_id is NEVER nulled.
  CONSTRAINT fk_departments_branch_same_business
    FOREIGN KEY (business_id, branch_id)
    REFERENCES public.branches(business_id, id)
    ON DELETE SET NULL (branch_id)
);

CREATE INDEX IF NOT EXISTS idx_departments_business ON public.departments (business_id);
CREATE INDEX IF NOT EXISTS idx_departments_branch ON public.departments (branch_id);

-- ----------------------------------------------------------------------------
-- 7. PUBLIC.BUSINESS_MEMBERSHIPS (Tenant Access Association)
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.business_memberships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  primary_role TEXT NOT NULL DEFAULT 'Employee',
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'revoked')),
  is_owner BOOLEAN NOT NULL DEFAULT false,
  invited_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  revoked_at TIMESTAMPTZ,
  CONSTRAINT uq_business_membership UNIQUE (business_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_memberships_user ON public.business_memberships (user_id);
CREATE INDEX IF NOT EXISTS idx_memberships_business ON public.business_memberships (business_id);
CREATE INDEX IF NOT EXISTS idx_memberships_active ON public.business_memberships (business_id, user_id) WHERE status = 'active';

-- ----------------------------------------------------------------------------
-- 8. PUBLIC.BUSINESS_INVITATIONS (Team Invitations)
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.business_invitations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  intended_role TEXT NOT NULL DEFAULT 'Employee',
  branch_id UUID,
  department_id UUID,
  token_hash TEXT NOT NULL UNIQUE, -- SHA-256 hash; UNIQUE automatically creates the index
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined', 'expired', 'cancelled')),
  invited_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  accepted_at TIMESTAMPTZ,
  -- CROSS-TENANT INTEGRITY CONSTRAINTS:
  -- Guarantees branch_id and department_id belong strictly to the SAME business_id.
  -- ON DELETE SET NULL (column) ensures business_id is NEVER nulled.
  CONSTRAINT fk_invitations_branch_same_business
    FOREIGN KEY (business_id, branch_id)
    REFERENCES public.branches(business_id, id)
    ON DELETE SET NULL (branch_id),
  CONSTRAINT fk_invitations_department_same_business
    FOREIGN KEY (business_id, department_id)
    REFERENCES public.departments(business_id, id)
    ON DELETE SET NULL (department_id)
);

CREATE INDEX IF NOT EXISTS idx_invitations_email_lower ON public.business_invitations (LOWER(email));
CREATE INDEX IF NOT EXISTS idx_invitations_business ON public.business_invitations (business_id);

-- ----------------------------------------------------------------------------
-- 9. ZERO-RECURSION SECURITY DEFINER HELPER FUNCTIONS
-- ----------------------------------------------------------------------------
-- These functions run with elevated internal search security to safely inspect
-- memberships and ownership without recursively triggering table RLS policies.

-- Helper 1: Determine whether caller shares an active business with target user
CREATE OR REPLACE FUNCTION public.can_view_user_profile(p_target_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RETURN FALSE;
  END IF;

  -- Caller can always view their own profile
  IF v_caller_id = p_target_user_id THEN
    RETURN TRUE;
  END IF;

  -- True if caller and target user share at least one active business membership
  RETURN EXISTS (
    SELECT 1 
    FROM public.business_memberships m1
    JOIN public.business_memberships m2 ON m1.business_id = m2.business_id
    WHERE m1.user_id = v_caller_id
      AND m1.status = 'active'
      AND m2.user_id = p_target_user_id
      AND m2.status = 'active'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.can_view_user_profile(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_view_user_profile(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.can_view_user_profile(UUID) TO authenticated;

-- Helper 2: Bypasses RLS recursion when checking if caller is an active member
CREATE OR REPLACE FUNCTION public.is_member_of_business(p_business_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT (auth.uid() IS NOT NULL) AND EXISTS (
    SELECT 1 FROM public.business_memberships
    WHERE business_id = p_business_id
      AND user_id = auth.uid()
      AND status = 'active'
  );
$$;

REVOKE ALL ON FUNCTION public.is_member_of_business(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_member_of_business(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.is_member_of_business(UUID) TO authenticated;

-- Helper 3: Bypasses RLS recursion when checking if caller is owner
CREATE OR REPLACE FUNCTION public.is_business_owner(p_business_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT (auth.uid() IS NOT NULL) AND (
    EXISTS (
      SELECT 1 FROM public.businesses
      WHERE id = p_business_id
        AND owner_user_id = auth.uid()
        AND deleted_at IS NULL
    )
    OR EXISTS (
      SELECT 1 FROM public.business_memberships
      WHERE business_id = p_business_id
        AND user_id = auth.uid()
        AND is_owner = true
        AND status = 'active'
    )
  );
$$;

REVOKE ALL ON FUNCTION public.is_business_owner(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_business_owner(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.is_business_owner(UUID) TO authenticated;

-- Helper 4: Returns normalized lowercase email for caller without RLS recursion
CREATE OR REPLACE FUNCTION public.get_auth_user_email()
RETURNS TEXT
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT LOWER(email) 
  FROM public.user_profiles 
  WHERE id = auth.uid() 
    AND auth.uid() IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.get_auth_user_email() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_auth_user_email() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_auth_user_email() TO authenticated;

-- ----------------------------------------------------------------------------
-- 10. AUTH USER CREATION TRIGGER & IDEMPOTENT BACKFILL
-- ----------------------------------------------------------------------------

-- Function executed solely AFTER INSERT on auth.users for new user provisioning
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_full_name TEXT;
  v_avatar_url TEXT;
BEGIN
  v_full_name := COALESCE(
    NEW.raw_user_meta_data->>'full_name',
    NEW.raw_user_meta_data->>'name',
    SPLIT_PART(NEW.email, '@', 1)
  );
  v_avatar_url := COALESCE(
    NEW.raw_user_meta_data->>'avatar_url',
    NEW.raw_user_meta_data->>'picture'
  );

  INSERT INTO public.user_profiles (id, email, full_name, avatar_url, status)
  VALUES (
    NEW.id,
    NEW.email,
    v_full_name,
    v_avatar_url,
    'active'
  )
  ON CONFLICT (id) DO UPDATE SET
    email = EXCLUDED.email,
    full_name = CASE 
      WHEN public.user_profiles.full_name IS NULL OR public.user_profiles.full_name = '' 
      THEN EXCLUDED.full_name 
      ELSE public.user_profiles.full_name 
    END,
    avatar_url = COALESCE(public.user_profiles.avatar_url, EXCLUDED.avatar_url),
    updated_at = NOW();

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.handle_new_user() FROM anon;
GRANT EXECUTE ON FUNCTION public.handle_new_user() TO authenticated;

-- Simplified trigger: Fires ONLY on INSERT of new accounts in auth.users
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- Safe idempotent backfill for all existing Supabase Auth users
INSERT INTO public.user_profiles (id, email, full_name, avatar_url, status)
SELECT 
  u.id,
  u.email,
  COALESCE(
    u.raw_user_meta_data->>'full_name',
    u.raw_user_meta_data->>'name',
    SPLIT_PART(u.email, '@', 1)
  ) AS full_name,
  COALESCE(
    u.raw_user_meta_data->>'avatar_url',
    u.raw_user_meta_data->>'picture'
  ) AS avatar_url,
  'active' AS status
FROM auth.users u
WHERE u.email IS NOT NULL
ON CONFLICT (id) DO UPDATE SET
  email = EXCLUDED.email,
  full_name = CASE 
    WHEN public.user_profiles.full_name IS NULL OR public.user_profiles.full_name = '' 
    THEN EXCLUDED.full_name 
    ELSE public.user_profiles.full_name 
  END,
  avatar_url = COALESCE(public.user_profiles.avatar_url, EXCLUDED.avatar_url),
  updated_at = NOW();

-- ----------------------------------------------------------------------------
-- 11. ATTACH UPDATED_AT TRIGGERS
-- ----------------------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_user_profiles_updated_at ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_updated_at
  BEFORE UPDATE ON public.user_profiles
  FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_businesses_updated_at ON public.businesses;
CREATE TRIGGER trg_businesses_updated_at
  BEFORE UPDATE ON public.businesses
  FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_branches_updated_at ON public.branches;
CREATE TRIGGER trg_branches_updated_at
  BEFORE UPDATE ON public.branches
  FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_departments_updated_at ON public.departments;
CREATE TRIGGER trg_departments_updated_at
  BEFORE UPDATE ON public.departments
  FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_business_memberships_updated_at ON public.business_memberships;
CREATE TRIGGER trg_business_memberships_updated_at
  BEFORE UPDATE ON public.business_memberships
  FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

DROP TRIGGER IF EXISTS trg_business_invitations_updated_at ON public.business_invitations;
CREATE TRIGGER trg_business_invitations_updated_at
  BEFORE UPDATE ON public.business_invitations
  FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 12. STRUCTURAL COLUMN IMMUTABILITY & INTEGRITY BEFORE UPDATE TRIGGERS
-- ----------------------------------------------------------------------------
-- Enforces strict column-level immutability during UPDATE operations to prevent
-- authenticated users from tampering with structural identity, tenant keys,
-- creation timestamps, membership bounds, or account status.

-- 12.1 User Profiles Immutability & Validation Trigger
CREATE OR REPLACE FUNCTION public.trg_enforce_user_profiles_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Immutable primary key
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'user_profiles.id is immutable';
  END IF;

  -- Immutable creation timestamp
  IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'user_profiles.created_at is immutable';
  END IF;

  -- Email: immutable directly via client; can only be synchronized from Supabase Auth
  IF NEW.email IS DISTINCT FROM OLD.email THEN
    IF NOT EXISTS (
      SELECT 1 FROM auth.users u
      WHERE u.id = NEW.id
        AND LOWER(u.email) = LOWER(NEW.email)
    ) THEN
      RAISE EXCEPTION 'user_profiles.email cannot be changed directly; email must be updated via auth';
    END IF;
  END IF;

  -- Client self-service restriction on status
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF auth.role() = 'authenticated' THEN
      RAISE EXCEPTION 'user_profiles.status cannot be changed directly by user';
    END IF;
  END IF;

  -- Suspended or deactivated users cannot update profile fields
  IF OLD.status <> 'active' AND auth.role() = 'authenticated' THEN
    RAISE EXCEPTION 'Suspended or deactivated user cannot update profile';
  END IF;

  -- Validate default_business_id: user must be registered owner or active member of that business
  IF NEW.default_business_id IS NOT NULL AND NEW.default_business_id IS DISTINCT FROM OLD.default_business_id THEN
    IF NOT (
      EXISTS (
        SELECT 1 FROM public.businesses b
        WHERE b.id = NEW.default_business_id
          AND b.owner_user_id = NEW.id
          AND b.deleted_at IS NULL
      )
      OR EXISTS (
        SELECT 1 FROM public.business_memberships m
        WHERE m.business_id = NEW.default_business_id
          AND m.user_id = NEW.id
          AND m.status = 'active'
      )
    ) THEN
      RAISE EXCEPTION 'Cannot set default_business_id: user is neither registered owner nor active member of the specified business';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.trg_enforce_user_profiles_immutability() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_enforce_user_profiles_immutability() FROM anon;
GRANT EXECUTE ON FUNCTION public.trg_enforce_user_profiles_immutability() TO authenticated;

DROP TRIGGER IF EXISTS trg_user_profiles_immutability ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_immutability
  BEFORE UPDATE ON public.user_profiles
  FOR EACH ROW EXECUTE FUNCTION public.trg_enforce_user_profiles_immutability();

-- 12.2 Businesses Immutability Trigger
CREATE OR REPLACE FUNCTION public.trg_enforce_businesses_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'businesses.id is immutable';
  END IF;

  IF NEW.owner_user_id IS DISTINCT FROM OLD.owner_user_id THEN
    RAISE EXCEPTION 'businesses.owner_user_id is immutable; ownership transfer requires dedicated workflow';
  END IF;

  IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'businesses.created_at is immutable';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.trg_enforce_businesses_immutability() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_enforce_businesses_immutability() FROM anon;
GRANT EXECUTE ON FUNCTION public.trg_enforce_businesses_immutability() TO authenticated;

DROP TRIGGER IF EXISTS trg_businesses_immutability ON public.businesses;
CREATE TRIGGER trg_businesses_immutability
  BEFORE UPDATE ON public.businesses
  FOR EACH ROW EXECUTE FUNCTION public.trg_enforce_businesses_immutability();

-- 12.3 Branches Immutability Trigger
CREATE OR REPLACE FUNCTION public.trg_enforce_branches_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'branches.id is immutable';
  END IF;

  IF NEW.business_id IS DISTINCT FROM OLD.business_id THEN
    RAISE EXCEPTION 'branches.business_id is immutable; branches cannot be moved between businesses';
  END IF;

  IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'branches.created_at is immutable';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.trg_enforce_branches_immutability() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_enforce_branches_immutability() FROM anon;
GRANT EXECUTE ON FUNCTION public.trg_enforce_branches_immutability() TO authenticated;

DROP TRIGGER IF EXISTS trg_branches_immutability ON public.branches;
CREATE TRIGGER trg_branches_immutability
  BEFORE UPDATE ON public.branches
  FOR EACH ROW EXECUTE FUNCTION public.trg_enforce_branches_immutability();

-- 12.4 Departments Immutability Trigger
CREATE OR REPLACE FUNCTION public.trg_enforce_departments_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'departments.id is immutable';
  END IF;

  IF NEW.business_id IS DISTINCT FROM OLD.business_id THEN
    RAISE EXCEPTION 'departments.business_id is immutable; departments cannot be moved between businesses';
  END IF;

  IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'departments.created_at is immutable';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.trg_enforce_departments_immutability() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_enforce_departments_immutability() FROM anon;
GRANT EXECUTE ON FUNCTION public.trg_enforce_departments_immutability() TO authenticated;

DROP TRIGGER IF EXISTS trg_departments_immutability ON public.departments;
CREATE TRIGGER trg_departments_immutability
  BEFORE UPDATE ON public.departments
  FOR EACH ROW EXECUTE FUNCTION public.trg_enforce_departments_immutability();

-- 12.5 Business Memberships Immutability Trigger
CREATE OR REPLACE FUNCTION public.trg_enforce_memberships_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'business_memberships.id is immutable';
  END IF;

  IF NEW.business_id IS DISTINCT FROM OLD.business_id THEN
    RAISE EXCEPTION 'business_memberships.business_id is immutable; memberships cannot be moved between businesses';
  END IF;

  IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
    RAISE EXCEPTION 'business_memberships.user_id is immutable; membership user target cannot be changed';
  END IF;

  IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'business_memberships.created_at is immutable';
  END IF;

  IF NEW.joined_at IS DISTINCT FROM OLD.joined_at THEN
    RAISE EXCEPTION 'business_memberships.joined_at is immutable';
  END IF;

  -- Prevent arbitrary escalation of is_owner
  IF OLD.is_owner = false AND NEW.is_owner = true THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.businesses b
      WHERE b.id = NEW.business_id
        AND b.owner_user_id = NEW.user_id
        AND b.deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'Cannot escalate membership to owner; user is not the registered business owner';
    END IF;
  END IF;

  -- Prevent demoting registered owner
  IF OLD.is_owner = true AND NEW.is_owner = false THEN
    IF EXISTS (
      SELECT 1 FROM public.businesses b
      WHERE b.id = NEW.business_id
        AND b.owner_user_id = NEW.user_id
    ) THEN
      RAISE EXCEPTION 'Cannot demote registered business owner from owner membership';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.trg_enforce_memberships_immutability() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_enforce_memberships_immutability() FROM anon;
GRANT EXECUTE ON FUNCTION public.trg_enforce_memberships_immutability() TO authenticated;

DROP TRIGGER IF EXISTS trg_business_memberships_immutability ON public.business_memberships;
CREATE TRIGGER trg_business_memberships_immutability
  BEFORE UPDATE ON public.business_memberships
  FOR EACH ROW EXECUTE FUNCTION public.trg_enforce_memberships_immutability();

-- 12.6 Business Invitations Immutability Trigger
CREATE OR REPLACE FUNCTION public.trg_enforce_invitations_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'business_invitations.id is immutable';
  END IF;

  IF NEW.business_id IS DISTINCT FROM OLD.business_id THEN
    RAISE EXCEPTION 'business_invitations.business_id is immutable; invitations cannot be moved between businesses';
  END IF;

  IF NEW.email IS DISTINCT FROM OLD.email THEN
    RAISE EXCEPTION 'business_invitations.email is immutable; issue a new invitation instead';
  END IF;

  IF NEW.token_hash IS DISTINCT FROM OLD.token_hash THEN
    RAISE EXCEPTION 'business_invitations.token_hash is immutable';
  END IF;

  IF NEW.invited_by IS DISTINCT FROM OLD.invited_by THEN
    RAISE EXCEPTION 'business_invitations.invited_by is immutable';
  END IF;

  IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'business_invitations.created_at is immutable';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.trg_enforce_invitations_immutability() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_enforce_invitations_immutability() FROM anon;
GRANT EXECUTE ON FUNCTION public.trg_enforce_invitations_immutability() TO authenticated;

DROP TRIGGER IF EXISTS trg_business_invitations_immutability ON public.business_invitations;
CREATE TRIGGER trg_business_invitations_immutability
  BEFORE UPDATE ON public.business_invitations
  FOR EACH ROW EXECUTE FUNCTION public.trg_enforce_invitations_immutability();

-- ----------------------------------------------------------------------------
-- 13. ROW LEVEL SECURITY (RLS) POLICIES
-- ----------------------------------------------------------------------------

ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.businesses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.departments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_invitations ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- 13.1 USER_PROFILES POLICIES (Zero Recursion & Active-Only Update)
-- ----------------------------------------------------------------------------

DROP POLICY IF EXISTS "user_profiles_select_policy" ON public.user_profiles;
CREATE POLICY "user_profiles_select_policy" ON public.user_profiles
  FOR SELECT
  TO authenticated
  USING (
    public.can_view_user_profile(id)
  );

DROP POLICY IF EXISTS "user_profiles_update_policy" ON public.user_profiles;
CREATE POLICY "user_profiles_update_policy" ON public.user_profiles
  FOR UPDATE
  TO authenticated
  USING (auth.uid() = id AND status = 'active')
  WITH CHECK (auth.uid() = id);

-- ----------------------------------------------------------------------------
-- 13.2 BUSINESSES POLICIES
-- ----------------------------------------------------------------------------

DROP POLICY IF EXISTS "businesses_select_policy" ON public.businesses;
CREATE POLICY "businesses_select_policy" ON public.businesses
  FOR SELECT
  TO authenticated
  USING (
    deleted_at IS NULL
    AND (
      owner_user_id = auth.uid()
      OR public.is_member_of_business(id)
    )
  );

-- Bootstrap support: Owner inserts initial business record
DROP POLICY IF EXISTS "businesses_insert_policy" ON public.businesses;
CREATE POLICY "businesses_insert_policy" ON public.businesses
  FOR INSERT
  TO authenticated
  WITH CHECK (
    owner_user_id = auth.uid()
  );

DROP POLICY IF EXISTS "businesses_update_policy" ON public.businesses;
CREATE POLICY "businesses_update_policy" ON public.businesses
  FOR UPDATE
  TO authenticated
  USING (
    deleted_at IS NULL
    AND public.is_business_owner(id)
  )
  WITH CHECK (
    public.is_business_owner(id)
  );

DROP POLICY IF EXISTS "businesses_delete_policy" ON public.businesses;
CREATE POLICY "businesses_delete_policy" ON public.businesses
  FOR DELETE
  TO authenticated
  USING (false);

-- ----------------------------------------------------------------------------
-- 13.3 BRANCHES POLICIES
-- ----------------------------------------------------------------------------

DROP POLICY IF EXISTS "branches_select_policy" ON public.branches;
CREATE POLICY "branches_select_policy" ON public.branches
  FOR SELECT
  TO authenticated
  USING (
    deleted_at IS NULL
    AND (
      public.is_business_owner(business_id)
      OR public.is_member_of_business(business_id)
    )
  );

-- Bootstrap support: Owner can insert main branch upon business creation
DROP POLICY IF EXISTS "branches_insert_policy" ON public.branches;
CREATE POLICY "branches_insert_policy" ON public.branches
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_business_owner(business_id)
  );

DROP POLICY IF EXISTS "branches_update_policy" ON public.branches;
CREATE POLICY "branches_update_policy" ON public.branches
  FOR UPDATE
  TO authenticated
  USING (
    deleted_at IS NULL
    AND public.is_business_owner(business_id)
  )
  WITH CHECK (
    public.is_business_owner(business_id)
  );

DROP POLICY IF EXISTS "branches_delete_policy" ON public.branches;
CREATE POLICY "branches_delete_policy" ON public.branches
  FOR DELETE
  TO authenticated
  USING (false);

-- ----------------------------------------------------------------------------
-- 13.4 DEPARTMENTS POLICIES
-- ----------------------------------------------------------------------------

DROP POLICY IF EXISTS "departments_select_policy" ON public.departments;
CREATE POLICY "departments_select_policy" ON public.departments
  FOR SELECT
  TO authenticated
  USING (
    deleted_at IS NULL
    AND (
      public.is_business_owner(business_id)
      OR public.is_member_of_business(business_id)
    )
  );

-- Bootstrap support: Owner can insert department
DROP POLICY IF EXISTS "departments_insert_policy" ON public.departments;
CREATE POLICY "departments_insert_policy" ON public.departments
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_business_owner(business_id)
  );

DROP POLICY IF EXISTS "departments_update_policy" ON public.departments;
CREATE POLICY "departments_update_policy" ON public.departments
  FOR UPDATE
  TO authenticated
  USING (
    deleted_at IS NULL
    AND public.is_business_owner(business_id)
  )
  WITH CHECK (
    public.is_business_owner(business_id)
  );

DROP POLICY IF EXISTS "departments_delete_policy" ON public.departments;
CREATE POLICY "departments_delete_policy" ON public.departments
  FOR DELETE
  TO authenticated
  USING (false);

-- ----------------------------------------------------------------------------
-- 13.5 BUSINESS_MEMBERSHIPS POLICIES (Zero Recursion & Owner Bootstrap)
-- ----------------------------------------------------------------------------

DROP POLICY IF EXISTS "memberships_select_policy" ON public.business_memberships;
CREATE POLICY "memberships_select_policy" ON public.business_memberships
  FOR SELECT
  TO authenticated
  USING (
    -- User can always inspect their own membership
    user_id = auth.uid()
    -- Or active members of the tenant can see the coworker list (via SECURITY DEFINER helper)
    OR public.is_member_of_business(business_id)
    -- Or business owner can see all memberships
    OR public.is_business_owner(business_id)
  );

-- Owner bootstrap & Owner Invariant:
-- 1. Initial owner bootstrap: caller is businesses.owner_user_id, creating their OWN membership with is_owner = true.
-- 2. Subsequent team members: business owner can add other users, but is_owner MUST BE false.
-- 3. No non-owner can ever insert an owner membership.
DROP POLICY IF EXISTS "memberships_insert_policy" ON public.business_memberships;
CREATE POLICY "memberships_insert_policy" ON public.business_memberships
  FOR INSERT
  TO authenticated
  WITH CHECK (
    -- Condition A: Initial Owner Bootstrapping
    (
      is_owner = true
      AND user_id = auth.uid()
      AND EXISTS (
        SELECT 1 FROM public.businesses b
        WHERE b.id = business_id
          AND b.owner_user_id = auth.uid()
          AND b.deleted_at IS NULL
      )
    )
    OR
    -- Condition B: Owner inviting/adding staff (is_owner must be false)
    (
      is_owner = false
      AND public.is_business_owner(business_id)
    )
  );

DROP POLICY IF EXISTS "memberships_update_policy" ON public.business_memberships;
CREATE POLICY "memberships_update_policy" ON public.business_memberships
  FOR UPDATE
  TO authenticated
  USING (
    public.is_business_owner(business_id)
  )
  WITH CHECK (
    public.is_business_owner(business_id)
    -- Prevent non-primary owners from escalating is_owner
    AND (
      is_owner = false 
      OR EXISTS (
        SELECT 1 FROM public.businesses b 
        WHERE b.id = business_id 
          AND b.owner_user_id = user_id
      )
    )
  );

DROP POLICY IF EXISTS "memberships_delete_policy" ON public.business_memberships;
CREATE POLICY "memberships_delete_policy" ON public.business_memberships
  FOR DELETE
  TO authenticated
  USING (false);

-- ----------------------------------------------------------------------------
-- 13.6 BUSINESS_INVITATIONS POLICIES (Normalized Email Security)
-- ----------------------------------------------------------------------------

DROP POLICY IF EXISTS "invitations_select_policy" ON public.business_invitations;
CREATE POLICY "invitations_select_policy" ON public.business_invitations
  FOR SELECT
  TO authenticated
  USING (
    -- Invitee can view invitation strictly intended for their authenticated email
    LOWER(email) = public.get_auth_user_email()
    -- Or authorized business owner/manager can inspect invitations of their business
    OR public.is_business_owner(business_id)
  );

DROP POLICY IF EXISTS "invitations_insert_policy" ON public.business_invitations;
CREATE POLICY "invitations_insert_policy" ON public.business_invitations
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_business_owner(business_id)
    AND invited_by = auth.uid()
  );

DROP POLICY IF EXISTS "invitations_update_policy" ON public.business_invitations;
CREATE POLICY "invitations_update_policy" ON public.business_invitations
  FOR UPDATE
  TO authenticated
  USING (
    public.is_business_owner(business_id)
  )
  WITH CHECK (
    public.is_business_owner(business_id)
  );

DROP POLICY IF EXISTS "invitations_delete_policy" ON public.business_invitations;
CREATE POLICY "invitations_delete_policy" ON public.business_invitations
  FOR DELETE
  TO authenticated
  USING (
    public.is_business_owner(business_id)
  );
