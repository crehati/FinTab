-- =============================================================================
-- Migration: 016_public_storefront_catalog_rpc.sql
-- Description: Safe public storefront read & WhatsApp order submission RPCs
--              for external customer catalog links (/catalog/<slug>?biz=<id>)
--              and custom storefront domains without exposing sensitive PII or
--              financial ledgers.
-- =============================================================================

BEGIN;

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
  v_branches JSONB := '[]'::jsonb;
  v_categories JSONB := '[]'::jsonb;
  v_products JSONB := '[]'::jsonb;
  v_catalog_settings JSONB := '{}'::jsonb;
  v_clean_slug TEXT := lower(trim(coalesce(p_store_slug, '')));
  v_clean_domain TEXT := lower(trim(coalesce(p_custom_domain, '')));
BEGIN
  IF p_business_id IS NOT NULL THEN
    SELECT
      id,
      trade_name,
      legal_name,
      currency,
      logo_url,
      contact_phone,
      contact_email,
      address,
      settings,
      metadata,
      created_at
    INTO v_biz
    FROM public.businesses
    WHERE id = p_business_id
      AND deleted_at IS NULL
    LIMIT 1;
  ELSIF v_clean_domain <> '' THEN
    SELECT
      id,
      trade_name,
      legal_name,
      currency,
      logo_url,
      contact_phone,
      contact_email,
      address,
      settings,
      metadata,
      created_at
    INTO v_biz
    FROM public.businesses
    WHERE deleted_at IS NULL
      AND (
        lower(coalesce(metadata->'workspace_sync'->'catalogSettings'->>'customDomain', '')) = v_clean_domain
        OR lower(coalesce(settings->'catalogSettings'->>'customDomain', '')) = v_clean_domain
      )
    LIMIT 1;
  ELSIF v_clean_slug <> '' THEN
    SELECT
      id,
      trade_name,
      legal_name,
      currency,
      logo_url,
      contact_phone,
      contact_email,
      address,
      settings,
      metadata,
      created_at
    INTO v_biz
    FROM public.businesses
    WHERE deleted_at IS NULL
      AND (
        lower(coalesce(metadata->'workspace_sync'->'catalogSettings'->>'storeSlug', '')) = v_clean_slug
        OR lower(coalesce(settings->'catalogSettings'->>'storeSlug', '')) = v_clean_slug
        OR trim(both '-' from regexp_replace(lower(coalesce(trade_name, legal_name, '')), '[^a-z0-9]+', '-', 'g')) = v_clean_slug
      )
    LIMIT 1;
  END IF;

  IF NOT FOUND OR v_biz.id IS NULL THEN
    RETURN NULL;
  END IF;

  v_catalog_settings := coalesce(
    v_biz.metadata->'workspace_sync'->'catalogSettings',
    v_biz.settings->'catalogSettings',
    '{}'::jsonb
  );

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', br.id,
    'businessId', br.business_id,
    'name', br.name,
    'address', CASE WHEN br.address IS NULL THEN '' WHEN jsonb_typeof(to_jsonb(br.address)) = 'string' THEN (to_jsonb(br.address) #>> '{}') ELSE coalesce(br.address->>'street', br.address->>'address', '') END,
    'phone', coalesce(br.phone, ''),
    'isMain', coalesce(br.is_main, false)
  ) ORDER BY br.is_main DESC, br.created_at ASC), '[]'::jsonb)
  INTO v_branches
  FROM public.branches br
  WHERE br.business_id = v_biz.id
    AND br.deleted_at IS NULL;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', cat.id,
    'businessId', cat.business_id,
    'name', cat.name
  ) ORDER BY cat.name ASC), '[]'::jsonb)
  INTO v_categories
  FROM public.product_categories cat
  WHERE cat.business_id = v_biz.id
    AND cat.deleted_at IS NULL
    AND coalesce(cat.is_active, true) = true;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id,
    'businessId', p.business_id,
    'categoryId', coalesce(p.category_id::text, ''),
    'name', p.name,
    'sku', coalesce(p.sku, ''),
    'barcode', coalesce(p.barcode, ''),
    'description', coalesce(p.description, ''),
    'image', coalesce(p.metadata->>'image', ''),
    'brand', coalesce(p.metadata->>'brand', ''),
    'promoBadge', coalesce(p.metadata->>'promo_badge', 'none'),
    'sellingPrice', coalesce((
      SELECT pr.price
      FROM public.product_prices pr
      WHERE pr.product_id = p.id
        AND pr.business_id = v_biz.id
        AND pr.deleted_at IS NULL
        AND coalesce(pr.is_active, true) = true
      ORDER BY (CASE WHEN lower(coalesce(pr.price_tier, 'retail')) = 'retail' AND coalesce(pr.min_quantity, 1) = 1 THEN 0 ELSE 1 END), pr.price ASC
      LIMIT 1
    ), 0),
    'currentStock', coalesce((
      SELECT jsonb_object_agg(bal.branch_key, bal.qty)
      FROM (
        SELECT
          coalesce(ib.branch_id::text, 'main') AS branch_key,
          greatest(0, sum(coalesce(ib.available_quantity, ib.on_hand_quantity, 0))) AS qty
        FROM public.inventory_balances ib
        WHERE ib.business_id = v_biz.id
          AND ib.product_id = p.id
        GROUP BY coalesce(ib.branch_id::text, 'main')
      ) bal
    ), '{}'::jsonb)
  ) ORDER BY p.name ASC), '[]'::jsonb)
  INTO v_products
  FROM public.products p
  WHERE p.business_id = v_biz.id
    AND p.deleted_at IS NULL
    AND coalesce(p.is_active, true) = true;

  RETURN jsonb_build_object(
    'business', jsonb_build_object(
      'id', v_biz.id,
      'name', coalesce(v_biz.trade_name, v_biz.legal_name, 'Storefront Catalog'),
      'legalName', coalesce(v_biz.legal_name, v_biz.trade_name),
      'currency', coalesce(v_biz.currency, 'HTG'),
      'logoUrl', coalesce(v_biz.logo_url, v_biz.settings->>'logoUrl', ''),
      'phone', coalesce(v_biz.contact_phone, v_biz.settings->>'phone', ''),
      'email', coalesce(v_biz.contact_email, v_biz.settings->>'email', ''),
      'address', CASE WHEN v_biz.address IS NULL THEN '' WHEN jsonb_typeof(to_jsonb(v_biz.address)) = 'string' THEN (to_jsonb(v_biz.address) #>> '{}') ELSE coalesce(v_biz.address->>'street', v_biz.address->>'address', '') END,
      'createdDate', v_biz.created_at
    ),
    'catalogSettings', v_catalog_settings,
    'branches', v_branches,
    'categories', v_categories,
    'products', v_products
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_public_storefront_catalog(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_storefront_catalog(UUID, TEXT, TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.submit_public_catalog_order(
  p_business_id UUID,
  p_order JSONB,
  p_notification JSONB DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_meta JSONB;
  v_ws JSONB;
  v_orders JSONB;
  v_notifs JSONB;
BEGIN
  IF p_business_id IS NULL OR p_order IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT metadata INTO v_meta
  FROM public.businesses
  WHERE id = p_business_id
    AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  v_meta := coalesce(v_meta, '{}'::jsonb);
  v_ws := coalesce(v_meta->'workspace_sync', jsonb_build_object('businessId', p_business_id::text));
  v_orders := coalesce(v_ws->'catalogOrders', '[]'::jsonb);
  v_notifs := coalesce(v_ws->'userNotifications', '[]'::jsonb);

  v_orders := jsonb_build_array(p_order) || (
    SELECT coalesce(jsonb_agg(elem), '[]'::jsonb)
    FROM (
      SELECT elem
      FROM jsonb_array_elements(v_orders) AS elem
      WHERE elem->>'id' IS DISTINCT FROM p_order->>'id'
      LIMIT 199
    ) sub
  );

  IF p_notification IS NOT NULL THEN
    v_notifs := jsonb_build_array(p_notification) || (
      SELECT coalesce(jsonb_agg(elem), '[]'::jsonb)
      FROM (
        SELECT elem
        FROM jsonb_array_elements(v_notifs) AS elem
        WHERE elem->>'id' IS DISTINCT FROM p_notification->>'id'
        LIMIT 99
      ) sub2
    );
  END IF;

  v_ws := jsonb_set(v_ws, '{catalogOrders}', v_orders, true);
  v_ws := jsonb_set(v_ws, '{userNotifications}', v_notifs, true);
  v_ws := jsonb_set(v_ws, '{updatedAt}', to_jsonb(now()::text), true);

  UPDATE public.businesses
  SET
    metadata = jsonb_set(v_meta, '{workspace_sync}', v_ws, true),
    updated_at = now()
  WHERE id = p_business_id;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_public_catalog_order(UUID, JSONB, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_public_catalog_order(UUID, JSONB, JSONB) TO anon, authenticated;

COMMIT;
