
// @ts-nocheck
import React, { useMemo, useState, useEffect } from 'react';
import { NavLink, useNavigate } from 'react-router-dom';
import type { Product, Customer, User, ReceiptSettingsData, Sale, Deposit, CustomPayment, OwnerSettings, BusinessSettingsData, Expense, AppPermissions, BusinessProfile, PerformanceUser, ExpenseRequest, AnomalyAlert, WorkflowRoleKey } from '../types';
import Card from './Card';
import { CustomersIcon, InventoryIcon, StaffIcon, InvestorIcon, WarningIcon, CloseIcon, LinkIcon, FINALIZED_SALE_STATUSES, StorefrontIcon, ReportsIcon, ExpensesIcon, LightBulbIcon, CounterIcon, PlusIcon, SearchIcon } from '../constants';
import { formatCurrency, formatAbbreviatedNumber, getStoredItem } from '../lib/utils';
import RequestsDashboard from './RequestsDashboard';
import UserDetailModal from './UserDetailModal';
import { hasAccess } from '../lib/permissions';
import AlertsWidget from './AlertsWidget';

class WidgetErrorBoundary extends React.Component<{ children: React.ReactNode }, { hasError: boolean }> {
    constructor(props: { children: React.ReactNode }) {
        super(props);
        this.state = { hasError: false };
    }
    static getDerivedStateFromError() { return { hasError: true }; }
    render() {
        if (this.state.hasError) {
            return (
                <div className="p-8 bg-rose-50 dark:bg-rose-950/20 border-2 border-dashed border-rose-100 dark:border-rose-900/30 rounded-[2rem] text-center font-sans">
                    <p className="text-[10px] font-black text-rose-500 uppercase tracking-[0.2em]">Protocol Interrupt</p>
                    <p className="text-[9px] text-rose-400 font-bold mt-2 uppercase tracking-tight leading-relaxed">Diagnostic logic suspended.</p>
                </div>
            );
        }
        return this.props.children;
    }
}

const KPIMetric: React.FC<{ title: string; value: number | string; cs: string; colorClass?: string; caption?: string }> = ({ title, value, cs, colorClass = "text-slate-900 dark:text-white", caption }) => (
    <div 
        className="bg-white dark:bg-gray-900 p-6 sm:p-8 rounded-[2rem] sm:rounded-[2.5rem] shadow-sm border border-slate-100 dark:border-gray-800 flex flex-col justify-between h-full group hover:shadow-xl transition-all cursor-help"
        title={typeof value === 'number' ? formatCurrency(value, cs) : value}
    >
        <div>
            <p className="text-[9px] font-black uppercase tracking-[0.3em] text-slate-400 mb-4">{title}</p>
            <p className={`text-2xl sm:text-3xl font-black ${colorClass} tracking-tighter tabular-nums leading-none`}>
                {typeof value === 'number' ? `${cs}${formatAbbreviatedNumber(value)}` : value}
            </p>
        </div>
        {caption && (
            <div className="mt-6">
                <p className="text-[8px] sm:text-[9px] font-bold text-slate-400 uppercase tracking-widest leading-relaxed">{caption}</p>
            </div>
        )}
    </div>
);

interface DashboardProps {
    products: Product[];
    customers: Customer[];
    users: User[];
    sales: Sale[];
    expenses: Expense[];
    deposits: Deposit[];
    expenseRequests: ExpenseRequest[];
    anomalyAlerts: AnomalyAlert[];
    currentUser: User;
    businessProfile: BusinessProfile | null;
    businessSettings: BusinessSettingsData;
    ownerSettings: OwnerSettings;
    receiptSettings: ReceiptSettingsData;
    permissions: AppPermissions;
    t: (key: string) => string;
    lowStockThreshold: number;
    isSafeMode: boolean;
    onApproveClientOrder: (saleId: string) => void;
    onRejectClientOrder: (saleId: string) => void;
    onUpdateWithdrawalStatus: (userId: string, withdrawalId: string, status: Withdrawal['status'], note?: string) => void;
    handleUpdateCustomPaymentStatus: (targetUserId: string, paymentId: string, status: CustomPayment['status'], note?: string) => void;
    onUpdateExpenseRequestStatus: (requestId: string, status: 'approved' | 'rejected', reason?: string) => void;
    onUpdateDepositStatus: (depositId: string, status: 'approved' | 'rejected') => void;
    onApproveBankSale: (saleId: string) => void;
    onRejectBankSale: (saleId: string, reason: string) => void;
    onDismissAnomaly: (id: string, reason?: string) => void;
    onMarkAnomalyRead: (id: string) => void;
}

const Dashboard: React.FC<DashboardProps> = (props) => {
    const { 
        products, customers, users, t, receiptSettings, lowStockThreshold,
        sales, expenses, deposits, currentUser, permissions, onUpdateWithdrawalStatus,
        onApproveClientOrder, onRejectClientOrder, handleUpdateCustomPaymentStatus, 
        onUpdateExpenseRequestStatus, onUpdateDepositStatus, onApproveBankSale, onRejectBankSale, 
        onDismissAnomaly, onMarkAnomalyRead, businessSettings, businessProfile, ownerSettings, expenseRequests, isSafeMode, anomalyAlerts
    } = props;
    
    const cs = receiptSettings.currencySymbol;
    const [auditUser, setAuditUser] = useState<PerformanceUser | null>(null);
    const navigate = useNavigate();

    // Identity Checks
    const isOwner = currentUser?.role === 'Owner' || currentUser?.role === 'Super Admin';
    const isPrivileged = isOwner || currentUser?.role === 'Manager';
    const isStaff = currentUser?.role === 'Staff' || currentUser?.role === 'Cashier';
    const isInvestor = currentUser?.role === 'Investor';

    // Global Stats
    const stats = useMemo(() => {
        const safeSales = sales || [];
        const safeProducts = products || [];
        const safeExpenses = expenses || [];

        const finalizedSales = safeSales.filter(s => s && s.status && FINALIZED_SALE_STATUSES.includes(s.status));
        const totalRevenue = finalizedSales.reduce((sum, s) => sum + (s.total || 0), 0);
        
        const lifetimeGrossProfit = finalizedSales.reduce((total, sale) => {
            const cogs = (sale.items || []).reduce((sum, item) => {
                const prod = safeProducts.find(p => p.id === item.product.id);
                return sum + ((prod?.costPrice || 0) * item.quantity);
            }, 0);
            return total + (sale.subtotal - sale.discount - cogs);
        }, 0);

        const activeExpenses = safeExpenses.filter(e => e.status !== 'deleted');
        const totalExpVal = activeExpenses.reduce((sum, e) => sum + e.amount, 0);
        const netProfit = Math.max(0, lifetimeGrossProfit - totalExpVal);

        const stockCost = safeProducts.reduce((sum, p) => sum + (p.stock * p.costPrice), 0);
        const stockValue = safeProducts.reduce((sum, p) => sum + (p.stock * p.price), 0);

        const productStats = safeProducts.map(p => {
            const sold = finalizedSales.reduce((sum, s) => {
                const item = (s.items || []).find(i => i.product.id === p.id);
                return sum + (item ? item.quantity : 0);
            }, 0);
            return { ...p, unitsSold: sold };
        });

        const bestSellers = [...productStats].sort((a, b) => b.unitsSold - a.unitsSold).slice(0, 10);
        const leastSellers = [...productStats].sort((a, b) => a.unitsSold - b.unitsSold).slice(0, 10);

        return { 
            totalRevenue, lifetimeGrossProfit, totalExpVal, netProfit, 
            stockCost, stockValue, bestSellers, leastSellers,
            missingCostCount: safeProducts.filter(p => !p.costPrice || p.costPrice === 0).length
        };
    }, [sales, products, expenses]);

    // Owner Equity Logic
    const ownerEquity = useMemo(() => {
        if (!isOwner || !currentUser) return null;
        const participants = (users || []).filter(u => u && (u.role === 'Investor' || u.role === 'Owner') && u.status === 'Active');
        const totalCapital = participants.reduce((sum, p) => sum + (p.initialInvestment || 0), 0);
        const myInvestment = currentUser.initialInvestment || 0;
        const share = totalCapital > 0 ? (myInvestment / totalCapital) : 0;
        
        const distRate = (businessSettings?.investorDistributionPercentage || 100) / 100;
        const earned = stats.netProfit * share * distRate;
        
        const withdrawn = (currentUser.withdrawals || [])
            .filter(w => w.status === 'completed' && w.source === 'investment')
            .reduce((sum, w) => sum + w.amount, 0);
            
        return { share: (share * 100).toFixed(1), earned, withdrawn, available: Math.max(0, earned - withdrawn) };
    }, [isOwner, users, currentUser, stats.netProfit, businessSettings?.investorDistributionPercentage]);

    const staffLeaderboard = useMemo(() => {
        if (isSafeMode) return [];
        return (users || [])
            .filter(u => u && u.role !== 'Investor' && (u.role !== 'Owner' || (ownerSettings && ownerSettings.showOnLeaderboard)))
            .map(member => {
                const memberSales = (sales || []).filter(s => s && s.userId === member.id && FINALIZED_SALE_STATUSES.includes(s.status));
                return { ...member, salesCount: memberSales.length, totalSalesValue: memberSales.reduce((sum, s) => sum + s.total, 0) };
            })
            .sort((a, b) => b.totalSalesValue - a.totalSalesValue).slice(0, 5);
    }, [users, sales, ownerSettings, isSafeMode]);

    // Investor-specific calculations
    const investorEquity = useMemo(() => {
        if (!isInvestor || !currentUser) return null;
        
        const activeInvestors = (users || []).filter(u => u && (u.role === 'Investor' || u.role === 'Owner') && u.status === 'Active');
        const totalCapital = activeInvestors.reduce((sum, inv) => sum + (inv.initialInvestment || 0), 0);
        const myInvestment = currentUser.initialInvestment || 0;
        const myShare = totalCapital > 0 ? (myInvestment / totalCapital) : 0;
        
        const distRate = (businessSettings?.investorDistributionPercentage || 100) / 100;
        const totalProfitShare = stats.netProfit * myShare * distRate;
        
        const withdrawn = (currentUser.withdrawals || [])
            .filter(w => w.status === 'completed' && w.source === 'investment')
            .reduce((sum, w) => sum + w.amount, 0);
        const reserved = (currentUser.withdrawals || [])
            .filter(w => ['pending', 'approved_by_owner'].includes(w.status) && w.source === 'investment')
            .reduce((sum, w) => sum + w.amount, 0);
            
        return {
            investment: myInvestment,
            share: (myShare * 100).toFixed(2),
            earned: totalProfitShare,
            withdrawn,
            available: Math.max(0, totalProfitShare - withdrawn - reserved)
        };
    }, [isInvestor, users, stats.netProfit, currentUser?.initialInvestment, currentUser?.withdrawals, businessSettings?.investorDistributionPercentage]);

    const assignedTasks = useMemo(() => {
        const tasks = [];
        const workflow = businessSettings?.workflowRoles || {};
        Object.entries(workflow).forEach(([roleKey, assignments]) => {
            if (Array.isArray(assignments) && assignments.some(a => a.userId === currentUser?.id)) {
                tasks.push(roleKey as WorkflowRoleKey);
            }
        });
        return tasks;
    }, [businessSettings?.workflowRoles, currentUser?.id]);

    const todaysSalesSummary = useMemo(() => {
        const todayStr = new Date().toISOString().split('T')[0];
        const todays = (sales || []).filter(s => s && s.date && s.date.startsWith(todayStr) && FINALIZED_SALE_STATUSES.includes(s.status));
        return { count: todays.length, revenue: todays.reduce((s, x) => s + x.total, 0) };
    }, [sales]);

    return (
        <div className="max-w-7xl mx-auto space-y-8 sm:space-y-12 pb-32 animate-fade-in font-sans">
            {/* Header / Identity Hub */}
            <div className="bg-slate-900 rounded-[2.5rem] sm:rounded-[3rem] p-6 sm:p-10 text-white shadow-2xl relative overflow-hidden border border-white/5">
                <div className="absolute top-0 right-0 w-[300px] sm:w-[500px] h-[300px] sm:h-[500px] bg-primary/20 rounded-full -mr-24 sm:-mr-48 -mt-24 sm:-mt-48 blur-[80px] sm:blur-[120px]"></div>
                <div className="relative flex flex-col md:flex-row justify-between items-center gap-6 sm:gap-10">
                    <div className="flex items-center gap-6 sm:gap-10 w-full sm:w-auto">
                        <div className="w-16 h-16 sm:w-20 sm:h-20 bg-white/5 backdrop-blur-xl rounded-3xl flex items-center justify-center border border-white/10 shadow-inner flex-shrink-0">
                            <StorefrontIcon className="w-8 h-8 sm:w-10 sm:h-10 text-primary" />
                        </div>
                        <div className="min-w-0">
                            <h2 className="text-2xl sm:text-4xl font-black uppercase tracking-tighter leading-none truncate">Terminal: {currentUser?.name?.split(' ')[0]}</h2>
                            <p className="text-slate-500 font-bold uppercase tracking-[0.4em] text-[8px] sm:text-[10px] mt-2 sm:mt-4">{currentUser?.role} Node Operational</p>
                        </div>
                    </div>
                    {(isOwner || isInvestor) && (
                        <div className="bg-white/5 backdrop-blur-md p-1.5 sm:p-2 rounded-[2rem] sm:rounded-[2.5rem] border border-white/10 flex w-full sm:w-auto">
                            <div className="flex-1 px-4 sm:px-8 py-3 sm:py-5 text-center border-r border-white/5" title={formatCurrency(currentUser?.initialInvestment || 0, cs)}>
                                <p className="text-[7px] sm:text-[9px] font-black text-slate-500 uppercase tracking-widest mb-1">Stake</p>
                                <p className="text-lg sm:text-2xl font-black text-primary tabular-nums tracking-tight">
                                    {isOwner ? ownerEquity?.share : investorEquity?.share}%
                                </p>
                            </div>
                            <div className="flex-1 px-4 sm:px-8 py-3 sm:py-5 text-center" title={formatCurrency(isOwner ? ownerEquity?.available : investorEquity?.available, cs)}>
                                <p className="text-[7px] sm:text-[9px] font-black text-slate-500 uppercase tracking-widest mb-1">Liquid</p>
                                <p className="text-lg sm:text-2xl font-black text-emerald-500 tabular-nums tracking-tight">
                                    {cs}{formatAbbreviatedNumber(isOwner ? ownerEquity?.available : investorEquity?.available)}
                                </p>
                            </div>
                        </div>
                    )}
                </div>
            </div>

            {/* Investor Equity Hub */}
            {isInvestor && investorEquity && (
                <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6 animate-fade-in">
                    <div 
                        className="bg-slate-900 text-white p-8 rounded-[2.5rem] shadow-2xl relative overflow-hidden flex flex-col justify-between cursor-help border border-white/5"
                        title={formatCurrency(investorEquity.investment, cs)}
                    >
                        <div className="absolute top-0 right-0 w-32 h-32 bg-primary/20 rounded-full -mr-16 -mt-16 blur-2xl"></div>
                        <div>
                            <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest mb-4">Capital Stake</p>
                            <p className="text-3xl font-black tabular-nums tracking-tighter">{cs}{formatAbbreviatedNumber(investorEquity.investment)}</p>
                        </div>
                        <div className="mt-8 pt-6 border-t border-white/5 flex justify-between items-center">
                            <p className="text-[9px] font-black text-slate-500 uppercase tracking-widest">{investorEquity.share}% Share</p>
                            <span className="w-1.5 h-1.5 rounded-full bg-emerald-500"></span>
                        </div>
                    </div>
                    <div 
                        className="bg-white dark:bg-gray-900 p-8 rounded-[2.5rem] shadow-xl border border-slate-50 dark:border-gray-800 flex flex-col justify-between cursor-help"
                        title={formatCurrency(investorEquity.earned, cs)}
                    >
                        <div>
                            <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest mb-4">Total Realized</p>
                            <p className="text-3xl font-black text-emerald-600 tabular-nums tracking-tighter">{cs}{formatAbbreviatedNumber(investorEquity.earned)}</p>
                        </div>
                        <p className="text-[9px] font-bold text-slate-400 uppercase tracking-widest mt-8">Accrued Inflow</p>
                    </div>
                    <div 
                        className="bg-white dark:bg-gray-900 p-8 rounded-[2.5rem] shadow-xl border border-slate-50 dark:border-gray-800 flex flex-col justify-between cursor-help"
                        title={formatCurrency(investorEquity.available, cs)}
                    >
                        <div>
                            <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest mb-4">Liquid Balance</p>
                            <p className="text-3xl font-black text-primary tabular-nums tracking-tighter">{cs}{formatAbbreviatedNumber(investorEquity.available)}</p>
                        </div>
                        <NavLink to="/profile" className="mt-8 py-3 bg-primary text-white text-center rounded-2xl text-[9px] font-black uppercase tracking-[0.2em] shadow-lg shadow-primary/20 hover:opacity-90 active:scale-[0.98] transition-all">Claim Dividend →</NavLink>
                    </div>
                </div>
            )}

            {/* Privileged Logic Grid (Treasury & Health) */}
            {isPrivileged && (
                <div className="grid grid-cols-2 sm:grid-cols-2 lg:grid-cols-4 gap-4 sm:gap-6">
                    <KPIMetric title="Revenue" value={stats.totalRevenue} cs={cs} caption="Realized Inflow" />
                    <KPIMetric title="Gross Profit" value={stats.lifetimeGrossProfit} cs={cs} colorClass="text-emerald-600" caption="Yield Net COGS" />
                    <KPIMetric title="Exposure" value={stats.totalExpVal} cs={cs} colorClass="text-rose-600" caption="Total Authorized Debits" />
                    <div 
                        className="bg-primary text-white p-6 sm:p-8 rounded-[2rem] sm:rounded-[2.5rem] shadow-2xl shadow-primary/30 flex flex-col justify-between cursor-help group transition-all hover:-translate-y-1 col-span-2 sm:col-span-1"
                        title={formatCurrency(stats.netProfit, cs)}
                    >
                        <div>
                            <p className="text-[9px] font-black text-white/50 uppercase tracking-widest mb-4">Net Treasury</p>
                            <p className="text-2xl sm:text-3xl font-black tabular-nums tracking-tighter">{cs}{formatAbbreviatedNumber(stats.netProfit)}</p>
                        </div>
                        <NavLink to="/reports" className="text-[8px] sm:text-[9px] font-black text-white uppercase tracking-[0.3em] hover:underline mt-8 opacity-60 group-hover:opacity-100 transition-opacity">Ledger Reports →</NavLink>
                    </div>
                </div>
            )}

            {/* Staff-Specific Action Hub */}
            {isStaff && (
                <div className="grid grid-cols-1 lg:grid-cols-3 gap-6 sm:gap-10 animate-fade-in">
                    <div className="lg:col-span-3">
                        <NavLink to="/counter" className="relative h-full min-h-[220px] sm:min-h-[280px] p-8 sm:p-12 bg-slate-900 text-white rounded-[2.5rem] sm:rounded-[3.5rem] shadow-2xl flex flex-col justify-center group hover:scale-[1.01] transition-all border border-white/5 overflow-hidden">
                            <div className="absolute top-0 right-0 w-48 sm:w-64 h-48 sm:h-64 bg-primary/20 rounded-full -mr-24 sm:-mr-32 -mt-24 sm:-mt-32 blur-[60px] sm:blur-[100px] group-hover:scale-110 transition-transform duration-1000"></div>
                            <div className="relative z-10">
                                <div className="flex items-center gap-4 sm:gap-6 mb-6 sm:mb-8">
                                    <div className="bg-primary p-4 sm:p-6 rounded-2xl sm:rounded-[2rem] shadow-xl group-hover:rotate-12 transition-transform duration-500 flex-shrink-0">
                                        <PlusIcon className="w-8 h-8 sm:w-12 sm:h-12" />
                                    </div>
                                    <h3 className="text-3xl sm:text-5xl font-black uppercase tracking-tighter leading-none">New Sale</h3>
                                </div>
                                <p className="text-[10px] sm:text-xs font-bold text-slate-400 uppercase tracking-[0.4em] ml-1">Launch Terminal Authorization Interface</p>
                            </div>
                            <div className="absolute bottom-6 sm:bottom-12 right-6 sm:right-12 opacity-10 group-hover:opacity-100 transition-opacity">
                                <CounterIcon className="w-16 h-16 sm:w-24 sm:h-24 text-white" />
                            </div>
                        </NavLink>
                    </div>
                </div>
            )}

            {/* Verification & Alerts Hub */}
            <div className="grid grid-cols-1 lg:grid-cols-3 gap-6 sm:gap-10">
                <div className="lg:col-span-2">
                    <div className="bg-white dark:bg-gray-900 rounded-[2.5rem] sm:rounded-[3rem] shadow-xl border border-slate-50 dark:border-gray-800 overflow-hidden h-full">
                         <header className="px-6 sm:px-10 py-6 sm:py-8 border-b dark:border-gray-800 flex justify-between items-center bg-slate-50/30 dark:bg-gray-800/30">
                            <div className="flex items-center gap-4">
                                <div className="w-1.5 h-1.5 bg-primary rounded-full animate-pulse"></div>
                                <h3 className="text-[10px] sm:text-[11px] font-black uppercase tracking-[0.4em] text-slate-900 dark:text-white">Central Hub</h3>
                            </div>
                            <span className="text-[8px] sm:text-[9px] font-black text-slate-400 uppercase tracking-widest">Verification Node</span>
                        </header>
                        <div className="p-4 sm:p-8">
                            <RequestsDashboard 
                                users={users || []} sales={sales || []} deposits={deposits || []} expenseRequests={expenseRequests || []}
                                receiptSettings={receiptSettings} onUpdateWithdrawalStatus={onUpdateWithdrawalStatus}
                                onUpdateDepositStatus={onUpdateDepositStatus}
                                onApproveBankSale={onApproveBankSale} onRejectBankSale={onRejectBankSale}
                                onUpdateExpenseRequestStatus={onUpdateExpenseRequestStatus}
                                handleUpdateCustomPaymentStatus={handleUpdateCustomPaymentStatus}
                                onApproveClientOrder={onApproveClientOrder} onRejectClientOrder={onRejectClientOrder}
                                customers={customers || []} t={t} currentUser={currentUser} permissions={permissions}
                            />
                        </div>
                    </div>
                </div>
                <div className="lg:col-span-1 space-y-6 sm:space-y-10">
                    {(isPrivileged || isInvestor) && (
                        <WidgetErrorBoundary>
                            <AlertsWidget 
                                alerts={anomalyAlerts || []} 
                                onDismiss={onDismissAnomaly} 
                                onMarkRead={onMarkAnomalyRead}
                                receiptSettings={receiptSettings} 
                                currentUser={currentUser}
                                businessSettings={businessSettings}
                            />
                        </WidgetErrorBoundary>
                    )}
                    {assignedTasks.length > 0 && (
                        <div className="bg-white dark:bg-gray-900 rounded-[2.5rem] shadow-xl border border-slate-50 dark:border-gray-800 p-8 sm:p-10 animate-fade-in">
                            <h3 className="text-[11px] font-black uppercase tracking-[0.4em] text-slate-900 dark:text-white mb-8 sm:mb-10 flex items-center gap-3">
                                <div className="w-1 h-4 bg-primary rounded-full"></div>
                                Task Queue
                            </h3>
                            <div className="space-y-4">
                                {assignedTasks.map(task => (
                                    <NavLink key={task} to={`/${task.includes('cash') ? 'cash-count' : task.includes('stock') ? 'weekly-inventory-check' : 'goods-receiving'}`} className="flex items-center justify-between p-5 sm:p-6 bg-slate-50 dark:bg-gray-800 rounded-[2rem] hover:shadow-xl transition-all text-left border border-transparent hover:border-primary/20 group active:scale-[0.98]">
                                        <div className="min-w-0 pr-4">
                                            <span className="text-[10px] sm:text-[11px] font-black uppercase tracking-widest text-slate-700 dark:text-slate-200 group-hover:text-primary transition-colors block truncate">{task.replace(/([A-Z])/g, ' $1')}</span>
                                            <span className="text-[8px] font-bold text-slate-400 uppercase tracking-widest mt-1">Status: Pending</span>
                                        </div>
                                        <span className="text-[8px] font-black text-primary uppercase bg-primary/10 px-3 py-1.5 rounded-xl border border-primary/20 flex-shrink-0">Action</span>
                                    </NavLink>
                                ))}
                            </div>
                        </div>
                    )}
                </div>
            </div>

            {/* Global Operational Metrics Grid */}
            <div className="grid grid-cols-2 lg:grid-cols-4 gap-4 sm:gap-6 px-2">
                <div className="bg-white dark:bg-gray-900 p-6 sm:p-8 rounded-[2rem] sm:rounded-[2.5rem] shadow-sm border border-slate-50 dark:border-gray-800 flex flex-col sm:flex-row items-center gap-4 sm:gap-6 group hover:shadow-xl transition-all text-center sm:text-left">
                    <div className="p-4 sm:p-5 bg-slate-50 dark:bg-gray-800 text-primary rounded-[1.5rem] transition-colors group-hover:bg-primary group-hover:text-white"><CustomersIcon className="w-6 h-6 sm:w-7 sm:h-7" /></div>
                    <div className="min-w-0"><p className="text-[8px] sm:text-[9px] font-black uppercase tracking-widest text-slate-400">Clients</p><p className="text-2xl sm:text-4xl font-black text-slate-900 dark:text-white tracking-tighter mt-1 tabular-nums leading-none">{customers?.length || 0}</p></div>
                </div>
                <div className="bg-white dark:bg-gray-900 p-6 sm:p-8 rounded-[2rem] sm:rounded-[2.5rem] shadow-sm border border-slate-50 dark:border-gray-800 flex flex-col sm:flex-row items-center gap-4 sm:gap-6 group hover:shadow-xl transition-all text-center sm:text-left">
                    <div className="p-4 sm:p-5 bg-slate-50 dark:bg-gray-800 text-primary rounded-[1.5rem] transition-colors group-hover:bg-primary group-hover:text-white"><StaffIcon className="w-6 h-6 sm:w-7 sm:h-7" /></div>
                    <div className="min-w-0"><p className="text-[8px] sm:text-[9px] font-black uppercase tracking-widest text-slate-400">Personnel</p><p className="text-2xl sm:text-4xl font-black text-slate-900 dark:text-white tracking-tighter mt-1 tabular-nums leading-none">{users?.length || 0}</p></div>
                </div>
                <div className="bg-white dark:bg-gray-900 p-6 sm:p-8 rounded-[2rem] sm:rounded-[2.5rem] shadow-sm border border-slate-50 dark:border-gray-800 flex flex-col sm:flex-row items-center gap-4 sm:gap-6 group hover:shadow-xl transition-all text-center sm:text-left" title={formatCurrency(todaysSalesSummary.revenue, cs)}>
                    <div className="p-4 sm:p-5 bg-slate-50 dark:bg-gray-800 text-emerald-500 rounded-[1.5rem] transition-colors group-hover:bg-emerald-500 group-hover:text-white"><ReportsIcon className="w-6 h-6 sm:w-7 sm:h-7" /></div>
                    <div className="min-w-0"><p className="text-[8px] sm:text-[9px] font-black uppercase tracking-widest text-slate-400">Syncs</p><p className="text-2xl sm:text-4xl font-black text-slate-900 dark:text-white tracking-tighter mt-1 tabular-nums leading-none">{todaysSalesSummary.count}</p></div>
                </div>
                <div className="bg-white dark:bg-gray-900 p-6 sm:p-8 rounded-[2rem] sm:rounded-[2.5rem] shadow-sm border border-slate-50 dark:border-gray-800 flex flex-col sm:flex-row items-center gap-4 sm:gap-6 group hover:shadow-xl transition-all text-center sm:text-left">
                    <div className="p-4 sm:p-5 bg-slate-50 dark:bg-gray-800 text-amber-500 rounded-[1.5rem] transition-colors group-hover:bg-amber-500 group-hover:text-white"><InventoryIcon className="w-6 h-6 sm:w-7 sm:h-7" /></div>
                    <div className="min-w-0"><p className="text-[8px] sm:text-[9px] font-black uppercase tracking-widest text-slate-400">Quantum</p><p className="text-2xl sm:text-4xl font-black text-slate-900 dark:text-white tracking-tighter mt-1 tabular-nums leading-none">{products?.reduce((s, p) => s + (p?.stock || 0), 0) || 0}</p></div>
                </div>
            </div>

            {/* Corporate Intelligence (Owners/Admins) */}
            {isPrivileged && (
                <div className="space-y-10 sm:space-y-12 pt-10 sm:pt-16 border-t-2 border-slate-50 dark:border-gray-800 animate-fade-in px-2">
                    <div className="flex flex-col sm:flex-row items-center gap-6 text-center sm:text-left">
                        <div className="bg-slate-900 text-white p-5 rounded-[2rem] shadow-xl flex-shrink-0"><ReportsIcon className="w-10 h-10" /></div>
                        <div>
                            <h2 className="text-3xl sm:text-4xl font-black text-slate-900 dark:text-white uppercase tracking-tighter">Intelligence Matrix</h2>
                            <p className="text-[8px] sm:text-[10px] font-bold text-slate-400 uppercase tracking-[0.4em] mt-2 sm:mt-3">Advanced Performance Ledger</p>
                        </div>
                    </div>

                    <div className="grid grid-cols-1 lg:grid-cols-2 gap-8 sm:gap-10">
                        {/* Best Sellers */}
                        <div className="bg-white dark:bg-gray-900 rounded-[2.5rem] sm:rounded-[3rem] shadow-xl border border-slate-50 dark:border-gray-800 overflow-hidden">
                            <header className="px-8 sm:px-10 py-6 sm:py-8 border-b dark:border-gray-800 flex justify-between items-center bg-slate-50/30 dark:bg-gray-800/30">
                                <div className="flex items-center gap-4">
                                    <div className="w-1.5 h-1.5 bg-emerald-500 rounded-full"></div>
                                    <h3 className="text-[10px] sm:text-[11px] font-black uppercase tracking-[0.4em] text-slate-900 dark:text-white">Velocity Leaderboard</h3>
                                </div>
                            </header>
                            <div className="table-wrapper border-none rounded-none overflow-x-auto">
                                <table className="w-full text-[10px] sm:text-[11px] text-left">
                                    <thead className="bg-slate-50 dark:bg-gray-900 text-[8px] sm:text-[9px] font-black uppercase tracking-widest text-slate-400">
                                        <tr>
                                            <th className="px-8 sm:px-10 py-5 sm:py-6">Asset ID</th>
                                            <th className="px-8 sm:px-10 py-5 sm:py-6 text-center">Velocity</th>
                                            <th className="px-8 sm:px-10 py-5 sm:py-6 text-right">Inventory</th>
                                        </tr>
                                    </thead>
                                    <tbody className="divide-y divide-slate-50 dark:divide-gray-800">
                                        {(stats.bestSellers || []).slice(0, 5).map((p, i) => (
                                            <tr key={p.id} className="hover:bg-slate-50/50 dark:hover:bg-gray-800/50 transition-colors group">
                                                <td className="px-8 sm:px-10 py-5 sm:py-6 font-black text-slate-900 dark:text-white uppercase truncate max-w-[120px] sm:max-w-[200px]"><span className="text-slate-300 dark:text-slate-600 mr-2 sm:mr-3 group-hover:text-primary transition-colors">{(i+1).toString().padStart(2, '0')}</span>{p.name}</td>
                                                <td className="px-8 sm:px-10 py-5 sm:py-6 text-center font-black text-primary tabular-nums text-base sm:text-lg">{p.unitsSold}</td>
                                                <td className="px-8 sm:px-10 py-5 sm:py-6 text-right font-bold text-slate-400 uppercase tabular-nums">{p.stock}</td>
                                            </tr>
                                        ))}
                                    </tbody>
                                </table>
                            </div>
                        </div>

                        {/* Inventory Risk */}
                        <div className="bg-white dark:bg-gray-900 rounded-[2.5rem] sm:rounded-[3rem] shadow-xl border border-slate-50 dark:border-gray-800 overflow-hidden">
                            <header className="px-8 sm:px-10 py-6 sm:py-8 border-b dark:border-gray-800 flex justify-between items-center bg-slate-50/30 dark:bg-gray-800/30">
                                <div className="flex items-center gap-4">
                                    <div className="w-1.5 h-1.5 bg-rose-500 rounded-full"></div>
                                    <h3 className="text-[10px] sm:text-[11px] font-black uppercase tracking-[0.4em] text-slate-900 dark:text-white">Stagnant Asset Risk</h3>
                                </div>
                            </header>
                            <div className="table-wrapper border-none rounded-none overflow-x-auto">
                                <table className="w-full text-[10px] sm:text-[11px] text-left">
                                    <thead className="bg-slate-50 dark:bg-gray-900 text-[8px] sm:text-[9px] font-black uppercase tracking-widest text-slate-400">
                                        <tr>
                                            <th className="px-8 sm:px-10 py-5 sm:py-6">Asset ID</th>
                                            <th className="px-8 sm:px-10 py-5 sm:py-6 text-center">Velocity</th>
                                            <th className="px-8 sm:px-10 py-5 sm:py-6 text-right">Burn Value</th>
                                        </tr>
                                    </thead>
                                    <tbody className="divide-y divide-slate-50 dark:divide-gray-800">
                                        {(stats.leastSellers || []).slice(0, 5).map((p, i) => (
                                            <tr key={p.id} className="hover:bg-slate-50/50 dark:hover:bg-gray-800/50 transition-colors group" title={formatCurrency(p.stock * p.costPrice, cs)}>
                                                <td className="px-8 sm:px-10 py-5 sm:py-6 font-black text-slate-900 dark:text-white uppercase truncate max-w-[120px] sm:max-w-[200px]"><span className="text-slate-300 dark:text-slate-600 mr-2 sm:mr-3 group-hover:text-rose-500 transition-colors">{(i+1).toString().padStart(2, '0')}</span>{p.name}</td>
                                                <td className="px-8 sm:px-10 py-5 sm:py-6 text-center font-black text-rose-400 tabular-nums text-base sm:text-lg">{p.unitsSold}</td>
                                                <td className="px-8 sm:px-10 py-5 sm:py-6 text-right font-black text-slate-900 dark:text-white tabular-nums text-base sm:text-lg">{cs}{formatAbbreviatedNumber(p.stock * p.costPrice)}</td>
                                            </tr>
                                        ))}
                                    </tbody>
                                </table>
                            </div>
                        </div>
                    </div>
                </div>
            )}

            {isPrivileged && hasAccess(currentUser, 'INVENTORY', 'view_inventory', permissions) && (
                <div className="bg-white dark:bg-gray-900 rounded-[2.5rem] sm:rounded-[3rem] border border-slate-50 dark:border-gray-800 p-8 sm:p-10 shadow-sm relative group overflow-hidden animate-fade-in mx-2">
                    <div className="absolute top-0 right-0 w-32 h-32 bg-rose-500/5 rounded-full -mr-16 -mt-16 blur-2xl"></div>
                    <div className="flex items-center gap-4 sm:gap-5 mb-8 sm:mb-10">
                        <div className="w-2 h-2 rounded-full bg-rose-500 animate-pulse"></div>
                        <h4 className="text-[10px] sm:text-[11px] font-black text-slate-900 dark:text-white uppercase tracking-[0.4em]">Node Supply Violations</h4>
                    </div>
                    {products?.filter(p => p.stock <= lowStockThreshold).length > 0 ? (
                        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4 sm:gap-6">
                            {products.filter(p => p.stock <= lowStockThreshold).slice(0, 6).map(p => (
                                <div key={p.id} className="p-5 sm:p-6 bg-rose-50/30 dark:bg-rose-950/20 border border-rose-100 dark:border-rose-900/30 rounded-2xl sm:rounded-3xl flex justify-between items-center group-hover:shadow-md transition-all">
                                    <span className="text-[9px] sm:text-[10px] font-black text-rose-600 uppercase truncate max-w-[120px] sm:max-w-[150px] tracking-tight">{p.name}</span>
                                    <span className="text-xs sm:text-sm font-black text-rose-700 dark:text-rose-400 tabular-nums">{p.stock} Units</span>
                                </div>
                            ))}
                        </div>
                    ) : (
                        <div className="text-center py-10 sm:py-12 bg-emerald-50/30 dark:bg-emerald-950/10 rounded-[2rem] border border-emerald-100 dark:border-emerald-900/30">
                            <p className="text-[9px] sm:text-[10px] font-black text-emerald-600 uppercase tracking-widest">Supply protocols within safety bounds.</p>
                        </div>
                    )}
                    <NavLink to="/inventory" className="block text-center text-[8px] sm:text-[9px] font-black text-primary uppercase tracking-[0.3em] mt-10 sm:mt-12 hover:underline">Execute Audit Flow →</NavLink>
                </div>
            )}

            {auditUser && (
                <UserDetailModal 
                    isOpen={!!auditUser} onClose={() => setAuditUser(null)} user={auditUser}
                    sales={sales || []} expenses={expenses || []} customers={customers || []}
                    currentUser={currentUser} receiptSettings={receiptSettings}
                    businessProfile={businessProfile} onClockInOut={() => {}}
                />
            )}
            
            {hasAccess(currentUser, 'REPORTS', 'view_sales_reports', permissions) && (
                <div className="lg:col-span-1 mt-10 sm:mt-12 animate-fade-in px-2">
                    <div className="bg-white dark:bg-gray-900 rounded-[2.5rem] sm:rounded-[3rem] shadow-xl border border-slate-50 dark:border-gray-800 p-8 sm:p-10">
                        <div className="flex items-center gap-4 mb-8 sm:mb-10">
                            <div className="w-1.5 h-1.5 bg-primary rounded-full"></div>
                            <h3 className="text-[10px] sm:text-[11px] font-black uppercase tracking-[0.4em] text-slate-900 dark:text-white">Staff Productivity</h3>
                        </div>
                        <div className="space-y-4 sm:space-y-6">
                            {(staffLeaderboard || []).map((member, i) => (
                                <button 
                                    key={member.id} 
                                    onClick={() => setAuditUser(member)}
                                    className="w-full flex items-center justify-between p-5 sm:p-6 bg-slate-50 dark:bg-gray-800 rounded-[1.5rem] sm:rounded-[2rem] hover:shadow-2xl hover:-translate-y-0.5 transition-all text-left border border-transparent hover:border-primary/20 group"
                                >
                                    <div className="flex items-center gap-4 sm:gap-5">
                                        <div className="relative flex-shrink-0">
                                            <img src={member.avatarUrl} className="w-10 h-10 sm:w-12 sm:h-12 rounded-xl sm:rounded-2xl object-cover shadow-sm border-2 border-white dark:border-gray-700" />
                                            <span className="absolute -top-1.5 -left-1.5 w-5 h-5 sm:w-6 sm:h-6 rounded-lg bg-slate-900 text-white flex items-center justify-center text-[7px] sm:text-[9px] font-black group-hover:bg-primary transition-colors">{(i+1).toString().padStart(2, '0')}</span>
                                        </div>
                                        <div className="min-w-0">
                                            <p className="text-xs font-black text-slate-900 dark:text-white uppercase tracking-tight truncate w-32 sm:w-40">{member.name}</p>
                                            <p className="text-[8px] sm:text-[9px] font-bold text-slate-400 uppercase tracking-widest mt-0.5 sm:mt-1">{member.salesCount} Settlements</p>
                                        </div>
                                    </div>
                                    <div className="text-right ml-4" title={formatCurrency(member.totalSalesValue, cs)}>
                                        <p className="text-xs sm:text-sm font-black text-primary tabular-nums">{cs}{formatAbbreviatedNumber(member.totalSalesValue)}</p>
                                        <p className="text-[7px] sm:text-[8px] font-black text-slate-400 uppercase tracking-widest mt-0.5 sm:mt-1">Auth</p>
                                    </div>
                                </button>
                            ))}
                        </div>
                    </div>
                </div>
            )}
        </div>
    );
};

export default Dashboard;
