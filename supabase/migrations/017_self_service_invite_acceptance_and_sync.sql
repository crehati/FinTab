-- =============================================================================
-- Migration: 017_self_service_invite_acceptance_and_sync.sql
-- Description: FinTab Enterprise - Verified Self-Service Invitation Activation
--              & Invitation Lifecycle Alignment for Staff & Investors
--
-- Root Causes Addressed:
-- 1. Invited Staff & Investor users who confirm their email via Supabase Auth
--    were blocked by `memberships_insert_policy` from creating or activating
--    their own `business_memberships` row upon verified email acceptance,
--    causing empty cloud memberships on subsequent logins or new devices.
-- 2. `business_invitations` status constraint and missing `revoked_at` column
--    caused client revocation/reconciliation queries to fail or mismatch.
--
-- Security Invariants Preserved:
-- - Requires active authenticated caller (`auth.uid()`).
-- - Requires cryptographic email verification (`auth.users.email_confirmed_at IS NOT NULL`).
-- - Strictly validates caller email against non-revoked/non-cancelled
--   `business_invitations` OR signed `raw_user_meta_data->>'invited_business_id'`.
-- - Blocks `PrimaryOwner` / `Owner` privilege escalation (`is_owner = false` always).
-- - Enforces single-business restriction for Staff & Investor accounts.
-- =============================================================================

BEGIN;

-- 1. Align `public.business_invitations` with revocation metadata and statuses
ALTER TABLE public.business_invitations
  ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ;

DO $$
DECLARE
  v_con RECORD;
BEGIN
  FOR v_con IN
    SELECT con.conname
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
    WHERE nsp.nspname = 'public'
      AND rel.relname = 'business_invitations'
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%status%'
  LOOP
    EXECUTE format('ALTER TABLE public.business_invitations DROP CONSTRAINT IF EXISTS %I;', v_con.conname);
  END LOOP;
END $$;

ALTER TABLE public.business_invitations
  ADD CONSTRAINT business_invitations_status_check
  CHECK (status IN ('pending', 'accepted', 'declined', 'expired', 'cancelled', 'revoked'));

-- 2. Verified self-service invitation activation RPC for Staff & Investors
CREATE OR REPLACE FUNCTION public.rpc_activate_verified_invite_membership(
  p_business_id UUID,
  p_role_code TEXT DEFAULT 'Employee',
  p_branch_id UUID DEFAULT NULL,
  p_full_name TEXT DEFAULT NULL,
  p_phone TEXT DEFAULT NULL,
  p_account_type TEXT DEFAULT 'staff'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_auth_email TEXT;
  v_clean_email TEXT;
  v_email_confirmed_at TIMESTAMPTZ;
  v_raw_meta JSONB;
  v_meta_biz_id TEXT;
  v_latest_inv RECORD;
  v_has_valid_inv BOOLEAN := FALSE;
  v_has_valid_meta BOOLEAN := FALSE;
  v_biz_id UUID;
  v_req_role TEXT;
  v_mapped_role_code TEXT;
  v_role RECORD;
  v_valid_branch_id UUID := NULL;
  v_resolved_name TEXT;
  v_membership_id UUID;
  v_role_assignment_id UUID;
  v_emp_code TEXT;
  v_inv_code TEXT;
  v_seq INT;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required to activate workspace membership';
  END IF;

  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'Target business_id is required';
  END IF;

  -- Verify caller email is confirmed in Supabase Auth
  SELECT email, email_confirmed_at, COALESCE(raw_user_meta_data, '{}'::jsonb)
  INTO v_auth_email, v_email_confirmed_at, v_raw_meta
  FROM auth.users
  WHERE id = v_caller_id;

  IF v_auth_email IS NULL THEN
    RAISE EXCEPTION 'Authenticated user record not found';
  END IF;

  IF v_email_confirmed_at IS NULL THEN
    RAISE EXCEPTION 'Email address (%) must be confirmed before activating workspace access', v_auth_email;
  END IF;

  v_clean_email := lower(trim(v_auth_email));

  -- Check latest invitation row in public.business_invitations (if any)
  SELECT * INTO v_latest_inv
  FROM public.business_invitations
  WHERE business_id = p_business_id
    AND lower(email) = v_clean_email
  ORDER BY created_at DESC
  LIMIT 1;

  IF FOUND THEN
    IF v_latest_inv.status IN ('revoked', 'cancelled', 'declined') THEN
      RAISE EXCEPTION 'Invitation has been revoked or cancelled for %', v_clean_email;
    END IF;
    IF v_latest_inv.status IN ('pending', 'accepted')
       AND (v_latest_inv.status = 'accepted' OR v_latest_inv.expires_at IS NULL OR v_latest_inv.expires_at > NOW()) THEN
      v_has_valid_inv := TRUE;
    END IF;
  END IF;

  -- Also accept verified signup user_metadata injected at invitation acceptance signUp
  v_meta_biz_id := trim(COALESCE(v_raw_meta->>'invited_business_id', ''));
  IF v_meta_biz_id = p_business_id::TEXT THEN
    v_has_valid_meta := TRUE;
  END IF;

  IF NOT (v_has_valid_inv OR v_has_valid_meta) THEN
    RAISE EXCEPTION 'No verified invitation authorization found for % in business %', v_clean_email, p_business_id;
  END IF;

  -- Lock target business row
  SELECT id INTO v_biz_id
  FROM public.businesses
  WHERE id = p_business_id
    AND status = 'active'
    AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Target business % is inactive or unavailable', p_business_id;
  END IF;

  -- Enforce single active business workspace rule for Staff & Investors
  IF EXISTS (
    SELECT 1
    FROM public.business_memberships m
    WHERE m.user_id = v_caller_id
      AND m.business_id <> p_business_id
      AND m.status = 'active'
      AND m.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Staff and investor accounts are limited to one active business workspace';
  END IF;

  -- Map UI role aliases safely to canonical system roles (never PrimaryOwner / Owner)
  v_req_role := COALESCE(
    NULLIF(trim(COALESCE(v_latest_inv.intended_role, '')), ''),
    NULLIF(trim(COALESCE(p_role_code, '')), ''),
    CASE WHEN lower(trim(COALESCE(p_account_type, ''))) = 'investor' THEN 'Investor' ELSE 'Employee' END
  );

  IF v_req_role IN ('PrimaryOwner', 'Owner') THEN
    RAISE EXCEPTION 'PrimaryOwner role cannot be assigned via invitation';
  END IF;

  v_mapped_role_code := CASE v_req_role
    WHEN 'Admin' THEN 'SuperAdmin'
    WHEN 'Manager' THEN 'BranchManager'
    ELSE v_req_role
  END;

  SELECT * INTO v_role
  FROM public.roles
  WHERE code = v_mapped_role_code
    AND (
      (is_system = true AND business_id IS NULL)
      OR (is_system = false AND business_id = p_business_id)
    )
  LIMIT 1;

  IF v_role.id IS NULL THEN
    SELECT * INTO v_role
    FROM public.roles
    WHERE code = CASE WHEN lower(trim(COALESCE(p_account_type, ''))) = 'investor' THEN 'Investor' ELSE 'Employee' END
      AND is_system = true
      AND business_id IS NULL
    LIMIT 1;
  END IF;

  IF v_role.id IS NULL OR v_role.code = 'PrimaryOwner' THEN
    RAISE EXCEPTION 'Unable to resolve valid role for business %', p_business_id;
  END IF;

  -- Validate optional branch_id within the target business
  IF p_branch_id IS NOT NULL THEN
    SELECT id INTO v_valid_branch_id
    FROM public.branches
    WHERE id = p_branch_id
      AND business_id = p_business_id
      AND deleted_at IS NULL
    LIMIT 1;
  END IF;
  IF v_valid_branch_id IS NULL AND v_latest_inv.branch_id IS NOT NULL THEN
    SELECT id INTO v_valid_branch_id
    FROM public.branches
    WHERE id = v_latest_inv.branch_id
      AND business_id = p_business_id
      AND deleted_at IS NULL
    LIMIT 1;
  END IF;

  -- Upsert authoritative user_profiles
  v_resolved_name := COALESCE(
    NULLIF(trim(COALESCE(p_full_name, '')), ''),
    NULLIF(trim(COALESCE(v_raw_meta->>'full_name', '')), ''),
    SPLIT_PART(v_clean_email, '@', 1)
  );

  INSERT INTO public.user_profiles (
    id,
    email,
    full_name,
    phone_number,
    default_business_id,
    status,
    metadata
  ) VALUES (
    v_caller_id,
    v_clean_email,
    v_resolved_name,
    NULLIF(trim(COALESCE(p_phone, v_raw_meta->>'phone', '')), ''),
    p_business_id,
    'active',
    jsonb_build_object(
      'platformAccountType',
      CASE WHEN v_role.code = 'Investor' OR lower(trim(COALESCE(p_account_type, ''))) = 'investor' THEN 'investor' ELSE 'staff' END
    )
  )
  ON CONFLICT (id) DO UPDATE SET
    email = EXCLUDED.email,
    full_name = CASE
      WHEN NULLIF(trim(COALESCE(p_full_name, '')), '') IS NOT NULL THEN EXCLUDED.full_name
      WHEN public.user_profiles.full_name IS NULL OR public.user_profiles.full_name = '' THEN EXCLUDED.full_name
      ELSE public.user_profiles.full_name
    END,
    phone_number = COALESCE(EXCLUDED.phone_number, public.user_profiles.phone_number),
    default_business_id = COALESCE(public.user_profiles.default_business_id, p_business_id),
    status = 'active',
    updated_at = NOW();

  -- Upsert business_memberships (strictly non-owner)
  INSERT INTO public.business_memberships (
    business_id,
    user_id,
    is_owner,
    primary_role,
    status,
    joined_at
  ) VALUES (
    p_business_id,
    v_caller_id,
    false,
    v_role.code,
    'active',
    NOW()
  )
  ON CONFLICT (business_id, user_id) DO UPDATE SET
    is_owner = false,
    primary_role = EXCLUDED.primary_role,
    status = 'active',
    revoked_at = NULL,
    updated_at = NOW()
  RETURNING id INTO v_membership_id;

  -- Ensure active role assignment for this role
  SELECT id INTO v_role_assignment_id
  FROM public.role_assignments
  WHERE membership_id = v_membership_id
    AND role_id = v_role.id
    AND status = 'active'
  LIMIT 1;

  IF v_role_assignment_id IS NULL THEN
    INSERT INTO public.role_assignments (
      business_id,
      membership_id,
      role_id,
      status,
      assigned_by
    ) VALUES (
      p_business_id,
      v_membership_id,
      v_role.id,
      'active',
      COALESCE(v_latest_inv.invited_by, v_caller_id)
    )
    RETURNING id INTO v_role_assignment_id;

    IF v_valid_branch_id IS NOT NULL THEN
      INSERT INTO public.role_assignment_scopes (role_assignment_id, scope_type, branch_id)
      VALUES (v_role_assignment_id, 'Branch', v_valid_branch_id)
      ON CONFLICT DO NOTHING;
    ELSE
      INSERT INTO public.role_assignment_scopes (role_assignment_id, scope_type)
      VALUES (v_role_assignment_id, 'Business')
      ON CONFLICT DO NOTHING;
    END IF;
  END IF;

  -- Create or reactivate workforce / investor profile row
  IF v_role.code = 'Investor' OR lower(trim(COALESCE(p_account_type, ''))) = 'investor' THEN
    SELECT COALESCE(COUNT(*), 0) + 1 INTO v_seq
    FROM public.investors
    WHERE business_id = p_business_id;

    v_inv_code := 'INV-' || LPAD(v_seq::TEXT, 3, '0') || '-' || SUBSTRING(REPLACE(v_caller_id::TEXT, '-', ''), 1, 4);

    INSERT INTO public.investors (
      business_id,
      membership_id,
      user_id,
      investor_code,
      legal_name,
      status
    ) VALUES (
      p_business_id,
      v_membership_id,
      v_caller_id,
      v_inv_code,
      v_resolved_name,
      'active'
    )
    ON CONFLICT (business_id, user_id) DO UPDATE SET
      membership_id = EXCLUDED.membership_id,
      legal_name = EXCLUDED.legal_name,
      status = 'active',
      updated_at = NOW();
  ELSE
    SELECT COALESCE(COUNT(*), 0) + 1 INTO v_seq
    FROM public.staff_profiles
    WHERE business_id = p_business_id;

    v_emp_code := 'EMP-' || LPAD(v_seq::TEXT, 4, '0') || '-' || SUBSTRING(REPLACE(v_caller_id::TEXT, '-', ''), 1, 4);

    INSERT INTO public.staff_profiles (
      business_id,
      membership_id,
      user_id,
      employee_code,
      job_title,
      branch_id,
      employment_status,
      hire_date
    ) VALUES (
      p_business_id,
      v_membership_id,
      v_caller_id,
      v_emp_code,
      v_role.name,
      v_valid_branch_id,
      'Active',
      CURRENT_DATE
    )
    ON CONFLICT (business_id, user_id) DO UPDATE SET
      membership_id = EXCLUDED.membership_id,
      job_title = EXCLUDED.job_title,
      branch_id = COALESCE(EXCLUDED.branch_id, public.staff_profiles.branch_id),
      employment_status = 'Active',
      termination_date = NULL,
      updated_at = NOW();
  END IF;

  -- Mark pending invitation accepted if one exists
  UPDATE public.business_invitations
  SET
    status = 'accepted',
    accepted_at = COALESCE(accepted_at, NOW()),
    updated_at = NOW()
  WHERE business_id = p_business_id
    AND lower(email) = v_clean_email
    AND status = 'pending';

  RETURN jsonb_build_object(
    'business_id', p_business_id,
    'membership_id', v_membership_id,
    'role_assignment_id', v_role_assignment_id,
    'role_code', v_role.code,
    'status', 'active'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_activate_verified_invite_membership(UUID, TEXT, UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_activate_verified_invite_membership(UUID, TEXT, UUID, TEXT, TEXT, TEXT) TO authenticated;

COMMIT;
