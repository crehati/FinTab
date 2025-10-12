import React, { useMemo, useState } from 'react';
import type { User, CompanyValuation, Sale, Expense, ReceiptSettingsData, Product, BusinessSettingsData } from '../types';
import Card from './Card';
import UserModal from './UserModal';
import ConfirmationModal from './ConfirmationModal';
import { PlusIcon } from '../constants';
import { formatCurrency, formatAbbreviatedNumber } from '../lib/utils';


interface InvestorPageProps {
    users: User[];
    companyValuations: CompanyValuation[];
    sales: Sale[];
    expenses: Expense[];
    products: Product[];
    t: (key: string) => string;
    receiptSettings: ReceiptSettingsData;
    currentUser: User | null;
    onSaveUser: (userData: Omit<User, 'id' | 'avatarUrl'>, isEditing: boolean, existingUserId?: string) => void;
    onDeleteUser: (userId: string) => void;
    businessSettings: BusinessSettingsData;
}

const InfoCard: React.FC<{ title: string; value: string; fullValue?: string; subtext?: string; valueColor?: string }> = ({ title, value, fullValue, subtext, valueColor = 'text-gray-900' }) => (
    <div className="bg-gray-50 p-4 rounded-lg text-center h-full flex flex-col justify-center border" title={fullValue}>
        <p className="text-sm font-medium text-gray-500">{title}</p>
        <p className={`text-2xl font-bold mt-1 ${valueColor}`}>{value}</p>
        {subtext && <p className="text-xs text-gray-400 mt-1">{subtext}</p>}
    </div>
);

const InvestorPage: React.FC<InvestorPageProps> = ({ users, companyValuations, sales, expenses, t, receiptSettings, products, currentUser, onSaveUser, onDeleteUser, businessSettings }) => {
    const [isUserModalOpen, setIsUserModalOpen] = useState(false);
    const [isConfirmModalOpen, setIsConfirmModalOpen] = useState(false);
    const [editingUser, setEditingUser] = useState<User | null>(null);
    const [userToDelete, setUserToDelete] = useState<User | null>(null);
    
    const cs = receiptSettings.currencySymbol;
    const investors = useMemo(() => users.filter(u => u.role === 'Investor' || u.role === 'Owner'), [users]);
    const canManage = currentUser && ['Owner', 'Manager'].includes(currentUser.role);

    // Modal Handlers
    const handleOpenAddModal = () => {
        setEditingUser(null);
        setIsUserModalOpen(true);
    };

    const handleOpenEditModal = (user: User) => {
        setEditingUser(user);
        setIsUserModalOpen(true);
    };

    const handleDeleteClick = (user: User) => {
        setUserToDelete(user);
        setIsConfirmModalOpen(true);
    };

    const handleConfirmDelete = () => {
        if (userToDelete) {
            onDeleteUser(userToDelete.id);
        }
        setIsConfirmModalOpen(false);
        setUserToDelete(null);
    };

    const handleSaveUser = (userData: Omit<User, 'id' | 'avatarUrl'>, isEditing: boolean) => {
        onSaveUser(userData, isEditing, editingUser?.id);
        setIsUserModalOpen(false);
        setEditingUser(null);
    };

    // --- Core Financial Calculations ---

    const totalInitialInvestmentAllInvestors = useMemo(() => 
        investors.reduce((sum, investor) => sum + (investor.initialInvestment || 0), 0),
    [investors]);

    const totalCompanyGrossProfit = useMemo(() => {
        const completedSales = sales.filter(s => s.status === 'completed');
        return completedSales.reduce((totalProfit, sale) => {
            const costOfGoods = sale.items.reduce((cogs, item) => {
                const product = products.find(p => p.id === item.product.id);
                const costPrice = product ? product.costPrice : 0;
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

    return (
        <div className="space-y-8">
            <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
                <Card title="Total Capital Invested">
                    <div className="text-center" title={formatCurrency(totalInitialInvestmentAllInvestors, cs)}>
                        <p className="text-4xl font-bold text-gray-800">{cs}{formatAbbreviatedNumber(totalInitialInvestmentAllInvestors)}</p>
                        <p className="text-sm text-gray-500 mt-2">from {investors.length} investor{investors.length !== 1 ? 's' : ''}</p>
                    </div>
                </Card>
                <Card title="Company Net Profit (All Time)">
                    <div className="space-y-3 text-lg">
                        <div className="flex justify-between" title={formatCurrency(totalCompanyGrossProfit, cs)}>
                            <span className="text-gray-500">Gross Profit from Sales</span>
                            <span className="font-semibold text-green-600">{cs}{formatAbbreviatedNumber(totalCompanyGrossProfit)}</span>
                        </div>
                        <div className="flex justify-between" title={formatCurrency(totalExpenses, cs)}>
                            <span className="text-gray-500">Total Expenses</span>
                            <span className="font-semibold text-red-600">- {cs}{formatAbbreviatedNumber(totalExpenses)}</span>
                        </div>
                        <div className="flex justify-between border-t pt-3 mt-3" title={formatCurrency(totalCompanyNetProfit, cs)}>
                            <span className="font-bold text-gray-800">Net Profit to Distribute</span>
                            <span className={`font-bold text-2xl ${totalCompanyNetProfit >= 0 ? 'text-primary' : 'text-red-700'}`}>{cs}{formatAbbreviatedNumber(totalCompanyNetProfit)}</span>
                        </div>
                    </div>
                </Card>
            </div>

            {investors.map(investor => {
                const initialInvestment = investor.initialInvestment || 0;
                const ownershipPercentage = totalInitialInvestmentAllInvestors > 0 ? (initialInvestment / totalInitialInvestmentAllInvestors) * 100 : 0;
                
                const profitShare = totalCompanyNetProfit * (ownershipPercentage / 100);

                const totalWithdrawn = (investor.withdrawals || [])
                    .filter(w => ['approved', 'paid', 'completed'].includes(w.status))
                    .reduce((sum, w) => sum + w.amount, 0);

                const withdrawableAmount = (profitShare * (businessSettings.investorProfitWithdrawalRate / 100));
                const availableForWithdrawal = Math.max(0, withdrawableAmount - totalWithdrawn);
                
                return (
                    <Card 
                        key={investor.id} 
                        title={investor.name}
                        headerContent={canManage && (
                            <div className="flex items-center gap-4">
                                <button
                                    onClick={() => handleOpenEditModal(investor)}
                                    className="text-sm font-medium text-primary hover:underline"
                                >
                                    Edit
                                </button>
                                {investor.role !== 'Owner' && (
                                <button
                                    onClick={() => handleDeleteClick(investor)}
                                    className="text-sm font-medium text-red-600 hover:underline"
                                >
                                    Delete
                                </button>
                                )}
                            </div>
                        )}
                    >
                        <div className="flex flex-col md:flex-row md:items-center gap-6">
                            <div className="flex-shrink-0 text-center">
                                <img src={investor.avatarUrl} alt={investor.name} className="w-24 h-24 rounded-full object-cover mx-auto shadow-md" />
                                {investor.investmentDate && <p className="mt-2 text-sm text-gray-500">Invested on {new Date(investor.investmentDate).toLocaleDateString()}</p>}
                            </div>
                            <div className="grid grid-cols-2 lg:grid-cols-4 gap-4 w-full">
                                <InfoCard 
                                    title="Initial Investment"
                                    value={`${cs}${formatAbbreviatedNumber(initialInvestment)}`}
                                    fullValue={formatCurrency(initialInvestment, cs)}
                                    subtext={`${ownershipPercentage.toFixed(2)}% of total capital`}
                                />
                                <InfoCard 
                                    title="Net Profit Share Earned"
                                    value={`${cs}${formatAbbreviatedNumber(profitShare)}`}
                                    fullValue={formatCurrency(profitShare, cs)}
                                    valueColor={profitShare >= 0 ? 'text-green-600' : 'text-red-600'}
                                    subtext="Your share of net profit"
                                />
                                <InfoCard 
                                    title="Amount Withdrawn"
                                    value={`${cs}${formatAbbreviatedNumber(totalWithdrawn)}`}
                                    fullValue={formatCurrency(totalWithdrawn, cs)}
                                />
                                <InfoCard 
                                    title="Available to Withdraw"
                                    value={`${cs}${formatAbbreviatedNumber(availableForWithdrawal)}`}
                                    fullValue={formatCurrency(availableForWithdrawal, cs)}
                                    valueColor="text-primary"
                                    subtext={`(${businessSettings.investorProfitWithdrawalRate}% of profit share)`}
                                />
                            </div>
                        </div>
                    </Card>
                );
            })}
            
             {canManage && (
                <button
                    onClick={handleOpenAddModal}
                    className="fixed bottom-24 right-6 md:bottom-10 md:right-10 bg-primary text-white rounded-full p-4 shadow-lg hover:bg-primary-700 transition-transform transform hover:scale-110 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-primary z-20"
                    aria-label="Add new investor"
                >
                    <PlusIcon />
                </button>
            )}

            <UserModal
                isOpen={isUserModalOpen}
                onClose={() => setIsUserModalOpen(false)}
                onSave={handleSaveUser}
                userToEdit={editingUser}
                receiptSettings={receiptSettings}
                defaultRole="Investor"
            />
            <ConfirmationModal
                isOpen={isConfirmModalOpen}
                onClose={() => setIsConfirmModalOpen(false)}
                onConfirm={handleConfirmDelete}
                title="Delete Investor"
                message={`Are you sure you want to remove ${userToDelete?.name} as an investor? This action cannot be undone.`}
            />
        </div>
    );
};

export default InvestorPage;