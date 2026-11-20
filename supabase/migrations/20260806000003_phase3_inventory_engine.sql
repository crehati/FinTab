-- ============================================================================
-- FinTab Enterprise OS — Phase 3 Supabase Migration
-- Module: Enterprise Inventory Management Engine
-- Tables / Views:
--   1. inventory_locations (Nested warehouse locations)
--   2. inventory_batches (Batch and Expiration tracking)
--   3. serial_numbers (Serial number tracking)
--   4. inventory_movements (Immutable inventory ledger)
--   5. inventory_balance (Calculated SQL View)
--   6. inventory_adjustments (Stock adjustments)
--   7. inventory_transfers (Transfer workflow)
--   8. inventory_transfer_items (Transfer line items)
--   9. inventory_reservations (Reservation engine)
-- Date: 2026-08-06
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ----------------------------------------------------------------------------
-- 1. INVENTORY LOCATIONS (Nested Warehouse Locations)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_locations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    parent_id UUID REFERENCES public.inventory_locations(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    code TEXT,
    location_type TEXT NOT NULL DEFAULT 'warehouse' CHECK (location_type IN ('warehouse', 'zone', 'aisle', 'shelf', 'bin', 'transit', 'virtual')),
    address TEXT,
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

CREATE TRIGGER trg_inventory_locations_updated_at
    BEFORE UPDATE ON public.inventory_locations
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 2. INVENTORY BATCHES (Batch & Expiration Tracking)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_batches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    batch_number TEXT NOT NULL,
    mfg_date TIMESTAMPTZ,
    expiry_date TIMESTAMPTZ,
    cost_per_unit NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_inventory_batches_updated_at
    BEFORE UPDATE ON public.inventory_batches
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 3. SERIAL NUMBERS (Item Level Serialization)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.serial_numbers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    batch_id UUID REFERENCES public.inventory_batches(id) ON DELETE SET NULL,
    current_location_id UUID REFERENCES public.inventory_locations(id) ON DELETE SET NULL,
    serial_number TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'available' CHECK (status IN ('available', 'reserved', 'sold', 'in_transit', 'damaged', 'returned', 'decommissioned')),
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_serial_numbers_updated_at
    BEFORE UPDATE ON public.serial_numbers
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 4. INVENTORY MOVEMENTS (Immutable Inventory Ledger)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_movements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    location_id UUID NOT NULL REFERENCES public.inventory_locations(id) ON DELETE RESTRICT,
    batch_id UUID REFERENCES public.inventory_batches(id) ON DELETE SET NULL,
    serial_number_id UUID REFERENCES public.serial_numbers(id) ON DELETE SET NULL,
    movement_type TEXT NOT NULL CHECK (movement_type IN ('IN', 'OUT', 'TRANSFER_IN', 'TRANSFER_OUT', 'ADJUSTMENT_IN', 'ADJUSTMENT_OUT', 'RESERVATION', 'UNRESERVATION', 'INITIAL_STAGING')),
    quantity NUMERIC(15, 4) NOT NULL,
    unit_cost NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    cost_method TEXT NOT NULL DEFAULT 'FIFO' CHECK (cost_method IN ('FIFO', 'LIFO', 'WEIGHTED_AVG', 'SPECIFIC_ID')),
    reference_type TEXT,
    reference_id UUID,
    notes TEXT,
    ai_anomaly_score NUMERIC(5, 4) NOT NULL DEFAULT 0.0000,
    ai_analysis_tags JSONB NOT NULL DEFAULT '[]'::jsonb,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

-- ----------------------------------------------------------------------------
-- 5. INVENTORY BALANCE (Calculated SQL View)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.inventory_balance AS
SELECT
    business_id,
    product_id,
    location_id,
    batch_id,
    COALESCE(SUM(quantity), 0) AS on_hand_quantity,
    COALESCE(SUM(quantity * unit_cost), 0) AS total_value,
    MAX(created_at) AS last_movement_at
FROM public.inventory_movements
GROUP BY business_id, product_id, location_id, batch_id;

-- ----------------------------------------------------------------------------
-- 6. INVENTORY ADJUSTMENTS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_adjustments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    location_id UUID NOT NULL REFERENCES public.inventory_locations(id) ON DELETE RESTRICT,
    adjustment_number TEXT NOT NULL,
    reason TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'pending_approval', 'approved', 'rejected', 'cancelled')),
    approved_by UUID REFERENCES public.user_profiles(id),
    approved_at TIMESTAMPTZ,
    notes TEXT,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_inventory_adjustments_updated_at
    BEFORE UPDATE ON public.inventory_adjustments
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 7. INVENTORY TRANSFERS (Transfer Workflow: Pending -> Approved -> Shipped -> Received)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_transfers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    transfer_number TEXT NOT NULL,
    from_location_id UUID NOT NULL REFERENCES public.inventory_locations(id) ON DELETE RESTRICT,
    to_location_id UUID NOT NULL REFERENCES public.inventory_locations(id) ON DELETE RESTRICT,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'shipped', 'received', 'cancelled')),
    notes TEXT,
    approved_at TIMESTAMPTZ,
    shipped_at TIMESTAMPTZ,
    received_at TIMESTAMPTZ,
    approved_by UUID REFERENCES public.user_profiles(id),
    shipped_by UUID REFERENCES public.user_profiles(id),
    received_by UUID REFERENCES public.user_profiles(id),
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_inventory_transfers_updated_at
    BEFORE UPDATE ON public.inventory_transfers
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 8. INVENTORY TRANSFER ITEMS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_transfer_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    transfer_id UUID NOT NULL REFERENCES public.inventory_transfers(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    batch_id UUID REFERENCES public.inventory_batches(id) ON DELETE SET NULL,
    requested_quantity NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    shipped_quantity NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    received_quantity NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    unit_cost NUMERIC(15, 4) NOT NULL DEFAULT 0.0000,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_inventory_transfer_items_updated_at
    BEFORE UPDATE ON public.inventory_transfer_items
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ----------------------------------------------------------------------------
-- 9. INVENTORY RESERVATIONS (Reservation Engine)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_reservations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    location_id UUID NOT NULL REFERENCES public.inventory_locations(id) ON DELETE RESTRICT,
    batch_id UUID REFERENCES public.inventory_batches(id) ON DELETE SET NULL,
    serial_number_id UUID REFERENCES public.serial_numbers(id) ON DELETE SET NULL,
    reserved_quantity NUMERIC(15, 4) NOT NULL DEFAULT 1.0000,
    reference_type TEXT,
    reference_id UUID,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'fulfilled', 'cancelled', 'expired')),
    expires_at TIMESTAMPTZ,
    version INT NOT NULL DEFAULT 1,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ DEFAULT NULL,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TRIGGER trg_inventory_reservations_updated_at
    BEFORE UPDATE ON public.inventory_reservations
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- ============================================================================
-- INDEXES FOR TENANT ISOLATION & OPTIMIZED LOOKUPS
-- ============================================================================

CREATE INDEX idx_inventory_locations_biz ON public.inventory_locations(business_id, deleted_at);
CREATE INDEX idx_inventory_locations_parent ON public.inventory_locations(parent_id);

CREATE INDEX idx_inventory_batches_biz ON public.inventory_batches(business_id, deleted_at);
CREATE INDEX idx_inventory_batches_prod ON public.inventory_batches(product_id);
CREATE INDEX idx_inventory_batches_num ON public.inventory_batches(business_id, batch_number);

CREATE INDEX idx_serial_numbers_biz ON public.serial_numbers(business_id, deleted_at);
CREATE INDEX idx_serial_numbers_prod ON public.serial_numbers(product_id);
CREATE INDEX idx_serial_numbers_num ON public.serial_numbers(business_id, serial_number);
CREATE INDEX idx_serial_numbers_loc ON public.serial_numbers(current_location_id);

CREATE INDEX idx_inventory_movements_biz ON public.inventory_movements(business_id);
CREATE INDEX idx_inventory_movements_prod_loc ON public.inventory_movements(business_id, product_id, location_id);
CREATE INDEX idx_inventory_movements_batch ON public.inventory_movements(batch_id);
CREATE INDEX idx_inventory_movements_serial ON public.inventory_movements(serial_number_id);

CREATE INDEX idx_inventory_adjustments_biz ON public.inventory_adjustments(business_id, deleted_at);
CREATE INDEX idx_inventory_adjustments_loc ON public.inventory_adjustments(location_id);

CREATE INDEX idx_inventory_transfers_biz ON public.inventory_transfers(business_id, deleted_at);
CREATE INDEX idx_inventory_transfers_from ON public.inventory_transfers(from_location_id);
CREATE INDEX idx_inventory_transfers_to ON public.inventory_transfers(to_location_id);

CREATE INDEX idx_inventory_transfer_items_biz ON public.inventory_transfer_items(business_id, deleted_at);
CREATE INDEX idx_inventory_transfer_items_transfer ON public.inventory_transfer_items(transfer_id);

CREATE INDEX idx_inventory_reservations_biz ON public.inventory_reservations(business_id, deleted_at);
CREATE INDEX idx_inventory_reservations_prod_loc ON public.inventory_reservations(product_id, location_id);

-- ============================================================================
-- SUPABASE ROW LEVEL SECURITY (RLS) POLICIES
-- ============================================================================

DO $$
DECLARE
    tbl text;
    tables text[] := ARRAY[
        'inventory_locations',
        'inventory_batches',
        'serial_numbers',
        'inventory_movements',
        'inventory_adjustments',
        'inventory_transfers',
        'inventory_transfer_items',
        'inventory_reservations'
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
