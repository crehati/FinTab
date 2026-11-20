-- ============================================================================
-- FINTAB ENTERPRISE BOS: MIGRATION 021
-- Cross-User Business Parity, Storefront JSONB Address Fix & Member Reconciliation
-- Strictly verified against Migrations 001, 002, 003, and 016
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. EXTEND `user_profiles_select_policy` SAFELY FOR INVITED MEMBERS
--    (Uses exact Migration 001 & 002 columns: business_memberships,
--     business_invitations, and investors.user_id)
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "user_profiles_select_policy" ON public.user_profiles;

CREATE POLICY "user_profiles_select_policy"
  ON public.user_profiles
  FOR SELECT
  TO authenticated
  USING (
    id = auth.uid()
    OR EXISTS (
      SELECT 1
      FROM public.business_memberships caller_bm
      JOIN public.business_memberships target_bm
        ON caller_bm.business_id = target_bm.business_id
      WHERE caller_bm.user_id = auth.uid()
        AND caller_bm.status = 'active'
        AND caller_bm.revoked_at IS NULL
        AND target_bm.user_id = user_profiles.id
    )
    OR EXISTS (
      SELECT 1
      FROM public.businesses b
      JOIN public.business_invitations bi
        ON bi.business_id = b.id
      WHERE (b.owner_user_id = auth.uid() OR public.is_member_of_business(b.id))
        AND b.deleted_at IS NULL
        AND lower(trim(coalesce(bi.email, ''))) = lower(trim(coalesce(user_profiles.email, '')))
    )
    OR EXISTS (
      SELECT 1
      FROM public.business_memberships caller_bm
      JOIN public.investors inv
        ON caller_bm.business_id = inv.business_id
      WHERE caller_bm.user_id = auth.uid()
        AND caller_bm.status = 'active'
        AND caller_bm.revoked_at IS NULL
        AND inv.user_id = user_profiles.id
    )
  );

-- ----------------------------------------------------------------------------
-- 2. FIX `public.get_public_storefront_catalog(UUID, TEXT, TEXT)`
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_public_storefront_catalog(UUID);
DROP FUNCTION IF EXISTS public.get_public_storefront_catalog(UUID, TEXT);

CREATE OR REPLACE FUNCTION public.get_public_storefront_catalog(
  p_business_id UUID DEFAULT NULL,
  p_store_slug TEXT DEFAULT NULL,
  p_custom_domain TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_biz RECORD;
  v_ws JSONB;
  v_ws_biz JSONB;
  v_ws_cat_settings JSONB;
  v_biz_addr TEXT;
  v_logo_url TEXT;
  v_phone TEXT;
  v_email TEXT;
  v_branches JSONB := '[]'::jsonb;
  v_categories JSONB := '[]'::jsonb;
  v_products JSONB := '[]'::jsonb;
  v_clean_slug TEXT := lower(trim(coalesce(p_store_slug, '')));
  v_clean_domain TEXT := lower(trim(coalesce(p_custom_domain, '')));
BEGIN
  IF p_business_id IS NOT NULL THEN
    SELECT *
    INTO v_biz
    FROM public.businesses b
    WHERE b.id = p_business_id
      AND b.deleted_at IS NULL
    LIMIT 1;
  ELSIF v_clean_domain <> '' THEN
    SELECT *
    INTO v_biz
    FROM public.businesses b
    WHERE b.deleted_at IS NULL
      AND (
        lower(trim(coalesce(b.metadata->'workspace_sync'->'catalogSettings'->>'customDomain', ''))) = v_clean_domain
        OR lower(trim(coalesce(b.settings->'catalogSettings'->>'customDomain', ''))) = v_clean_domain
        OR lower(trim(coalesce(b.settings->>'customDomain', ''))) = v_clean_domain
      )
    LIMIT 1;
  ELSIF v_clean_slug <> '' THEN
    SELECT *
    INTO v_biz
    FROM public.businesses b
    WHERE b.deleted_at IS NULL
      AND (
        lower(regexp_replace(coalesce(b.trade_name, b.legal_name, ''), '[^a-zA-Z0-9]+', '-', 'g')) = v_clean_slug
        OR lower(regexp_replace(coalesce(b.legal_name, ''), '[^a-zA-Z0-9]+', '-', 'g')) = v_clean_slug
        OR lower(trim(coalesce(b.metadata->'workspace_sync'->'catalogSettings'->>'storeSlug', ''))) = v_clean_slug
        OR lower(trim(coalesce(b.settings->>'storeSlug', ''))) = v_clean_slug
      )
    LIMIT 1;
  END IF;

  IF v_biz.id IS NULL THEN
    RETURN NULL;
  END IF;

  v_ws := COALESCE(v_biz.metadata->'workspace_sync', '{}'::jsonb);
  v_ws_biz := COALESCE(v_ws->'business', '{}'::jsonb);
  v_ws_cat_settings := COALESCE(v_ws->'catalogSettings', v_biz.settings->'catalogSettings', '{}'::jsonb);

  v_biz_addr := COALESCE(
    NULLIF(btrim(
      CASE
        WHEN v_biz.address IS NULL THEN ''
        WHEN jsonb_typeof(to_jsonb(v_biz.address)) = 'string' THEN (to_jsonb(v_biz.address) #>> '{}')
        ELSE COALESCE(to_jsonb(v_biz.address)->>'street', to_jsonb(v_biz.address)->>'address', '')
      END
    ), ''),
    NULLIF(btrim(COALESCE(v_biz.settings->>'businessAddress', v_biz.settings->>'address', '')), ''),
    NULLIF(btrim(COALESCE(v_ws_cat_settings->>'businessAddress', '')), ''),
    NULLIF(btrim(COALESCE(v_ws_biz->>'address', '')), ''),
    ''
  );

  v_logo_url := COALESCE(
    NULLIF(btrim(COALESCE(v_biz.logo_url, '')), ''),
    NULLIF(btrim(COALESCE(v_biz.settings->>'logoUrl', '')), ''),
    NULLIF(btrim(COALESCE(v_ws_biz->>'logoUrl', '')), ''),
    NULLIF(btrim(COALESCE(v_ws_cat_settings->>'businessLogo', '')), ''),
    ''
  );

  v_phone := COALESCE(
    NULLIF(btrim(COALESCE(v_biz.contact_phone, '')), ''),
    NULLIF(btrim(COALESCE(v_biz.settings->>'whatsappNumber', v_biz.settings->>'phone', '')), ''),
    NULLIF(btrim(COALESCE(v_ws_cat_settings->>'whatsappNumber', '')), ''),
    NULLIF(btrim(COALESCE(v_ws_biz->>'phone', '')), ''),
    ''
  );

  v_email := COALESCE(
    NULLIF(btrim(COALESCE(v_biz.contact_email, '')), ''),
    NULLIF(btrim(COALESCE(v_biz.settings->>'businessEmail', v_biz.settings->>'email', '')), ''),
    NULLIF(btrim(COALESCE(v_ws_cat_settings->>'businessEmail', v_ws_cat_settings->>'contactEmail', '')), ''),
    NULLIF(btrim(COALESCE(v_ws_biz->>'email', v_ws_biz->>'ownerEmail', '')), ''),
    ''
  );

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', br.id,
        'businessId', br.business_id,
        'name', br.name,
        'address', CASE
          WHEN br.address IS NULL THEN ''
          WHEN jsonb_typeof(to_jsonb(br.address)) = 'string' THEN (to_jsonb(br.address) #>> '{}')
          ELSE COALESCE(to_jsonb(br.address)->>'street', to_jsonb(br.address)->>'address', '')
        END,
        'phone', COALESCE(br.phone, ''),
        'isMain', COALESCE(br.is_main, false)
      )
      ORDER BY br.is_main DESC, br.created_at ASC
    ),
    '[]'::jsonb
  )
  INTO v_branches
  FROM public.branches br
  WHERE br.business_id = v_biz.id
    AND br.deleted_at IS NULL;

  IF jsonb_array_length(COALESCE(v_branches, '[]'::jsonb)) = 0
     AND jsonb_typeof(v_ws->'branches') = 'array' THEN
    v_branches := v_ws->'branches';
  END IF;

  WITH sql_cats AS (
    SELECT
      pc.id::text AS id,
      pc.business_id::text AS business_id,
      pc.name AS name
    FROM public.product_categories pc
    WHERE pc.business_id = v_biz.id
      AND pc.deleted_at IS NULL
      AND COALESCE(pc.is_active, true) = true
  ),
  ws_cats AS (
    SELECT
      COALESCE(elem->>'id', '') AS id,
      v_biz.id::text AS business_id,
      COALESCE(elem->>'name', 'General') AS name
    FROM jsonb_array_elements(
      CASE WHEN jsonb_typeof(v_ws->'categories') = 'array' THEN v_ws->'categories' ELSE '[]'::jsonb END
    ) elem
    WHERE COALESCE(elem->>'id', '') <> ''
  ),
  merged_cats AS (
    SELECT id, business_id, name FROM sql_cats
    UNION ALL
    SELECT w.id, w.business_id, w.name
    FROM ws_cats w
    WHERE NOT EXISTS (SELECT 1 FROM sql_cats s WHERE s.id = w.id)
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', mc.id,
        'businessId', mc.business_id,
        'name', mc.name
      )
    ),
    '[]'::jsonb
  )
  INTO v_categories
  FROM merged_cats mc;

  WITH stock_by_branch AS (
    SELECT
      ib.product_id,
      COALESCE(ib.branch_id::text, 'main') AS branch_key,
      GREATEST(0, SUM(COALESCE(ib.available_quantity, ib.on_hand_quantity - COALESCE(ib.reserved_quantity, 0), 0))) AS avail_qty
    FROM public.inventory_balances ib
    WHERE ib.business_id = v_biz.id
    GROUP BY ib.product_id, COALESCE(ib.branch_id::text, 'main')
  ),
  stock_json AS (
    SELECT
      sbb.product_id,
      jsonb_object_agg(sbb.branch_key, sbb.avail_qty) AS current_stock
    FROM stock_by_branch sbb
    GROUP BY sbb.product_id
  ),
  ws_prods AS (
    SELECT
      COALESCE(elem->>'id', '') AS id,
      elem AS raw_prod
    FROM jsonb_array_elements(
      CASE WHEN jsonb_typeof(v_ws->'products') = 'array' THEN v_ws->'products' ELSE '[]'::jsonb END
    ) elem
    WHERE COALESCE(elem->>'id', '') <> ''
  ),
  sql_prods AS (
    SELECT
      p.id::text AS id,
      jsonb_build_object(
        'id', p.id,
        'businessId', p.business_id,
        'categoryId', COALESCE(p.category_id::text, wp.raw_prod->>'categoryId', ''),
        'name', p.name,
        'sku', COALESCE(p.sku, ''),
        'barcode', COALESCE(p.barcode, ''),
        'description', COALESCE(NULLIF(p.description, ''), wp.raw_prod->>'description', ''),
        'image', COALESCE(
          NULLIF(p.metadata->>'image', ''),
          NULLIF(wp.raw_prod->>'image', ''),
          ''
        ),
        'brand', COALESCE(
          NULLIF(p.metadata->>'brand', ''),
          NULLIF(wp.raw_prod->>'brand', ''),
          ''
        ),
        'promoBadge', COALESCE(
          NULLIF(p.metadata->>'promo_badge', ''),
          NULLIF(p.metadata->>'promoBadge', ''),
          NULLIF(wp.raw_prod->>'promoBadge', ''),
          'none'
        ),
        'sellingPrice', COALESCE(
          (
            SELECT pr.price
            FROM public.product_prices pr
            WHERE pr.product_id = p.id
              AND pr.business_id = v_biz.id
              AND pr.deleted_at IS NULL
              AND COALESCE(pr.is_active, true) = true
            ORDER BY (CASE WHEN lower(coalesce(pr.price_tier, 'retail')) = 'retail' AND coalesce(pr.min_quantity, 1) = 1 THEN 0 ELSE 1 END), pr.price ASC
            LIMIT 1
          ),
          NULLIF((p.metadata->>'sellingPrice')::numeric, 0),
          (wp.raw_prod->>'sellingPrice')::numeric,
          0
        ),
        'currentStock', CASE
          WHEN sj.current_stock IS NOT NULL AND sj.current_stock <> '{}'::jsonb THEN sj.current_stock
          WHEN jsonb_typeof(wp.raw_prod->'currentStock') = 'object' THEN wp.raw_prod->'currentStock'
          ELSE '{}'::jsonb
        END
      ) AS prod_obj
    FROM public.products p
    LEFT JOIN stock_json sj ON sj.product_id = p.id
    LEFT JOIN ws_prods wp ON wp.id = p.id::text
    WHERE p.business_id = v_biz.id
      AND p.deleted_at IS NULL
      AND COALESCE(p.is_active, true) = true
  ),
  combined_prods AS (
    SELECT prod_obj FROM sql_prods
    UNION ALL
    SELECT jsonb_build_object(
      'id', wp.id,
      'businessId', v_biz.id,
      'categoryId', COALESCE(wp.raw_prod->>'categoryId', ''),
      'name', COALESCE(wp.raw_prod->>'name', 'Product'),
      'sku', COALESCE(wp.raw_prod->>'sku', ''),
      'barcode', COALESCE(wp.raw_prod->>'barcode', ''),
      'description', COALESCE(wp.raw_prod->>'description', ''),
      'image', COALESCE(wp.raw_prod->>'image', ''),
      'brand', COALESCE(wp.raw_prod->>'brand', ''),
      'promoBadge', COALESCE(wp.raw_prod->>'promoBadge', 'none'),
      'sellingPrice', COALESCE((wp.raw_prod->>'sellingPrice')::numeric, 0),
      'currentStock', CASE
        WHEN jsonb_typeof(wp.raw_prod->'currentStock') = 'object' THEN wp.raw_prod->'currentStock'
        ELSE '{}'::jsonb
      END
    )
    FROM ws_prods wp
    WHERE NOT EXISTS (SELECT 1 FROM sql_prods sp WHERE sp.id = wp.id)
  )
  SELECT COALESCE(jsonb_agg(cp.prod_obj), '[]'::jsonb)
  INTO v_products
  FROM combined_prods cp;

  RETURN jsonb_build_object(
    'business', jsonb_build_object(
      'id', v_biz.id,
      'name', COALESCE(v_biz.trade_name, v_biz.legal_name, v_ws_biz->>'name', 'Storefront Catalog'),
      'legalName', COALESCE(v_biz.legal_name, v_biz.trade_name, v_ws_biz->>'legalName', 'Storefront Catalog'),
      'currency', COALESCE(v_biz.currency, v_ws_biz->>'currency', 'HTG'),
      'taxRate', COALESCE((v_biz.settings->>'taxRate')::numeric, (v_ws_biz->>'taxRate')::numeric, 0),
      'logoUrl', v_logo_url,
      'phone', v_phone,
      'email', v_email,
      'ownerEmail', COALESCE(NULLIF(v_ws_biz->>'ownerEmail', ''), v_email),
      'address', v_biz_addr,
      'createdDate', v_biz.created_at
    ),
    'catalogSettings', v_ws_cat_settings,
    'branches', v_branches,
    'categories', v_categories,
    'products', v_products
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_public_storefront_catalog(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_storefront_catalog(UUID, TEXT, TEXT) TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. ALIGNED INVITE ACTIVATION RPC
--    Strictly matches Migration 001 & 002 tables, columns, and triggers:
--    - public.roles.is_system = true & canonical role codes
--    - public.business_memberships (never mutates immutable joined_at on UPDATE)
--    - public.role_assignment_scopes.scope_type = 'Business' (capital B)
--    - public.staff_profiles ON CONFLICT (business_id, user_id)
--    - public.investors (business_id, membership_id, user_id, investor_code, legal_name, status, payout_routing_info)
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_activate_verified_invite_membership(UUID, TEXT, TEXT, UUID, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.rpc_activate_verified_invite_membership(
  p_business_id UUID,
  p_account_type TEXT DEFAULT 'staff',
  p_role_code TEXT DEFAULT 'Employee',
  p_branch_id UUID DEFAULT NULL,
  p_full_name TEXT DEFAULT NULL,
  p_phone TEXT DEFAULT NULL,
  p_investment_amount NUMERIC DEFAULT 0,
  p_share_percentage NUMERIC DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_auth_user RECORD;
  v_biz RECORD;
  v_ws JSONB;
  v_override_status TEXT;
  v_membership_id UUID;
  v_role_id UUID;
  v_role_assignment_id UUID;
  v_main_branch_id UUID;
  v_effective_branch_id UUID;
  v_clean_role TEXT;
  v_acct_type TEXT := lower(trim(coalesce(p_account_type, 'staff')));
  v_resolved_name TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required to activate workspace membership.';
  END IF;

  SELECT id, email, email_confirmed_at, raw_user_meta_data
  INTO v_auth_user
  FROM auth.users
  WHERE id = v_uid;

  IF v_auth_user.id IS NULL THEN
    RAISE EXCEPTION 'Authenticated user record not found.';
  END IF;

  IF v_auth_user.email_confirmed_at IS NULL THEN
    RAISE EXCEPTION 'Email address must be confirmed before workspace membership activation.';
  END IF;

  SELECT *
  INTO v_biz
  FROM public.businesses
  WHERE id = p_business_id
    AND deleted_at IS NULL;

  IF v_biz.id IS NULL THEN
    RAISE EXCEPTION 'Target business workspace not found or inactive.';
  END IF;

  v_ws := COALESCE(v_biz.metadata->'workspace_sync', '{}'::jsonb);

  v_override_status := v_ws #>> ARRAY['memberAccessOverrides', p_business_id::text || ':' || lower(trim(v_auth_user.email)), 'status'];
  IF lower(coalesce(v_override_status, '')) = 'revoked' THEN
    RAISE EXCEPTION 'This workspace invitation has been revoked by the business owner.';
  END IF;

  v_resolved_name := COALESCE(
    NULLIF(trim(p_full_name), ''),
    NULLIF(trim(v_auth_user.raw_user_meta_data->>'full_name'), ''),
    split_part(v_auth_user.email, '@', 1)
  );

  INSERT INTO public.user_profiles (
    id,
    email,
    full_name,
    phone_number,
    status,
    updated_at
  )
  VALUES (
    v_uid,
    lower(trim(v_auth_user.email)),
    v_resolved_name,
    NULLIF(trim(coalesce(p_phone, v_auth_user.raw_user_meta_data->>'phone_number', v_auth_user.raw_user_meta_data->>'phone', '')), ''),
    'active',
    now()
  )
  ON CONFLICT (id) DO UPDATE
  SET
    full_name = CASE
      WHEN NULLIF(trim(p_full_name), '') IS NOT NULL THEN trim(p_full_name)
      WHEN user_profiles.full_name IS NULL OR user_profiles.full_name IN ('User', 'Staff Member', 'FinTab User')
        THEN EXCLUDED.full_name
      ELSE user_profiles.full_name
    END,
    phone_number = COALESCE(EXCLUDED.phone_number, user_profiles.phone_number),
    updated_at = now();

  -- Map to exact Migration 002 system role codes (never PrimaryOwner)
  v_clean_role := CASE
    WHEN v_acct_type = 'investor' THEN 'Investor'
    WHEN lower(coalesce(p_role_code, '')) IN ('coowner', 'co_owner') THEN 'CoOwner'
    WHEN lower(coalesce(p_role_code, '')) IN ('superadmin', 'admin') THEN 'SuperAdmin'
    WHEN lower(coalesce(p_role_code, '')) IN ('generalmanager', 'executive') THEN 'GeneralManager'
    WHEN lower(coalesce(p_role_code, '')) IN ('branchmanager', 'manager', 'owner', 'primaryowner') THEN 'BranchManager'
    WHEN lower(coalesce(p_role_code, '')) IN ('departmentmanager', 'supervisor') THEN 'DepartmentManager'
    WHEN lower(coalesce(p_role_code, '')) = 'salesmanager' THEN 'SalesManager'
    WHEN lower(coalesce(p_role_code, '')) IN ('salesperson', 'seller') THEN 'Salesperson'
    WHEN lower(coalesce(p_role_code, '')) = 'cashier' THEN 'Cashier'
    WHEN lower(coalesce(p_role_code, '')) IN ('stockmanager', 'stock_clerk', 'inventory_manager') THEN 'StockManager'
    WHEN lower(coalesce(p_role_code, '')) = 'stockstaff' THEN 'StockStaff'
    WHEN lower(coalesce(p_role_code, '')) IN ('financemanager', 'accountant') THEN 'FinanceManager'
    WHEN lower(coalesce(p_role_code, '')) = 'investor' THEN 'Investor'
    WHEN lower(coalesce(p_role_code, '')) IN ('viewer', 'auditor') THEN 'Viewer'
    ELSE 'Employee'
  END;

  SELECT id INTO v_main_branch_id
  FROM public.branches
  WHERE business_id = p_business_id
    AND deleted_at IS NULL
  ORDER BY is_main DESC, created_at ASC
  LIMIT 1;

  v_effective_branch_id := COALESCE(p_branch_id, v_main_branch_id);

  -- Upsert public.business_memberships (never mutate immutable joined_at on UPDATE!)
  INSERT INTO public.business_memberships (
    business_id,
    user_id,
    primary_role,
    status,
    is_owner,
    invited_by,
    joined_at,
    revoked_at,
    updated_at
  )
  VALUES (
    p_business_id,
    v_uid,
    v_clean_role,
    'active',
    false,
    v_biz.owner_user_id,
    now(),
    NULL,
    now()
  )
  ON CONFLICT (business_id, user_id) DO UPDATE
  SET
    status = 'active',
    primary_role = CASE
      WHEN business_memberships.is_owner = true THEN business_memberships.primary_role
      ELSE EXCLUDED.primary_role
    END,
    revoked_at = NULL,
    updated_at = now()
  RETURNING id INTO v_membership_id;

  UPDATE public.business_invitations
  SET
    status = 'accepted',
    accepted_at = COALESCE(accepted_at, now()),
    updated_at = now()
  WHERE business_id = p_business_id
    AND lower(trim(email)) = lower(trim(v_auth_user.email))
    AND status = 'pending';

  -- Bind system role using exact Migration 002 column `roles.is_system = true`
  SELECT id INTO v_role_id
  FROM public.roles
  WHERE is_system = true
    AND (code = v_clean_role OR lower(code) = lower(v_clean_role))
  LIMIT 1;

  IF v_role_id IS NOT NULL THEN
    SELECT id INTO v_role_assignment_id
    FROM public.role_assignments
    WHERE membership_id = v_membership_id
      AND role_id = v_role_id
      AND status = 'active'
      AND revoked_at IS NULL
    LIMIT 1;

    IF v_role_assignment_id IS NULL THEN
      INSERT INTO public.role_assignments (
        business_id,
        membership_id,
        role_id,
        status,
        assigned_by,
        assigned_at
      )
      VALUES (
        p_business_id,
        v_membership_id,
        v_role_id,
        'active',
        v_biz.owner_user_id,
        now()
      )
      RETURNING id INTO v_role_assignment_id;
    END IF;

    IF v_role_assignment_id IS NOT NULL AND NOT EXISTS (
      SELECT 1
      FROM public.role_assignment_scopes ras
      WHERE ras.role_assignment_id = v_role_assignment_id
    ) THEN
      INSERT INTO public.role_assignment_scopes (role_assignment_id, scope_type, branch_id)
      VALUES (v_role_assignment_id, 'Business', NULL);
    END IF;
  END IF;

  -- Provision public.investors or public.staff_profiles using exact Migration 002 columns
  IF v_acct_type = 'investor' THEN
    INSERT INTO public.investors (
      business_id,
      membership_id,
      user_id,
      investor_code,
      legal_name,
      status,
      payout_routing_info,
      created_at,
      updated_at
    )
    VALUES (
      p_business_id,
      v_membership_id,
      v_uid,
      'INV-' || upper(substring(replace(v_uid::text, '-', '') from 1 for 6)),
      v_resolved_name,
      'active',
      jsonb_build_object(
        'email', lower(trim(v_auth_user.email)),
        'phone', COALESCE(p_phone, ''),
        'investmentAmount', GREATEST(0, COALESCE(p_investment_amount, 0)),
        'sharePercentage', LEAST(100, GREATEST(0, COALESCE(p_share_percentage, 0)))
      ),
      now(),
      now()
    )
    ON CONFLICT (business_id, user_id) DO UPDATE
    SET
      legal_name = COALESCE(NULLIF(EXCLUDED.legal_name, ''), investors.legal_name),
      status = 'active',
      payout_routing_info = COALESCE(investors.payout_routing_info, '{}'::jsonb) || EXCLUDED.payout_routing_info,
      updated_at = now();
  ELSE
    INSERT INTO public.staff_profiles (
      business_id,
      membership_id,
      user_id,
      employee_code,
      job_title,
      branch_id,
      employment_status,
      hire_date,
      created_at,
      updated_at
    )
    VALUES (
      p_business_id,
      v_membership_id,
      v_uid,
      'EMP-' || upper(substring(replace(v_uid::text, '-', '') from 1 for 6)),
      v_clean_role,
      v_effective_branch_id,
      'Active',
      CURRENT_DATE,
      now(),
      now()
    )
    ON CONFLICT (business_id, user_id) DO UPDATE
    SET
      job_title = COALESCE(EXCLUDED.job_title, staff_profiles.job_title),
      branch_id = COALESCE(EXCLUDED.branch_id, staff_profiles.branch_id),
      employment_status = 'Active',
      updated_at = now();
  END IF;

  RETURN jsonb_build_object(
    'activated', true,
    'membershipId', v_membership_id,
    'businessId', p_business_id,
    'businessName', COALESCE(v_biz.trade_name, v_biz.legal_name, 'Workspace'),
    'currency', COALESCE(v_biz.currency, 'HTG'),
    'branchId', v_effective_branch_id,
    'roleCode', v_clean_role
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_activate_verified_invite_membership(UUID, TEXT, TEXT, UUID, TEXT, TEXT, NUMERIC, NUMERIC) TO authenticated;

-- ----------------------------------------------------------------------------
-- 4. OWNER RECONCILIATION RPC: `rpc_owner_reconcile_workspace_members`
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_owner_reconcile_workspace_members(
  p_business_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_biz RECORD;
  v_ws JSONB;
  v_main_branch_id UUID;
  v_rec RECORD;
  v_mem_id UUID;
  v_role_id UUID;
  v_ra_id UUID;
  v_clean_role TEXT;
  v_reconciled_count INT := 0;
BEGIN
  IF v_uid IS NULL OR p_business_id IS NULL THEN
    RETURN jsonb_build_object('reconciled', 0);
  END IF;

  SELECT *
  INTO v_biz
  FROM public.businesses
  WHERE id = p_business_id
    AND deleted_at IS NULL;

  IF v_biz.id IS NULL OR (v_biz.owner_user_id <> v_uid AND NOT public.is_business_owner(p_business_id)) THEN
    RETURN jsonb_build_object('reconciled', 0);
  END IF;

  v_ws := COALESCE(v_biz.metadata->'workspace_sync', '{}'::jsonb);

  SELECT id INTO v_main_branch_id
  FROM public.branches
  WHERE business_id = p_business_id
    AND deleted_at IS NULL
  ORDER BY is_main DESC, created_at ASC
  LIMIT 1;

  FOR v_rec IN
    WITH candidate_invites AS (
      SELECT
        lower(trim(bi.email)) AS email,
        CASE WHEN lower(bi.intended_role) = 'investor' THEN 'investor' ELSE 'staff' END AS account_type,
        bi.intended_role AS role_hint,
        bi.branch_id AS branch_id,
        NULL::text AS invitee_name
      FROM public.business_invitations bi
      WHERE bi.business_id = p_business_id
        AND bi.status IN ('pending', 'accepted')
      UNION
      SELECT
        lower(trim(coalesce(elem->>'normalizedEmail', elem->>'email', ''))) AS email,
        lower(trim(coalesce(elem->>'accountType', 'staff'))) AS account_type,
        coalesce(elem->>'roleId', 'Employee') AS role_hint,
        CASE
          WHEN (elem->>'branchId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            THEN (elem->>'branchId')::uuid
          ELSE NULL
        END AS branch_id,
        NULLIF(trim(coalesce(elem->>'inviteeName', '')), '') AS invitee_name
      FROM jsonb_array_elements(
        CASE WHEN jsonb_typeof(v_ws->'invitations') = 'array' THEN v_ws->'invitations' ELSE '[]'::jsonb END
      ) elem
      WHERE lower(coalesce(elem->>'status', '')) IN ('pending', 'accepted')
    )
    SELECT DISTINCT ON (au.id)
      au.id AS user_id,
      lower(trim(au.email)) AS email,
      COALESCE(
        ci.invitee_name,
        NULLIF(trim(au.raw_user_meta_data->>'full_name'), ''),
        split_part(au.email, '@', 1)
      ) AS full_name,
      ci.account_type,
      ci.role_hint,
      COALESCE(ci.branch_id, v_main_branch_id) AS effective_branch_id
    FROM candidate_invites ci
    JOIN auth.users au
      ON lower(trim(au.email)) = ci.email
    WHERE ci.email <> ''
      AND au.id <> v_biz.owner_user_id
      AND au.email_confirmed_at IS NOT NULL
      AND lower(coalesce(
        v_ws #>> ARRAY['memberAccessOverrides', p_business_id::text || ':' || ci.email, 'status'],
        ''
      )) <> 'revoked'
  LOOP
    BEGIN
      INSERT INTO public.user_profiles (id, email, full_name, status, updated_at)
      VALUES (v_rec.user_id, v_rec.email, v_rec.full_name, 'active', now())
      ON CONFLICT (id) DO NOTHING;

      v_clean_role := CASE
        WHEN v_rec.account_type = 'investor' THEN 'Investor'
        WHEN lower(coalesce(v_rec.role_hint, '')) IN ('coowner', 'co_owner') THEN 'CoOwner'
        WHEN lower(coalesce(v_rec.role_hint, '')) IN ('superadmin', 'admin') THEN 'SuperAdmin'
        WHEN lower(coalesce(v_rec.role_hint, '')) IN ('generalmanager', 'executive') THEN 'GeneralManager'
        WHEN lower(coalesce(v_rec.role_hint, '')) IN ('branchmanager', 'manager', 'owner', 'primaryowner') THEN 'BranchManager'
        WHEN lower(coalesce(v_rec.role_hint, '')) IN ('departmentmanager', 'supervisor') THEN 'DepartmentManager'
        WHEN lower(coalesce(v_rec.role_hint, '')) = 'salesmanager' THEN 'SalesManager'
        WHEN lower(coalesce(v_rec.role_hint, '')) IN ('salesperson', 'seller') THEN 'Salesperson'
        WHEN lower(coalesce(v_rec.role_hint, '')) = 'cashier' THEN 'Cashier'
        WHEN lower(coalesce(v_rec.role_hint, '')) IN ('stockmanager', 'stock_clerk', 'inventory_manager') THEN 'StockManager'
        WHEN lower(coalesce(v_rec.role_hint, '')) = 'stockstaff' THEN 'StockStaff'
        WHEN lower(coalesce(v_rec.role_hint, '')) IN ('financemanager', 'accountant') THEN 'FinanceManager'
        WHEN lower(coalesce(v_rec.role_hint, '')) = 'investor' THEN 'Investor'
        WHEN lower(coalesce(v_rec.role_hint, '')) IN ('viewer', 'auditor') THEN 'Viewer'
        ELSE 'Employee'
      END;

      INSERT INTO public.business_memberships (
        business_id, user_id, primary_role, status, is_owner, invited_by, joined_at, revoked_at, updated_at
      )
      VALUES (
        p_business_id,
        v_rec.user_id,
        v_clean_role,
        'active',
        false,
        v_biz.owner_user_id,
        now(),
        NULL,
        now()
      )
      ON CONFLICT (business_id, user_id) DO UPDATE
      SET
        status = 'active',
        revoked_at = NULL,
        updated_at = now()
      RETURNING id INTO v_mem_id;

      SELECT id INTO v_role_id
      FROM public.roles
      WHERE is_system = true
        AND (code = v_clean_role OR lower(code) = lower(v_clean_role))
      LIMIT 1;

      IF v_role_id IS NOT NULL THEN
        SELECT id INTO v_ra_id
        FROM public.role_assignments
        WHERE membership_id = v_mem_id
          AND role_id = v_role_id
          AND status = 'active'
          AND revoked_at IS NULL
        LIMIT 1;

        IF v_ra_id IS NULL THEN
          INSERT INTO public.role_assignments (
            business_id, membership_id, role_id, status, assigned_by, assigned_at
          )
          VALUES (
            p_business_id, v_mem_id, v_role_id, 'active', v_biz.owner_user_id, now()
          )
          RETURNING id INTO v_ra_id;
        END IF;

        IF v_ra_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM public.role_assignment_scopes WHERE role_assignment_id = v_ra_id
        ) THEN
          INSERT INTO public.role_assignment_scopes (role_assignment_id, scope_type, branch_id)
          VALUES (v_ra_id, 'Business', NULL);
        END IF;
      END IF;

      IF v_rec.account_type = 'investor' THEN
        INSERT INTO public.investors (
          business_id, membership_id, user_id, investor_code, legal_name, status, payout_routing_info, created_at, updated_at
        )
        VALUES (
          p_business_id,
          v_mem_id,
          v_rec.user_id,
          'INV-' || upper(substring(replace(v_rec.user_id::text, '-', '') from 1 for 6)),
          v_rec.full_name,
          'active',
          jsonb_build_object('email', v_rec.email),
          now(),
          now()
        )
        ON CONFLICT (business_id, user_id) DO UPDATE
        SET status = 'active', updated_at = now();
      ELSE
        INSERT INTO public.staff_profiles (
          business_id, membership_id, user_id, employee_code, job_title, branch_id, employment_status, hire_date, created_at, updated_at
        )
        VALUES (
          p_business_id,
          v_mem_id,
          v_rec.user_id,
          'EMP-' || upper(substring(replace(v_rec.user_id::text, '-', '') from 1 for 6)),
          v_clean_role,
          v_rec.effective_branch_id,
          'Active',
          CURRENT_DATE,
          now(),
          now()
        )
        ON CONFLICT (business_id, user_id) DO UPDATE
        SET
          employment_status = 'Active',
          updated_at = now();
      END IF;

      UPDATE public.business_invitations
      SET status = 'accepted', accepted_at = COALESCE(accepted_at, now()), updated_at = now()
      WHERE business_id = p_business_id
        AND lower(trim(email)) = v_rec.email
        AND status = 'pending';

      v_reconciled_count := v_reconciled_count + 1;
    EXCEPTION WHEN OTHERS THEN
      -- Skip conflicting single-business accounts without failing reconciliation for other members
      CONTINUE;
    END;
  END LOOP;

  RETURN jsonb_build_object('reconciled', v_reconciled_count);
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_owner_reconcile_workspace_members(UUID) TO authenticated;

-- ----------------------------------------------------------------------------
-- 5. UNIFIED MEMBER WORKSPACE HYDRATION RPC: `rpc_get_member_workspace_hydration`
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_get_member_workspace_hydration(
  p_business_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_auth_user RECORD;
  v_biz RECORD;
  v_ws JSONB;
  v_email TEXT;
  v_is_authorized BOOLEAN := FALSE;
  v_is_invited BOOLEAN := FALSE;
  v_override_status TEXT;
  v_inv_acct_type TEXT := 'staff';
  v_inv_role TEXT := 'Employee';
  v_storefront JSONB;
BEGIN
  IF v_uid IS NULL OR p_business_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT id, email, email_confirmed_at, raw_user_meta_data
  INTO v_auth_user
  FROM auth.users
  WHERE id = v_uid;

  IF v_auth_user.id IS NULL THEN
    RETURN NULL;
  END IF;

  v_email := lower(trim(coalesce(v_auth_user.email, '')));

  SELECT *
  INTO v_biz
  FROM public.businesses
  WHERE id = p_business_id
    AND deleted_at IS NULL;

  IF v_biz.id IS NULL THEN
    RETURN NULL;
  END IF;

  v_ws := COALESCE(v_biz.metadata->'workspace_sync', '{}'::jsonb);

  IF v_biz.owner_user_id = v_uid THEN
    v_is_authorized := TRUE;
  ELSIF EXISTS (
    SELECT 1
    FROM public.business_memberships bm
    WHERE bm.business_id = p_business_id
      AND bm.user_id = v_uid
      AND bm.status = 'active'
      AND bm.revoked_at IS NULL
  ) THEN
    v_is_authorized := TRUE;
  ELSE
    v_override_status := v_ws #>> ARRAY['memberAccessOverrides', p_business_id::text || ':' || v_email, 'status'];
    IF lower(coalesce(v_override_status, '')) <> 'revoked' THEN
      IF EXISTS (
        SELECT 1
        FROM public.business_invitations bi
        WHERE bi.business_id = p_business_id
          AND lower(trim(bi.email)) = v_email
          AND bi.status IN ('pending', 'accepted')
      ) THEN
        v_is_invited := TRUE;
        SELECT
          CASE WHEN lower(bi.intended_role) = 'investor' THEN 'investor' ELSE 'staff' END,
          bi.intended_role
        INTO v_inv_acct_type, v_inv_role
        FROM public.business_invitations bi
        WHERE bi.business_id = p_business_id
          AND lower(trim(bi.email)) = v_email
        ORDER BY bi.created_at DESC
        LIMIT 1;
      ELSIF (v_auth_user.raw_user_meta_data->>'invited_business_id') = p_business_id::text THEN
        v_is_invited := TRUE;
        v_inv_acct_type := lower(coalesce(v_auth_user.raw_user_meta_data->>'platform_account_type', 'staff'));
        v_inv_role := coalesce(v_auth_user.raw_user_meta_data->>'invited_role', 'Employee');
      ELSIF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(
          CASE WHEN jsonb_typeof(v_ws->'invitations') = 'array' THEN v_ws->'invitations' ELSE '[]'::jsonb END
        ) elem
        WHERE lower(trim(coalesce(elem->>'normalizedEmail', elem->>'email', ''))) = v_email
          AND lower(coalesce(elem->>'status', '')) IN ('pending', 'accepted')
      ) THEN
        v_is_invited := TRUE;
      END IF;
    END IF;

    IF v_is_invited AND v_auth_user.email_confirmed_at IS NOT NULL THEN
      BEGIN
        PERFORM public.rpc_activate_verified_invite_membership(
          p_business_id,
          v_inv_acct_type,
          v_inv_role,
          NULL,
          COALESCE(v_auth_user.raw_user_meta_data->>'full_name', NULL),
          COALESCE(v_auth_user.raw_user_meta_data->>'phone_number', NULL),
          0,
          0
        );
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
      v_is_authorized := TRUE;
    END IF;
  END IF;

  IF NOT v_is_authorized THEN
    RETURN NULL;
  END IF;

  v_storefront := public.get_public_storefront_catalog(p_business_id, NULL, NULL);

  RETURN jsonb_build_object(
    'business', COALESCE(v_storefront->'business', '{}'::jsonb) || jsonb_build_object(
      'settings', COALESCE(v_biz.settings, '{}'::jsonb),
      'workspaceSync', v_ws
    ),
    'branches', COALESCE(v_storefront->'branches', '[]'::jsonb),
    'categories', COALESCE(v_storefront->'categories', '[]'::jsonb),
    'products', COALESCE(v_storefront->'products', '[]'::jsonb),
    'customPermissions', COALESCE(v_ws->'customPermissions', '{}'::jsonb),
    'rolePermissionsMatrix', COALESCE(v_ws->'rolePermissionsMatrix', '{}'::jsonb),
    'catalogSettings', COALESCE(v_ws->'catalogSettings', '{}'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_get_member_workspace_hydration(UUID) TO authenticated;

-- ----------------------------------------------------------------------------
-- 6. ONE-TIME BACKFILL FOR EXISTING CONFIRMED INVITED STAFF & INVESTORS
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_b RECORD;
  v_r RECORD;
  v_mem_id UUID;
  v_role_id UUID;
  v_ra_id UUID;
  v_clean_role TEXT;
  v_main_br UUID;
  v_ws JSONB;
BEGIN
  FOR v_b IN
    SELECT * FROM public.businesses WHERE deleted_at IS NULL
  LOOP
    v_ws := COALESCE(v_b.metadata->'workspace_sync', '{}'::jsonb);

    SELECT id INTO v_main_br
    FROM public.branches
    WHERE business_id = v_b.id AND deleted_at IS NULL
    ORDER BY is_main DESC, created_at ASC
    LIMIT 1;

    FOR v_r IN
      SELECT DISTINCT ON (au.id)
        au.id AS user_id,
        lower(trim(au.email)) AS email,
        COALESCE(
          NULLIF(trim(au.raw_user_meta_data->>'full_name'), ''),
          split_part(au.email, '@', 1)
        ) AS full_name,
        COALESCE(
          NULLIF(trim(au.raw_user_meta_data->>'platform_account_type'), ''),
          'staff'
        ) AS account_type,
        COALESCE(
          NULLIF(trim(au.raw_user_meta_data->>'invited_role'), ''),
          'Cashier'
        ) AS role_hint
      FROM auth.users au
      WHERE au.id <> v_b.owner_user_id
        AND au.email_confirmed_at IS NOT NULL
        AND (
          (au.raw_user_meta_data->>'invited_business_id') = v_b.id::text
          OR EXISTS (
            SELECT 1 FROM public.business_invitations bi
            WHERE bi.business_id = v_b.id
              AND lower(trim(bi.email)) = lower(trim(au.email))
              AND bi.status IN ('pending', 'accepted')
          )
          OR EXISTS (
            SELECT 1
            FROM jsonb_array_elements(
              CASE WHEN jsonb_typeof(v_ws->'invitations') = 'array' THEN v_ws->'invitations' ELSE '[]'::jsonb END
            ) elem
            WHERE lower(trim(coalesce(elem->>'normalizedEmail', elem->>'email', ''))) = lower(trim(au.email))
              AND lower(coalesce(elem->>'status', '')) IN ('pending', 'accepted')
          )
        )
        AND lower(coalesce(
          v_ws #>> ARRAY['memberAccessOverrides', v_b.id::text || ':' || lower(trim(au.email)), 'status'],
          ''
        )) <> 'revoked'
    LOOP
      BEGIN
        INSERT INTO public.user_profiles (id, email, full_name, status, updated_at)
        VALUES (v_r.user_id, v_r.email, v_r.full_name, 'active', now())
        ON CONFLICT (id) DO NOTHING;

        v_clean_role := CASE
          WHEN lower(v_r.account_type) = 'investor' THEN 'Investor'
          WHEN lower(v_r.role_hint) IN ('coowner', 'co_owner') THEN 'CoOwner'
          WHEN lower(v_r.role_hint) IN ('superadmin', 'admin') THEN 'SuperAdmin'
          WHEN lower(v_r.role_hint) IN ('generalmanager', 'executive') THEN 'GeneralManager'
          WHEN lower(v_r.role_hint) IN ('branchmanager', 'manager', 'owner', 'primaryowner') THEN 'BranchManager'
          WHEN lower(v_r.role_hint) IN ('departmentmanager', 'supervisor') THEN 'DepartmentManager'
          WHEN lower(v_r.role_hint) = 'salesmanager' THEN 'SalesManager'
          WHEN lower(v_r.role_hint) IN ('salesperson', 'seller') THEN 'Salesperson'
          WHEN lower(v_r.role_hint) = 'cashier' THEN 'Cashier'
          WHEN lower(v_r.role_hint) IN ('stockmanager', 'stock_clerk', 'inventory_manager') THEN 'StockManager'
          WHEN lower(v_r.role_hint) = 'stockstaff' THEN 'StockStaff'
          WHEN lower(v_r.role_hint) IN ('financemanager', 'accountant') THEN 'FinanceManager'
          WHEN lower(v_r.role_hint) = 'investor' THEN 'Investor'
          WHEN lower(v_r.role_hint) IN ('viewer', 'auditor') THEN 'Viewer'
          ELSE 'Employee'
        END;

        INSERT INTO public.business_memberships (
          business_id, user_id, primary_role, status, is_owner, invited_by, joined_at, revoked_at, updated_at
        )
        VALUES (
          v_b.id,
          v_r.user_id,
          v_clean_role,
          'active',
          false,
          v_b.owner_user_id,
          now(),
          NULL,
          now()
        )
        ON CONFLICT (business_id, user_id) DO UPDATE
        SET status = 'active', revoked_at = NULL, updated_at = now()
        RETURNING id INTO v_mem_id;

        SELECT id INTO v_role_id
        FROM public.roles
        WHERE is_system = true
          AND (code = v_clean_role OR lower(code) = lower(v_clean_role))
        LIMIT 1;

        IF v_role_id IS NOT NULL THEN
          SELECT id INTO v_ra_id
          FROM public.role_assignments
          WHERE membership_id = v_mem_id AND role_id = v_role_id AND status = 'active' AND revoked_at IS NULL
          LIMIT 1;

          IF v_ra_id IS NULL THEN
            INSERT INTO public.role_assignments (business_id, membership_id, role_id, status, assigned_by, assigned_at)
            VALUES (v_b.id, v_mem_id, v_role_id, 'active', v_b.owner_user_id, now())
            RETURNING id INTO v_ra_id;
          END IF;

          IF v_ra_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM public.role_assignment_scopes WHERE role_assignment_id = v_ra_id
          ) THEN
            INSERT INTO public.role_assignment_scopes (role_assignment_id, scope_type, branch_id)
            VALUES (v_ra_id, 'Business', NULL);
          END IF;
        END IF;

        IF lower(v_r.account_type) = 'investor' THEN
          INSERT INTO public.investors (
            business_id, membership_id, user_id, investor_code, legal_name, status, payout_routing_info, created_at, updated_at
          )
          VALUES (
            v_b.id,
            v_mem_id,
            v_r.user_id,
            'INV-' || upper(substring(replace(v_r.user_id::text, '-', '') from 1 for 6)),
            v_r.full_name,
            'active',
            jsonb_build_object('email', v_r.email),
            now(),
            now()
          )
          ON CONFLICT (business_id, user_id) DO UPDATE
          SET status = 'active', updated_at = now();
        ELSE
          INSERT INTO public.staff_profiles (
            business_id, membership_id, user_id, employee_code, job_title, branch_id, employment_status, hire_date, created_at, updated_at
          )
          VALUES (
            v_b.id,
            v_mem_id,
            v_r.user_id,
            'EMP-' || upper(substring(replace(v_r.user_id::text, '-', '') from 1 for 6)),
            v_clean_role,
            v_main_br,
            'Active',
            CURRENT_DATE,
            now(),
            now()
          )
          ON CONFLICT (business_id, user_id) DO UPDATE
          SET employment_status = 'Active', updated_at = now();
        END IF;
      EXCEPTION WHEN OTHERS THEN
        CONTINUE;
      END;
    END LOOP;
  END LOOP;
END;
$$;

COMMIT;
