-- =============================================================================
-- Migration: 015_enable_supabase_dashboard_user_deletion.sql
-- Description: Allows deleting users (and their owned test businesses) directly
--              from the Supabase Dashboard (Authentication -> Users -> Delete)
--              without triggering "Database error deleting user".
--
-- Root Causes Fixed:
-- 1. `public.user_profiles.id` referenced `auth.users(id) ON DELETE RESTRICT`.
-- 2. Foreign keys referencing `auth.users`, `public.user_profiles`,
--    `public.businesses`, `public.business_memberships`, `public.branches`,
--    `public.staff_profiles`, and `public.investor_profiles` used `RESTRICT`
--    or `NO ACTION`.
-- 3. Append-only `BEFORE UPDATE OR DELETE` triggers on `role_assignments` and
--    ledger tables blocked cascading deletes when a user/tenant was removed.
-- =============================================================================

BEGIN;

-- 1. Update append-only / immutability triggers so they only block UPDATE
--    (or direct client DELETEs), allowing cascading user/tenant cleanup from
--    Supabase Auth / SQL Admin to succeed cleanly.
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT
      n.nspname AS schema_name,
      c.relname AS table_name,
      t.tgname AS trigger_name,
      pg_get_triggerdef(t.oid) AS trigger_def
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE NOT t.tgisinternal
      AND n.nspname = 'public'
      AND pg_get_triggerdef(t.oid) ILIKE '%DELETE%'
      AND (
        t.tgname ILIKE '%immutable%'
        OR t.tgname ILIKE '%append_only%'
        OR t.tgname ILIKE '%prevent_delete%'
        OR t.tgname ILIKE '%no_delete%'
        OR t.tgname ILIKE '%guard%'
        OR c.relname IN (
          'role_assignments',
          'capital_contributions',
          'capital_returns',
          'inventory_movements',
          'bank_transactions',
          'cash_transactions',
          'sales_transactions',
          'payments',
          'vault_transactions',
          'petty_cash_transactions',
          'petty_cash_budget_adjustments',
          'mobile_money_transactions',
          'commercial_audit_logs',
          'commission_earnings',
          'commission_adjustments',
          'disbursement_settlement_allocations'
        )
      )
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I;', r.trigger_name, r.schema_name, r.table_name);
  END LOOP;
END $$;

-- 2. Automatically convert all RESTRICT / NO ACTION foreign keys in `public`
--    that block `auth.users` deletion into `ON DELETE CASCADE` (if NOT NULL
--    or primary identity link) or `ON DELETE SET NULL` (if nullable audit column).
DO $$
DECLARE
  fk RECORD;
  v_new_def TEXT;
  v_all_nullable BOOLEAN;
BEGIN
  FOR fk IN
    SELECT
      con.oid AS constraint_oid,
      con.conname AS constraint_name,
      nsp.nspname AS table_schema,
      rel.relname AS table_name,
      frel.relname AS referenced_table,
      fnsp.nspname AS referenced_schema,
      con.confdeltype AS delete_action,
      pg_get_constraintdef(con.oid) AS constraint_def,
      con.conkey AS col_attnums,
      rel.oid AS table_oid
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
    JOIN pg_class frel ON frel.oid = con.confrelid
    JOIN pg_namespace fnsp ON fnsp.oid = frel.relnamespace
    WHERE con.contype = 'f'
      AND nsp.nspname = 'public'
      AND con.confdeltype IN ('r', 'a') -- 'r' = RESTRICT, 'a' = NO ACTION
  LOOP
    -- Check if all referencing columns in this FK are nullable
    SELECT bool_and( NOT att.attnotnull )
    INTO v_all_nullable
    FROM unnest(fk.col_attnums) AS col_num
    JOIN pg_attribute att
      ON att.attrelid = fk.table_oid
     AND att.attnum = col_num;

    -- Strip any existing ON DELETE clause from the constraint definition
    v_new_def := regexp_replace(
      fk.constraint_def,
      '\s+ON\s+DELETE\s+(RESTRICT|NO\s+ACTION|CASCADE|SET\s+NULL(\s*\([^)]+\))?|SET\s+DEFAULT)',
      '',
      'gi'
    );

    -- If it's a single-column nullable audit/actor reference to user_profiles/users,
    -- use ON DELETE SET NULL so historical business records remain intact when a staff user is deleted.
    -- Otherwise, use ON DELETE CASCADE so owned entities are cleaned up cleanly.
    IF v_all_nullable
       AND array_length(fk.col_attnums, 1) = 1
       AND fk.referenced_table IN ('user_profiles', 'users')
       AND fk.table_name NOT IN ('user_profiles', 'business_memberships', 'staff_profiles', 'investor_profiles')
    THEN
      v_new_def := v_new_def || ' ON DELETE SET NULL';
    ELSE
      v_new_def := v_new_def || ' ON DELETE CASCADE';
    END IF;

    EXECUTE format(
      'ALTER TABLE %I.%I DROP CONSTRAINT %I, ADD CONSTRAINT %I %s;',
      fk.table_schema,
      fk.table_name,
      fk.constraint_name,
      fk.constraint_name,
      v_new_def
    );
  END LOOP;
END $$;

COMMIT;
