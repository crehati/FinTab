import React, { useMemo, useState } from 'react';
import type { User, Sale, Expense, ReceiptSettingsData, Product, Withdrawal, CompanyValuation, BusinessSettingsData, BusinessProfile } from '../types';
import Card from './Card';
import WithdrawalRequestModal from './WithdrawalRequestModal';
import WithdrawalReceiptModal from './WithdrawalReceiptModal';
import { formatCurrency, formatAbbreviatedNumber } from '../lib/utils';

interface InvestorProfileProps {
    currentUser: User;
    users: User[];
    sales: Sale[];
    expenses: Expense[];
    products: Product[];
    t: (key: string) => string;
    receiptSettings: ReceiptSettingsData;
    companyValuations: CompanyValuation[];
    businessSettings: BusinessSettingsData;
    businessProfile: BusinessProfile | null;
    onRequestWithdrawal: (userId: string, amount: number, source: 'commission' | 'investment') => void;
    onConfirmWithdrawalReceived: (userId: string, withdrawalId: string) => void;
}

const MetricDisplay: React.FC<{ label: string; value: string; fullValue?: string; className?: string }> = ({ label, value, fullValue, className }) => (
    <div className={`bg-gray-50 p-4 rounded-lg border flex justify-between items-center ${className}`} title={fullValue}>
        <span className="text-md font-medium text-gray-600">{label}</span>
        <span className="text-xl font-bold text-gray-800">{value}</span>
    </div>
);

const InvestorProfile: React.FC<InvestorProfileProps> = ({ currentUser, users, sales, expenses, products, t, receiptSettings, businessSettings, businessProfile, onRequestWithdrawal, onConfirmWithdrawalReceived }) => {
    const [isWithdrawalModalOpen, setIsWithdrawalModalOpen] = useState(false);
    const [receiptToShow, setReceiptToShow] = useState<Withdrawal | null>(null);
    const cs = receiptSettings.currencySymbol;
    
    // --- FINANCIAL CALCULATIONS ---
    const investors = useMemo(() => users.filter(u => u.role === 'Investor'), [users]);
    const totalInitialInvestmentAllInvestors = useMemo(() => 
        investors.reduce((sum, investor) => sum + (investor.initialInvestment || 0), 0),
    [investors]);
    
    const totalCompanyGrossProfit = useMemo(() => {
        const completedSales = sales.filter(s => s.status === 'completed');
        return completedSales.reduce((totalProfit, sale) => {
            const costOfGoods = sale.items.reduce((cogs, item) => {
                const productDetails = products.find(p => p.id === item.product.id);
                const costPrice = productDetails ? productDetails.costPrice : 0;
                return cogs + (costPrice * item.quantity);
            }, 0);
            
            const saleRevenue = sale.subtotal - sale.discount;
            const saleProfit = saleRevenue - costOfGoods;
            
            return totalProfit + saleProfit;
        }, 0);
    }, [sales, products]);

    const totalExpenses = useMemo(() =>
        expenses.reduce((sum, expense) => sum + expense.amount, 0),
    [expenses]);

    const totalCompanyNetProfit = useMemo(() => 
        totalCompanyGrossProfit - totalExpenses,
    [totalCompanyGrossProfit, totalExpenses]);

    const initialInvestment = currentUser.initialInvestment || 0;
    const ownershipPercentage = totalInitialInvestmentAllInvestors > 0 ? (initialInvestment / totalInitialInvestmentAllInvestors) * 100 : 0;
    const profitShare = totalCompanyNetProfit * (ownershipPercentage / 100);
    
    const totalWithdrawnAndApproved = useMemo(() =>
        (currentUser.withdrawals || [])
            .filter(w => ['approved', 'paid', 'completed'].includes(w.status) && w.source === 'investment')
            .reduce((sum, w) => sum + w.amount, 0),
    [currentUser.withdrawals]);

    const withdrawableAmount = (profitShare * (businessSettings.investorProfitWithdrawalRate / 100));
    const availableBalance = Math.max(0, withdrawableAmount - totalWithdrawnAndApproved);

    const sortedWithdrawals = useMemo(() => {
        return [...(currentUser.withdrawals || [])]
            .filter(w => w.source === 'investment')
            .sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime());
    }, [currentUser.withdrawals]);


    const getStatusBadge = (status: Withdrawal['status']) => {
        switch (status) {
            case 'pending':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-yellow-100 text-yellow-800">Pending</span>;
            case 'approved':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-blue-100 text-blue-800">Approved</span>;
            case 'paid':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-purple-100 text-purple-800">Paid</span>;
            case 'completed':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-green-100 text-green-800">Completed</span>;
            case 'rejected':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-red-100 text-red-800">Rejected</span>;
            default:
                return null;
        }
    };
    
    const handleRequestSubmit = (amount: number, source: 'commission' | 'investment') => {
        onRequestWithdrawal(currentUser.id, amount, source);
    };

    if (currentUser.role !== 'Investor') {
        return (
            <Card title="Access Denied">
                <p>This page is only available to users with the 'Investor' role.</p>
            </Card>
        );
    }

    return (
        <div className="space-y-6">
            <Card title="My Investment Overview">
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <MetricDisplay label="Total Invested" value={`${cs}${formatAbbreviatedNumber(initialInvestment)}`} fullValue={formatCurrency(initialInvestment, cs)} />
                    <MetricDisplay label="Ownership of Capital" value={`${ownershipPercentage.toFixed(2)}%`} />
                </div>
            </Card>

            <Card title="Financial Overview">
                 <div className="space-y-4">
                    <MetricDisplay label="Net Profit Share Earned" value={`${cs}${formatAbbreviatedNumber(profitShare)}`} fullValue={formatCurrency(profitShare, cs)} />
                    <MetricDisplay label="Total Withdrawn & Approved" value={`${cs}${formatAbbreviatedNumber(totalWithdrawnAndApproved)}`} fullValue={formatCurrency(totalWithdrawnAndApproved, cs)} />
                    <MetricDisplay label="Available to Withdraw" value={`${cs}${formatAbbreviatedNumber(availableBalance)}`} fullValue={formatCurrency(availableBalance, cs)} className="bg-primary-50 border-primary text-primary-800" />
                     <p className="text-xs text-center text-gray-500 pt-2">
                        You can withdraw up to {businessSettings.investorProfitWithdrawalRate}% of your total earned profit share.
                    </p>
                    <button
                        onClick={() => setIsWithdrawalModalOpen(true)}
                        disabled={availableBalance <= 0}
                        className="w-full mt-4 bg-primary text-white py-3 rounded-lg font-semibold hover:bg-blue-700 transition-colors disabled:bg-gray-300 disabled:cursor-not-allowed"
                    >
                        Request Withdrawal
                    </button>
                </div>
            </Card>

            <Card title="Withdrawal History">
                {sortedWithdrawals.length > 0 ? (
                    <div className="space-y-3">
                         {sortedWithdrawals.map((withdrawal) => (
                            <div key={withdrawal.id} className="text-sm p-3 bg-gray-50 rounded-md">
                                <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-2">
                                    <div className="flex-grow">
                                        <div className="flex justify-between items-center">
                                            <p className="font-medium text-gray-600">{new Date(withdrawal.date).toLocaleDateString()}</p>
                                            <span className="font-bold text-red-600 sm:hidden">-{cs}{withdrawal.amount.toFixed(2)}</span>
                                        </div>
                                        <div className="mt-2 flex items-center gap-4">
                                            {withdrawal.status === 'paid' ? (
                                                <div className="flex items-center gap-2">
                                                    {getStatusBadge(withdrawal.status)}
                                                    <span className="text-xs text-purple-800 animate-pulse hidden sm:inline">Awaiting Your Confirmation</span>
                                                </div>
                                            ) : getStatusBadge(withdrawal.status)}
                                        </div>
                                    </div>
                                    <div className="text-right hidden sm:block">
                                         <span className="font-bold text-red-600">-{cs}{withdrawal.amount.toFixed(2)}</span>
                                    </div>
                                </div>
                                {withdrawal.status === 'paid' && (
                                    <div className="mt-3 pt-3 border-t border-gray-200">
                                         <button 
                                            onClick={() => {
                                                onConfirmWithdrawalReceived(currentUser.id, withdrawal.id);
                                                setReceiptToShow({ ...withdrawal, status: 'completed' });
                                            }}
                                            className="w-full sm:w-auto px-3 py-1.5 text-xs font-bold text-white bg-green-500 rounded-md hover:bg-green-600 transition-all shadow transform active:scale-95"
                                        >
                                            Confirm I've Received Payment
                                        </button>
                                    </div>
                                )}
                                 {withdrawal.status === 'completed' && (
                                    <div className="mt-3 pt-3 border-t border-gray-200">
                                         <button 
                                            onClick={() => setReceiptToShow(withdrawal)}
                                            className="w-full sm:w-auto px-3 py-1.5 text-xs font-bold text-primary bg-primary/10 rounded-md hover:bg-primary/20 transition-all"
                                        >
                                            View Receipt
                                        </button>
                                    </div>
                                )}
                            </div>
                        ))}
                         <div className="mt-4 pt-4 border-t text-xs text-gray-600">
                            <p><strong>Info:</strong> Your available balance is your withdrawable profit share minus any withdrawals that are approved for payout or already paid/completed.</p>
                        </div>
                    </div>
                ) : (
                     <p className="text-center text-sm text-gray-500 py-4">You have no withdrawal history.</p>
                )}
            </Card>

             <WithdrawalRequestModal
                isOpen={isWithdrawalModalOpen}
                onClose={() => setIsWithdrawalModalOpen(false)}
                onConfirm={handleRequestSubmit}
                availableBalance={availableBalance}
                currencySymbol={cs}
                source="investment"
            />
            <WithdrawalReceiptModal
                isOpen={!!receiptToShow}
                onClose={() => setReceiptToShow(null)}
                withdrawal={receiptToShow}
                user={currentUser}
                businessProfile={businessProfile}
                receiptSettings={receiptSettings}
            />
        </div>
    );
};

export default InvestorProfile;