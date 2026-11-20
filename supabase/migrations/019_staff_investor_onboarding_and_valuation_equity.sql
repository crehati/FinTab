-- =============================================================================
-- Migration 019: Staff & Investor Onboarding Fixes, Profile Visibility & Valuation-Based Equity Units
-- =============================================================================
-- Fixes:
-- 1. Extends `user_profiles_select_policy` so business owners/members can read `user_profiles`
--    for `public.investors` (preventing 'N/A' emails or 'FinTab User' rows on Cap Table).
-- 2. Heals any stale `legal_name = 'FinTab User'` or `'User'` in `public.investors` and `public.user_profiles`
--    from `auth.users` metadata/email.
-- 3. Adds `equity_units` and `pre_money_valuation` to `public.capital_contributions` so new investor
--    contributions dilute ownership based on CURRENT Business Valuation (`I_new / (V_pre + I_new)`),
--    never raw historical initial capital (`I_new / (C_initial + I_new)`).
-- 4. Updates `rpc_get_cap_table`, `rpc_get_my_equity`, `rpc_record_capital_contribution`, and
--    `rpc_activate_verified_invite_membership` (recording invited investor capital & equity units upon verification).
-- =============================================================================

BEGIN;

-- 1. Extend user_profiles RLS policy to cover both staff_profiles AND investors in the same business
DROP POLICY IF EXISTS "user_profiles_select_policy" ON public.user_profiles;

CREATE POLICY "user_profiles_select_policy"
ON public.user_profiles
FOR SELECT
TO authenticated
USING (
  id = auth.uid()
  OR EXISTS (
    SELECT 1
    FROM public.business_memberships my_bm
    JOIN public.business_memberships target_bm
      ON target_bm.business_id = my_bm.business_id
    WHERE my_bm.user_id = auth.uid()
      AND my_bm.status = 'active'
      AND target_bm.user_id = public.user_profiles.id
  )
  OR EXISTS (
    SELECT 1
    FROM public.staff_profiles sp
    JOIN public.business_memberships my_bm
      ON my_bm.business_id = sp.business_id
    WHERE sp.user_id = public.user_profiles.id
      AND my_bm.user_id = auth.uid()
      AND my_bm.status = 'active'
  )
  OR EXISTS (
    SELECT 1
    FROM public.investors inv
    JOIN public.business_memberships my_bm
      ON my_bm.business_id = inv.business_id
    WHERE inv.user_id = public.user_profiles.id
      AND my_bm.user_id = auth.uid()
      AND my_bm.status = 'active'
  )
  OR EXISTS (
    SELECT 1
    FROM public.businesses b
    WHERE b.owner_user_id = auth.uid()
      AND (
        EXISTS (SELECT 1 FROM public.business_memberships bm WHERE bm.business_id = b.id AND bm.user_id = public.user_profiles.id)
        OR EXISTS (SELECT 1 FROM public.staff_profiles sp WHERE sp.business_id = b.id AND sp.user_id = public.user_profiles.id)
        OR EXISTS (SELECT 1 FROM public.investors inv WHERE inv.business_id = b.id AND inv.user_id = public.user_profiles.id)
      )
  )
);

-- 2. Heal any placeholder 'FinTab User' / 'User' names in user_profiles & investors
UPDATE public.user_profiles up
SET
  full_name = COALESCE(
    NULLIF(TRIM(au.raw_user_meta_data->>'full_name'), ''),
    NULLIF(SPLIT_PART(au.email, '@', 1), ''),
    up.full_name
  ),
  email = COALESCE(NULLIF(up.email, ''), LOWER(TRIM(au.email)))
FROM auth.users au
WHERE up.id = au.id
  AND (
    up.full_name IS NULL
    OR TRIM(up.full_name) IN ('', 'FinTab User', 'User')
    OR up.email IS NULL
    OR TRIM(up.email) = ''
  );

UPDATE public.investors inv
SET legal_name = COALESCE(
  NULLIF(TRIM(up.full_name), ''),
  NULLIF(SPLIT_PART(up.email, '@', 1), ''),
  inv.legal_name
)
FROM public.user_profiles up
WHERE inv.user_id = up.id
  AND (
    inv.legal_name IS NULL
    OR TRIM(inv.legal_name) IN ('', 'FinTab User', 'User')
  )
  AND up.full_name IS NOT NULL
  AND TRIM(up.full_name) NOT IN ('', 'FinTab User', 'User');

-- 3. Add valuation-based equity_units & pre_money_valuation columns to capital_contributions
ALTER TABLE public.capital_contributions
  ADD COLUMN IF NOT EXISTS equity_units NUMERIC(20, 6),
  ADD COLUMN IF NOT EXISTS pre_money_valuation NUMERIC(15, 2);

-- Backfill existing rows where equity_units is NULL (1 unit per currency unit at inception)
UPDATE public.capital_contributions
SET equity_units = amount
WHERE equity_units IS NULL;

-- 4. Upgrade rpc_record_capital_contribution to compute dilution-accurate equity_units from pre-money valuation
CREATE OR REPLACE FUNCTION public.rpc_record_capital_contribution(
  p_business_id UUID,
  p_investor_id UUID,
  p_amount NUMERIC,
  p_contribution_type TEXT DEFAULT 'additional_capital',
  p_effective_date DATE DEFAULT CURRENT_DATE,
  p_notes TEXT DEFAULT NULL,
  p_pre_money_valuation NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_next_entry INTEGER;
  v_existing_units NUMERIC(20, 6);
  v_existing_capital NUMERIC(15, 2);
  v_effective_pre_money NUMERIC(15, 2);
  v_units_to_issue NUMERIC(20, 6);
  v_new_id UUID;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Contribution amount must be strictly positive';
  END IF;

  IF NOT (
    public.is_verified_primary_owner(p_business_id, v_caller_id)
    OR public.has_permission_in_scope(p_business_id, 'investor:manage', NULL, NULL, NULL, v_caller_id)
  ) THEN
    RAISE EXCEPTION 'Insufficient permissions to record capital contribution';
  END IF;

  SELECT
    COALESCE(MAX(entry_number), 0) + 1,
    COALESCE(SUM(COALESCE(equity_units, amount)), 0),
    COALESCE(SUM(amount), 0)
  INTO v_next_entry, v_existing_units, v_existing_capital
  FROM public.capital_contributions
  WHERE business_id = p_business_id;

  v_effective_pre_money := COALESCE(NULLIF(p_pre_money_valuation, 0), v_existing_capital);

  IF v_existing_units <= 0 OR v_effective_pre_money <= 0 THEN
    v_units_to_issue := p_amount;
  ELSE
    -- Post-money dilution formula: U_new = U_existing * (I_new / V_pre)
    -- Guarantees New_Pct = I_new / (V_pre + I_new)
    v_units_to_issue := v_existing_units * (p_amount / v_effective_pre_money);
  END IF;

  INSERT INTO public.capital_contributions (
    business_id,
    investor_id,
    entry_number,
    contribution_type,
    amount,
    equity_units,
    pre_money_valuation,
    effective_date,
    notes,
    created_by
  ) VALUES (
    p_business_id,
    p_investor_id,
    v_next_entry,
    p_contribution_type,
    p_amount,
    v_units_to_issue,
    v_effective_pre_money,
    COALESCE(p_effective_date, CURRENT_DATE),
    p_notes,
    v_caller_id
  )
  RETURNING id INTO v_new_id;

  RETURN jsonb_build_object(
    'contribution_id', v_new_id,
    'business_id', p_business_id,
    'investor_id', p_investor_id,
    'entry_number', v_next_entry,
    'amount', p_amount,
    'equity_units', v_units_to_issue,
    'pre_money_valuation', v_effective_pre_money
  );
END;
$$;

-- 5. Upgrade rpc_get_cap_table to calculate ownership percentage from equity_units (real valuation dilution)
CREATE OR REPLACE FUNCTION public.rpc_get_cap_table(p_business_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_total_capital NUMERIC(15, 2) := 0;
  v_total_units NUMERIC(20, 6) := 0;
  v_cap_table JSONB := '[]'::jsonb;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT
    COALESCE(SUM(cc.amount), 0),
    COALESCE(SUM(COALESCE(cc.equity_units, cc.amount)), 0)
  INTO v_total_capital, v_total_units
  FROM public.capital_contributions cc
  JOIN public.investors inv ON inv.id = cc.investor_id
  WHERE cc.business_id = p_business_id
    AND inv.status = 'active';

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'investor_id', sub.investor_id,
        'investor_code', sub.investor_code,
        'legal_name', sub.legal_name,
        'investor_status', sub.investor_status,
        'total_investor_capital', sub.total_investor_capital,
        'equity_units', sub.investor_units,
        'equity_percentage',
          CASE
            WHEN v_total_units > 0 THEN ROUND((sub.investor_units / v_total_units) * 100.0, 4)
            WHEN v_total_capital > 0 THEN ROUND((sub.total_investor_capital / v_total_capital) * 100.0, 4)
            ELSE 0
          END,
        'contribution_count', sub.contribution_count,
        'first_investment_date', sub.first_investment_date,
        'latest_investment_date', sub.latest_investment_date
      )
      ORDER BY sub.investor_code ASC
    ),
    '[]'::jsonb
  )
  INTO v_cap_table
  FROM (
    SELECT
      inv.id AS investor_id,
      inv.investor_code,
      COALESCE(NULLIF(TRIM(up.full_name), ''), inv.legal_name) AS legal_name,
      inv.status AS investor_status,
      COALESCE(SUM(cc.amount), 0) AS total_investor_capital,
      COALESCE(SUM(COALESCE(cc.equity_units, cc.amount)), 0) AS investor_units,
      COUNT(cc.id) AS contribution_count,
      MIN(cc.effective_date) AS first_investment_date,
      MAX(cc.effective_date) AS latest_investment_date
    FROM public.investors inv
    LEFT JOIN public.user_profiles up ON up.id = inv.user_id
    LEFT JOIN public.capital_contributions cc
      ON cc.investor_id = inv.id AND cc.business_id = p_business_id
    WHERE inv.business_id = p_business_id
      AND inv.status = 'active'
    GROUP BY inv.id, inv.investor_code, inv.legal_name, up.full_name, inv.status
  ) sub;

  RETURN jsonb_build_object(
    'business_id', p_business_id,
    'total_business_capital', v_total_capital,
    'total_equity_units', v_total_units,
    'cap_table', v_cap_table
  );
END;
$$;

-- 6. Upgrade rpc_get_my_equity to use equity_units
CREATE OR REPLACE FUNCTION public.rpc_get_my_equity(p_business_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_investor_id UUID;
  v_my_capital NUMERIC(15, 2) := 0;
  v_my_units NUMERIC(20, 6) := 0;
  v_total_capital NUMERIC(15, 2) := 0;
  v_total_units NUMERIC(20, 6) := 0;
  v_count INTEGER := 0;
  v_first_date DATE;
  v_latest_date DATE;
BEGIN
  IF v_caller_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT id INTO v_investor_id
  FROM public.investors
  WHERE business_id = p_business_id
    AND user_id = v_caller_id
    AND status = 'active'
  LIMIT 1;

  IF v_investor_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT
    COALESCE(SUM(amount), 0),
    COALESCE(SUM(COALESCE(equity_units, amount)), 0),
    COUNT(id),
    MIN(effective_date),
    MAX(effective_date)
  INTO v_my_capital, v_my_units, v_count, v_first_date, v_latest_date
  FROM public.capital_contributions
  WHERE business_id = p_business_id
    AND investor_id = v_investor_id;

  SELECT
    COALESCE(SUM(cc.amount), 0),
    COALESCE(SUM(COALESCE(cc.equity_units, cc.amount)), 0)
  INTO v_total_capital, v_total_units
  FROM public.capital_contributions cc
  JOIN public.investors inv ON inv.id = cc.investor_id
  WHERE cc.business_id = p_business_id
    AND inv.status = 'active';

  RETURN jsonb_build_object(
    'business_id', p_business_id,
    'investor_id', v_investor_id,
    'my_total_capital', v_my_capital,
    'total_investor_capital', v_my_capital,
    'total_business_capital', v_total_capital,
    'equity_percentage',
      CASE
        WHEN v_total_units > 0 THEN ROUND((v_my_units / v_total_units) * 100.0, 4)
        WHEN v_total_capital > 0 THEN ROUND((v_my_capital / v_total_capital) * 100.0, 4)
        ELSE 0
      END,
    'contribution_count', v_count,
    'first_contribution_date', v_first_date,
    'latest_contribution_date', v_latest_date
  );
END;
$$;

-- 7. Upgrade rpc_activate_verified_invite_membership so invited Investors also get their capital & valuation units recorded
CREATE OR REPLACE FUNCTION public.rpc_activate_verified_invite_membership(
  p_business_id UUID,
  p_role_code TEXT DEFAULT 'Employee',
  p_branch_id UUID DEFAULT NULL,
  p_full_name TEXT DEFAULT NULL,
  p_phone TEXT DEFAULT NULL,
  p_account_type TEXT DEFAULT 'staff',
  p_investment_amount NUMERIC DEFAULT NULL,
  p_pre_money_valuation NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_email TEXT;
  v_resolved_name TEXT;
  v_membership_id UUID;
  v_role_id UUID;
  v_role_assignment_id UUID;
  v_membership_type TEXT;
  v_clean_role TEXT;
  v_investor_id UUID;
  v_inv_code TEXT;
  v_emp_code TEXT;
  v_next_entry INTEGER;
  v_existing_units NUMERIC(20, 6);
  v_existing_capital NUMERIC(15, 2);
  v_effective_pre_money NUMERIC(15, 2);
  v_units_to_issue NUMERIC(20, 6);
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT LOWER(TRIM(email)),
         COALESCE(NULLIF(TRIM(p_full_name), ''), NULLIF(TRIM(raw_user_meta_data->>'full_name'), ''), SPLIT_PART(email, '@', 1))
  INTO v_user_email, v_resolved_name
  FROM auth.users
  WHERE id = v_user_id;

  IF v_user_email IS NULL THEN
    RAISE EXCEPTION 'Authenticated user email not found';
  END IF;

  -- Upsert user_profiles with authoritative verified name & email
  INSERT INTO public.user_profiles (id, email, full_name, phone_number, platform_account_type, status)
  VALUES (
    v_user_id,
    v_user_email,
    v_resolved_name,
    p_phone,
    CASE WHEN p_account_type = 'investor' THEN 'investor' ELSE 'staff' END,
    'active'
  )
  ON CONFLICT (id) DO UPDATE SET
    email = EXCLUDED.email,
    full_name = COALESCE(NULLIF(TRIM(EXCLUDED.full_name), ''), public.user_profiles.full_name),
    phone_number = COALESCE(NULLIF(TRIM(EXCLUDED.phone_number), ''), public.user_profiles.phone_number),
    status = 'active',
    updated_at = NOW();

  v_membership_type := CASE WHEN p_account_type = 'investor' THEN 'investor' ELSE 'employee' END;
  v_clean_role := CASE
    WHEN p_account_type = 'investor' AND p_role_code NOT IN ('CoOwner', 'Investor') THEN 'Investor'
    WHEN p_role_code IN ('PrimaryOwner', 'Owner') THEN 'Employee'
    ELSE COALESCE(NULLIF(TRIM(p_role_code), ''), 'Employee')
  END;

  INSERT INTO public.business_memberships (
    business_id,
    user_id,
    membership_type,
    status,
    is_primary_owner,
    joined_at
  ) VALUES (
    p_business_id,
    v_user_id,
    v_membership_type,
    'active',
    FALSE,
    NOW()
  )
  ON CONFLICT (business_id, user_id) DO UPDATE SET
    membership_type = EXCLUDED.membership_type,
    status = 'active',
    revoked_at = NULL,
    updated_at = NOW()
  RETURNING id INTO v_membership_id;

  SELECT id INTO v_role_id
  FROM public.roles
  WHERE code = v_clean_role
    AND (business_id IS NULL OR business_id = p_business_id)
  ORDER BY business_id NULLS LAST
  LIMIT 1;

  IF v_role_id IS NOT NULL THEN
    SELECT id INTO v_role_assignment_id
    FROM public.role_assignments
    WHERE membership_id = v_membership_id
      AND role_id = v_role_id
    LIMIT 1;

    IF v_role_assignment_id IS NULL THEN
      INSERT INTO public.role_assignments (
        business_id,
        membership_id,
        role_id,
        status,
        assigned_by,
        effective_from
      ) VALUES (
        p_business_id,
        v_membership_id,
        v_role_id,
        'active',
        v_user_id,
        NOW()
      )
      RETURNING id INTO v_role_assignment_id;
    ELSE
      UPDATE public.role_assignments
      SET status = 'active', revoked_at = NULL, updated_at = NOW()
      WHERE id = v_role_assignment_id;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.role_assignment_scopes WHERE role_assignment_id = v_role_assignment_id
    ) THEN
      INSERT INTO public.role_assignment_scopes (
        role_assignment_id,
        scope_type,
        branch_id
      ) VALUES (
        v_role_assignment_id,
        CASE WHEN p_branch_id IS NOT NULL THEN 'Branch' ELSE 'Business' END,
        p_branch_id
      );
    END IF;
  END IF;

  IF p_account_type = 'investor' THEN
    SELECT id INTO v_investor_id
    FROM public.investors
    WHERE business_id = p_business_id AND user_id = v_user_id
    LIMIT 1;

    IF v_investor_id IS NULL THEN
      v_inv_code := 'INV-' || LPAD(((SELECT COUNT(*) + 1 FROM public.investors WHERE business_id = p_business_id))::TEXT, 3, '0');
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
        v_user_id,
        v_inv_code,
        v_resolved_name,
        'active'
      )
      RETURNING id INTO v_investor_id;
    ELSE
      UPDATE public.investors
      SET legal_name = v_resolved_name, status = 'active', updated_at = NOW()
      WHERE id = v_investor_id;
    END IF;

    -- Record initial investor capital contribution with post-money valuation units if not yet recorded
    IF p_investment_amount IS NOT NULL AND p_investment_amount > 0 THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.capital_contributions
        WHERE business_id = p_business_id AND investor_id = v_investor_id
      ) THEN
        SELECT
          COALESCE(MAX(entry_number), 0) + 1,
          COALESCE(SUM(COALESCE(equity_units, amount)), 0),
          COALESCE(SUM(amount), 0)
        INTO v_next_entry, v_existing_units, v_existing_capital
        FROM public.capital_contributions
        WHERE business_id = p_business_id;

        v_effective_pre_money := COALESCE(NULLIF(p_pre_money_valuation, 0), v_existing_capital);
        IF v_existing_units <= 0 OR v_effective_pre_money <= 0 THEN
          v_units_to_issue := p_investment_amount;
        ELSE
          v_units_to_issue := v_existing_units * (p_investment_amount / v_effective_pre_money);
        END IF;

        INSERT INTO public.capital_contributions (
          business_id,
          investor_id,
          entry_number,
          contribution_type,
          amount,
          equity_units,
          pre_money_valuation,
          effective_date,
          notes,
          created_by
        ) VALUES (
          p_business_id,
          v_investor_id,
          v_next_entry,
          'additional_capital',
          p_investment_amount,
          v_units_to_issue,
          v_effective_pre_money,
          CURRENT_DATE,
          'Initial invited investor capital contribution',
          v_user_id
        );
      END IF;
    END IF;
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM public.staff_profiles WHERE business_id = p_business_id AND user_id = v_user_id
    ) THEN
      v_emp_code := 'EMP-' || LPAD(((SELECT COUNT(*) + 1 FROM public.staff_profiles WHERE business_id = p_business_id))::TEXT, 3, '0');
      INSERT INTO public.staff_profiles (
        business_id,
        membership_id,
        user_id,
        employee_code,
        job_title,
        primary_branch_id,
        employment_type,
        status,
        hire_date
      ) VALUES (
        p_business_id,
        v_membership_id,
        v_user_id,
        v_emp_code,
        v_clean_role,
        p_branch_id,
        'full_time',
        'active',
        CURRENT_DATE
      );
    ELSE
      UPDATE public.staff_profiles
      SET status = 'active', job_title = v_clean_role, updated_at = NOW()
      WHERE business_id = p_business_id AND user_id = v_user_id;
    END IF;
  END IF;

  UPDATE public.business_invitations
  SET status = 'accepted', accepted_at = NOW(), updated_at = NOW()
  WHERE business_id = p_business_id
    AND LOWER(TRIM(email)) = v_user_email
    AND status = 'pending';

  RETURN jsonb_build_object(
    'membership_id', v_membership_id,
    'business_id', p_business_id,
    'user_id', v_user_id,
    'role_code', v_clean_role,
    'status', 'active'
  );
END;
$$;

COMMIT;
