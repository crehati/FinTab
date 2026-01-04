
// @ts-nocheck
import React, { useState, useEffect, useCallback } from 'react';
import { Routes, Route, Navigate, useNavigate, useLocation, Link } from 'react-router-dom';
import { supabase, isSupabaseConfigured } from './lib/supabase';
import { getStoredItem, setStoredItemAndDispatchEvent, getSystemLogo } from './lib/utils';
import { 
    MenuIcon,
    AIIcon,
    DEFAULT_RECEIPT_SETTINGS,
    DEFAULT_OWNER_SETTINGS,
    DEFAULT_BUSINESS_SETTINGS,
    FINTAB_LOGO_SVG
} from './constants';
import { DEFAULT_PERMISSIONS } from './lib/permissions';
import { translations } from './lib/translations';
import { notify } from './components/Toast';

// Component Imports
import Dashboard from './components/Dashboard';
import Sidebar from './components/Sidebar';
import BottomNavBar from './components/BottomNavBar';
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
import MyProfile from './components/MyProfile';
import Settings from './components/Settings';
import BusinessSettings from './components/BusinessSettings';
import OwnerSettingsPage from './components/OwnerSettings';
import PrinterSettings from './components/PrinterSettings';
import ReceiptSettings from './components/ReceiptSettings';
import Permissions from './components/Permissions';
import NotificationCenter from './components/NotificationCenter';
import SelectBusiness from './components/SelectBusiness';
import Transactions from './components/Transactions';
import CashCountPage from './components/CashCount';
import BankAccountsPage from './components/BankAccounts';
import GoodsCostingPage from './components/GoodsCosting';
import GoodsReceivingPage from './components/GoodsReceiving';
import WeeklyInventoryCheckPage from './components/WeeklyInventoryCheck';
import AlertsPage from './components/AlertsPage';
import AIAssistant from './components/AIAssistant';
import ExpenseRequestPage from './components/ExpenseRequestPage';

/**
 * Real-time Clock Node for Top Bar
 */
const TerminalClock = () => {
    const [time, setTime] = useState(new Date());
    useEffect(() => {
        const timer = setInterval(() => setTime(new Date()), 1000);
        return () => clearInterval(timer);
    }, []);
    return (
        <div className="hidden md:flex flex-col items-end px-4 border-l border-slate-100 dark:border-gray-800">
            <p className="text-[11px] font-black text-slate-900 dark:text-white tabular-nums leading-none">
                {time.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}
            </p>
            <p className="text-[8px] font-bold text-slate-400 uppercase tracking-widest mt-1">
                {time.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' })}
            </p>
        </div>
    );
};

export const ErrorBoundary = class extends React.Component {
    constructor(props) { super(props); this.state = { hasError: false }; }
    static getDerivedStateFromError() { return { hasError: true }; }
    render() {
        if (this.state.hasError) {
            return (
                <div className="min-h-screen flex items-center justify-center bg-slate-50 dark:bg-gray-950 p-6 font-sans">
                    <div className="max-w-md w-full bg-white dark:bg-gray-900 rounded-[3rem] p-12 shadow-2xl border border-rose-100 dark:border-rose-900/30 text-center">
                        <div className="w-20 h-20 bg-rose-50 dark:bg-rose-900/20 text-rose-500 rounded-3xl flex items-center justify-center mx-auto mb-8">
                            <svg className="w-10 h-10" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" strokeWidth={2}/></svg>
                        </div>
                        <h2 className="text-2xl font-black text-rose-600 uppercase tracking-tighter">Terminal Fatal</h2>
                        <button onClick={() => { localStorage.clear(); window.location.reload(); }} className="mt-10 w-full py-5 bg-slate-900 text-white rounded-2xl font-black uppercase text-[10px] tracking-widest shadow-xl">Re-Initialize Ledger</button>
                    </div>
                </div>
            );
        }
        return this.props.children;
    }
};

const App = () => {
    const navigate = useNavigate();
    const [isInitialized, setIsInitialized] = useState(false);
    const [currentUser, setCurrentUser] = useState(null);
    const [activeBusinessId, setActiveBusinessId] = useState(localStorage.getItem('fintab_active_business_id'));
    const [isSidebarOpen, setIsSidebarOpen] = useState(false);

    // Global Operational States
    const [businessProfile, setBusinessProfile] = useState(null);
    const [products, setProducts] = useState([]);
    const [sales, setSales] = useState([]);
    const [customers, setCustomers] = useState([]);
    const [users, setUsers] = useState([]);
    const [expenses, setExpenses] = useState([]);
    const [expenseRequests, setExpenseRequests] = useState([]);
    const [cashCounts, setCashCounts] = useState([]);
    const [bankAccounts, setBankAccounts] = useState([]);
    const [bankTransactions, setBankTransactions] = useState([]);
    const [goodsCostings, setGoodsCostings] = useState([]);
    const [goodsReceivings, setGoodsReceivings] = useState([]);
    const [weeklyChecks, setWeeklyChecks] = useState([]);
    const [anomalyAlerts, setAnomalyAlerts] = useState([]);
    const [notifications, setNotifications] = useState([]);
    const [cart, setCart] = useState([]);

    const t = useCallback((key) => translations['en'][key] || key, []);

    const syncState = (bid, key, data) => {
        setStoredItemAndDispatchEvent(`fintab_${bid}_${key}`, data);
    };

    const fetchAllData = async (bid, authUser) => {
        if (!bid) return;
        setBusinessProfile(getStoredItem(`fintab_${bid}_profile`, { businessName: 'FinTab Node' }));
        setProducts(getStoredItem(`fintab_${bid}_products`, []));
        setSales(getStoredItem(`fintab_${bid}_sales`, []));
        setCustomers(getStoredItem(`fintab_${bid}_customers`, []));
        setUsers(getStoredItem(`fintab_${bid}_users`, [authUser]));
        setExpenses(getStoredItem(`fintab_${bid}_expenses`, []));
        setExpenseRequests(getStoredItem(`fintab_${bid}_expense_requests`, []));
        setCashCounts(getStoredItem(`fintab_${bid}_cash_counts`, []));
        setBankAccounts(getStoredItem(`fintab_${bid}_bank_accounts`, []));
        setBankTransactions(getStoredItem(`fintab_${bid}_bank_transactions`, []));
        setGoodsCostings(getStoredItem(`fintab_${bid}_goods_costings`, []));
        setGoodsReceivings(getStoredItem(`fintab_${bid}_goods_receivings`, []));
        setWeeklyChecks(getStoredItem(`fintab_${bid}_weekly_checks`, []));
        setAnomalyAlerts(getStoredItem(`fintab_${bid}_anomaly_alerts`, []));
        setNotifications(getStoredItem(`fintab_${bid}_notifications`, []));
        setCurrentUser(authUser);
    };

    useEffect(() => {
        const init = async () => {
            const localSession = getStoredItem('fintab_simulator_session', null);
            const bid = localStorage.getItem('fintab_active_business_id');
            if (localSession) {
                await fetchAllData(bid, localSession);
            }
            setIsInitialized(true);
        };
        init();
    }, []);

    const handleLogout = () => {
        localStorage.clear();
        window.location.reload();
    };

    // Logic Handlers
    const updateProducts = (p) => { setProducts(p); syncState(activeBusinessId, 'products', p); };
    const updateSales = (s) => { setSales(s); syncState(activeBusinessId, 'sales', s); };
    const updateCustomers = (c) => { setCustomers(c); syncState(activeBusinessId, 'customers', c); };
    const updateCashCounts = (cc) => { setCashCounts(cc); syncState(activeBusinessId, 'cash_counts', cc); };
    const updateBankAccounts = (ba) => { setBankAccounts(ba); syncState(activeBusinessId, 'bank_accounts', ba); };
    const updateBankTransactions = (bt) => { setBankTransactions(bt); syncState(activeBusinessId, 'bank_transactions', bt); };
    const updateCostings = (gc) => { setGoodsCostings(gc); syncState(activeBusinessId, 'goods_costings', gc); };
    const updateReceivings = (gr) => { setGoodsReceivings(gr); syncState(activeBusinessId, 'goods_receivings', gr); };
    const updateExpenses = (e) => { setExpenses(e); syncState(activeBusinessId, 'expenses', e); };
    const updateExpenseRequests = (er) => { setExpenseRequests(er); syncState(activeBusinessId, 'expense_requests', er); };

    const handleUpdateCurrentUserProfile = (p) => {
        const next = { ...currentUser, ...p };
        setCurrentUser(next);
        setStoredItemAndDispatchEvent('fintab_simulator_session', next);
        const updatedUsers = users.map(u => u.id === currentUser.id ? next : u);
        setUsers(updatedUsers);
        syncState(activeBusinessId, 'users', updatedUsers);
    };

    const handleUpdateCustomPaymentStatus = (targetUserId, paymentId, status, note = '') => {
        const updatedUsers = users.map(u => {
            if (u.id === targetUserId) {
                const updatedPayments = (u.customPayments || []).map(p => 
                    p.id === paymentId ? { ...p, status, auditLog: [...(p.auditLog || []), { timestamp: new Date().toISOString(), status, actorId: currentUser.id, actorName: currentUser.name, note }] } : p
                );
                return { ...u, customPayments: updatedPayments };
            }
            return u;
        });
        setUsers(updatedUsers);
        syncState(activeBusinessId, 'users', updatedUsers);
        notify("Remittance Status Synced", "success");
    };

    const onUpdateWithdrawalStatus = (targetUserId, withdrawalId, status, note = '') => {
        const updatedUsers = users.map(u => {
            if (u.id === targetUserId) {
                const updatedWithdrawals = (u.withdrawals || []).map(w => 
                    w.id === withdrawalId ? { ...w, status, auditLog: [...(w.auditLog || []), { timestamp: new Date().toISOString(), status, actorId: currentUser.id, actorName: currentUser.name, note }] } : w
                );
                return { ...u, withdrawals: updatedWithdrawals };
            }
            return u;
        });
        setUsers(updatedUsers);
        syncState(activeBusinessId, 'users', updatedUsers);
        notify("Payout Status Synced", "success");
    };

    const onRequestWithdrawal = (uid, amt, src) => {
        const newWithdrawal = {
            id: `wd-${Date.now()}`,
            date: new Date().toISOString(),
            amount: amt,
            status: 'pending',
            source: src,
            auditLog: [{ timestamp: new Date().toISOString(), status: 'pending', actorId: currentUser.id, actorName: currentUser.name, note: 'Payout initialization' }]
        };
        const updatedUsers = users.map(u => u.id === uid ? { ...u, withdrawals: [newWithdrawal, ...(u.withdrawals || [])] } : u);
        setUsers(updatedUsers);
        syncState(activeBusinessId, 'users', updatedUsers);
        notify("Liquidation Protocol Initialized", "info");
    };

    const handleInitiateCustomPayment = (uid, amt, desc) => {
        const newPayment = {
            id: `cp-${Date.now()}`,
            dateInitiated: new Date().toISOString(),
            amount: amt,
            description: desc,
            status: 'pending_owner_approval',
            initiatedBy: currentUser.name,
            auditLog: [{ timestamp: new Date().toISOString(), status: 'pending_owner_approval', actorId: currentUser.id, actorName: currentUser.name, note: 'Payment drafting' }]
        };
        const updatedUsers = users.map(u => u.id === uid ? { ...u, customPayments: [newPayment, ...(u.customPayments || [])] } : u);
        setUsers(updatedUsers);
        syncState(activeBusinessId, 'users', updatedUsers);
        notify("Payment Node Authorized", "success");
    };

    const onConfirmWithdrawalReceived = (uid, wId) => {
        onUpdateWithdrawalStatus(uid, wId, 'completed', 'Verified receipt of funds.');
    };

    const onUpdateExpenseRequestStatus = (rId, status, reason = '') => {
        const updated = expenseRequests.map(r => r.id === rId ? { ...r, status, rejectionReason: reason } : r);
        updateExpenseRequests(updated);
        notify(`Expense ${status}`, "info");
    };

    const onApproveBankSale = (sId) => {
        const updated = sales.map(s => s.id === sId ? { ...s, status: 'completed_bank_verified' } : s);
        updateSales(updated);
        notify("Settlement Verified", "success");
    };

    const onRejectBankSale = (sId, reason) => {
        const updated = sales.map(s => s.id === sId ? { ...s, status: 'rejected_bank_not_verified', verificationNote: reason } : s);
        updateSales(updated);
        notify("Settlement Rejected", "error");
    };

    const onApproveClientOrder = (sId) => {
        const updated = sales.map(s => s.id === sId ? { ...s, status: 'approved_by_owner' } : s);
        updateSales(updated);
        notify("Order Node Authorized", "success");
    };

    const onRejectClientOrder = (sId) => {
        const updated = sales.map(s => s.id === sId ? { ...s, status: 'rejected' } : s);
        updateSales(updated);
        notify("Order Rejected", "info");
    };

    const onSwitchUser = (u) => {
        setStoredItemAndDispatchEvent('fintab_simulator_session', u);
        window.location.reload();
    };

    if (!isInitialized) return null;

    const isAuth = !!currentUser;
    const hasBiz = !!activeBusinessId;

    return (
        <div className="flex h-screen bg-slate-50 dark:bg-gray-950 overflow-hidden font-sans">
            {isAuth && hasBiz && (
                <Sidebar t={t} isOpen={isSidebarOpen} setIsOpen={setIsSidebarOpen} cart={cart} currentUser={currentUser} onLogout={handleLogout} permissions={DEFAULT_PERMISSIONS} businessProfile={businessProfile} ownerSettings={DEFAULT_OWNER_SETTINGS} systemLogo={FINTAB_LOGO_SVG} />
            )}
            <div className="flex-1 flex flex-col min-w-0 overflow-hidden relative">
                {isAuth && hasBiz && (
                    <header className="h-16 flex items-center justify-between px-6 bg-white/80 dark:bg-gray-900/80 backdrop-blur-xl border-b border-slate-100 dark:border-gray-800 z-50">
                        <div className="flex items-center gap-4">
                            <button onClick={() => setIsSidebarOpen(true)} className="lg:hidden p-2 text-slate-500 rounded-xl hover:bg-slate-50 transition-all"><MenuIcon className="w-5 h-5" /></button>
                            <Link to="/dashboard" className="flex items-center gap-3">
                                <div className="w-8 h-8 rounded-lg overflow-hidden bg-slate-100 flex items-center justify-center shadow-sm">
                                    <img src={businessProfile?.logo || FINTAB_LOGO_SVG} className="w-full h-full object-contain" alt="logo" />
                                </div>
                                <h1 className="text-sm font-black text-slate-900 dark:text-white uppercase tracking-tight">{businessProfile?.businessName || 'FinTab'}</h1>
                            </Link>
                        </div>
                        <div className="flex items-center gap-2 md:gap-4">
                            <TerminalClock />
                            <Link to="/chat-help" className="p-2 text-slate-400 hover:text-primary transition-colors"><AIIcon className="w-5 h-5" /></Link>
                            <NotificationCenter notifications={notifications} onMarkAsRead={() => {}} onMarkAllAsRead={() => {}} onClear={() => {}} />
                            <Link to="/profile"><img src={currentUser.avatarUrl} className="w-8 h-8 rounded-lg object-cover ring-2 ring-primary/10 shadow-sm" alt="profile" /></Link>
                        </div>
                    </header>
                )}
                
                <main className={`flex-1 overflow-y-auto custom-scrollbar ${isAuth && hasBiz ? 'p-6 sm:p-10 pb-40 lg:pb-32' : ''}`}>
                    <Routes>
                        <Route path="/login" element={!isAuth ? <Login t={t} /> : <Navigate to={hasBiz ? "/dashboard" : "/select-business"} replace />} />
                        <Route path="/select-business" element={isAuth ? <SelectBusiness currentUser={currentUser} onSelect={(id) => { setActiveBusinessId(id); localStorage.setItem('fintab_active_business_id', id); window.location.reload(); }} onLogout={handleLogout} /> : <Navigate to="/login" replace />} />

                        {isAuth && hasBiz ? (
                            <>
                                <Route path="/dashboard" element={<Dashboard products={products} customers={customers} users={users} sales={sales} expenses={expenses} deposits={[]} expenseRequests={expenseRequests} anomalyAlerts={anomalyAlerts} currentUser={currentUser} businessProfile={businessProfile} businessSettings={DEFAULT_BUSINESS_SETTINGS} ownerSettings={DEFAULT_OWNER_SETTINGS} receiptSettings={DEFAULT_RECEIPT_SETTINGS} permissions={DEFAULT_PERMISSIONS} t={t} onApproveClientOrder={onApproveClientOrder} onRejectClientOrder={onRejectClientOrder} onUpdateWithdrawalStatus={onUpdateWithdrawalStatus} handleUpdateCustomPaymentStatus={handleUpdateCustomPaymentStatus} onUpdateExpenseRequestStatus={onUpdateExpenseRequestStatus} onUpdateDepositStatus={() => {}} onApproveBankSale={onApproveBankSale} onRejectBankSale={onRejectBankSale} onDismissAnomaly={() => {}} onMarkAnomalyRead={() => {}} isSafeMode={false} lowStockThreshold={10} />} />
                                <Route path="/today" element={<Today sales={sales} customers={customers} expenses={expenses} products={products} t={t} receiptSettings={DEFAULT_RECEIPT_SETTINGS} />} />
                                <Route path="/inventory" element={<Inventory products={products} setProducts={updateProducts} t={t} receiptSettings={DEFAULT_RECEIPT_SETTINGS} currentUser={currentUser} users={users} handleSaveProduct={(p) => updateProducts([p, ...products])} onSaveStockAdjustment={() => {}} />} />
                                <Route path="/items" element={<Items products={products} cart={cart} t={t} receiptSettings={DEFAULT_RECEIPT_SETTINGS} onUpdateCartItem={(p, v, q) => setCart([{ product: p, variant: v, quantity: q }, ...cart.filter(i => i.product.id !== p.id)])} />} />
                                <Route path="/counter" element={<Counter cart={cart} customers={customers} users={users} onProcessSale={(s) => updateSales([s, ...sales])} onClearCart={() => setCart([])} receiptSettings={DEFAULT_RECEIPT_SETTINGS} t={t} currentUser={currentUser} businessSettings={DEFAULT_BUSINESS_SETTINGS} printerSettings={{autoPrint: false}} permissions={DEFAULT_PERMISSIONS} bankAccounts={bankAccounts} onAddCustomer={(c) => { const nc = { ...c, id: Date.now() }; updateCustomers([nc, ...customers]); return nc; }} onUpdateCartItem={(p, v, q) => {}} isTrialExpired={false} />} />
                                <Route path="/receipts" element={<Receipts sales={sales} customers={customers} users={users} t={t} receiptSettings={DEFAULT_RECEIPT_SETTINGS} onDeleteSale={(id) => updateSales(sales.filter(x => x.id !== id))} currentUser={currentUser} isTrialExpired={false} printerSettings={{autoPrint: false}} />} />
                                <Route path="/proforma" element={<Proforma sales={sales} customers={customers} users={users} t={t} receiptSettings={DEFAULT_RECEIPT_SETTINGS} onDeleteSale={(id) => updateSales(sales.filter(x => x.id !== id))} currentUser={currentUser} isTrialExpired={false} printerSettings={{autoPrint: false}} />} />
                                <Route path="/transactions" element={<Transactions sales={sales} deposits={[]} bankAccounts={bankAccounts} users={users} receiptSettings={DEFAULT_RECEIPT_SETTINGS} currentUser={currentUser} onRequestDeposit={() => {}} t={t} />} />
                                <Route path="/commission" element={<Commission products={products} setProducts={updateProducts} t={t} receiptSettings={DEFAULT_RECEIPT_SETTINGS} />} />
                                <Route path="/expenses" element={<Expenses expenses={expenses} setExpenses={updateExpenses} t={t} receiptSettings={DEFAULT_RECEIPT_SETTINGS} />} />
                                <Route path="/expense-requests" element={<ExpenseRequestPage expenseRequests={expenseRequests} expenses={expenses} currentUser={currentUser} handleRequestExpense={(req) => updateExpenseRequests([req, ...expenseRequests])} receiptSettings={DEFAULT_RECEIPT_SETTINGS} t={t} />} />
                                <Route path="/cash-count" element={<CashCountPage cashCounts={cashCounts} setCashCounts={updateCashCounts} users={users} sales={sales} currentUser={currentUser} receiptSettings={DEFAULT_RECEIPT_SETTINGS} businessSettings={DEFAULT_BUSINESS_SETTINGS} businessProfile={businessProfile} permissions={DEFAULT_PERMISSIONS} createNotification={() => {}} />} />
                                <Route path="/bank-accounts" element={<BankAccountsPage bankAccounts={bankAccounts} setBankAccounts={updateBankAccounts} bankTransactions={bankTransactions} setBankTransactions={updateBankTransactions} receiptSettings={DEFAULT_RECEIPT_SETTINGS} currentUser={currentUser} users={users} />} />
                                <Route path="/goods-costing" element={<GoodsCostingPage goodsCostings={goodsCostings} setGoodsCostings={updateCostings} products={products} setProducts={updateProducts} users={users} currentUser={currentUser} receiptSettings={DEFAULT_RECEIPT_SETTINGS} businessSettings={DEFAULT_BUSINESS_SETTINGS} businessProfile={businessProfile} permissions={DEFAULT_PERMISSIONS} createNotification={() => {}} />} />
                                <Route path="/goods-receiving" element={<GoodsReceivingPage goodsReceivings={goodsReceivings} setGoodsReceivings={updateReceivings} products={products} setProducts={updateProducts} users={users} currentUser={currentUser} receiptSettings={DEFAULT_RECEIPT_SETTINGS} businessSettings={DEFAULT_BUSINESS_SETTINGS} businessProfile={businessProfile} permissions={DEFAULT_PERMISSIONS} createNotification={() => {}} />} />
                                <Route path="/weekly-inventory-check" element={<WeeklyInventoryCheckPage weeklyChecks={weeklyChecks} setWeeklyChecks={setWeeklyChecks} products={products} users={users} currentUser={currentUser} receiptSettings={DEFAULT_RECEIPT_SETTINGS} businessSettings={DEFAULT_BUSINESS_SETTINGS} businessProfile={businessProfile} permissions={DEFAULT_PERMISSIONS} createNotification={() => {}} />} />
                                <Route path="/customers" element={<Customers customers={customers} setCustomers={updateCustomers} t={t} receiptSettings={DEFAULT_RECEIPT_SETTINGS} />} />
                                <Route path="/users" element={<Users users={users} sales={sales} customers={customers} t={t} currentUser={currentUser} receiptSettings={DEFAULT_RECEIPT_SETTINGS} onSaveUser={(u) => setUsers([u, ...users])} onDeleteUser={(id) => setUsers(users.filter(x => x.id !== id))} permissions={DEFAULT_PERMISSIONS} ownerSettings={DEFAULT_OWNER_SETTINGS} businessProfile={businessProfile} handleInitiateCustomPayment={handleInitiateCustomPayment} />} />
                                <Route path="/investors" element={<InvestorPage users={users} sales={sales} expenses={expenses} products={products} t={t} receiptSettings={DEFAULT_RECEIPT_SETTINGS} currentUser={currentUser} onSaveUser={() => {}} onDeleteUser={() => {}} businessSettings={DEFAULT_BUSINESS_SETTINGS} businessProfile={businessProfile} permissions={DEFAULT_PERMISSIONS} />} />
                                <Route path="/reports" element={<Reports sales={sales} products={products} expenses={expenses} customers={customers} users={users} t={t} receiptSettings={DEFAULT_RECEIPT_SETTINGS} currentUser={currentUser} permissions={DEFAULT_PERMISSIONS} ownerSettings={DEFAULT_OWNER_SETTINGS} lowStockThreshold={10} setLowStockThreshold={() => {}} />} />
                                <Route path="/settings" element={<Settings language="en" setLanguage={() => {}} t={t} currentUser={currentUser} receiptSettings={DEFAULT_RECEIPT_SETTINGS} setReceiptSettings={() => {}} theme="light" setTheme={() => {}} />} />
                                <Route path="/settings/business" element={<BusinessSettings settings={DEFAULT_BUSINESS_SETTINGS} onUpdateSettings={() => {}} businessProfile={businessProfile} onUpdateBusinessProfile={(p) => setBusinessProfile(p)} onResetBusiness={handleLogout} t={t} currentUser={currentUser} users={users} onUpdateCurrentUserProfile={handleUpdateCurrentUserProfile} />} />
                                <Route path="/settings/owner" element={<OwnerSettingsPage ownerSettings={DEFAULT_OWNER_SETTINGS} onUpdate={() => {}} t={t} />} />
                                <Route path="/settings/printer" element={<PrinterSettings settings={{autoPrint: false}} onUpdateSettings={() => {}} />} />
                                <Route path="/settings/receipts" element={<ReceiptSettings settings={DEFAULT_RECEIPT_SETTINGS} setSettings={() => {}} t={t} />} />
                                <Route path="/settings/permissions" element={<Permissions permissions={DEFAULT_PERMISSIONS} onUpdatePermissions={() => {}} t={t} users={users} />} />
                                <Route path="/profile" element={<MyProfile currentUser={currentUser} users={users} sales={sales} expenses={expenses} customers={customers} products={products} receiptSettings={DEFAULT_RECEIPT_SETTINGS} t={t} onRequestWithdrawal={onRequestWithdrawal} handleUpdateCustomPaymentStatus={handleUpdateCustomPaymentStatus} handleInitiateCustomPayment={handleInitiateCustomPayment} businessProfile={businessProfile} ownerSettings={DEFAULT_OWNER_SETTINGS} businessSettings={DEFAULT_BUSINESS_SETTINGS} onUpdateWithdrawalStatus={onUpdateWithdrawalStatus} onConfirmWithdrawalReceived={onConfirmWithdrawalReceived} companyValuations={[]} onSwitchUser={onSwitchUser} onUpdateCurrentUserProfile={handleUpdateCurrentUserProfile} />} />
                                <Route path="/chat-help" element={<AIAssistant currentUser={currentUser} sales={sales} products={products} expenses={expenses} customers={customers} users={users} expenseRequests={expenseRequests} cashCounts={cashCounts} goodsCosting={goodsCostings} goodsReceiving={goodsReceivings} anomalyAlerts={anomalyAlerts} businessSettings={DEFAULT_BUSINESS_SETTINGS} lowStockThreshold={10} t={t} receiptSettings={DEFAULT_RECEIPT_SETTINGS} permissions={DEFAULT_PERMISSIONS} setProducts={updateProducts} setSales={updateSales} createNotification={() => {}} notifications={notifications} />} />
                                <Route path="/" element={<Navigate to="/dashboard" replace />} />
                            </>
                        ) : (
                            <Route path="*" element={<Navigate to="/login" replace />} />
                        )}
                    </Routes>
                </main>
                {isAuth && hasBiz && (
                    <BottomNavBar t={t} cart={cart} currentUser={currentUser} permissions={DEFAULT_PERMISSIONS} />
                )}
            </div>
        </div>
    );
};

export default App;
