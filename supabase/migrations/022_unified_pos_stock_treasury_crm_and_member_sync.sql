-- =============================================================================
-- FinTab Enterprise OS - Migration 022:
-- Unified POS Sale Execution, Live Stock Deduction, Cash/Bank Settlement,
-- Customer Loyalty Points & Member Workspace Sync
-- =============================================================================
-- Fixes cross-user and RLS gaps for active workspace members (Cashiers, Staff,
-- Managers, and Business Owners):
--   1. public.fn_is_verified_workspace_member(p_business_id)
--   2. public.rpc_execute_unified_pos_sale(p_business_id, p_payload)
--      Atomically persists sales_transactions, sales_transaction_items, payments,
--      deducts inventory_balances + logs inventory_movements, credits Cash Vault
--      or Bank/Mobile account, updates customer loyalty points/spend/credit, and
--      merges cross-device notifications & state into workspace_sync.
--   3. public.rpc_execute_unified_sale_reversal(...)
--      Atomically processes sale refunds/voids/deletes with Restock vs Damaged
--      Write-Off, bank/cash reversal, and customer points/spend reversal.
--   4. public.rpc_post_member_stock_change(...)
--      Atomically updates inventory_balances (auto-creating location & balance
--      row from prior stock when missing) and logs inventory_movements.
--   5. public.rpc_merge_member_workspace_state(p_business_id, p_patch)
--      Allows verified active staff members to sync operational records (sales,
--      stock, customer points, expense requests, receipt correction requests,
--      notifications) to businesses.metadata.workspace_sync safely.
--   6. One-time idempotent reconciliation for historical sales whose stock,
--      customer points, or cash/bank settlements were skipped under client RLS.
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. HELPER: VERIFY ACTIVE WORKSPACE MEMBER OR PRIMARY OWNER
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fn_is_verified_workspace_member(
  p_business_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_email TEXT;
  v_owner_id UUID;
  v_meta JSONB;
  v_override_status TEXT;
  v_has_membership BOOLEAN := FALSE;
BEGIN
  IF v_uid IS NULL OR p_business_id IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT b.owner_user_id, COALESCE(b.metadata, '{}'::jsonb)
  INTO v_owner_id, v_meta
  FROM public.businesses b
  WHERE b.id = p_business_id
    AND b.deleted_at IS NULL;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  IF v_owner_id = v_uid THEN
    RETURN TRUE;
  END IF;

  SELECT lower(trim(u.email))
  INTO v_email
  FROM auth.users u
  WHERE u.id = v_uid;

  IF v_email IS NOT NULL AND v_email <> '' THEN
    v_override_status := v_meta #>> ARRAY['workspace_sync', 'memberAccessOverrides', p_business_id::text || ':' || v_email, 'status'];
    IF v_override_status IN ('Revoked', 'Suspended') THEN
      RETURN FALSE;
    END IF;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.business_memberships bm
    WHERE bm.business_id = p_business_id
      AND bm.user_id = v_uid
      AND bm.status = 'active'
  ) INTO v_has_membership;

  IF v_has_membership THEN
    RETURN TRUE;
  END IF;

  -- Also accept invited active staff/investor present in workspace_sync invitations/staff before owner reconciliation
  IF v_email IS NOT NULL AND v_email <> '' THEN
    IF EXISTS (
      SELECT 1
      FROM public.business_invitations bi
      WHERE bi.business_id = p_business_id
        AND lower(trim(bi.email)) = v_email
        AND bi.status IN ('pending', 'accepted')
    ) THEN
      RETURN TRUE;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(
        CASE
          WHEN jsonb_typeof(v_meta #> '{workspace_sync,invitations}') = 'array'
          THEN v_meta #> '{workspace_sync,invitations}'
          ELSE '[]'::jsonb
        END
      ) AS inv
      WHERE lower(trim(COALESCE(inv->>'email', inv->>'normalizedEmail', ''))) = v_email
        AND lower(COALESCE(inv->>'status', '')) IN ('pending', 'accepted')
    ) THEN
      RETURN TRUE;
    END IF;
  END IF;

  RETURN FALSE;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_is_verified_workspace_member(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_verified_workspace_member(UUID) TO authenticated;

-- =============================================================================
-- 2. HELPER: ENSURE DEFAULT INVENTORY LOCATION FOR A BRANCH
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fn_ensure_branch_sales_floor_location(
  p_business_id UUID,
  p_branch_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_loc_id UUID;
  v_code TEXT;
BEGIN
  SELECT il.id
  INTO v_loc_id
  FROM public.inventory_locations il
  WHERE il.business_id = p_business_id
    AND il.branch_id = p_branch_id
    AND il.deleted_at IS NULL
    AND il.is_active = true
  ORDER BY (CASE WHEN il.location_type = 'sales_floor' THEN 0 ELSE 1 END), il.created_at ASC
  LIMIT 1;

  IF v_loc_id IS NOT NULL THEN
    RETURN v_loc_id;
  END IF;

  v_code := 'SF-' || upper(left(replace(p_branch_id::text, '-', ''), 6));

  INSERT INTO public.inventory_locations (
    business_id,
    branch_id,
    name,
    code,
    location_type,
    is_active
  ) VALUES (
    p_business_id,
    p_branch_id,
    'Main Sales Floor',
    v_code,
    'sales_floor',
    true
  )
  ON CONFLICT (business_id, branch_id, code) DO UPDATE
    SET is_active = true,
        deleted_at = NULL,
        updated_at = NOW()
  RETURNING id INTO v_loc_id;

  RETURN v_loc_id;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_ensure_branch_sales_floor_location(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- =============================================================================
-- 3. UNIFIED ATOMIC POS SALE EXECUTION RPC (FOR OWNER & ALL ACTIVE STAFF)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_execute_unified_pos_sale(
  p_business_id UUID,
  p_payload JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_branch_id UUID;
  v_location_id UUID;
  v_tx_id UUID;
  v_tx_number TEXT;
  v_currency VARCHAR(3);
  v_subtotal NUMERIC(15, 4);
  v_discount_total NUMERIC(15, 4);
  v_tax_total NUMERIC(15, 4);
  v_total_amount NUMERIC(15, 4);
  v_amount_paid NUMERIC(15, 4);
  v_balance_due NUMERIC(15, 4);
  v_raw_pm TEXT;
  v_sql_pm TEXT;
  v_customer_id UUID := NULL;
  v_customer_name TEXT;
  v_customer_phone TEXT;
  v_customer_email TEXT;
  v_points_earned INTEGER := 0;
  v_new_loyalty_points INTEGER := 0;
  v_new_total_spent NUMERIC(15, 4) := 0;
  v_new_balance_credit NUMERIC(15, 4) := 0;
  v_raw_sales_rep TEXT;
  v_salesperson_uid UUID := NULL;
  v_staff_name TEXT;
  v_bank_account_id UUID := NULL;
  v_vault_id UUID := NULL;
  v_wallet_id UUID := NULL;
  v_acc_currency VARCHAR(3);
  v_notes TEXT;
  v_occurred_at TIMESTAMPTZ;
  v_meta JSONB;
  v_item JSONB;
  v_prod_id UUID;
  v_item_qty NUMERIC(15, 4);
  v_item_price NUMERIC(15, 4);
  v_item_cost NUMERIC(15, 4);
  v_item_disc NUMERIC(15, 4);
  v_item_tax NUMERIC(15, 4);
  v_item_line_total NUMERIC(15, 4);
  v_prior_stock NUMERIC(15, 4);
  v_cur_on_hand NUMERIC(15, 4);
  v_cur_reserved NUMERIC(15, 4);
  v_next_on_hand NUMERIC(15, 4);
  v_ws_stock_val TEXT;
  v_biz_meta JSONB;
  v_stock_results JSONB := '{}'::jsonb;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Active session required to execute POS sale';
  END IF;

  IF NOT public.fn_is_verified_workspace_member(p_business_id) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller is not an active member of business %', p_business_id;
  END IF;

  -- Ensure caller has a user_profiles row so FK cashier_user_id -> user_profiles(id) never fails
  INSERT INTO public.user_profiles (id, email, full_name, status)
  SELECT u.id, COALESCE(u.email, v_caller_id::text || '@fintab.local'),
         COALESCE(NULLIF(trim(u.raw_user_meta_data->>'full_name'), ''), split_part(COALESCE(u.email, 'Staff'), '@', 1)),
         'active'
  FROM auth.users u
  WHERE u.id = v_caller_id
  ON CONFLICT (id) DO NOTHING;

  -- Resolve branch_id
  BEGIN
    IF (p_payload->>'branch_id') IS NOT NULL AND (p_payload->>'branch_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      v_branch_id := (p_payload->>'branch_id')::UUID;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_branch_id := NULL;
  END;

  IF v_branch_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.branches br WHERE br.id = v_branch_id AND br.business_id = p_business_id AND br.deleted_at IS NULL
  ) THEN
    SELECT br.id INTO v_branch_id
    FROM public.branches br
    WHERE br.business_id = p_business_id AND br.deleted_at IS NULL
    ORDER BY br.is_main DESC, br.created_at ASC
    LIMIT 1;
  END IF;

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'BRANCH_NOT_FOUND: No active branch found for business %', p_business_id;
  END IF;

  v_location_id := public.fn_ensure_branch_sales_floor_location(p_business_id, v_branch_id);

  -- Resolve transaction ID & number
  BEGIN
    IF (p_payload->>'id') IS NOT NULL AND (p_payload->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      v_tx_id := (p_payload->>'id')::UUID;
    ELSE
      v_tx_id := gen_random_uuid();
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_tx_id := gen_random_uuid();
  END;

  -- Idempotency: if this sale transaction already exists, return its summary cleanly
  IF EXISTS (SELECT 1 FROM public.sales_transactions st WHERE st.business_id = p_business_id AND st.id = v_tx_id) THEN
    SELECT st.transaction_number, st.total_amount
    INTO v_tx_number, v_total_amount
    FROM public.sales_transactions st
    WHERE st.business_id = p_business_id AND st.id = v_tx_id;

    RETURN jsonb_build_object(
      'success', true,
      'idempotent_replay', true,
      'transaction_id', v_tx_id,
      'transaction_number', v_tx_number,
      'branch_id', v_branch_id,
      'total_amount', v_total_amount
    );
  END IF;

  v_tx_number := COALESCE(NULLIF(trim(p_payload->>'transaction_number'), ''), 'TX-' || right((extract(epoch from clock_timestamp()) * 1000)::bigint::text, 6));
  IF EXISTS (SELECT 1 FROM public.sales_transactions st WHERE st.business_id = p_business_id AND st.transaction_number = v_tx_number) THEN
    v_tx_number := v_tx_number || '-' || substr(replace(v_tx_id::text, '-', ''), 1, 4);
  END IF;

  SELECT upper(left(trim(COALESCE(NULLIF(p_payload->>'currency', ''), b.currency, 'HTG')), 3)),
         COALESCE(b.metadata, '{}'::jsonb)
  INTO v_currency, v_biz_meta
  FROM public.businesses b
  WHERE b.id = p_business_id;

  v_subtotal := GREATEST(0, ROUND(COALESCE((p_payload->>'subtotal')::NUMERIC, (p_payload->>'total')::NUMERIC, 0), 4));
  v_discount_total := GREATEST(0, ROUND(COALESCE((p_payload->>'discount')::NUMERIC, 0), 4));
  IF v_discount_total > v_subtotal THEN
    v_discount_total := v_subtotal;
  END IF;
  v_tax_total := GREATEST(0, ROUND(COALESCE((p_payload->>'tax')::NUMERIC, 0), 4));
  -- Enforce chk_sales_trans_math: total_amount = subtotal - discount_total + tax_total
  v_total_amount := ROUND(v_subtotal - v_discount_total + v_tax_total, 4);

  v_raw_pm := lower(trim(COALESCE(p_payload->>'payment_method', 'cash')));
  IF v_raw_pm = 'credit' OR v_raw_pm = 'store_credit' THEN
    v_sql_pm := 'store_credit';
    v_amount_paid := GREATEST(0, LEAST(v_total_amount, ROUND(COALESCE((p_payload->>'amount_paid')::NUMERIC, 0), 4)));
  ELSIF v_raw_pm IN ('bank', 'bank_transfer') THEN
    v_sql_pm := 'bank_transfer';
    v_amount_paid := v_total_amount;
  ELSIF v_raw_pm IN ('card', 'debit_card', 'credit_card') THEN
    v_sql_pm := 'debit_card';
    v_amount_paid := v_total_amount;
  ELSIF v_raw_pm IN ('moncash', 'natcash', 'mobile_money') THEN
    v_sql_pm := 'mobile_money';
    v_amount_paid := v_total_amount;
  ELSE
    v_sql_pm := 'cash';
    v_amount_paid := v_total_amount;
  END IF;

  v_balance_due := ROUND(v_total_amount - v_amount_paid, 4);
  v_occurred_at := COALESCE((p_payload->>'occurred_at')::TIMESTAMPTZ, NOW());
  v_notes := NULLIF(trim(COALESCE(p_payload->>'notes', '')), '');
  v_staff_name := COALESCE(NULLIF(trim(p_payload->>'staff_name'), ''), 'Staff');

  -- Resolve salesperson_user_id (must exist in user_profiles; if staff_profiles.id was passed, resolve its user_id)
  v_raw_sales_rep := trim(COALESCE(p_payload->>'sales_rep_id', ''));
  IF v_raw_sales_rep ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    SELECT up.id INTO v_salesperson_uid
    FROM public.user_profiles up
    WHERE up.id = v_raw_sales_rep::UUID;

    IF v_salesperson_uid IS NULL THEN
      SELECT sp.user_id INTO v_salesperson_uid
      FROM public.staff_profiles sp
      WHERE sp.business_id = p_business_id
        AND sp.id = v_raw_sales_rep::UUID
        AND sp.user_id IS NOT NULL
      LIMIT 1;
    END IF;
  END IF;
  v_salesperson_uid := COALESCE(v_salesperson_uid, v_caller_id);

  -- Resolve & Upsert Customer + Update Loyalty Points & Spend
  IF (p_payload->>'customer_id') IS NOT NULL AND (p_payload->>'customer_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    v_customer_id := (p_payload->>'customer_id')::UUID;
    v_customer_name := COALESCE(NULLIF(trim(p_payload->>'customer_name'), ''), 'Client');
    v_customer_phone := NULLIF(trim(COALESCE(p_payload->>'customer_phone', '')), '');
    v_customer_email := NULLIF(trim(COALESCE(p_payload->>'customer_email', '')), '');

    INSERT INTO public.customers (
      id,
      business_id,
      customer_number,
      full_name,
      phone,
      email,
      status,
      metadata,
      updated_at
    ) VALUES (
      v_customer_id,
      p_business_id,
      'CUST-' || upper(left(replace(v_customer_id::text, '-', ''), 6)),
      v_customer_name,
      v_customer_phone,
      v_customer_email,
      'active',
      '{}'::jsonb,
      NOW()
    )
    ON CONFLICT (id) DO NOTHING;

    -- Verify customer belongs to this business before linking FK
    IF EXISTS (SELECT 1 FROM public.customers c WHERE c.id = v_customer_id AND c.business_id = p_business_id) THEN
      v_points_earned := GREATEST(1, FLOOR(v_total_amount / 10.0)::INTEGER);

      UPDATE public.customers c
      SET
        metadata = COALESCE(c.metadata, '{}'::jsonb) || jsonb_build_object(
          'total_spent', ROUND(COALESCE((c.metadata->>'total_spent')::NUMERIC, 0) + v_total_amount, 2),
          'loyalty_points', COALESCE((c.metadata->>'loyalty_points')::INTEGER, 0) + v_points_earned,
          'balance_credit', ROUND(COALESCE((c.metadata->>'balance_credit')::NUMERIC, 0) + v_balance_due, 2),
          'last_purchase_at', v_occurred_at
        ),
        updated_at = NOW()
      WHERE c.id = v_customer_id
        AND c.business_id = p_business_id
      RETURNING
        COALESCE((metadata->>'loyalty_points')::INTEGER, 0),
        COALESCE((metadata->>'total_spent')::NUMERIC, 0),
        COALESCE((metadata->>'balance_credit')::NUMERIC, 0)
      INTO v_new_loyalty_points, v_new_total_spent, v_new_balance_credit;
    ELSE
      v_customer_id := NULL;
    END IF;
  END IF;

  -- Resolve Bank / Mobile Account UUID if non-cash
  IF (p_payload->>'bank_account_id') IS NOT NULL AND (p_payload->>'bank_account_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    v_bank_account_id := (p_payload->>'bank_account_id')::UUID;
  END IF;

  v_meta := COALESCE(p_payload->'metadata', '{}'::jsonb) || jsonb_build_object(
    'payment_method', COALESCE(p_payload->>'payment_method', 'Cash'),
    'bank_account_id', v_bank_account_id,
    'customer_id', v_customer_id,
    'customer_name', v_customer_name,
    'sales_rep_id', COALESCE(NULLIF(v_raw_sales_rep, ''), v_salesperson_uid::text),
    'salesperson_user_id', v_salesperson_uid,
    'staff_name', v_staff_name,
    'points_earned', v_points_earned
  );

  -- 1. Insert Sales Transaction Header
  INSERT INTO public.sales_transactions (
    id,
    business_id,
    branch_id,
    cashier_user_id,
    salesperson_user_id,
    customer_id,
    transaction_number,
    transaction_type,
    status,
    subtotal,
    discount_total,
    tax_total,
    total_amount,
    amount_paid,
    balance_due,
    currency,
    notes,
    occurred_at,
    metadata
  ) VALUES (
    v_tx_id,
    p_business_id,
    v_branch_id,
    v_caller_id,
    v_salesperson_uid,
    v_customer_id,
    v_tx_number,
    'sale',
    CASE WHEN v_balance_due > 0 AND v_amount_paid > 0 THEN 'partially_paid'
         WHEN v_balance_due > 0 AND v_amount_paid = 0 THEN 'completed'
         ELSE 'completed'
    END,
    v_subtotal,
    v_discount_total,
    v_tax_total,
    v_total_amount,
    v_amount_paid,
    v_balance_due,
    v_currency,
    v_notes,
    v_occurred_at,
    v_meta
  );

  -- 2. Loop over items: Insert sales_transaction_items AND deduct inventory_balances + log inventory_movements
  IF jsonb_typeof(p_payload->'items') = 'array' THEN
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_payload->'items')
    LOOP
      v_prod_id := NULL;
      BEGIN
        IF COALESCE(v_item->>'productId', v_item->>'product_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
          v_prod_id := COALESCE(v_item->>'productId', v_item->>'product_id')::UUID;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_prod_id := NULL;
      END;

      v_item_qty := GREATEST(0.0001, ROUND(COALESCE((v_item->>'qty')::NUMERIC, (v_item->>'quantity')::NUMERIC, 1), 4));
      v_item_price := GREATEST(0, ROUND(COALESCE((v_item->>'price')::NUMERIC, (v_item->>'unit_price')::NUMERIC, 0), 4));
      v_item_cost := GREATEST(0, ROUND(COALESCE((v_item->>'costPrice')::NUMERIC, (v_item->>'cost_price')::NUMERIC, 0), 4));
      v_item_disc := GREATEST(0, ROUND(COALESCE((v_item->>'discountAmount')::NUMERIC, 0), 4));
      v_item_tax := GREATEST(0, ROUND(COALESCE((v_item->>'taxAmount')::NUMERIC, 0), 4));
      v_item_line_total := GREATEST(0, ROUND((v_item_qty * v_item_price) - v_item_disc + v_item_tax, 4));

      IF v_prod_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.products p WHERE p.id = v_prod_id AND p.business_id = p_business_id
      ) THEN
        INSERT INTO public.sales_transaction_items (
          business_id,
          transaction_id,
          product_id,
          inventory_location_id,
          quantity,
          unit_price,
          discount_amount,
          tax_amount,
          line_total,
          cost_price,
          salesperson_user_id
        ) VALUES (
          p_business_id,
          v_tx_id,
          v_prod_id,
          v_location_id,
          v_item_qty,
          v_item_price,
          v_item_disc,
          v_item_tax,
          v_item_line_total,
          v_item_cost,
          v_salesperson_uid
        );

        -- Seed inventory_balances from prior_stock or workspace_sync stock if row doesn't exist yet
        v_prior_stock := GREATEST(0, COALESCE((v_item->>'priorStock')::NUMERIC, 0));
        IF v_prior_stock = 0 AND jsonb_typeof(v_biz_meta #> '{workspace_sync,products}') = 'array' THEN
          SELECT COALESCE(
            (wp->'currentStock'->>(v_branch_id::text))::NUMERIC,
            (SELECT MAX((kv.value)::NUMERIC) FROM jsonb_each_text(COALESCE(wp->'currentStock', '{}'::jsonb)) kv WHERE kv.value ~ '^-?[0-9]+(\.[0-9]+)?$'),
            0
          )
          INTO v_prior_stock
          FROM jsonb_array_elements(v_biz_meta #> '{workspace_sync,products}') wp
          WHERE wp->>'id' = v_prod_id::text
          LIMIT 1;
          v_prior_stock := COALESCE(v_prior_stock, 0);
        END IF;

        INSERT INTO public.inventory_balances (
          business_id,
          branch_id,
          location_id,
          product_id,
          on_hand_quantity,
          reserved_quantity,
          average_unit_cost,
          updated_at
        ) VALUES (
          p_business_id,
          v_branch_id,
          v_location_id,
          v_prod_id,
          GREATEST(v_prior_stock, v_item_qty),
          0.0000,
          v_item_cost,
          NOW()
        )
        ON CONFLICT (business_id, location_id, product_id) DO NOTHING;

        SELECT ib.on_hand_quantity, ib.reserved_quantity
        INTO v_cur_on_hand, v_cur_reserved
        FROM public.inventory_balances ib
        WHERE ib.business_id = p_business_id
          AND ib.location_id = v_location_id
          AND ib.product_id = v_prod_id
        FOR UPDATE;

        -- If existing balance was 0 because product was initialized in workspace_sync with >0 stock and zero SALE movements exist, seed from v_prior_stock
        IF v_cur_on_hand = 0 AND v_prior_stock > 0 AND NOT EXISTS (
          SELECT 1 FROM public.inventory_movements im
          WHERE im.business_id = p_business_id AND im.product_id = v_prod_id
        ) THEN
          v_cur_on_hand := v_prior_stock;
        END IF;

        v_next_on_hand := GREATEST(v_cur_reserved, v_cur_on_hand - v_item_qty);

        UPDATE public.inventory_balances
        SET on_hand_quantity = v_next_on_hand,
            updated_at = NOW()
        WHERE business_id = p_business_id
          AND location_id = v_location_id
          AND product_id = v_prod_id;

        -- Also keep any secondary location rows in sync if single-location branch
        INSERT INTO public.inventory_movements (
          business_id,
          branch_id,
          location_id,
          product_id,
          movement_type,
          quantity,
          unit_cost,
          reference_type,
          reference_id,
          notes,
          actor_id,
          created_at
        ) VALUES (
          p_business_id,
          v_branch_id,
          v_location_id,
          v_prod_id,
          'SALE',
          -v_item_qty,
          v_item_cost,
          'sale',
          v_tx_id,
          'POS Sale #' || v_tx_number || ' by ' || v_staff_name,
          v_caller_id,
          v_occurred_at
        );

        v_stock_results := v_stock_results || jsonb_build_object(v_prod_id::text, v_next_on_hand);
      END IF;
    END LOOP;
  END IF;

  -- 3. Record Payment & Settle Treasury Account (Cash Vault vs Bank Account vs Mobile Money Wallet)
  IF v_amount_paid > 0 AND v_sql_pm <> 'store_credit' THEN
    -- Validate whether v_bank_account_id belongs to public.bank_accounts or public.mobile_money_wallets
    IF v_bank_account_id IS NOT NULL THEN
      SELECT ba.currency INTO v_acc_currency
      FROM public.bank_accounts ba
      WHERE ba.id = v_bank_account_id AND ba.business_id = p_business_id AND ba.deleted_at IS NULL;

      IF NOT FOUND THEN
        SELECT w.id, w.currency INTO v_wallet_id, v_acc_currency
        FROM public.mobile_money_wallets w
        WHERE w.id = v_bank_account_id AND w.business_id = p_business_id AND w.deleted_at IS NULL;
        v_bank_account_id := NULL;
      END IF;
    END IF;

    -- Auto-resolve first active bank account if payment method is bank_transfer/card and no valid UUID was supplied
    IF v_sql_pm IN ('bank_transfer', 'debit_card') AND v_bank_account_id IS NULL THEN
      SELECT ba.id, ba.currency INTO v_bank_account_id, v_acc_currency
      FROM public.bank_accounts ba
      WHERE ba.business_id = p_business_id AND ba.deleted_at IS NULL AND ba.status = 'active'
      ORDER BY ba.is_primary DESC, ba.created_at ASC
      LIMIT 1;
    END IF;

    INSERT INTO public.payments (
      business_id,
      branch_id,
      transaction_id,
      payment_number,
      payment_method,
      amount,
      currency,
      status,
      bank_account_id,
      received_by,
      occurred_at
    ) VALUES (
      p_business_id,
      v_branch_id,
      v_tx_id,
      'PAY-' || substr(replace(v_tx_id::text, '-', ''), 1, 10),
      v_sql_pm,
      v_amount_paid,
      v_currency,
      'completed',
      CASE WHEN v_sql_pm <> 'cash' THEN v_bank_account_id ELSE NULL END,
      v_caller_id,
      v_occurred_at
    )
    ON CONFLICT (business_id, payment_number) DO NOTHING;

    IF v_sql_pm = 'cash' THEN
      -- Ensure Main Cash Vault exists in public.business_cash_vaults and credit it
      SELECT v.id, v.currency INTO v_vault_id, v_acc_currency
      FROM public.business_cash_vaults v
      WHERE v.business_id = p_business_id AND v.deleted_at IS NULL AND v.status = 'active'
      ORDER BY v.created_at ASC
      LIMIT 1;

      IF v_vault_id IS NULL THEN
        INSERT INTO public.business_cash_vaults (
          business_id,
          branch_id,
          vault_name,
          vault_code,
          currency,
          status,
          custodian_user_id
        ) VALUES (
          p_business_id,
          v_branch_id,
          'Main Cash Till',
          'TILL-MAIN',
          v_currency,
          'active',
          v_caller_id
        )
        ON CONFLICT (business_id, vault_code) DO UPDATE
          SET status = 'active', deleted_at = NULL, updated_at = NOW()
        RETURNING id, currency INTO v_vault_id, v_acc_currency;
      END IF;

      INSERT INTO public.vault_transactions (
        business_id,
        vault_id,
        direction,
        amount,
        currency,
        transaction_type,
        description,
        actor_user_id,
        idempotency_key,
        occurred_at,
        metadata
      ) VALUES (
        p_business_id,
        v_vault_id,
        'in',
        v_amount_paid,
        COALESCE(v_acc_currency, v_currency),
        'deposit',
        'Cash POS Sale #' || v_tx_number || ' (' || v_staff_name || ')',
        v_caller_id,
        v_tx_id,
        v_occurred_at,
        jsonb_build_object('sale_id', v_tx_id, 'transaction_number', v_tx_number)
      )
      ON CONFLICT (business_id, idempotency_key) DO NOTHING;

    ELSIF v_bank_account_id IS NOT NULL THEN
      INSERT INTO public.bank_transactions (
        business_id,
        bank_account_id,
        transaction_type,
        direction,
        amount,
        currency,
        source_type,
        source_id,
        reference_number,
        description,
        actor_user_id,
        occurred_at,
        metadata
      )
      SELECT
        p_business_id,
        v_bank_account_id,
        'deposit',
        'credit',
        v_amount_paid,
        COALESCE(v_acc_currency, v_currency),
        'payment',
        v_tx_id,
        v_tx_number,
        'POS Sale #' || v_tx_number || ' (' || COALESCE(p_payload->>'payment_method', 'Bank') || ' • ' || v_staff_name || ')',
        v_caller_id,
        v_occurred_at,
        jsonb_build_object('sale_id', v_tx_id, 'transaction_number', v_tx_number)
      WHERE NOT EXISTS (
        SELECT 1 FROM public.bank_transactions bt
        WHERE bt.business_id = p_business_id
          AND bt.bank_account_id = v_bank_account_id
          AND bt.source_id = v_tx_id
          AND bt.direction = 'credit'
      );

    ELSIF v_wallet_id IS NOT NULL THEN
      INSERT INTO public.mobile_money_transactions (
        business_id,
        wallet_id,
        direction,
        amount,
        fee_amount,
        currency,
        transaction_type,
        reference_code,
        notes,
        actor_user_id,
        idempotency_key,
        occurred_at
      ) VALUES (
        p_business_id,
        v_wallet_id,
        'in',
        v_amount_paid,
        0.0000,
        COALESCE(v_acc_currency, v_currency),
        'deposit',
        v_tx_number,
        'POS Sale #' || v_tx_number || ' (' || v_staff_name || ')',
        v_caller_id,
        v_tx_id,
        v_occurred_at
      )
      ON CONFLICT (business_id, idempotency_key) DO NOTHING;
    END IF;
  END IF;

  -- 4. Touch businesses.updated_at so all connected Owner/Staff browsers detect the update immediately
  UPDATE public.businesses
  SET updated_at = NOW()
  WHERE id = p_business_id;

  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_tx_id,
    'transaction_number', v_tx_number,
    'branch_id', v_branch_id,
    'settlement_account_id', COALESCE(v_bank_account_id, v_wallet_id, v_vault_id),
    'customer_id', v_customer_id,
    'points_earned', v_points_earned,
    'customer_loyalty_points', v_new_loyalty_points,
    'customer_total_spent', v_new_total_spent,
    'customer_balance_credit', v_new_balance_credit,
    'stock_by_product', v_stock_results
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_execute_unified_pos_sale(UUID, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_execute_unified_pos_sale(UUID, JSONB) TO authenticated;

-- =============================================================================
-- 4. UNIFIED SALE REVERSAL / REFUND / DELETE RPC (RESTOCK VS WRITE-OFF)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_execute_unified_sale_reversal(
  p_business_id UUID,
  p_sale_id UUID,
  p_restock BOOLEAN DEFAULT TRUE,
  p_refund_amount NUMERIC DEFAULT NULL,
  p_reason TEXT DEFAULT 'Sale Reversal',
  p_action TEXT DEFAULT 'refund'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_sale RECORD;
  v_item RECORD;
  v_loc_id UUID;
  v_refund_amt NUMERIC(15, 4);
  v_ratio NUMERIC(15, 6);
  v_pts_to_reverse INTEGER;
  v_orig_comm NUMERIC(15, 4);
  v_rev_comm NUMERIC(15, 4);
  v_vault_id UUID;
  v_idem_key UUID := gen_random_uuid();
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Active session required';
  END IF;

  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission(p_business_id, 'sales:refund')
    OR public.has_permission(p_business_id, 'sales:manage')
  ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller lacks refund/reversal clearance';
  END IF;

  SELECT * INTO v_sale
  FROM public.sales_transactions st
  WHERE st.business_id = p_business_id
    AND st.id = p_sale_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'NOT_FOUND');
  END IF;

  IF v_sale.status IN ('refunded', 'voided') AND p_action <> 'delete' THEN
    RETURN jsonb_build_object('success', true, 'already_reversed', true);
  END IF;

  v_refund_amt := COALESCE(p_refund_amount, v_sale.total_amount);
  v_refund_amt := GREATEST(0, LEAST(v_sale.total_amount, ROUND(v_refund_amt, 4)));
  v_ratio := CASE WHEN v_sale.total_amount > 0 THEN LEAST(1, v_refund_amt / v_sale.total_amount) ELSE 1 END;

  -- 1. Restock items if requested and not previously restocked
  IF p_restock AND v_sale.status NOT IN ('refunded', 'voided') THEN
    v_loc_id := public.fn_ensure_branch_sales_floor_location(p_business_id, v_sale.branch_id);

    FOR v_item IN
      SELECT sti.product_id, sti.quantity, sti.cost_price, COALESCE(sti.inventory_location_id, v_loc_id) AS loc_id
      FROM public.sales_transaction_items sti
      WHERE sti.business_id = p_business_id
        AND sti.transaction_id = p_sale_id
    LOOP
      INSERT INTO public.inventory_balances (
        business_id, branch_id, location_id, product_id, on_hand_quantity, reserved_quantity, average_unit_cost, updated_at
      ) VALUES (
        p_business_id, v_sale.branch_id, v_item.loc_id, v_item.product_id, v_item.quantity, 0, COALESCE(v_item.cost_price, 0), NOW()
      )
      ON CONFLICT (business_id, location_id, product_id) DO UPDATE
        SET on_hand_quantity = public.inventory_balances.on_hand_quantity + v_item.quantity,
            updated_at = NOW();

      INSERT INTO public.inventory_movements (
        business_id, branch_id, location_id, product_id, movement_type, quantity, unit_cost, reference_type, reference_id, notes, actor_id
      ) VALUES (
        p_business_id, v_sale.branch_id, v_item.loc_id, v_item.product_id, 'RETURN', v_item.quantity, COALESCE(v_item.cost_price, 0), 'return', p_sale_id,
        COALESCE(p_reason, 'Returned & Restocked from #' || v_sale.transaction_number), v_caller_id
      );
    END LOOP;
  END IF;

  -- 2. Reverse Customer Spend, Loyalty Points & Credit
  IF v_sale.customer_id IS NOT NULL AND v_sale.status NOT IN ('refunded', 'voided') THEN
    v_pts_to_reverse := GREATEST(0, ROUND(COALESCE((v_sale.metadata->>'points_earned')::NUMERIC, FLOOR(v_sale.total_amount / 10.0)) * v_ratio)::INTEGER);
    UPDATE public.customers c
    SET metadata = COALESCE(c.metadata, '{}'::jsonb) || jsonb_build_object(
      'total_spent', GREATEST(0, ROUND(COALESCE((c.metadata->>'total_spent')::NUMERIC, 0) - v_refund_amt, 2)),
      'loyalty_points', GREATEST(0, COALESCE((c.metadata->>'loyalty_points')::INTEGER, 0) - v_pts_to_reverse),
      'balance_credit', CASE
        WHEN v_sale.balance_due > 0 THEN GREATEST(0, ROUND(COALESCE((c.metadata->>'balance_credit')::NUMERIC, 0) - (v_sale.balance_due * v_ratio), 2))
        ELSE COALESCE((c.metadata->>'balance_credit')::NUMERIC, 0)
      END
    ),
    updated_at = NOW()
    WHERE c.business_id = p_business_id AND c.id = v_sale.customer_id;
  END IF;

  -- 3. Reverse Treasury (Bank or Cash Vault) if not previously reversed
  IF v_refund_amt > 0 AND v_sale.amount_paid > 0 AND v_sale.status NOT IN ('refunded', 'voided') THEN
    IF (v_sale.metadata->>'bank_account_id') IS NOT NULL
       AND (v_sale.metadata->>'bank_account_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       AND lower(COALESCE(v_sale.metadata->>'payment_method', 'cash')) <> 'cash' THEN
      IF EXISTS (
        SELECT 1 FROM public.bank_accounts ba
        WHERE ba.id = (v_sale.metadata->>'bank_account_id')::UUID AND ba.business_id = p_business_id AND ba.deleted_at IS NULL
      ) THEN
        INSERT INTO public.bank_transactions (
          business_id, bank_account_id, transaction_type, direction, amount, currency, source_type, source_id, reference_number, description, actor_user_id, occurred_at
        ) VALUES (
          p_business_id, (v_sale.metadata->>'bank_account_id')::UUID, 'withdrawal', 'debit', LEAST(v_refund_amt, v_sale.amount_paid), v_sale.currency,
          'payment', p_sale_id, v_sale.transaction_number, 'Refund #' || v_sale.transaction_number || ': ' || COALESCE(p_reason, ''), v_caller_id, NOW()
        );
      END IF;
    ELSIF lower(COALESCE(v_sale.metadata->>'payment_method', 'cash')) = 'cash' THEN
      SELECT v.id INTO v_vault_id
      FROM public.business_cash_vaults v
      WHERE v.business_id = p_business_id AND v.deleted_at IS NULL AND v.status = 'active'
      ORDER BY v.created_at ASC
      LIMIT 1;

      IF v_vault_id IS NOT NULL THEN
        INSERT INTO public.vault_transactions (
          business_id, vault_id, direction, amount, currency, transaction_type, description, actor_user_id, idempotency_key, occurred_at
        ) VALUES (
          p_business_id, v_vault_id, 'out', LEAST(v_refund_amt, v_sale.amount_paid), v_sale.currency, 'withdrawal',
          'Cash Refund #' || v_sale.transaction_number || ': ' || COALESCE(p_reason, ''), v_caller_id, v_idem_key, NOW()
        );
      END IF;
    END IF;
  END IF;

  -- 4. Update Sales Transaction Status & Commission Metadata
  v_orig_comm := COALESCE((v_sale.metadata->>'total_commission')::NUMERIC, 0);
  v_rev_comm := ROUND(v_orig_comm * v_ratio, 2);

  UPDATE public.sales_transactions st
  SET status = CASE WHEN p_action = 'delete' THEN 'voided' ELSE 'refunded' END,
      notes = COALESCE(st.notes || ' | ', '') || COALESCE(p_reason, 'Reversed'),
      metadata = COALESCE(st.metadata, '{}'::jsonb) || jsonb_build_object(
        'refund_restocked', p_restock,
        'refunded_at', NOW(),
        'refund_amount', v_refund_amt,
        'reversed_commission', v_rev_comm,
        'total_commission', GREATEST(0, v_orig_comm - v_rev_comm),
        'is_deleted', (p_action = 'delete')
      ),
      updated_at = NOW()
  WHERE st.business_id = p_business_id
    AND st.id = p_sale_id;

  UPDATE public.businesses SET updated_at = NOW() WHERE id = p_business_id;

  RETURN jsonb_build_object(
    'success', true,
    'sale_id', p_sale_id,
    'restocked', p_restock,
    'refund_amount', v_refund_amt
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_execute_unified_sale_reversal(UUID, UUID, BOOLEAN, NUMERIC, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_execute_unified_sale_reversal(UUID, UUID, BOOLEAN, NUMERIC, TEXT, TEXT) TO authenticated;

-- =============================================================================
-- 5. ATOMIC STOCK RESTOCK / ADJUSTMENT RPC (AUTO-INITIALIZES MISSING BALANCES)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_post_member_stock_change(
  p_business_id UUID,
  p_branch_id UUID,
  p_product_id UUID,
  p_delta NUMERIC,
  p_prior_stock NUMERIC DEFAULT 0,
  p_reason TEXT DEFAULT 'Stock Adjustment'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_branch_id UUID := p_branch_id;
  v_loc_id UUID;
  v_cur_on_hand NUMERIC(15, 4);
  v_cur_reserved NUMERIC(15, 4);
  v_next_on_hand NUMERIC(15, 4);
  v_move_type TEXT;
  v_ref_type TEXT;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Active session required';
  END IF;

  IF NOT public.fn_is_verified_workspace_member(p_business_id) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Not a verified member of business %', p_business_id;
  END IF;

  IF p_delta = 0 THEN
    RETURN jsonb_build_object('success', true, 'on_hand_quantity', COALESCE(p_prior_stock, 0));
  END IF;

  IF v_branch_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.branches br WHERE br.id = v_branch_id AND br.business_id = p_business_id AND br.deleted_at IS NULL
  ) THEN
    SELECT br.id INTO v_branch_id
    FROM public.branches br
    WHERE br.business_id = p_business_id AND br.deleted_at IS NULL
    ORDER BY br.is_main DESC, br.created_at ASC
    LIMIT 1;
  END IF;

  v_loc_id := public.fn_ensure_branch_sales_floor_location(p_business_id, v_branch_id);

  INSERT INTO public.inventory_balances (
    business_id, branch_id, location_id, product_id, on_hand_quantity, reserved_quantity, average_unit_cost, updated_at
  ) VALUES (
    p_business_id, v_branch_id, v_loc_id, p_product_id, GREATEST(0, COALESCE(p_prior_stock, 0)), 0, 0, NOW()
  )
  ON CONFLICT (business_id, location_id, product_id) DO NOTHING;

  SELECT ib.on_hand_quantity, ib.reserved_quantity
  INTO v_cur_on_hand, v_cur_reserved
  FROM public.inventory_balances ib
  WHERE ib.business_id = p_business_id
    AND ib.location_id = v_loc_id
    AND ib.product_id = p_product_id
  FOR UPDATE;

  IF v_cur_on_hand = 0 AND COALESCE(p_prior_stock, 0) > 0 AND p_delta < 0 AND NOT EXISTS (
    SELECT 1 FROM public.inventory_movements im
    WHERE im.business_id = p_business_id AND im.product_id = p_product_id
  ) THEN
    v_cur_on_hand := p_prior_stock;
  END IF;

  v_next_on_hand := GREATEST(v_cur_reserved, v_cur_on_hand + p_delta);

  UPDATE public.inventory_balances
  SET on_hand_quantity = v_next_on_hand,
      updated_at = NOW()
  WHERE business_id = p_business_id
    AND location_id = v_loc_id
    AND product_id = p_product_id;

  IF p_delta > 0 THEN
    IF lower(COALESCE(p_reason, '')) LIKE '%return%' OR lower(COALESCE(p_reason, '')) LIKE '%refund%' THEN
      v_move_type := 'RETURN';
      v_ref_type := 'return';
    ELSE
      v_move_type := 'ADJUSTMENT_IN';
      v_ref_type := 'adjustment';
    END IF;
  ELSE
    IF lower(COALESCE(p_reason, '')) LIKE '%sale%' THEN
      v_move_type := 'SALE';
      v_ref_type := 'sale';
    ELSE
      v_move_type := 'ADJUSTMENT_OUT';
      v_ref_type := 'adjustment';
    END IF;
  END IF;

  INSERT INTO public.inventory_movements (
    business_id, branch_id, location_id, product_id, movement_type, quantity, unit_cost, reference_type, notes, actor_id
  ) VALUES (
    p_business_id, v_branch_id, v_loc_id, p_product_id, v_move_type, p_delta, 0, v_ref_type, p_reason, v_caller_id
  );

  UPDATE public.businesses SET updated_at = NOW() WHERE id = p_business_id;

  RETURN jsonb_build_object(
    'success', true,
    'branch_id', v_branch_id,
    'location_id', v_loc_id,
    'previous_quantity', v_cur_on_hand,
    'on_hand_quantity', v_next_on_hand
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_post_member_stock_change(UUID, UUID, UUID, NUMERIC, NUMERIC, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_post_member_stock_change(UUID, UUID, UUID, NUMERIC, NUMERIC, TEXT) TO authenticated;

-- =============================================================================
-- 6. SAFE MEMBER WORKSPACE SYNC MERGE RPC (SO STAFF SYNC REACHES OWNER!)
-- =============================================================================
-- Non-owner staff cannot run direct UPDATE on public.businesses due to owner-only
-- RLS. This SECURITY DEFINER RPC merges ONLY safe operational collections (sales,
-- products stock, customers, expenses requests, receiptCorrectionRequests,
-- userNotifications, proformas) without allowing staff to alter permissions,
-- roles, memberships, or business settings.
CREATE OR REPLACE FUNCTION public.rpc_merge_member_workspace_state(
  p_business_id UUID,
  p_patch JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_meta JSONB;
  v_ws JSONB;
  v_del_sales JSONB;

  -- Helper merge-by-id inline via CTE
  v_merged_sales JSONB;
  v_merged_customers JSONB;
  v_merged_expenses JSONB;
  v_merged_notifs JSONB;
  v_merged_reqs JSONB;
  v_merged_proformas JSONB;
  v_merged_products JSONB;
  v_merged_bank_txs JSONB;
  v_merged_bank_accs JSONB;
BEGIN
  IF NOT public.fn_is_verified_workspace_member(p_business_id) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Caller is not an active member of business %', p_business_id;
  END IF;

  SELECT COALESCE(b.metadata, '{}'::jsonb)
  INTO v_meta
  FROM public.businesses b
  WHERE b.id = p_business_id
  FOR UPDATE;

  v_ws := COALESCE(v_meta->'workspace_sync', jsonb_build_object('businessId', p_business_id));
  v_del_sales := COALESCE(v_ws->'deletedSaleIds', '[]'::jsonb);

  -- Merge Sales by id
  IF jsonb_typeof(p_patch->'sales') = 'array' THEN
    SELECT COALESCE(jsonb_agg(val), '[]'::jsonb) INTO v_merged_sales
    FROM (
      SELECT DISTINCT ON (item->>'id') item AS val
      FROM (
        SELECT item, 2 AS prio FROM jsonb_array_elements(p_patch->'sales') item WHERE item->>'id' IS NOT NULL
        UNION ALL
        SELECT item, 1 AS prio FROM jsonb_array_elements(
          CASE WHEN jsonb_typeof(v_ws->'sales') = 'array' THEN v_ws->'sales' ELSE '[]'::jsonb END
        ) item WHERE item->>'id' IS NOT NULL
      ) s
      WHERE NOT (v_del_sales ? (s.item->>'id'))
      ORDER BY item->>'id', prio DESC
    ) merged;
    v_ws := jsonb_set(v_ws, '{sales}', v_merged_sales, true);
  END IF;

  -- Merge Customers by id (taking highest loyaltyPoints / totalSpent unless refunded)
  IF jsonb_typeof(p_patch->'customers') = 'array' THEN
    SELECT COALESCE(jsonb_agg(val), '[]'::jsonb) INTO v_merged_customers
    FROM (
      SELECT DISTINCT ON (item->>'id') item AS val
      FROM (
        SELECT item, COALESCE((item->>'loyaltyPoints')::NUMERIC, 0) AS pts, 2 AS prio
        FROM jsonb_array_elements(p_patch->'customers') item WHERE item->>'id' IS NOT NULL
        UNION ALL
        SELECT item, COALESCE((item->>'loyaltyPoints')::NUMERIC, 0) AS pts, 1 AS prio
        FROM jsonb_array_elements(
          CASE WHEN jsonb_typeof(v_ws->'customers') = 'array' THEN v_ws->'customers' ELSE '[]'::jsonb END
        ) item WHERE item->>'id' IS NOT NULL
      ) c
      ORDER BY item->>'id', pts DESC, prio DESC
    ) merged;
    v_ws := jsonb_set(v_ws, '{customers}', v_merged_customers, true);
  END IF;

  -- Merge Products stock updates (preserving product details, updating currentStock & stockUpdatedAt when newer)
  IF jsonb_typeof(p_patch->'products') = 'array' AND jsonb_typeof(v_ws->'products') = 'array' THEN
    SELECT COALESCE(jsonb_agg(
      CASE
        WHEN patch_p.item IS NOT NULL AND (
          COALESCE(patch_p.item->>'stockUpdatedAt', '') >= COALESCE(orig_p.item->>'stockUpdatedAt', '')
        ) THEN orig_p.item || jsonb_build_object(
          'currentStock', COALESCE(patch_p.item->'currentStock', orig_p.item->'currentStock'),
          'stockUpdatedAt', COALESCE(patch_p.item->>'stockUpdatedAt', orig_p.item->>'stockUpdatedAt')
        )
        ELSE orig_p.item
      END
    ), v_ws->'products')
    INTO v_merged_products
    FROM jsonb_array_elements(v_ws->'products') orig_p(item)
    LEFT JOIN LATERAL (
      SELECT p_it AS item
      FROM jsonb_array_elements(p_patch->'products') p_it
      WHERE p_it->>'id' = orig_p.item->>'id'
      LIMIT 1
    ) patch_p ON TRUE;
    v_ws := jsonb_set(v_ws, '{products}', v_merged_products, true);
  END IF;

  -- Merge Expenses (staff expense requests) without overwriting Paid/Approved status with Pending
  IF jsonb_typeof(p_patch->'expenses') = 'array' THEN
    SELECT COALESCE(jsonb_agg(val), '[]'::jsonb) INTO v_merged_expenses
    FROM (
      SELECT DISTINCT ON (item->>'id') item AS val
      FROM (
        SELECT item,
               CASE COALESCE(item->>'paymentStatus', item->>'status', '')
                 WHEN 'Paid' THEN 4 WHEN 'Rejected' THEN 3 WHEN 'Approved' THEN 2 WHEN 'Pending Approval' THEN 1 ELSE 0
               END AS rank_val,
               1 AS prio
        FROM jsonb_array_elements(
          CASE WHEN jsonb_typeof(v_ws->'expenses') = 'array' THEN v_ws->'expenses' ELSE '[]'::jsonb END
        ) item WHERE item->>'id' IS NOT NULL
        UNION ALL
        SELECT item,
               CASE COALESCE(item->>'paymentStatus', item->>'status', '')
                 WHEN 'Paid' THEN 4 WHEN 'Rejected' THEN 3 WHEN 'Approved' THEN 2 WHEN 'Pending Approval' THEN 1 ELSE 0
               END AS rank_val,
               2 AS prio
        FROM jsonb_array_elements(p_patch->'expenses') item WHERE item->>'id' IS NOT NULL
      ) e
      ORDER BY item->>'id', rank_val DESC, prio DESC
    ) merged;
    v_ws := jsonb_set(v_ws, '{expenses}', v_merged_expenses, true);
  END IF;

  -- Merge Receipt Correction Requests
  IF jsonb_typeof(p_patch->'receiptCorrectionRequests') = 'array' THEN
    SELECT COALESCE(jsonb_agg(val), '[]'::jsonb) INTO v_merged_reqs
    FROM (
      SELECT DISTINCT ON (item->>'id') item AS val
      FROM (
        SELECT item, CASE WHEN COALESCE(item->>'status', 'pending') <> 'pending' THEN 2 ELSE 1 END AS st_rank, 1 AS prio
        FROM jsonb_array_elements(
          CASE WHEN jsonb_typeof(v_ws->'receiptCorrectionRequests') = 'array' THEN v_ws->'receiptCorrectionRequests' ELSE '[]'::jsonb END
        ) item WHERE item->>'id' IS NOT NULL
        UNION ALL
        SELECT item, CASE WHEN COALESCE(item->>'status', 'pending') <> 'pending' THEN 2 ELSE 1 END AS st_rank, 2 AS prio
        FROM jsonb_array_elements(p_patch->'receiptCorrectionRequests') item WHERE item->>'id' IS NOT NULL
      ) r
      ORDER BY item->>'id', st_rank DESC, prio DESC
    ) merged;
    v_ws := jsonb_set(v_ws, '{receiptCorrectionRequests}', v_merged_reqs, true);
  END IF;

  -- Merge User Notifications (keep latest 150)
  IF jsonb_typeof(p_patch->'userNotifications') = 'array' THEN
    SELECT COALESCE(jsonb_agg(val), '[]'::jsonb) INTO v_merged_notifs
    FROM (
      SELECT val FROM (
        SELECT DISTINCT ON (item->>'id') item AS val, COALESCE(item->>'date', '') AS dt
        FROM (
          SELECT item, 2 AS prio FROM jsonb_array_elements(p_patch->'userNotifications') item WHERE item->>'id' IS NOT NULL
          UNION ALL
          SELECT item, 1 AS prio FROM jsonb_array_elements(
            CASE WHEN jsonb_typeof(v_ws->'userNotifications') = 'array' THEN v_ws->'userNotifications' ELSE '[]'::jsonb END
          ) item WHERE item->>'id' IS NOT NULL
        ) n
        ORDER BY item->>'id', prio DESC
      ) dedup
      ORDER BY dt DESC
      LIMIT 150
    ) capped;
    v_ws := jsonb_set(v_ws, '{userNotifications}', v_merged_notifs, true);
  END IF;

  -- Merge Proformas
  IF jsonb_typeof(p_patch->'proformas') = 'array' THEN
    SELECT COALESCE(jsonb_agg(val), '[]'::jsonb) INTO v_merged_proformas
    FROM (
      SELECT DISTINCT ON (item->>'id') item AS val
      FROM (
        SELECT item, 2 AS prio FROM jsonb_array_elements(p_patch->'proformas') item WHERE item->>'id' IS NOT NULL
        UNION ALL
        SELECT item, 1 AS prio FROM jsonb_array_elements(
          CASE WHEN jsonb_typeof(v_ws->'proformas') = 'array' THEN v_ws->'proformas' ELSE '[]'::jsonb END
        ) item WHERE item->>'id' IS NOT NULL
      ) pf
      ORDER BY item->>'id', prio DESC
    ) merged;
    v_ws := jsonb_set(v_ws, '{proformas}', v_merged_proformas, true);
  END IF;

  -- Merge Cash Till / Bank Transactions recorded during POS sales
  IF jsonb_typeof(p_patch->'bankTransactions') = 'array' THEN
    SELECT COALESCE(jsonb_agg(val), '[]'::jsonb) INTO v_merged_bank_txs
    FROM (
      SELECT DISTINCT ON (item->>'id') item AS val
      FROM (
        SELECT item, 2 AS prio FROM jsonb_array_elements(p_patch->'bankTransactions') item WHERE item->>'id' IS NOT NULL
        UNION ALL
        SELECT item, 1 AS prio FROM jsonb_array_elements(
          CASE WHEN jsonb_typeof(v_ws->'bankTransactions') = 'array' THEN v_ws->'bankTransactions' ELSE '[]'::jsonb END
        ) item WHERE item->>'id' IS NOT NULL
      ) bt
      ORDER BY item->>'id', prio DESC
    ) merged;
    v_ws := jsonb_set(v_ws, '{bankTransactions}', v_merged_bank_txs, true);
  END IF;

  v_ws := jsonb_set(v_ws, '{updatedAt}', to_jsonb(NOW()::text), true);
  v_meta := jsonb_set(v_meta, '{workspace_sync}', v_ws, true);

  UPDATE public.businesses
  SET metadata = v_meta,
      updated_at = NOW()
  WHERE id = p_business_id;

  RETURN jsonb_build_object('success', true, 'updated_at', NOW());
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_merge_member_workspace_state(UUID, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_merge_member_workspace_state(UUID, JSONB) TO authenticated;

-- =============================================================================
-- 7. ONE-TIME IDEMPOTENT RECONCILIATION OF HISTORICAL SALES STOCK, POINTS & TILL
-- =============================================================================
DO $$
DECLARE
  r_sale RECORD;
  r_item RECORD;
  v_loc_id UUID;
  v_vault_id UUID;
  v_bank_id UUID;
  v_acc_curr VARCHAR(3);
BEGIN
  -- 7a. Deduct unrecorded stock movements for existing completed sales_transactions
  FOR r_item IN
    SELECT
      st.id AS sale_id,
      st.business_id,
      st.branch_id,
      st.transaction_number,
      st.cashier_user_id,
      st.occurred_at,
      sti.product_id,
      sti.quantity,
      sti.cost_price
    FROM public.sales_transactions st
    JOIN public.sales_transaction_items sti
      ON sti.business_id = st.business_id AND sti.transaction_id = st.id
    WHERE st.status = 'completed'
      AND NOT EXISTS (
        SELECT 1 FROM public.inventory_movements im
        WHERE im.business_id = st.business_id
          AND im.product_id = sti.product_id
          AND (im.reference_id = st.id OR im.notes LIKE '%' || st.transaction_number || '%')
      )
  LOOP
    v_loc_id := public.fn_ensure_branch_sales_floor_location(r_item.business_id, r_item.branch_id);

    UPDATE public.inventory_balances ib
    SET on_hand_quantity = GREATEST(ib.reserved_quantity, ib.on_hand_quantity - r_item.quantity),
        updated_at = NOW()
    WHERE ib.business_id = r_item.business_id
      AND ib.product_id = r_item.product_id
      AND ib.branch_id = r_item.branch_id;

    IF FOUND THEN
      INSERT INTO public.inventory_movements (
        business_id, branch_id, location_id, product_id, movement_type, quantity, unit_cost, reference_type, reference_id, notes, actor_id, created_at
      ) VALUES (
        r_item.business_id, r_item.branch_id, v_loc_id, r_item.product_id, 'SALE', -r_item.quantity, COALESCE(r_item.cost_price, 0),
        'sale', r_item.sale_id, 'Reconciled POS Sale #' || r_item.transaction_number, r_item.cashier_user_id, r_item.occurred_at
      );
    END IF;
  END LOOP;

  -- 7b. Reconcile Customer total_spent & loyalty_points from completed sales
  UPDATE public.customers c
  SET metadata = COALESCE(c.metadata, '{}'::jsonb) || jsonb_build_object(
    'total_spent', GREATEST(COALESCE((c.metadata->>'total_spent')::NUMERIC, 0), agg.sum_spent),
    'loyalty_points', GREATEST(COALESCE((c.metadata->>'loyalty_points')::INTEGER, 0), agg.sum_points)
  ),
  updated_at = NOW()
  FROM (
    SELECT
      st.business_id,
      st.customer_id,
      ROUND(SUM(st.total_amount), 2) AS sum_spent,
      SUM(GREATEST(1, FLOOR(st.total_amount / 10.0)::INTEGER))::INTEGER AS sum_points
    FROM public.sales_transactions st
    WHERE st.status = 'completed'
      AND st.customer_id IS NOT NULL
    GROUP BY st.business_id, st.customer_id
  ) agg
  WHERE c.business_id = agg.business_id
    AND c.id = agg.customer_id;

  -- 7c. Reconcile Cash Vault & Bank Ledger for historical completed sales missing treasury postings
  FOR r_sale IN
    SELECT
      st.id,
      st.business_id,
      st.branch_id,
      st.transaction_number,
      st.amount_paid,
      st.currency,
      st.cashier_user_id,
      st.occurred_at,
      st.metadata,
      COALESCE(
        (SELECT p.payment_method FROM public.payments p WHERE p.business_id = st.business_id AND p.transaction_id = st.id LIMIT 1),
        lower(COALESCE(st.metadata->>'payment_method', 'cash'))
      ) AS eff_pm,
      (SELECT p.bank_account_id FROM public.payments p WHERE p.business_id = st.business_id AND p.transaction_id = st.id LIMIT 1) AS pay_bank_id
    FROM public.sales_transactions st
    WHERE st.status = 'completed'
      AND st.amount_paid > 0
  LOOP
    IF r_sale.eff_pm = 'cash' THEN
      SELECT v.id, v.currency INTO v_vault_id, v_acc_curr
      FROM public.business_cash_vaults v
      WHERE v.business_id = r_sale.business_id AND v.deleted_at IS NULL AND v.status = 'active'
      ORDER BY v.created_at ASC
      LIMIT 1;

      IF v_vault_id IS NULL THEN
        INSERT INTO public.business_cash_vaults (
          business_id, branch_id, vault_name, vault_code, currency, status, custodian_user_id
        ) VALUES (
          r_sale.business_id, r_sale.branch_id, 'Main Cash Till', 'TILL-MAIN', r_sale.currency, 'active', r_sale.cashier_user_id
        )
        ON CONFLICT (business_id, vault_code) DO UPDATE SET status = 'active', deleted_at = NULL
        RETURNING id, currency INTO v_vault_id, v_acc_curr;
      END IF;

      INSERT INTO public.vault_transactions (
        business_id, vault_id, direction, amount, currency, transaction_type, description, actor_user_id, idempotency_key, occurred_at
      ) VALUES (
        r_sale.business_id, v_vault_id, 'in', r_sale.amount_paid, COALESCE(v_acc_curr, r_sale.currency), 'deposit',
        'Cash POS Sale #' || r_sale.transaction_number, r_sale.cashier_user_id, r_sale.id, r_sale.occurred_at
      )
      ON CONFLICT (business_id, idempotency_key) DO NOTHING;

    ELSIF r_sale.eff_pm IN ('bank', 'bank_transfer', 'debit_card', 'credit_card') THEN
      v_bank_id := r_sale.pay_bank_id;
      IF v_bank_id IS NULL AND (r_sale.metadata->>'bank_account_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        v_bank_id := (r_sale.metadata->>'bank_account_id')::UUID;
      END IF;
      IF v_bank_id IS NULL THEN
        SELECT ba.id INTO v_bank_id
        FROM public.bank_accounts ba
        WHERE ba.business_id = r_sale.business_id AND ba.deleted_at IS NULL AND ba.status = 'active'
        ORDER BY ba.is_primary DESC, ba.created_at ASC
        LIMIT 1;
      END IF;

      IF v_bank_id IS NOT NULL THEN
        SELECT ba.currency INTO v_acc_curr
        FROM public.bank_accounts ba
        WHERE ba.id = v_bank_id AND ba.business_id = r_sale.business_id AND ba.deleted_at IS NULL;

        IF FOUND AND NOT EXISTS (
          SELECT 1 FROM public.bank_transactions bt
          WHERE bt.business_id = r_sale.business_id AND bt.source_id = r_sale.id AND bt.direction = 'credit'
        ) THEN
          INSERT INTO public.bank_transactions (
            business_id, bank_account_id, transaction_type, direction, amount, currency, source_type, source_id, reference_number, description, actor_user_id, occurred_at
          ) VALUES (
            r_sale.business_id, v_bank_id, 'deposit', 'credit', r_sale.amount_paid, v_acc_curr, 'payment', r_sale.id,
            r_sale.transaction_number, 'POS Sale #' || r_sale.transaction_number, r_sale.cashier_user_id, r_sale.occurred_at
          );
        END IF;
      END IF;
    END IF;
  END LOOP;
END;
$$;

COMMIT;
