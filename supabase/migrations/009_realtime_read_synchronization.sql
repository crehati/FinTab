-- ==============================================================================
-- Migration 009: Realtime Read Synchronization & Cache Invalidation
-- Phase: 6B-2
-- ==============================================================================
-- Scope & Architectural Constraints:
-- 1. Read-Only Invalidation: Events serve exclusively as cache-invalidation signals.
--    Zero offline mutation queues, zero outbox tables, zero local transactional playback.
-- 2. Strictly Approved Tables: Enables Supabase Realtime CDC strictly for:
--    - public.inventory_transfers
--    - public.inventory_balances
--    - public.register_shifts
--    - public.product_prices
--    - public.products
--    - public.business_memberships
-- 3. Explicit Prohibitions:
--    - DO NOT publish ledger tables: inventory_movements, payments, bank_transactions, cash_transactions
--    - DO NOT publish child item detail tables: inventory_transfer_items, sales_transaction_items
--    - DO NOT publish complex/sensitive scope/role tables: role_assignments, role_assignment_scopes
--    - DO NOT publish confidential workforce tables: staff_private_details, staff_compensation
-- 4. Minimum Required Replica Identity:
--    - REPLICA IDENTITY FULL is enabled strictly on public.inventory_transfers to ensure
--      reliable RLS evaluation across branch visibility barriers during transfer lifecycle
--      status transitions (draft -> in_transit -> received).
--    - All other tables retain default replica identity.
-- 5. Immutability:
--    - Zero alterations to migrations 001-008.
--    - Zero business schema redesign, zero RPC alterations.
-- ==============================================================================

-- 1. Set REPLICA IDENTITY FULL strictly on public.inventory_transfers
ALTER TABLE public.inventory_transfers REPLICA IDENTITY FULL;

-- 2. Add approved operational and security tables to the supabase_realtime publication
ALTER PUBLICATION supabase_realtime ADD TABLE 
  public.inventory_transfers,
  public.inventory_balances,
  public.register_shifts,
  public.product_prices,
  public.products,
  public.business_memberships;
