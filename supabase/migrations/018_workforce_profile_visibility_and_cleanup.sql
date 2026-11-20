-- =============================================================================
-- Migration: 018_workforce_profile_visibility_and_cleanup.sql
-- Description: FinTab Enterprise - Fix Staff Profile Visibility RLS & Purge
--              Phantom / Email-less Workforce Records
--
-- Root Causes Addressed:
-- 1. `public.can_view_user_profile(UUID)` previously required BOTH caller AND
--    target memberships to have `status = 'active'`. Whenever a staff member was
--    suspended or deactivated, PostgREST RLS returned `user_profiles: null` to
--    the Business Owner, causing the UI/repository to render fallback strings
--    such as `EMP-7348 | Staff Member` with a blank email and replicate that
--    corrupted row across browsers via workspace_sync.
-- 2. `WorkspaceSyncService.setMemberAccessStatus` previously queried non-existent
--    columns (`status`, `terminated_at`) and table (`investor_profiles`), while
--    `staff_profiles` delete policy blocks client DELETEs.
--
-- Solution:
-- - Allow active workspace members/owners to view `user_profiles` for any user
--   associated with the SAME business (via `business_memberships`,
--   `staff_profiles`, or `investors`), regardless of target suspension/revocation
--   status, while keeping cross-tenant isolation strict.
-- - Provide `rpc_owner_set_member_access` & `rpc_owner_purge_orphan_staff_records`
--   SECURITY DEFINER RPCs using canonical columns (`employment_status`,
--   `termination_date`, `public.investors`).
-- - Idempotently purge existing email-less / orphan non-owner `staff_profiles`
--   and strip corrupted `Staff Member` entries without email from
--   `businesses.metadata->'workspace_sync'->'staff'`.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Fix `public.can_view_user_profile(UUID)` so suspended/inactive members
--    of the same business retain their real name & email in the Owner directory.
-- -----------------------------------------------------------------------------
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
  IF v_caller_id IS NULL OR p_target_user_id IS NULL THEN
    RETURN FALSE;
  END IF;

  -- Caller can always view their own profile
  IF v_caller_id = p_target_user_id THEN
    RETURN TRUE;
  END IF;

  -- True if caller holds an active membership in any business where the target
  -- user is (or was) a member, staff profile, or investor of that SAME business.
  RETURN EXISTS (
    SELECT 1
    FROM public.business_memberships m1
    WHERE m1.user_id = v_caller_id
      AND m1.status = 'active'
      AND m1.revoked_at IS NULL
      AND (
        EXISTS (
          SELECT 1
          FROM public.business_memberships m2
          WHERE m2.business_id = m1.business_id
            AND m2.user_id = p_target_user_id
        )
        OR EXISTS (
          SELECT 1
          FROM public.staff_profiles sp
          WHERE sp.business_id = m1.business_id
            AND sp.user_id = p_target_user_id
        )
        OR EXISTS (
          SELECT 1
          FROM public.investors inv
          WHERE inv.business_id = m1.business_id
            AND inv.user_id = p_target_user_id
        )
      )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.can_view_user_profile(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_view_user_profile(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.can_view_user_profile(UUID) TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. Authoritative Owner RPC to Suspend / Reactivate / Revoke Staff & Investors
--    across business_memberships, staff_profiles, investors, invitations, and
--    user_profiles using canonical SQL columns.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_owner_set_member_access(
  p_business_id UUID,
  p_target_user_id UUID DEFAULT NULL,
  p_staff_profile_id UUID DEFAULT NULL,
  p_investor_id UUID DEFAULT NULL,
  p_status TEXT DEFAULT 'Suspended',
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_is_authorized BOOLEAN := FALSE;
  v_normalized_status TEXT;
  v_mem_status TEXT;
  v_emp_status TEXT;
  v_inv_status TEXT;
  v_user_status TEXT;
  v_target_user_id UUID := p_target_user_id;
  v_target_email TEXT;
  v_is_protected_owner BOOLEAN := FALSE;
  v_now TIMESTAMPTZ := NOW();
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required to manage member access';
  END IF;

  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'Target business_id is required';
  END IF;

  v_is_authorized :=
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(p_business_id, 'staff:manage', NULL, NULL, NULL)
    OR public.has_permission_in_scope(p_business_id, 'staff:terminate', NULL, NULL, NULL);

  IF NOT v_is_authorized THEN
    RAISE EXCEPTION 'Permission denied: staff:manage or owner authority required';
  END IF;

  -- Resolve target user_id from staff_profile_id or investor_id if not passed directly
  IF v_target_user_id IS NULL AND p_staff_profile_id IS NOT NULL THEN
    SELECT user_id INTO v_target_user_id
    FROM public.staff_profiles
    WHERE id = p_staff_profile_id
      AND business_id = p_business_id
    LIMIT 1;
  END IF;

  IF v_target_user_id IS NULL AND p_investor_id IS NOT NULL THEN
    SELECT user_id INTO v_target_user_id
    FROM public.investors
    WHERE id = p_investor_id
      AND business_id = p_business_id
    LIMIT 1;
  END IF;

  -- Protect PrimaryOwner from accidental suspension/removal
  IF v_target_user_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.business_memberships m
      WHERE m.business_id = p_business_id
        AND m.user_id = v_target_user_id
        AND (m.is_owner = true OR m.primary_role = 'PrimaryOwner')
    ) INTO v_is_protected_owner;

    IF v_is_protected_owner THEN
      RAISE EXCEPTION 'PrimaryOwner workspace access cannot be suspended or revoked';
    END IF;
  END IF;

  v_normalized_status := lower(trim(COALESCE(p_status, 'suspended')));
  IF v_normalized_status IN ('active', 'reactivate') THEN
    v_mem_status := 'active';
    v_emp_status := 'Active';
    v_inv_status := 'active';
    v_user_status := 'active';
  ELSIF v_normalized_status IN ('revoked', 'remove', 'terminated') THEN
    v_mem_status := 'revoked';
    v_emp_status := 'Terminated';
    v_inv_status := 'inactive';
    v_user_status := 'deactivated';
  ELSE
    v_mem_status := 'suspended';
    v_emp_status := 'Suspended';
    v_inv_status := 'inactive';
    v_user_status := 'suspended';
  END IF;

  IF v_target_user_id IS NOT NULL THEN
    SELECT lower(trim(email)) INTO v_target_email
    FROM public.user_profiles
    WHERE id = v_target_user_id
    LIMIT 1;

    UPDATE public.business_memberships
    SET
      status = v_mem_status,
      revoked_at = CASE WHEN v_mem_status = 'revoked' THEN v_now WHEN v_mem_status = 'active' THEN NULL ELSE revoked_at END,
      updated_at = v_now
    WHERE business_id = p_business_id
      AND user_id = v_target_user_id
      AND is_owner = false
      AND primary_role <> 'PrimaryOwner';

    UPDATE public.staff_profiles
    SET
      employment_status = v_emp_status,
      termination_date = CASE WHEN v_emp_status = 'Terminated' THEN COALESCE(termination_date, CURRENT_DATE) WHEN v_emp_status = 'Active' THEN NULL ELSE termination_date END,
      updated_at = v_now
    WHERE business_id = p_business_id
      AND user_id = v_target_user_id;

    UPDATE public.investors
    SET
      status = v_inv_status,
      updated_at = v_now
    WHERE business_id = p_business_id
      AND user_id = v_target_user_id;

    UPDATE public.user_profiles
    SET
      status = v_user_status,
      updated_at = v_now
    WHERE id = v_target_user_id;

    IF v_mem_status = 'revoked' THEN
      UPDATE public.role_assignments ra
      SET
        status = 'revoked',
        updated_at = v_now
      FROM public.business_memberships m
      WHERE ra.membership_id = m.id
        AND m.business_id = p_business_id
        AND m.user_id = v_target_user_id
        AND m.is_owner = false;

      IF v_target_email IS NOT NULL AND v_target_email <> '' THEN
        UPDATE public.business_invitations
        SET
          status = 'revoked',
          revoked_at = COALESCE(revoked_at, v_now),
          updated_at = v_now
        WHERE business_id = p_business_id
          AND lower(email) = v_target_email
          AND status <> 'revoked';
      END IF;
    END IF;
  END IF;

  IF p_staff_profile_id IS NOT NULL THEN
    UPDATE public.staff_profiles
    SET
      employment_status = v_emp_status,
      termination_date = CASE WHEN v_emp_status = 'Terminated' THEN COALESCE(termination_date, CURRENT_DATE) WHEN v_emp_status = 'Active' THEN NULL ELSE termination_date END,
      updated_at = v_now
    WHERE id = p_staff_profile_id
      AND business_id = p_business_id;
  END IF;

  IF p_investor_id IS NOT NULL THEN
    UPDATE public.investors
    SET
      status = v_inv_status,
      updated_at = v_now
    WHERE id = p_investor_id
      AND business_id = p_business_id;
  END IF;

  RETURN jsonb_build_object(
    'business_id', p_business_id,
    'target_user_id', v_target_user_id,
    'membership_status', v_mem_status,
    'employment_status', v_emp_status,
    'reason', p_reason
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_owner_set_member_access(UUID, UUID, UUID, UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_owner_set_member_access(UUID, UUID, UUID, UUID, TEXT, TEXT) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. Authoritative Owner RPC to Purge Orphan / Corrupted / Email-less Staff
--    and Clean `businesses.metadata->'workspace_sync'->'staff'`.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_owner_purge_orphan_staff_records(
  p_business_id UUID,
  p_staff_profile_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_is_authorized BOOLEAN := FALSE;
  v_rec RECORD;
  v_deleted_count INT := 0;
  v_terminated_count INT := 0;
  v_meta JSONB;
  v_sync JSONB;
  v_clean_staff JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'Target business_id is required';
  END IF;

  v_is_authorized :=
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(p_business_id, 'staff:terminate', NULL, NULL, NULL)
    OR public.has_permission_in_scope(p_business_id, 'staff:manage', NULL, NULL, NULL);

  IF NOT v_is_authorized THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  FOR v_rec IN
    SELECT
      sp.id,
      sp.membership_id,
      sp.user_id
    FROM public.staff_profiles sp
    LEFT JOIN public.user_profiles up ON up.id = sp.user_id
    LEFT JOIN auth.users au ON au.id = sp.user_id
    LEFT JOIN public.business_memberships m ON m.id = sp.membership_id
    WHERE sp.business_id = p_business_id
      AND COALESCE(m.is_owner, FALSE) = FALSE
      AND COALESCE(m.primary_role, '') <> 'PrimaryOwner'
      AND (
        (p_staff_profile_id IS NOT NULL AND sp.id = p_staff_profile_id)
        OR up.id IS NULL
        OR NULLIF(btrim(COALESCE(up.email, '')), '') IS NULL
        OR au.id IS NULL
        OR (
          sp.employment_status = 'Terminated'
          AND (m.id IS NULL OR m.status = 'revoked')
        )
      )
  LOOP
    -- Attempt clean deletion of dependent non-financial metadata rows and the orphan staff profile
    BEGIN
      DELETE FROM public.staff_private_details
      WHERE business_id = p_business_id AND staff_profile_id = v_rec.id;

      DELETE FROM public.staff_compensation
      WHERE business_id = p_business_id AND staff_profile_id = v_rec.id;

      DELETE FROM public.staff_profiles
      WHERE id = v_rec.id AND business_id = p_business_id;

      v_deleted_count := v_deleted_count + 1;
    EXCEPTION WHEN foreign_key_violation THEN
      UPDATE public.staff_profiles
      SET
        employment_status = 'Terminated',
        termination_date = COALESCE(termination_date, CURRENT_DATE),
        updated_at = NOW()
      WHERE id = v_rec.id AND business_id = p_business_id;

      v_terminated_count := v_terminated_count + 1;
    END;

    IF v_rec.membership_id IS NOT NULL THEN
      UPDATE public.business_memberships
      SET
        status = 'revoked',
        revoked_at = COALESCE(revoked_at, NOW()),
        updated_at = NOW()
      WHERE id = v_rec.membership_id
        AND business_id = p_business_id
        AND is_owner = false;

      UPDATE public.role_assignments
      SET status = 'revoked', updated_at = NOW()
      WHERE membership_id = v_rec.membership_id
        AND business_id = p_business_id;
    END IF;
  END LOOP;

  -- Strip any email-less / synthetic "Staff Member" rows from workspace_sync.staff
  SELECT metadata INTO v_meta
  FROM public.businesses
  WHERE id = p_business_id
  FOR UPDATE;

  IF v_meta IS NOT NULL AND jsonb_typeof(v_meta->'workspace_sync') = 'object' THEN
    v_sync := v_meta->'workspace_sync';
    IF jsonb_typeof(v_sync->'staff') = 'array' THEN
      SELECT COALESCE(jsonb_agg(elem), '[]'::jsonb) INTO v_clean_staff
      FROM jsonb_array_elements(v_sync->'staff') AS elem
      WHERE NULLIF(btrim(COALESCE(elem->>'email', '')), '') IS NOT NULL
        AND position('@' in COALESCE(elem->>'email', '')) > 1
        AND (p_staff_profile_id IS NULL OR elem->>'id' <> p_staff_profile_id::TEXT)
        AND NOT (
          COALESCE(elem->>'name', '') = 'Staff Member'
          AND NULLIF(btrim(COALESCE(elem->>'email', '')), '') IS NULL
        );

      v_sync := jsonb_set(v_sync, '{staff}', v_clean_staff, true);
      v_meta := jsonb_set(v_meta, '{workspace_sync}', v_sync, true);

      UPDATE public.businesses
      SET metadata = v_meta, updated_at = NOW()
      WHERE id = p_business_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'business_id', p_business_id,
    'deleted_count', v_deleted_count,
    'terminated_count', v_terminated_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_owner_purge_orphan_staff_records(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_owner_purge_orphan_staff_records(UUID, UUID) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. One-Time Idempotent Data Cleanup: Remove Email-less / Orphan Non-Owner
--    Workforce Rows and Clean Existing `workspace_sync.staff` Snapshots
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_rec RECORD;
  v_biz RECORD;
  v_meta JSONB;
  v_sync JSONB;
  v_clean_staff JSONB;
BEGIN
  -- 4a. Clean orphaned / email-less non-owner staff_profiles across all businesses
  FOR v_rec IN
    SELECT sp.id, sp.business_id, sp.membership_id
    FROM public.staff_profiles sp
    LEFT JOIN public.user_profiles up ON up.id = sp.user_id
    LEFT JOIN auth.users au ON au.id = sp.user_id
    LEFT JOIN public.business_memberships m ON m.id = sp.membership_id
    WHERE COALESCE(m.is_owner, FALSE) = FALSE
      AND COALESCE(m.primary_role, '') <> 'PrimaryOwner'
      AND (
        up.id IS NULL
        OR NULLIF(btrim(COALESCE(up.email, '')), '') IS NULL
        OR au.id IS NULL
      )
  LOOP
    BEGIN
      DELETE FROM public.staff_private_details
      WHERE business_id = v_rec.business_id AND staff_profile_id = v_rec.id;

      DELETE FROM public.staff_compensation
      WHERE business_id = v_rec.business_id AND staff_profile_id = v_rec.id;

      DELETE FROM public.staff_profiles
      WHERE id = v_rec.id AND business_id = v_rec.business_id;
    EXCEPTION WHEN foreign_key_violation THEN
      UPDATE public.staff_profiles
      SET
        employment_status = 'Terminated',
        termination_date = COALESCE(termination_date, CURRENT_DATE),
        updated_at = NOW()
      WHERE id = v_rec.id AND business_id = v_rec.business_id;
    END;

    IF v_rec.membership_id IS NOT NULL THEN
      UPDATE public.business_memberships
      SET status = 'revoked', revoked_at = COALESCE(revoked_at, NOW()), updated_at = NOW()
      WHERE id = v_rec.membership_id AND business_id = v_rec.business_id AND is_owner = false;

      UPDATE public.role_assignments
      SET status = 'revoked', updated_at = NOW()
      WHERE membership_id = v_rec.membership_id AND business_id = v_rec.business_id;
    END IF;
  END LOOP;

  -- 4b. Remove email-less entries from every business's workspace_sync.staff array
  FOR v_biz IN
    SELECT id, metadata
    FROM public.businesses
    WHERE metadata ? 'workspace_sync'
      AND jsonb_typeof(metadata->'workspace_sync') = 'object'
      AND jsonb_typeof(metadata->'workspace_sync'->'staff') = 'array'
  LOOP
    v_meta := v_biz.metadata;
    v_sync := v_meta->'workspace_sync';

    SELECT COALESCE(jsonb_agg(elem), '[]'::jsonb) INTO v_clean_staff
    FROM jsonb_array_elements(v_sync->'staff') AS elem
    WHERE NULLIF(btrim(COALESCE(elem->>'email', '')), '') IS NOT NULL
      AND position('@' in COALESCE(elem->>'email', '')) > 1;

    v_sync := jsonb_set(v_sync, '{staff}', v_clean_staff, true);
    v_meta := jsonb_set(v_meta, '{workspace_sync}', v_sync, true);

    UPDATE public.businesses
    SET metadata = v_meta, updated_at = NOW()
    WHERE id = v_biz.id;
  END LOOP;
END $$;

COMMIT;
