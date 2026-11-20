-- =============================================================================
-- Migration: 002_roles_workforce_capital.sql
-- Description: FinTab Enterprise BOS - Phase 002: Roles, Workforce, and Capital
-- Architecture: Multi-Tenant RBAC, Scoped Authorization, Workforce Isolation,
--               Append-Only Capital Ledger, Dynamic Equity, and Atomic Onboarding
-- Dependencies: 001_foundation_identity_and_tenancy.sql
-- Notice: Strictly idempotent, zero mock data, hardened SECURITY DEFINER functions.
-- =============================================================================

-- Ensure required cryptographic extensions are active
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- =============================================================================
-- 1. ROLES & PERMISSIONS SCHEMA
-- =============================================================================

-- Table: public.roles
-- Supports both system-standard roles (business_id IS NULL) and tenant custom roles.
CREATE TABLE IF NOT EXISTS public.roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES public.businesses(id) ON DELETE RESTRICT,
  code TEXT NOT NULL,
  name TEXT NOT NULL,
  description TEXT,
  is_system BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_roles_system_business CHECK (
    (is_system = true AND business_id IS NULL) OR
    (is_system = false AND business_id IS NOT NULL)
  ),
  CONSTRAINT chk_roles_custom_not_system_code CHECK (
    is_system = true OR code NOT IN (
      'PrimaryOwner',
      'CoOwner',
      'SuperAdmin',
      'GeneralManager',
      'BranchManager',
      'DepartmentManager',
      'SalesManager',
      'Salesperson',
      'Cashier',
      'StockManager',
      'StockStaff',
      'FinanceManager',
      'Investor',
      'Employee',
      'Viewer'
    )
  ),
  CONSTRAINT uq_roles_business_id_id UNIQUE (business_id, id)
);

-- Code uniqueness: System roles unique globally; custom roles unique per business.
CREATE UNIQUE INDEX IF NOT EXISTS uq_roles_system_code
  ON public.roles (code)
  WHERE is_system = true;

CREATE UNIQUE INDEX IF NOT EXISTS uq_roles_custom_code
  ON public.roles (business_id, code)
  WHERE is_system = false;

CREATE INDEX IF NOT EXISTS idx_roles_business_id ON public.roles (business_id);

-- Table: public.permissions
-- Canonical, immutable catalog of granular functional permissions.
CREATE TABLE IF NOT EXISTS public.permissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key TEXT NOT NULL UNIQUE,
  module TEXT NOT NULL,
  description TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_permissions_module ON public.permissions (module);

-- Table: public.role_permissions
-- Flat explicit mapping of permissions to roles. No recursive inheritance.
CREATE TABLE IF NOT EXISTS public.role_permissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  role_id UUID NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
  permission_id UUID NOT NULL REFERENCES public.permissions(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_role_permissions UNIQUE (role_id, permission_id)
);

CREATE INDEX IF NOT EXISTS idx_role_permissions_role_id ON public.role_permissions (role_id);
CREATE INDEX IF NOT EXISTS idx_role_permissions_permission_id ON public.role_permissions (permission_id);

-- =============================================================================
-- 2. ROLE ASSIGNMENTS & SCOPES
-- =============================================================================

-- Ensure business_memberships has the composite unique constraint (business_id, id)
-- required for tenant-safe composite foreign keys in Phase 002.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.business_memberships'::regclass
      AND conname = 'uq_business_memberships_business_id_id'
  ) THEN
    ALTER TABLE public.business_memberships
      ADD CONSTRAINT uq_business_memberships_business_id_id
      UNIQUE (business_id, id);
  END IF;
END $$;

-- Table: public.role_assignments
-- Binds a business membership to a role. Audited and tenant-contained.
CREATE TABLE IF NOT EXISTS public.role_assignments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  membership_id UUID NOT NULL,
  role_id UUID NOT NULL REFERENCES public.roles(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked', 'expired')),
  assigned_by UUID REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  assigned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  revoked_by UUID REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  revocation_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT fk_role_assignments_membership_same_biz
    FOREIGN KEY (business_id, membership_id)
    REFERENCES public.business_memberships(business_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT uq_role_assignments_business_id_id UNIQUE (business_id, id)
);

-- Active assignment uniqueness per membership and role
CREATE UNIQUE INDEX IF NOT EXISTS uq_role_assignments_active_unique
  ON public.role_assignments (membership_id, role_id)
  WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_role_assignments_business_id ON public.role_assignments (business_id);
CREATE INDEX IF NOT EXISTS idx_role_assignments_membership_id ON public.role_assignments (membership_id);
CREATE INDEX IF NOT EXISTS idx_role_assignments_role_id ON public.role_assignments (role_id);

-- Table: public.role_assignment_scopes
-- Enforces spatial boundaries: Business, Branch, Department, or Self.
-- Note: ON DELETE CASCADE is specified solely for database referential consistency;
-- application deletion of parent role_assignments is strictly blocked by RLS (USING (false)).
-- Historical role and scope records survive normal application lifecycle events.
CREATE TABLE IF NOT EXISTS public.role_assignment_scopes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  role_assignment_id UUID NOT NULL REFERENCES public.role_assignments(id) ON DELETE CASCADE,
  scope_type TEXT NOT NULL CHECK (scope_type IN ('Business', 'Branch', 'Department', 'Self')),
  branch_id UUID,
  department_id UUID,
  target_user_id UUID REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Business: Entire current business tenant only
  CONSTRAINT chk_scope_business_fields CHECK (
    scope_type <> 'Business' OR (
      branch_id IS NULL AND department_id IS NULL AND target_user_id IS NULL
    )
  ),

  -- Branch: Bounded to specific branch within tenant
  CONSTRAINT chk_scope_branch_fields CHECK (
    scope_type <> 'Branch' OR (
      branch_id IS NOT NULL AND department_id IS NULL AND target_user_id IS NULL
    )
  ),

  -- Department: Bounded to specific department within tenant
  CONSTRAINT chk_scope_department_fields CHECK (
    scope_type <> 'Department' OR (
      department_id IS NOT NULL AND target_user_id IS NULL
    )
  ),

  -- Self: Bounded strictly to assigned user's own records
  CONSTRAINT chk_scope_self_fields CHECK (
    scope_type <> 'Self' OR (
      branch_id IS NULL AND department_id IS NULL AND target_user_id IS NOT NULL
    )
  )
);

-- Unique scope per assignment to prevent duplicate rows
CREATE UNIQUE INDEX IF NOT EXISTS uq_role_assignment_scope_dedup
  ON public.role_assignment_scopes (
    role_assignment_id,
    scope_type,
    COALESCE(branch_id, '00000000-0000-0000-0000-000000000000'::UUID),
    COALESCE(department_id, '00000000-0000-0000-0000-000000000000'::UUID),
    COALESCE(target_user_id, '00000000-0000-0000-0000-000000000000'::UUID)
  );

CREATE INDEX IF NOT EXISTS idx_role_assignment_scopes_assignment_id
  ON public.role_assignment_scopes (role_assignment_id);

-- =============================================================================
-- 3. WORKFORCE: STAFF PROFILES
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.staff_profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  membership_id UUID NOT NULL,
  user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  employee_code TEXT NOT NULL,
  job_title TEXT NOT NULL,
  branch_id UUID,
  department_id UUID,
  employment_status TEXT NOT NULL DEFAULT 'Active'
    CHECK (employment_status IN ('Active', 'Probation', 'OnLeave', 'Suspended', 'Terminated')),
  hire_date DATE NOT NULL DEFAULT CURRENT_DATE,
  termination_date DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT fk_staff_profiles_membership_same_biz
    FOREIGN KEY (business_id, membership_id)
    REFERENCES public.business_memberships(business_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT fk_staff_profiles_branch_same_biz
    FOREIGN KEY (business_id, branch_id)
    REFERENCES public.branches(business_id, id)
    ON DELETE SET NULL (branch_id),
  CONSTRAINT fk_staff_profiles_dept_same_biz
    FOREIGN KEY (business_id, department_id)
    REFERENCES public.departments(business_id, id)
    ON DELETE SET NULL (department_id),
  CONSTRAINT uq_staff_profiles_business_id_id UNIQUE (business_id, id),
  CONSTRAINT uq_staff_profiles_business_user UNIQUE (business_id, user_id),
  CONSTRAINT uq_staff_profiles_biz_employee_code UNIQUE (business_id, employee_code)
);

CREATE INDEX IF NOT EXISTS idx_staff_profiles_business_id ON public.staff_profiles (business_id);
CREATE INDEX IF NOT EXISTS idx_staff_profiles_user_id ON public.staff_profiles (user_id);
CREATE INDEX IF NOT EXISTS idx_staff_profiles_branch_id ON public.staff_profiles (branch_id);

-- Table: public.staff_private_details
-- Confidential workforce HR details isolated from general directory.
-- Protected by strict RLS requiring PrimaryOwner OR staff:manage within scope (or Self).
CREATE TABLE IF NOT EXISTS public.staff_private_details (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  staff_profile_id UUID NOT NULL,
  emergency_contact JSONB DEFAULT '{}'::jsonb,
  national_id_number TEXT,
  residential_address TEXT,
  date_of_birth DATE,
  private_notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT fk_staff_private_details_profile_same_biz
    FOREIGN KEY (business_id, staff_profile_id)
    REFERENCES public.staff_profiles(business_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT uq_staff_private_details_profile UNIQUE (business_id, staff_profile_id),
  CONSTRAINT uq_staff_private_details_business_id_id UNIQUE (business_id, id)
);

CREATE INDEX IF NOT EXISTS idx_staff_private_details_biz_profile
  ON public.staff_private_details (business_id, staff_profile_id);

-- Table: public.staff_compensation
-- Confidential compensation records isolated from general staff directory.
-- Append-only historical tracking. Protected by scope-aware RLS and atomic RPC.
CREATE TABLE IF NOT EXISTS public.staff_compensation (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  staff_profile_id UUID NOT NULL,
  compensation_type TEXT NOT NULL CHECK (compensation_type IN ('Hourly', 'Salary', 'Commission', 'Contract')),
  base_rate NUMERIC(15,2) NOT NULL DEFAULT 0.00 CHECK (base_rate >= 0.00),
  effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
  effective_to DATE,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'historical', 'superseded')),
  notes TEXT,
  created_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT fk_staff_compensation_profile_same_biz
    FOREIGN KEY (business_id, staff_profile_id)
    REFERENCES public.staff_profiles(business_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT chk_compensation_temporal CHECK (
    effective_to IS NULL OR effective_to >= effective_from
  ),
  CONSTRAINT uq_staff_compensation_business_id_id UNIQUE (business_id, id)
);

-- Exactly one active compensation record permitted per staff profile
CREATE UNIQUE INDEX IF NOT EXISTS uq_staff_compensation_active_profile
  ON public.staff_compensation (business_id, staff_profile_id)
  WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_staff_compensation_biz_profile
  ON public.staff_compensation (business_id, staff_profile_id);

-- =============================================================================
-- 4. CAPITAL: INVESTORS, CONTRIBUTIONS & DIVIDENDS
-- =============================================================================

-- Table: public.investors
CREATE TABLE IF NOT EXISTS public.investors (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  membership_id UUID NOT NULL,
  user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  investor_code TEXT NOT NULL,
  legal_name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'dissolved')),
  payout_routing_info JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT fk_investors_membership_same_biz
    FOREIGN KEY (business_id, membership_id)
    REFERENCES public.business_memberships(business_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT uq_investors_business_id_id UNIQUE (business_id, id),
  CONSTRAINT uq_investors_business_user UNIQUE (business_id, user_id),
  CONSTRAINT uq_investors_biz_investor_code UNIQUE (business_id, investor_code)
);

CREATE INDEX IF NOT EXISTS idx_investors_business_id ON public.investors (business_id);
CREATE INDEX IF NOT EXISTS idx_investors_user_id ON public.investors (user_id);

-- Table: public.capital_contributions
-- Strictly append-only. Sequential entry_number per business.
CREATE TABLE IF NOT EXISTS public.capital_contributions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  investor_id UUID NOT NULL,
  entry_number INT NOT NULL,
  amount NUMERIC(15,2) NOT NULL,
  contribution_type TEXT NOT NULL CHECK (
    contribution_type IN (
      'initial_owner_capital',
      'additional_capital',
      'retained_earnings_conversion',
      'corrective_reversal'
    )
  ),
  reference_contribution_id UUID REFERENCES public.capital_contributions(id) ON DELETE RESTRICT,
  effective_date DATE NOT NULL DEFAULT CURRENT_DATE,
  notes TEXT,
  created_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT fk_capital_contributions_investor_same_biz
    FOREIGN KEY (business_id, investor_id)
    REFERENCES public.investors(business_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT uq_capital_contributions_sequence UNIQUE (business_id, entry_number),
  CONSTRAINT chk_capital_amount_not_zero CHECK (amount <> 0.00)
);

-- One reversal maximum per original contribution
CREATE UNIQUE INDEX IF NOT EXISTS uq_capital_contributions_single_reversal
  ON public.capital_contributions (reference_contribution_id)
  WHERE contribution_type = 'corrective_reversal';

CREATE INDEX IF NOT EXISTS idx_capital_contributions_biz_investor
  ON public.capital_contributions (business_id, investor_id);
CREATE INDEX IF NOT EXISTS idx_capital_contributions_biz_seq
  ON public.capital_contributions (business_id, entry_number DESC);

-- Table: public.dividend_payouts
CREATE TABLE IF NOT EXISTS public.dividend_payouts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  investor_id UUID NOT NULL,
  amount NUMERIC(15,2) NOT NULL CHECK (amount > 0.00),
  declaration_date DATE NOT NULL,
  disbursement_date DATE,
  status TEXT NOT NULL DEFAULT 'declared' CHECK (status IN ('declared', 'approved', 'paid', 'cancelled')),
  payment_method TEXT,
  reference_identifier TEXT,
  created_by UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT fk_dividend_payouts_investor_same_biz
    FOREIGN KEY (business_id, investor_id)
    REFERENCES public.investors(business_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT uq_dividend_payouts_business_id_id UNIQUE (business_id, id)
);

CREATE INDEX IF NOT EXISTS idx_dividend_payouts_biz_investor
  ON public.dividend_payouts (business_id, investor_id);

-- =============================================================================
-- 5. BUSINESS RULES & INTEGRITY TRIGGERS
-- =============================================================================

-- Rule 5.1: Tenant-Safe Role Assignment Validation
-- Custom roles must belong to the assignment's business. System roles are global.
CREATE OR REPLACE FUNCTION public.trg_validate_role_assignment_tenancy()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role_business_id UUID;
  v_role_is_system BOOLEAN;
BEGIN
  SELECT business_id, is_system INTO v_role_business_id, v_role_is_system
  FROM public.roles
  WHERE id = NEW.role_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Referenced role_id % does not exist', NEW.role_id;
  END IF;

  IF v_role_is_system IS FALSE AND v_role_business_id <> NEW.business_id THEN
    RAISE EXCEPTION 'Cross-tenant violation: Custom role belongs to business % and cannot be assigned in business %',
      v_role_business_id, NEW.business_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_role_assignment_tenancy_ins_upd ON public.role_assignments;
CREATE TRIGGER trg_validate_role_assignment_tenancy_ins_upd
  BEFORE INSERT OR UPDATE ON public.role_assignments
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_validate_role_assignment_tenancy();

-- Rule 5.2: PrimaryOwner Role Assignment Immutability & Protection
-- Inspects OLD and NEW. Blocks deletion and mutation of existing PrimaryOwner assignments.
-- Only the authentic businesses.owner_user_id can hold PrimaryOwner.
CREATE OR REPLACE FUNCTION public.trg_protect_primary_owner_assignment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_old_is_po BOOLEAN := FALSE;
  v_new_is_po BOOLEAN := FALSE;
  v_biz_owner_id UUID;
  v_membership_user_id UUID;
BEGIN
  -- 1. Check if OLD was a PrimaryOwner assignment
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    SELECT EXISTS (
      SELECT 1 FROM public.roles
      WHERE id = OLD.role_id AND code = 'PrimaryOwner' AND is_system = true
    ) INTO v_old_is_po;
  END IF;

  -- 2. Strict deletion protection
  IF TG_OP = 'DELETE' THEN
    IF v_old_is_po THEN
      RAISE EXCEPTION 'PrimaryOwner role assignment cannot be deleted; use formal ownership transfer instead';
    END IF;
    RETURN OLD;
  END IF;

  -- 3. Check if NEW is a PrimaryOwner assignment
  SELECT EXISTS (
    SELECT 1 FROM public.roles
    WHERE id = NEW.role_id AND code = 'PrimaryOwner' AND is_system = true
  ) INTO v_new_is_po;

  -- 4. Mutation protection for existing PrimaryOwner assignments
  IF v_old_is_po THEN
    IF NEW.role_id <> OLD.role_id THEN
      RAISE EXCEPTION 'PrimaryOwner role assignment cannot be converted to another role; use ownership transfer';
    END IF;
    IF NEW.membership_id <> OLD.membership_id THEN
      RAISE EXCEPTION 'PrimaryOwner role assignment cannot be reassigned to another membership';
    END IF;
    IF NEW.business_id <> OLD.business_id THEN
      RAISE EXCEPTION 'PrimaryOwner role assignment cannot be moved to another business';
    END IF;
    IF NEW.status <> 'active' THEN
      RAISE EXCEPTION 'PrimaryOwner role assignment status cannot be deactivated or changed; transfer business ownership instead';
    END IF;
    IF NEW.expires_at IS NOT NULL THEN
      RAISE EXCEPTION 'PrimaryOwner role assignment cannot expire';
    END IF;
  END IF;

  -- 5. Validation on assignment of PrimaryOwner (INSERT or UPDATE)
  IF v_new_is_po THEN
    SELECT owner_user_id INTO v_biz_owner_id
    FROM public.businesses
    WHERE id = NEW.business_id AND deleted_at IS NULL;

    SELECT user_id INTO v_membership_user_id
    FROM public.business_memberships
    WHERE id = NEW.membership_id AND business_id = NEW.business_id;

    IF v_biz_owner_id IS NULL OR v_membership_user_id <> v_biz_owner_id THEN
      RAISE EXCEPTION 'Security invariant violated: User % is not the PrimaryOwner of business %',
        v_membership_user_id, NEW.business_id;
    END IF;

    IF NEW.status <> 'active' THEN
      RAISE EXCEPTION 'PrimaryOwner role assignment must be active upon creation';
    END IF;

    IF NEW.expires_at IS NOT NULL THEN
      RAISE EXCEPTION 'PrimaryOwner role assignment cannot expire';
    END IF;

    -- Enforce strictly one active PrimaryOwner assignment per business
    IF NEW.status = 'active' AND EXISTS (
      SELECT 1 FROM public.role_assignments ra
      JOIN public.roles r ON ra.role_id = r.id
      WHERE ra.business_id = NEW.business_id
        AND r.code = 'PrimaryOwner'
        AND r.is_system = true
        AND ra.status = 'active'
        AND ra.id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid)
    ) THEN
      RAISE EXCEPTION 'Business % already has an active PrimaryOwner role assignment', NEW.business_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_primary_owner_assignment_upd_del ON public.role_assignments;
CREATE TRIGGER trg_protect_primary_owner_assignment_upd_del
  BEFORE UPDATE OR DELETE ON public.role_assignments
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_protect_primary_owner_assignment();

DROP TRIGGER IF EXISTS trg_protect_primary_owner_assignment_ins ON public.role_assignments;
CREATE TRIGGER trg_protect_primary_owner_assignment_ins
  BEFORE INSERT ON public.role_assignments
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_protect_primary_owner_assignment();

-- Rule 5.2A: Protected Sovereign Role Permission Guard
-- Blocks assignment of sovereign protected permissions ('legal_ownership:edit',
-- 'business:transfer_ownership', 'business:delete') to any role other than system 'PrimaryOwner'.
-- Protects against privilege escalation via custom roles or unauthorized system role modification.
CREATE OR REPLACE FUNCTION public.trg_protect_sovereign_permissions()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_perm_key TEXT;
  v_role_code TEXT;
  v_role_is_system BOOLEAN;
BEGIN
  SELECT key INTO v_perm_key FROM public.permissions WHERE id = NEW.permission_id;
  SELECT code, is_system INTO v_role_code, v_role_is_system FROM public.roles WHERE id = NEW.role_id;

  IF v_perm_key IN ('legal_ownership:edit', 'business:transfer_ownership', 'business:delete') THEN
    IF NOT (v_role_is_system = true AND v_role_code = 'PrimaryOwner') THEN
      RAISE EXCEPTION 'Security invariant violated: Permission % is a sovereign protected permission and can ONLY be mapped to the system PrimaryOwner role',
        v_perm_key;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_sovereign_permissions_ins_upd ON public.role_permissions;
CREATE TRIGGER trg_protect_sovereign_permissions_ins_upd
  BEFORE INSERT OR UPDATE ON public.role_permissions
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_protect_sovereign_permissions();

-- Rule 5.2B: Role Assignment Structural Immutability & Audit Anti-Spoofing
-- Structural fields cannot be mutated. Clients cannot spoof assigned_by or revoked_by.
CREATE OR REPLACE FUNCTION public.trg_enforce_role_assignments_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  v_caller_id := auth.uid();

  -- On INSERT: Ensure assigned_by reflects caller if authenticated (anti-spoofing)
  IF TG_OP = 'INSERT' THEN
    IF v_caller_id IS NOT NULL THEN
      NEW.assigned_by := v_caller_id;
    END IF;
    RETURN NEW;
  END IF;

  -- On UPDATE: Enforce structural immutability
  IF NEW.id <> OLD.id THEN
    RAISE EXCEPTION 'role_assignments.id is immutable';
  END IF;
  IF NEW.business_id <> OLD.business_id THEN
    RAISE EXCEPTION 'role_assignments.business_id is immutable';
  END IF;
  IF NEW.membership_id <> OLD.membership_id THEN
    RAISE EXCEPTION 'role_assignments.membership_id is immutable';
  END IF;
  IF NEW.role_id <> OLD.role_id THEN
    RAISE EXCEPTION 'role_assignments.role_id is immutable; revoke and reassign instead';
  END IF;
  IF NEW.assigned_at <> OLD.assigned_at THEN
    RAISE EXCEPTION 'role_assignments.assigned_at is immutable';
  END IF;
  IF NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'role_assignments.created_at is immutable';
  END IF;
  IF NEW.assigned_by IS DISTINCT FROM OLD.assigned_by THEN
    RAISE EXCEPTION 'role_assignments.assigned_by cannot be altered after creation';
  END IF;

  -- Anti-spoofing and audit enforcement for revocation
  IF OLD.status = 'revoked' THEN
    IF NEW.status <> 'revoked' THEN
      RAISE EXCEPTION 'Revoked role assignments cannot be reactivated; issue a new role assignment instead';
    END IF;
    IF NEW.revoked_at IS DISTINCT FROM OLD.revoked_at OR NEW.revoked_by IS DISTINCT FROM OLD.revoked_by THEN
      RAISE EXCEPTION 'Revocation metadata cannot be altered once revoked';
    END IF;
    IF NEW.revocation_reason IS DISTINCT FROM OLD.revocation_reason THEN
      RAISE EXCEPTION 'Revocation reason cannot be altered once revoked';
    END IF;
    IF NEW.expires_at IS DISTINCT FROM OLD.expires_at THEN
      RAISE EXCEPTION 'Revoked role assignment expiration cannot be altered';
    END IF;
  ELSIF NEW.status = 'revoked' THEN
    NEW.revoked_at := NOW();
    IF v_caller_id IS NOT NULL THEN
      NEW.revoked_by := v_caller_id;
    END IF;
  ELSE
    IF NEW.revoked_at IS NOT NULL OR NEW.revoked_by IS NOT NULL THEN
      RAISE EXCEPTION 'revoked_at and revoked_by cannot be set when status is not revoked';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_role_assignments_immutability_ins_upd ON public.role_assignments;
CREATE TRIGGER trg_enforce_role_assignments_immutability_ins_upd
  BEFORE INSERT OR UPDATE ON public.role_assignments
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_enforce_role_assignments_immutability();

-- Rule 5.3: Role Assignment Scope Integrity
-- Validates branch/department belongs to same tenant, Self targets assigned user,
-- and department.branch_id matches scope branch_id when both are present.
CREATE OR REPLACE FUNCTION public.trg_validate_role_assignment_scope_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_assignment_business_id UUID;
  v_assignment_user_id UUID;
  v_dept_branch_id UUID;
BEGIN
  SELECT ra.business_id, bm.user_id
  INTO v_assignment_business_id, v_assignment_user_id
  FROM public.role_assignments ra
  JOIN public.business_memberships bm ON ra.membership_id = bm.id
  WHERE ra.id = NEW.role_assignment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent role assignment % does not exist', NEW.role_assignment_id;
  END IF;

  -- 1. Business scope validation: Must not specify branch, department, or target_user
  IF NEW.scope_type = 'Business' THEN
    IF NEW.branch_id IS NOT NULL OR NEW.department_id IS NOT NULL OR NEW.target_user_id IS NOT NULL THEN
      RAISE EXCEPTION 'Business scope cannot specify branch_id, department_id, or target_user_id';
    END IF;
  END IF;

  -- 2. Branch scope validation: Must specify branch belonging to tenant; department and target_user forbidden
  IF NEW.scope_type = 'Branch' THEN
    IF NEW.branch_id IS NULL THEN
      RAISE EXCEPTION 'Branch scope requires a valid branch_id';
    END IF;
    IF NEW.department_id IS NOT NULL OR NEW.target_user_id IS NOT NULL THEN
      RAISE EXCEPTION 'Branch scope cannot specify department_id or target_user_id';
    END IF;
  END IF;

  -- 3. Department scope validation: Must specify department belonging to tenant; target_user forbidden
  IF NEW.scope_type = 'Department' THEN
    IF NEW.department_id IS NULL THEN
      RAISE EXCEPTION 'Department scope requires a valid department_id';
    END IF;
    IF NEW.target_user_id IS NOT NULL THEN
      RAISE EXCEPTION 'Department scope cannot specify target_user_id';
    END IF;
  END IF;

  -- 4. Branch tenancy check
  IF NEW.branch_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.branches
      WHERE id = NEW.branch_id AND business_id = v_assignment_business_id
    ) THEN
      RAISE EXCEPTION 'Scope branch % does not belong to business %',
        NEW.branch_id, v_assignment_business_id;
    END IF;
  END IF;

  -- 5. Department tenancy and branch/department consistency check
  IF NEW.department_id IS NOT NULL THEN
    SELECT branch_id INTO v_dept_branch_id
    FROM public.departments
    WHERE id = NEW.department_id AND business_id = v_assignment_business_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Scope department % does not belong to business %',
        NEW.department_id, v_assignment_business_id;
    END IF;

    -- Branch/Department consistency check when both IDs exist
    IF NEW.branch_id IS NOT NULL AND v_dept_branch_id IS NOT NULL AND v_dept_branch_id <> NEW.branch_id THEN
      RAISE EXCEPTION 'Branch/Department mismatch: Department % belongs to branch %, but scope specifies branch %',
        NEW.department_id, v_dept_branch_id, NEW.branch_id;
    END IF;
  END IF;

  -- 6. Self scope validation: Must not specify branch or department; target_user_id must match assignment user
  IF NEW.scope_type = 'Self' THEN
    IF NEW.branch_id IS NOT NULL OR NEW.department_id IS NOT NULL THEN
      RAISE EXCEPTION 'Self scope cannot specify branch_id or department_id';
    END IF;
    IF NEW.target_user_id IS NULL OR NEW.target_user_id <> v_assignment_user_id THEN
      RAISE EXCEPTION 'Self scope target_user_id must strictly match the assignment membership user (%)',
        v_assignment_user_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_role_assignment_scope_integrity_ins ON public.role_assignment_scopes;
CREATE TRIGGER trg_validate_role_assignment_scope_integrity_ins
  BEFORE INSERT ON public.role_assignment_scopes
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_validate_role_assignment_scope_integrity();

-- Rule 5.4: Scope Immutability Protection
-- Role assignment scopes cannot be silently repurposed via UPDATE.
CREATE OR REPLACE FUNCTION public.trg_enforce_scope_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.role_assignment_id <> NEW.role_assignment_id
     OR OLD.scope_type <> NEW.scope_type
     OR OLD.branch_id IS DISTINCT FROM NEW.branch_id
     OR OLD.department_id IS DISTINCT FROM NEW.department_id
     OR OLD.target_user_id IS DISTINCT FROM NEW.target_user_id THEN
    RAISE EXCEPTION 'role_assignment_scopes are immutable; revoke and recreate the assignment instead';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_scope_immutability_upd ON public.role_assignment_scopes;
CREATE TRIGGER trg_enforce_scope_immutability_upd
  BEFORE UPDATE ON public.role_assignment_scopes
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_enforce_scope_immutability();

-- Rule 5.5: Staff Single-Business Enforcement
-- Staff accounts belong to ONE business only. Business owners cannot be staff elsewhere.
CREATE OR REPLACE FUNCTION public.trg_enforce_staff_single_business()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- An active employee cannot hold an active staff profile in any other business
  IF EXISTS (
    SELECT 1
    FROM public.staff_profiles sp
    WHERE sp.user_id = NEW.user_id
      AND sp.business_id <> NEW.business_id
      AND sp.employment_status <> 'Terminated'
  ) THEN
    RAISE EXCEPTION 'Active staff accounts belong to ONE business only. Active profile exists elsewhere';
  END IF;

  -- A registered business owner cannot be onboarded as subordinate staff in another business
  IF EXISTS (
    SELECT 1
    FROM public.businesses b
    WHERE b.owner_user_id = NEW.user_id
      AND b.id <> NEW.business_id
      AND b.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Registered business owners cannot hold staff profiles in other businesses';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_staff_single_business_ins_upd ON public.staff_profiles;
CREATE TRIGGER trg_enforce_staff_single_business_ins_upd
  BEFORE INSERT OR UPDATE ON public.staff_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_enforce_staff_single_business();

-- Rule 5.6: Investor Multi-Business vs. Single-Business Limits
-- Owners can hold investor records in multiple businesses they own.
-- Non-owners are strictly limited to exactly one business.
CREATE OR REPLACE FUNCTION public.trg_enforce_investor_business_limits()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_is_owner_of_target BOOLEAN;
BEGIN
  SELECT (owner_user_id = NEW.user_id) INTO v_is_owner_of_target
  FROM public.businesses
  WHERE id = NEW.business_id AND deleted_at IS NULL;

  -- If user is the registered owner of target business:
  IF v_is_owner_of_target IS TRUE THEN
    -- Verify that any other investor records held by this user are ALSO in businesses they own
    IF EXISTS (
      SELECT 1
      FROM public.investors i
      JOIN public.businesses b ON i.business_id = b.id
      WHERE i.user_id = NEW.user_id
        AND i.business_id <> NEW.business_id
        AND b.owner_user_id <> NEW.user_id
        AND b.deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'User holds an ordinary non-owner investor position in another business';
    END IF;
    RETURN NEW;
  END IF;

  -- If user is an ordinary (non-owner) investor:
  -- Must NOT hold an investor record in ANY other business
  IF EXISTS (
    SELECT 1
    FROM public.investors i
    WHERE i.user_id = NEW.user_id
      AND i.business_id <> NEW.business_id
  ) THEN
    RAISE EXCEPTION 'Non-owner investor accounts are restricted to ONE business only';
  END IF;

  -- Ordinary investor cannot hold active staff profile in another business
  IF EXISTS (
    SELECT 1
    FROM public.staff_profiles sp
    WHERE sp.user_id = NEW.user_id
      AND sp.business_id <> NEW.business_id
      AND sp.employment_status <> 'Terminated'
  ) THEN
    RAISE EXCEPTION 'Active staff members from another business cannot be onboarded as investors';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_investor_business_limits_ins_upd ON public.investors;
CREATE TRIGGER trg_enforce_investor_business_limits_ins_upd
  BEFORE INSERT OR UPDATE ON public.investors
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_enforce_investor_business_limits();

-- Rule 5.6B: Staff Profile & Investor Membership Identity Consistency & Immutability
-- Guarantees that staff_profiles.user_id and investors.user_id strictly match business_memberships.user_id,
-- and prevents reassignment of historical identity fields on UPDATE.
CREATE OR REPLACE FUNCTION public.trg_validate_staff_profile_membership_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_membership_user_id UUID;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.id <> OLD.id THEN
      RAISE EXCEPTION 'staff_profiles.id is immutable';
    END IF;
    IF NEW.business_id <> OLD.business_id THEN
      RAISE EXCEPTION 'staff_profiles.business_id is immutable';
    END IF;
    IF NEW.membership_id <> OLD.membership_id THEN
      RAISE EXCEPTION 'staff_profiles.membership_id is immutable; identity transfer is forbidden';
    END IF;
    IF NEW.user_id <> OLD.user_id THEN
      RAISE EXCEPTION 'staff_profiles.user_id is immutable; identity transfer is forbidden';
    END IF;
    IF NEW.employee_code <> OLD.employee_code THEN
      RAISE EXCEPTION 'staff_profiles.employee_code is immutable';
    END IF;
    IF NEW.created_at <> OLD.created_at THEN
      RAISE EXCEPTION 'staff_profiles.created_at is immutable';
    END IF;
  END IF;

  SELECT user_id INTO v_membership_user_id
  FROM public.business_memberships
  WHERE id = NEW.membership_id AND business_id = NEW.business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Referenced membership % does not exist in business %', NEW.membership_id, NEW.business_id;
  END IF;

  IF v_membership_user_id <> NEW.user_id THEN
    RAISE EXCEPTION 'Identity mismatch: staff_profiles.user_id (%) does not match business_memberships.user_id (%) for membership %',
      NEW.user_id, v_membership_user_id, NEW.membership_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_staff_profile_membership_user_ins_upd ON public.staff_profiles;
CREATE TRIGGER trg_validate_staff_profile_membership_user_ins_upd
  BEFORE INSERT OR UPDATE ON public.staff_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_validate_staff_profile_membership_user();

CREATE OR REPLACE FUNCTION public.trg_validate_investor_membership_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_membership_user_id UUID;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.id <> OLD.id THEN
      RAISE EXCEPTION 'investors.id is immutable';
    END IF;
    IF NEW.business_id <> OLD.business_id THEN
      RAISE EXCEPTION 'investors.business_id is immutable';
    END IF;
    IF NEW.membership_id <> OLD.membership_id THEN
      RAISE EXCEPTION 'investors.membership_id is immutable; investor identity transfer is forbidden';
    END IF;
    IF NEW.user_id <> OLD.user_id THEN
      RAISE EXCEPTION 'investors.user_id is immutable; investor identity transfer is forbidden';
    END IF;
    IF NEW.investor_code <> OLD.investor_code THEN
      RAISE EXCEPTION 'investors.investor_code is immutable';
    END IF;
    IF NEW.created_at <> OLD.created_at THEN
      RAISE EXCEPTION 'investors.created_at is immutable';
    END IF;
  END IF;

  SELECT user_id INTO v_membership_user_id
  FROM public.business_memberships
  WHERE id = NEW.membership_id AND business_id = NEW.business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Referenced membership % does not exist in business %', NEW.membership_id, NEW.business_id;
  END IF;

  IF v_membership_user_id <> NEW.user_id THEN
    RAISE EXCEPTION 'Identity mismatch: investors.user_id (%) does not match business_memberships.user_id (%) for membership %',
      NEW.user_id, v_membership_user_id, NEW.membership_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_investor_membership_user_ins_upd ON public.investors;
CREATE TRIGGER trg_validate_investor_membership_user_ins_upd
  BEFORE INSERT OR UPDATE ON public.investors
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_validate_investor_membership_user();

-- Rule 5.6C: Staff Branch / Department Consistency
-- When both branch_id and department_id are set, validates department belongs to that branch.
CREATE OR REPLACE FUNCTION public.trg_validate_staff_profile_branch_department()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_dept_branch_id UUID;
BEGIN
  IF NEW.branch_id IS NOT NULL AND NEW.department_id IS NOT NULL THEN
    SELECT branch_id INTO v_dept_branch_id
    FROM public.departments
    WHERE id = NEW.department_id AND business_id = NEW.business_id;

    IF v_dept_branch_id IS NOT NULL AND v_dept_branch_id <> NEW.branch_id THEN
      RAISE EXCEPTION 'Branch/Department mismatch: Department % belongs to branch %, but staff profile specifies branch %',
        NEW.department_id, v_dept_branch_id, NEW.branch_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_staff_profile_branch_dept_ins_upd ON public.staff_profiles;
CREATE TRIGGER trg_validate_staff_profile_branch_dept_ins_upd
  BEFORE INSERT OR UPDATE ON public.staff_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_validate_staff_profile_branch_department();

-- Rule 5.7: Capital Contributions Immutability & Reversal Invariants
-- Strict append-only ledger: UPDATE and DELETE are completely blocked.
CREATE OR REPLACE FUNCTION public.trg_enforce_capital_contributions_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'capital_contributions is an append-only immutable ledger; mutations and deletions are prohibited';
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_capital_contributions_immutability_upd_del ON public.capital_contributions;
CREATE TRIGGER trg_enforce_capital_contributions_immutability_upd_del
  BEFORE UPDATE OR DELETE ON public.capital_contributions
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_enforce_capital_contributions_immutability();

-- Rule 5.8: Capital Contribution Insert Validation
-- Validates full reversal rules and cumulative capital non-negativity.
CREATE OR REPLACE FUNCTION public.trg_validate_capital_contribution_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ref RECORD;
  v_current_investor_capital NUMERIC(15,2);
  v_current_business_capital NUMERIC(15,2);
BEGIN
  -- Normal Contributions: Amount must be strictly positive
  IF NEW.contribution_type IN ('initial_owner_capital', 'additional_capital', 'retained_earnings_conversion') THEN
    IF NEW.amount <= 0.00 THEN
      RAISE EXCEPTION 'Capital contribution amount must be strictly greater than zero';
    END IF;
    IF NEW.reference_contribution_id IS NOT NULL THEN
      RAISE EXCEPTION 'Reference contribution ID is only permitted for corrective reversals';
    END IF;
    RETURN NEW;
  END IF;

  -- Corrective Reversals: Strict Full-Reversal Model
  IF NEW.contribution_type = 'corrective_reversal' THEN
    IF NEW.amount >= 0.00 THEN
      RAISE EXCEPTION 'Corrective reversal amount must be strictly negative';
    END IF;

    IF NEW.reference_contribution_id IS NULL THEN
      RAISE EXCEPTION 'Corrective reversal requires a reference_contribution_id';
    END IF;

    SELECT * INTO v_ref
    FROM public.capital_contributions
    WHERE id = NEW.reference_contribution_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Referenced capital contribution % does not exist', NEW.reference_contribution_id;
    END IF;

    IF v_ref.business_id <> NEW.business_id THEN
      RAISE EXCEPTION 'Referenced contribution belongs to another business';
    END IF;

    IF v_ref.investor_id <> NEW.investor_id THEN
      RAISE EXCEPTION 'Referenced contribution belongs to a different investor';
    END IF;

    IF v_ref.contribution_type = 'corrective_reversal' THEN
      RAISE EXCEPTION 'Cannot reverse a corrective reversal';
    END IF;

    -- Reversal must equal exactly the negative of original amount (Full Reversals Only)
    IF NEW.amount <> (-1.00 * v_ref.amount) THEN
      RAISE EXCEPTION 'Reversal amount (%) must equal exactly negative original amount (%)',
        NEW.amount, (-1.00 * v_ref.amount);
    END IF;

    -- Cumulative Solvency Check: Total business capital must remain strictly > 0.00
    SELECT COALESCE(SUM(amount), 0.00) INTO v_current_business_capital
    FROM public.capital_contributions
    WHERE business_id = NEW.business_id;

    IF (v_current_business_capital + NEW.amount) <= 0.00 THEN
      RAISE EXCEPTION 'Reversal rejected: Total business capital cannot be reduced to zero or below';
    END IF;

    -- Cumulative Investor Capital: May reach 0.00, but cannot become negative
    SELECT COALESCE(SUM(amount), 0.00) INTO v_current_investor_capital
    FROM public.capital_contributions
    WHERE business_id = NEW.business_id AND investor_id = NEW.investor_id;

    IF (v_current_investor_capital + NEW.amount) < 0.00 THEN
      RAISE EXCEPTION 'Reversal rejected: Investor cumulative capital cannot become negative';
    END IF;

    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_capital_contribution_insert_ins ON public.capital_contributions;
CREATE TRIGGER trg_validate_capital_contribution_insert_ins
  BEFORE INSERT ON public.capital_contributions
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_validate_capital_contribution_insert();

-- Rule 5.9: Staff Private Details HR-Controlled Field Protection
-- Ordinary employees can only update emergency_contact and residential_address.
-- National ID, birth date, and HR private notes can only be modified by authorized HR.
CREATE OR REPLACE FUNCTION public.trg_protect_staff_private_details()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_is_hr BOOLEAN := FALSE;
  v_target_branch_id UUID;
  v_target_dept_id UUID;
  v_target_user_id UUID;
BEGIN
  v_caller_id := auth.uid();

  IF TG_OP = 'UPDATE' THEN
    IF NEW.id <> OLD.id THEN
      RAISE EXCEPTION 'staff_private_details.id is immutable';
    END IF;
    IF NEW.business_id <> OLD.business_id THEN
      RAISE EXCEPTION 'staff_private_details.business_id is immutable';
    END IF;
    IF NEW.staff_profile_id <> OLD.staff_profile_id THEN
      RAISE EXCEPTION 'staff_private_details.staff_profile_id is immutable';
    END IF;
    IF NEW.created_at <> OLD.created_at THEN
      RAISE EXCEPTION 'staff_private_details.created_at is immutable';
    END IF;

    -- Determine if caller is authorized HR (owner or staff:manage in target staff scope)
    IF v_caller_id IS NOT NULL THEN
      IF public.is_business_owner(OLD.business_id) THEN
        v_is_hr := TRUE;
      ELSE
        SELECT branch_id, department_id, user_id
        INTO v_target_branch_id, v_target_dept_id, v_target_user_id
        FROM public.staff_profiles
        WHERE id = OLD.staff_profile_id AND business_id = OLD.business_id;

        IF FOUND AND public.has_permission_in_scope(
          OLD.business_id,
          'staff:manage',
          v_target_branch_id,
          v_target_dept_id,
          v_target_user_id
        ) THEN
          v_is_hr := TRUE;
        END IF;
      END IF;
    END IF;

    -- If caller is ordinary employee (self-service), prevent modifying HR-controlled fields
    IF NOT v_is_hr THEN
      IF NEW.national_id_number IS DISTINCT FROM OLD.national_id_number THEN
        RAISE EXCEPTION 'Employees cannot modify national_id_number; contact HR';
      END IF;
      IF NEW.date_of_birth IS DISTINCT FROM OLD.date_of_birth THEN
        RAISE EXCEPTION 'Employees cannot modify date_of_birth; contact HR';
      END IF;
      IF NEW.private_notes IS DISTINCT FROM OLD.private_notes THEN
        RAISE EXCEPTION 'Employees cannot modify HR private_notes';
      END IF;
    END IF;

    NEW.updated_at := NOW();
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_staff_private_details_upd ON public.staff_private_details;
CREATE TRIGGER trg_protect_staff_private_details_upd
  BEFORE UPDATE ON public.staff_private_details
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_protect_staff_private_details();

-- Rule 5.10: Dividend Payouts Lifecycle Integrity, Anti-Spoofing & Immutability
CREATE OR REPLACE FUNCTION public.trg_enforce_dividend_payouts_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  v_caller_id := auth.uid();

  IF TG_OP = 'INSERT' THEN
    -- Anti-spoofing: force created_by to authenticated caller
    IF v_caller_id IS NOT NULL THEN
      NEW.created_by := v_caller_id;
    END IF;
    IF NEW.status IS NULL THEN
      NEW.status := 'declared';
    ELSIF NEW.status NOT IN ('declared', 'approved') THEN
      RAISE EXCEPTION 'New dividend payouts must be inserted with status declared or approved';
    END IF;
    IF NEW.status = 'paid' THEN
      RAISE EXCEPTION 'Dividend payouts cannot be created directly with paid status; follow approval workflow';
    END IF;
    RETURN NEW;
  END IF;

  -- ON UPDATE:
  -- Structural fields cannot be mutated
  IF NEW.id <> OLD.id THEN
    RAISE EXCEPTION 'dividend_payouts.id is immutable';
  END IF;
  IF NEW.business_id <> OLD.business_id THEN
    RAISE EXCEPTION 'dividend_payouts.business_id is immutable';
  END IF;
  IF NEW.investor_id <> OLD.investor_id THEN
    RAISE EXCEPTION 'dividend_payouts.investor_id is immutable';
  END IF;
  IF NEW.created_by <> OLD.created_by THEN
    RAISE EXCEPTION 'dividend_payouts.created_by is immutable';
  END IF;
  IF NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'dividend_payouts.created_at is immutable';
  END IF;

  -- Once paid, the record is completely immutable
  IF OLD.status = 'paid' THEN
    RAISE EXCEPTION 'Paid dividend payouts are historical records and strictly immutable';
  END IF;

  -- Once cancelled, the record cannot be resurrected or edited
  IF OLD.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cancelled dividend payouts cannot be edited or reactivated';
  END IF;

  -- Validate allowed status transitions
  IF NEW.status <> OLD.status THEN
    IF OLD.status = 'declared' AND NEW.status NOT IN ('approved', 'cancelled') THEN
      RAISE EXCEPTION 'Invalid status transition: declared payouts can only transition to approved or cancelled';
    ELSIF OLD.status = 'approved' AND NEW.status NOT IN ('paid', 'cancelled') THEN
      RAISE EXCEPTION 'Invalid status transition: approved payouts can only transition to paid or cancelled';
    END IF;
  END IF;

  -- If transitioning to paid, disbursement_date and payment_method are required
  IF NEW.status = 'paid' THEN
    IF NEW.disbursement_date IS NULL THEN
      NEW.disbursement_date := CURRENT_DATE;
    END IF;
    IF NEW.payment_method IS NULL OR trim(NEW.payment_method) = '' THEN
      RAISE EXCEPTION 'payment_method is required when marking dividend payout as paid';
    END IF;
  END IF;

  -- Amount and declaration_date cannot be mutated once approved
  IF OLD.status = 'approved' AND (NEW.amount <> OLD.amount OR NEW.declaration_date <> OLD.declaration_date) THEN
    RAISE EXCEPTION 'amount and declaration_date cannot be modified after payout approval; cancel and reissue instead';
  END IF;

  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_dividend_payouts_integrity_ins_upd ON public.dividend_payouts;
CREATE TRIGGER trg_enforce_dividend_payouts_integrity_ins_upd
  BEFORE INSERT OR UPDATE ON public.dividend_payouts
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_enforce_dividend_payouts_integrity();

-- =============================================================================
-- 6. DYNAMIC VIEWS
-- =============================================================================

-- View: public.v_investor_equity
-- Authoritative dynamic equity derivation. Real-time cap table.
CREATE OR REPLACE VIEW public.v_investor_equity
WITH (security_invoker = true)
AS
WITH business_totals AS (
  SELECT
    business_id,
    COALESCE(SUM(amount), 0.00) AS total_business_capital
  FROM public.capital_contributions
  GROUP BY business_id
),
investor_totals AS (
  SELECT
    c.business_id,
    c.investor_id,
    COALESCE(SUM(c.amount), 0.00) AS total_investor_capital,
    COUNT(c.id) AS contribution_count,
    MIN(c.effective_date) AS first_investment_date,
    MAX(c.effective_date) AS latest_investment_date
  FROM public.capital_contributions c
  GROUP BY c.business_id, c.investor_id
)
SELECT
  it.business_id,
  it.investor_id,
  i.user_id,
  i.investor_code,
  i.legal_name,
  i.status AS investor_status,
  it.total_investor_capital,
  bt.total_business_capital,
  CASE
    WHEN bt.total_business_capital <= 0.00 THEN 0.0000
    ELSE ROUND((it.total_investor_capital / bt.total_business_capital) * 100.0, 4)
  END AS equity_percentage,
  it.contribution_count,
  it.first_investment_date,
  it.latest_investment_date
FROM investor_totals it
JOIN business_totals bt ON it.business_id = bt.business_id
JOIN public.investors i ON it.investor_id = i.id;

-- Direct client SELECT is revoked to prevent distorted denominator perceptions via RLS.
-- Ordinary investors access equity via rpc_get_my_equity().
-- Executive cap-table access is gated via rpc_get_cap_table().
REVOKE ALL ON TABLE public.v_investor_equity FROM PUBLIC, anon, authenticated;

-- View: public.v_user_active_permissions
-- Flattened active-permission view.
CREATE OR REPLACE VIEW public.v_user_active_permissions
WITH (security_invoker = true)
AS
SELECT DISTINCT
  ra.business_id,
  bm.user_id,
  r.id AS role_id,
  r.code AS role_code,
  r.name AS role_name,
  p.id AS permission_id,
  p.key AS permission_key,
  p.module AS permission_module,
  ras.scope_type,
  ras.branch_id,
  ras.department_id,
  ras.target_user_id
FROM public.role_assignments ra
JOIN public.business_memberships bm ON ra.membership_id = bm.id
JOIN public.roles r ON ra.role_id = r.id
JOIN public.role_permissions rp ON rp.role_id = r.id
JOIN public.permissions p ON rp.permission_id = p.id
LEFT JOIN public.role_assignment_scopes ras ON ras.role_assignment_id = ra.id
WHERE ra.status = 'active'
  AND (ra.expires_at IS NULL OR ra.expires_at > NOW())
  AND bm.status = 'active';

-- Direct client SELECT is revoked to prevent unauthorized or unvetted permission enumeration.
-- Callers must retrieve authorized permissions via rpc_get_my_active_permissions(p_business_id).
REVOKE ALL ON TABLE public.v_user_active_permissions FROM PUBLIC, anon, authenticated;

-- =============================================================================
-- 7. SCOPE-AWARE AUTHORIZATION FUNCTIONS
-- =============================================================================

-- Function: public.has_permission
-- Checks if the caller possesses the permission anywhere within the tenant.
CREATE OR REPLACE FUNCTION public.has_permission(
  p_business_id UUID,
  p_permission_key TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_is_owner BOOLEAN;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL OR p_business_id IS NULL OR p_permission_key IS NULL THEN
    RETURN FALSE;
  END IF;

  -- 1. Business must exist, have status = 'active', and deleted_at IS NULL for ALL callers
  SELECT (owner_user_id = v_caller_id) INTO v_is_owner
  FROM public.businesses
  WHERE id = p_business_id
    AND status = 'active'
    AND deleted_at IS NULL;

  IF v_is_owner IS NULL THEN
    RETURN FALSE;
  END IF;

  -- 2. PrimaryOwner holds universal permission for all REGISTERED permissions
  IF v_is_owner IS TRUE THEN
    RETURN EXISTS (
      SELECT 1
      FROM public.permissions
      WHERE key = p_permission_key
    );
  END IF;

  -- 3. Verify active membership in this business
  IF NOT EXISTS (
    SELECT 1 FROM public.business_memberships
    WHERE business_id = p_business_id
      AND user_id = v_caller_id
      AND status = 'active'
  ) THEN
    RETURN FALSE;
  END IF;

  -- 4. Check active role assignments
  RETURN EXISTS (
    SELECT 1
    FROM public.role_assignments ra
    JOIN public.business_memberships bm ON ra.membership_id = bm.id
    JOIN public.role_permissions rp ON rp.role_id = ra.role_id
    JOIN public.permissions p ON rp.permission_id = p.id
    WHERE ra.business_id = p_business_id
      AND bm.user_id = v_caller_id
      AND ra.status = 'active'
      AND (ra.expires_at IS NULL OR ra.expires_at > NOW())
      AND p.key = p_permission_key
  );
END;
$$;

REVOKE ALL ON FUNCTION public.has_permission(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_permission(UUID, TEXT) TO authenticated;

-- Function: public.has_permission_in_scope
-- Scope-aware authorization helper for a specific resource boundary.
CREATE OR REPLACE FUNCTION public.has_permission_in_scope(
  p_business_id UUID,
  p_permission_key TEXT,
  p_branch_id UUID DEFAULT NULL,
  p_department_id UUID DEFAULT NULL,
  p_target_user_id UUID DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_is_owner BOOLEAN;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL OR p_business_id IS NULL OR p_permission_key IS NULL THEN
    RETURN FALSE;
  END IF;

  -- 1. Business must exist, have status = 'active', and deleted_at IS NULL for ALL callers
  SELECT (owner_user_id = v_caller_id) INTO v_is_owner
  FROM public.businesses
  WHERE id = p_business_id
    AND status = 'active'
    AND deleted_at IS NULL;

  IF v_is_owner IS NULL THEN
    RETURN FALSE;
  END IF;

  -- 2. PrimaryOwner holds tenant-wide authority for all REGISTERED permissions
  IF v_is_owner IS TRUE THEN
    RETURN EXISTS (
      SELECT 1
      FROM public.permissions
      WHERE key = p_permission_key
    );
  END IF;

  -- 3. Caller must be an active member of this business
  IF NOT EXISTS (
    SELECT 1 FROM public.business_memberships
    WHERE business_id = p_business_id
      AND user_id = v_caller_id
      AND status = 'active'
  ) THEN
    RETURN FALSE;
  END IF;

  -- 4. Evaluate scope-aware matches
  RETURN EXISTS (
    SELECT 1
    FROM public.role_assignments ra
    JOIN public.business_memberships bm ON ra.membership_id = bm.id
    JOIN public.role_permissions rp ON rp.role_id = ra.role_id
    JOIN public.permissions p ON rp.permission_id = p.id
    LEFT JOIN public.role_assignment_scopes ras ON ras.role_assignment_id = ra.id
    WHERE ra.business_id = p_business_id
      AND bm.user_id = v_caller_id
      AND ra.status = 'active'
      AND (ra.expires_at IS NULL OR ra.expires_at > NOW())
      AND p.key = p_permission_key
      AND (
        -- Business Scope: covers entire business tenant
        ras.scope_type = 'Business'
        -- Branch Scope: covers matching branch
        OR (ras.scope_type = 'Branch' AND p_branch_id IS NOT NULL AND ras.branch_id = p_branch_id)
        -- Department Scope: covers matching department
        OR (ras.scope_type = 'Department' AND p_department_id IS NOT NULL AND ras.department_id = p_department_id)
        -- Self Scope: covers caller's own records only
        OR (ras.scope_type = 'Self' AND p_target_user_id IS NOT NULL AND p_target_user_id = v_caller_id)
      )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.has_permission_in_scope(UUID, TEXT, UUID, UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_permission_in_scope(UUID, TEXT, UUID, UUID, UUID) TO authenticated;

-- Function: public.rpc_get_my_active_permissions
-- Returns the caller's authorized roles, explicit permissions, and scopes for a business.
CREATE OR REPLACE FUNCTION public.rpc_get_my_active_permissions(p_business_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_is_owner BOOLEAN;
  v_roles JSONB;
  v_permissions JSONB;
  v_scopes JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT (owner_user_id = v_caller_id) INTO v_is_owner
  FROM public.businesses
  WHERE id = p_business_id AND status = 'active' AND deleted_at IS NULL;

  IF v_is_owner IS NULL THEN
    RAISE EXCEPTION 'Active business % not found', p_business_id;
  END IF;

  IF v_is_owner IS TRUE THEN
    SELECT jsonb_agg(DISTINCT key ORDER BY key) INTO v_permissions FROM public.permissions;
    RETURN jsonb_build_object(
      'business_id', p_business_id,
      'is_primary_owner', TRUE,
      'roles', jsonb_build_array('PrimaryOwner'),
      'permissions', COALESCE(v_permissions, '[]'::jsonb),
      'scopes', jsonb_build_array(jsonb_build_object('scope_type', 'Business'))
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.business_memberships
    WHERE business_id = p_business_id AND user_id = v_caller_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Caller is not an active member of business %', p_business_id;
  END IF;

  SELECT jsonb_agg(DISTINCT r.code ORDER BY r.code) INTO v_roles
  FROM public.role_assignments ra
  JOIN public.roles r ON ra.role_id = r.id
  JOIN public.business_memberships bm ON ra.membership_id = bm.id
  WHERE ra.business_id = p_business_id
    AND bm.user_id = v_caller_id
    AND ra.status = 'active'
    AND (ra.expires_at IS NULL OR ra.expires_at > NOW());

  SELECT jsonb_agg(DISTINCT p.key ORDER BY p.key) INTO v_permissions
  FROM public.role_assignments ra
  JOIN public.role_permissions rp ON rp.role_id = ra.role_id
  JOIN public.permissions p ON rp.permission_id = p.id
  JOIN public.business_memberships bm ON ra.membership_id = bm.id
  WHERE ra.business_id = p_business_id
    AND bm.user_id = v_caller_id
    AND ra.status = 'active'
    AND (ra.expires_at IS NULL OR ra.expires_at > NOW());

  SELECT jsonb_agg(DISTINCT jsonb_build_object(
    'role_code', r.code,
    'scope_type', ras.scope_type,
    'branch_id', ras.branch_id,
    'department_id', ras.department_id,
    'target_user_id', ras.target_user_id
  )) INTO v_scopes
  FROM public.role_assignments ra
  JOIN public.roles r ON ra.role_id = r.id
  JOIN public.role_assignment_scopes ras ON ras.role_assignment_id = ra.id
  JOIN public.business_memberships bm ON ra.membership_id = bm.id
  WHERE ra.business_id = p_business_id
    AND bm.user_id = v_caller_id
    AND ra.status = 'active'
    AND (ra.expires_at IS NULL OR ra.expires_at > NOW());

  RETURN jsonb_build_object(
    'business_id', p_business_id,
    'is_primary_owner', FALSE,
    'roles', COALESCE(v_roles, '[]'::jsonb),
    'permissions', COALESCE(v_permissions, '[]'::jsonb),
    'scopes', COALESCE(v_scopes, '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_get_my_active_permissions(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_my_active_permissions(UUID) TO authenticated;

-- =============================================================================
-- 8. SECURE CAPITAL & EQUITY RPCs
-- =============================================================================

-- Function: public.rpc_get_my_equity
-- Secure equity calculator for investors. Calculates true denominator without row leakage.
CREATE OR REPLACE FUNCTION public.rpc_get_my_equity(p_business_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_investor_id UUID;
  v_my_capital NUMERIC(15,2);
  v_total_biz_capital NUMERIC(15,2);
  v_equity_pct NUMERIC(7,4);
  v_first_date DATE;
  v_latest_date DATE;
  v_count INT;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  -- Verify business exists and is active
  IF NOT EXISTS (
    SELECT 1 FROM public.businesses
    WHERE id = p_business_id AND status = 'active' AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Active business % not found', p_business_id;
  END IF;

  SELECT id INTO v_investor_id
  FROM public.investors
  WHERE business_id = p_business_id
    AND user_id = v_caller_id
    AND status = 'active';

  IF v_investor_id IS NULL THEN
    RAISE EXCEPTION 'Caller is not an active investor in business %', p_business_id;
  END IF;

  SELECT COALESCE(SUM(amount), 0.00) INTO v_total_biz_capital
  FROM public.capital_contributions
  WHERE business_id = p_business_id;

  SELECT
    COALESCE(SUM(amount), 0.00),
    COUNT(id),
    MIN(effective_date),
    MAX(effective_date)
  INTO
    v_my_capital,
    v_count,
    v_first_date,
    v_latest_date
  FROM public.capital_contributions
  WHERE business_id = p_business_id
    AND investor_id = v_investor_id;

  IF v_total_biz_capital <= 0.00 THEN
    v_equity_pct := 0.0000;
  ELSE
    v_equity_pct := ROUND((v_my_capital / v_total_biz_capital) * 100.0, 4);
  END IF;

  RETURN jsonb_build_object(
    'business_id', p_business_id,
    'investor_id', v_investor_id,
    'my_total_capital', v_my_capital,
    'total_business_capital', v_total_biz_capital,
    'equity_percentage', v_equity_pct,
    'contribution_count', v_count,
    'first_contribution_date', v_first_date,
    'latest_contribution_date', v_latest_date
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_get_my_equity(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_my_equity(UUID) TO authenticated;

-- Function: public.rpc_get_cap_table
-- Privileged cap table viewer for PrimaryOwner or callers with investor:view_equity.
-- Provides full real-time capitalization table with true denominator.
CREATE OR REPLACE FUNCTION public.rpc_get_cap_table(p_business_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_is_owner BOOLEAN;
  v_total_biz_capital NUMERIC(15,2);
  v_cap_table JSONB;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  -- 1. Business must exist, have status = 'active', and deleted_at IS NULL
  SELECT (owner_user_id = v_caller_id) INTO v_is_owner
  FROM public.businesses
  WHERE id = p_business_id
    AND status = 'active'
    AND deleted_at IS NULL;

  IF v_is_owner IS NULL THEN
    RAISE EXCEPTION 'Active business % not found', p_business_id;
  END IF;

  -- 2. Authorization: PrimaryOwner or Business-scoped registered permission 'investor:view_equity'
  IF NOT (
    v_is_owner IS TRUE
    OR public.has_permission_in_scope(p_business_id, 'investor:view_equity', NULL, NULL, NULL)
  ) THEN
    RAISE EXCEPTION 'Unauthorized: PrimaryOwner or Business-scoped investor:view_equity permission required';
  END IF;

  -- 3. Calculate total business capital denominator
  SELECT COALESCE(SUM(amount), 0.00) INTO v_total_biz_capital
  FROM public.capital_contributions
  WHERE business_id = p_business_id;

  -- 4. Aggregate cap table per investor (user_id omitted for data minimization)
  WITH investor_totals AS (
    SELECT
      c.investor_id,
      COALESCE(SUM(c.amount), 0.00) AS total_investor_capital,
      COUNT(c.id) AS contribution_count,
      MIN(c.effective_date) AS first_investment_date,
      MAX(c.effective_date) AS latest_investment_date
    FROM public.capital_contributions c
    WHERE c.business_id = p_business_id
    GROUP BY c.investor_id
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'investor_id', it.investor_id,
      'investor_code', i.investor_code,
      'legal_name', i.legal_name,
      'investor_status', i.status,
      'total_investor_capital', it.total_investor_capital,
      'equity_percentage', CASE
        WHEN v_total_biz_capital <= 0.00 THEN 0.0000
        ELSE ROUND((it.total_investor_capital / v_total_biz_capital) * 100.0, 4)
      END,
      'contribution_count', it.contribution_count,
      'first_investment_date', it.first_investment_date,
      'latest_investment_date', it.latest_investment_date
    ) ORDER BY it.total_investor_capital DESC
  ) INTO v_cap_table
  FROM investor_totals it
  JOIN public.investors i ON it.investor_id = i.id;

  RETURN jsonb_build_object(
    'business_id', p_business_id,
    'total_business_capital', v_total_biz_capital,
    'cap_table', COALESCE(v_cap_table, '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_get_cap_table(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_cap_table(UUID) TO authenticated;

-- Function: public.rpc_create_business_atomic
-- Atomic ACID onboarding of business, branch, membership, role, investor, and Entry #1.
CREATE OR REPLACE FUNCTION public.rpc_create_business_atomic(
  p_legal_name TEXT,
  p_trade_name TEXT DEFAULT NULL,
  p_currency TEXT DEFAULT 'USD',
  p_timezone TEXT DEFAULT 'America/New_York',
  p_initial_branch_name TEXT DEFAULT 'Main Branch',
  p_initial_capital NUMERIC(15,2) DEFAULT 100.00,
  p_capital_notes TEXT DEFAULT 'Founding owner initial equity contribution'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_caller_name TEXT;
  v_biz_id UUID;
  v_branch_id UUID;
  v_membership_id UUID;
  v_role_id UUID;
  v_assignment_id UUID;
  v_investor_id UUID;
  v_contribution_id UUID;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required to create a business';
  END IF;

  IF p_legal_name IS NULL OR char_length(trim(p_legal_name)) < 2 THEN
    RAISE EXCEPTION 'Business legal name must be at least 2 characters';
  END IF;

  -- Invariant: Initial capital is mandatory and must be strictly > 0.00
  IF p_initial_capital IS NULL OR p_initial_capital <= 0.00 THEN
    RAISE EXCEPTION 'Initial owner capital must be strictly greater than zero';
  END IF;

  -- Caller cannot be an active employee in another business
  IF EXISTS (
    SELECT 1 FROM public.staff_profiles
    WHERE user_id = v_caller_id AND employment_status <> 'Terminated'
  ) THEN
    RAISE EXCEPTION 'Active staff members in another business cannot create a business';
  END IF;

  SELECT full_name INTO v_caller_name
  FROM public.user_profiles
  WHERE id = v_caller_id AND status = 'active';

  IF v_caller_name IS NULL THEN
    RAISE EXCEPTION 'Active user profile required to create a business';
  END IF;

  -- 1. Create Business
  INSERT INTO public.businesses (
    owner_user_id,
    legal_name,
    trade_name,
    currency,
    timezone,
    status
  ) VALUES (
    v_caller_id,
    trim(p_legal_name),
    NULLIF(trim(p_trade_name), ''),
    COALESCE(p_currency, 'USD'),
    COALESCE(p_timezone, 'America/New_York'),
    'active'
  )
  RETURNING id INTO v_biz_id;

  -- 2. Create Initial Main Branch
  INSERT INTO public.branches (
    business_id,
    name,
    is_main,
    status
  ) VALUES (
    v_biz_id,
    COALESCE(NULLIF(trim(p_initial_branch_name), ''), 'Main Branch'),
    true,
    'active'
  )
  RETURNING id INTO v_branch_id;

  -- 3. Create Owner Membership
  INSERT INTO public.business_memberships (
    business_id,
    user_id,
    is_owner,
    primary_role,
    status
  ) VALUES (
    v_biz_id,
    v_caller_id,
    true,
    'PrimaryOwner',
    'active'
  )
  RETURNING id INTO v_membership_id;

  -- 4. Assign PrimaryOwner System Role
  SELECT id INTO v_role_id
  FROM public.roles
  WHERE code = 'PrimaryOwner' AND is_system = true;

  IF v_role_id IS NULL THEN
    RAISE EXCEPTION 'System role PrimaryOwner not found';
  END IF;

  INSERT INTO public.role_assignments (
    business_id,
    membership_id,
    role_id,
    status,
    assigned_by
  ) VALUES (
    v_biz_id,
    v_membership_id,
    v_role_id,
    'active',
    v_caller_id
  )
  RETURNING id INTO v_assignment_id;

  -- 5. Create Business Scope for PrimaryOwner
  INSERT INTO public.role_assignment_scopes (
    role_assignment_id,
    scope_type
  ) VALUES (
    v_assignment_id,
    'Business'
  );

  -- 6. Register Owner as Founding Investor
  INSERT INTO public.investors (
    business_id,
    membership_id,
    user_id,
    investor_code,
    legal_name,
    status
  ) VALUES (
    v_biz_id,
    v_membership_id,
    v_caller_id,
    'INV-001',
    COALESCE(v_caller_name, trim(p_legal_name)),
    'active'
  )
  RETURNING id INTO v_investor_id;

  -- 7. Write Capital Ledger Entry #1
  INSERT INTO public.capital_contributions (
    business_id,
    investor_id,
    entry_number,
    amount,
    contribution_type,
    effective_date,
    notes,
    created_by
  ) VALUES (
    v_biz_id,
    v_investor_id,
    1,
    p_initial_capital,
    'initial_owner_capital',
    CURRENT_DATE,
    COALESCE(p_capital_notes, 'Founding owner initial equity contribution'),
    v_caller_id
  )
  RETURNING id INTO v_contribution_id;

  -- 8. Set default_business_id for convenience if not already set
  UPDATE public.user_profiles
  SET default_business_id = v_biz_id
  WHERE id = v_caller_id AND default_business_id IS NULL;

  RETURN jsonb_build_object(
    'business_id', v_biz_id,
    'branch_id', v_branch_id,
    'membership_id', v_membership_id,
    'investor_id', v_investor_id,
    'contribution_id', v_contribution_id,
    'initial_capital', p_initial_capital,
    'equity_percentage', 100.0000
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_create_business_atomic(TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_business_atomic(TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, TEXT) TO authenticated;

-- Function: public.rpc_record_capital_contribution
-- Append-only capital ledger entry writer with serial row locking.
CREATE OR REPLACE FUNCTION public.rpc_record_capital_contribution(
  p_business_id UUID,
  p_investor_id UUID,
  p_amount NUMERIC(15,2),
  p_contribution_type TEXT,
  p_effective_date DATE DEFAULT CURRENT_DATE,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_locked_biz_id UUID;
  v_next_entry INT;
  v_contribution_id UUID;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_business_id IS NULL OR p_investor_id IS NULL THEN
    RAISE EXCEPTION 'business_id and investor_id are required';
  END IF;

  -- 1. Lock business record to serialize entry sequence and verify active status
  SELECT id INTO v_locked_biz_id
  FROM public.businesses
  WHERE id = p_business_id
    AND status = 'active'
    AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active business % not found', p_business_id;
  END IF;

  -- 2. Authorization check: PrimaryOwner OR Business-scoped legal_ownership:edit
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(
      p_business_id,
      'legal_ownership:edit',
      NULL,
      NULL,
      NULL
    )
  ) THEN
    RAISE EXCEPTION 'Unauthorized: PrimaryOwner or legal_ownership:edit permission required to record capital contributions';
  END IF;

  -- 3. Verify investor exists, belongs to business, and is active
  IF NOT EXISTS (
    SELECT 1 FROM public.investors
    WHERE id = p_investor_id
      AND business_id = p_business_id
      AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Active investor % not found in business %', p_investor_id, p_business_id;
  END IF;

  -- 4. Amount validation
  IF p_amount IS NULL OR p_amount <= 0.00 THEN
    RAISE EXCEPTION 'Capital contribution amount must be strictly greater than zero';
  END IF;

  -- 5. Strict contribution type validation (only additional_capital permitted via this endpoint)
  IF p_contribution_type <> 'additional_capital' THEN
    RAISE EXCEPTION 'Invalid contribution type: %. Only additional_capital is permitted via this endpoint',
      p_contribution_type;
  END IF;

  -- 6. Generate next entry sequence under business row lock
  SELECT COALESCE(MAX(entry_number), 0) + 1 INTO v_next_entry
  FROM public.capital_contributions
  WHERE business_id = p_business_id;

  -- 7. Insert append-only ledger entry with created_by guaranteed to be auth.uid()
  INSERT INTO public.capital_contributions (
    business_id,
    investor_id,
    entry_number,
    amount,
    contribution_type,
    effective_date,
    notes,
    created_by
  ) VALUES (
    p_business_id,
    p_investor_id,
    v_next_entry,
    p_amount,
    p_contribution_type,
    COALESCE(p_effective_date, CURRENT_DATE),
    trim(p_notes),
    v_caller_id
  )
  RETURNING id INTO v_contribution_id;

  RETURN jsonb_build_object(
    'contribution_id', v_contribution_id,
    'business_id', p_business_id,
    'investor_id', p_investor_id,
    'entry_number', v_next_entry,
    'amount', p_amount,
    'effective_date', COALESCE(p_effective_date, CURRENT_DATE)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_record_capital_contribution(UUID, UUID, NUMERIC, TEXT, DATE, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_record_capital_contribution(UUID, UUID, NUMERIC, TEXT, DATE, TEXT) TO authenticated;

-- Function: public.rpc_reverse_capital_contribution
-- Full reversal of an erroneous capital contribution with serialized lock and invariant checks.
CREATE OR REPLACE FUNCTION public.rpc_reverse_capital_contribution(
  p_business_id UUID,
  p_reference_contribution_id UUID,
  p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_locked_biz_id UUID;
  v_ref RECORD;
  v_next_entry INT;
  v_reversal_id UUID;
  v_reversal_amount NUMERIC(15,2);
  v_current_biz_total NUMERIC(15,2);
  v_current_inv_total NUMERIC(15,2);
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_business_id IS NULL OR p_reference_contribution_id IS NULL THEN
    RAISE EXCEPTION 'business_id and reference_contribution_id are required';
  END IF;

  -- 1. Authorization: PrimaryOwner OR Business-scoped legal_ownership:edit
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(
      p_business_id,
      'legal_ownership:edit',
      NULL,
      NULL,
      NULL
    )
  ) THEN
    RAISE EXCEPTION 'Unauthorized: PrimaryOwner or legal_ownership:edit permission required to reverse capital contributions';
  END IF;

  -- 2. Substantive reversal reason requirement
  IF p_reason IS NULL OR char_length(trim(p_reason)) < 5 THEN
    RAISE EXCEPTION 'A substantive reversal reason is required (minimum 5 characters)';
  END IF;

  -- 3. Acquire row lock on business record to serialize ledger operations
  SELECT id INTO v_locked_biz_id
  FROM public.businesses
  WHERE id = p_business_id
    AND status = 'active'
    AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active business % not found', p_business_id;
  END IF;

  -- 4. Lock and verify referenced contribution record
  SELECT * INTO v_ref
  FROM public.capital_contributions
  WHERE id = p_reference_contribution_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Referenced capital contribution % not found in business %',
      p_reference_contribution_id, p_business_id;
  END IF;

  -- Invariant: Cannot reverse an existing reversal
  IF v_ref.contribution_type = 'corrective_reversal' THEN
    RAISE EXCEPTION 'Cannot reverse a corrective reversal entry';
  END IF;

  -- Invariant: Contribution cannot be reversed more than once
  IF EXISTS (
    SELECT 1 FROM public.capital_contributions
    WHERE reference_contribution_id = v_ref.id
  ) THEN
    RAISE EXCEPTION 'Capital contribution % has already been reversed', v_ref.id;
  END IF;

  -- Exact full negative reversal amount
  v_reversal_amount := -1.00 * v_ref.amount;

  -- Invariant: Business total capital after reversal must remain > 0.00
  SELECT COALESCE(SUM(amount), 0.00) INTO v_current_biz_total
  FROM public.capital_contributions
  WHERE business_id = p_business_id;

  IF (v_current_biz_total + v_reversal_amount) <= 0.00 THEN
    RAISE EXCEPTION 'Reversal rejected: business total capital after reversal must remain strictly greater than zero (current: %, reversal: %)',
      v_current_biz_total, v_reversal_amount;
  END IF;

  -- Invariant: Investor total capital after reversal must remain >= 0.00
  SELECT COALESCE(SUM(amount), 0.00) INTO v_current_inv_total
  FROM public.capital_contributions
  WHERE business_id = p_business_id AND investor_id = v_ref.investor_id;

  IF (v_current_inv_total + v_reversal_amount) < 0.00 THEN
    RAISE EXCEPTION 'Reversal rejected: investor capital after reversal cannot be negative (current: %, reversal: %)',
      v_current_inv_total, v_reversal_amount;
  END IF;

  -- 5. Generate next entry sequence under serialized business lock
  SELECT COALESCE(MAX(entry_number), 0) + 1 INTO v_next_entry
  FROM public.capital_contributions
  WHERE business_id = p_business_id;

  -- 6. Insert reversal record with created_by guaranteed to be auth.uid()
  INSERT INTO public.capital_contributions (
    business_id,
    investor_id,
    entry_number,
    amount,
    contribution_type,
    reference_contribution_id,
    effective_date,
    notes,
    created_by
  ) VALUES (
    p_business_id,
    v_ref.investor_id,
    v_next_entry,
    v_reversal_amount,
    'corrective_reversal',
    v_ref.id,
    CURRENT_DATE,
    trim(p_reason),
    v_caller_id
  )
  RETURNING id INTO v_reversal_id;

  RETURN jsonb_build_object(
    'reversal_id', v_reversal_id,
    'business_id', p_business_id,
    'investor_id', v_ref.investor_id,
    'entry_number', v_next_entry,
    'reversed_contribution_id', v_ref.id,
    'amount', v_reversal_amount
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_reverse_capital_contribution(UUID, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_reverse_capital_contribution(UUID, UUID, TEXT) TO authenticated;

-- Function: public.rpc_set_staff_compensation
-- Atomically manages append-only compensation changes with scope-aware authorization.
-- Enforces inclusive date boundaries, staff row locking, and immutable historical records.
CREATE OR REPLACE FUNCTION public.rpc_set_staff_compensation(
  p_business_id UUID,
  p_staff_profile_id UUID,
  p_compensation_type TEXT,
  p_base_rate NUMERIC,
  p_effective_from DATE DEFAULT CURRENT_DATE,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_sp RECORD;
  v_curr_id UUID;
  v_curr_from DATE;
  v_closed_count INT := 0;
  v_new_id UUID;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_business_id IS NULL OR p_staff_profile_id IS NULL THEN
    RAISE EXCEPTION 'business_id and staff_profile_id are required';
  END IF;

  -- 1. Lock target staff profile row FOR UPDATE to serialize compensation changes
  SELECT id, business_id, user_id, branch_id, department_id, employment_status
  INTO v_sp
  FROM public.staff_profiles
  WHERE id = p_staff_profile_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Staff profile % not found in business %', p_staff_profile_id, p_business_id;
  END IF;

  -- 2. Scope-aware authorization check: PrimaryOwner OR staff:compensation_manage on staff scope
  IF NOT (
    public.is_business_owner(p_business_id)
    OR public.has_permission_in_scope(
      p_business_id,
      'staff:compensation_manage',
      v_sp.branch_id,
      v_sp.department_id,
      v_sp.user_id
    )
  ) THEN
    RAISE EXCEPTION 'Unauthorized: staff:compensation_manage permission required for target staff scope';
  END IF;

  -- 3. Input validations
  IF p_compensation_type NOT IN ('Hourly', 'Salary', 'Commission', 'Contract') THEN
    RAISE EXCEPTION 'Invalid compensation type: %', p_compensation_type;
  END IF;

  IF p_base_rate IS NULL OR p_base_rate < 0.00 THEN
    RAISE EXCEPTION 'base_rate must be non-negative';
  END IF;

  IF p_effective_from IS NULL THEN
    RAISE EXCEPTION 'effective_from date is required';
  END IF;

  IF p_effective_from > CURRENT_DATE THEN
    RAISE EXCEPTION 'Future-dated compensation is not supported in Migration 002';
  END IF;

  -- 4. Fetch and lock current active compensation record
  SELECT id, effective_from INTO v_curr_id, v_curr_from
  FROM public.staff_compensation
  WHERE business_id = p_business_id
    AND staff_profile_id = p_staff_profile_id
    AND status = 'active'
  FOR UPDATE;

  -- 5. Chronological progression check
  IF v_curr_id IS NOT NULL AND p_effective_from <= v_curr_from THEN
    RAISE EXCEPTION 'New compensation effective_from (%) must be strictly greater than current effective_from (%)',
      p_effective_from, v_curr_from;
  END IF;

  -- 6. Close existing active compensation record with inclusive boundary (effective_to = p_effective_from - 1)
  IF v_curr_id IS NOT NULL THEN
    UPDATE public.staff_compensation
    SET
      status = 'superseded',
      effective_to = p_effective_from - 1
    WHERE id = v_curr_id;
    v_closed_count := 1;
  END IF;

  -- 7. Insert new active compensation record (created_by is guaranteed auth.uid())
  INSERT INTO public.staff_compensation (
    business_id,
    staff_profile_id,
    compensation_type,
    base_rate,
    effective_from,
    effective_to,
    status,
    notes,
    created_by
  ) VALUES (
    p_business_id,
    p_staff_profile_id,
    p_compensation_type,
    p_base_rate,
    p_effective_from,
    NULL,
    'active',
    trim(p_notes),
    v_caller_id
  )
  RETURNING id INTO v_new_id;

  RETURN jsonb_build_object(
    'compensation_id', v_new_id,
    'staff_profile_id', p_staff_profile_id,
    'business_id', p_business_id,
    'compensation_type', p_compensation_type,
    'base_rate', p_base_rate,
    'effective_from', p_effective_from,
    'superseded_previous_records', v_closed_count,
    'created_by', v_caller_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_set_staff_compensation(UUID, UUID, TEXT, NUMERIC, DATE, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_staff_compensation(UUID, UUID, TEXT, NUMERIC, DATE, TEXT) TO authenticated;

-- Function: public.hash_business_invitation_token
-- Canonical deterministic SHA-256 token hashing helper for business invitations.
-- Ensures strict parity between invitation issuance and invitation acceptance.
-- Privilege minimized: IMMUTABLE STRICT (SECURITY INVOKER default, no elevated access).
CREATE OR REPLACE FUNCTION public.hash_business_invitation_token(p_token TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
BEGIN
  IF p_token IS NULL OR char_length(trim(p_token)) < 16 THEN
    RAISE EXCEPTION 'Valid token string of at least 16 characters is required for hashing';
  END IF;
  RETURN encode(sha256(convert_to(trim(p_token), 'UTF8')), 'hex');
END;
$$;

REVOKE ALL ON FUNCTION public.hash_business_invitation_token(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hash_business_invitation_token(TEXT) TO authenticated;

-- Function: public.rpc_create_business_invitation
-- Issues a secure team invitation. Generates high-entropy random token,
-- hashes it using public.hash_business_invitation_token, stores ONLY the hash in
-- business_invitations.token_hash, and returns the plaintext token once to the creator.
CREATE OR REPLACE FUNCTION public.rpc_create_business_invitation(
  p_business_id UUID,
  p_email TEXT,
  p_intended_role TEXT,
  p_branch_id UUID DEFAULT NULL,
  p_department_id UUID DEFAULT NULL,
  p_expires_in_days INT DEFAULT 7
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_clean_email TEXT;
  v_role RECORD;
  v_dept_branch_id UUID;
  v_raw_token TEXT;
  v_token_hash TEXT;
  v_invitation_id UUID;
  v_expires_at TIMESTAMPTZ;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required to issue invitations';
  END IF;

  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'business_id is required';
  END IF;

  -- 1. Validate email format
  v_clean_email := lower(trim(p_email));
  IF v_clean_email IS NULL OR v_clean_email !~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' THEN
    RAISE EXCEPTION 'Valid email address is required';
  END IF;

  -- 2. Validate intended role: cannot be PrimaryOwner
  IF trim(p_intended_role) = 'PrimaryOwner' THEN
    RAISE EXCEPTION 'PrimaryOwner invitations are forbidden; use formal ownership transfer';
  END IF;

  SELECT * INTO v_role
  FROM public.roles
  WHERE code = trim(p_intended_role)
    AND (
      (is_system = true AND business_id IS NULL)
      OR (is_system = false AND business_id = p_business_id)
    );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid role: % does not exist in business %', p_intended_role, p_business_id;
  END IF;

  -- 3. Validate branch/department tenancy, consistency, and caller scope authorization
  IF NOT public.is_business_owner(p_business_id) THEN
    IF p_department_id IS NOT NULL THEN
      SELECT branch_id INTO v_dept_branch_id
      FROM public.departments
      WHERE id = p_department_id AND business_id = p_business_id AND status = 'active';

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Department % is invalid or does not belong to business %', p_department_id, p_business_id;
      END IF;

      IF p_branch_id IS NOT NULL AND v_dept_branch_id IS NOT NULL AND v_dept_branch_id <> p_branch_id THEN
        RAISE EXCEPTION 'Branch/Department mismatch: Department % belongs to branch %, but invitation specifies branch %',
          p_department_id, v_dept_branch_id, p_branch_id;
      END IF;

      IF p_branch_id IS NULL AND v_dept_branch_id IS NOT NULL THEN
        p_branch_id := v_dept_branch_id;
      END IF;

      IF NOT public.has_permission_in_scope(p_business_id, 'staff:manage', p_branch_id, p_department_id, NULL) THEN
        RAISE EXCEPTION 'Unauthorized: staff:manage permission required for department %', p_department_id;
      END IF;

    ELSIF p_branch_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.branches
        WHERE id = p_branch_id AND business_id = p_business_id AND status = 'active'
      ) THEN
        RAISE EXCEPTION 'Branch % is invalid or does not belong to business %', p_branch_id, p_business_id;
      END IF;

      IF NOT public.has_permission_in_scope(p_business_id, 'staff:manage', p_branch_id, NULL, NULL) THEN
        RAISE EXCEPTION 'Unauthorized: staff:manage permission required for branch %', p_branch_id;
      END IF;

    ELSE
      -- Business-scoped invitation: caller must have Business-scoped staff:manage
      IF NOT public.has_permission_in_scope(p_business_id, 'staff:manage', NULL, NULL, NULL) THEN
        RAISE EXCEPTION 'Unauthorized: Business-scoped staff:manage permission required for business-wide invitation';
      END IF;
    END IF;
  ELSE
    -- PrimaryOwner: Validate branch and department exist if provided
    IF p_branch_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.branches
        WHERE id = p_branch_id AND business_id = p_business_id AND status = 'active'
      ) THEN
        RAISE EXCEPTION 'Branch % is invalid or does not belong to business %', p_branch_id, p_business_id;
      END IF;
    END IF;

    IF p_department_id IS NOT NULL THEN
      SELECT branch_id INTO v_dept_branch_id
      FROM public.departments
      WHERE id = p_department_id AND business_id = p_business_id AND status = 'active';

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Department % is invalid or does not belong to business %', p_department_id, p_business_id;
      END IF;

      IF p_branch_id IS NOT NULL AND v_dept_branch_id IS NOT NULL AND v_dept_branch_id <> p_branch_id THEN
        RAISE EXCEPTION 'Branch/Department mismatch: Department % belongs to branch %, but invitation specifies branch %',
          p_department_id, v_dept_branch_id, p_branch_id;
      END IF;

      IF p_branch_id IS NULL AND v_dept_branch_id IS NOT NULL THEN
        p_branch_id := v_dept_branch_id;
      END IF;
    END IF;
  END IF;

  -- 5. Expiration calculation (default 7 days, max 30 days)
  IF p_expires_in_days IS NULL OR p_expires_in_days < 1 OR p_expires_in_days > 30 THEN
    RAISE EXCEPTION 'expires_in_days must be between 1 and 30';
  END IF;
  v_expires_at := NOW() + (p_expires_in_days || ' days')::interval;

  -- 6. Cancel existing pending invitations for this email in this business
  UPDATE public.business_invitations
  SET status = 'cancelled'
  WHERE business_id = p_business_id
    AND lower(email) = v_clean_email
    AND status = 'pending';

  -- 7. High-entropy raw token generation (32 random bytes = 64 hex characters)
  v_raw_token := encode(gen_random_bytes(32), 'hex');

  -- 8. Compute token hash using canonical helper
  v_token_hash := public.hash_business_invitation_token(v_raw_token);

  -- 9. Insert invitation: stores ONLY the token hash
  INSERT INTO public.business_invitations (
    business_id,
    email,
    intended_role,
    branch_id,
    department_id,
    token_hash,
    status,
    invited_by,
    expires_at
  ) VALUES (
    p_business_id,
    v_clean_email,
    v_role.code,
    p_branch_id,
    p_department_id,
    v_token_hash,
    'pending',
    v_caller_id,
    v_expires_at
  )
  RETURNING id INTO v_invitation_id;

  -- 10. Return plaintext token once to authorized creator
  RETURN jsonb_build_object(
    'invitation_id', v_invitation_id,
    'business_id', p_business_id,
    'email', v_clean_email,
    'intended_role', v_role.code,
    'token', v_raw_token,
    'expires_at', v_expires_at,
    'status', 'pending'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_create_business_invitation(UUID, TEXT, TEXT, UUID, UUID, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_business_invitation(UUID, TEXT, TEXT, UUID, UUID, INT) TO authenticated;

-- Function: public.rpc_accept_business_invitation
-- Accepts a team invitation using a verified bearer token.
-- Hashes token via canonical helper, enforces verified email, serialized tenancy, deterministic roles, and single-business limits.
CREATE OR REPLACE FUNCTION public.rpc_accept_business_invitation(
  p_token TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_auth_email TEXT;
  v_email_confirmed_at TIMESTAMPTZ;
  v_caller_name TEXT;
  v_token_hash TEXT;
  v_invitation RECORD;
  v_role RECORD;
  v_locked_biz_id UUID;
  v_membership_id UUID;
  v_role_assignment_id UUID;
  v_staff_id UUID;
  v_investor_id UUID;
  v_emp_code TEXT;
  v_emp_seq INT;
  v_inv_code TEXT;
  v_inv_seq INT;
  v_inv_dept_branch_id UUID;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required to accept an invitation';
  END IF;

  IF p_token IS NULL OR char_length(trim(p_token)) < 16 THEN
    RAISE EXCEPTION 'Valid invitation bearer token is required';
  END IF;

  -- 1. Compute SHA-256 hash using canonical helper (token is never stored or logged)
  v_token_hash := public.hash_business_invitation_token(p_token);

  -- 2. Verify caller identity and verified email confirmation in auth.users
  SELECT email, email_confirmed_at INTO v_auth_email, v_email_confirmed_at
  FROM auth.users
  WHERE id = v_caller_id;

  IF v_auth_email IS NULL THEN
    RAISE EXCEPTION 'Authenticated user identity not found in auth.users';
  END IF;

  IF v_email_confirmed_at IS NULL THEN
    RAISE EXCEPTION 'User email (%) has not been confirmed. Verified email required to accept invitations', v_auth_email;
  END IF;

  SELECT full_name INTO v_caller_name
  FROM public.user_profiles
  WHERE id = v_caller_id AND status = 'active';

  IF v_caller_name IS NULL THEN
    RAISE EXCEPTION 'Active user profile not found for authenticated caller';
  END IF;

  -- 3. Lock invitation row FOR UPDATE to guarantee single-use acceptance
  SELECT * INTO v_invitation
  FROM public.business_invitations
  WHERE token_hash = v_token_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invitation not found or invalid token';
  END IF;

  -- 4. Verify status is pending
  IF v_invitation.status <> 'pending' THEN
    RAISE EXCEPTION 'Invitation is no longer pending (current status: %)', v_invitation.status;
  END IF;

  -- 5. Verify expiration
  IF v_invitation.expires_at <= NOW() THEN
    RAISE EXCEPTION 'Invitation has expired';
  END IF;

  -- 6. Verify case-insensitive email match against authoritative auth email
  IF LOWER(v_auth_email) <> LOWER(v_invitation.email) THEN
    RAISE EXCEPTION 'Authenticated email (%) does not match invited email (%)',
      v_auth_email, v_invitation.email;
  END IF;

  -- 6B. Verify Branch/Department consistency on invitation if both are present
  IF v_invitation.branch_id IS NOT NULL AND v_invitation.department_id IS NOT NULL THEN
    SELECT branch_id INTO v_inv_dept_branch_id
    FROM public.departments
    WHERE id = v_invitation.department_id AND business_id = v_invitation.business_id;

    IF v_inv_dept_branch_id IS NOT NULL AND v_inv_dept_branch_id <> v_invitation.branch_id THEN
      RAISE EXCEPTION 'Branch/Department mismatch on invitation: Department % belongs to branch %, but invitation specifies branch %',
        v_invitation.department_id, v_inv_dept_branch_id, v_invitation.branch_id;
    END IF;
  END IF;

  -- 7. Lock target business record FOR UPDATE to serialize membership and sequence counters
  SELECT id INTO v_locked_biz_id
  FROM public.businesses
  WHERE id = v_invitation.business_id
    AND status = 'active'
    AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Target business % is inactive or no longer exists', v_invitation.business_id;
  END IF;

  -- 8. Verify caller is not already an active member of this business
  IF EXISTS (
    SELECT 1 FROM public.business_memberships
    WHERE business_id = v_invitation.business_id
      AND user_id = v_caller_id
      AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Caller is already an active member of this business';
  END IF;

  -- 9. Deterministic Role Resolution (Reject nonexistent roles, never fall back silently)
  SELECT * INTO v_role
  FROM public.roles
  WHERE code = trim(v_invitation.intended_role)
    AND (
      (is_system = true AND business_id IS NULL)
      OR
      (is_system = false AND business_id = v_invitation.business_id)
    );

  IF v_role.id IS NULL THEN
    RAISE EXCEPTION 'Invalid or nonexistent intended role code % for business %',
      v_invitation.intended_role, v_invitation.business_id;
  END IF;

  -- Security invariant: PrimaryOwner cannot be assigned via invitation
  IF v_role.code = 'PrimaryOwner' THEN
    RAISE EXCEPTION 'Security invariant violation: PrimaryOwner role cannot be assigned via invitation';
  END IF;

  -- 10. Check single-business limits based on role category
  IF v_role.code = 'Investor' THEN
    IF EXISTS (
      SELECT 1 FROM public.investors
      WHERE user_id = v_caller_id AND business_id <> v_invitation.business_id
    ) THEN
      RAISE EXCEPTION 'Non-owner investor accounts are restricted to ONE business only';
    END IF;
  ELSIF v_role.code IN (
    'SuperAdmin', 'GeneralManager', 'BranchManager', 'DepartmentManager',
    'SalesManager', 'Salesperson', 'Cashier', 'StockManager',
    'StockStaff', 'FinanceManager', 'Employee'
  ) THEN
    IF EXISTS (
      SELECT 1 FROM public.staff_profiles
      WHERE user_id = v_caller_id
        AND business_id <> v_invitation.business_id
        AND employment_status <> 'Terminated'
    ) THEN
      RAISE EXCEPTION 'Active staff accounts belong to ONE business only. Active profile exists elsewhere';
    END IF;
  END IF;

  -- 11. Create Business Membership (using role code)
  INSERT INTO public.business_memberships (
    business_id,
    user_id,
    is_owner,
    primary_role,
    status
  ) VALUES (
    v_invitation.business_id,
    v_caller_id,
    false,
    v_role.code,
    'active'
  )
  RETURNING id INTO v_membership_id;

  -- 12. Create Role Assignment
  INSERT INTO public.role_assignments (
    business_id,
    membership_id,
    role_id,
    status,
    assigned_by
  ) VALUES (
    v_invitation.business_id,
    v_membership_id,
    v_role.id,
    'active',
    v_invitation.invited_by
  )
  RETURNING id INTO v_role_assignment_id;

  -- 13. Create Role Assignment Scope
  IF v_invitation.department_id IS NOT NULL THEN
    INSERT INTO public.role_assignment_scopes (
      role_assignment_id,
      scope_type,
      branch_id,
      department_id
    ) VALUES (
      v_role_assignment_id,
      'Department',
      v_invitation.branch_id,
      v_invitation.department_id
    );
  ELSIF v_invitation.branch_id IS NOT NULL THEN
    INSERT INTO public.role_assignment_scopes (
      role_assignment_id,
      scope_type,
      branch_id
    ) VALUES (
      v_role_assignment_id,
      'Branch',
      v_invitation.branch_id
    );
  ELSE
    INSERT INTO public.role_assignment_scopes (
      role_assignment_id,
      scope_type
    ) VALUES (
      v_role_assignment_id,
      'Business'
    );
  END IF;

  -- 14. Create Workforce or Capital Entity (Category-Aware)
  IF v_role.code = 'Investor' THEN
    SELECT COALESCE(COUNT(*), 0) + 1 INTO v_inv_seq
    FROM public.investors
    WHERE business_id = v_invitation.business_id;

    v_inv_code := 'INV-' || LPAD(v_inv_seq::TEXT, 3, '0');

    INSERT INTO public.investors (
      business_id,
      membership_id,
      user_id,
      investor_code,
      legal_name,
      status
    ) VALUES (
      v_invitation.business_id,
      v_membership_id,
      v_caller_id,
      v_inv_code,
      v_caller_name,
      'active'
    )
    RETURNING id INTO v_investor_id;

  ELSIF v_role.code IN (
    'SuperAdmin', 'GeneralManager', 'BranchManager', 'DepartmentManager',
    'SalesManager', 'Salesperson', 'Cashier', 'StockManager',
    'StockStaff', 'FinanceManager', 'Employee'
  ) THEN
    SELECT COALESCE(COUNT(*), 0) + 1 INTO v_emp_seq
    FROM public.staff_profiles
    WHERE business_id = v_invitation.business_id;

    v_emp_code := 'EMP-' || LPAD(v_emp_seq::TEXT, 4, '0');

    INSERT INTO public.staff_profiles (
      business_id,
      membership_id,
      user_id,
      employee_code,
      job_title,
      branch_id,
      department_id,
      employment_status,
      hire_date
    ) VALUES (
      v_invitation.business_id,
      v_membership_id,
      v_caller_id,
      v_emp_code,
      v_role.name,
      v_invitation.branch_id,
      v_invitation.department_id,
      'Active',
      CURRENT_DATE
    )
    RETURNING id INTO v_staff_id;
  END IF;
  -- Note: Custom roles (is_system = false) and governance / membership-only roles ('CoOwner', 'Viewer')
  -- do not create staff or investor profiles. They create membership, role assignment, and scope ONLY.

  -- 15. Mark Invitation as Accepted (Single-Use)
  UPDATE public.business_invitations
  SET
    status = 'accepted',
    accepted_at = NOW(),
    updated_at = NOW()
  WHERE id = v_invitation.id;

  -- 16. Set default_business_id for convenience if caller has none
  UPDATE public.user_profiles
  SET default_business_id = v_invitation.business_id
  WHERE id = v_caller_id AND default_business_id IS NULL;

  RETURN jsonb_build_object(
    'invitation_id', v_invitation.id,
    'business_id', v_invitation.business_id,
    'membership_id', v_membership_id,
    'role_assignment_id', v_role_assignment_id,
    'role_code', v_role.code,
    'staff_profile_id', v_staff_id,
    'investor_id', v_investor_id,
    'status', 'accepted'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_accept_business_invitation(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_accept_business_invitation(TEXT) TO authenticated;

-- Function: public.rpc_assign_role
-- Controlled role assignment and scope creation RPC.
-- Enforces: target membership validation, caller staff:manage authority over target person,
-- caller authority to grant requested scope (preventing privilege widening), blocks PrimaryOwner.
CREATE OR REPLACE FUNCTION public.rpc_assign_role(
  p_business_id UUID,
  p_membership_id UUID,
  p_role_id UUID,
  p_scope_type TEXT,
  p_branch_id UUID DEFAULT NULL,
  p_department_id UUID DEFAULT NULL,
  p_target_user_id UUID DEFAULT NULL,
  p_expires_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_is_owner BOOLEAN;
  v_target_user_id UUID;
  v_target_membership_status TEXT;
  v_target_is_owner BOOLEAN;
  v_role_code TEXT;
  v_role_is_system BOOLEAN;
  v_role_biz_id UUID;
  v_target_staff_branch_id UUID;
  v_target_staff_dept_id UUID;
  v_dept_branch_id UUID;
  v_assignment_id UUID;
  v_scope_id UUID;
  v_effective_branch_id UUID := p_branch_id;
  v_effective_dept_id UUID := p_department_id;
  v_effective_user_id UUID := p_target_user_id;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required to assign roles';
  END IF;

  IF p_business_id IS NULL OR p_membership_id IS NULL OR p_role_id IS NULL OR p_scope_type IS NULL THEN
    RAISE EXCEPTION 'business_id, membership_id, role_id, and scope_type are required';
  END IF;

  -- 1. Validate Business active status
  IF NOT EXISTS (
    SELECT 1 FROM public.businesses
    WHERE id = p_business_id AND status = 'active' AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Active business % not found', p_business_id;
  END IF;

  v_is_owner := public.is_business_owner(p_business_id);

  -- 2. Validate Target Membership in business
  SELECT user_id, is_owner, status
  INTO v_target_user_id, v_target_is_owner, v_target_membership_status
  FROM public.business_memberships
  WHERE id = p_membership_id AND business_id = p_business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Membership % does not exist in business %', p_membership_id, p_business_id;
  END IF;

  IF v_target_membership_status <> 'active' THEN
    RAISE EXCEPTION 'Cannot assign role to membership with status %', v_target_membership_status;
  END IF;

  -- 3. Validate Role
  SELECT code, is_system, business_id
  INTO v_role_code, v_role_is_system, v_role_biz_id
  FROM public.roles
  WHERE id = p_role_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Role % does not exist', p_role_id;
  END IF;

  -- Block assignment of PrimaryOwner
  IF v_role_code = 'PrimaryOwner' THEN
    RAISE EXCEPTION 'PrimaryOwner role cannot be assigned via rpc_assign_role; use formal ownership transfer';
  END IF;

  -- Tenancy check on custom role
  IF v_role_is_system IS FALSE AND v_role_biz_id <> p_business_id THEN
    RAISE EXCEPTION 'Cross-tenant violation: Role % belongs to business %', p_role_id, v_role_biz_id;
  END IF;

  -- 4. Resolve target staff profile scope (if person has a staff profile)
  SELECT branch_id, department_id
  INTO v_target_staff_branch_id, v_target_staff_dept_id
  FROM public.staff_profiles
  WHERE business_id = p_business_id AND user_id = v_target_user_id;

  -- 5. Validate caller authority over target person:
  -- Caller must be owner OR possess staff:manage over target person's scope
  IF NOT (
    v_is_owner
    OR public.has_permission_in_scope(
      p_business_id,
      'staff:manage',
      v_target_staff_branch_id,
      v_target_staff_dept_id,
      v_target_user_id
    )
  ) THEN
    RAISE EXCEPTION 'Unauthorized: Caller lacks staff:manage authority over target person';
  END IF;

  -- 6. Validate scope type and ensure caller is authorized to grant the requested scope
  -- (Caller may grant a scope ONLY equal to or narrower than caller's administrative scope)
  IF p_scope_type NOT IN ('Business', 'Branch', 'Department', 'Self') THEN
    RAISE EXCEPTION 'Invalid scope_type: must be Business, Branch, Department, or Self';
  END IF;

  IF p_scope_type = 'Business' THEN
    IF NOT (
      v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'staff:manage', NULL, NULL, NULL)
    ) THEN
      RAISE EXCEPTION 'Unauthorized: Only Business administrators can grant Business-scoped roles';
    END IF;
    v_effective_branch_id := NULL;
    v_effective_dept_id := NULL;
    v_effective_user_id := NULL;

  ELSIF p_scope_type = 'Branch' THEN
    IF v_effective_branch_id IS NULL THEN
      RAISE EXCEPTION 'Branch scope requires branch_id';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.branches
      WHERE id = v_effective_branch_id AND business_id = p_business_id AND status = 'active'
    ) THEN
      RAISE EXCEPTION 'Branch % does not exist in business %', v_effective_branch_id, p_business_id;
    END IF;
    IF NOT (
      v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'staff:manage', v_effective_branch_id, NULL, NULL)
    ) THEN
      RAISE EXCEPTION 'Unauthorized: Caller lacks staff:manage authority over branch % to grant Branch scope', v_effective_branch_id;
    END IF;
    v_effective_dept_id := NULL;
    v_effective_user_id := NULL;

  ELSIF p_scope_type = 'Department' THEN
    IF v_effective_dept_id IS NULL THEN
      RAISE EXCEPTION 'Department scope requires department_id';
    END IF;
    SELECT branch_id INTO v_dept_branch_id
    FROM public.departments
    WHERE id = v_effective_dept_id AND business_id = p_business_id AND status = 'active';

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Department % does not exist in business %', v_effective_dept_id, p_business_id;
    END IF;

    IF v_effective_branch_id IS NOT NULL AND v_effective_branch_id <> v_dept_branch_id THEN
      RAISE EXCEPTION 'Branch/Department mismatch: Department belongs to branch %, not %', v_dept_branch_id, v_effective_branch_id;
    END IF;
    v_effective_branch_id := v_dept_branch_id;

    IF NOT (
      v_is_owner
      OR public.has_permission_in_scope(p_business_id, 'staff:manage', v_effective_branch_id, v_effective_dept_id, NULL)
    ) THEN
      RAISE EXCEPTION 'Unauthorized: Caller lacks staff:manage authority over department % to grant Department scope', v_effective_dept_id;
    END IF;
    v_effective_user_id := NULL;

  ELSIF p_scope_type = 'Self' THEN
    v_effective_branch_id := NULL;
    v_effective_dept_id := NULL;
    v_effective_user_id := v_target_user_id;
  END IF;

  -- 7. Insert role_assignments record
  INSERT INTO public.role_assignments (
    business_id,
    membership_id,
    role_id,
    status,
    assigned_by,
    expires_at
  ) VALUES (
    p_business_id,
    p_membership_id,
    p_role_id,
    'active',
    v_caller_id,
    p_expires_at
  )
  RETURNING id INTO v_assignment_id;

  -- 8. Insert role_assignment_scopes record
  INSERT INTO public.role_assignment_scopes (
    role_assignment_id,
    scope_type,
    branch_id,
    department_id,
    target_user_id
  ) VALUES (
    v_assignment_id,
    p_scope_type,
    v_effective_branch_id,
    v_effective_dept_id,
    v_effective_user_id
  )
  RETURNING id INTO v_scope_id;

  RETURN jsonb_build_object(
    'role_assignment_id', v_assignment_id,
    'scope_id', v_scope_id,
    'business_id', p_business_id,
    'membership_id', p_membership_id,
    'role_id', p_role_id,
    'role_code', v_role_code,
    'scope_type', p_scope_type,
    'branch_id', v_effective_branch_id,
    'department_id', v_effective_dept_id,
    'target_user_id', v_effective_user_id,
    'status', 'active'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_assign_role(UUID, UUID, UUID, TEXT, UUID, UUID, UUID, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_assign_role(UUID, UUID, UUID, TEXT, UUID, UUID, UUID, TIMESTAMPTZ) TO authenticated;

-- Function: public.rpc_revoke_role_assignment
-- Controlled role revocation RPC.
-- Locks assignment FOR UPDATE, rejects PrimaryOwner revocation,
-- requires caller staff:manage authority over target user scope, enforces substantive reason.
CREATE OR REPLACE FUNCTION public.rpc_revoke_role_assignment(
  p_role_assignment_id UUID,
  p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id UUID;
  v_assignment RECORD;
  v_role RECORD;
  v_is_owner BOOLEAN;
  v_target_user_id UUID;
  v_target_staff_branch_id UUID;
  v_target_staff_dept_id UUID;
  v_clean_reason TEXT;
BEGIN
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required to revoke role assignments';
  END IF;

  IF p_role_assignment_id IS NULL THEN
    RAISE EXCEPTION 'p_role_assignment_id is required';
  END IF;

  v_clean_reason := trim(p_reason);
  IF v_clean_reason IS NULL OR char_length(v_clean_reason) < 3 THEN
    RAISE EXCEPTION 'A substantive revocation reason is required (minimum 3 characters)';
  END IF;

  -- 1. Lock assignment FOR UPDATE
  SELECT ra.*, bm.user_id AS target_user_id
  INTO v_assignment
  FROM public.role_assignments ra
  JOIN public.business_memberships bm ON ra.membership_id = bm.id
  WHERE ra.id = p_role_assignment_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Role assignment % does not exist', p_role_assignment_id;
  END IF;

  IF v_assignment.status = 'revoked' THEN
    RAISE EXCEPTION 'Role assignment % is already revoked', p_role_assignment_id;
  END IF;

  -- 2. Reject PrimaryOwner revocation
  SELECT code, is_system INTO v_role
  FROM public.roles
  WHERE id = v_assignment.role_id;

  IF v_role.code = 'PrimaryOwner' AND v_role.is_system IS TRUE THEN
    RAISE EXCEPTION 'PrimaryOwner role assignment cannot be revoked; use formal ownership transfer';
  END IF;

  -- 3. Check ownership
  v_is_owner := public.is_business_owner(v_assignment.business_id);

  -- 4. Resolve target user's staff scope
  v_target_user_id := v_assignment.target_user_id;
  SELECT branch_id, department_id
  INTO v_target_staff_branch_id, v_target_staff_dept_id
  FROM public.staff_profiles
  WHERE business_id = v_assignment.business_id AND user_id = v_target_user_id;

  -- 5. Scope-aware authorization check:
  -- Caller must be owner OR possess staff:manage over target person's scope
  IF NOT (
    v_is_owner
    OR public.has_permission_in_scope(
      v_assignment.business_id,
      'staff:manage',
      v_target_staff_branch_id,
      v_target_staff_dept_id,
      v_target_user_id
    )
  ) THEN
    RAISE EXCEPTION 'Unauthorized: caller lacks staff:manage authority over target role assignment';
  END IF;

  -- 6. Perform revocation
  UPDATE public.role_assignments
  SET
    status = 'revoked',
    revocation_reason = v_clean_reason,
    revoked_at = NOW(),
    revoked_by = v_caller_id,
    updated_at = NOW()
  WHERE id = p_role_assignment_id;

  RETURN jsonb_build_object(
    'role_assignment_id', p_role_assignment_id,
    'status', 'revoked',
    'revoked_by', v_caller_id,
    'revocation_reason', v_clean_reason
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_revoke_role_assignment(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_revoke_role_assignment(UUID, TEXT) TO authenticated;

-- =============================================================================
-- 9. ROW-LEVEL SECURITY (RLS) POLICIES
-- =============================================================================

ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_assignment_scopes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_private_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_compensation ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.investors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.capital_contributions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dividend_payouts ENABLE ROW LEVEL SECURITY;

-- Helper: public.is_business_member
-- Evaluates whether caller has an active membership in an active, non-deleted business.
-- Security Definer to bypass RLS recursion when policies inspect memberships.
CREATE OR REPLACE FUNCTION public.is_business_member(p_business_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT (auth.uid() IS NOT NULL) AND EXISTS (
    SELECT 1 
    FROM public.business_memberships m
    JOIN public.businesses b ON b.id = m.business_id
    WHERE m.business_id = p_business_id
      AND m.user_id = auth.uid()
      AND m.status = 'active'
      AND b.status = 'active'
      AND b.deleted_at IS NULL
  );
$$;

REVOKE ALL ON FUNCTION public.is_business_member(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_business_member(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.is_business_member(UUID) TO authenticated;

-- 9.1 roles Policies
DROP POLICY IF EXISTS "roles_select_policy" ON public.roles;
CREATE POLICY "roles_select_policy" ON public.roles
  FOR SELECT TO authenticated
  USING (
    is_system = true
    OR (business_id IS NOT NULL AND public.is_business_member(business_id))
  );

DROP POLICY IF EXISTS "roles_insert_policy" ON public.roles;
CREATE POLICY "roles_insert_policy" ON public.roles
  FOR INSERT TO authenticated
  WITH CHECK (
    is_system = false
    AND business_id IS NOT NULL
    AND public.is_business_owner(business_id)
  );

DROP POLICY IF EXISTS "roles_update_policy" ON public.roles;
CREATE POLICY "roles_update_policy" ON public.roles
  FOR UPDATE TO authenticated
  USING (
    is_system = false
    AND business_id IS NOT NULL
    AND public.is_business_owner(business_id)
  )
  WITH CHECK (
    is_system = false
    AND business_id IS NOT NULL
    AND public.is_business_owner(business_id)
  );

DROP POLICY IF EXISTS "roles_delete_policy" ON public.roles;
CREATE POLICY "roles_delete_policy" ON public.roles
  FOR DELETE TO authenticated
  USING (
    is_system = false
    AND business_id IS NOT NULL
    AND public.is_business_owner(business_id)
  );

-- 9.2 permissions Policies
DROP POLICY IF EXISTS "permissions_select_policy" ON public.permissions;
CREATE POLICY "permissions_select_policy" ON public.permissions
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS "permissions_modify_policy" ON public.permissions;
CREATE POLICY "permissions_modify_policy" ON public.permissions
  FOR ALL TO authenticated
  USING (false);

-- 9.3 role_permissions Policies
DROP POLICY IF EXISTS "role_permissions_select_policy" ON public.role_permissions;
CREATE POLICY "role_permissions_select_policy" ON public.role_permissions
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.roles r
      WHERE r.id = role_permissions.role_id
        AND (r.is_system = true OR public.is_business_member(r.business_id))
    )
  );

DROP POLICY IF EXISTS "role_permissions_insert_policy" ON public.role_permissions;
CREATE POLICY "role_permissions_insert_policy" ON public.role_permissions
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.roles r
      WHERE r.id = role_permissions.role_id
        AND r.is_system = false
        AND public.is_business_owner(r.business_id)
    )
  );

DROP POLICY IF EXISTS "role_permissions_delete_policy" ON public.role_permissions;
CREATE POLICY "role_permissions_delete_policy" ON public.role_permissions
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.roles r
      WHERE r.id = role_permissions.role_id
        AND r.is_system = false
        AND public.is_business_owner(r.business_id)
    )
  );

-- 9.4 role_assignments Policies
DROP POLICY IF EXISTS "role_assignments_select_policy" ON public.role_assignments;
CREATE POLICY "role_assignments_select_policy" ON public.role_assignments
  FOR SELECT TO authenticated
  USING (public.is_business_member(business_id));

-- Direct client INSERT and UPDATE blocked: role assignments must be managed via controlled RPCs.
DROP POLICY IF EXISTS "role_assignments_insert_policy" ON public.role_assignments;
CREATE POLICY "role_assignments_insert_policy" ON public.role_assignments
  FOR INSERT TO authenticated
  WITH CHECK (false);

DROP POLICY IF EXISTS "role_assignments_update_policy" ON public.role_assignments;
CREATE POLICY "role_assignments_update_policy" ON public.role_assignments
  FOR UPDATE TO authenticated
  USING (false);

DROP POLICY IF EXISTS "role_assignments_delete_policy" ON public.role_assignments;
CREATE POLICY "role_assignments_delete_policy" ON public.role_assignments
  FOR DELETE TO authenticated
  USING (false);

-- 9.5 role_assignment_scopes Policies
DROP POLICY IF EXISTS "role_assignment_scopes_select_policy" ON public.role_assignment_scopes;
CREATE POLICY "role_assignment_scopes_select_policy" ON public.role_assignment_scopes
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.role_assignments ra
      WHERE ra.id = role_assignment_scopes.role_assignment_id
        AND public.is_business_member(ra.business_id)
    )
  );

-- Direct client INSERT blocked: scopes must be created atomically via rpc_assign_role.
DROP POLICY IF EXISTS "role_assignment_scopes_insert_policy" ON public.role_assignment_scopes;
CREATE POLICY "role_assignment_scopes_insert_policy" ON public.role_assignment_scopes
  FOR INSERT TO authenticated
  WITH CHECK (false);

DROP POLICY IF EXISTS "role_assignment_scopes_update_policy" ON public.role_assignment_scopes;
CREATE POLICY "role_assignment_scopes_update_policy" ON public.role_assignment_scopes
  FOR UPDATE TO authenticated
  USING (false);

DROP POLICY IF EXISTS "role_assignment_scopes_delete_policy" ON public.role_assignment_scopes;
CREATE POLICY "role_assignment_scopes_delete_policy" ON public.role_assignment_scopes
  FOR DELETE TO authenticated
  USING (false);

-- 9.6 staff_profiles Policies
-- Scope-aware SELECT: PrimaryOwner, Business-scoped staff:view, Branch-scoped staff:view,
-- Department-scoped staff:view, or employee self-access.
DROP POLICY IF EXISTS "staff_profiles_select_policy" ON public.staff_profiles;
CREATE POLICY "staff_profiles_select_policy" ON public.staff_profiles
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR public.is_business_owner(business_id)
    OR public.has_permission_in_scope(
      business_id,
      'staff:view',
      branch_id,
      department_id,
      user_id
    )
  );

-- Scope-aware INSERT: Requires PrimaryOwner or staff:manage over target branch/department/user.
DROP POLICY IF EXISTS "staff_profiles_insert_policy" ON public.staff_profiles;
CREATE POLICY "staff_profiles_insert_policy" ON public.staff_profiles
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_business_owner(business_id)
    OR public.has_permission_in_scope(
      business_id,
      'staff:manage',
      branch_id,
      department_id,
      user_id
    )
  );

-- Scope-aware UPDATE: USING protects authority over OLD row, WITH CHECK protects authority over NEW row.
DROP POLICY IF EXISTS "staff_profiles_update_policy" ON public.staff_profiles;
CREATE POLICY "staff_profiles_update_policy" ON public.staff_profiles
  FOR UPDATE TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR public.has_permission_in_scope(
      business_id,
      'staff:manage',
      branch_id,
      department_id,
      user_id
    )
  )
  WITH CHECK (
    public.is_business_owner(business_id)
    OR public.has_permission_in_scope(
      business_id,
      'staff:manage',
      branch_id,
      department_id,
      user_id
    )
  );

DROP POLICY IF EXISTS "staff_profiles_delete_policy" ON public.staff_profiles;
CREATE POLICY "staff_profiles_delete_policy" ON public.staff_profiles
  FOR DELETE TO authenticated
  USING (false);

-- 9.7 staff_compensation Policies
-- Confidential compensation records isolated from general staff directory.
-- Scope-aware SELECT: Requires PrimaryOwner OR staff:compensation_view within target profile scope.
DROP POLICY IF EXISTS "staff_compensation_select_policy" ON public.staff_compensation;
CREATE POLICY "staff_compensation_select_policy" ON public.staff_compensation
  FOR SELECT TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR EXISTS (
      SELECT 1 FROM public.staff_profiles sp
      WHERE sp.id = staff_compensation.staff_profile_id
        AND sp.business_id = staff_compensation.business_id
        AND public.has_permission_in_scope(
          business_id,
          'staff:compensation_view',
          sp.branch_id,
          sp.department_id,
          sp.user_id
        )
    )
  );

-- Direct client INSERT blocked: append-only compensation must be set atomically via rpc_set_staff_compensation.
DROP POLICY IF EXISTS "staff_compensation_insert_policy" ON public.staff_compensation;
CREATE POLICY "staff_compensation_insert_policy" ON public.staff_compensation
  FOR INSERT TO authenticated
  WITH CHECK (false);

-- Direct client UPDATE blocked: historical compensation values are immutable.
DROP POLICY IF EXISTS "staff_compensation_update_policy" ON public.staff_compensation;
CREATE POLICY "staff_compensation_update_policy" ON public.staff_compensation
  FOR UPDATE TO authenticated
  USING (false);

-- Hard deletes forbidden to preserve payroll audit history.
DROP POLICY IF EXISTS "staff_compensation_delete_policy" ON public.staff_compensation;
CREATE POLICY "staff_compensation_delete_policy" ON public.staff_compensation
  FOR DELETE TO authenticated
  USING (false);

-- 9.8 staff_private_details Policies
-- Confidential workforce HR details isolated from general directory.
-- Requires PrimaryOwner, staff:manage within scope, or the employee themselves.
DROP POLICY IF EXISTS "staff_private_details_select_policy" ON public.staff_private_details;
CREATE POLICY "staff_private_details_select_policy" ON public.staff_private_details
  FOR SELECT TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR EXISTS (
      SELECT 1 FROM public.staff_profiles sp
      WHERE sp.id = staff_private_details.staff_profile_id
        AND sp.business_id = staff_private_details.business_id
        AND (
          sp.user_id = auth.uid()
          OR public.has_permission_in_scope(
            business_id,
            'staff:manage',
            sp.branch_id,
            sp.department_id,
            sp.user_id
          )
        )
    )
  );

DROP POLICY IF EXISTS "staff_private_details_insert_policy" ON public.staff_private_details;
CREATE POLICY "staff_private_details_insert_policy" ON public.staff_private_details
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_business_owner(business_id)
    OR EXISTS (
      SELECT 1 FROM public.staff_profiles sp
      WHERE sp.id = staff_private_details.staff_profile_id
        AND sp.business_id = staff_private_details.business_id
        AND public.has_permission_in_scope(
          business_id,
          'staff:manage',
          sp.branch_id,
          sp.department_id,
          sp.user_id
        )
    )
  );

DROP POLICY IF EXISTS "staff_private_details_update_policy" ON public.staff_private_details;
CREATE POLICY "staff_private_details_update_policy" ON public.staff_private_details
  FOR UPDATE TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR EXISTS (
      SELECT 1 FROM public.staff_profiles sp
      WHERE sp.id = staff_private_details.staff_profile_id
        AND sp.business_id = staff_private_details.business_id
        AND (
          sp.user_id = auth.uid()
          OR public.has_permission_in_scope(
            business_id,
            'staff:manage',
            sp.branch_id,
            sp.department_id,
            sp.user_id
          )
        )
    )
  )
  WITH CHECK (
    public.is_business_owner(business_id)
    OR EXISTS (
      SELECT 1 FROM public.staff_profiles sp
      WHERE sp.id = staff_private_details.staff_profile_id
        AND sp.business_id = staff_private_details.business_id
        AND (
          sp.user_id = auth.uid()
          OR public.has_permission_in_scope(
            business_id,
            'staff:manage',
            sp.branch_id,
            sp.department_id,
            sp.user_id
          )
        )
    )
  );

DROP POLICY IF EXISTS "staff_private_details_delete_policy" ON public.staff_private_details;
CREATE POLICY "staff_private_details_delete_policy" ON public.staff_private_details
  FOR DELETE TO authenticated
  USING (false);

-- 9.9 investors Policies
DROP POLICY IF EXISTS "investors_select_policy" ON public.investors;
CREATE POLICY "investors_select_policy" ON public.investors
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR public.is_business_owner(business_id)
    OR public.has_permission_in_scope(business_id, 'investor:view', NULL, NULL, NULL)
  );

DROP POLICY IF EXISTS "investors_insert_policy" ON public.investors;
CREATE POLICY "investors_insert_policy" ON public.investors
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_business_owner(business_id)
    OR public.has_permission_in_scope(business_id, 'investor:manage', NULL, NULL, NULL)
  );

DROP POLICY IF EXISTS "investors_update_policy" ON public.investors;
CREATE POLICY "investors_update_policy" ON public.investors
  FOR UPDATE TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR public.has_permission_in_scope(business_id, 'investor:manage', NULL, NULL, NULL)
  )
  WITH CHECK (
    public.is_business_owner(business_id)
    OR public.has_permission_in_scope(business_id, 'investor:manage', NULL, NULL, NULL)
  );

DROP POLICY IF EXISTS "investors_delete_policy" ON public.investors;
CREATE POLICY "investors_delete_policy" ON public.investors
  FOR DELETE TO authenticated
  USING (false);

-- 9.10 capital_contributions Policies
-- Direct select allowed only for PrimaryOwner, executive cap-table viewers, or an investor viewing own lines.
DROP POLICY IF EXISTS "capital_contributions_select_policy" ON public.capital_contributions;
CREATE POLICY "capital_contributions_select_policy" ON public.capital_contributions
  FOR SELECT TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR public.has_permission_in_scope(business_id, 'investor:view_equity', NULL, NULL, NULL)
    OR EXISTS (
      SELECT 1 FROM public.investors i
      WHERE i.id = capital_contributions.investor_id
        AND i.user_id = auth.uid()
    )
  );

-- Direct client INSERT blocked: append-only ledger entries must be recorded via authorized RPCs.
DROP POLICY IF EXISTS "capital_contributions_insert_policy" ON public.capital_contributions;
CREATE POLICY "capital_contributions_insert_policy" ON public.capital_contributions
  FOR INSERT TO authenticated
  WITH CHECK (false);

DROP POLICY IF EXISTS "capital_contributions_update_policy" ON public.capital_contributions;
CREATE POLICY "capital_contributions_update_policy" ON public.capital_contributions
  FOR UPDATE TO authenticated
  USING (false);

DROP POLICY IF EXISTS "capital_contributions_delete_policy" ON public.capital_contributions;
CREATE POLICY "capital_contributions_delete_policy" ON public.capital_contributions
  FOR DELETE TO authenticated
  USING (false);

-- 9.11 dividend_payouts Policies
DROP POLICY IF EXISTS "dividend_payouts_select_policy" ON public.dividend_payouts;
CREATE POLICY "dividend_payouts_select_policy" ON public.dividend_payouts
  FOR SELECT TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR public.has_permission_in_scope(business_id, 'investor:view', NULL, NULL, NULL)
    OR EXISTS (
      SELECT 1 FROM public.investors i
      WHERE i.id = dividend_payouts.investor_id
        AND i.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "dividend_payouts_insert_policy" ON public.dividend_payouts;
CREATE POLICY "dividend_payouts_insert_policy" ON public.dividend_payouts
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_business_owner(business_id)
    OR public.has_permission_in_scope(business_id, 'investor:payout', NULL, NULL, NULL)
  );

DROP POLICY IF EXISTS "dividend_payouts_update_policy" ON public.dividend_payouts;
CREATE POLICY "dividend_payouts_update_policy" ON public.dividend_payouts
  FOR UPDATE TO authenticated
  USING (
    public.is_business_owner(business_id)
    OR public.has_permission_in_scope(business_id, 'investor:payout', NULL, NULL, NULL)
  )
  WITH CHECK (
    public.is_business_owner(business_id)
    OR public.has_permission_in_scope(business_id, 'investor:payout', NULL, NULL, NULL)
  );

DROP POLICY IF EXISTS "dividend_payouts_delete_policy" ON public.dividend_payouts;
CREATE POLICY "dividend_payouts_delete_policy" ON public.dividend_payouts
  FOR DELETE TO authenticated
  USING (false);

-- =============================================================================
-- 10. SYSTEM SEED DATA: CANONICAL PERMISSIONS & SYSTEM ROLES
-- =============================================================================

-- 10.1 Seed System Permissions
INSERT INTO public.permissions (key, module, description) VALUES
  -- Business & System Administration
  ('business:view', 'business', 'View business profile and tenant settings'),
  ('business:update', 'business', 'Update business general settings and details'),
  ('business:transfer_ownership', 'business', 'Initiate or complete transfer of primary business ownership'),
  ('business:delete', 'business', 'Archive or delete the business tenant'),

  -- Branch & Facility Management
  ('branch:view', 'branch', 'View branch locations and facility statuses'),
  ('branch:create', 'branch', 'Create new physical or virtual branches'),
  ('branch:update', 'branch', 'Update branch location details and operating hours'),
  ('branch:delete', 'branch', 'Archive or deactivate a branch location'),

  -- Department & Organizational Hierarchy
  ('department:view', 'department', 'View departments and organizational structure'),
  ('department:create', 'department', 'Create organizational departments'),
  ('department:update', 'department', 'Update department names and metadata'),
  ('department:delete', 'department', 'Archive or deactivate departments'),

  -- Workforce & Staff Management
  ('staff:view', 'staff', 'View staff directory, employee profiles, and shift status'),
  ('staff:manage', 'staff', 'Hire, onboard, edit, or reassign staff members'),
  ('staff:terminate', 'staff', 'Process staff termination or suspension'),
  ('staff:compensation_view', 'staff', 'View staff compensation, wages, and pay rates'),
  ('staff:compensation_manage', 'staff', 'Update staff salary and wage parameters'),

  -- Sales & POS Operations
  ('sales:view', 'sales', 'View sales orders and transaction history'),
  ('sales:create', 'sales', 'Process point-of-sale checkout and generate receipts'),
  ('sales:discount', 'sales', 'Apply discounts or custom pricing to a sale'),
  ('sales:refund', 'sales', 'Process customer refunds and credit notes'),
  ('sales:void', 'sales', 'Void existing receipts or incomplete checkout transactions'),

  -- Catalog & Product Management
  ('catalog:view', 'catalog', 'View product catalog, pricing, and categories'),
  ('catalog:create', 'catalog', 'Create new products, variants, and categories'),
  ('catalog:update', 'catalog', 'Update product pricing, SKUs, and details'),
  ('catalog:delete', 'catalog', 'Archive or deactivate products and categories'),

  -- Inventory & Stock Logistics
  ('inventory:view', 'inventory', 'View real-time stock balances across locations'),
  ('inventory:adjust', 'inventory', 'Log physical count adjustments, shrinkage, or damages'),
  ('inventory:transfer', 'inventory', 'Initiate or receive inter-branch inventory transfers'),
  ('inventory:audit', 'inventory', 'Conduct formal stock audit cycles and reconciliation'),

  -- Treasury, Banking & Finance
  ('treasury:view', 'treasury', 'View company bank accounts, vaults, and balances'),
  ('treasury:deposit', 'treasury', 'Log capital deposits, incoming cash, or receipts'),
  ('treasury:transfer', 'treasury', 'Transfer funds between treasury accounts or vaults'),
  ('treasury:reconcile', 'treasury', 'Reconcile bank statements against internal ledgers'),

  -- Investors & Equity Cap Table
  ('investor:view', 'investor', 'View investor roster and contact information'),
  ('investor:view_equity', 'investor', 'View complete enterprise cap table and equity stakes'),
  ('investor:manage', 'investor', 'Onboard investors and record capital adjustments'),
  ('investor:payout', 'investor', 'Declare, approve, and execute dividend disbursements'),

  -- Analytics, Auditing & Reporting
  ('reports:view_operational', 'reports', 'View daily operational, shift, and branch reports'),
  ('reports:view_financial', 'reports', 'View P&L, balance sheets, and cash flow statements'),
  ('audit:view_logs', 'audit', 'Inspect cryptographic audit trails and security logs'),

  -- Legal Ownership & Capital Ledger Sovereign Governance
  ('legal_ownership:edit', 'ownership', 'Sovereign governance authority to record or reverse equity capital ledger entries')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module,
  description = EXCLUDED.description;

-- 10.2 Seed System Standard Roles
INSERT INTO public.roles (code, name, description, is_system, business_id) VALUES
  ('PrimaryOwner', 'Primary Owner', 'Authoritative founding business owner holding total sovereign authority', true, NULL),
  ('CoOwner', 'Co-Owner', 'Executive business partner holding full operational governance', true, NULL),
  ('SuperAdmin', 'Super Administrator', 'Technical enterprise administrator managing system settings and staff', true, NULL),
  ('GeneralManager', 'General Manager', 'Executive manager overseeing all operational branches and finance', true, NULL),
  ('BranchManager', 'Branch Manager', 'Operational manager responsible for a specific branch and facility', true, NULL),
  ('DepartmentManager', 'Department Manager', 'Team lead responsible for a functional department', true, NULL),
  ('SalesManager', 'Sales Manager', 'Commercial lead managing sales representatives and customer pricing', true, NULL),
  ('Salesperson', 'Salesperson', 'Frontline sales representative processing quotes and customer orders', true, NULL),
  ('Cashier', 'Cashier', 'Point of sale operator processing transactions, payments, and receipts', true, NULL),
  ('StockManager', 'Stock Manager', 'Logistics lead managing warehouse stock, transfers, and counts', true, NULL),
  ('StockStaff', 'Stock Staff', 'Inventory clerk receiving purchase orders and logging counts', true, NULL),
  ('FinanceManager', 'Finance Manager', 'Accountant and controller managing treasury, taxes, and ledgers', true, NULL),
  ('Investor', 'Investor', 'Equity partner with secure portal access to financial returns and equity', true, NULL),
  ('Employee', 'Employee', 'Standard staff member with self-service schedule and shift access', true, NULL),
  ('Viewer', 'Read-Only Viewer', 'Auditor with read-only access to standard operational reports', true, NULL)
ON CONFLICT (code) WHERE is_system = true DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description;

-- 10.3 Map Standard Permissions to System Roles
DO $$
DECLARE
  v_role_id UUID;
BEGIN
  -- Helper macro: map permission keys to role code
  -- PrimaryOwner gets ALL permissions
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'PrimaryOwner' AND is_system = true;
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT v_role_id, p.id FROM public.permissions p
  ON CONFLICT (role_id, permission_id) DO NOTHING;

  -- CoOwner gets ALL permissions except ownership transfer, business deletion, and sovereign legal ownership ledger mutation
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'CoOwner' AND is_system = true;
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT v_role_id, p.id FROM public.permissions p
  WHERE p.key NOT IN ('business:transfer_ownership', 'business:delete', 'legal_ownership:edit')
  ON CONFLICT (role_id, permission_id) DO NOTHING;

  -- SuperAdmin: System settings, branches, departments, staff, catalog, inventory, audit
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'SuperAdmin' AND is_system = true;
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT v_role_id, p.id FROM public.permissions p
  WHERE p.key IN (
    'business:view', 'business:update',
    'branch:view', 'branch:create', 'branch:update',
    'department:view', 'department:create', 'department:update',
    'staff:view', 'staff:manage', 'staff:compensation_view',
    'catalog:view', 'catalog:create', 'catalog:update',
    'inventory:view', 'inventory:transfer', 'inventory:audit',
    'treasury:view', 'reports:view_operational', 'audit:view_logs'
  )
  ON CONFLICT (role_id, permission_id) DO NOTHING;

  -- GeneralManager
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'GeneralManager' AND is_system = true;
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT v_role_id, p.id FROM public.permissions p
  WHERE p.key IN (
    'business:view', 'branch:view', 'department:view',
    'staff:view', 'staff:manage', 'staff:compensation_view',
    'sales:view', 'sales:create', 'sales:discount', 'sales:refund',
    'catalog:view', 'catalog:create', 'catalog:update',
    'inventory:view', 'inventory:adjust', 'inventory:transfer', 'inventory:audit',
    'treasury:view', 'reports:view_operational', 'reports:view_financial'
  )
  ON CONFLICT (role_id, permission_id) DO NOTHING;

  -- BranchManager
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'BranchManager' AND is_system = true;
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT v_role_id, p.id FROM public.permissions p
  WHERE p.key IN (
    'branch:view', 'department:view', 'staff:view',
    'sales:view', 'sales:create', 'sales:discount', 'sales:refund',
    'catalog:view', 'inventory:view', 'inventory:adjust', 'inventory:transfer',
    'reports:view_operational'
  )
  ON CONFLICT (role_id, permission_id) DO NOTHING;

  -- DepartmentManager
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'DepartmentManager' AND is_system = true;
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT v_role_id, p.id FROM public.permissions p
  WHERE p.key IN (
    'department:view', 'staff:view', 'reports:view_operational'
  )
  ON CONFLICT (role_id, permission_id) DO NOTHING;

  -- SalesManager
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'SalesManager' AND is_system = true;
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT v_role_id, p.id FROM public.permissions p
  WHERE p.key IN (
    'catalog:view', 'sales:view', 'sales:create', 'sales:discount', 'sales:refund', 'sales:void',
    'reports:view_operational'
  )
  ON CONFLICT (role_id, permission_id) DO NOTHING;

  -- Cashier
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'Cashier' AND is_system = true;
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT v_role_id, p.id FROM public.permissions p
  WHERE p.key IN ('catalog:view', 'sales:view', 'sales:create')
  ON CONFLICT (role_id, permission_id) DO NOTHING;

  -- StockManager
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'StockManager' AND is_system = true;
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT v_role_id, p.id FROM public.permissions p
  WHERE p.key IN (
    'catalog:view', 'catalog:create', 'catalog:update',
    'inventory:view', 'inventory:adjust', 'inventory:transfer', 'inventory:audit'
  )
  ON CONFLICT (role_id, permission_id) DO NOTHING;

  -- FinanceManager
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'FinanceManager' AND is_system = true;
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT v_role_id, p.id FROM public.permissions p
  WHERE p.key IN (
    'business:view', 'sales:view', 'sales:refund',
    'treasury:view', 'treasury:deposit', 'treasury:transfer', 'treasury:reconcile',
    'investor:view', 'investor:view_equity', 'investor:payout',
    'reports:view_operational', 'reports:view_financial'
  )
  ON CONFLICT (role_id, permission_id) DO NOTHING;

  -- Investor
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'Investor' AND is_system = true;
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT v_role_id, p.id FROM public.permissions p
  WHERE p.key IN ('business:view', 'investor:view')
  ON CONFLICT (role_id, permission_id) DO NOTHING;

  -- Employee
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'Employee' AND is_system = true;
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT v_role_id, p.id FROM public.permissions p
  WHERE p.key IN ('business:view', 'branch:view')
  ON CONFLICT (role_id, permission_id) DO NOTHING;

  -- Viewer
  SELECT id INTO v_role_id FROM public.roles WHERE code = 'Viewer' AND is_system = true;
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT v_role_id, p.id FROM public.permissions p
  WHERE p.key IN ('business:view', 'branch:view', 'catalog:view', 'reports:view_operational')
  ON CONFLICT (role_id, permission_id) DO NOTHING;
END $$;

-- =============================================================================
-- END OF MIGRATION 002
-- =============================================================================
