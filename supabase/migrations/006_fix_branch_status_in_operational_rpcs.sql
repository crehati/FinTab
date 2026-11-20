-- ============================================================================
-- FinTab Enterprise OS — Corrective Migration 006
-- Module: Operational RPCs Branch Status Compatibility Fix
--
-- Root Cause:
--   In public.branches, the lifecycle active status is determined by
--   status = 'active'. There is no 'is_active' column on public.branches.
--   Migration 005 inadvertently referenced branches.is_active in:
--     1. public.rpc_complete_sale
--     2. public.rpc_get_operational_dashboard_metrics
--   This corrective migration re-declares both functions with:
--     SELECT (status = 'active') INTO v_branch_active FROM public.branches ...
--   preserving all signatures, parameters, return types, SECURITY DEFINER,
--   search_path, RBAC, business logic, calculations, error tokens, and grants.
-- ============================================================================

-- ============================================================================
-- 1. RPC: public.rpc_complete_sale
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_complete_sale(
  p_business_id UUID,
  p_branch_id UUID,
  p_register_id UUID,
  p_shift_id UUID,
  p_items JSONB,
  p_payments JSONB DEFAULT '[]'::jsonb,
  p_customer_id UUID DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  -- Caller & Tenancy
  v_caller_id UUID;
  v_biz_currency VARCHAR(3);
  v_branch_active BOOLEAN;

  -- Hardware & Shift
  v_reg_status TEXT;
  v_reg_branch_id UUID;
  v_shift_status TEXT;
  v_shift_branch_id UUID;
  v_shift_register_id UUID;

  -- Cart & Financial Totals
  v_item_count INT := 0;
  v_subtotal NUMERIC(15, 4) := 0.0000;
  v_discount_total NUMERIC(15, 4) := 0.0000;
  v_tax_total NUMERIC(15, 4) := 0.0000;
  v_total_amount NUMERIC(15, 4) := 0.0000;

  -- Payment & Credit
  v_total_tender NUMERIC(15, 4) := 0.0000;
  v_proposed_balance_due NUMERIC(15, 4) := 0.0000;
  v_cust_id UUID;
  v_cust_credit_limit NUMERIC(15, 4);
  v_cust_status TEXT;
  v_cust_deleted_at TIMESTAMPTZ;
  v_current_outstanding NUMERIC(15, 4) := 0.0000;

  -- Transaction Outputs
  v_txn_number TEXT;
  v_txn_id UUID;
  v_item RECORD;
  v_pay RECORD;
  v_pay_res JSONB;
  v_recorded_payments JSONB := '[]'::jsonb;

  -- Loop Variables & Concurrency
  r_agg RECORD;
  v_bal_id UUID;
  v_bal_avail NUMERIC(15, 4);
  v_bal_avg_cost NUMERIC(15, 4);
  v_prod_cost NUMERIC(15, 4);
  v_prod_active BOOLEAN;
  v_prod_deleted TIMESTAMPTZ;
  v_loc_active BOOLEAN;
  v_loc_deleted TIMESTAMPTZ;
  v_loc_branch_id UUID;
  v_item_cost NUMERIC(15, 4);
  v_item_idx INT := 0;
  v_pay_idx INT := 0;

  -- Authorization & Policy Flags
  v_is_owner BOOLEAN := FALSE;
  v_can_discount BOOLEAN := FALSE;

  -- Price Resolution & Cart Cache
  v_tier TEXT;
  v_prod_total_qty NUMERIC(15, 4);
  v_canonical_price NUMERIC(15, 4);
  v_unit_price NUMERIC(15, 4);
  v_item_qty NUMERIC(15, 4);
  v_item_disc NUMERIC(15, 4);
  v_tax_rate NUMERIC(15, 4);
  v_item_tax NUMERIC(15, 4);
  v_line_subtotal NUMERIC(15, 4);
  v_line_total NUMERIC(15, 4);
  v_resolved_items JSONB := '[]'::jsonb;

  -- Post-payment Verification
  v_final_amount_paid NUMERIC(15, 4);
  v_final_balance_due NUMERIC(15, 4);
  v_final_status TEXT;
BEGIN
  -- ---------------------------------------------------------------------------
  -- 1. Caller Authentication
  -- ---------------------------------------------------------------------------
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated to execute checkout';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 2. Argument Null Checks
  -- ---------------------------------------------------------------------------
  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'INVALID_ARGUMENT: business_id is required';
  END IF;
  IF p_branch_id IS NULL THEN
    RAISE EXCEPTION 'INVALID_ARGUMENT: branch_id is required';
  END IF;
  IF p_register_id IS NULL THEN
    RAISE EXCEPTION 'INVALID_ARGUMENT: register_id is required';
  END IF;
  IF p_shift_id IS NULL THEN
    RAISE EXCEPTION 'INVALID_ARGUMENT: shift_id is required';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 3. Business Tenancy & Currency Validation
  -- ---------------------------------------------------------------------------
  SELECT currency INTO v_biz_currency
  FROM public.businesses
  WHERE id = p_business_id AND status = 'active' AND deleted_at IS NULL;

  IF v_biz_currency IS NULL THEN
    RAISE EXCEPTION 'INVALID_BUSINESS: Business % does not exist or is inactive', p_business_id;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 4. Scoped RBAC Authorization
  -- ---------------------------------------------------------------------------
  v_is_owner := public.is_business_owner(p_business_id);

  IF NOT (
    v_is_owner
    OR public.has_permission_in_scope(p_business_id, 'sales:create', p_branch_id)
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks sales:create permission for branch %',
      v_caller_id, p_branch_id;
  END IF;

  v_can_discount := v_is_owner
    OR public.has_permission_in_scope(p_business_id, 'sales:discount', p_branch_id);

  -- ---------------------------------------------------------------------------
  -- 5. Branch Validation
  -- ---------------------------------------------------------------------------
  SELECT (status = 'active') INTO v_branch_active
  FROM public.branches
  WHERE id = p_branch_id AND business_id = p_business_id AND deleted_at IS NULL;

  IF v_branch_active IS NULL OR NOT v_branch_active THEN
    RAISE EXCEPTION 'INVALID_BRANCH: Branch % does not exist or is inactive in business %',
      p_branch_id, p_business_id;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 6. Register Validation
  -- ---------------------------------------------------------------------------
  SELECT status, branch_id INTO v_reg_status, v_reg_branch_id
  FROM public.registers
  WHERE id = p_register_id AND business_id = p_business_id;

  IF v_reg_status IS NULL THEN
    RAISE EXCEPTION 'INVALID_REGISTER: Register % does not exist in business %',
      p_register_id, p_business_id;
  END IF;
  IF v_reg_branch_id <> p_branch_id THEN
    RAISE EXCEPTION 'BRANCH_MISMATCH: Register % belongs to branch %, not transaction branch %',
      p_register_id, v_reg_branch_id, p_branch_id;
  END IF;
  IF v_reg_status <> 'active' THEN
    RAISE EXCEPTION 'INACTIVE_REGISTER: Register % is not active (status: %)',
      p_register_id, v_reg_status;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 7. Shift Validation
  -- ---------------------------------------------------------------------------
  SELECT status, branch_id, register_id INTO v_shift_status, v_shift_branch_id, v_shift_register_id
  FROM public.register_shifts
  WHERE id = p_shift_id AND business_id = p_business_id;

  IF v_shift_status IS NULL THEN
    RAISE EXCEPTION 'INVALID_SHIFT: Shift % does not exist in business %',
      p_shift_id, p_business_id;
  END IF;
  IF v_shift_branch_id <> p_branch_id THEN
    RAISE EXCEPTION 'BRANCH_MISMATCH: Shift % belongs to branch %, not transaction branch %',
      p_shift_id, v_shift_branch_id, p_branch_id;
  END IF;
  IF v_shift_register_id <> p_register_id THEN
    RAISE EXCEPTION 'REGISTER_MISMATCH: Shift % belongs to register %, not transaction register %',
      p_shift_id, v_shift_register_id, p_register_id;
  END IF;
  IF v_shift_status <> 'open' THEN
    RAISE EXCEPTION 'SHIFT_NOT_OPEN: Shift % is % (must be open to complete sales)',
      p_shift_id, v_shift_status;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 8. Cart Items Structural Validation, Canonical Price Resolution & Math
  -- ---------------------------------------------------------------------------
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'INVALID_CART: Cart items must be a non-empty JSON array';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_item_idx := v_item_idx + 1;

    -- Mandatory keys presence
    IF (v_item.value->>'product_id') IS NULL THEN
      RAISE EXCEPTION 'INVALID_CART_ITEM: Item #% is missing product_id', v_item_idx;
    END IF;
    IF (v_item.value->>'location_id') IS NULL THEN
      RAISE EXCEPTION 'INVALID_CART_ITEM: Item #% is missing location_id', v_item_idx;
    END IF;
    IF (v_item.value->>'quantity') IS NULL THEN
      RAISE EXCEPTION 'INVALID_CART_ITEM: Item #% is missing quantity', v_item_idx;
    END IF;

    -- Quantity validation
    v_item_qty := ((v_item.value->>'quantity')::NUMERIC);
    IF v_item_qty <= 0 THEN
      RAISE EXCEPTION 'INVALID_CART_ITEM: Item #% quantity must be greater than zero', v_item_idx;
    END IF;

    -- 8.1 Validate Product Tenancy & Active State
    SELECT cost_price, is_active, deleted_at
    INTO v_prod_cost, v_prod_active, v_prod_deleted
    FROM public.products
    WHERE id = (v_item.value->>'product_id')::UUID AND business_id = p_business_id;

    IF v_prod_active IS NULL OR v_prod_deleted IS NOT NULL OR NOT v_prod_active THEN
      RAISE EXCEPTION 'INVALID_PRODUCT: Product % does not exist or is inactive in business %',
        (v_item.value->>'product_id')::UUID, p_business_id;
    END IF;

    -- 8.2 Price Tier Security & Authorization
    -- Default canonical tier is 'Retail'. Non-Retail tiers require business owner
    -- or sales:discount authority scoped to the branch.
    IF (v_item.value->>'price_tier') IS NOT NULL AND (v_item.value->>'price_tier') <> 'Retail' THEN
      IF NOT v_can_discount THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks sales:discount to select price tier % for product %',
          v_caller_id, (v_item.value->>'price_tier'), (v_item.value->>'product_id')::UUID;
      END IF;
      v_tier := (v_item.value->>'price_tier');
    ELSE
      v_tier := 'Retail';
    END IF;

    -- 8.3 Minimum Quantity Evaluation Rule
    -- min_quantity is evaluated against the aggregated total quantity for the product
    -- across the entire cart/sale (per-product total). This prevents line-splitting
    -- workarounds while honoring volume-break price tier eligibility.
    SELECT COALESCE(SUM((it.value->>'quantity')::NUMERIC), 0.0000)
    INTO v_prod_total_qty
    FROM jsonb_array_elements(p_items) AS it
    WHERE (it.value->>'product_id')::UUID = (v_item.value->>'product_id')::UUID;

    -- 8.4 Server-Side Canonical Price Resolution from public.product_prices
    -- Requires: same business, same product, matching business currency, active status,
    -- un-deleted, current temporal validity window, and min_quantity <= aggregated product quantity.
    -- products.cost_price is strictly NOT used as a selling price.
    SELECT price INTO v_canonical_price
    FROM public.product_prices
    WHERE business_id = p_business_id
      AND product_id = (v_item.value->>'product_id')::UUID
      AND price_tier = v_tier
      AND currency = v_biz_currency
      AND is_active = true
      AND deleted_at IS NULL
      AND (valid_from IS NULL OR valid_from <= NOW())
      AND (valid_to IS NULL OR valid_to >= NOW())
      AND min_quantity <= v_prod_total_qty
    ORDER BY min_quantity DESC, created_at DESC
    LIMIT 1;

    IF v_canonical_price IS NULL THEN
      RAISE EXCEPTION 'PRICE_NOT_CONFIGURED: Product % has no valid % price configured for currency % (cart qty: %)',
        (v_item.value->>'product_id')::UUID, v_tier, v_biz_currency, v_prod_total_qty;
    END IF;

    -- 8.5 Custom Unit Price Authorization
    -- If client sends a custom unit_price differing from canonical price, require sales:discount.
    IF (v_item.value->>'unit_price') IS NOT NULL
       AND ((v_item.value->>'unit_price')::NUMERIC) <> v_canonical_price THEN
      IF NOT v_can_discount THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks sales:discount to override unit price for product %',
          v_caller_id, (v_item.value->>'product_id')::UUID;
      END IF;
      IF ((v_item.value->>'unit_price')::NUMERIC) < 0 THEN
        RAISE EXCEPTION 'INVALID_CART_ITEM: Item #% unit_price cannot be negative', v_item_idx;
      END IF;
      v_unit_price := ((v_item.value->>'unit_price')::NUMERIC);
    ELSE
      v_unit_price := v_canonical_price;
    END IF;

    -- 8.6 Manual Discount Authorization
    -- Any positive discount requires business owner or sales:discount authority.
    v_item_disc := COALESCE((v_item.value->>'discount_amount')::NUMERIC, 0.0000);
    IF v_item_disc < 0 THEN
      RAISE EXCEPTION 'INVALID_CART_ITEM: Item #% discount_amount cannot be negative', v_item_idx;
    END IF;

    IF v_item_disc > 0 THEN
      IF NOT v_can_discount THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks sales:discount to apply manual discounts',
          v_caller_id;
      END IF;
    END IF;

    -- Line base subtotal calculation
    v_line_subtotal := ROUND(v_item_qty * v_unit_price, 4);

    -- Discount limit check: discount cannot exceed line base merchandise amount
    IF v_item_disc > v_line_subtotal THEN
      RAISE EXCEPTION 'DISCOUNT_EXCEEDS_PRICE: Item #% discount (%) exceeds total line base (%)',
        v_item_idx, v_item_disc, v_line_subtotal;
    END IF;

    -- 8.7 Tax Validation (Temporary Accounting Input Policy B)
    -- Tax input is validated and recorded for transaction accounting.
    -- Server-authoritative jurisdiction, taxability, exemption, and rate determination
    -- are deferred to a future Tax Engine.
    IF (v_item.value->>'tax_amount') IS NOT NULL AND (v_item.value->>'tax_rate') IS NOT NULL THEN
      RAISE EXCEPTION 'INVALID_TAX_INPUT: Provide tax_amount or tax_rate, not both.';
    ELSIF (v_item.value->>'tax_amount') IS NOT NULL THEN
      v_item_tax := ((v_item.value->>'tax_amount')::NUMERIC);
      IF v_item_tax < 0 THEN
        RAISE EXCEPTION 'INVALID_CART_ITEM: Item #% tax_amount cannot be negative', v_item_idx;
      END IF;
    ELSIF (v_item.value->>'tax_rate') IS NOT NULL THEN
      v_tax_rate := ((v_item.value->>'tax_rate')::NUMERIC);
      IF v_tax_rate < 0 THEN
        RAISE EXCEPTION 'INVALID_CART_ITEM: Item #% tax_rate cannot be negative', v_item_idx;
      END IF;
      v_item_tax := ROUND((v_line_subtotal - v_item_disc) * (v_tax_rate / 100.0), 4);
    ELSE
      v_item_tax := 0.0000;
    END IF;

    v_line_total := (v_line_subtotal - v_item_disc) + v_item_tax;

    -- Accumulate server-authoritative header totals
    v_subtotal := v_subtotal + v_line_subtotal;
    v_discount_total := v_discount_total + v_item_disc;
    v_tax_total := v_tax_total + v_item_tax;

    -- Cache fully-resolved item for atomic insertion and inventory movement
    v_resolved_items := v_resolved_items || jsonb_build_array(
      jsonb_build_object(
        'product_id', (v_item.value->>'product_id')::UUID,
        'location_id', (v_item.value->>'location_id')::UUID,
        'quantity', v_item_qty,
        'unit_price', v_unit_price,
        'discount_amount', v_item_disc,
        'tax_amount', v_item_tax,
        'line_total', v_line_total,
        'notes', v_item.value->>'notes'
      )
    );
  END LOOP;

  v_total_amount := v_subtotal - v_discount_total + v_tax_total;

  -- ---------------------------------------------------------------------------
  -- 9. Duplicate-Cart Aggregation & Deterministic Inventory Locking
  -- Note: Deterministic lock ordering on (location_id, product_id) minimizes
  -- and prevents lock-order inversion among concurrent checkout transactions.
  -- ---------------------------------------------------------------------------
  FOR r_agg IN
    SELECT
      (item.value->>'location_id')::UUID AS location_id,
      (item.value->>'product_id')::UUID AS product_id,
      SUM((item.value->>'quantity')::NUMERIC) AS total_quantity
    FROM jsonb_array_elements(v_resolved_items) AS item
    GROUP BY (item.value->>'location_id')::UUID, (item.value->>'product_id')::UUID
    ORDER BY (item.value->>'location_id')::UUID ASC, (item.value->>'product_id')::UUID ASC
  LOOP
    -- 9.1 Validate Location Tenancy & Branch Association
    SELECT is_active, deleted_at, branch_id
    INTO v_loc_active, v_loc_deleted, v_loc_branch_id
    FROM public.inventory_locations
    WHERE id = r_agg.location_id AND business_id = p_business_id;

    IF v_loc_active IS NULL OR v_loc_deleted IS NOT NULL OR NOT v_loc_active THEN
      RAISE EXCEPTION 'INVALID_LOCATION: Location % does not exist or is inactive in business %',
        r_agg.location_id, p_business_id;
    END IF;
    IF v_loc_branch_id <> p_branch_id THEN
      RAISE EXCEPTION 'BRANCH_MISMATCH: Inventory location % belongs to branch %, not transaction branch %',
        r_agg.location_id, v_loc_branch_id, p_branch_id;
    END IF;

    -- 9.2 Pessimistic Row Lock (FOR UPDATE)
    -- Requires an existing, initialized inventory_balances row.
    -- Fails immediately before any sales headers, items, or payments are created.
    SELECT id, available_quantity, average_unit_cost
    INTO v_bal_id, v_bal_avail, v_bal_avg_cost
    FROM public.inventory_balances
    WHERE business_id = p_business_id
      AND location_id = r_agg.location_id
      AND product_id = r_agg.product_id
    FOR UPDATE;

    IF NOT FOUND OR v_bal_id IS NULL THEN
      RAISE EXCEPTION 'INVENTORY_BALANCE_NOT_FOUND: Product % at location % has no initialized inventory record',
        r_agg.product_id, r_agg.location_id;
    END IF;

    -- 9.3 Validate Aggregate Available Stock
    IF v_bal_avail < r_agg.total_quantity THEN
      RAISE EXCEPTION 'INSUFFICIENT_STOCK: Product % at location % requires % units, but only % available',
        r_agg.product_id, r_agg.location_id, r_agg.total_quantity, v_bal_avail;
    END IF;
  END LOOP;

  -- ---------------------------------------------------------------------------
  -- 10. Tender Validation & Customer Credit Concurrency
  -- ---------------------------------------------------------------------------
  IF p_payments IS NOT NULL THEN
    IF jsonb_typeof(p_payments) <> 'array' THEN
      RAISE EXCEPTION 'INVALID_PAYMENTS: Payments parameter must be a JSON array';
    END IF;

    FOR v_pay IN SELECT * FROM jsonb_array_elements(p_payments)
    LOOP
      v_pay_idx := v_pay_idx + 1;

      IF ((v_pay.value->>'amount')::NUMERIC) IS NULL OR ((v_pay.value->>'amount')::NUMERIC) <= 0 THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_AMOUNT: Payment #% amount must be greater than zero', v_pay_idx;
      END IF;

      IF (v_pay.value->>'payment_method') IS NULL OR (v_pay.value->>'payment_method') NOT IN (
        'cash', 'bank_transfer', 'debit_card', 'credit_card', 'mobile_money', 'store_credit', 'other'
      ) THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_METHOD: Payment #% method (%) is not supported',
          v_pay_idx, (v_pay.value->>'payment_method');
      END IF;

      IF (v_pay.value->>'payment_method') = 'bank_transfer' AND (v_pay.value->>'bank_account_id') IS NULL THEN
        RAISE EXCEPTION 'BANK_ACCOUNT_REQUIRED: Payment #% (bank_transfer) requires bank_account_id', v_pay_idx;
      END IF;

      v_total_tender := v_total_tender + ((v_pay.value->>'amount')::NUMERIC);
    END LOOP;
  END IF;

  -- Reject overpayment at checkout
  IF v_total_tender > v_total_amount THEN
    RAISE EXCEPTION 'OVERPAYMENT_NOT_ALLOWED: Total tender (%) exceeds total sale amount (%)',
      v_total_tender, v_total_amount;
  END IF;

  v_proposed_balance_due := v_total_amount - v_total_tender;

  -- Credit validation if unpaid balance exists
  IF v_proposed_balance_due > 0 THEN
    IF p_customer_id IS NULL THEN
      RAISE EXCEPTION 'CUSTOMER_REQUIRED: Credit sale with balance due (%) requires a valid customer',
        v_proposed_balance_due;
    END IF;

    -- Lock customer record FOR UPDATE to serialize concurrent credit sales
    SELECT id, credit_limit, status, deleted_at
    INTO v_cust_id, v_cust_credit_limit, v_cust_status, v_cust_deleted_at
    FROM public.customers
    WHERE id = p_customer_id AND business_id = p_business_id
    FOR UPDATE;

    IF v_cust_id IS NULL OR v_cust_deleted_at IS NOT NULL OR v_cust_status <> 'active' THEN
      RAISE EXCEPTION 'INVALID_CUSTOMER: Customer % does not exist or is inactive in business %',
        p_customer_id, p_business_id;
    END IF;

    -- Authoritative outstanding balance calculation from open transactions
    SELECT COALESCE(SUM(balance_due), 0.0000)
    INTO v_current_outstanding
    FROM public.sales_transactions
    WHERE customer_id = p_customer_id
      AND business_id = p_business_id
      AND balance_due > 0
      AND status IN ('pending_payment', 'partially_paid');

    IF (v_current_outstanding + v_proposed_balance_due) > v_cust_credit_limit THEN
      RAISE EXCEPTION 'CREDIT_LIMIT_EXCEEDED: Customer % credit limit is %, current outstanding is %, proposed balance is %',
        p_customer_id, v_cust_credit_limit, v_current_outstanding, v_proposed_balance_due;
    END IF;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 11. Concurrency-Safe Sequential Document Number Generation
  -- Note: Implements concurrency-safe server-side sequential document numbering
  -- using public.document_sequences.
  -- ---------------------------------------------------------------------------
  v_txn_number := public.rpc_next_document_number(p_business_id, 'sale', 'TXN');

  -- ---------------------------------------------------------------------------
  -- 12. Create Sales Transaction Header
  -- ---------------------------------------------------------------------------
  INSERT INTO public.sales_transactions (
    business_id, branch_id, register_id, shift_id,
    cashier_user_id, customer_id, transaction_number,
    transaction_type, status,
    subtotal, discount_total, tax_total, total_amount,
    amount_paid, balance_due, currency,
    notes, occurred_at, created_at, updated_at, metadata
  ) VALUES (
    p_business_id, p_branch_id, p_register_id, p_shift_id,
    v_caller_id, p_customer_id, v_txn_number,
    'sale', 'pending_payment',
    v_subtotal, v_discount_total, v_tax_total, v_total_amount,
    0.0000, v_total_amount, v_biz_currency,
    p_notes, NOW(), NOW(), NOW(), COALESCE(p_metadata, '{}'::jsonb)
  ) RETURNING id INTO v_txn_id;

  -- ---------------------------------------------------------------------------
  -- 13. Insert Sales Transaction Line Items
  -- Note: Must be inserted while status = 'pending_payment' before payment sync
  -- can finalize transaction to satisfy trg_protect_sales_transaction_items.
  -- ---------------------------------------------------------------------------
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_resolved_items)
  LOOP
    -- Retrieve historical cost snapshot exclusively from locked inventory balance
    -- products.cost_price is strictly NOT used as authoritative historical COGS snapshot
    SELECT average_unit_cost INTO v_item_cost
    FROM public.inventory_balances
    WHERE business_id = p_business_id
      AND location_id = (v_item.value->>'location_id')::UUID
      AND product_id = (v_item.value->>'product_id')::UUID;

    v_item_cost := COALESCE(v_item_cost, 0.0000);

    INSERT INTO public.sales_transaction_items (
      business_id, transaction_id, product_id, inventory_location_id,
      quantity, unit_price, discount_amount, tax_amount, line_total,
      cost_price, notes, created_at
    ) VALUES (
      p_business_id,
      v_txn_id,
      (v_item.value->>'product_id')::UUID,
      (v_item.value->>'location_id')::UUID,
      (v_item.value->>'quantity')::NUMERIC,
      (v_item.value->>'unit_price')::NUMERIC,
      (v_item.value->>'discount_amount')::NUMERIC,
      (v_item.value->>'tax_amount')::NUMERIC,
      (v_item.value->>'line_total')::NUMERIC,
      v_item_cost,
      v_item.value->>'notes',
      NOW()
    );
  END LOOP;

  -- ---------------------------------------------------------------------------
  -- 14. Authoritative Inventory Movements Posting
  -- Reuses Migration 003 public.rpc_post_inventory_movement()
  -- ---------------------------------------------------------------------------
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_resolved_items)
  LOOP
    SELECT average_unit_cost INTO v_item_cost
    FROM public.inventory_balances
    WHERE business_id = p_business_id
      AND location_id = (v_item.value->>'location_id')::UUID
      AND product_id = (v_item.value->>'product_id')::UUID;

    PERFORM public.rpc_post_inventory_movement(
      p_business_id := p_business_id,
      p_branch_id := p_branch_id,
      p_location_id := (v_item.value->>'location_id')::UUID,
      p_product_id := (v_item.value->>'product_id')::UUID,
      p_movement_type := 'SALE',
      p_quantity := -ABS((v_item.value->>'quantity')::NUMERIC),
      p_unit_cost := COALESCE(v_item_cost, 0.0000),
      p_reference_type := 'sale',
      p_reference_id := v_txn_id,
      p_notes := 'Sale ' || v_txn_number,
      p_allow_negative := FALSE
    );
  END LOOP;

  -- ---------------------------------------------------------------------------
  -- 15. Record Payments & Treasury Routing
  -- Reuses Migration 004 public.rpc_record_payment()
  -- ---------------------------------------------------------------------------
  IF p_payments IS NOT NULL AND jsonb_array_length(p_payments) > 0 THEN
    FOR v_pay IN SELECT * FROM jsonb_array_elements(p_payments)
    LOOP
      v_pay_res := public.rpc_record_payment(
        p_business_id := p_business_id,
        p_transaction_id := v_txn_id,
        p_payment_method := v_pay.value->>'payment_method',
        p_amount := (v_pay.value->>'amount')::NUMERIC,
        p_bank_account_id := (v_pay.value->>'bank_account_id')::UUID,
        p_register_id := p_register_id,
        p_shift_id := p_shift_id,
        p_reference_number := v_pay.value->>'reference_number',
        p_notes := v_pay.value->>'notes'
      );
      v_recorded_payments := v_recorded_payments || jsonb_build_array(v_pay_res);
    END LOOP;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 16. Authoritative Final State Verification & Receipt Output
  -- ---------------------------------------------------------------------------
  SELECT amount_paid, balance_due, status
  INTO v_final_amount_paid, v_final_balance_due, v_final_status
  FROM public.sales_transactions
  WHERE id = v_txn_id;

  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_txn_id,
    'transaction_number', v_txn_number,
    'status', v_final_status,
    'currency', v_biz_currency,
    'subtotal', v_subtotal,
    'discount_total', v_discount_total,
    'tax_total', v_tax_total,
    'total_amount', v_total_amount,
    'amount_paid', v_final_amount_paid,
    'balance_due', v_final_balance_due,
    'customer_id', p_customer_id,
    'branch_id', p_branch_id,
    'register_id', p_register_id,
    'shift_id', p_shift_id,
    'payments', v_recorded_payments
  );
END;
$$;

-- Security & Permissions
REVOKE ALL ON FUNCTION public.rpc_complete_sale(UUID, UUID, UUID, UUID, JSONB, JSONB, UUID, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_complete_sale(UUID, UUID, UUID, UUID, JSONB, JSONB, UUID, TEXT, JSONB) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_complete_sale(UUID, UUID, UUID, UUID, JSONB, JSONB, UUID, TEXT, JSONB) TO authenticated;

-- ============================================================================
-- 2. RPC: public.rpc_get_operational_dashboard_metrics
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_get_operational_dashboard_metrics(
  p_business_id UUID,
  p_branch_id UUID DEFAULT NULL,
  p_start_date TIMESTAMPTZ DEFAULT (CURRENT_DATE - INTERVAL '30 days'),
  p_end_date TIMESTAMPTZ DEFAULT NOW()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_biz_currency VARCHAR(3);
  v_branch_active BOOLEAN;
  v_is_owner BOOLEAN := FALSE;

  -- Domain Scoped View Permissions (Option A: Section-Filtered Metrics)
  v_can_view_sales BOOLEAN := FALSE;
  v_can_view_inventory_qty BOOLEAN := FALSE;
  v_can_view_inventory_val BOOLEAN := FALSE;
  v_can_view_registers BOOLEAN := FALSE;
  v_can_view_cash BOOLEAN := FALSE;
  v_can_view_bank BOOLEAN := FALSE;
  v_can_view_receivables BOOLEAN := FALSE;
  v_can_view_expenses BOOLEAN := FALSE;

  -- Date Bounds Temp
  v_tmp_date TIMESTAMPTZ;

  -- Sales & Margin KPIs (NULL if caller lacks sales viewing permission)
  v_gmv NUMERIC(15, 4);
  v_discounts NUMERIC(15, 4);
  v_net_sales NUMERIC(15, 4);
  v_tax_collected NUMERIC(15, 4);
  v_cogs NUMERIC(15, 4);
  v_gross_profit NUMERIC(15, 4);
  v_gross_margin_pct NUMERIC(15, 4);
  v_txn_count BIGINT;
  v_avg_ticket NUMERIC(15, 4);

  -- Inventory KPIs (Separated: valuation requires financial view, active SKUs requires operational/inventory view)
  v_inventory_val NUMERIC(15, 4);
  v_active_skus BIGINT;

  -- Treasury & Shifts (Separated: shift count requires registers:view, cash on hand requires cash:view/treasury:view)
  v_open_shifts BIGINT;
  v_cash_on_hand NUMERIC(15, 4);
  v_bank_balance NUMERIC(15, 4);

  -- Receivables & Expenses (NULL if caller lacks domain viewing permissions)
  v_receivables NUMERIC(15, 4);
  v_pending_expenses NUMERIC(15, 4);
  v_paid_expenses NUMERIC(15, 4);
BEGIN
  -- ---------------------------------------------------------------------------
  -- 1. Caller Authentication
  -- ---------------------------------------------------------------------------
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Caller must be authenticated';
  END IF;

  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'INVALID_ARGUMENT: business_id is required';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 2. Business Tenancy & Currency
  -- ---------------------------------------------------------------------------
  SELECT currency INTO v_biz_currency
  FROM public.businesses
  WHERE id = p_business_id AND status = 'active' AND deleted_at IS NULL;

  IF v_biz_currency IS NULL THEN
    RAISE EXCEPTION 'INVALID_BUSINESS: Business % does not exist or is inactive', p_business_id;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 3. Scoped RBAC Verification & Domain Permission Evaluation
  -- ---------------------------------------------------------------------------
  v_is_owner := public.is_business_owner(p_business_id);

  IF NOT v_is_owner THEN
    -- Active business membership check
    IF NOT EXISTS (
      SELECT 1 FROM public.business_memberships
      WHERE business_id = p_business_id AND user_id = v_caller_id AND status = 'active'
    ) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: Caller % is not an active member of business %',
        v_caller_id, p_business_id;
    END IF;
  END IF;

  IF p_branch_id IS NULL THEN
    -- Tenant-wide request: caller must have tenant-wide (unscoped) permissions or be owner
    v_can_view_sales := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', NULL)
      OR public.has_permission_in_scope(p_business_id, 'reports:view_operational', NULL)
      OR public.has_permission_in_scope(p_business_id, 'sales:view', NULL);

    v_can_view_inventory_qty := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', NULL)
      OR public.has_permission_in_scope(p_business_id, 'reports:view_operational', NULL)
      OR public.has_permission_in_scope(p_business_id, 'inventory:view', NULL);

    v_can_view_inventory_val := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', NULL);

    v_can_view_registers := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_operational', NULL)
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', NULL)
      OR public.has_permission_in_scope(p_business_id, 'registers:view', NULL);

    v_can_view_cash := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', NULL)
      OR public.has_permission_in_scope(p_business_id, 'cash:view', NULL)
      OR public.has_permission_in_scope(p_business_id, 'treasury:view', NULL);

    v_can_view_bank := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', NULL)
      OR public.has_permission_in_scope(p_business_id, 'bank:view', NULL)
      OR public.has_permission_in_scope(p_business_id, 'treasury:view', NULL);

    -- Receivables: strictly requires financial reporting or payment settlement authority
    v_can_view_receivables := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', NULL)
      OR public.has_permission_in_scope(p_business_id, 'payments:view', NULL);

    v_can_view_expenses := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', NULL)
      OR public.has_permission_in_scope(p_business_id, 'expenses:view', NULL);

    -- Gate: caller must have at least one tenant-wide viewing permission
    IF NOT (
      v_can_view_sales
      OR v_can_view_inventory_qty
      OR v_can_view_inventory_val
      OR v_can_view_registers
      OR v_can_view_cash
      OR v_can_view_bank
      OR v_can_view_receivables
      OR v_can_view_expenses
    ) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks tenant-wide reporting permissions for business %',
        v_caller_id, p_business_id;
    END IF;

  ELSE
    -- Branch-scoped request: validate branch tenancy
    SELECT (status = 'active') INTO v_branch_active
    FROM public.branches
    WHERE id = p_branch_id AND business_id = p_business_id AND deleted_at IS NULL;

    IF v_branch_active IS NULL OR NOT v_branch_active THEN
      RAISE EXCEPTION 'INVALID_BRANCH: Branch % does not exist or is inactive in business %',
        p_branch_id, p_business_id;
    END IF;

    -- Branch-scoped permissions: evaluated strictly for p_branch_id
    v_can_view_sales := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_operational', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'sales:view', p_branch_id);

    v_can_view_inventory_qty := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_operational', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'inventory:view', p_branch_id);

    v_can_view_inventory_val := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', p_branch_id);

    v_can_view_registers := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'reports:view_operational', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'registers:view', p_branch_id);

    v_can_view_cash := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'cash:view', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'treasury:view', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', p_branch_id);

    -- Bank accounts are enterprise-level entities without a branch_id foreign key.
    -- Branch-scoped dashboards strictly omit/null bank balances to avoid falsely attributing enterprise cash to a branch.
    v_can_view_bank := FALSE;

    -- Receivables: strictly requires financial reporting or payment settlement authority
    v_can_view_receivables := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'payments:view', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', p_branch_id);

    v_can_view_expenses := v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'expenses:view', p_branch_id)
      OR public.has_permission_in_scope(p_business_id, 'reports:view_financial', p_branch_id);

    -- Gate: caller must have at least one valid permission for this branch
    IF NOT (
      v_can_view_sales
      OR v_can_view_inventory_qty
      OR v_can_view_inventory_val
      OR v_can_view_registers
      OR v_can_view_cash
      OR v_can_view_receivables
      OR v_can_view_expenses
    ) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: Caller % lacks permissions for branch % in business %',
        v_caller_id, p_branch_id, p_business_id;
    END IF;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 4. Date Bounds Sanity Check
  -- ---------------------------------------------------------------------------
  IF p_start_date > p_end_date THEN
    v_tmp_date := p_start_date;
    p_start_date := p_end_date;
    p_end_date := v_tmp_date;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 5. Sales & Margin KPIs (Avoiding Join Multiplication)
  -- ---------------------------------------------------------------------------
  IF v_can_view_sales THEN
    WITH txn_cogs AS (
      SELECT
        sti.transaction_id,
        SUM(sti.quantity * sti.cost_price) AS cogs
      FROM public.sales_transaction_items sti
      WHERE sti.business_id = p_business_id
      GROUP BY sti.transaction_id
    )
    SELECT
      COALESCE(SUM(st.subtotal), 0.0000),
      COALESCE(SUM(st.discount_total), 0.0000),
      COALESCE(SUM(st.subtotal - st.discount_total), 0.0000),
      COALESCE(SUM(st.tax_total), 0.0000),
      COALESCE(SUM(tc.cogs), 0.0000),
      COUNT(st.id)
    INTO
      v_gmv, v_discounts, v_net_sales, v_tax_collected, v_cogs, v_txn_count
    FROM public.sales_transactions st
    LEFT JOIN txn_cogs tc ON st.id = tc.transaction_id
    WHERE st.business_id = p_business_id
      AND (p_branch_id IS NULL OR st.branch_id = p_branch_id)
      AND st.occurred_at >= p_start_date
      AND st.occurred_at <= p_end_date
      AND st.status IN ('pending_payment', 'partially_paid', 'completed');

    v_gross_profit := v_net_sales - v_cogs;

    IF v_net_sales > 0 THEN
      v_gross_margin_pct := ROUND((v_gross_profit / v_net_sales) * 100.0, 4);
    ELSE
      v_gross_margin_pct := 0.0000;
    END IF;

    IF v_txn_count > 0 THEN
      v_avg_ticket := ROUND(v_net_sales / v_txn_count, 4);
    ELSE
      v_avg_ticket := 0.0000;
    END IF;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 6. Inventory Valuation & SKU Count (from v_inventory_stock_valuation)
  -- ---------------------------------------------------------------------------
  IF v_can_view_inventory_val THEN
    SELECT COALESCE(SUM(total_inventory_value), 0.0000)
    INTO v_inventory_val
    FROM public.v_inventory_stock_valuation
    WHERE business_id = p_business_id
      AND (p_branch_id IS NULL OR branch_id = p_branch_id);
  END IF;

  IF v_can_view_inventory_qty THEN
    SELECT COUNT(DISTINCT product_id)
    INTO v_active_skus
    FROM public.v_inventory_stock_valuation
    WHERE business_id = p_business_id
      AND (p_branch_id IS NULL OR branch_id = p_branch_id);
  END IF;

  -- ---------------------------------------------------------------------------
  -- 7. Register Shifts & Physical Cash on Hand
  -- ---------------------------------------------------------------------------
  IF v_can_view_registers THEN
    SELECT COUNT(*)
    INTO v_open_shifts
    FROM public.register_shifts
    WHERE business_id = p_business_id
      AND (p_branch_id IS NULL OR branch_id = p_branch_id)
      AND status = 'open';
  END IF;

  IF v_can_view_cash THEN
    SELECT COALESCE(SUM(current_cash_on_hand), 0.0000)
    INTO v_cash_on_hand
    FROM public.v_cash_register_balances
    WHERE business_id = p_business_id
      AND (p_branch_id IS NULL OR branch_id = p_branch_id);
  END IF;

  -- ---------------------------------------------------------------------------
  -- 8. Enterprise Bank Balance
  -- Note: Bank accounts in FinTab are enterprise-level entities without branch_id.
  -- Returns non-null ONLY for tenant-wide requests by authorized users.
  -- ---------------------------------------------------------------------------
  IF p_branch_id IS NULL AND v_can_view_bank THEN
    SELECT COALESCE(SUM(calculated_balance), 0.0000)
    INTO v_bank_balance
    FROM public.v_bank_account_balances
    WHERE business_id = p_business_id;
  ELSE
    v_bank_balance := NULL;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 9. Outstanding Customer Receivables
  -- ---------------------------------------------------------------------------
  IF v_can_view_receivables THEN
    IF p_branch_id IS NULL THEN
      SELECT COALESCE(SUM(total_outstanding_balance), 0.0000)
      INTO v_receivables
      FROM public.v_customer_receivables
      WHERE business_id = p_business_id;
    ELSE
      SELECT COALESCE(SUM(balance_due), 0.0000)
      INTO v_receivables
      FROM public.sales_transactions
      WHERE business_id = p_business_id
        AND branch_id = p_branch_id
        AND balance_due > 0
        AND status IN ('pending_payment', 'partially_paid');
    END IF;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 10. Operational Expenses
  -- ---------------------------------------------------------------------------
  IF v_can_view_expenses THEN
    SELECT
      COALESCE(SUM(amount) FILTER (WHERE status IN ('draft', 'pending_approval')), 0.0000),
      COALESCE(SUM(amount) FILTER (WHERE status = 'paid' AND expense_date >= p_start_date::date AND expense_date <= p_end_date::date), 0.0000)
    INTO
      v_pending_expenses, v_paid_expenses
    FROM public.expenses
    WHERE business_id = p_business_id
      AND (p_branch_id IS NULL OR branch_id = p_branch_id)
      AND deleted_at IS NULL;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 11. Authoritative Metric JSON Aggregation
  -- ---------------------------------------------------------------------------
  RETURN jsonb_build_object(
    'currency', v_biz_currency,
    'start_date', p_start_date,
    'end_date', p_end_date,
    'branch_id', p_branch_id,
    'gross_merchandise_value', v_gmv,
    'discounts_total', v_discounts,
    'net_sales', v_net_sales,
    'sales_tax_collected', v_tax_collected,
    'cogs', v_cogs,
    'gross_profit', v_gross_profit,
    'gross_margin_pct', v_gross_margin_pct,
    'transaction_count', v_txn_count,
    'average_ticket', v_avg_ticket,
    'inventory_value', v_inventory_val,
    'active_sku_count', v_active_skus,
    'open_shift_count', v_open_shifts,
    'cash_on_hand', v_cash_on_hand,
    'enterprise_bank_balance', v_bank_balance,
    'bank_balance', v_bank_balance,
    'outstanding_receivables', v_receivables,
    'pending_expense_amount', v_pending_expenses,
    'paid_expense_amount', v_paid_expenses
  );
END;
$$;

-- Security & Permissions
REVOKE ALL ON FUNCTION public.rpc_get_operational_dashboard_metrics(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_get_operational_dashboard_metrics(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_operational_dashboard_metrics(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
