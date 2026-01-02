
// @ts-nocheck
import React, { useState, useEffect, useCallback, useMemo, useLayoutEffect } from 'react';
import { Routes, Route, Navigate, useNavigate, useLocation, Link } from 'react-router-dom';
import { supabase, isSupabaseConfigured } from './lib/supabase';
import { getStoredItem, setStoredItemAndDispatchEvent, getSystemLogo, formatCurrency } from './lib/utils';
import { 
    BellIcon, 
    MenuIcon,
    CartIcon,
    CounterIcon,
    DEFAULT_RECEIPT_SETTINGS,
    DEFAULT_OWNER_SETTINGS,
    DEFAULT_BUSINESS_SETTINGS,
    FINALIZED_SALE_STATUSES,
    WarningIcon,
    CloseIcon,
    DUMMY_PRODUCTS,
    FINTAB_LOGO_SVG
} from './constants';
import { DEFAULT_PERMISSIONS, hasAccess } from './lib/permissions';
import { translations } from './lib/translations';
import type { AppNotification, Sale, User, Withdrawal, Expense, ExpenseRequest, CashCount, GoodsCosting, GoodsReceiving, AnomalyAlert, WeeklyInventoryCheck, Product, ModuleKey, Customer, ProductVariant, CustomPayment, Deposit, StockAdjustment, CartItem, LicensingInfo, AppPermissions, BankAccount, BankTransaction, WorkflowRoleKey } from './types';

// Components
import Dashboard from './components/Dashboard';
import Sidebar from './components/Sidebar';
import Inventory from './components/Inventory';
import Customers from './components/Customers';
import Users from './components/Users';
import Receipts from './components/Receipts';
import Login from './components/Login';
import Onboarding from './components/Onboarding';
import BottomNavBar from './components/BottomNavBar';
import AIAssistant from './components/AIAssistant';
import Today from './components/Today';
import Reports from './components/Reports';
import Items from './components/Items';
import Counter from './components/Counter';
import Proforma from './components/Proforma';
import Commission from './components/Commission';
import Expenses from './components/Expenses';
import ExpenseRequestPage from './components/ExpenseRequestPage';
import MyProfile from './components/MyProfile';
import Settings from './components/Settings';
import ReceiptSettings from './components/ReceiptSettings';
import Permissions from './components/Permissions';
import BusinessSettings from './components/BusinessSettings';
import OwnerSettingsPage from './components/OwnerSettings';
import PrinterSettings from './components/PrinterSettings';
import NotificationCenter from './components/NotificationCenter';
import AccessDenied from './components/AccessDenied';
import GoBackButton from './components/GoBackButton';
import SelectBusiness from './components/SelectBusiness';
import Transactions from './components/Transactions';
import InvestorPage from './components/Investor';
import CashCountPage from './components/CashCount';
import GoodsCostingPage from './components/GoodsCosting';
import GoodsReceivingPage from './components/GoodsReceiving';
import WeeklyInventoryCheckPage from './components/WeeklyInventoryCheck';
import Directory from './components/Directory';
import AlertsPage from './components/AlertsPage';
import PublicStorefront from './components/PublicStorefront';
import BankAccountsPage from './components/BankAccounts';

const ScrollToTop = () => {
    const { pathname } = useLocation();
    useLayoutEffect(() => {
        const viewport = document.getElementById('app-main-viewport');
        if (viewport) viewport.scrollTo(0, 0);
    }, [pathname]);
    return null;
};

const Header = ({ currentUser, businessProfile, onMenuClick, notifications, cartCount, onMarkAsRead, onMarkAllAsRead, onClear, systemLogo }) => (
    <header className="h-16 flex items-center justify-between px-6 bg-white/80 dark:bg-gray-900/80 backdrop-blur-xl border-b border-slate-100 dark:border-gray-800 z-50 sticky top-0 flex-shrink-0">
        <div className="flex items-center gap-2 sm:gap-4">
            <div className="flex items-center">
                <button onClick={onMenuClick} className="lg:hidden p-2.5 text-slate-500 hover:bg-slate-50 dark:hover:bg-gray-800 rounded-2xl transition-all active:scale-95">
                    <MenuIcon />
                </button>
                <GoBackButton />
            </div>
            <Link to="/dashboard" className="flex items-center gap-3 group transition-all">
                <div className="w-8 h-8 rounded-lg overflow-hidden bg-slate-100 dark:bg-gray-800 flex items-center justify-center shadow-sm">
                    <img src={businessProfile?.logo || systemLogo} className="w-full h-full object-contain" alt="Logo" />
                </div>
                <div className="hidden sm:block">
                    <h1 className="text-base font-black text-primary uppercase tracking-tight leading-none group-hover:text-blue-700 transition-colors">{businessProfile?.businessName || 'FinTab'}</h1>
                    <p className="text-[8px] font-black text-slate-400 uppercase tracking-[0.2em] mt-1.5 opacity-80">Authorized Node</p>
                </div>
            </Link>
        </div>
        <div className="flex items-center gap-2 sm:gap-4">
            {currentUser && (
                <NotificationCenter 
                    notifications={notifications} 
                    onMarkAsRead={onMarkAsRead}
                    onMarkAllAsRead={onMarkAllAsRead}
                    onClear={onClear}
                />
            )}
            <Link to="/counter" className="p-2.5 rounded-2xl text-slate-400 hover:text-primary hover:bg-slate-50 dark:hover:bg-gray-800 relative transition-all active:scale-95 group">
                <CounterIcon className="w-6 h-6 transition-transform group-hover:-rotate-6" />
                {cartCount > 0 && <span className="absolute top-1.5 right-1.5 badge-standard bg-primary scale-75 border-2 border-white dark:border-gray-900">{cartCount}</span>}
            </Link>
            <div className="h-8 w-px bg-slate-100 dark:border-gray-800 mx-1 opacity-60"></div>
            <Link to="/profile" className="flex items-center gap-3 pl-2 group transition-all">
                <div className="relative">
                    <img src={currentUser?.avatarUrl || `https://ui-avatars.com/api/?name=${encodeURIComponent(currentUser?.name || 'User')}`} className="w-9 h-9 rounded-2xl object-cover shadow-sm border-2 border-white dark:border-gray-800 group-hover:border-primary transition-all duration-300" />
                    <div className="absolute -bottom-0.5 -right-0.5 w-3 h-3 bg-emerald-50 border-2 border-white dark:border-gray-900 rounded-full shadow-sm"></div>
                </div>
                <div className="hidden md:block text-left">
                    <p className="text-xs font-black text-slate-900 dark:text-white uppercase tracking-tight group-hover:text-primary transition-colors">{currentUser?.name || 'Terminal'}</p>
                    <p className="text-[8px] font-black text-slate-400 uppercase tracking-widest mt-1 opacity-70">{currentUser?.role || 'Guest'}</p>
                </div>
            </Link>
        </div>
    </header>
);

export class ErrorBoundary extends React.Component<{ children?: React.ReactNode }, { hasError: boolean }> {
    constructor(props: { children?: React.ReactNode }) {
        super(props);
        this.state = { hasError: false };
    }
    static getDerivedStateFromError() { return { hasError: true }; }
    render() {
        if (this.state.hasError) {
            return (
                <div className="min-h-screen flex items-center justify-center bg-slate-50 dark:bg-gray-950 p-8 font-sans">
                    <div className="max-w-md w-full bg-white dark:bg-gray-900 rounded-[2.5rem] shadow-2xl p-10 text-center border border-rose-100 dark:border-rose-900/30">
                        <div className="w-20 h-20 bg-rose-50 dark:bg-rose-950/20 rounded-3xl flex items-center justify-center mx-auto mb-6 text-rose-500"><WarningIcon className="w-10 h-10" /></div>
                        <h2 className="text-2xl font-black text-slate-900 dark:text-white uppercase tracking-tighter mb-4">System Critical Halt</h2>
                        <button onClick={() => window.location.reload()} className="w-full py-4 bg-slate-900 text-white rounded-2xl font-black uppercase text-[10px] tracking-widest shadow-xl active:scale-95 transition-all">Re-Initialize Node</button>
                    </div>
                </div>
            );
        }
        return this.props.children;
    }
}

const SplashScreen = ({ onComplete }: { onComplete: () => void }) => {
    const [isVisible, setIsVisible] = useState(true);

    useEffect(() => {
        const timer = setTimeout(() => {
            setIsVisible(false);
            setTimeout(onComplete, 1000); 
        }, 3000);
        return () => clearTimeout(timer);
    }, [onComplete]);

    if (!isVisible) return null;

    return (
        <div className="fixed inset-0 bg-slate-950 z-[100] flex flex-col items-center justify-center">
            <div className="w-32 h-32 mb-8 animate-pulse">
                <img src={FINTAB_LOGO_SVG} alt="FinTab Logo" className="w-full h-full" />
            </div>
            <h1 className="text-4xl font-black text-white tracking-[0.4em] mb-4">FINTAB</h1>
            <div className="w-48 h-1 bg-white/10 rounded-full overflow-hidden">
                <div className="h-full bg-primary animate-[loading-bar_3s_ease-in-out_infinite]" style={{ width: '100%' }} />
            </div>
            <p className="text-[10px] font-black text-slate-500 uppercase tracking-[0.5em] mt-8">Initializing Node...</p>
        </div>
    );
};

const App = () => {
    const navigate = useNavigate();
    const [isInitialized, setIsInitialized] = useState(false);
    const [currentUser, setCurrentUser] = useState<User | null>(getStoredItem('fintab_simulator_session', null));
    const [activeBusinessId, setActiveBusinessId] = useState<string | null>(localStorage.getItem('fintab_active_business_id'));
    const [isSidebarOpen, setIsSidebarOpen] = useState(false);
    const [language, setLanguage] = useState(localStorage.getItem('fintab_lang') || 'en');
    const [theme, setTheme] = useState<'light' | 'dark'>(localStorage.getItem('fintab_theme') === 'dark' ? 'dark' : 'light');

    // Data State (Scoped by Business ID)
    const [businessProfile, setBusinessProfile] = useState<BusinessProfile | null>(null);
    const [businessSettings, setBusinessSettings] = useState<BusinessSettingsData>(DEFAULT_BUSINESS_SETTINGS);
    const [receiptSettings, setReceiptSettings] = useState<ReceiptSettingsData>(DEFAULT_RECEIPT_SETTINGS);
    const [ownerSettings, setOwnerSettings] = useState<OwnerSettings>(DEFAULT_OWNER_SETTINGS);
    const [permissions, setPermissions] = useState<AppPermissions>(DEFAULT_PERMISSIONS);
    const [printerSettings, setPrinterSettings] = useState<PrinterSettingsData>({ autoPrint: false });
    
    const [products, setProducts] = useState<Product[]>([]);
    const [sales, setSales] = useState<Sale[]>([]);
    const [customers, setCustomers] = useState<Customer[]>([]);
    const [users, setUsers] = useState<User[]>([]);
    const [expenses, setExpenses] = useState<Expense[]>([]);
    const [expenseRequests, setExpenseRequests] = useState<ExpenseRequest[]>([]);
    const [deposits, setDeposits] = useState<Deposit[]>([]);
    const [anomalyAlerts, setAnomalyAlerts] = useState<AnomalyAlert[]>([]);
    const [cashCounts, setCashCounts] = useState<CashCount[]>([]);
    const [goodsCostings, setGoodsCostings] = useState<GoodsCosting[]>([]);
    const [goodsReceivings, setGoodsReceivings] = useState<GoodsReceiving[]>([]);
    const [weeklyChecks, setWeeklyChecks] = useState<WeeklyInventoryCheck[]>([]);
    const [bankAccounts, setBankAccounts] = useState<BankAccount[]>([]);
    const [bankTransactions, setBankTransactions] = useState<BankTransaction[]>([]);
    const [notifications, setNotifications] = useState<AppNotification[]>([]);
    const [cart, setCart] = useState<CartItem[]>([]);

    const systemLogo = getSystemLogo();

    // AUTH LISTENER FOR SUPABASE
    useEffect(() => {
        if (!isSupabaseConfigured) return;

        const { data: { subscription } } = supabase.auth.onAuthStateChange(async (event, session) => {
            if (session?.user) {
                // If logged in via Supabase, we derive the user object
                const userObj = {
                    id: session.user.id,
                    name: session.user.user_metadata?.full_name || session.user.email?.split('@')[0] || 'User',
                    email: session.user.email!,
                    avatarUrl: session.user.user_metadata?.avatar_url || `https://ui-avatars.com/api/?name=${encodeURIComponent(session.user.email!)}`,
                    role: 'Owner' // Default role for supabase auth owner
                };
                setCurrentUser(userObj);
                setStoredItemAndDispatchEvent('fintab_simulator_session', userObj);
            } else if (event === 'SIGNED_OUT') {
                setCurrentUser(null);
                setActiveBusinessId(null);
            }
        });

        return () => subscription.unsubscribe();
    }, []);

    useEffect(() => {
        if (activeBusinessId) {
            const bizPrefix = `fintab_${activeBusinessId}`;
            setBusinessProfile(getStoredItem(`${bizPrefix}_profile`, null));
            setBusinessSettings(getStoredItem(`${bizPrefix}_settings`, DEFAULT_BUSINESS_SETTINGS));
            setReceiptSettings(getStoredItem(`${bizPrefix}_receipt_settings`, DEFAULT_RECEIPT_SETTINGS));
            setOwnerSettings(getStoredItem(`${bizPrefix}_owner_settings`, DEFAULT_OWNER_SETTINGS));
            setPermissions(getStoredItem(`${bizPrefix}_permissions`, DEFAULT_PERMISSIONS));
            setPrinterSettings(getStoredItem(`${bizPrefix}_printer_settings`, { autoPrint: false }));
            setProducts(getStoredItem(`${bizPrefix}_products`, DUMMY_PRODUCTS));
            setSales(getStoredItem(`${bizPrefix}_sales`, []));
            setCustomers(getStoredItem(`${bizPrefix}_customers`, []));
            setUsers(getStoredItem(`${bizPrefix}_users`, []));
            setExpenses(getStoredItem(`${bizPrefix}_expenses`, []));
            setExpenseRequests(getStoredItem(`${bizPrefix}_expense_requests`, []));
            setDeposits(getStoredItem(`${bizPrefix}_deposits`, []));
            setAnomalyAlerts(getStoredItem(`${bizPrefix}_anomaly_alerts`, []));
            setCashCounts(getStoredItem(`${bizPrefix}_cash_counts`, []));
            setGoodsCostings(getStoredItem(`${bizPrefix}_goods_costings`, []));
            setGoodsReceivings(getStoredItem(`${bizPrefix}_goods_receivings`, []));
            setWeeklyChecks(getStoredItem(`${bizPrefix}_weekly_checks`, []));
            setBankAccounts(getStoredItem(`${bizPrefix}_bank_accounts`, []));
            setBankTransactions(getStoredItem(`${bizPrefix}_bank_transactions`, []));
            setNotifications(getStoredItem(`${bizPrefix}_notifications`, []));
            setCart(getStoredItem(`${bizPrefix}_cart`, []));
        }
    }, [activeBusinessId]);

    // FIX: Translation logic to support flat keys in translations.ts
    const t = useCallback((key: string) => {
        if (!key) return '';
        const langData = translations[language] || translations['en'];
        const normalizedKey = key.toLowerCase();
        // Check exact match first, then case-insensitive match
        return langData[key] || langData[normalizedKey] || key;
    }, [language]);

    useEffect(() => {
        if (theme === 'dark') document.documentElement.classList.add('dark');
        else document.documentElement.classList.remove('dark');
        localStorage.setItem('fintab_theme', theme);
    }, [theme]);

    const handleLogout = () => {
        if (isSupabaseConfigured) supabase.auth.signOut();
        setCurrentUser(null);
        setActiveBusinessId(null);
        localStorage.removeItem('fintab_simulator_session');
        localStorage.removeItem('fintab_active_business_id');
        navigate('/login');
    };

    const handleSelectBusiness = (id: string) => {
        setActiveBusinessId(id);
        localStorage.setItem('fintab_active_business_id', id);
        navigate('/dashboard');
    };

    const handleEnterDemo = () => {
        const demoUser = {
            id: 'u-demo',
            name: 'Demo Admin',
            email: 'demo@fintab.io',
            role: 'Owner',
            avatarUrl: `https://ui-avatars.com/api/?name=Demo+Admin&background=2563EB&color=fff`,
            type: 'commission',
            initialInvestment: 50000
        };
        
        // Setup Registry
        const registry = getStoredItem<AdminBusinessData[]>('fintab_businesses_registry', []);
        if (!registry.find(b => b.id === 'biz-demo')) {
            registry.push({
                id: 'biz-demo',
                profile: { businessName: 'FinTab Demo Node', businessType: 'Retail', logo: FINTAB_LOGO_SVG },
                licensingInfo: { licenseType: 'Trial', enrollmentDate: new Date().toISOString(), trialEndDate: new Date(Date.now() + 14 * 24 * 60 * 60 * 1000).toISOString() },
                owner: { name: 'Demo Admin', email: 'demo@fintab.io' },
                stats: { totalRevenue: 12500, salesCount: 45, userCount: 3, joinedDate: new Date().toISOString(), status: 'Active' }
            });
            localStorage.setItem('fintab_businesses_registry', JSON.stringify(registry));
        }

        const bizUsersKey = `fintab_biz-demo_users`;
        const existingUsers = getStoredItem(bizUsersKey, []);
        if (existingUsers.length === 0) {
            localStorage.setItem(bizUsersKey, JSON.stringify([demoUser]));
        }

        setStoredItemAndDispatchEvent('fintab_simulator_session', demoUser);
        setCurrentUser(demoUser);
        handleSelectBusiness('biz-demo');
    };

    const persistData = (key: string, data: any) => {
        if (activeBusinessId) {
            setStoredItemAndDispatchEvent(`fintab_${activeBusinessId}_${key}`, data);
        }
    };

    const handleUpdateCartItem = (product: Product, variant: ProductVariant | undefined, quantity: number) => {
        let newCart = [...cart];
        const existingIdx = newCart.findIndex(item => item.product.id === product.id && item.variant?.id === variant?.id);
        
        if (quantity <= 0) {
            if (existingIdx > -1) newCart.splice(existingIdx, 1);
        } else {
            if (existingIdx > -1) {
                newCart[existingIdx].quantity = quantity;
            } else {
                newCart.push({ product, variant, quantity, stock: variant ? variant.stock : product.stock });
            }
        }
        setCart(newCart);
        persistData('cart', newCart);
    };

    const handleProcessSale = (sale: Sale) => {
        const updatedSales = [sale, ...sales];
        setSales(updatedSales);
        persistData('sales', updatedSales);
        
        if (sale.status === 'completed' || sale.status === 'completed_bank_verified') {
            const updatedProducts = products.map(p => {
                const cartItem = sale.items.find(i => i.product.id === p.id);
                if (cartItem) return { ...p, stock: p.stock - cartItem.quantity };
                return p;
            });
            setProducts(updatedProducts);
            persistData('products', updatedProducts);
        }
    };

    if (!isInitialized) return <SplashScreen onComplete={() => setIsInitialized(true)} />;

    if (!currentUser) return <Login onEnterDemo={handleEnterDemo} />;

    if (!activeBusinessId) return <SelectBusiness currentUser={currentUser} onSelect={handleSelectBusiness} onLogout={handleLogout} />;

    return (
        <div className="flex h-screen bg-slate-50 dark:bg-gray-950 overflow-hidden font-sans">
            <ScrollToTop />
            <Sidebar 
                t={t} 
                isOpen={isSidebarOpen} 
                setIsOpen={setIsSidebarOpen} 
                cart={cart} 
                currentUser={currentUser} 
                onLogout={handleLogout}
                permissions={permissions}
                businessProfile={businessProfile}
                ownerSettings={ownerSettings}
                systemLogo={systemLogo}
                isSafeMode={false}
            />
            <div className="flex-1 flex flex-col min-w-0 overflow-hidden relative">
                <Header 
                    currentUser={currentUser}
                    businessProfile={businessProfile}
                    systemLogo={systemLogo}
                    onMenuClick={() => setIsSidebarOpen(true)}
                    notifications={notifications}
                    cartCount={cart.reduce((s, i) => s + i.quantity, 0)}
                    onMarkAsRead={(id) => {
                        const updated = notifications.map(n => n.id === id ? { ...n, isRead: true } : n);
                        setNotifications(updated);
                        persistData('notifications', updated);
                    }}
                    onMarkAllAsRead={() => {
                        const updated = notifications.map(n => ({ ...n, isRead: true }));
                        setNotifications(updated);
                        persistData('notifications', updated);
                    }}
                    onClear={(id) => {
                        const updated = notifications.filter(n => n.id !== id);
                        setNotifications(updated);
                        persistData('notifications', updated);
                    }}
                />
                <main id="app-main-viewport" className="flex-1 overflow-y-auto custom-scrollbar p-4 md:p-8 pb-32">
                    <Routes>
                        <Route path="/dashboard" element={<Dashboard {...{ products, customers, users, sales, expenses, deposits, expenseRequests, anomalyAlerts, currentUser, businessProfile, businessSettings, ownerSettings, receiptSettings, permissions, t, lowStockThreshold: 10, isSafeMode: false }} />} />
                        <Route path="/assistant" element={<AIAssistant {...{ currentUser, sales, products, expenses, customers, users, expenseRequests, cashCounts, goodsCosting: goodsCostings, goodsReceiving: goodsReceivings, anomalyAlerts, businessSettings, lowStockThreshold: 10, t, receiptSettings, permissions }} />} />
                        <Route path="/inventory" element={<Inventory {...{ products, setProducts: (p) => { setProducts(p); persistData('products', p); }, t, receiptSettings, currentUser, users, handleSaveProduct: (p, edit) => {
                            const updated = edit ? products.map(old => old.id === p.id ? p : old) : [p, ...products];
                            setProducts(updated);
                            persistData('products', updated);
                        }, onSaveStockAdjustment: (id, adj) => {
                             const updated = products.map(p => {
                                if (p.id === id) {
                                    const ns = adj.type === 'add' ? p.stock + adj.quantity : p.stock - adj.quantity;
                                    return { ...p, stock: ns, stockHistory: [{ date: new Date().toISOString(), userId: currentUser.id, ...adj, newStockLevel: ns }, ...(p.stockHistory || [])] };
                                }
                                return p;
                             });
                             setProducts(updated);
                             persistData('products', updated);
                        } }} />} />
                        <Route path="/customers" element={<Customers {...{ customers, setCustomers: (c) => { setCustomers(c); persistData('customers', c); }, t, receiptSettings }} />} />
                        <Route path="/users" element={<Users {...{ users, sales, customers, t, currentUser, receiptSettings, permissions, ownerSettings, businessProfile, onSaveUser: (u, edit, id) => {
                            const updated = edit ? users.map(old => old.id === id ? { ...old, ...u } : old) : [{ ...u, id: `u-${Date.now()}`, avatarUrl: `https://ui-avatars.com/api/?name=${encodeURIComponent(u.name)}` }, ...users];
                            setUsers(updated);
                            persistData('users', updated);
                        }, onDeleteUser: (id) => {
                            const updated = users.filter(u => u.id !== id);
                            setUsers(updated);
                            persistData('users', updated);
                        }, handleInitiateCustomPayment: (target, amt, desc) => {
                            const payment = { id: `cp-${Date.now()}`, dateInitiated: new Date().toISOString(), amount: amt, description: desc, status: 'pending_owner_approval', initiatedBy: currentUser.name, auditLog: [] };
                            const updated = users.map(u => u.id === target ? { ...u, customPayments: [payment, ...(u.customPayments || [])] } : u);
                            setUsers(updated);
                            persistData('users', updated);
                        } }} />} />
                        <Route path="/receipts" element={<Receipts {...{ sales, customers, users, t, receiptSettings, currentUser, isTrialExpired: false, printerSettings, onDeleteSale: (id) => {
                            const updated = sales.filter(s => s.id !== id);
                            setSales(updated);
                            persistData('sales', updated);
                        } }} />} />
                        <Route path="/proforma" element={<Proforma {...{ sales, customers, users, t, receiptSettings, currentUser, isTrialExpired: false, printerSettings, onDeleteSale: (id) => {
                            const updated = sales.filter(s => s.id !== id);
                            setSales(updated);
                            persistData('sales', updated);
                        } }} />} />
                        <Route path="/items" element={<Items {...{ products, cart, t, receiptSettings, onUpdateCartItem: handleUpdateCartItem }} />} />
                        <Route path="/counter" element={<Counter {...{ cart, customers, users, onUpdateCartItem: handleUpdateCartItem, onProcessSale: handleProcessSale, onClearCart: () => { setCart([]); persistData('cart', []); }, receiptSettings, t, currentUser, businessSettings, printerSettings, isTrialExpired: false, permissions, bankAccounts, onAddCustomer: (c) => {
                            const nc = { ...c, id: `c-${Date.now()}`, joinDate: new Date().toISOString(), purchaseHistory: [] };
                            const updated = [nc, ...customers];
                            setCustomers(updated);
                            persistData('customers', updated);
                            return nc;
                        } }} />} />
                        <Route path="/commission" element={<Commission {...{ products, setProducts: (p) => { setProducts(p); persistData('products', p); }, t, receiptSettings }} />} />
                        <Route path="/expenses" element={<Expenses {...{ expenses, setExpenses: (e) => { setExpenses(e); persistData('expenses', e); }, t, receiptSettings }} />} />
                        <Route path="/expense-requests" element={<ExpenseRequestPage {...{ expenseRequests, expenses, currentUser, t, receiptSettings, handleRequestExpense: (r) => {
                            const nr = { ...r, id: `er-${Date.now()}`, date: new Date().toISOString(), userId: currentUser.id, status: 'pending' };
                            const updated = [nr, ...expenseRequests];
                            setExpenseRequests(updated);
                            persistData('expense_requests', updated);
                        } }} />} />
                        <Route path="/profile" element={<MyProfile {...{ currentUser, users, sales, expenses, customers, products, receiptSettings, t, onRequestWithdrawal: (uid, amt, src) => {
                            const w = { id: `wd-${Date.now()}`, date: new Date().toISOString(), amount: amt, status: 'pending', source: src, auditLog: [] };
                            const updated = users.map(u => u.id === uid ? { ...u, withdrawals: [w, ...(u.withdrawals || [])] } : u);
                            setUsers(updated);
                            persistData('users', updated);
                            if (uid === currentUser.id) setCurrentUser({ ...currentUser, withdrawals: [w, ...(currentUser.withdrawals || [])] });
                        }, onUpdateWithdrawalStatus: (uid, wid, st) => {
                            const updated = users.map(u => u.id === uid ? { ...u, withdrawals: (u.withdrawals || []).map(w => w.id === wid ? { ...w, status: st } : w) } : u);
                            setUsers(updated);
                            persistData('users', updated);
                        }, onConfirmWithdrawalReceived: (uid, wid) => {
                            const updated = users.map(u => u.id === uid ? { ...u, withdrawals: (u.withdrawals || []).map(w => w.id === wid ? { ...w, status: 'completed' } : w) } : u);
                            setUsers(updated);
                            persistData('users', updated);
                        }, handleUpdateCustomPaymentStatus: (uid, pid, st) => {
                            const updated = users.map(u => u.id === uid ? { ...u, customPayments: (u.customPayments || []).map(p => p.id === pid ? { ...p, status: st } : p) } : u);
                            setUsers(updated);
                            persistData('users', updated);
                        }, handleInitiateCustomPayment: (target, amt, desc) => {
                            const p = { id: `cp-${Date.now()}`, dateInitiated: new Date().toISOString(), amount: amt, description: desc, status: 'pending_owner_approval', initiatedBy: currentUser.name, auditLog: [] };
                            const updated = users.map(u => u.id === target ? { ...u, customPayments: [p, ...(u.customPayments || [])] } : u);
                            setUsers(updated);
                            persistData('users', updated);
                        }, onSwitchUser: (u) => { setCurrentUser(u); setStoredItemAndDispatchEvent('fintab_simulator_session', u); }, onUpdateCurrentUserProfile: (p) => { const next = { ...currentUser, ...p }; setCurrentUser(next); const updated = users.map(u => u.id === currentUser.id ? next : u); setUsers(updated); persistData('users', updated); setStoredItemAndDispatchEvent('fintab_simulator_session', next); }, businessProfile, ownerSettings, businessSettings, companyValuations: [] }} />} />
                        <Route path="/settings" element={<Settings {...{ language, setLanguage: (l) => { setLanguage(l); localStorage.setItem('fintab_lang', l); }, t, currentUser, receiptSettings, setReceiptSettings: (s) => { setReceiptSettings(s); persistData('receipt_settings', s); }, theme, setTheme }} />} />
                        <Route path="/settings/receipts" element={<ReceiptSettings settings={receiptSettings} setSettings={(s) => { setReceiptSettings(s); persistData('receipt_settings', s); }} t={t} />} />
                        <Route path="/settings/permissions" element={<Permissions permissions={permissions} onUpdatePermissions={(p) => { setPermissions(p); persistData('permissions', p); }} t={t} users={users} />} />
                        <Route path="/settings/business" element={<BusinessSettings settings={businessSettings} onUpdateSettings={(s) => { setBusinessSettings(s); persistData('settings', s); }} businessProfile={businessProfile} onUpdateBusinessProfile={(p) => { setBusinessProfile(p); persistData('profile', p); }} onResetBusiness={() => { localStorage.clear(); window.location.reload(); }} t={t} currentUser={currentUser} onUpdateCurrentUserProfile={(p) => { const next = { ...currentUser, ...p }; setCurrentUser(next); persistData('users', users.map(u => u.id === currentUser.id ? next : u)); setStoredItemAndDispatchEvent('fintab_simulator_session', next); }} users={users} />} />
                        <Route path="/settings/owner" element={<OwnerSettingsPage ownerSettings={ownerSettings} onUpdate={(s) => { setOwnerSettings(s); persistData('owner_settings', s); }} t={t} />} />
                        <Route path="/settings/printer" element={<PrinterSettings settings={printerSettings} onUpdateSettings={(s) => { setPrinterSettings(s); persistData('printer_settings', s); }} />} />
                        <Route path="/cash-count" element={<CashCountPage {...{ cashCounts, setCashCounts: (c) => { setCashCounts(c); persistData('cash_counts', c); }, users, sales, currentUser, receiptSettings, permissions, businessSettings, businessProfile, createNotification: (target, title, msg, type, link) => {
                            const n = { id: `notif-${Date.now()}`, userId: target, title, message: msg, timestamp: new Date().toISOString(), isRead: false, type, link };
                            const updated = [n, ...notifications];
                            setNotifications(updated);
                            persistData('notifications', updated);
                        } }} />} />
                        <Route path="/bank-accounts" element={<BankAccountsPage {...{ bankAccounts, setBankAccounts: (b) => { setBankAccounts(b); persistData('bank_accounts', b); }, bankTransactions, setBankTransactions: (t) => { setBankTransactions(t); persistData('bank_transactions', t); }, receiptSettings, currentUser, users }} />} />
                        <Route path="/goods-costing" element={<GoodsCostingPage {...{ goodsCostings, setGoodsCostings: (c) => { setGoodsCostings(c); persistData('goods_costings', c); }, products, setProducts: (p) => { setProducts(p); persistData('products', p); }, users, currentUser, receiptSettings, permissions, businessSettings, businessProfile, createNotification: (target, title, msg, type, link) => {
                             const n = { id: `notif-${Date.now()}`, userId: target, title, message: msg, timestamp: new Date().toISOString(), isRead: false, type, link };
                             const updated = [n, ...notifications];
                             setNotifications(updated);
                             persistData('notifications', updated);
                        } }} />} />
                        <Route path="/goods-receiving" element={<GoodsReceivingPage {...{ goodsReceivings, setGoodsReceivings: (r) => { setGoodsReceivings(r); persistData('goods_receivings', r); }, products, setProducts: (p) => { setProducts(p); persistData('products', p); }, users, currentUser, receiptSettings, permissions, businessSettings, businessProfile, createNotification: (target, title, msg, type, link) => {
                             const n = { id: `notif-${Date.now()}`, userId: target, title, message: msg, timestamp: new Date().toISOString(), isRead: false, type, link };
                             const updated = [n, ...notifications];
                             setNotifications(updated);
                             persistData('notifications', updated);
                        } }} />} />
                        <Route path="/weekly-inventory-check" element={<WeeklyInventoryCheckPage {...{ weeklyChecks, setWeeklyChecks: (c) => { setWeeklyChecks(c); persistData('weekly_checks', c); }, products, users, currentUser, receiptSettings, businessSettings, businessProfile, permissions, createNotification: (target, title, msg, type, link) => {
                             const n = { id: `notif-${Date.now()}`, userId: target, title, message: msg, timestamp: new Date().toISOString(), isRead: false, type, link };
                             const updated = [n, ...notifications];
                             setNotifications(updated);
                             persistData('notifications', updated);
                        } }} />} />
                        <Route path="/directory" element={<Directory />} />
                        <Route path="/alerts" element={<AlertsPage {...{ anomalyAlerts, onDismiss: (id, reason) => {
                            const updated = anomalyAlerts.map(a => a.id === id ? { ...a, isDismissed: true, dismissalReason: reason } : a);
                            setAnomalyAlerts(updated);
                            persistData('anomaly_alerts', updated);
                        }, onMarkRead: (id) => {
                            const updated = anomalyAlerts.map(a => a.id === id ? { ...a, isRead: true } : a);
                            setAnomalyAlerts(updated);
                            persistData('anomaly_alerts', updated);
                        }, receiptSettings, currentUser }} />} />
                        <Route path="/public-shopfront/:businessId" element={<PublicStorefront />} />
                        <Route path="/today" element={<Today {...{ sales, customers, expenses, products, t, receiptSettings }} />} />
                        <Route path="/reports" element={<Reports {...{ sales, products, expenses, customers, users, t, lowStockThreshold: 10, setLowStockThreshold: () => {}, receiptSettings, currentUser, permissions, ownerSettings }} />} />
                        <Route path="/transactions" element={<Transactions {...{ sales, deposits, bankAccounts, users, receiptSettings, currentUser, t, onRequestDeposit: (amt, desc, bid) => {
                            const d = { id: `dep-${Date.now()}`, date: new Date().toISOString(), amount: amt, description: desc, userId: currentUser.id, status: 'pending', bankAccountId: bid };
                            const updated = [d, ...deposits];
                            setDeposits(updated);
                            persistData('deposits', updated);
                        } }} />} />
                        <Route path="/investors" element={<InvestorPage {...{ users, sales, expenses, products, t, receiptSettings, currentUser, onSaveUser: (u, edit, id) => {
                            const updated = edit ? users.map(old => old.id === id ? { ...old, ...u } : old) : [{ ...u, id: `u-${Date.now()}`, avatarUrl: `https://ui-avatars.com/api/?name=${encodeURIComponent(u.name)}` }, ...users];
                            setUsers(updated);
                            persistData('users', updated);
                        }, onDeleteUser: (id) => {
                            const updated = users.filter(u => u.id !== id);
                            setUsers(updated);
                            persistData('users', updated);
                        }, businessSettings, businessProfile, permissions }} />} />
                        <Route path="*" element={<Navigate to="/dashboard" replace />} />
                    </Routes>
                </main>
            </div>
        </div>
    );
};

export default App;
