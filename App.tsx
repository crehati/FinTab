// @ts-nocheck
// FIX: Imported `Component` directly from React and extended it to resolve type issues with `this.props`.
import React, { Component, useState, useCallback, useEffect, useMemo, useRef, ErrorInfo, ReactNode, PropsWithChildren } from 'react';
import { HashRouter, Routes, Route, useLocation, Navigate, NavLink, useNavigate, useParams } from 'react-router-dom';

// Import types
// FIX: Added 'StockAdjustment' to the type imports.
import type { Product, Customer, User, Sale, Expense, CartItem, ReceiptSettingsData, Investor, CompanyValuation, Role, Withdrawal, Deposit, BusinessSettingsData, BusinessProfile, StockAdjustment, CustomPayment, ExpenseRequest, LicensingInfo, AppPermissions, PrinterSettingsData, ProductVariant, OwnerSettings, AdminBusinessData } from './types';

// Import constants and dummy data
import {
    DUMMY_PRODUCTS,
    DUMMY_CUSTOMERS,
    DUMMY_USERS,
    DUMMY_SALES,
    DUMMY_EXPENSES,
    DUMMY_DEPOSITS,
    COMPANY_VALUATION_HISTORY,
    MenuIcon,
    ChevronDownIcon,
    BellIcon,
    CounterIcon,
    DUMMY_ADMIN_BUSINESS_DATA
} from './constants';
import { DEFAULT_PERMISSIONS } from './lib/permissions';

// Import components directly to avoid dynamic import issues
import Dashboard from './components/Dashboard';
import Sidebar from './components/Sidebar';
import Inventory from './components/Inventory';
import Customers from './components/Customers';
import Users from './components/Users';
import Receipts from './components/Receipts';
import Expenses from './components/Expenses';
import ExpenseRequestPage from './components/ExpenseRequestPage';
import ExpenseReport from './components/ExpenseReport';
import Settings from './components/Settings';
import ChatHelp from './components/ChatHelp';
import Proforma from './components/Proforma';
import Commission from './components/Commission';
import ReceiptSettings from './components/ReceiptSettings';
import Today from './components/Today';
import Reports from './components/Reports';
import Items from './components/Items';
import Counter from './components/Counter';
import More from './components/More';
import BottomNavBar from './components/BottomNavBar';
import InvestorPage from './components/Investor';
import Login from './components/Login';
import LoginPortal from './components/LoginPortal';
import Permissions from './components/Permissions';
import MyProfile from './components/MyProfile';
import InvestorProfile from './components/InvestorProfile';
import Transactions from './components/Transactions';
import AccessDenied from './components/AccessDenied';
import BusinessSettings from './components/BusinessSettings';
import Onboarding from './components/Onboarding';
import AdminDashboard from './components/AdminDashboard';
import RequestsDashboard from './components/RequestsDashboard';
import PublicStorefront from './components/PublicStorefront';
import AIAssistant from './components/AIAssistant';
import UpgradeBanner from './components/UpgradeBanner';
import GoBackButton from './components/GoBackButton';
import PrinterSettings from './components/PrinterSettings';
import Directory from './components/Directory';


// Import translations
import { translations } from './lib/translations';
import { hasAccess } from './lib/permissions';
import { setStoredItemAndDispatchEvent as setStoredItem, getStoredItem } from './lib/utils';

// Error Boundary Component
interface ErrorBoundaryProps {
  // children removed from here and handled by PropsWithChildren
}
interface ErrorBoundaryState {
  hasError: boolean;
}
// FIX: Changed props to use PropsWithChildren to correctly type `children` and resolve compilation error.
export class ErrorBoundary extends Component<PropsWithChildren<ErrorBoundaryProps>, ErrorBoundaryState> {
  constructor(props: PropsWithChildren<ErrorBoundaryProps>) {
    super(props);
    this.state = { hasError: false };
  }

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { hasError: true };
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    console.error("Uncaught error:", error, errorInfo);
  }

  render() {
    if (this.state.hasError) {
      return (
        <div className="flex items-center justify-center h-screen">
            <div className="text-center">
                <h1 className="text-2xl font-bold text-error">Something went wrong.</h1>
                <p className="text-neutral-medium mt-2">Please refresh the page to try again.</p>
            </div>
        </div>
      );
    }

    return this.props.children;
  }
}


// Default Receipt Settings
const DEFAULT_RECEIPT_SETTINGS: ReceiptSettingsData = {
    logo: null,
    businessName: 'Your Business Name',
    slogan: 'Your Slogan Here',
    address: '123 Business Ave, Your City',
    phone: '(123) 456-7890',
    email: 'contact@yourbusiness.com',
    website: 'www.yourbusiness.com',
    currencySymbol: '$',
    receiptPrefix: 'RE',
    social: { twitter: '@yourtwitter', instagram: '@yourinstagram' },
    receiptTitle: 'SALES RECEIPT',
    thankYouNote: 'Thank you for your business!',
    termsAndConditions: 'All sales are final. Exchanges within 7 days with receipt.',
    labels: {
        receiptNumber: "Receipt No:",
        proformaNumber: "Proforma No:",
        date: "Date:",
        time: "Time:",
        customer: "Customer:",
        cashier: "Cashier:",
        payment: "Payment Method:",
        item: "Name",
        total: "Total",
        subtotal: "Subtotal",
        tax: "Tax:",
        discount: "Discount",
        grandTotal: "GRAND TOTAL",
        itemCode: "Code",
        quantity: "Quantity",
        price: "Price",
        cashReceived: "Cash Received:",
        change: "Change:",
        pMode: "P Mode",
        itemCount: "I#",
        unitCount: "U#",
        amount: "Amount"
    }
};

// Default Business Settings
const DEFAULT_BUSINESS_SETTINGS: BusinessSettingsData = {
    paymentMethods: ['Cash', 'Credit Card', 'Debit Card', 'Bank Transfer', 'Mobile Payment'],
    defaultTaxRate: 8,
    rounding: {
        enabled: false,
        toNearest: 0.05,
    },
    delivery: {
        enabled: false,
        fee: 10,
    },
    investorProfitWithdrawalRate: 10, // Default to 10%
    acceptRemoteOrders: true,
};

// Default Owner Settings
const DEFAULT_OWNER_SETTINGS: OwnerSettings = {
    commissionTrackingEnabled: true,
    includeInStaffReports: true,
    showOnLeaderboard: true,
};

// Default Printer Settings
const DEFAULT_PRINTER_SETTINGS: PrinterSettingsData = {
    autoPrint: false,
};

const useWindowSize = () => {
    const [windowSize, setWindowSize] = useState({
        width: window.innerWidth,
        height: window.innerHeight,
    });
    useEffect(() => {
        const handleResize = () => setWindowSize({ width: window.innerWidth, height: window.innerHeight });
        window.addEventListener('resize', handleResize);
        return () => window.removeEventListener('resize', handleResize);
    }, []);
    return windowSize;
};

const pageTitles: { [key: string]: string } = {
    '/dashboard': 'Dashboard',
    '/assistant': 'AI Assistant',
    '/today': 'Today\'s Summary',
    '/reports': 'Reports',
    '/shopfront': 'Shopfront',
    '/inventory': 'Inventory',
    '/receipts': 'Sales Receipts',
    '/proforma': 'Proforma Invoices',
    '/commission': 'Commissions',
    '/expenses': 'Expenses',
    '/expense-requests': 'Expense II',
    '/expenses/reports': 'Expense Report',
    '/customer-management': 'Customers',
    '/users': 'User Management',
    '/investors': 'Investor Dashboard',
    '/counter': 'Counter',
    '/transactions': 'Cash Transactions',
    '/chat-help': 'Chat Help',
    '/settings': 'Settings',
    '/settings/receipts': 'Receipt Settings',
    '/settings/permissions': 'Role & Permission Management',
    '/settings/business': 'Business Settings',
    '/settings/printer': 'Printer Settings',
    '/more': 'More Options',
    '/profile': 'My Profile',
    '/investor-profile': 'My Investment',
    '/access-denied': 'Access Denied',
    '/directory': 'Business Directory'
};

const MainLayout: React.FC<{
    isMobile: boolean;
    t: (key: string) => string;
    currentUser: User;
    handleUserChange: (user: User) => void;
    handleLogout: () => void;
    users: User[];
    sales: Sale[];
    customers: Customer[];
    products: Product[];
    expenses: Expense[];
    deposits: Deposit[];
    lowStockThreshold: number;
    setLowStockThreshold: (val: number) => void;
    cart: CartItem[];
    onUpdateCartItem: (product: Product, variant: ProductVariant | undefined, quantity: number) => void;
    onProcessSale: (sale: Sale) => void;
    onDeleteSale: (saleId: string) => void;
    onClearCart: () => void;
    receiptSettings: ReceiptSettingsData;
    setProducts: (products: Product[]) => void;
    setExpenses: (expenses: Expense[]) => void;
    setCustomers: (customers: Customer[]) => void;
    companyValuations: CompanyValuation[];
    language: string;
    setLanguage: (lang: string) => void;
    setReceiptSettings: (settings: ReceiptSettingsData) => void;
    permissions: AppPermissions;
    setPermissions: (permissions: AppPermissions) => void;
    onAddCustomer: (customerData: Omit<Customer, 'id' | 'joinDate' | 'purchaseHistory'>) => Customer;
    onSaveUser: (userData: Omit<User, 'id' | 'avatarUrl'>, isEditing: boolean, existingUserId?: string) => User | void;
    onDeleteUser: (userId: string) => void;
    handleRequestWithdrawal: (userId: string, amount: number, source: 'commission' | 'investment') => void;
    onUpdateWithdrawalStatus: (userId: string, withdrawalId: string, status: 'approved' | 'rejected') => void;
    handleRequestDeposit: (amount: number, description: string) => void;
    onUpdateDepositStatus: (depositId: string, status: 'approved' | 'rejected') => void;
    onApproveSale: (saleId: string) => void;
    onRejectSale: (saleId: string) => void;
    businessSettings: BusinessSettingsData;
    setBusinessSettings: (settings: BusinessSettingsData) => void;
    onResetBusiness: () => void;
    handleSaveStockAdjustment: (productId: string, adjustment: Omit<StockAdjustment, 'date' | 'userId' | 'newStockLevel'>, userId: string) => void;
    businessProfile: BusinessProfile | null;
    setBusinessProfile: (profile: BusinessProfile | null) => void;
    onMarkWithdrawalPaid: (userId: string, withdrawalId: string) => void;
    handleConfirmWithdrawalReceived: (userId: string, withdrawalId: string) => void;
    onApproveClientOrder: (saleId: string) => void;
    onRejectClientOrder: (saleId: string) => void;
    handleInitiateCustomPayment: (targetUserId: string, amount: number, description: string) => void;
    handleUpdateCustomPaymentStatus: (targetUserId: string, paymentId: string, status: CustomPayment['status']) => void;
    expenseRequests: ExpenseRequest[];
    handleRequestExpense: (requestData: Omit<ExpenseRequest, 'id' | 'date' | 'userId' | 'status'>) => void;
    onUpdateExpenseRequestStatus: (requestId: string, status: 'approved' | 'rejected') => void;
    isTrialExpired: boolean;
    trialLimits: { canAddProduct: boolean; canAddCustomer: boolean; canAddStaff: boolean; };
    licensingInfo: LicensingInfo | null;
    printerSettings: PrinterSettingsData;
    setPrinterSettings: (settings: PrinterSettingsData) => void;
    ownerSettings: OwnerSettings;
    setOwnerSettings: (settings: OwnerSettings) => void;
    onUpdateCurrentUserProfile: (profileData: { name?: string; avatarUrl?: string; phone?: string; initialInvestment?: number; }) => void;
    children: ReactNode;
}> = (props) => {
    const { 
        isMobile, t, currentUser, handleUserChange, handleLogout, users, sales, customers, products, expenses, deposits,
        lowStockThreshold, setLowStockThreshold, cart, onUpdateCartItem, onProcessSale, onDeleteSale, onClearCart,
        receiptSettings, setProducts, setExpenses, setCustomers, companyValuations, language, setLanguage,
        setReceiptSettings, permissions, setPermissions, onAddCustomer, onSaveUser, onDeleteUser,
        handleRequestWithdrawal, onUpdateWithdrawalStatus, handleRequestDeposit, onUpdateDepositStatus,
        onApproveSale, onRejectSale, businessSettings, setBusinessSettings, onResetBusiness, handleSaveStockAdjustment, businessProfile,
        setBusinessProfile, onMarkWithdrawalPaid, handleConfirmWithdrawalReceived, onApproveClientOrder, onRejectClientOrder,
        handleInitiateCustomPayment, handleUpdateCustomPaymentStatus, expenseRequests, handleRequestExpense, onUpdateExpenseRequestStatus,
        isTrialExpired, trialLimits, licensingInfo, printerSettings, setPrinterSettings, ownerSettings, setOwnerSettings,
        children
    } = props;
    const [isSidebarOpen, setIsSidebarOpen] = useState(false);
    const [isProfileDropdownOpen, setIsProfileDropdownOpen] = useState(false);
    const [isNotificationsOpen, setIsNotificationsOpen] = useState(false);
    const profileDropdownRef = useRef<HTMLDivElement>(null);
    const notificationsRef = useRef<HTMLDivElement>(null);
    const navigate = useNavigate();

    const location = useLocation();
    const title = pageTitles[location.pathname] || businessProfile?.businessName || 'FinTab';
    
    const rootPaths = [
        '/',
        '/dashboard',
        '/assistant',
        '/today',
        '/reports',
        '/shopfront',
        '/directory',
        '/inventory',
        '/receipts',
        '/proforma',
        '/transactions',
        '/commission',
        '/expenses',
        '/expense-requests',
        '/customer-management',
        '/users',
        '/investors',
        '/counter',
        '/chat-help',
        '/settings',
        '/more',
        '/profile',
        '/investor-profile',
    ];
    const isRootPath = rootPaths.includes(location.pathname);
    
    const cartItemCount = cart.reduce((sum, item) => sum + item.quantity, 0);

    // Route protection check
    useEffect(() => {
        if (location.pathname !== '/access-denied' && !hasAccess(currentUser, location.pathname, 'view', permissions)) {
            navigate('/access-denied', { replace: true });
        }
    }, [location.pathname, currentUser, permissions, navigate]);


    useEffect(() => {
        const handleClickOutside = (event: MouseEvent) => {
            if (profileDropdownRef.current && !profileDropdownRef.current.contains(event.target as Node)) {
                setIsProfileDropdownOpen(false);
            }
            if (notificationsRef.current && !notificationsRef.current.contains(event.target as Node)) {
                setIsNotificationsOpen(false);
            }
        };
        document.addEventListener("mousedown", handleClickOutside);
        return () => document.removeEventListener("mousedown", handleClickOutside);
    }, []);

    const CheckIcon = () => (
        <svg className="h-5 w-5 text-primary" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor">
            <path fillRule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clipRule="evenodd" />
        </svg>
    );
    
    // Notification Calculations
    const canManageRequests = useMemo(() => {
        if (!currentUser || !permissions) return false;
        return (
            hasAccess(currentUser, '/expense-requests', 'edit', permissions) ||
            hasAccess(currentUser, '/proforma', 'edit', permissions) ||
            hasAccess(currentUser, '/receipts', 'edit', permissions) ||
            hasAccess(currentUser, '/users', 'edit', permissions) ||
            hasAccess(currentUser, '/transactions', 'edit', permissions)
        );
    }, [currentUser, permissions]);

    const pendingSales = sales.filter(s => s.status === 'pending_approval');
    const pendingWithdrawals = users.flatMap(u => u.withdrawals || []).filter(w => w.status === 'pending');
    const pendingDeposits = deposits.filter(d => d.status === 'pending');
    const pendingClientOrders = sales.filter(s => s.status === 'client_order');
    const pendingExpenseRequests = expenseRequests.filter(er => er.status === 'pending');
    const totalPendingCount = pendingSales.length + pendingWithdrawals.length + pendingDeposits.length + pendingClientOrders.length + pendingExpenseRequests.length;

    const profileLink = currentUser.role === 'Investor' ? '/investor-profile' : '/profile';
    const displayRole = currentUser.role === 'Custom' ? currentUser.customRoleName : currentUser.role;

    return (
        <div className="h-screen flex bg-neutral-light dark:bg-gray-900 font-sans">
            <Sidebar t={t} isOpen={isSidebarOpen} setIsOpen={setIsSidebarOpen} cart={cart} currentUser={currentUser} onLogout={handleLogout} permissions={permissions} businessProfile={businessProfile} ownerSettings={ownerSettings} />
            <div className="flex-1 flex flex-col overflow-hidden">
                {licensingInfo?.licenseType === 'Free' && businessProfile && (
                    <UpgradeBanner businessName={businessProfile.businessName} businessEmail={businessProfile.businessEmail} />
                )}
                 <header className={`bg-white dark:bg-gray-800 dark:border-b dark:border-gray-700 shadow-md flex items-center justify-between flex-shrink-0 ${isMobile ? 'h-16 px-4 sticky top-0 z-10' : 'h-20 px-6'}`}>
                    <div className="flex items-center gap-4">
                        {isMobile ? (
                            isRootPath ? (
                                <button onClick={() => setIsSidebarOpen(true)} className="text-neutral-medium hover:text-primary dark:text-gray-400 dark:hover:text-primary" aria-label="Open menu">
                                    <MenuIcon />
                                </button>
                            ) : (
                                <GoBackButton />
                            )
                        ) : (
                            !isRootPath && <GoBackButton />
                        )}
                        <h1 className={`font-bold text-neutral-dark dark:text-gray-100 ${isMobile ? 'text-xl' : 'text-3xl'}`}>{isMobile ? (businessProfile?.businessName || 'FinTab') : title}</h1>
                    </div>
                    <div className="flex items-center gap-3">
                         {!isMobile && hasAccess(currentUser, '/counter', 'view', permissions) && (
                            <NavLink
                                to="/counter"
                                className="relative p-2 rounded-full text-neutral-medium dark:text-gray-400 hover:bg-neutral-light dark:hover:bg-gray-700 hover:text-neutral-dark dark:hover:text-gray-200 transition-colors duration-200"
                                aria-label={`View Counter (${cartItemCount} items)`}
                            >
                                <CounterIcon />
                                {cartItemCount > 0 && (
                                    <span className="absolute -top-1 -right-1 flex h-5 w-5">
                                        <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-accent-teal opacity-75"></span>
                                        <span className="relative inline-flex rounded-full h-5 w-5 bg-accent-teal text-white text-xs items-center justify-center">{cartItemCount}</span>
                                    </span>
                                )}
                            </NavLink>
                        )}
                         {canManageRequests && (
                            <div className="relative" ref={notificationsRef}>
                                <button
                                    onClick={() => setIsNotificationsOpen(prev => !prev)}
                                    className="relative p-2 rounded-full text-neutral-medium dark:text-gray-400 hover:bg-neutral-light dark:hover:bg-gray-700 hover:text-neutral-dark dark:hover:text-gray-200 transition-colors duration-200"
                                >
                                    <BellIcon />
                                    {totalPendingCount > 0 && (
                                        <span className="absolute -top-1 -right-1 flex h-5 w-5">
                                            <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-error opacity-75"></span>
                                            <span className="relative inline-flex rounded-full h-5 w-5 bg-error text-white text-xs items-center justify-center">{totalPendingCount}</span>
                                        </span>
                                    )}
                                </button>
                                {isNotificationsOpen && (
                                    <div className="absolute right-0 mt-2 w-80 bg-white dark:bg-gray-800 rounded-xl shadow-xl z-20 border border-neutral-light dark:border-gray-700">
                                        <div className="p-4 font-semibold border-b border-neutral-light dark:border-gray-700 text-neutral-dark dark:text-gray-200">Notifications</div>
                                        <div className="py-2 max-h-80 overflow-y-auto">
                                            {totalPendingCount === 0 ? (
                                                <p className="px-4 py-3 text-sm text-neutral-medium dark:text-gray-400">No new notifications.</p>
                                            ) : (
                                                <>
                                                    {pendingExpenseRequests.length > 0 && (
                                                        <NavLink to="/dashboard" state={{ openTab: 'requests', openSubTab: 'expenseRequests' }} onClick={() => setIsNotificationsOpen(false)} className="block px-4 py-3 text-sm text-neutral-dark dark:text-gray-200 hover:bg-neutral-light dark:hover:bg-gray-700 rounded-md mx-2">
                                                            <p className="font-semibold">{pendingExpenseRequests.length} Expense Request(s)</p>
                                                            <p className="text-xs text-neutral-medium dark:text-gray-500">Staff members have submitted expenses for approval.</p>
                                                        </NavLink>
                                                    )}
                                                    {pendingClientOrders.length > 0 && (
                                                        <NavLink to="/dashboard" state={{ openTab: 'requests', openSubTab: 'clientOrders' }} onClick={() => setIsNotificationsOpen(false)} className="block px-4 py-3 text-sm text-neutral-dark dark:text-gray-200 hover:bg-neutral-light dark:hover:bg-gray-700 rounded-md mx-2">
                                                            <p className="font-semibold">{pendingClientOrders.length} New Client Order(s)</p>
                                                            <p className="text-xs text-neutral-medium dark:text-gray-500">Orders placed from your public shopfront.</p>
                                                        </NavLink>
                                                    )}
                                                    {pendingSales.length > 0 && (
                                                        <NavLink to="/dashboard" state={{ openTab: 'requests', openSubTab: 'saleApprovals' }} onClick={() => setIsNotificationsOpen(false)} className="block px-4 py-3 text-sm text-neutral-dark dark:text-gray-200 hover:bg-neutral-light dark:hover:bg-gray-700 rounded-md mx-2">
                                                            <p className="font-semibold">{pendingSales.length} Sale Approval(s) Pending</p>
                                                            <p className="text-xs text-neutral-medium dark:text-gray-500">Bank transfers waiting for confirmation.</p>
                                                        </NavLink>
                                                    )}
                                                    {pendingWithdrawals.length > 0 && (
                                                        <NavLink to="/dashboard" state={{ openTab: 'requests', openSubTab: 'withdrawals' }} onClick={() => setIsNotificationsOpen(false)} className="block px-4 py-3 text-sm text-neutral-dark dark:text-gray-200 hover:bg-neutral-light dark:hover:bg-gray-700 rounded-md mx-2">
                                                            <p className="font-semibold">{pendingWithdrawals.length} Withdrawal Request(s)</p>
                                                            <p className="text-xs text-neutral-medium dark:text-gray-500">Staff members have requested payouts.</p>
                                                        </NavLink>
                                                    )}
                                                    {pendingDeposits.length > 0 && (
                                                        <NavLink to="/dashboard" state={{ openTab: 'requests', openSubTab: 'deposits' }} onClick={() => setIsNotificationsOpen(false)} className="block px-4 py-3 text-sm text-neutral-dark dark:text-gray-200 hover:bg-neutral-light dark:hover:bg-gray-700 rounded-md mx-2">
                                                             <p className="font-semibold">{pendingDeposits.length} Deposit Request(s)</p>
                                                            <p className="text-xs text-neutral-medium dark:text-gray-500">Cashiers have requested to deposit cash.</p>
                                                        </NavLink>
                                                    )}
                                                </>
                                            )}
                                        </div>
                                    </div>
                                )}
                            </div>
                        )}
                         <div className="relative" ref={profileDropdownRef}>
                            <button 
                                onClick={() => setIsProfileDropdownOpen(prev => !prev)}
                                className={isMobile ? "text-right" : "flex items-center gap-3 p-2 rounded-xl hover:bg-neutral-light dark:hover:bg-gray-700 transition-colors duration-200"}>
                                <img src={currentUser.avatarUrl} alt="My Profile" className="h-10 w-10 rounded-full object-cover" />
                                {!isMobile && (
                                    <div className="text-left">
                                        <p className="font-semibold text-neutral-dark dark:text-gray-200">{currentUser.name}</p>
                                        <p className="text-xs text-neutral-medium dark:text-gray-400">{displayRole}</p>
                                    </div>
                                )}
                                {!isMobile && <ChevronDownIcon />}
                            </button>
                            {isProfileDropdownOpen && (
                                <div className="absolute right-0 mt-2 w-48 bg-white dark:bg-gray-800 rounded-xl shadow-xl z-20 border border-neutral-light dark:border-gray-700 py-2">
                                    <NavLink to={profileLink} onClick={() => setIsProfileDropdownOpen(false)} className="block px-4 py-2 text-sm text-neutral-dark dark:text-gray-200 hover:bg-neutral-light dark:hover:bg-gray-700">My Profile</NavLink>
                                    <button onClick={handleLogout} className="w-full text-left block px-4 py-2 text-sm text-error hover:bg-red-50 dark:hover:bg-red-900/20">Logout</button>
                                </div>
                            )}
                        </div>
                    </div>
                </header>
                <main className="flex-1 overflow-y-auto p-4 pb-20 md:p-6 md:pb-6">
                    {children}
                </main>
                {isMobile && <BottomNavBar t={t} cart={cart} currentUser={currentUser} permissions={permissions} />}
            </div>
        </div>
    );
};

// --- NEW Business-aware LocalStorage Helper Functions ---
const getBusinessStoredItem = <T,>(businessId: string, key: string, defaultValue: T): T => {
    if (!businessId) return defaultValue;
    return getStoredItem(`fintab_${businessId}_${key}`, defaultValue);
};

const setBusinessStoredItem = (businessId: string, key: string, value: any): void => {
    if (!businessId) return;
    setStoredItem(`fintab_${businessId}_${key}`, value);
};


const App: React.FC = () => {
    const { width } = useWindowSize();
    const isMobile = width < 768;
    const navigate = useNavigate();

    // --- Multi-Business State Management ---
    const [businesses, setBusinesses] = useState<AdminBusinessData[]>(() => getStoredItem('fintab_businesses_registry', []));
    const [currentBusinessId, setCurrentBusinessId] = useState<string | null>(() => getStoredItem('fintab_currentBusinessId', null));
    const isInitialSetupDone = businesses.length > 0;

    // --- Global (non-business specific) State ---
    const [theme, setTheme] = useState<'light' | 'dark'>(() => getStoredItem('fintab_theme', 'light'));
    const [currentUser, setCurrentUser] = useState<User | null>(() => getStoredItem('fintab_current_user', null));

    // --- Business-Specific State (loaded dynamically) ---
    const [language, setLanguage] = useState('en');
    const [products, setProducts] = useState<Product[]>([]);
    const [customers, setCustomers] = useState<Customer[]>([]);
    const [users, setUsers] = useState<User[]>([]);
    const [sales, setSales] = useState<Sale[]>([]);
    const [expenses, setExpenses] = useState<Expense[]>([]);
    const [expenseRequests, setExpenseRequests] = useState<ExpenseRequest[]>([]);
    const [deposits, setDeposits] = useState<Deposit[]>([]);
    const [cart, setCart] = useState<CartItem[]>([]);
    const [companyValuations, setCompanyValuations] = useState<CompanyValuation[]>([]);
    const [receiptSettings, setReceiptSettings] = useState<ReceiptSettingsData>(DEFAULT_RECEIPT_SETTINGS);
    const [businessSettings, setBusinessSettings] = useState<BusinessSettingsData>(DEFAULT_BUSINESS_SETTINGS);
    const [ownerSettings, setOwnerSettings] = useState<OwnerSettings>(DEFAULT_OWNER_SETTINGS);
    const [printerSettings, setPrinterSettings] = useState<PrinterSettingsData>(DEFAULT_PRINTER_SETTINGS);
    const [businessProfile, setBusinessProfile] = useState<BusinessProfile | null>(null);
    const [licensingInfo, setLicensingInfo] = useState<LicensingInfo | null>(null);
    const [permissions, setPermissions] = useState<AppPermissions>(DEFAULT_PERMISSIONS);
    const [lowStockThreshold, setLowStockThreshold] = useState(5);
    
    const t = useCallback((key: string) => {
        return translations[language as keyof typeof translations]?.[key as any] || key;
    }, [language]);

    // NEW: Effect to load all business data when currentBusinessId changes
    useEffect(() => {
        if (currentBusinessId) {
            const businessData = businesses.find(b => b.id === currentBusinessId);
            if (businessData) {
                setBusinessProfile(businessData.profile);
                setLicensingInfo(businessData.licensingInfo);
            }
            // Load all data from namespaced storage
            setLanguage(getBusinessStoredItem(currentBusinessId, 'language', 'en'));
            setProducts(getBusinessStoredItem(currentBusinessId, 'products', []));
            setCustomers(getBusinessStoredItem(currentBusinessId, 'customers', []));
            setUsers(getBusinessStoredItem(currentBusinessId, 'users', []));
            setSales(getBusinessStoredItem(currentBusinessId, 'sales', []));
            setExpenses(getBusinessStoredItem(currentBusinessId, 'expenses', []));
            setExpenseRequests(getBusinessStoredItem(currentBusinessId, 'expense_requests', []));
            setDeposits(getBusinessStoredItem(currentBusinessId, 'deposits', []));
            setCart(getBusinessStoredItem(currentBusinessId, 'cart', []));
            setCompanyValuations(getBusinessStoredItem(currentBusinessId, 'valuations', []));
            setReceiptSettings(getBusinessStoredItem(currentBusinessId, 'receipt_settings', DEFAULT_RECEIPT_SETTINGS));
            setBusinessSettings(getBusinessStoredItem(currentBusinessId, 'business_settings', DEFAULT_BUSINESS_SETTINGS));
            setOwnerSettings(getBusinessStoredItem(currentBusinessId, 'owner_settings', DEFAULT_OWNER_SETTINGS));
            setPrinterSettings(getBusinessStoredItem(currentBusinessId, 'printer_settings', DEFAULT_PRINTER_SETTINGS));
            setPermissions(getBusinessStoredItem(currentBusinessId, 'permissions', DEFAULT_PERMISSIONS));
            setLowStockThreshold(getBusinessStoredItem(currentBusinessId, 'low_stock_threshold', 5));
        } else {
            // Clear all data on logout
            setProducts([]); setCustomers([]); setUsers([]); setSales([]); setExpenses([]);
            setExpenseRequests([]); setDeposits([]); setCart([]); setCompanyValuations([]);
            setReceiptSettings(DEFAULT_RECEIPT_SETTINGS); setBusinessSettings(DEFAULT_BUSINESS_SETTINGS);
            setOwnerSettings(DEFAULT_OWNER_SETTINGS); setPrinterSettings(DEFAULT_PRINTER_SETTINGS);
            setBusinessProfile(null); setLicensingInfo(null); setPermissions(DEFAULT_PERMISSIONS);
            setLowStockThreshold(5); setLanguage('en');
        }
    }, [currentBusinessId, businesses]);

    // --- Data Persistence Effects (now business-aware) ---
    useEffect(() => { setStoredItem('fintab_businesses_registry', businesses); }, [businesses]);
    useEffect(() => { setStoredItem('fintab_currentBusinessId', currentBusinessId); }, [currentBusinessId]);
    useEffect(() => { setStoredItem('fintab_current_user', currentUser); }, [currentUser]);
    useEffect(() => { setStoredItem('fintab_theme', theme); }, [theme]);
    // Namespaced useEffects
    useEffect(() => { if (currentBusinessId) setBusinessStoredItem(currentBusinessId, 'language', language); }, [language, currentBusinessId]);
    useEffect(() => { if (currentBusinessId) setBusinessStoredItem(currentBusinessId, 'products', products); }, [products, currentBusinessId]);
    useEffect(() => { if (currentBusinessId) setBusinessStoredItem(currentBusinessId, 'customers', customers); }, [customers, currentBusinessId]);
    useEffect(() => { if (currentBusinessId) setBusinessStoredItem(currentBusinessId, 'users', users); }, [users, currentBusinessId]);
    useEffect(() => { if (currentBusinessId) setBusinessStoredItem(currentBusinessId, 'sales', sales); }, [sales, currentBusinessId]);
    useEffect(() => { if (currentBusinessId) setBusinessStoredItem(currentBusinessId, 'expenses', expenses); }, [expenses, currentBusinessId]);
    useEffect(() => { if (currentBusinessId) setBusinessStoredItem(currentBusinessId, 'expense_requests', expenseRequests); }, [expenseRequests, currentBusinessId]);
    useEffect(() => { if (currentBusinessId) setBusinessStoredItem(currentBusinessId, 'deposits', deposits); }, [deposits, currentBusinessId]);
    useEffect(() => { if (currentBusinessId) setBusinessStoredItem(currentBusinessId, 'cart', cart); }, [cart, currentBusinessId]);
    useEffect(() => { if (currentBusinessId) setBusinessStoredItem(currentBusinessId, 'receipt_settings', receiptSettings); }, [receiptSettings, currentBusinessId]);
    useEffect(() => { if (currentBusinessId) setBusinessStoredItem(currentBusinessId, 'business_settings', businessSettings); }, [businessSettings, currentBusinessId]);
    useEffect(() => { if (currentBusinessId) setBusinessStoredItem(currentBusinessId, 'owner_settings', ownerSettings); }, [ownerSettings, currentBusinessId]);
    useEffect(() => { if (currentBusinessId) setBusinessStoredItem(currentBusinessId, 'printer_settings', printerSettings); }, [printerSettings, currentBusinessId]);
    useEffect(() => { if (currentBusinessId) setBusinessStoredItem(currentBusinessId, 'valuations', companyValuations); }, [companyValuations, currentBusinessId]);
    useEffect(() => { if (currentBusinessId) setBusinessStoredItem(currentBusinessId, 'permissions', permissions); }, [permissions, currentBusinessId]);
    useEffect(() => { if (currentBusinessId) setBusinessStoredItem(currentBusinessId, 'low_stock_threshold', lowStockThreshold); }, [lowStockThreshold, currentBusinessId]);

    // Keyboard handling for mobile devices
    useEffect(() => {
        const handleFocus = (event: FocusEvent) => {
            const target = event.target as HTMLElement;
            if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.tagName === 'SELECT') {
                setTimeout(() => { target.scrollIntoView({ behavior: 'smooth', block: 'center' }); }, 300);
            }
        };
        window.addEventListener('focusin', handleFocus);
        return () => { window.removeEventListener('focusin', handleFocus); };
    }, []);

    // This effect applies the dark class to the HTML element
    useEffect(() => {
        const root = window.document.documentElement;
        if (theme === 'dark') {
            root.classList.add('dark');
        } else {
            root.classList.remove('dark');
        }
    }, [theme]);

    const handleLogout = useCallback(() => {
        setCurrentUser(null);
        setCurrentBusinessId(null);
        navigate('/login/portal');
    }, [navigate]);

    // This effect synchronizes the `currentUser` state with the main `users` list.
    useEffect(() => {
        if (currentUser && users.length > 0) {
            const updatedUserInList = users.find(u => u.id === currentUser.id);
            if (!updatedUserInList) {
                handleLogout();
                return;
            }
            if (JSON.stringify(updatedUserInList) !== JSON.stringify(currentUser)) {
                setCurrentUser(updatedUserInList);
            }
        }
    }, [users, currentUser, handleLogout]);
    
    // --- Licensing and Trial Logic ---
    const isTrialExpired = useMemo(() => {
        if (!licensingInfo || licensingInfo.licenseType === 'Premium') return false;
        if (licensingInfo.licenseType === 'Free') return true;
        const endDate = new Date(licensingInfo.trialEndDate);
        return new Date() > endDate;
    }, [licensingInfo]);

    // Effect to automatically switch to 'Free' plan when trial expires.
    useEffect(() => {
        if (licensingInfo?.licenseType === 'Trial' && isTrialExpired) {
            const newLicensingInfo = { ...licensingInfo, licenseType: 'Free' as const };
            setLicensingInfo(newLicensingInfo);
            // Also update the master business registry
            setBusinesses(prev => prev.map(b => b.id === currentBusinessId ? { ...b, licensingInfo: newLicensingInfo } : b));
        }
    }, [isTrialExpired, licensingInfo, currentBusinessId]);

    const trialLimits = useMemo(() => {
        const hasLimits = licensingInfo?.licenseType === 'Trial' || licensingInfo?.licenseType === 'Free';
        if (!hasLimits) {
            return { canAddProduct: true, canAddCustomer: true, canAddStaff: true };
        }
        const canAddProduct = products.length < 100;
        const canAddCustomer = customers.length < 100;
        const staffCount = users.filter(u => u.role !== 'Investor' && u.role !== 'Owner').length;
        const canAddStaff = staffCount < 3;
        
        return { canAddProduct, canAddCustomer, canAddStaff };
    }, [licensingInfo, products.length, customers.length, users]);

    // REFACTORED: `handleLogin` to search across all businesses
    const handleLogin = useCallback((email: string, password_provided: string) => {
        for (const business of businesses) {
            const businessUsers = getBusinessStoredItem<User[]>(business.id, 'users', []);
            const user = businessUsers.find(u => u.email.toLowerCase() === email.toLowerCase() && u.password === password_provided);
            if (user) {
                setCurrentBusinessId(business.id);
                setCurrentUser(user);
                return true;
            }
        }
        return false;
    }, [businesses]);

    // --- CORE BUSINESS LOGIC (mostly unchanged, now operates on loaded state) ---
    const handleUpdateCartItem = useCallback((product: Product, variant: ProductVariant | undefined, quantity: number) => {
        setCart(prevCart => {
            const cartItemId = variant ? variant.id : product.id;
            const existingItemIndex = prevCart.findIndex(item => (item.variant ? item.variant.id : item.product.id) === cartItemId);

            let availableStock: number;
            if (variant) {
                availableStock = variant.stock;
            } else {
                availableStock = product.stock;
            }

            if (quantity <= 0) {
                if (existingItemIndex > -1) {
                    const newCart = [...prevCart];
                    newCart.splice(existingItemIndex, 1);
                    return newCart;
                }
                return prevCart;
            }

            const newQuantity = Math.min(quantity, availableStock);

            if (existingItemIndex > -1) {
                const newCart = [...prevCart];
                newCart[existingItemIndex] = { ...newCart[existingItemIndex], quantity: newQuantity };
                return newCart;
            } else {
                if (newQuantity > 0) {
                    return [...prevCart, { product, variant, quantity: newQuantity }];
                }
                return prevCart;
            }
        });
    }, []);
    
    const onProcessSale = useCallback((sale: Sale) => {
        const seller = users.find(u => u.id === sale.userId);
        if (seller && seller.role === 'Owner' && !ownerSettings.commissionTrackingEnabled) {
            sale.commission = 0;
        }

        if (sale.status === 'completed') {
            setProducts(prevProducts => {
                const newProducts = JSON.parse(JSON.stringify(prevProducts)); // Deep copy
                sale.items.forEach(item => {
                    const productIndex = newProducts.findIndex((p: Product) => p.id === item.product.id);
                    if (productIndex !== -1) {
                        const productToUpdate = newProducts[productIndex];
                        if (item.variant) {
                            const variantIndex = productToUpdate.variants?.findIndex((v: ProductVariant) => v.id === item.variant!.id);
                            if (variantIndex !== -1 && productToUpdate.variants) {
                                productToUpdate.variants[variantIndex].stock -= item.quantity;
                            }
                            productToUpdate.stock = productToUpdate.variants?.reduce((sum: number, v: ProductVariant) => sum + v.stock, 0) || 0;
                        } else {
                            productToUpdate.stock -= item.quantity;
                        }
                        newProducts[productIndex] = productToUpdate;
                    }
                });
                return newProducts;
            });
        }
        
        setCustomers(prevCustomers => prevCustomers.map(c => 
            c.id === sale.customerId 
            ? {...c, purchaseHistory: [sale, ...c.purchaseHistory]}
            : c
        ));

        setSales(prevSales => [sale, ...prevSales]);
        setCart([]);
    }, [users, ownerSettings]);

    const onDeleteSale = useCallback((saleId: string) => {
        setSales(prevSales => {
            const saleToDelete = prevSales.find(s => s.id === saleId);
            if (saleToDelete && saleToDelete.status === 'completed') {
                setProducts(prevProducts => {
                    const newProducts = JSON.parse(JSON.stringify(prevProducts));
                    saleToDelete.items.forEach(item => {
                        const productIndex = newProducts.findIndex((p: Product) => p.id === item.product.id);
                        if (productIndex !== -1) {
                           const productToUpdate = newProducts[productIndex];
                           if (item.variant) {
                                const variantIndex = productToUpdate.variants?.findIndex((v: ProductVariant) => v.id === item.variant!.id);
                                if (variantIndex !== -1 && productToUpdate.variants) {
                                    productToUpdate.variants[variantIndex].stock += item.quantity;
                                }
                                productToUpdate.stock = productToUpdate.variants?.reduce((sum: number, v: ProductVariant) => sum + v.stock, 0) || 0;
                           } else {
                               productToUpdate.stock += item.quantity;
                           }
                           newProducts[productIndex] = productToUpdate;
                        }
                    });
                    return newProducts;
                });
            }
            return prevSales.filter(s => s.id !== saleId);
        });
    }, [setProducts]);

    const handleClearCart = useCallback(() => setCart([]), []);
    const onAddCustomer = useCallback((customerData: Omit<Customer, 'id' | 'joinDate' | 'purchaseHistory'>): Customer => {
        const newCustomer: Customer = { ...customerData, id: `cust-${Date.now()}`, joinDate: new Date().toISOString(), purchaseHistory: [] };
        setCustomers(prev => [newCustomer, ...prev]);
        return newCustomer;
    }, []);
    const onSaveUser = useCallback((userData: Omit<User, 'id' | 'avatarUrl'>, isEditing: boolean, existingUserId?: string): User | void => {
        if(isEditing && existingUserId) {
            setUsers(prev => prev.map(u => u.id === existingUserId ? {...u, ...userData} : u));
        } else {
            const newUser: User = { ...userData, id: `user-${Date.now()}`, avatarUrl: `https://i.pravatar.cc/150?u=${Date.now()}`, status: 'Invited' };
            setUsers(prev => [...prev, newUser]);
            return newUser;
        }
    }, []);
    const onDeleteUser = useCallback((userId: string) => setUsers(prev => prev.filter(u => u.id !== userId)), []);
    const handleUpdateCurrentUserProfile = useCallback((profileData: { name?: string; avatarUrl?: string; phone?: string; initialInvestment?: number; }) => {
        if (!currentUser) return;
        setUsers(prevUsers => prevUsers.map(u => u.id === currentUser.id ? { ...u, ...profileData } : u ));
    }, [currentUser]);
    const handleRequestWithdrawal = useCallback((userId: string, amount: number, source: 'commission' | 'investment') => {
        setUsers(prev => prev.map(u => {
            if(u.id === userId) {
                const newWithdrawal: Withdrawal = { id: `wd-${Date.now()}`, date: new Date().toISOString(), amount, status: 'pending', source };
                return {...u, withdrawals: [...(u.withdrawals || []), newWithdrawal]};
            }
            return u;
        }));
    }, []);
    const handleConfirmWithdrawalReceived = useCallback((userId: string, withdrawalId: string) => {
        const user = users.find(u => u.id === userId);
        const withdrawal = user?.withdrawals?.find(w => w.id === withdrawalId);
        if (user && withdrawal && withdrawal.status !== 'completed') {
            const newExpense: Expense = { id: `exp-wd-${withdrawalId}`, date: new Date().toISOString(), category: user.role === 'Investor' ? 'Investor Payout' : 'Staff Payout', description: `Payout to ${user.name} (Ref: ${withdrawalId.slice(-6)})`, amount: withdrawal.amount };
            setExpenses(prev => [newExpense, ...prev.filter(e => e.id !== newExpense.id)]);
        }
        setUsers(prev => prev.map(u => u.id === userId ? {...u, withdrawals: (u.withdrawals || []).map(w => w.id === withdrawalId ? {...w, status: 'completed'} : w)} : u));
    }, [users, setExpenses]);
    const handleRequestDeposit = useCallback((amount: number, description: string) => {
        if(!currentUser) return;
        const newDeposit: Deposit = { id: `dep-${Date.now()}`, date: new Date().toISOString(), amount, description, userId: currentUser.id, status: 'pending' };
        setDeposits(prev => [newDeposit, ...prev]);
    }, [currentUser]);
    const handleSaveStockAdjustment = useCallback((productId: string, adjustment: Omit<StockAdjustment, 'date' | 'userId' | 'newStockLevel'>, userId: string) => {
        setProducts(prev => prev.map(p => {
            if (p.id === productId) {
                const newStockLevel = adjustment.type === 'add' ? p.stock + adjustment.quantity : p.stock - adjustment.quantity;
                const newHistoryEntry: StockAdjustment = { ...adjustment, date: new Date().toISOString(), userId, newStockLevel };
                return { ...p, stock: newStockLevel, stockHistory: [newHistoryEntry, ...(p.stockHistory || [])] }
            }
            return p;
        }));
    }, []);
    const onResetBusiness = useCallback(() => {
        if(window.confirm("Are you sure? This will delete all data for the current business.")) {
            if (currentBusinessId) {
                // Find all keys for this business and remove them
                Object.keys(localStorage).forEach(key => {
                    if (key.startsWith(`fintab_${currentBusinessId}`)) {
                        localStorage.removeItem(key);
                    }
                });
                // Reload to clear state
                window.location.reload();
            }
        }
    }, [currentBusinessId]);
    const handleInitiateCustomPayment = useCallback((targetUserId: string, amount: number, description: string) => {
        if (!currentUser) return;
        setUsers(prev => prev.map(u => {
            if (u.id === targetUserId) {
                const newPayment: CustomPayment = { id: `cp-${Date.now()}`, dateInitiated: new Date().toISOString(), amount, description, status: 'pending_user_approval', initiatedBy: currentUser.id };
                return { ...u, customPayments: [...(u.customPayments || []), newPayment] };
            }
            return u;
        }));
    }, [currentUser]);
    const handleUpdateCustomPaymentStatus = useCallback((targetUserId: string, paymentId: string, status: CustomPayment['status']) => {
        if (status === 'completed') {
            const user = users.find(u => u.id === targetUserId);
            const payment = user?.customPayments?.find(p => p.id === paymentId);
            if (user && payment && payment.status !== 'completed') {
                const newExpense: Expense = { id: `exp-cp-${paymentId}`, date: new Date().toISOString(), category: 'Staff Payment', description: `Custom Payment: ${payment.description} to ${user.name} (Ref: ${paymentId.slice(-6)})`, amount: payment.amount };
                setExpenses(prev => [newExpense, ...prev.filter(e => e.id !== newExpense.id)]);
            }
        }
        setUsers(prev => prev.map(u => {
            if (u.id === targetUserId) {
                return { ...u, customPayments: (u.customPayments || []).map(p => p.id === paymentId ? { ...p, status } : p) };
            }
            return u;
        }));
    }, [users, setExpenses]);
    const handleRequestExpense = useCallback((requestData: Omit<ExpenseRequest, 'id' | 'date' | 'userId' | 'status'>) => {
        if (!currentUser) return;
        const newRequest: ExpenseRequest = { ...requestData, id: `expreq-${Date.now()}`, date: new Date().toISOString(), userId: currentUser.id, status: 'pending' };
        setExpenseRequests(prev => [newRequest, ...prev]);
    }, [currentUser]);
    const onUpdateExpenseRequestStatus = useCallback((requestId: string, status: 'approved' | 'rejected') => {
        if (!currentUser) return;
        setExpenseRequests(prev => prev.map(req => {
            if (req.id === requestId) {
                if (status === 'approved' && req.status === 'pending') {
                    const requester = users.find(u => u.id === req.userId);
                    const newExpense: Expense = { id: `exp-req-${req.id}`, date: new Date().toISOString(), category: req.category, description: `Approved request from ${requester?.name || 'user'}: ${req.description}`, amount: req.amount };
                    setExpenses(prevExp => [newExpense, ...prevExp]);
                }
                return { ...req, status, approvedBy: currentUser.id };
            }
            return req;
        }));
    }, [currentUser, users, setExpenses]);
    const onApproveSale = useCallback((saleId: string) => {
        setSales(prevSales => {
            const saleToApprove = prevSales.find(s => s.id === saleId);
            if (!saleToApprove) return prevSales;
            setProducts(prevProducts => {
                const newProducts = JSON.parse(JSON.stringify(prevProducts));
                saleToApprove.items.forEach(item => {
                    const productIndex = newProducts.findIndex((p: Product) => p.id === item.product.id);
                    if (productIndex !== -1) {
                        const productToUpdate = newProducts[productIndex];
                        if (item.variant) {
                            const variantIndex = productToUpdate.variants?.findIndex((v: ProductVariant) => v.id === item.variant!.id);
                            if (variantIndex !== -1 && productToUpdate.variants) {
                                productToUpdate.variants[variantIndex].stock -= item.quantity;
                            }
                            productToUpdate.stock = productToUpdate.variants?.reduce((sum: number, v: ProductVariant) => sum + v.stock, 0) || 0;
                        } else {
                            productToUpdate.stock -= item.quantity;
                        }
                        newProducts[productIndex] = productToUpdate;
                    }
                });
                return newProducts;
            });
            return prevSales.map(s => s.id === saleId ? { ...s, status: 'completed' } : s);
        });
    }, []);
    const onRejectSale = useCallback((saleId: string) => setSales(prev => prev.map(s => s.id === saleId ? { ...s, status: 'rejected' } : s)), []);
    const onApproveClientOrder = useCallback((saleId: string) => setSales(prev => prev.map(s => s.id === saleId ? { ...s, status: 'proforma' } : s)), []);
    const onRejectClientOrder = useCallback((saleId: string) => setSales(prev => prev.map(s => s.id === saleId ? { ...s, status: 'rejected' } : s)), []);
    const onUpdateWithdrawalStatus = useCallback((userId: string, withdrawalId: string, status: 'approved' | 'rejected') => {
        setUsers(prev => prev.map(u => u.id === userId ? { ...u, withdrawals: (u.withdrawals || []).map(w => w.id === withdrawalId ? { ...w, status } : w) } : u));
    }, []);
    const onMarkWithdrawalPaid = useCallback((userId: string, withdrawalId: string) => {
        setUsers(prev => prev.map(u => u.id === userId ? { ...u, withdrawals: (u.withdrawals || []).map(w => w.id === withdrawalId ? { ...w, status: 'paid' } : w) } : u));
    }, []);
    const onUpdateDepositStatus = useCallback((depositId: string, status: 'approved' | 'rejected') => setDeposits(prev => prev.map(d => d.id === depositId ? { ...d, status } : d)), []);

    // REFACTORED: Onboarding and Setup handlers
    const handleOnboardingFinish = useCallback((data: any) => {
        const newBusinessId = `biz-${Date.now()}`;
        const ownerUser: User = { id: 'user-1', name: data.owner.fullName, email: data.owner.email, password: data.owner.password, role: 'Owner', type: 'commission', avatarUrl: 'https://i.pravatar.cc/150?u=owner', status: 'Active', initialInvestment: 10000, investmentDate: new Date().toISOString() };
        const now = new Date();
        const trialEndDate = new Date(now.getTime() + 90 * 24 * 60 * 60 * 1000);
        const newLicensingInfo: LicensingInfo = { licenseType: 'Trial', enrollmentDate: now.toISOString(), trialEndDate: trialEndDate.toISOString() };
        const newBusinessProfile: BusinessProfile = { ...data.business, id: newBusinessId };

        const newBusinessEntry: AdminBusinessData = {
            id: newBusinessId,
            profile: newBusinessProfile,
            licensingInfo: newLicensingInfo,
            settings: { acceptRemoteOrders: true },
            owner: { name: data.owner.fullName, email: data.owner.email },
            stats: { totalRevenue: 0, salesCount: 0, userCount: 1, joinedDate: new Date().toISOString(), status: 'Active' },
        };
        
        // Initialize storage for the new business
        setBusinessStoredItem(newBusinessId, 'users', [ownerUser]);
        setBusinessStoredItem(newBusinessId, 'products', []);
        setBusinessStoredItem(newBusinessId, 'customers', []);
        setBusinessStoredItem(newBusinessId, 'sales', []);
        setBusinessStoredItem(newBusinessId, 'expenses', []);
        setBusinessStoredItem(newBusinessId, 'deposits', []);
        setBusinessStoredItem(newBusinessId, 'business_settings', DEFAULT_BUSINESS_SETTINGS);
        setBusinessStoredItem(newBusinessId, 'receipt_settings', { ...DEFAULT_RECEIPT_SETTINGS, businessName: newBusinessProfile.businessName });
        setBusinessStoredItem(newBusinessId, 'permissions', DEFAULT_PERMISSIONS);
        setBusinessStoredItem(newBusinessId, 'owner_settings', DEFAULT_OWNER_SETTINGS);

        setBusinesses(prev => [...prev, newBusinessEntry]);
        setCurrentBusinessId(newBusinessId);
        setCurrentUser(ownerUser);
        navigate('/');
    }, [navigate]);
    
    const handleSwitchToLogin = useCallback(() => {
        navigate('/login/portal');
    }, [navigate]);

    const handleSkipSetup = useCallback(() => {
        const demoBusiness = DUMMY_ADMIN_BUSINESS_DATA[0];
        const demoBusinessExists = businesses.some(b => b.id === demoBusiness.id);
        if (!demoBusinessExists) {
            setBusinessStoredItem(demoBusiness.id, 'users', DUMMY_USERS);
            setBusinessStoredItem(demoBusiness.id, 'products', DUMMY_PRODUCTS);
            setBusinessStoredItem(demoBusiness.id, 'customers', DUMMY_CUSTOMERS);
            setBusinessStoredItem(demoBusiness.id, 'sales', DUMMY_SALES);
            setBusinessStoredItem(demoBusiness.id, 'expenses', DUMMY_EXPENSES);
            setBusinessStoredItem(demoBusiness.id, 'deposits', DUMMY_DEPOSITS);
            setBusinessStoredItem(demoBusiness.id, 'valuations', COMPANY_VALUATION_HISTORY);
            setBusinessStoredItem(demoBusiness.id, 'receipt_settings', DEFAULT_RECEIPT_SETTINGS);
            setBusinessStoredItem(demoBusiness.id, 'business_settings', { ...DEFAULT_BUSINESS_SETTINGS, ...demoBusiness.settings });
            setBusinessStoredItem(demoBusiness.id, 'permissions', DEFAULT_PERMISSIONS);
            setBusinessStoredItem(demoBusiness.id, 'owner_settings', DEFAULT_OWNER_SETTINGS);
            setBusinesses([demoBusiness]);
        }
        setCurrentUser(null);
        setCurrentBusinessId(null);
        navigate('/login/portal');
    }, [navigate, businesses]);

    if (!isInitialSetupDone) {
        return (
            <Routes>
                <Route path="/setup" element={<Onboarding onFinish={handleOnboardingFinish} onSwitchToLogin={handleSwitchToLogin} onSkipSetup={handleSkipSetup} />} />
                <Route path="*" element={<Navigate to="/setup" />} />
            </Routes>
        );
    }
    
    if (!currentUser) {
        return (
            <Routes>
                <Route path="/login" element={<Login onLogin={handleLogin} />} />
                <Route path="/login/portal" element={<LoginPortal hasBusinesses={businesses.length > 0} />} />
                { DUMMY_USERS.find(u => u.role === 'Super Admin') && (
                    <Route path="/login/admin" element={<AdminDashboard currentUser={DUMMY_USERS.find(u => u.role === 'Super Admin')!} onLogout={() => { alert('Logged out'); setCurrentUser(null); setCurrentBusinessId(null); navigate('/login/portal'); }} />} />
                )}
                <Route path="/public-shopfront/:businessId" element={<PublicStorefront />} />
                <Route path="/directory" element={<Directory />} />
                <Route path="/setup" element={<Onboarding onFinish={handleOnboardingFinish} onSwitchToLogin={handleSwitchToLogin} onSkipSetup={handleSkipSetup} />} />
                <Route path="*" element={<Navigate to={isInitialSetupDone ? "/login/portal" : "/setup"} />} />
            </Routes>
        );
    }

    return (
        <MainLayout
            isMobile={isMobile}
            t={t}
            currentUser={currentUser}
            handleUserChange={setCurrentUser}
            handleLogout={handleLogout}
            users={users}
            sales={sales}
            customers={customers}
            products={products}
            expenses={expenses}
            deposits={deposits}
            lowStockThreshold={lowStockThreshold}
            setLowStockThreshold={setLowStockThreshold}
            cart={cart}
            onUpdateCartItem={handleUpdateCartItem}
            onProcessSale={onProcessSale}
            onDeleteSale={onDeleteSale}
            onClearCart={handleClearCart}
            receiptSettings={receiptSettings}
            setProducts={setProducts}
            setExpenses={setExpenses}
            setCustomers={setCustomers}
            companyValuations={companyValuations}
            language={language}
            setLanguage={setLanguage}
            setReceiptSettings={setReceiptSettings}
            permissions={permissions}
            setPermissions={setPermissions}
            onAddCustomer={onAddCustomer}
            onSaveUser={onSaveUser}
            onDeleteUser={onDeleteUser}
            handleRequestWithdrawal={handleRequestWithdrawal}
            onUpdateWithdrawalStatus={onUpdateWithdrawalStatus}
            handleRequestDeposit={handleRequestDeposit}
            onUpdateDepositStatus={onUpdateDepositStatus}
            onApproveSale={onApproveSale}
            onRejectSale={onRejectSale}
            businessSettings={businessSettings}
            setBusinessSettings={setBusinessSettings}
            onResetBusiness={onResetBusiness}
            handleSaveStockAdjustment={handleSaveStockAdjustment}
            businessProfile={businessProfile}
            setBusinessProfile={(profile) => {
                setBusinessProfile(profile);
                if (currentBusinessId && profile) {
                    setBusinesses(prev => prev.map(b => b.id === currentBusinessId ? { ...b, profile } : b));
                }
            }}
            onMarkWithdrawalPaid={onMarkWithdrawalPaid}
            handleConfirmWithdrawalReceived={handleConfirmWithdrawalReceived}
            onApproveClientOrder={onApproveClientOrder}
            onRejectClientOrder={onRejectClientOrder}
            handleInitiateCustomPayment={handleInitiateCustomPayment}
            handleUpdateCustomPaymentStatus={handleUpdateCustomPaymentStatus}
            expenseRequests={expenseRequests}
            handleRequestExpense={handleRequestExpense}
            onUpdateExpenseRequestStatus={onUpdateExpenseRequestStatus}
            isTrialExpired={isTrialExpired}
            trialLimits={trialLimits}
            licensingInfo={licensingInfo}
            printerSettings={printerSettings}
            setPrinterSettings={setPrinterSettings}
            ownerSettings={ownerSettings}
            setOwnerSettings={setOwnerSettings}
            onUpdateCurrentUserProfile={handleUpdateCurrentUserProfile}
        >
            <Routes>
                <Route path="/dashboard" element={<Dashboard products={products} customers={customers} users={users} t={t} receiptSettings={receiptSettings} lowStockThreshold={lowStockThreshold} sales={sales} expenses={expenses} deposits={deposits} currentUser={currentUser} permissions={permissions} onUpdateWithdrawalStatus={onUpdateWithdrawalStatus} onUpdateDepositStatus={onUpdateDepositStatus} onApproveSale={onApproveSale} onRejectSale={onRejectSale} onMarkWithdrawalPaid={onMarkWithdrawalPaid} onApproveClientOrder={onApproveClientOrder} onRejectClientOrder={onRejectClientOrder} handleInitiateCustomPayment={handleInitiateCustomPayment} handleUpdateCustomPaymentStatus={handleUpdateCustomPaymentStatus} expenseRequests={expenseRequests} onUpdateExpenseRequestStatus={onUpdateExpenseRequestStatus} ownerSettings={ownerSettings} businessSettings={businessSettings} businessProfile={businessProfile} />} />
                <Route path="/assistant" element={<AIAssistant currentUser={currentUser} sales={sales} products={products} expenses={expenses} lowStockThreshold={lowStockThreshold} t={t} receiptSettings={receiptSettings} permissions={permissions} />} />
                <Route path="/today" element={<Today sales={sales} customers={customers} expenses={expenses} products={products} t={t} receiptSettings={receiptSettings} />} />
                <Route path="/reports" element={<Reports sales={sales} products={products} expenses={expenses} customers={customers} users={users} t={t} lowStockThreshold={lowStockThreshold} setLowStockThreshold={setLowStockThreshold} receiptSettings={receiptSettings} currentUser={currentUser} permissions={permissions} ownerSettings={ownerSettings} />} />
                <Route path="/shopfront" element={<Items products={products} cart={cart} onUpdateCartItem={handleUpdateCartItem} t={t} receiptSettings={receiptSettings} />} />
                <Route path="/inventory" element={<Inventory products={products} setProducts={setProducts} t={t} receiptSettings={receiptSettings} onSaveStockAdjustment={handleSaveStockAdjustment} currentUser={currentUser} users={users} trialLimits={trialLimits} />} />
                <Route path="/receipts" element={<Receipts sales={sales} customers={customers} users={users} t={t} receiptSettings={receiptSettings} onDeleteSale={onDeleteSale} currentUser={currentUser} isTrialExpired={isTrialExpired} printerSettings={printerSettings} />} />
                <Route path="/proforma" element={<Proforma sales={sales} customers={customers} users={users} t={t} receiptSettings={receiptSettings} onDeleteSale={onDeleteSale} currentUser={currentUser} isTrialExpired={isTrialExpired} printerSettings={printerSettings} />} />
                <Route path="/commission" element={<Commission products={products} setProducts={setProducts} t={t} receiptSettings={receiptSettings} />} />
                <Route path="/expenses" element={<Expenses expenses={expenses} setExpenses={setExpenses} t={t} receiptSettings={receiptSettings} />} />
                <Route path="/expense-requests" element={<ExpenseRequestPage expenseRequests={expenseRequests} expenses={expenses} currentUser={currentUser} handleRequestExpense={handleRequestExpense} receiptSettings={receiptSettings} t={t} />} />
                <Route path="/expenses/reports" element={<ExpenseReport expenses={expenses} t={t} receiptSettings={receiptSettings} />} />
                <Route path="/customer-management" element={<Customers customers={customers} setCustomers={setCustomers} t={t} receiptSettings={receiptSettings} trialLimits={trialLimits} />} />
                <Route path="/users" element={<Users users={users} sales={sales} customers={customers} t={t} currentUser={currentUser} receiptSettings={receiptSettings} onSaveUser={onSaveUser} onDeleteUser={onDeleteUser} trialLimits={trialLimits} permissions={permissions} setPermissions={setPermissions} ownerSettings={ownerSettings} businessProfile={businessProfile} />} />
                <Route path="/investors" element={<InvestorPage users={users} companyValuations={companyValuations} sales={sales} expenses={expenses} products={products} t={t} receiptSettings={receiptSettings} currentUser={currentUser} onSaveUser={onSaveUser} onDeleteUser={onDeleteUser} businessSettings={businessSettings} />} />
                <Route path="/counter" element={<Counter cart={cart} customers={customers} users={users} onUpdateCartItem={handleUpdateCartItem} onProcessSale={onProcessSale} onDeleteSale={onDeleteSale} onClearCart={handleClearCart} receiptSettings={receiptSettings} t={t} onAddCustomer={onAddCustomer} currentUser={currentUser} businessSettings={businessSettings} printerSettings={printerSettings} isTrialExpired={isTrialExpired} />} />
                <Route path="/transactions" element={<Transactions sales={sales} deposits={deposits} users={users} receiptSettings={receiptSettings} currentUser={currentUser} onRequestDeposit={handleRequestDeposit} t={t} />} />
                <Route path="/chat-help" element={<ChatHelp t={t} />} />
                <Route path="/settings" element={<Settings language={language} setLanguage={setLanguage} t={t} currentUser={currentUser} receiptSettings={receiptSettings} setReceiptSettings={setReceiptSettings} theme={theme} setTheme={setTheme} />} />
                <Route path="/settings/receipts" element={<ReceiptSettings settings={receiptSettings} setSettings={setReceiptSettings} t={t} />} />
                <Route path="/settings/permissions" element={<Permissions permissions={permissions} onUpdatePermissions={setPermissions} t={t} users={users} />} />
                <Route path="/settings/business" element={<BusinessSettings settings={businessSettings} onUpdateSettings={setBusinessSettings} businessProfile={businessProfile} onUpdateBusinessProfile={(profile) => {
                    setBusinessProfile(profile);
                    if (currentBusinessId && profile) {
                        setBusinesses(prev => prev.map(b => b.id === currentBusinessId ? { ...b, profile } : b));
                    }
                }} onResetBusiness={onResetBusiness} t={t} currentUser={currentUser} onUpdateCurrentUserProfile={handleUpdateCurrentUserProfile} />} />
                <Route path="/settings/printer" element={<PrinterSettings settings={printerSettings} onUpdateSettings={setPrinterSettings} />} />
                <Route path="/more" element={<More t={t} currentUser={currentUser} permissions={permissions} />} />
                <Route path="/profile" element={<MyProfile currentUser={currentUser} users={users} sales={sales} expenses={expenses} customers={customers} receiptSettings={receiptSettings} t={t} onRequestWithdrawal={handleRequestWithdrawal} onConfirmWithdrawalReceived={handleConfirmWithdrawalReceived} handleUpdateCustomPaymentStatus={handleUpdateCustomPaymentStatus} businessProfile={businessProfile} ownerSettings={ownerSettings} setOwnerSettings={setOwnerSettings} businessSettings={businessSettings} onUpdateCurrentUserProfile={handleUpdateCurrentUserProfile} />} />
                <Route path="/investor-profile" element={<InvestorProfile currentUser={currentUser} users={users} sales={sales} expenses={expenses} products={products} t={t} receiptSettings={receiptSettings} companyValuations={companyValuations} businessSettings={businessSettings} businessProfile={businessProfile} onRequestWithdrawal={handleRequestWithdrawal} onConfirmWithdrawalReceived={handleConfirmWithdrawalReceived} />} />
                <Route path="/items" element={<Items products={products} cart={cart} t={t} receiptSettings={receiptSettings} onUpdateCartItem={handleUpdateCartItem} />} />
                <Route path="/access-denied" element={<AccessDenied />} />
                <Route path="/public-shopfront/:businessId" element={<PublicStorefront />} />
                <Route path="/directory" element={<Directory />} />
                <Route path="/" element={<Navigate to="/today" />} />
                <Route path="*" element={<Navigate to="/today" />} />
            </Routes>
        </MainLayout>
    );
};

export default App;