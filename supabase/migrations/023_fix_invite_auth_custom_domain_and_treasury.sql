-- ============================================================================
-- FINTAB ENTERPRISE BOS: MIGRATION 023
-- Staff & Investor Invite Confirmation, Owner-Issued 6-Digit Recovery PINs,
-- & Custom Domain `www.` Normalization for Storefront Catalog
-- ============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ----------------------------------------------------------------------------
-- 1. UPGRADE `public.get_public_storefront_catalog` WITH `www.` NORMALIZATION
--    & DELETED PRODUCT/CATEGORY EXCLUSION
-- ----------------------------------------------------------------------------
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
  v_clean_domain TEXT := regexp_replace(lower(trim(coalesce(p_custom_domain, ''))), '^www\.', '');
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
        regexp_replace(lower(trim(coalesce(b.metadata->'workspace_sync'->'catalogSettings'->>'customDomain', ''))), '^www\.', '') = v_clean_domain
        OR regexp_replace(lower(trim(coalesce(b.settings->'catalogSettings'->>'customDomain', ''))), '^www\.', '') = v_clean_domain
        OR regexp_replace(lower(trim(coalesce(b.settings->>'customDomain', ''))), '^www\.', '') = v_clean_domain
      )
    LIMIT 1;
  ELSIF v_clean_slug <> '' THEN
    SELECT *
    INTO v_biz
    FROM public.businesses b
    WHERE b.deleted_at IS NULL
      AND (
        trim(both '-' from lower(regexp_replace(coalesce(b.trade_name, b.legal_name, ''), '[^a-zA-Z0-9]+', '-', 'g'))) = v_clean_slug
        OR trim(both '-' from lower(regexp_replace(coalesce(b.legal_name, ''), '[^a-zA-Z0-9]+', '-', 'g'))) = v_clean_slug
        OR lower(trim(coalesce(b.metadata->'workspace_sync'->'catalogSettings'->>'storeSlug', ''))) = v_clean_slug
        OR lower(trim(coalesce(b.settings->'catalogSettings'->>'storeSlug', ''))) = v_clean_slug
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

  WITH deleted_cat_ids AS (
    SELECT value AS id
    FROM jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(v_ws->'deletedCategoryIds') = 'array' THEN v_ws->'deletedCategoryIds' ELSE '[]'::jsonb END
    )
  ),
  sql_cats AS (
    SELECT
      pc.id::text AS id,
      pc.business_id::text AS business_id,
      pc.name AS name
    FROM public.product_categories pc
    WHERE pc.business_id = v_biz.id
      AND pc.deleted_at IS NULL
      AND COALESCE(pc.is_active, true) = true
      AND NOT EXISTS (SELECT 1 FROM deleted_cat_ids d WHERE d.id = pc.id::text)
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
      AND NOT EXISTS (SELECT 1 FROM deleted_cat_ids d WHERE d.id = COALESCE(elem->>'id', ''))
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

  WITH deleted_prod_ids AS (
    SELECT value AS id
    FROM jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(v_ws->'deletedProductIds') = 'array' THEN v_ws->'deletedProductIds' ELSE '[]'::jsonb END
    )
  ),
  stock_by_branch AS (
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
      AND NOT EXISTS (SELECT 1 FROM deleted_prod_ids d WHERE d.id = COALESCE(elem->>'id', ''))
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
      AND NOT EXISTS (SELECT 1 FROM deleted_prod_ids d WHERE d.id = p.id::text)
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
-- 2. OWNER-AUTHORIZED INVITE CONFIRMATION RPC
--    Confirms `auth.users.email_confirmed_at` ONLY when a valid, non-revoked
--    workspace invitation exists for `(p_business_id, lower(p_email))` so
--    Staff & Investors on external email domains (Yahoo, Hotmail, custom)
--    are never stranded when Supabase default SMTP drops external emails.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_confirm_invited_auth_user(
  p_business_id UUID,
  p_email TEXT,
  p_invite_token_or_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_clean_email TEXT := lower(btrim(coalesce(p_email, '')));
  v_has_valid_invite BOOLEAN := FALSE;
  v_user_id UUID;
BEGIN
  IF p_business_id IS NULL OR v_clean_email = '' THEN
    RETURN jsonb_build_object('confirmed', false, 'reason', 'missing_parameters');
  END IF;

  -- Check authoritative SQL `public.business_invitations`
  SELECT EXISTS (
    SELECT 1
    FROM public.business_invitations bi
    WHERE bi.business_id = p_business_id
      AND lower(btrim(coalesce(bi.email, ''))) = v_clean_email
      AND lower(coalesce(bi.status::text, 'pending')) NOT IN ('revoked', 'expired')
  )
  INTO v_has_valid_invite;

  -- Also check `businesses.metadata->'workspace_sync'->'invitations'`
  IF NOT v_has_valid_invite THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.businesses b,
           jsonb_array_elements(
             CASE
               WHEN jsonb_typeof(b.metadata->'workspace_sync'->'invitations') = 'array'
               THEN b.metadata->'workspace_sync'->'invitations'
               ELSE '[]'::jsonb
             END
           ) inv
      WHERE b.id = p_business_id
        AND b.deleted_at IS NULL
        AND lower(btrim(coalesce(inv->>'normalizedEmail', inv->>'email', ''))) = v_clean_email
        AND lower(coalesce(inv->>'status', 'pending')) NOT IN ('revoked', 'expired')
    )
    INTO v_has_valid_invite;
  END IF;

  IF NOT v_has_valid_invite THEN
    RETURN jsonb_build_object('confirmed', false, 'reason', 'no_active_invitation');
  END IF;

  UPDATE auth.users u
  SET
    email_confirmed_at = COALESCE(u.email_confirmed_at, now()),
    updated_at = now()
  WHERE lower(btrim(coalesce(u.email, ''))) = v_clean_email
  RETURNING u.id INTO v_user_id;

  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('confirmed', false, 'reason', 'auth_user_not_found');
  END IF;

  RETURN jsonb_build_object('confirmed', true, 'user_id', v_user_id);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_confirm_invited_auth_user(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_confirm_invited_auth_user(UUID, TEXT, TEXT) TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. OWNER-ISSUED 6-DIGIT RECOVERY PIN VERIFICATION & PASSWORD RESET RPCs
--    Allows a Business Owner to generate a 30-minute 6-digit recovery PIN
--    for a Staff Member or Investor (stored in `workspace_sync.memberRecoveryPins`)
--    and share it over WhatsApp/SMS when email delivery is unavailable.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_verify_member_recovery_pin(
  p_email TEXT,
  p_recovery_pin TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_clean_email TEXT := lower(btrim(coalesce(p_email, '')));
  v_clean_pin TEXT := regexp_replace(coalesce(p_recovery_pin, ''), '\s+', '', 'g');
  v_biz RECORD;
  v_pin_obj JSONB;
  v_expires_at TIMESTAMPTZ;
BEGIN
  IF v_clean_email = '' OR length(v_clean_pin) < 6 THEN
    RETURN jsonb_build_object('valid', false, 'reason', 'invalid_input');
  END IF;

  FOR v_biz IN
    SELECT id, metadata
    FROM public.businesses
    WHERE deleted_at IS NULL
      AND metadata->'workspace_sync'->'memberRecoveryPins' ? v_clean_email
  LOOP
    v_pin_obj := v_biz.metadata->'workspace_sync'->'memberRecoveryPins'->v_clean_email;
    IF coalesce(v_pin_obj->>'pin', '') = v_clean_pin THEN
      BEGIN
        v_expires_at := (v_pin_obj->>'expiresAt')::timestamptz;
      EXCEPTION WHEN OTHERS THEN
        v_expires_at := now() + interval '15 minutes';
      END;

      IF v_expires_at >= now() THEN
        RETURN jsonb_build_object(
          'valid', true,
          'business_id', v_biz.id,
          'email', v_clean_email
        );
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('valid', false, 'reason', 'pin_not_found_or_expired');
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_verify_member_recovery_pin(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_verify_member_recovery_pin(TEXT, TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.rpc_reset_member_password_with_pin(
  p_email TEXT,
  p_recovery_pin TEXT,
  p_new_password TEXT,
  p_business_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_clean_email TEXT := lower(btrim(coalesce(p_email, '')));
  v_clean_pin TEXT := regexp_replace(coalesce(p_recovery_pin, ''), '\s+', '', 'g');
  v_matched_biz_id UUID;
  v_meta JSONB;
  v_ws JSONB;
  v_pins JSONB;
  v_pin_obj JSONB;
  v_expires_at TIMESTAMPTZ;
  v_user_id UUID;
BEGIN
  IF v_clean_email = '' OR length(v_clean_pin) < 6 OR length(coalesce(p_new_password, '')) < 6 THEN
    RETURN jsonb_build_object('updated', false, 'reason', 'invalid_parameters');
  END IF;

  SELECT b.id, b.metadata
  INTO v_matched_biz_id, v_meta
  FROM public.businesses b
  WHERE b.deleted_at IS NULL
    AND (p_business_id IS NULL OR b.id = p_business_id)
    AND b.metadata->'workspace_sync'->'memberRecoveryPins' ? v_clean_email
    AND coalesce(b.metadata->'workspace_sync'->'memberRecoveryPins'->v_clean_email->>'pin', '') = v_clean_pin
  LIMIT 1
  FOR UPDATE;

  IF v_matched_biz_id IS NULL THEN
    RETURN jsonb_build_object('updated', false, 'reason', 'invalid_or_expired_pin');
  END IF;

  v_pin_obj := v_meta->'workspace_sync'->'memberRecoveryPins'->v_clean_email;
  BEGIN
    v_expires_at := (v_pin_obj->>'expiresAt')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    v_expires_at := now() + interval '15 minutes';
  END;

  IF v_expires_at < now() THEN
    RETURN jsonb_build_object('updated', false, 'reason', 'pin_expired');
  END IF;

  UPDATE auth.users u
  SET
    encrypted_password = extensions.crypt(p_new_password, extensions.gen_salt('bf')),
    email_confirmed_at = COALESCE(u.email_confirmed_at, now()),
    updated_at = now()
  WHERE lower(btrim(coalesce(u.email, ''))) = v_clean_email
  RETURNING u.id INTO v_user_id;

  -- Consume the single-use recovery PIN
  v_ws := COALESCE(v_meta->'workspace_sync', '{}'::jsonb);
  v_pins := COALESCE(v_ws->'memberRecoveryPins', '{}'::jsonb) - v_clean_email;
  v_ws := jsonb_set(v_ws, '{memberRecoveryPins}', v_pins, true);

  UPDATE public.businesses
  SET
    metadata = jsonb_set(v_meta, '{workspace_sync}', v_ws, true),
    updated_at = now()
  WHERE id = v_matched_biz_id;

  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('updated', false, 'reason', 'auth_user_not_registered_yet', 'business_id', v_matched_biz_id);
  END IF;

  RETURN jsonb_build_object('updated', true, 'user_id', v_user_id, 'business_id', v_matched_biz_id);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_reset_member_password_with_pin(TEXT, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_reset_member_password_with_pin(TEXT, TEXT, TEXT, UUID) TO anon, authenticated;

COMMIT;
