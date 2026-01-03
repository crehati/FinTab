import React, { useMemo, useState, useEffect } from 'react';
import type { User, Sale, AttendanceRecord, PerformanceUser, ReceiptSettingsData, CustomPayment, Customer, Withdrawal, BusinessProfile, BusinessSettingsData, Expense } from '../types';
import { formatCurrency, formatAbbreviatedNumber, getStoredItem } from '../lib/utils';
import { FINALIZED_SALE_STATUSES, AIIcon, TransactionIcon, StaffIcon } from '../constants';
import WithdrawalReceiptModal from './WithdrawalReceiptModal';
import PaymentReceiptModal from './PaymentReceiptModal';
import ModalShell from './ModalShell';
// Fix: Import Card to resolve 'Cannot find name Card' error in JSX
import Card from './Card';

interface UserDetailModalProps {
    isOpen: boolean;
    onClose: () => void;
    user: PerformanceUser | null;
    sales: Sale[];
    expenses: Expense[];
    customers: Customer[];
    onClockInOut: (userId: string) => void;
    currentUser: User | null;
    receiptSettings: ReceiptSettingsData;
    businessProfile: BusinessProfile | null;
}

const MetricCard: React.FC<{ title: string; value: string; color?: string; subtext?: string; icon: React.ReactNode }> = ({ title, value, color = 'text-slate-900 dark:text-white', subtext, icon }) => (
    <div className="bg-white dark:bg-gray-900 p-7 rounded-[2.5rem] shadow-sm border border-slate-100 dark:border-gray-800 flex flex-col justify-between transition-all hover:shadow-xl group">
        <div className="flex justify-between items-start mb-6">
            <div className={`p-3 rounded-2xl bg-slate-50 dark:bg-gray-800 text-slate-400 group-hover:text-primary transition-colors`}>{icon}</div>
            <p className="text-[9px] font-black uppercase tracking-[0.3em] text-slate-400 pt-2">{title}</p>
        </div>
        <div>
            <p className={`text-2xl font-black ${color} tracking-tighter tabular-nums leading-none`}>{value}</p>
            {subtext && <p className="text-[10px] font-bold text-slate-400 mt-4 uppercase tracking-widest truncate">{subtext}</p>}
        </div>
    </div>
);

const UserDetailModal: React.FC<UserDetailModalProps> = ({ isOpen, onClose, user, sales, expenses, customers, onClockInOut, currentUser, receiptSettings, businessProfile }) => {
    const [activeTab, setActiveTab] = useState<'audit' | 'attendance' | 'transactions'>('audit');
    const [withdrawalReceiptToShow, setWithdrawalReceiptToShow] = useState<Withdrawal | null>(null);
    const [paymentReceiptToShow, setPaymentReceiptToShow] = useState<CustomPayment | null>(null);
    
    useEffect(() => {
        if (isOpen) setActiveTab('audit');
    }, [isOpen, user]);

    if (!isOpen || !user) return null;
    
    const cs = String(receiptSettings.currencySymbol || '$');
    const isHourly = user.type === 'hourly';
    const isInvestor = user.role === 'Investor' || user.role === 'Owner';
    
    const financialSummary = useMemo(() => {
        if (isInvestor) {
            const bizId = localStorage.getItem('fintab_active_business_id');
            const bizSettings = getStoredItem<any>(`fintab_${bizId}_settings`, { investorDistributionPercentage: 100 });
            const distRate = (bizSettings.investorDistributionPercentage || 100) / 100;

            const allInvestors = getStoredItem<User[]>(`fintab_${bizId}_users`, []).filter(u => (u.role === 'Investor' || u.role === 'Owner') && u.status === 'Active');
            const totalCapital = allInvestors.reduce((sum, inv) => sum + (inv.initialInvestment || 0), 0);
            const stake = user.initialInvestment || 0;
            const sharePercent = totalCapital > 0 ? (stake / totalCapital) : 0;

            const realizedSales = sales.filter(s => FINALIZED_SALE_STATUSES.includes(s.status));
            const lifetimeGrossProfit = realizedSales.reduce((total, sale) => {
                const cogs = sale.items.reduce((sum, item) => sum + ((item.product?.costPrice || 0) * item.quantity), 0);
                return total + (sale.subtotal - sale.discount - cogs);
            }, 0);
            
            const totalExpensesSum = (expenses || []).reduce((s, e) => s + e.amount, 0);
            const lifetimeNetProfit = Math.max(0, lifetimeGrossProfit - totalExpensesSum);

            const earned = lifetimeNetProfit * sharePercent * distRate;
            const withdrawn = (user.withdrawals || [])
                .filter(w => w.status === 'completed' && w.source === 'investment')
                .reduce((sum, w) => sum + w.amount, 0);

            return { earnedCommissions: 0, customTotal: 0, totalEarnings: earned, withdrawnTotal: withdrawn, availableBalance: Math.max(0, earned - withdrawn) };
        }

        const mySales = sales.filter(s => s.userId === user.id && s.status === 'completed');
        const earnedCommissions = mySales.reduce((sum, s) => sum + (Number(s.commission) || 0), 0);
        const customTotal = (user.customPayments || []).filter(p => p.status === 'completed').reduce((sum, p) => sum + p.amount, 0);
        const withdrawnTotal = (user.withdrawals || []).filter(w => w.status === 'completed').reduce((sum, w) => sum + w.amount, 0);
        const totalEarnings = earnedCommissions + customTotal;
        return { earnedCommissions, withdrawnTotal, customTotal, totalEarnings, availableBalance: Math.max(0, totalEarnings - withdrawnTotal) };
    }, [user, sales, expenses, isInvestor]);

    const transactionHistory = useMemo(() => {
        const wds = (user.withdrawals || []).map(w => ({ ...w, txType: 'Withdrawal', displayType: w.source === 'investment' ? 'Dividend Payout' : 'Commission Payout' }));
        const pms = (user.customPayments || []).map(p => ({ ...p, date: p.dateInitiated, txType: 'Payment', displayType: 'Remittance' }));
        return [...wds, ...pms].sort((a, b) => new Date(b.date || (b as any).dateInitiated).getTime() - new Date(a.date || (a as any).dateInitiated).getTime());
    }, [user]);

    const recentSales = sales.filter(sale => sale.userId === user.id && sale.status === 'completed').sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime()).slice(0, 10);

    return (
        <ModalShell
            isOpen={isOpen}
            onClose={onClose}
            title="Personnel Audit Hub"
            description={`Node Identity: ${user.id.toUpperCase()}`}
            maxWidth="max-w-5xl"
        >
            <div className="space-y-10 font-sans">
                {/* Visual Identity Block */}
                <div className="bg-slate-900 rounded-[3rem] p-8 sm:p-10 text-white shadow-2xl relative overflow-hidden border border-white/5">
                    <div className="absolute top-0 right-0 w-64 h-64 bg-primary/20 rounded-full -mr-32 -mt-32 blur-[100px]"></div>
                    <div className="relative flex flex-col sm:flex-row items-center gap-8">
                        <img src={String(user.avatarUrl)} alt="" className="w-24 h-24 sm:w-28 sm:h-28 rounded-[2.5rem] object-cover border-4 border-white/10 shadow-2xl" />
                        <div className="text-center sm:text-left">
                            <h2 className="text-3xl sm:text-5xl font-black uppercase tracking-tighter leading-none">{String(user.name)}</h2>
                            <div className="flex flex-wrap justify-center sm:justify-start items-center gap-4 mt-5">
                                <span className="px-4 py-1 bg-primary text-white text-[10px] font-black rounded-full uppercase tracking-widest shadow-lg">{String(user.role_label || user.role)}</span>
                                <span className="h-4 w-px bg-white/10 hidden sm:block"></span>
                                <p className="text-[10px] font-bold text-slate-400 uppercase tracking-[0.3em]">{user.email}</p>
                            </div>
                        </div>
                    </div>
                </div>

                {/* Local Nav */}
                <div className="flex bg-slate-100 dark:bg-gray-900 p-1.5 rounded-2xl shadow-inner border dark:border-gray-800 overflow-x-auto no-scrollbar">
                    {['audit', 'attendance', 'transactions'].map((tab) => (
                        (tab !== 'attendance' || isHourly) && (
                            <button 
                                key={tab}
                                onClick={() => setActiveTab(tab as any)} 
                                className={`flex-1 py-3 px-6 rounded-xl text-[10px] font-black uppercase tracking-widest transition-all whitespace-nowrap ${activeTab === tab ? 'bg-white dark:bg-gray-800 text-primary shadow-sm' : 'text-slate-400 hover:text-slate-600'}`}
                            >
                                {tab === 'audit' ? 'Quantum Audit' : tab === 'transactions' ? 'Financial Ledger' : tab}
                            </button>
                        )
                    ))}
                </div>

                {activeTab === 'audit' && (
                    <div className="space-y-10 animate-fade-in">
                        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6">
                            <MetricCard title="Lifetime Earned" value={`${cs}${formatAbbreviatedNumber(financialSummary.totalEarnings)}`} color="text-emerald-500" icon={<AIIcon className="w-5 h-5" />} subtext={isInvestor ? "Accrued Dividends" : `${user.salesCount} Settlements`} />
                            <MetricCard title="Total Disbursed" value={`${cs}${formatAbbreviatedNumber(financialSummary.withdrawnTotal)}`} color="text-rose-500" icon={<TransactionIcon className="w-5 h-5" />} subtext="Finalized Payouts" />
                            <MetricCard title="Liquid Balance" value={`${cs}${formatAbbreviatedNumber(financialSummary.availableBalance)}`} color="text-primary" icon={<StaffIcon className="w-5 h-5" />} subtext="Awaiting Authorization" />
                            <MetricCard title="Conversion Avg" value={isInvestor ? `${((financialSummary.totalEarnings / (user.initialInvestment || 1)) * 100).toFixed(1)}%` : `${cs}${formatAbbreviatedNumber(user.salesCount > 0 ? Number(user.totalSalesValue) / Number(user.salesCount) : 0)}`} icon={<AIIcon className="w-5 h-5" />} subtext="Performance Ratio" />
                        </div>

                        <div className="grid grid-cols-1 lg:grid-cols-2 gap-10">
                            {/* Fix: Wrap Activity Stream in imported Card component */}
                            <Card title="Activity Stream" className="rounded-[3rem] border-none shadow-xl">
                                <div className="space-y-4 max-h-[400px] overflow-y-auto custom-scrollbar pr-2">
                                    {recentSales.map(sale => (
                                        <div key={sale.id} className="p-5 bg-slate-50 dark:bg-gray-950 rounded-[2rem] flex justify-between items-center hover:shadow-md transition-all border border-slate-100 dark:border-gray-800">
                                            <div>
                                                <p className="text-[11px] font-black uppercase text-slate-900 dark:text-white tracking-tight">{new Date(sale.date).toLocaleDateString()}</p>
                                                <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest mt-1">LOG #{sale.id.slice(-6).toUpperCase()}</p>
                                            </div>
                                            <div className="text-right">
                                                <p className="text-sm font-black text-primary tabular-nums">{cs}{sale.total.toFixed(2)}</p>
                                                <p className="text-[8px] font-black text-emerald-600 uppercase tracking-widest mt-1">Yield: {cs}{sale.commission?.toFixed(2)}</p>
                                            </div>
                                        </div>
                                    ))}
                                    {recentSales.length === 0 && <p className="text-center py-20 text-[10px] font-black uppercase text-slate-300 tracking-[0.4em]">Zero Activity Logs</p>}
                                </div>
                            </Card>
                            {/* Fix: Wrap Vault Records in imported Card component */}
                            <Card title="Vault Records" className="rounded-[3rem] border-none shadow-xl">
                                <div className="space-y-4 max-h-[400px] overflow-y-auto custom-scrollbar pr-2">
                                    {transactionHistory.slice(0, 10).map((tx, idx) => (
                                        <div key={idx} className="p-5 bg-slate-50 dark:bg-gray-900 rounded-[2rem] flex justify-between items-center border border-slate-100 dark:border-gray-800">
                                            <div>
                                                <p className="text-[10px] font-black uppercase text-slate-900 dark:text-white tracking-widest">{tx.displayType}</p>
                                                <p className="text-[8px] font-bold text-slate-400 uppercase mt-1">{new Date(tx.date || tx.dateInitiated).toLocaleDateString()}</p>
                                            </div>
                                            <p className={`text-sm font-black tabular-nums ${tx.txType === 'Withdrawal' ? 'text-rose-600' : 'text-emerald-600'}`}>
                                                {tx.txType === 'Withdrawal' ? '-' : '+'}{cs}{tx.amount.toFixed(2)}
                                            </p>
                                        </div>
                                    ))}
                                    {transactionHistory.length === 0 && <p className="text-center py-20 text-[10px] font-black uppercase text-slate-300 tracking-[0.4em]">Zero Vault Records</p>}
                                </div>
                            </Card>
                        </div>
                    </div>
                )}

                {activeTab === 'transactions' && (
                    <div className="bg-white dark:bg-gray-900 rounded-[3rem] shadow-xl border border-slate-50 dark:border-gray-800 overflow-hidden animate-fade-in">
                        <div className="overflow-x-auto">
                            <table className="w-full text-sm text-left">
                                <thead className="bg-slate-50 dark:bg-gray-900 text-[10px] font-black uppercase tracking-[0.3em] text-slate-400 border-b dark:border-gray-800">
                                    <tr>
                                        <th className="px-10 py-8">Authorization Date</th>
                                        <th className="px-10 py-8">Protocol Class</th>
                                        <th className="px-10 py-8 text-right">Settlement Value</th>
                                        <th className="px-10 py-8 text-center">Protocol Lifecycle</th>
                                    </tr>
                                </thead>
                                <tbody className="divide-y divide-slate-50 dark:divide-gray-800">
                                    {transactionHistory.map((item, idx) => (
                                        <tr key={idx} className="hover:bg-slate-50/50 transition-colors">
                                            <td className="px-10 py-8 tabular-nums font-bold text-slate-600 dark:text-slate-400 uppercase text-xs">
                                                {new Date(item.date || item.dateInitiated).toLocaleString()}
                                            </td>
                                            <td className="px-10 py-8">
                                                <span className="text-[10px] font-black text-slate-900 dark:text-white uppercase tracking-widest">{item.displayType}</span>
                                            </td>
                                            <td className={`px-10 py-8 text-right font-black text-lg tabular-nums ${item.txType === 'Withdrawal' ? 'text-rose-600' : 'text-emerald-600'}`}>
                                                {item.txType === 'Withdrawal' ? '-' : '+'}{cs}{item.amount.toFixed(2)}
                                            </td>
                                            <td className="px-10 py-8 text-center">
                                                <span className={`px-3 py-1 rounded-lg text-[8px] font-black uppercase tracking-widest border ${item.status === 'completed' ? 'bg-emerald-50 text-emerald-600 border-emerald-100' : 'bg-amber-50 text-amber-600 border-amber-100'}`}>
                                                    {item.status.replace(/_/g, ' ')}
                                                </span>
                                            </td>
                                        </tr>
                                    ))}
                                </tbody>
                            </table>
                        </div>
                    </div>
                )}
            </div>
        </ModalShell>
    );
};

export default UserDetailModal;
