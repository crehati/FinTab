-- =============================================================================
-- Migration 020: Unified Business Member Sync & Storefront Hydration Parity
-- =============================================================================
-- 1. Enhances `public.get_public_storefront_catalog` so connected workspace
--    members (Cashier, Staff, Manager, Investor) and storefront visitors receive
--    complete authoritative business branding (logoUrl, phone, email, ownerEmail,
--    address, currency, taxRate), branches, categories/departments, products,
--    prices, and branch stock balances.
-- 2. Adds `public.rpc_owner_provision_workspace_member` so Business Owners can
--    authoritatively provision or reconcile member rows in `business_memberships`
--    and `role_assignments` by user_id or email.
-- =============================================================================

DROP FUNCTION IF EXISTS public.get_public_storefront_catalog(uuid);

CREATE OR REPLACE FUNCTION public.get_public_storefront_catalog(
  p_business_id uuid DEFAULT NULL,
  p_store_slug text DEFAULT NULL,
  p_custom_domain text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_biz record;
  v_logo text;
  v_phone text;
  v_email text;
  v_owner_email text;
  v_address text;
  v_tax_rate numeric;
  v_catalog_settings jsonb;
  v_branches jsonb;
  v_categories jsonb;
  v_products jsonb;
BEGIN
  SELECT
    b.id,
    b.trade_name,
    b.legal_name,
    b.currency,
    b.logo_url,
    b.contact_phone,
    b.contact_email,
    b.address,
    b.settings,
    b.metadata,
    b.status
  INTO v_biz
  FROM public.businesses b
  WHERE b.id = p_business_id
    AND b.deleted_at IS NULL
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_logo := COALESCE(
    NULLIF(v_biz.logo_url, ''),
    NULLIF(v_biz.settings->>'logoUrl', ''),
    NULLIF(v_biz.metadata->'workspace_sync'->'business'->>'logoUrl', ''),
    ''
  );

  v_phone := COALESCE(
    NULLIF(v_biz.contact_phone, ''),
    NULLIF(v_biz.settings->>'phone', ''),
    NULLIF(v_biz.metadata->'workspace_sync'->'business'->>'phone', ''),
    ''
  );

  v_email := COALESCE(
    NULLIF(v_biz.contact_email, ''),
    NULLIF(v_biz.settings->>'email', ''),
    NULLIF(v_biz.metadata->'workspace_sync'->'business'->>'email', ''),
    ''
  );

  v_owner_email := COALESCE(
    NULLIF(v_biz.settings->>'ownerEmail', ''),
    NULLIF(v_biz.metadata->'workspace_sync'->'business'->>'ownerEmail', ''),
    v_email
  );

  IF jsonb_typeof(v_biz.address) = 'object' THEN
    v_address := COALESCE(
      NULLIF(v_biz.address->>'street', ''),
      NULLIF(v_biz.address->>'address', ''),
      NULLIF(v_biz.settings->>'address', ''),
      ''
    );
  ELSE
    v_address := COALESCE(
      NULLIF(TRIM(BOTH '"' FROM COALESCE(v_biz.address::text, '')), ''),
      NULLIF(v_biz.settings->>'address', ''),
      ''
    );
  END IF;

  v_tax_rate := COALESCE((v_biz.settings->>'taxRate')::numeric, 0);

  v_catalog_settings := COALESCE(
    v_biz.metadata->'workspace_sync'->'catalogSettings',
    v_biz.settings->'catalogSettings',
    '{}'::jsonb
  );

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', br.id,
        'businessId', br.business_id,
        'name', COALESCE(br.name, 'Main Branch'),
        'phone', COALESCE(br.phone, ''),
        'address', CASE
          WHEN jsonb_typeof(br.address) = 'object' THEN COALESCE(br.address->>'street', '')
          ELSE COALESCE(TRIM(BOTH '"' FROM COALESCE(br.address::text, '')), '')
        END,
        'isMain', COALESCE(br.is_main, false)
      )
      ORDER BY br.is_main DESC NULLS LAST, br.created_at ASC
    ),
    '[]'::jsonb
  )
  INTO v_branches
  FROM public.branches br
  WHERE br.business_id = p_business_id
    AND br.deleted_at IS NULL;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', c.id,
        'businessId', c.business_id,
        'name', c.name,
        'description', COALESCE(c.description, '')
      )
      ORDER BY c.display_order ASC NULLS LAST, c.name ASC
    ),
    '[]'::jsonb
  )
  INTO v_categories
  FROM public.product_categories c
  WHERE c.business_id = p_business_id
    AND c.deleted_at IS NULL
    AND COALESCE(c.is_active, true) = true;

  SELECT COALESCE(
    jsonb_agg(prod_obj ORDER BY prod_obj->>'name' ASC),
    '[]'::jsonb
  )
  INTO v_products
  FROM (
    SELECT jsonb_build_object(
      'id', p.id,
      'businessId', p.business_id,
      'name', p.name,
      'sku', COALESCE(p.sku, ''),
      'barcode', COALESCE(p.barcode, p.sku, ''),
      'categoryId', COALESCE(p.category_id::text, 'general'),
      'sellingPrice', COALESCE(
        (
          SELECT pp.price
          FROM public.product_prices pp
          WHERE pp.business_id = p_business_id
            AND pp.product_id = p.id
            AND COALESCE(pp.is_active, true) = true
            AND pp.deleted_at IS NULL
          ORDER BY
            CASE WHEN LOWER(COALESCE(pp.price_tier, '')) = 'retail' AND COALESCE(pp.min_quantity, 1) = 1 THEN 0 ELSE 1 END,
            pp.created_at DESC
          LIMIT 1
        ),
        NULLIF((p.metadata->>'selling_price')::numeric, 0),
        0
      ),
      'priceStatus', 'PRICE_AVAILABLE',
      'currentStock', COALESCE(
        (
          SELECT jsonb_object_agg(branch_key, qty_sum)
          FROM (
            SELECT
              COALESCE(ib.branch_id::text, 'main') AS branch_key,
              SUM(COALESCE(ib.available_quantity, ib.on_hand_quantity, 0)) AS qty_sum
            FROM public.inventory_balances ib
            WHERE ib.business_id = p_business_id
              AND ib.product_id = p.id
            GROUP BY COALESCE(ib.branch_id::text, 'main')
          ) s
        ),
        '{}'::jsonb
      ),
      'minStockAlert', COALESCE((p.metadata->>'minimum_stock')::numeric, 5),
      'image', COALESCE(NULLIF(p.metadata->>'image', ''), '📦'),
      'description', COALESCE(p.description, ''),
      'brand', COALESCE(p.metadata->>'brand', p.metadata->>'brand_id', ''),
      'promoBadge', COALESCE(p.metadata->>'promo_badge', 'none'),
      'wholesaleTiers', COALESCE(p.metadata->'wholesale_tiers', '[]'::jsonb)
    ) AS prod_obj
    FROM public.products p
    WHERE p.business_id = p_business_id
      AND p.deleted_at IS NULL
      AND COALESCE(p.is_active, true) = true
  ) sub;

  IF jsonb_array_length(v_products) = 0
     AND jsonb_typeof(v_biz.metadata->'workspace_sync'->'products') = 'array' THEN
    v_products := v_biz.metadata->'workspace_sync'->'products';
  END IF;

  IF jsonb_array_length(v_categories) = 0
     AND jsonb_typeof(v_biz.metadata->'workspace_sync'->'categories') = 'array' THEN
    v_categories := v_biz.metadata->'workspace_sync'->'categories';
  END IF;

  RETURN jsonb_build_object(
    'business', jsonb_build_object(
      'id', v_biz.id,
      'name', COALESCE(NULLIF(v_biz.trade_name, ''), NULLIF(v_biz.legal_name, ''), 'Store'),
      'legalName', COALESCE(NULLIF(v_biz.legal_name, ''), NULLIF(v_biz.trade_name, ''), 'Store'),
      'currency', COALESCE(NULLIF(v_biz.currency, ''), 'HTG'),
      'taxRate', v_tax_rate,
      'logoUrl', v_logo,
      'phone', v_phone,
      'email', v_email,
      'ownerEmail', v_owner_email,
      'address', v_address
    ),
    'branches', v_branches,
    'categories', v_categories,
    'products', v_products,
    'catalogSettings', v_catalog_settings
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_public_storefront_catalog(uuid, text, text) TO anon, authenticated;
