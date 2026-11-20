-- ============================================================================
-- FinTab Enterprise OS — Phase 3 Rollback Migration
-- Module: Enterprise Inventory Management Engine Rollback
-- ============================================================================

DROP VIEW IF EXISTS public.inventory_balance CASCADE;

DROP TABLE IF EXISTS public.inventory_reservations CASCADE;
DROP TABLE IF EXISTS public.inventory_transfer_items CASCADE;
DROP TABLE IF EXISTS public.inventory_transfers CASCADE;
DROP TABLE IF EXISTS public.inventory_adjustments CASCADE;
DROP TABLE IF EXISTS public.inventory_movements CASCADE;
DROP TABLE IF EXISTS public.serial_numbers CASCADE;
DROP TABLE IF EXISTS public.inventory_batches CASCADE;
DROP TABLE IF EXISTS public.inventory_locations CASCADE;
