-- ============================================================================
-- FinTab Enterprise OS — Phase 2 Rollback Migration
-- Module: Enterprise Product Catalog Engine Rollback
-- ============================================================================

DROP TABLE IF EXISTS public.product_barcodes CASCADE;
DROP TABLE IF EXISTS public.product_bundle_items CASCADE;
DROP TABLE IF EXISTS public.product_bundles CASCADE;
DROP TABLE IF EXISTS public.product_attribute_values CASCADE;
DROP TABLE IF EXISTS public.product_attributes CASCADE;
DROP TABLE IF EXISTS public.product_variants CASCADE;
DROP TABLE IF EXISTS public.product_images CASCADE;
DROP TABLE IF EXISTS public.product_prices CASCADE;
DROP TABLE IF EXISTS public.supplier_products CASCADE;
DROP TABLE IF EXISTS public.products CASCADE;
DROP TABLE IF EXISTS public.suppliers CASCADE;
DROP TABLE IF EXISTS public.units_of_measure CASCADE;
DROP TABLE IF EXISTS public.product_brands CASCADE;
DROP TABLE IF EXISTS public.product_categories CASCADE;
