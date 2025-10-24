export interface Syncable {
  syncStatus?: 'pending' | 'synced';
  lastUpdated?: string;
  isDeleted?: boolean;
}

export interface StockAdjustment {
  date: string;
  userId: string;
  type: 'add' | 'remove';
  quantity: number;
  reason: string;
  newStockLevel: number;
}

export type BusinessSettingsData = Syncable & {
  paymentMethods: string[];
  defaultTaxRate: number;
  rounding: {
    enabled: boolean;
    toNearest: number; // e.g., 0.05 for nearest 5 cents, 1 for nearest dollar
  };
  delivery: {
    enabled: boolean;
    fee: number;
  };
  investorProfitWithdrawalRate: number; // Percentage (e.g., 10 for 10%)
  acceptRemoteOrders?: boolean;
}

export type BusinessProfile = Syncable & {
    id?: string;
    businessName: string;
    dateEstablished: string;
    employeeCount: string;
    businessType: string;
    website?: string;
    businessEmail: string;
    businessPhone: string;
    logo?: string | null;
    isPublic?: boolean;
}

export interface LicensingInfo {
  licenseType: 'Trial' | 'Free' | 'Premium';
  enrollmentDate: string;
  trialEndDate: string;
}

export interface VariantOption {
  name: string;
  values: string[];
}

export interface ProductVariant {
  id: string;
  attributes: { name: string; value: string }[];
  price: number;
  costPrice: number;
  stock: number;
  sku?: string;
}

export type Product = Syncable & {
  id: string;
  name: string;
  description?: string;
  category: string;
  price: number;
  costPrice: number;
  stock: number;
  imageUrl: string;
  commissionPercentage: number;
  tieredPricing?: Array<{ quantity: number; price: number; }>;
  stockHistory?: StockAdjustment[];
  productType?: 'simple' | 'variable';
  variantOptions?: VariantOption[];
  variants?: ProductVariant[];
}

export type Customer = Syncable & {
  id: string;
  name: string;
  email: string;
  phone: string;
  joinDate: string;
  purchaseHistory: Sale[];
}

export interface AttendanceRecord {
  clockIn: string;
  clockOut: string | null;
}

export interface Withdrawal {
    id: string;
    date: string;
    amount: number;
    status: 'pending' | 'approved' | 'rejected' | 'paid' | 'completed';
    source: 'commission' | 'investment';
    notes?: string;
}

export interface CustomPayment {
    id: string;
    dateInitiated: string;
    amount: number;
    description: string;
    status: 'pending_user_approval' | 'rejected_by_user' | 'approved_by_user' | 'paid' | 'completed';
    initiatedBy: string; // userId of owner/manager
    notes?: string;
}

export type Deposit = Syncable & {
    id: string;
    date: string;
    amount: number;
    description: string;
    userId: string;
    status: 'pending' | 'approved' | 'rejected';
}

export type Role = 'Owner' | 'Manager' | 'Cashier' | 'Investor' | 'SellerAgent' | 'Super Admin' | 'Custom';

export type User = Syncable & {
  id: string;
  name: string;
  role: Role;
  customRoleName?: string;
  email: string;
  avatarUrl: string;
  password?: string; // Optional for security reasons in a real app
  type: 'hourly' | 'commission';
  hourlyRate?: number;
  attendance?: AttendanceRecord[];
  withdrawals?: Withdrawal[];
  customPayments?: CustomPayment[];
  status?: 'Active' | 'Invited';
  // Investor-specific fields
  initialInvestment?: number;
  investmentDate?: string;
  sharePercentage?: number;
  bankDetails?: string;
  phone?: string;
}

export type PerformanceUser = User & {
    salesCount: number;
    totalSalesValue: number;
    totalCommission: number;
    totalHours: number;
    totalHourlyEarnings: number;
    totalCommissionWithdrawals: number;
    totalInvestmentWithdrawals: number;
};

export type CartItem = {
  product: Product;
  variant?: ProductVariant;
  quantity: number;
}

export type Sale = Syncable & {
  id: string;
  date: string;
  items: CartItem[];
  customerId: string;
  userId: string;
  subtotal: number;
  tax: number;
  discount: number;
  total: number;
  paymentMethod?: string;
  taxRate?: number;
  discountPercentage?: number;
  commission?: number;
  status: 'completed' | 'proforma' | 'pending_approval' | 'rejected' | 'client_order';
  cashReceived?: number;
  change?: number;
  businessId?: string;
}

export type Expense = Syncable & {
  id: string;
  date: string;
  category: string;
  description: string;
  amount: number;
}

export type ExpenseRequest = Syncable & {
  id: string;
  date: string;
  userId: string;
  category: string;
  description: string;
  amount: number;
  status: 'pending' | 'approved' | 'rejected';
  approvedBy?: string;
  notes?: string;
}

export type PrinterSettingsData = Syncable & {
  autoPrint: boolean;
}

export type ReceiptSettingsData = Syncable & {
  logo: string | null; // Base64 string or URL
  businessName: string;
  slogan: string;
  address: string;
  phone: string;
  email: string;
  website: string;
  currencySymbol: string;
  receiptPrefix: string;
  social: {
    twitter: string;
    instagram: string;
  };
  receiptTitle: string;
  thankYouNote: string;
  termsAndConditions: string;
  labels: {
    receiptNumber: string;
    proformaNumber: string;
    date: string;
    time: string;
    customer: string;
    cashier: string;
    payment: string;
    item: string;
    total: string; // Header for item total
    subtotal: string;
    tax: string;
    discount: string;
    grandTotal: string; // Final total
    itemCode: string;
    quantity: string;
    price: string;
    cashReceived: string;
    change: string;
    pMode: string;
    itemCount: string;
    unitCount: string;
    amount: string;
  }
}

// Props for components that will need to trigger a sale deletion
export interface ReceiptsProps {
    sales: Sale[];
    t: (key: string) => string;
    receiptSettings: ReceiptSettingsData;
    onDeleteSale: (saleId: string) => void;
    currentUser: User;
}

export interface Investor {
  id: string;
  name: string;
  avatarUrl: string;
  initialInvestment: number;
  investmentDate: string;
}

export interface CompanyValuation {
  date: string;
  value: number;
}

export type OwnerSettings = Syncable & {
  commissionTrackingEnabled: boolean;
  includeInStaffReports: boolean;
  showOnLeaderboard: boolean;
}

// New type for Admin Panel data
export interface AdminBusinessData {
  id: string;
  profile: BusinessProfile;
  licensingInfo: LicensingInfo;
  settings: {
    acceptRemoteOrders: boolean;
  };
  owner: {
    name: string;
    email: string;
  };
  stats: {
    totalRevenue: number;
    salesCount: number;
    userCount: number;
    joinedDate: string;
    status: 'Active' | 'Suspended' | 'Pending';
  };
}

// FIX: Added missing StorefrontProps interface.
export interface StorefrontProps {
    products: Product[];
    cart: CartItem[];
    customers: Customer[];
    users: User[];
    onUpdateCartItem: (product: Product, variant: ProductVariant | undefined, quantity: number) => void;
    onProcessSale: (sale: Sale) => void;
    onDeleteSale: (saleId: string) => void;
    receiptSettings: ReceiptSettingsData;
    currentUser: User;
    businessSettings: BusinessSettingsData;
    t: (key: string) => string;
}

// --- NEW PERMISSION TYPES ---
export const PERMISSION_ACTIONS = ['view', 'add', 'edit', 'delete', 'share', 'export'] as const;
export type PermissionAction = typeof PERMISSION_ACTIONS[number];

export type PermissionSet = {
    [key in PermissionAction]?: boolean;
};

export type UserPermissions = {
    [path: string]: PermissionSet;
};

export type AppPermissions = Syncable & {
    roles: Partial<Record<Role, UserPermissions>>;
    users: Record<string, UserPermissions>; // UserID -> UserPermissions (overrides)
}
// --- END NEW PERMISSION TYPES ---