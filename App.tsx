
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
    FINTAB_LOGO_SVG
} from './constants';
import { DEFAULT_PERMISSIONS, hasAccess } from './lib/permissions';
import { translations } from './lib/translations';
import Toast, { notify } from './components/Toast';
import JoinBusiness from './components/JoinBusiness';
import type { AppNotification, Sale, User, Withdrawal, Expense, ExpenseRequest, CashCount, GoodsCosting, GoodsReceiving, AnomalyAlert, WeeklyInventoryCheck, Product, ModuleKey, Customer, ProductVariant, CustomPayment, Deposit, StockAdjustment, CartItem, LicensingInfo, AppPermissions, BankAccount, BankTransaction, WorkflowRoleKey, BusinessProfile, BusinessSettingsData, ReceiptSettingsData, OwnerSettings, PrinterSettingsData, AdminBusinessData } from './types';

// Components
import Dashboard from './components/Dashboard';
import Sidebar from './components/Sidebar';
import Inventory from './components/Inventory';
import Customers from './components/Customers';
import Users from './components/Users';
import Receipts from './components/Receipts';
import Login from './components/Login';
import Today from './components/Today';
import Reports from './components/Reports';
import Items from './components/Items';
import Counter from './components/Counter';
import Proforma from './components/Proforma';
import Commission from './components/Commission';
import InvestorPage from './components/Investor';
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
import SelectBusiness from './components/SelectBusiness';
import Transactions from './components/Transactions';
import CashCountPage from './components/CashCount';
import GoodsCostingPage from './components/GoodsCosting';
import GoodsReceivingPage from './components/GoodsReceiving';
import WeeklyInventoryCheckPage from './components/WeeklyInventoryCheck';
import Directory from './components/Directory';
import AlertsPage from './components/AlertsPage';
import PublicStorefront from './components/PublicStorefront';
import BankAccountsPage from './components/BankAccounts';
import AIAssistant from './components/AIAssistant';

const ScrollToTop = () => {
    const { pathname } = useLocation();
    useLayoutEffect(() => {
        const viewport = document.getElementById('app-main-viewport');
        if (viewport) viewport.scrollTo(0, 0);
    }, [pathname]);
    return null;
};

const SplashScreen = ({ onComplete }: { onComplete: () => void }) => {
    useEffect(() => {
        const timer = setTimeout(onComplete, 2600);
        return () => clearTimeout(timer);
    }, [onComplete]);

    return (
        <div className="fixed inset-0 bg-slate-950 z-[200] flex flex-col items-center justify-center animate-fade-in">
            <div className="w-48 h-48 mb-12 animate-pulse transition-all">
                <img src={FINTAB_LOGO_SVG} alt="FinTab Logo" className="w-full h-full object-contain filter brightness-110" />
            </div>
            <div className="w-56 h-1 bg-white/10 rounded-full overflow-hidden relative">
                <div className="absolute inset-0 bg-primary animate-[loading-bar_2.6s_ease-in-out_forwards]" />
            </div>
            <p className="text-[10px] font-black text-slate-500 uppercase tracking-[0.6em] mt-10 ml-[0.6em]">Authorized Node Booting...</p>
        </div>
    );
};

const Header = ({ currentUser, businessProfile, onMenuClick, notifications, cartCount, onMarkAsRead, onMarkAllAsRead, onClear, systemLogo }) => (
    <header className="h-16 flex items-center justify-between px-4 sm:px-6 bg-white/80 dark:bg-gray-900/80 backdrop-blur-xl border-b border-slate-100 dark:border-gray-800 z-50 sticky top-0 flex-shrink-0">
        <div className="flex items-center gap-2 sm:gap-4 overflow-hidden">
            <button onClick={onMenuClick} className="lg:hidden p-2 text-slate-500 hover:bg-slate-50 dark:hover:bg-gray-800 rounded-xl transition-all active:scale-95">
                <MenuIcon className="w-5 h-5" />
            </button>
            <Link to="/dashboard" className="flex items-center gap-2 sm:gap-3 group transition-all overflow-hidden">
                <div className="w-7 h-7 sm:w-8 sm:h-8 rounded-lg overflow-hidden bg-slate-100 dark:bg-gray-800 flex items-center justify-center shadow-sm flex-shrink-0">
                    <img src={businessProfile?.logo || systemLogo} className="w-full h-full object-contain" alt="Logo" />
                </div>
                <div className="hidden xs:block truncate">
                    <h1 className="text-sm sm:text-base font-black text-primary uppercase tracking-tight leading-none group-hover:text-blue-700 transition-colors truncate">{businessProfile?.businessName || 'FinTab'}</h1>
                    <p className="text-[7px] sm:text-[8px] font-black text-slate-400 uppercase tracking-widest mt-1 opacity-80">Node: Verified</p>
                </div>
            </Link>
        </div>
        <div className="flex items-center gap-1 sm:gap-4">
            <NotificationCenter notifications={notifications} onMarkAsRead={onMarkAsRead} onMarkAllAsRead={onMarkAllAsRead} onClear={onClear} />
            <Link to="/counter" className="p-2 sm:p-2.5 rounded-xl text-slate-400 hover:text-primary hover:bg-slate-50 dark:hover:bg-gray-800 relative transition-all active:scale-95 group">
                <CounterIcon className="w-5 h-5 sm:w-6 sm:h-6 transition-transform group-hover:-rotate-6" />
                {cartCount > 0 && <span className="absolute top-1 right-1 sm:top-1.5 sm:right-1.5 bg-rose-500 text-white text-[8px] font-black w-4 h-4 flex items-center justify-center rounded-full border-2 border-white dark:border-gray-900">{cartCount}</span>}
            </Link>
            <div className="h-6 w-px bg-slate-100 dark:border-gray-800 mx-1"></div>
            <Link to="/profile" className="flex items-center gap-2 sm:gap-3 group transition-all">
                <div className="relative flex-shrink-0">
                    <img src={currentUser?.avatarUrl || `https://ui-avatars.com/api/?name=${encodeURIComponent(currentUser?.name || 'User')}`} className="w-8 h-8 sm:w-9 sm:h-9 rounded-xl object-cover shadow-sm border-2 border-white dark:border-gray-800" />
                    <div className="absolute -bottom-0.5 -right-0.5 w-2.5 h-2.5 bg-emerald-500 border-2 border-white dark:border-gray-900 rounded-full"></div>
                </div>
                <div className="hidden md:block text-left max-w-[100px]">
                    <p className="text-xs font-black text-slate-900 dark:text-white uppercase tracking-tight truncate">{currentUser?.name?.split(' ')[0] || 'User'}</p>
                    <p className="text-[7px] font-black text-slate-400 uppercase tracking-widest mt-0.5 opacity-70">{currentUser?.role}</p>
                </div>
            </Link>
        </div>
    </header>
);

export class ErrorBoundary extends React.Component<{ children?: React.ReactNode }, { hasError: boolean }> {
    constructor(props: { children?: React.ReactNode }) { super(props); this.state = { hasError: false }; }
    static getDerivedStateFromError() { return { hasError: true }; }
    render() {
        if (this.state.hasError) {
            return (
                <div className="min-h-screen flex items-center justify-center bg-slate-50 dark:bg-gray-950 p-6 font-sans">
                    <div className="max-w-md w-full bg-white dark:bg-gray-900 rounded-[2.5rem] shadow-2xl p-10 text-center border border-rose-100 dark:border-rose-900/30">
                        <div className="w-20 h-20 bg-rose-50 dark:bg-rose-950/20 rounded-3xl flex items-center justify-center mx-auto mb-6 text-rose-500"><WarningIcon className="w-10 h-10" /></div>
                        <h2 className="text-xl font-black text-slate-900 dark:text-white uppercase tracking-tighter mb-4">Diagnostic Protocol Failure</h2>
                        <button onClick={() => { localStorage.clear(); window.location.href = '/'; }} className="w-full py-4 bg-slate-900 text-white rounded-2xl font-black uppercase text-[10px] tracking-widest shadow-xl active:scale-95 transition-all">Emergency Node Reset</button>
                    </div>
                </div>
            );
        }
        return this.props.children;
    }
}

const App = () => {
    const navigate = useNavigate();
    const location = useLocation();
    const [isInitialized, setIsInitialized] = useState(false);
    const [showIntro, setShowIntro] = useState(true);
    const [currentUser, setCurrentUser] = useState<User | null>(null);
    const [activeBusinessId, setActiveBusinessId] = useState<string | null>(localStorage.getItem('fintab_active_business_id'));
    const [isSidebarOpen, setIsSidebarOpen] = useState(false);
    const [syncStatus, setSyncStatus] = useState<'idle' | 'syncing' | 'error'>('idle');
    
    // Identity-Locked States
    const [language, setLanguage] = useState(() => {
        const bid = localStorage.getItem('fintab_active_business_id');
        return localStorage.getItem(bid ? `fintab_${bid}_lang` : 'fintab_lang') || 'en';
    });
    const [theme, setTheme] = useState<'light' | 'dark'>(() => {
        const bid = localStorage.getItem('fintab_active_business_id');
        return (localStorage.getItem(bid ? `fintab_${bid}_theme` : 'fintab_theme') === 'dark') ? 'dark' : 'light';
    });

    // Operational Data State
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

    // CLOUD SYNC ENGINE
    const persistData = async (key: string, data: any, silent = true) => {
        if (!activeBusinessId) return;
        setSyncStatus('syncing');
        setStoredItemAndDispatchEvent(`fintab_${activeBusinessId}_${key}`, data);
        if (isSupabaseConfigured) {
            try {
                const { error } = await supabase.from('fintab_records').upsert({
                    business_id: activeBusinessId,
                    key: key,
                    data: data,
                    updated_at: new Date().toISOString()
                }, { onConflict: 'business_id,key' });
                if (error) {
                    console.error(`Sync Failure [${key}]:`, error.message);
                    setSyncStatus('error');
                } else {
                    setSyncStatus('idle');
                    if (!silent) notify(`Ledger Synced: ${key}`, "success");
                }
            } catch (err) { 
                console.error(`Sync Breach [${key}]:`, err); 
                setSyncStatus('error');
            }
        }
    };

    const fetchAllBusinessData = async (bid: string, sbUser: any) => {
        if (!isSupabaseConfigured || !bid) return;
        try {
            const { data, error } = await supabase.from('fintab_records').select('key, data').eq('business_id', bid);
            if (error) throw error;
            if (!data) return;
            
            const registry = {};
            data.forEach(record => {
                const { key, data: val } = record;
                registry[key] = val;
                localStorage.setItem(`fintab_${bid}_${key}`, JSON.stringify(val));
                switch(key) {
                    case 'profile': setBusinessProfile(val); break;
                    case 'settings': setBusinessSettings(val); break;
                    case 'receipt_settings': setReceiptSettings(val); break;
                    case 'owner_settings': setOwnerSettings(val); break;
                    case 'permissions': setPermissions(val); break;
                    case 'products': setProducts(val); break;
                    case 'sales': setSales(val); break;
                    case 'customers': setCustomers(val); break;
                    case 'users': setUsers(val); break;
                    case 'expenses': setExpenses(val); break;
                    case 'expense_requests': setExpenseRequests(val); break;
                    case 'deposits': setDeposits(val); break;
                    case 'cash_counts': setCashCounts(val); break;
                    case 'goods_costings': setGoodsCostings(val); break;
                    case 'goods_receivings': setGoodsReceivings(val); break;
                    case 'weekly_checks': setWeeklyChecks(val); break;
                    case 'bank_accounts': setBankAccounts(val); break;
                    case 'bank_transactions': setBankTransactions(val); break;
                    case 'notifications': setNotifications(val); break;
                    case 'printer_settings': setPrinterSettings(val); break;
                    case 'anomaly_alerts': setAnomalyAlerts(val); break;
                    case 'lang': setLanguage(val); break;
                    case 'theme': setTheme(val); break;
                }
            });

            const usersList = registry['users'] || [];
            const foundUser = usersList.find(u => u.email === sbUser.email);
            
            const userObj: User = {
                id: sbUser.id,
                name: foundUser?.name || sbUser.user_metadata?.full_name || sbUser.email?.split('@')[0] || 'User',
                email: sbUser.email!,
                avatarUrl: foundUser?.avatarUrl || sbUser.user_metadata?.avatar_url || `https://ui-avatars.com/api/?name=${encodeURIComponent(sbUser.email!)}`,
                role: foundUser?.role || 'Owner',
                status: 'Active',
                ...foundUser
            };
            
            setCurrentUser(userObj);
            setStoredItemAndDispatchEvent('fintab_simulator_session', userObj);

            // Robust Welcome Message
            const welcomeMsg = sessionStorage.getItem('fintab_welcome_message');
            if (welcomeMsg) {
                notify(welcomeMsg, "success");
                sessionStorage.removeItem('fintab_welcome_message');
            } else if (!localStorage.getItem(`fintab_${bid}_first_boot_seen`)) {
                notify(`Welcome Mr. ${userObj.name.split(' ')[0]} to ${businessProfile?.businessName || 'Business'}`, "success");
                localStorage.setItem(`fintab_${bid}_first_boot_seen`, 'true');
            }

        } catch (err) { 
            console.error("Identity Resolution Failed:", err); 
            notify("Identity Hub Error", "error");
        }
    };

    const attemptAutoSelectBusiness = async (sbUser: any) => {
        const registry = getStoredItem<AdminBusinessData[]>('fintab_businesses_registry', []);
        
        // Check for invited nodes first
        const inviteNode = registry.find(b => {
             const users = getStoredItem<User[]>(`fintab_${b.id}_users`, []);
             return users.some(u => u.email.toLowerCase() === sbUser.email.toLowerCase());
        });

        const myBusinesses = registry.filter(b => b.owner.email.toLowerCase() === sbUser.email.toLowerCase() || b.id === inviteNode?.id);

        if (myBusinesses.length === 1) {
            const bid = myBusinesses[0].id;
            setActiveBusinessId(bid);
            localStorage.setItem('fintab_active_business_id', bid);
            await fetchAllBusinessData(bid, sbUser);
            return true;
        }
        return false;
    };

    // AUTH ENGINE
    useEffect(() => {
        const init = async () => {
            if (!isSupabaseConfigured) { setIsInitialized(true); return; }
            const { data: { session } } = await supabase.auth.getSession();
            if (session?.user) {
                let bid = localStorage.getItem('fintab_active_business_id');
                if (!bid) {
                    const autoSelected = await attemptAutoSelectBusiness(session.user);
                    if (!autoSelected) navigate('/select-business');
                } else {
                    await fetchAllBusinessData(bid, session.user);
                }
            } else {
                // Check for local simulator session (Demo Mode)
                const localSession = getStoredItem<User>('fintab_simulator_session', null);
                if (localSession && activeBusinessId) {
                    setCurrentUser(localSession);
                    // Minimal fetch for demo (mostly local data)
                    const demoBiz = getStoredItem<AdminBusinessData[]>('fintab_businesses_registry', []).find(b => b.id === activeBusinessId);
                    if (demoBiz) setBusinessProfile(demoBiz.profile);
                }
            }
            setIsInitialized(true);
        };
        init();
        const { data: { subscription } } = supabase.auth.onAuthStateChange(async (event, session) => {
            if (event === 'SIGNED_IN' && session?.user) {
                let bid = localStorage.getItem('fintab_active_business_id');
                if (!bid) {
                    const autoSelected = await attemptAutoSelectBusiness(session.user);
                    if (autoSelected) navigate('/dashboard');
                    else navigate('/select-business');
                } else {
                    await fetchAllBusinessData(bid, session.user);
                    navigate('/dashboard');
                }
            } else if (event === 'SIGNED_OUT') { 
                handleLogout(true); 
            }
        });
        return () => subscription.unsubscribe();
    }, []);

    const handleLogout = async (skipSupabase = false) => {
        if (!skipSupabase && isSupabaseConfigured) await supabase.auth.signOut();
        localStorage.removeItem('fintab_simulator_session');
        localStorage.removeItem('fintab_active_business_id');
        window.location.href = window.location.origin + window.location.pathname + '#/login';
        window.location.reload();
    };

    const handleSelectBusiness = async (id: string) => {
        setActiveBusinessId(id);
        localStorage.setItem('fintab_active_business_id', id);
        const { data: { session } } = await supabase.auth.getSession();
        if (session?.user) {
            await fetchAllBusinessData(id, session.user);
        } else {
            // Local Session fallback for Demo
            const demoBiz = getStoredItem<AdminBusinessData[]>('fintab_businesses_registry', []).find(b => b.id === id);
            if (demoBiz) setBusinessProfile(demoBiz.profile);
        }
        navigate('/dashboard');
    };

    // STATE UPDATERS
    const handleUpdateProducts = (p: Product[]) => { setProducts(p); persistData('products', p); };
    const handleUpdateSales = (s: Sale[]) => { setSales(s); persistData('sales', s); };
    const handleUpdateCustomers = (c: Customer[]) => { setCustomers(c); persistData('customers', c); };
    const handleUpdateUsers = (u: User[]) => { setUsers(u); persistData('users', u); };
    const handleUpdateExpenses = (e: Expense[]) => { setExpenses(e); persistData('expenses', e); };
    const handleUpdateExpenseRequests = (r: ExpenseRequest[]) => { setExpenseRequests(r); persistData('expense_requests', r); };
    const handleUpdateDeposits = (d: Deposit[]) => { setDeposits(d); persistData('deposits', d); };
    const handleUpdateBankAccounts = (b: BankAccount[]) => { setBankAccounts(b); persistData('bank_accounts', b); };
    const handleUpdateBankTransactions = (t: BankTransaction[]) => { setBankTransactions(t); persistData('bank_transactions', t); };
    const handleUpdateCashCounts = (c: CashCount[]) => { setCashCounts(c); persistData('cash_counts', c); };
    const handleUpdateGoodsCostings = (c: GoodsCosting[]) => { setGoodsCostings(c); persistData('goods_costings', c); };
    const handleUpdateGoodsReceivings = (r: GoodsReceiving[]) => { setGoodsReceivings(r); persistData('goods_receivings', r); };
    const handleUpdateWeeklyChecks = (w: WeeklyInventoryCheck[]) => { setWeeklyChecks(w); persistData('weekly_checks', w); };
    const handleUpdateNotifications = (n: AppNotification[]) => { setNotifications(n); persistData('notifications', n); };
    const handleUpdateAnomalyAlerts = (a: AnomalyAlert[]) => { setAnomalyAlerts(a); persistData('anomaly_alerts', a); };

    const t = useCallback((key: string) => {
        const dict = translations[language] || translations['en'];
        return dict[key] || translations['en'][key] || key;
    }, [language]);

    useEffect(() => {
        if (theme === 'dark') document.documentElement.classList.add('dark');
        else document.documentElement.classList.remove('dark');
        if (activeBusinessId) persistData('theme', theme);
    }, [theme, activeBusinessId]);

    const handleUpdateCartItem = (product: Product, variant: ProductVariant | undefined, quantity: number) => {
        let newCart = [...cart];
        const existingIdx = newCart.findIndex(item => item.product.id === product.id && item.variant?.id === variant?.id);
        if (quantity <= 0) { if (existingIdx > -1) newCart.splice(existingIdx, 1); }
        else {
            if (existingIdx > -1) newCart[existingIdx].quantity = quantity;
            else newCart.push({ product, variant, quantity, stock: variant ? variant.stock : product.stock });
        }
        setCart(newCart);
    };

    // Ensure splash intro shows for a professional feel
    if (showIntro) return <SplashScreen onComplete={() => setShowIntro(false)} />;
    // Wait for init to finish cold boot session check
    if (!isInitialized) return null;

    return (
        <div className="flex h-screen bg-slate-50 dark:bg-gray-950 overflow-hidden font-sans">
            <ScrollToTop />
            {currentUser && activeBusinessId && (
                <Sidebar t={t} isOpen={isSidebarOpen} setIsOpen={setIsSidebarOpen} cart={cart} currentUser={currentUser} onLogout={() => handleLogout()} permissions={permissions} businessProfile={businessProfile} ownerSettings={ownerSettings} systemLogo={systemLogo} isSafeMode={false} />
            )}
            <div className="flex-1 flex flex-col min-w-0 overflow-hidden relative">
                {currentUser && activeBusinessId && (
                    <Header currentUser={currentUser} businessProfile={businessProfile} systemLogo={systemLogo} onMenuClick={() => setIsSidebarOpen(true)} notifications={notifications} cartCount={cart.reduce((s, i) => s + i.quantity, 0)} onMarkAsRead={(id) => { const updated = notifications.map(n => n.id === id ? { ...n, isRead: true } : n); handleUpdateNotifications(updated); }} onMarkAllAsRead={() => { const updated = notifications.map(n => ({ ...n, isRead: true })); handleUpdateNotifications(updated); }} onClear={(id) => { updated = notifications.filter(n => n.id !== id); handleUpdateNotifications(updated); }} />
                )}
                <main id="app-main-viewport" className={`flex-1 overflow-y-auto custom-scrollbar ${currentUser && activeBusinessId ? 'p-4 md:p-8 pb-32' : ''}`}>
                    <Routes>
                        <Route path="/join/:token" element={<JoinBusiness />} />
                        <Route path="/login" element={!currentUser ? <Login language={language} setLanguage={setLanguage} t={t} /> : <Navigate to={activeBusinessId ? "/dashboard" : "/select-business"} replace />} />
                        <Route path="/select-business" element={currentUser ? <SelectBusiness currentUser={currentUser} onSelect={handleSelectBusiness} onLogout={() => handleLogout()} /> : <Navigate to="/login" />} />
                        
                        <Route path="/dashboard" element={currentUser && activeBusinessId ? <Dashboard {...{ products, customers, users, sales, expenses, deposits, expenseRequests, anomalyAlerts, currentUser, businessProfile, businessSettings, ownerSettings, receiptSettings, permissions, t, lowStockThreshold: 10, isSafeMode: false, onApproveClientOrder: (id) => { const s = sales.map(x => x.id === id ? {...x, status: 'completed'} : x); handleUpdateSales(s); }, onRejectClientOrder: (id) => { const s = sales.map(x => x.id === id ? {...x, status: 'rejected'} : x); handleUpdateSales(s); }, onUpdateWithdrawalStatus: (uid, wid, st) => { const updated = users.map(u => u.id === uid ? {...u, withdrawals: (u.withdrawals || []).map(w => w.id === wid ? {...w, status: st} : w)} : u); handleUpdateUsers(updated); }, handleUpdateCustomPaymentStatus: (uid, pid, st) => { const updated = users.map(u => u.id === uid ? {...u, customPayments: (u.withdrawals || []).map(p => p.id === pid ? {...p, status: st} : p)} : u); handleUpdateUsers(updated); }, onUpdateExpenseRequestStatus: (rid, st) => { const updated = expenseRequests.map(r => r.id === rid ? {...r, status: st} : r); handleUpdateExpenseRequests(updated); }, onUpdateDepositStatus: (did, st) => { const updated = deposits.map(d => d.id === did ? {...d, status: st} : d); handleUpdateDeposits(updated); }, onApproveBankSale: (id) => { const s = sales.map(x => x.id === id ? {...x, status: 'completed'} : x); handleUpdateSales(s); }, onRejectBankSale: (id) => { const s = sales.map(x => x.id === id ? {...x, status: 'rejected'} : x); handleUpdateSales(s); }, onDismissAnomaly: (id, reason) => { const a = anomalyAlerts.map(x => x.id === id ? {...x, isDismissed: true, dismissalReason: reason} : x); handleUpdateAnomalyAlerts(a); }, onMarkAnomalyRead: (id) => { const a = anomalyAlerts.map(x => x.id === id ? {...x, isRead: true} : x); handleUpdateAnomalyAlerts(a); } }} /> : <Navigate to={currentUser ? "/select-business" : "/login"} replace />} />
                        <Route path="/inventory" element={currentUser && activeBusinessId ? <Inventory {...{ products, setProducts: handleUpdateProducts, t, receiptSettings, currentUser, users, handleSaveProduct: (p, edit) => { const updated = edit ? products.map(old => old.id === p.id ? p : old) : [p, ...products]; handleUpdateProducts(updated); }, onSaveStockAdjustment: (id, adj) => { const updated = products.map(p => { if (p.id === id) { const ns = adj.type === 'add' ? p.stock + adj.quantity : p.stock - adj.quantity; return { ...p, stock: ns, stockHistory: [{ date: new Date().toISOString(), userId: currentUser.id, ...adj, newStockLevel: ns }, ...(p.stockHistory || [])] }; } return p; }); handleUpdateProducts(updated); } }} /> : <Navigate to="/login" />} />
                        <Route path="/customers" element={currentUser && activeBusinessId ? <Customers {...{ customers, setCustomers: handleUpdateCustomers, t, receiptSettings }} /> : <Navigate to="/login" />} />
                        <Route path="/users" element={currentUser && activeBusinessId ? <Users {...{ users, sales, customers, t, currentUser, receiptSettings, permissions, ownerSettings, businessProfile, onSaveUser: (u, edit, id) => { const updated = edit ? users.map(old => old.id === id ? { ...old, ...u } : old) : [{ ...u, id: `u-${Date.now()}`, avatarUrl: `https://ui-avatars.com/api/?name=${encodeURIComponent(u.name)}` }, ...users]; handleUpdateUsers(updated); }, onDeleteUser: (id) => { const updated = users.filter(u => u.id !== id); handleUpdateUsers(updated); }, handleInitiateCustomPayment: (target, amt, desc) => { const p = { id: `cp-${Date.now()}`, dateInitiated: new Date().toISOString(), amount: amt, description: desc, status: 'pending_owner_approval', initiatedBy: currentUser.name, auditLog: [] }; const updated = users.map(u => u.id === target ? { ...u, customPayments: [p, ...(u.customPayments || [])] } : u); handleUpdateUsers(updated); } }} /> : <Navigate to="/login" />} />
                        <Route path="/receipts" element={currentUser && activeBusinessId ? <Receipts {...{ sales, customers, users, t, receiptSettings, currentUser, isTrialExpired: false, printerSettings, onDeleteSale: (id) => { const updated = sales.filter(s => s.id !== id); handleUpdateSales(updated); } }} /> : <Navigate to="/login" />} />
                        <Route path="/proforma" element={currentUser && activeBusinessId ? <Proforma {...{ sales, customers, users, t, receiptSettings, currentUser, isTrialExpired: false, printerSettings, onDeleteSale: (id) => { const updated = sales.filter(s => s.id !== id); handleUpdateSales(updated); } }} /> : <Navigate to="/login" />} />
                        <Route path="/items" element={currentUser && activeBusinessId ? <Items {...{ products, cart, t, receiptSettings, onUpdateCartItem: handleUpdateCartItem }} /> : <Navigate to="/login" />} />
                        <Route path="/counter" element={currentUser && activeBusinessId ? <Counter {...{ cart, customers, users, onUpdateCartItem: handleUpdateCartItem, onProcessSale: (sale) => { const s = [sale, ...sales]; handleUpdateSales(s); if(sale.status === 'completed') { const p = products.map(x => { const item = sale.items.find(i => i.product.id === x.id); return item ? {...x, stock: x.stock - item.quantity} : x; }); handleUpdateProducts(p); } }, onClearCart: () => setCart([]), receiptSettings, t, currentUser, businessSettings, printerSettings, isTrialExpired: false, permissions, bankAccounts, onAddCustomer: (c) => { const nc = { ...c, id: `c-${Date.now()}`, joinDate: new Date().toISOString(), purchaseHistory: [] }; handleUpdateCustomers([nc, ...customers]); return nc; } }} /> : <Navigate to="/login" />} />
                        <Route path="/expenses" element={currentUser && activeBusinessId ? <Expenses {...{ expenses, setExpenses: handleUpdateExpenses, t, receiptSettings }} /> : <Navigate to="/login" />} />
                        <Route path="/expense-requests" element={currentUser && activeBusinessId ? <ExpenseRequestPage {...{ expenseRequests, expenses, currentUser, handleRequestExpense: (r) => handleUpdateExpenseRequests([{...r, id: `req-${Date.now()}`, date: new Date().toISOString(), userId: currentUser.id, status: 'pending'}, ...expenseRequests]), receiptSettings, t }} /> : <Navigate to="/login" />} />
                        <Route path="/profile" element={currentUser && activeBusinessId ? <MyProfile {...{ currentUser, users, sales, expenses, customers, products, receiptSettings, t, onRequestWithdrawal: (uid, amt, src) => { const w = { id: `wd-${Date.now()}`, date: new Date().toISOString(), amount: amt, status: 'pending', source: src, auditLog: [] }; const updated = users.map(u => u.id === uid ? { ...u, withdrawals: [w, ...(u.withdrawals || [])] } : u); handleUpdateUsers(updated); }, handleUpdateCustomPaymentStatus: (uid, pid, st) => { const updated = users.map(u => u.id === uid ? {...u, customPayments: (u.withdrawals || []).map(p => p.id === pid ? {...p, status: st} : p)} : u); handleUpdateUsers(updated); }, handleInitiateCustomPayment: (target, amt, desc) => { const p = { id: `cp-${Date.now()}`, dateInitiated: new Date().toISOString(), amount: amt, description: desc, status: 'pending_owner_approval', initiatedBy: currentUser.name, auditLog: [] }; const updated = users.map(u => u.id === target ? { ...u, customPayments: [p, ...(u.customPayments || [])] } : u); handleUpdateUsers(updated); }, onUpdateWithdrawalStatus: (uid, wid, st) => { const updated = users.map(u => u.id === uid ? {...u, withdrawals: (u.withdrawals || []).map(w => w.id === wid ? {...w, status: st} : w)} : u); handleUpdateUsers(updated); }, onConfirmWithdrawalReceived: (uid, wid) => { const updated = users.map(u => u.id === uid ? {...u, withdrawals: (u.withdrawals || []).map(w => w.id === wid ? {...w, status: 'completed'} : w)} : u); handleUpdateUsers(updated); }, onSwitchUser: (u) => { setCurrentUser(u); setStoredItemAndDispatchEvent('fintab_simulator_session', u); window.location.reload(); }, onUpdateCurrentUserProfile: (p) => { const next = { ...currentUser, ...p }; setCurrentUser(next); const updated = users.map(u => u.id === currentUser.id ? next : u); handleUpdateUsers(updated); setStoredItemAndDispatchEvent('fintab_simulator_session', next); }, businessProfile, ownerSettings, businessSettings, companyValuations: [] }} /> : <Navigate to="/login" />} />
                        <Route path="/cash-count" element={currentUser && activeBusinessId ? <CashCountPage {...{ cashCounts, setCashCounts: handleUpdateCashCounts, users, sales, currentUser, receiptSettings, permissions, businessSettings, businessProfile, createNotification: (target, title, msg, type, link) => { const n = { id: `notif-${Date.now()}`, userId: target, title, message: msg, timestamp: new Date().toISOString(), isRead: false, type, link }; handleUpdateNotifications([n, ...notifications]); } }} /> : <Navigate to="/login" />} />
                        <Route path="/bank-accounts" element={currentUser && activeBusinessId ? <BankAccountsPage {...{ bankAccounts, setBankAccounts: handleUpdateBankAccounts, bankTransactions, setBankTransactions: handleUpdateBankTransactions, receiptSettings, currentUser, users }} /> : <Navigate to="/login" />} />
                        <Route path="/goods-costing" element={currentUser && activeBusinessId ? <GoodsCostingPage {...{ goodsCostings, setGoodsCostings: handleUpdateGoodsCostings, products, setProducts: handleUpdateProducts, users, currentUser, receiptSettings, businessSettings, businessProfile, permissions, createNotification: (target, title, msg, type, link) => { const n = { id: `notif-${Date.now()}`, userId: target, title, message: msg, timestamp: new Date().toISOString(), isRead: false, type, link }; handleUpdateNotifications([n, ...notifications]); } }} /> : <Navigate to="/login" />} />
                        <Route path="/goods-receiving" element={currentUser && activeBusinessId ? <GoodsReceivingPage {...{ goodsReceivings, setGoodsReceivings: handleUpdateGoodsReceivings, products, setProducts: handleUpdateProducts, users, currentUser, receiptSettings, businessSettings, businessProfile, permissions, createNotification: (target, title, msg, type, link) => { const n = { id: `notif-${Date.now()}`, userId: target, title, message: msg, timestamp: new Date().toISOString(), isRead: false, type, link }; handleUpdateNotifications([n, ...notifications]); } }} /> : <Navigate to="/login" />} />
                        <Route path="/weekly-inventory-check" element={currentUser && activeBusinessId ? <WeeklyInventoryCheckPage {...{ weeklyChecks, setWeeklyChecks: handleUpdateWeeklyChecks, products, users, currentUser, receiptSettings, businessSettings, businessProfile, permissions, createNotification: (target, title, message, type, link) => { const n = { id: `notif-${Date.now()}`, userId: target, title, message, timestamp: new Date().toISOString(), isRead: false, type, link }; handleUpdateNotifications([n, ...notifications]); } }} /> : <Navigate to="/login" />} />
                        <Route path="/alerts" element={currentUser && activeBusinessId ? <AlertsPage {...{ anomalyAlerts, onDismiss: (id, r) => handleUpdateAnomalyAlerts(anomalyAlerts.map(a => a.id === id ? {...a, isDismissed: true, dismissalReason: r} : a)), onMarkRead: (id) => handleUpdateAnomalyAlerts(anomalyAlerts.map(a => a.id === id ? {...a, isRead: true} : a)), receiptSettings, currentUser }} /> : <Navigate to="/login" />} />
                        <Route path="/settings" element={currentUser && activeBusinessId ? <Settings {...{ language, setLanguage: (l) => { setLanguage(l); localStorage.setItem(`fintab_${activeBusinessId}_lang`, l); persistData('lang', l); }, t, currentUser, receiptSettings, setReceiptSettings: (s) => { setReceiptSettings(s); persistData('receipt_settings', s); notify("Protocol Updated", "success"); }, theme, setTheme: (th) => { setTheme(th); localStorage.setItem(`fintab_${activeBusinessId}_theme`, th); persistData('theme', th); } }} /> : <Navigate to="/login" />} />
                        <Route path="/settings/receipts" element={currentUser && activeBusinessId ? <ReceiptSettings settings={receiptSettings} setSettings={(s) => { setReceiptSettings(s); persistData('receipt_settings', s); notify("Visual Identity Synced", "success"); }} t={t} /> : <Navigate to="/login" />} />
                        <Route path="/settings/permissions" element={currentUser && activeBusinessId ? <Permissions permissions={permissions} onUpdatePermissions={(p) => { setPermissions(p); persistData('permissions', p); notify("Access Matrix Authorized", "success"); }} t={t} users={users} /> : <Navigate to="/login" />} />
                        <Route path="/settings/business" element={currentUser && activeBusinessId ? <BusinessSettings settings={businessSettings} onUpdateSettings={(s) => { setBusinessSettings(s); persistData('settings', s); notify("Core Logic Synced", "success"); }} businessProfile={businessProfile} onUpdateBusinessProfile={(p) => { setBusinessProfile(p); persistData('profile', p); notify("Profile Updated", "success"); }} onResetBusiness={() => { if(confirm("Terminate node?")) { localStorage.clear(); window.location.reload(); } }} t={t} currentUser={currentUser} users={users} onUpdateCurrentUserProfile={(p) => { const next = { ...currentUser, ...p }; setCurrentUser(next); const updated = users.map(u => u.id === currentUser.id ? next : u); handleUpdateUsers(updated); setStoredItemAndDispatchEvent('fintab_simulator_session', next); }} /> : <Navigate to="/login" />} />
                        <Route path="/settings/owner" element={currentUser && activeBusinessId ? <OwnerSettingsPage ownerSettings={ownerSettings} onUpdate={(s) => { setOwnerSettings(s); persistData('owner_settings', s); notify("Override Applied", "success"); }} t={t} /> : <Navigate to="/login" />} />
                        <Route path="/settings/printer" element={currentUser && activeBusinessId ? <PrinterSettings settings={printerSettings} onUpdateSettings={(s) => { setPrinterSettings(s); persistData('printer_settings', s); notify("Hardware Synced", "success"); }} /> : <Navigate to="/login" />} />
                        
                        <Route path="/directory" element={<Directory />} />
                        <Route path="/public-shopfront/:businessId" element={<PublicStorefront />} />
                        <Route path="/today" element={currentUser && activeBusinessId ? <Today {...{ sales, customers, expenses, products, t, receiptSettings }} /> : <Navigate to="/login" />} />
                        <Route path="/reports" element={currentUser && activeBusinessId ? <Reports {...{ sales, products, expenses, customers, users, t, receiptSettings, currentUser, permissions, ownerSettings }} /> : <Navigate to="/login" />} />
                        <Route path="/transactions" element={currentUser && activeBusinessId ? <Transactions {...{ sales, deposits, bankAccounts, users, receiptSettings, currentUser, onRequestDeposit: (amt, desc, bid) => { const d = { id: `dep-${Date.now()}`, date: new Date().toISOString(), amount: amt, description: desc, userId: currentUser.id, status: 'pending', bankAccountId: bid }; handleUpdateDeposits([d, ...deposits]); }, t }} /> : <Navigate to="/login" />} />
                        <Route path="/commission" element={currentUser && activeBusinessId ? <Commission {...{ products, setProducts: handleUpdateProducts, t, receiptSettings }} /> : <Navigate to="/login" />} />
                        <Route path="/investors" element={currentUser && activeBusinessId ? <InvestorPage {...{ users, sales, expenses, products, t, receiptSettings, currentUser, onSaveUser: (u, edit, id) => { const updated = edit ? users.map(old => old.id === id ? { ...old, ...u } : old) : [{ ...u, id: `u-${Date.now()}`, avatarUrl: `https://ui-avatars.com/api/?name=${encodeURIComponent(u.name)}` }, ...users]; handleUpdateUsers(updated); }, onDeleteUser: (id) => { const updated = users.filter(u => u.id !== id); handleUpdateUsers(updated); }, businessSettings, businessProfile, permissions }} /> : <Navigate to="/login" />} />
                        <Route path="/chat-help" element={currentUser && activeBusinessId ? <AIAssistant {...{ currentUser, sales, products, expenses, customers, users, expenseRequests, cashCounts: cashCounts, goodsCosting: goodsCostings, goodsReceiving: goodsReceivings, anomalyAlerts, businessSettings, lowStockThreshold: 10, t, receiptSettings, permissions, setProducts: handleUpdateProducts, setSales: handleUpdateSales, createNotification: (target, title, message, type, link) => { const n = { id: `notif-${Date.now()}`, userId: target, title, message, timestamp: new Date().toISOString(), isRead: false, type, link }; handleUpdateNotifications([n, ...notifications]); }, notifications }} /> : <Navigate to="/login" />} />

                        <Route path="/" element={<Navigate to={currentUser ? (activeBusinessId ? "/dashboard" : "/select-business") : "/login"} replace />} />
                        <Route path="*" element={<Navigate to="/" replace />} />
                    </Routes>
                </main>
            </div>
            {syncStatus === 'syncing' && (
                <div className="fixed bottom-4 left-4 z-[300] bg-slate-900 text-white text-[8px] font-black uppercase tracking-widest px-3 py-1 rounded-full shadow-lg border border-white/10 flex items-center gap-2 animate-fade-in">
                    <div className="w-1.5 h-1.5 bg-primary rounded-full animate-pulse"></div>
                    Syncing Ledger...
                </div>
            )}
        </div>
    );
};

export default App;
