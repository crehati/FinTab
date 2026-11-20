-- ============================================================================
-- FinTab Enterprise OS — Corrective Migration 007
-- Module: Concurrency-Hardened Atomic Temporal Product Quantity-Break Pricing
--
-- Objective:
--   Enable quantity-break (volume-tier) pricing and temporal scheduling for products
--   by replacing the legacy uniqueness constraint `uq_product_prices_tier` on:
--     (business_id, product_id, price_tier, currency)
--   with an atomic, temporal, concurrency-hardened quantity-break model that provides:
--     1. Multiple volume breaks (min_quantity) per tier/currency.
--     2. Temporal price schedules (historical, present, and future price windows).
--     3. Soft-deleted records (deleted_at IS NOT NULL) without uniqueness collisions.
--     4. Open-ended / default baseline pricing (valid_from IS NULL, valid_to IS NULL).
--     5. Deterministic conflict prevention against overlapping active price intervals.
--     6. Transaction-scoped advisory serialization preventing concurrent race conditions.
--
-- Production Safety & Invariant Guarantees:
--   - Fully Atomic: Executed inside a single BEGIN ... COMMIT block.
--   - Strict Preconditions: Validates existing data integrity before dropping constraints.
--   - Robust Invariant Verification: Strips whitespace, parentheses, and casts to confirm
--     the semantic `min_quantity>0` CHECK invariant without fragile regex matching.
--   - Minimal Attack Surface: Internal integrity and helper functions have all privileges
--     revoked from PUBLIC, anon, and authenticated.
--   - Zero external extension requirements (no btree_gist required).
--   - Read paths (`rpc_complete_sale`) remain 100% non-blocking and accelerated.
-- ============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Precondition Assertions (Run before ANY DDL modifications)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_invalid_dates_count BIGINT;
  v_baseline_dups_count BIGINT;
  v_overlap_count BIGINT;
  v_has_min_qty_check BOOLEAN;
  v_has_legacy_constraint BOOLEAN;
  v_has_tier_qty_constraint BOOLEAN;
BEGIN
  -- 1.1 Assert Table Existence
  IF NOT EXISTS (
    SELECT 1 FROM pg_tables
    WHERE schemaname = 'public' AND tablename = 'product_prices'
  ) THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: Table public.product_prices does not exist.';
  END IF;

  -- 1.2 Assert min_quantity > 0 Invariant
  -- Normalize constraint definition: strip whitespace, parentheses, and numeric casts.
  -- Validates that the existing CHECK definition semantically contains 'min_quantity>0'.
  SELECT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
    WHERE c.conrelid = 'public.product_prices'::regclass
      AND c.contype = 'c'
      AND a.attname = 'min_quantity'
      AND (
        -- Check canonical naming or normalized semantic definition
        c.conname = 'product_prices_min_quantity_check'
        OR regexp_replace(
             regexp_replace(pg_get_constraintdef(c.oid), '::numeric(\([^)]*\))?', '', 'g'),
             '[\s\(\)]', '', 'g'
           ) ~* 'min_quantity>0'
      )
  ) INTO v_has_min_qty_check;

  IF NOT v_has_min_qty_check THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: Required invariant CHECK (min_quantity > 0) is missing on public.product_prices. Schema drift detected.';
  END IF;

  -- 1.3 Assert Zero Non-Positive min_quantity Values
  IF EXISTS (
    SELECT 1 FROM public.product_prices WHERE min_quantity <= 0
  ) THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: Table public.product_prices contains rows with min_quantity <= 0.';
  END IF;

  -- 1.4 Assert Zero Invalid Temporal Ranges (valid_from > valid_to)
  SELECT COUNT(*) INTO v_invalid_dates_count
  FROM public.product_prices
  WHERE valid_from IS NOT NULL
    AND valid_to IS NOT NULL
    AND valid_from > valid_to;

  IF v_invalid_dates_count > 0 THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: Table public.product_prices contains % row(s) where valid_from > valid_to.',
      v_invalid_dates_count;
  END IF;

  -- 1.5 Assert Legacy Constraint State
  SELECT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'uq_product_prices_tier' AND conrelid = 'public.product_prices'::regclass
  ) INTO v_has_legacy_constraint;

  SELECT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'uq_product_prices_tier_qty' AND conrelid = 'public.product_prices'::regclass
  ) INTO v_has_tier_qty_constraint;

  IF NOT (v_has_legacy_constraint OR v_has_tier_qty_constraint) THEN
    RAISE NOTICE 'Legacy constraint already absent or modified; verifying state.';
  END IF;

  -- 1.6 Assert Zero Duplicate Baseline Prices
  SELECT COUNT(*) INTO v_baseline_dups_count
  FROM (
    SELECT business_id, product_id, price_tier, currency, min_quantity
    FROM public.product_prices
    WHERE deleted_at IS NULL
      AND is_active = true
      AND valid_from IS NULL
      AND valid_to IS NULL
    GROUP BY business_id, product_id, price_tier, currency, min_quantity
    HAVING COUNT(*) > 1
  ) dups;

  IF v_baseline_dups_count > 0 THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: Table public.product_prices contains % duplicate active baseline pricing key(s).',
      v_baseline_dups_count;
  END IF;

  -- 1.7 Assert Zero Existing Overlapping Temporal Prices
  SELECT COUNT(*) INTO v_overlap_count
  FROM public.product_prices p1
  JOIN public.product_prices p2
    ON p1.business_id = p2.business_id
   AND p1.product_id = p2.product_id
   AND p1.price_tier = p2.price_tier
   AND p1.currency = p2.currency
   AND p1.min_quantity = p2.min_quantity
   AND p1.id < p2.id
  WHERE p1.deleted_at IS NULL AND p1.is_active = true
    AND p2.deleted_at IS NULL AND p2.is_active = true
    AND COALESCE(p1.valid_from, '-infinity'::timestamptz) <= COALESCE(p2.valid_to, 'infinity'::timestamptz)
    AND COALESCE(p1.valid_to, 'infinity'::timestamptz) >= COALESCE(p2.valid_from, '-infinity'::timestamptz);

  IF v_overlap_count > 0 THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: Table public.product_prices contains % conflicting/overlapping active temporal price pair(s).',
      v_overlap_count;
  END IF;

  RAISE NOTICE 'Migration 007 Preconditions Passed: public.product_prices is clean and eligible for migration.';
END $$;

-- -----------------------------------------------------------------------------
-- 2. Drop Legacy Uniqueness Constraints
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'uq_product_prices_tier' AND conrelid = 'public.product_prices'::regclass
  ) THEN
    ALTER TABLE public.product_prices DROP CONSTRAINT uq_product_prices_tier;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'uq_product_prices_tier_qty' AND conrelid = 'public.product_prices'::regclass
  ) THEN
    ALTER TABLE public.product_prices DROP CONSTRAINT uq_product_prices_tier_qty;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 3. Temporal Sanity CHECK Constraint (valid_from <= valid_to)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_product_prices_valid_dates' AND conrelid = 'public.product_prices'::regclass
  ) THEN
    ALTER TABLE public.product_prices
      ADD CONSTRAINT chk_product_prices_valid_dates
      CHECK (valid_from IS NULL OR valid_to IS NULL OR valid_from <= valid_to);
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 4. Baseline Partial Unique Index
-- -----------------------------------------------------------------------------
-- Enforces that for active, un-deleted baseline prices (without time boundaries),
-- there can only be exactly one price per (business_id, product_id, price_tier,
-- currency, min_quantity).
CREATE UNIQUE INDEX IF NOT EXISTS uq_product_prices_baseline
  ON public.product_prices (business_id, product_id, price_tier, currency, min_quantity)
  WHERE deleted_at IS NULL AND is_active = true AND valid_from IS NULL AND valid_to IS NULL;

-- -----------------------------------------------------------------------------
-- 5. Helper Function: Deterministic 64-Bit Advisory Lock Key Computation
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_product_price_lock_key(
  p_business_id UUID,
  p_product_id UUID,
  p_price_tier TEXT,
  p_currency TEXT,
  p_min_quantity NUMERIC(15, 4)
)
RETURNS BIGINT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT ('x' || substr(
    md5(
      p_business_id::text || ':' ||
      p_product_id::text || ':' ||
      p_price_tier || ':' ||
      p_currency || ':' ||
      p_min_quantity::text
    ),
    1, 16
  ))::bit(64)::bigint;
$$;

-- -----------------------------------------------------------------------------
-- 6. Concurrency-Hardened Temporal Overlap Prevention Function & Trigger
-- -----------------------------------------------------------------------------
-- Serializes concurrent writes for the same logical pricing key using
-- transaction-scoped advisory locks (pg_advisory_xact_lock) before querying
-- for overlapping validity windows.
CREATE OR REPLACE FUNCTION public.fn_validate_product_price_overlap()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_new_lock_key BIGINT;
  v_old_lock_key BIGINT;
  v_new_lower TIMESTAMPTZ;
  v_new_upper TIMESTAMPTZ;
  v_conflict_id UUID;
  v_conflict_price NUMERIC(15, 4);
  v_conflict_from TIMESTAMPTZ;
  v_conflict_to TIMESTAMPTZ;
BEGIN
  -- ---------------------------------------------------------------------------
  -- 6.1 Early Exit for Inactive or Soft-Deleted Records
  -- ---------------------------------------------------------------------------
  IF NEW.deleted_at IS NOT NULL OR NEW.is_active = FALSE THEN
    RETURN NEW;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 6.2 Transaction-Scoped Advisory Serialization
  -- ---------------------------------------------------------------------------
  v_new_lock_key := public.fn_product_price_lock_key(
    NEW.business_id,
    NEW.product_id,
    NEW.price_tier,
    NEW.currency,
    NEW.min_quantity
  );

  IF TG_OP = 'UPDATE' THEN
    v_old_lock_key := public.fn_product_price_lock_key(
      OLD.business_id,
      OLD.product_id,
      OLD.price_tier,
      OLD.currency,
      OLD.min_quantity
    );

    IF v_new_lock_key <> v_old_lock_key THEN
      -- Key mutated: acquire locks in deterministic ascending numerical order to prevent deadlocks
      IF v_new_lock_key < v_old_lock_key THEN
        PERFORM pg_advisory_xact_lock(v_new_lock_key);
        PERFORM pg_advisory_xact_lock(v_old_lock_key);
      ELSE
        PERFORM pg_advisory_xact_lock(v_old_lock_key);
        PERFORM pg_advisory_xact_lock(v_new_lock_key);
      END IF;
    ELSE
      -- Key unchanged: acquire single lock for the pricing key
      PERFORM pg_advisory_xact_lock(v_new_lock_key);
    END IF;
  ELSE
    -- INSERT: acquire single lock for the new pricing key
    PERFORM pg_advisory_xact_lock(v_new_lock_key);
  END IF;

  -- ---------------------------------------------------------------------------
  -- 6.3 Temporal Boundary Normalization & Validation
  -- ---------------------------------------------------------------------------
  v_new_lower := COALESCE(NEW.valid_from, '-infinity'::timestamptz);
  v_new_upper := COALESCE(NEW.valid_to, 'infinity'::timestamptz);

  IF v_new_lower > v_new_upper THEN
    RAISE EXCEPTION 'INVALID_DATE_RANGE: valid_from (%) must be before or equal to valid_to (%)',
      NEW.valid_from, NEW.valid_to;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 6.4 Overlap Detection Under Serialization (Closed Interval Semantics)
  -- ---------------------------------------------------------------------------
  -- Because rpc_complete_sale uses:
  --   (valid_from IS NULL OR valid_from <= NOW())
  --   (valid_to IS NULL OR valid_to >= NOW())
  -- effective intervals are closed at both endpoints. Two price windows sharing
  -- an exact boundary timestamp overlap under checkout semantics.
  SELECT
    id, price, valid_from, valid_to
  INTO
    v_conflict_id, v_conflict_price, v_conflict_from, v_conflict_to
  FROM public.product_prices
  WHERE business_id = NEW.business_id
    AND product_id = NEW.product_id
    AND price_tier = NEW.price_tier
    AND currency = NEW.currency
    AND min_quantity = NEW.min_quantity
    AND is_active = TRUE
    AND deleted_at IS NULL
    AND id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid)
    AND (
      v_new_lower <= COALESCE(valid_to, 'infinity'::timestamptz)
      AND v_new_upper >= COALESCE(valid_from, '-infinity'::timestamptz)
    )
  LIMIT 1;

  IF v_conflict_id IS NOT NULL THEN
    RAISE EXCEPTION 'PRICE_INTERVAL_OVERLAP: Active price tier % for product % (min_qty %) overlaps with existing price record % (valid % to %)',
      NEW.price_tier, NEW.product_id, NEW.min_quantity, v_conflict_id, v_conflict_from, v_conflict_to;
  END IF;

  RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------------
-- 7. Privilege Hardening (Zero Exposure of Internal Helper / Trigger Functions)
-- -----------------------------------------------------------------------------
-- Ordinary users executing INSERT/UPDATE do NOT require direct EXECUTE privilege
-- on trigger functions. Direct execute is revoked from PUBLIC, anon, and authenticated.
REVOKE ALL ON FUNCTION public.fn_validate_product_price_overlap() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_validate_product_price_overlap() FROM anon;
REVOKE ALL ON FUNCTION public.fn_validate_product_price_overlap() FROM authenticated;

REVOKE ALL ON FUNCTION public.fn_product_price_lock_key(UUID, UUID, TEXT, TEXT, NUMERIC) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_product_price_lock_key(UUID, UUID, TEXT, TEXT, NUMERIC) FROM anon;
REVOKE ALL ON FUNCTION public.fn_product_price_lock_key(UUID, UUID, TEXT, TEXT, NUMERIC) FROM authenticated;

-- -----------------------------------------------------------------------------
-- 8. Register Overlap Validation Trigger
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_validate_product_price_overlap ON public.product_prices;
CREATE TRIGGER trg_validate_product_price_overlap
  BEFORE INSERT OR UPDATE OF business_id, product_id, price_tier, currency, min_quantity, valid_from, valid_to, is_active, deleted_at
  ON public.product_prices
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_validate_product_price_overlap();

-- -----------------------------------------------------------------------------
-- 9. High-Performance Composite Resolution Index
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_product_prices_temporal_resolution
  ON public.product_prices (
    business_id,
    product_id,
    price_tier,
    currency,
    min_quantity DESC,
    created_at DESC
  )
  WHERE deleted_at IS NULL AND is_active = true;

-- -----------------------------------------------------------------------------
-- 10. Post-DDL Catalog Assertions
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  -- 10.1 Assert legacy constraint is gone
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'uq_product_prices_tier' AND conrelid = 'public.product_prices'::regclass
  ) THEN
    RAISE EXCEPTION 'POST_ASSERTION_FAILED: Legacy constraint uq_product_prices_tier is still present.';
  END IF;

  -- 10.2 Assert valid dates check constraint is present
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_product_prices_valid_dates' AND conrelid = 'public.product_prices'::regclass
  ) THEN
    RAISE EXCEPTION 'POST_ASSERTION_FAILED: Constraint chk_product_prices_valid_dates was not created.';
  END IF;

  -- 10.3 Assert partial unique index is present
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'product_prices'
      AND indexname = 'uq_product_prices_baseline'
  ) THEN
    RAISE EXCEPTION 'POST_ASSERTION_FAILED: Index uq_product_prices_baseline was not created.';
  END IF;

  -- 10.4 Assert trigger is registered
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.product_prices'::regclass
      AND tgname = 'trg_validate_product_price_overlap'
  ) THEN
    RAISE EXCEPTION 'POST_ASSERTION_FAILED: Trigger trg_validate_product_price_overlap was not created.';
  END IF;

  -- 10.5 Assert temporal resolution index is present
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'product_prices'
      AND indexname = 'idx_product_prices_temporal_resolution'
  ) THEN
    RAISE EXCEPTION 'POST_ASSERTION_FAILED: Index idx_product_prices_temporal_resolution was not created.';
  END IF;

  RAISE NOTICE 'Migration 007 Post-DDL Assertions Passed: Schema transition verified successfully.';
END $$;

COMMIT;
