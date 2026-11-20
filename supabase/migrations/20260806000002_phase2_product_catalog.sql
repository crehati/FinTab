-- ============================================================================
-- FinTab Enterprise OS — Phase 2 Supabase Migration
-- Module: Enterprise Product Catalog Engine
-- Tables:
--   1. product_categories
--   2. product_brands
--   3. units_of_measure
--   4. suppliers
--   5. supplier_products
--   6. products
--   7. product_prices
--   8. product_images
--   9. product_variants
--  10. product_attributes
--  11. product_attribute_values
--  12. product_bundles
--  13. product_bundle_items
--  14. product_barcodes
-- Date: 2026-08-06
-- ============================================================================

-- Ensure uuid-ossp extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ----------------------------------------------------------------------------
-- 1. PRODUCT CATEGORIES (Nested Categories Support)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    parent_id UUID REFERENCES public.product_categories(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    slug TEXT,
    description TEXT,
    display_order INT NOT NULL DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT true,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_product_categories_updated_at
    BEFORE UPDATE ON public.product_categories
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 2. PRODUCT BRANDS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_brands (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    code TEXT,
    logo_url TEXT,
    website TEXT,
    is_active BOOLEAN NOT NULL DEFAULT true,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_product_brands_updated_at
    BEFORE UPDATE ON public.product_brands
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 3. UNITS OF MEASURE (UOM)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.units_of_measure (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    symbol TEXT NOT NULL,
    precision_digits INT NOT NULL DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT true,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_units_of_measure_updated_at
    BEFORE UPDATE ON public.units_of_measure
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 4. SUPPLIERS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.suppliers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    contact_name TEXT,
    email TEXT,
    phone TEXT,
    address TEXT,
    tax_id TEXT,
    payment_terms TEXT,
    is_active BOOLEAN NOT NULL DEFAULT true,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_suppliers_updated_at
    BEFORE UPDATE ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 5. PRODUCTS (Catalog Foundation - NO inventory/stock/profit/revenue stored)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    category_id UUID REFERENCES public.product_categories(id) ON DELETE SET NULL,
    brand_id UUID REFERENCES public.product_brands(id) ON DELETE SET NULL,
    uom_id UUID REFERENCES public.units_of_measure(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    sku TEXT,
    description TEXT,
    product_type TEXT NOT NULL DEFAULT 'standard' CHECK (product_type IN ('standard', 'variant_parent', 'bundle', 'service')),
    is_active BOOLEAN NOT NULL DEFAULT true,
    ai_recommendation_tags JSONB NOT NULL DEFAULT '[]'::jsonb,
    ai_embedding JSONB NOT NULL DEFAULT '{}'::jsonb,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_products_updated_at
    BEFORE UPDATE ON public.products
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 6. SUPPLIER PRODUCTS (Unlimited Suppliers per product)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.supplier_products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    supplier_id UUID NOT NULL REFERENCES public.suppliers(id) ON DELETE CASCADE,
    supplier_sku TEXT,
    cost_price NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    currency TEXT NOT NULL DEFAULT 'USD',
    is_primary BOOLEAN NOT NULL DEFAULT false,
    lead_time_days INT DEFAULT 0,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_supplier_products_updated_at
    BEFORE UPDATE ON public.supplier_products
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 7. PRODUCT PRICES (Unlimited Selling Prices)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_prices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    price_list_name TEXT NOT NULL DEFAULT 'Retail',
    price NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    currency TEXT NOT NULL DEFAULT 'USD',
    min_quantity NUMERIC(15, 4) NOT NULL DEFAULT 1.0000,
    valid_from TIMESTAMPTZ,
    valid_to TIMESTAMPTZ,
    is_active BOOLEAN NOT NULL DEFAULT true,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_product_prices_updated_at
    BEFORE UPDATE ON public.product_prices
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 8. PRODUCT IMAGES (Unlimited Images)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_images (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    url TEXT NOT NULL,
    alt_text TEXT,
    display_order INT NOT NULL DEFAULT 0,
    is_primary BOOLEAN NOT NULL DEFAULT false,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_product_images_updated_at
    BEFORE UPDATE ON public.product_images
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 9. PRODUCT VARIANTS (Unlimited Variants)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_variants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    parent_product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    sku TEXT,
    variant_name TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_product_variants_updated_at
    BEFORE UPDATE ON public.product_variants
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 10. PRODUCT ATTRIBUTES
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_attributes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    code TEXT,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_product_attributes_updated_at
    BEFORE UPDATE ON public.product_attributes
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 11. PRODUCT ATTRIBUTE VALUES
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_attribute_values (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    attribute_id UUID NOT NULL REFERENCES public.product_attributes(id) ON DELETE CASCADE,
    variant_id UUID REFERENCES public.product_variants(id) ON DELETE CASCADE,
    product_id UUID REFERENCES public.products(id) ON DELETE CASCADE,
    value TEXT NOT NULL,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_product_attribute_values_updated_at
    BEFORE UPDATE ON public.product_attribute_values
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 12. PRODUCT BUNDLES
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_bundles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    bundle_product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    discount_percentage NUMERIC(5, 2) NOT NULL DEFAULT 0.00,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_product_bundles_updated_at
    BEFORE UPDATE ON public.product_bundles
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 13. PRODUCT BUNDLE ITEMS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_bundle_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    bundle_id UUID NOT NULL REFERENCES public.product_bundles(id) ON DELETE CASCADE,
    component_product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    quantity NUMERIC(15, 4) NOT NULL DEFAULT 1.0000,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_product_bundle_items_updated_at
    BEFORE UPDATE ON public.product_bundle_items
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 14. PRODUCT BARCODES (Unlimited Barcodes)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_barcodes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    variant_id UUID REFERENCES public.product_variants(id) ON DELETE CASCADE,
    barcode TEXT NOT NULL,
    barcode_type TEXT NOT NULL DEFAULT 'EAN13' CHECK (barcode_type IN ('EAN13', 'UPC', 'CODE128', 'QR', 'CUSTOM')),
    is_primary BOOLEAN NOT NULL DEFAULT false,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_product_barcodes_updated_at
    BEFORE UPDATE ON public.product_barcodes
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ============================================================================
-- INDEXES FOR TENANT ISOLATION & OPTIMIZED LOOKUPS
-- ============================================================================

CREATE INDEX idx_product_categories_biz ON public.product_categories(business_id, deleted_at);
CREATE INDEX idx_product_categories_parent ON public.product_categories(parent_id);

CREATE INDEX idx_product_brands_biz ON public.product_brands(business_id, deleted_at);

CREATE INDEX idx_units_of_measure_biz ON public.units_of_measure(business_id, deleted_at);

CREATE INDEX idx_suppliers_biz ON public.suppliers(business_id, deleted_at);

CREATE INDEX idx_products_biz ON public.products(business_id, deleted_at);
CREATE INDEX idx_products_cat ON public.products(category_id);
CREATE INDEX idx_products_brand ON public.products(brand_id);
CREATE INDEX idx_products_sku ON public.products(business_id, sku);

CREATE INDEX idx_supplier_products_biz ON public.supplier_products(business_id, deleted_at);
CREATE INDEX idx_supplier_products_prod ON public.supplier_products(product_id);
CREATE INDEX idx_supplier_products_supp ON public.supplier_products(supplier_id);

CREATE INDEX idx_product_prices_biz ON public.product_prices(business_id, deleted_at);
CREATE INDEX idx_product_prices_prod ON public.product_prices(product_id);

CREATE INDEX idx_product_images_biz ON public.product_images(business_id, deleted_at);
CREATE INDEX idx_product_images_prod ON public.product_images(product_id);

CREATE INDEX idx_product_variants_biz ON public.product_variants(business_id, deleted_at);
CREATE INDEX idx_product_variants_parent ON public.product_variants(parent_product_id);

CREATE INDEX idx_product_attributes_biz ON public.product_attributes(business_id, deleted_at);

CREATE INDEX idx_product_attr_vals_biz ON public.product_attribute_values(business_id, deleted_at);
CREATE INDEX idx_product_attr_vals_attr ON public.product_attribute_values(attribute_id);
CREATE INDEX idx_product_attr_vals_variant ON public.product_attribute_values(variant_id);

CREATE INDEX idx_product_bundles_biz ON public.product_bundles(business_id, deleted_at);

CREATE INDEX idx_product_bundle_items_biz ON public.product_bundle_items(business_id, deleted_at);
CREATE INDEX idx_product_bundle_items_bundle ON public.product_bundle_items(bundle_id);

CREATE INDEX idx_product_barcodes_biz ON public.product_barcodes(business_id, deleted_at);
CREATE INDEX idx_product_barcodes_code ON public.product_barcodes(business_id, barcode);

-- ============================================================================
-- SUPABASE ROW LEVEL SECURITY (RLS) POLICIES
-- ============================================================================

DO $$
DECLARE
    tbl text;
    tables text[] := ARRAY[
        'product_categories',
        'product_brands',
        'units_of_measure',
        'suppliers',
        'supplier_products',
        'products',
        'product_prices',
        'product_images',
        'product_variants',
        'product_attributes',
        'product_attribute_values',
        'product_bundles',
        'product_bundle_items',
        'product_barcodes'
    ];
BEGIN
    FOREACH tbl IN ARRAY tables LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', tbl);
        
        EXECUTE format('
            CREATE POLICY %I_tenant_isolation ON public.%I
                FOR ALL
                USING (
                    business_id IN (
                        SELECT business_id FROM public.business_memberships
                        WHERE user_id = auth.uid() AND status = ''active''
                    )
                )
                WITH CHECK (
                    business_id IN (
                        SELECT business_id FROM public.business_memberships
                        WHERE user_id = auth.uid() AND status = ''active''
                    )
                );
        ', tbl, tbl);
    END LOOP;
END $$;
