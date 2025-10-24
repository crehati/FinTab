import React, { useMemo, useState } from 'react';
import { NavLink } from 'react-router-dom';
import type { Product, Customer, User, ReceiptSettingsData, Sale, Deposit, CustomPayment, ExpenseRequest, OwnerSettings, BusinessSettingsData, Expense, AppPermissions, BusinessProfile } from '../types';
import Card from './Card';
import { CustomersIcon, InventoryIcon, StaffIcon, InvestorIcon, WarningIcon, CloseIcon, AIIcon, LinkIcon } from '../constants';
import { formatCurrency, formatAbbreviatedNumber } from '../lib/utils';
import RequestsDashboard from './RequestsDashboard';
import StaffPaymentManager from './StaffPaymentManager';
import { hasAccess } from '../lib/permissions';

const OwnerGreeting: React.FC<{ currentUser: User; sales: Sale[]; users: User[] }> = ({ currentUser, sales, users }) => {
    const todayString = new Date().toISOString().split('T')[0];
    const todaysRevenue = sales
        .filter(s => new Date(s.date).toISOString().startsWith(todayString) && s.status === 'completed')
        .reduce((sum, s) => sum + s.total, 0);

    const pendingPayouts = (currentUser.withdrawals || []).filter(w => w.status === 'approved').length +
                           (currentUser.customPayments || []).filter(p => p.status === 'approved_by_user').length;

    return (
        <div className="bg-white dark:bg-gray-800 p-6 rounded-xl shadow-md flex flex-col gap-4">
            <div className="flex items-center gap-4">
                <div className="bg-primary/10 text-primary p-3 rounded-full">
                    <AIIcon />
                </div>
                <div>
                    <h2 className="text-2xl font-bold text-neutral-dark dark:text-gray-100">Welcome back, {currentUser.name.split(' ')[0]} 👋</h2>
                    <p className="text-neutral-medium dark:text-gray-400">
                        Your store earned <span className="font-bold text-success" title={formatCurrency(todaysRevenue, '$')}>{`$${formatAbbreviatedNumber(todaysRevenue)}`}</span> today, and you have <span className="font-bold text-warning">{pendingPayouts}</span> pending payout(s).
                    </p>
                </div>
            </div>
            <div className="flex flex-col sm:flex-row gap-2">
                <NavLink to="/today" className="flex-1 text-center bg-primary/10 text-primary font-semibold py-2 px-4 rounded-lg hover:bg-primary/20 transition-colors">💰 View Today’s Sales</NavLink>
                <NavLink to="/users" className="flex-1 text-center bg-primary/10 text-primary font-semibold py-2 px-4 rounded-lg hover:bg-primary/20 transition-colors">👥 Manage Staff</NavLink>
                <NavLink to="/profile" className="flex-1 text-center bg-primary/10 text-primary font-semibold py-2 px-4 rounded-lg hover:bg-primary/20 transition-colors">🧾 View Investment Summary</NavLink>
            </div>
        </div>
    );
};


interface DashboardProps {
    products: Product[];
    customers: Customer[];
    users: User[];
    t: (key: string) => string;
    receiptSettings: ReceiptSettingsData;
    lowStockThreshold: number;
    sales: Sale[];
    expenses: Expense[];
    deposits: Deposit[];
    currentUser: User;
    permissions: AppPermissions;
    onUpdateWithdrawalStatus: (userId: string, withdrawalId: string, status: 'approved' | 'rejected') => void;
    onUpdateDepositStatus: (depositId: string, status: 'approved' | 'rejected') => void;
    onApproveSale: (saleId: string) => void;
    onRejectSale: (saleId: string) => void;
    onMarkWithdrawalPaid: (userId: string, withdrawalId: string) => void;
    onApproveClientOrder: (saleId: string) => void;
    onRejectClientOrder: (saleId: string) => void;
    handleInitiateCustomPayment: (targetUserId: string, amount: number, description: string) => void;
    handleUpdateCustomPaymentStatus: (targetUserId: string, paymentId: string, status: CustomPayment['status']) => void;
    expenseRequests: ExpenseRequest[];
    onUpdateExpenseRequestStatus: (requestId: string, status: 'approved' | 'rejected') => void;
    ownerSettings: OwnerSettings;
    businessSettings: BusinessSettingsData;
    businessProfile: BusinessProfile | null;
}

const MetricCard: React.FC<{ title: string; value: string; fullValue?: string; subtext?: string; icon: React.ReactNode; }> = ({ title, value, fullValue, subtext, icon }) => (
    <div className="bg-white dark:bg-gray-800 p-6 rounded-xl shadow-md flex items-center" title={fullValue}>
        <div className="p-3 bg-primary/10 text-primary rounded-lg">
            {icon}
        </div>
        <div className="ml-4">
            <p className="text-sm font-medium text-neutral-medium dark:text-gray-400">{title}</p>
            <p className="text-2xl font-bold text-neutral-dark dark:text-gray-100">{value}</p>
            {subtext && <p className="text-xs text-neutral-medium dark:text-gray-500">{subtext}</p>}
        </div>
    </div>
);

const Dashboard: React.FC<DashboardProps> = (props) => {
    const { 
        products, customers, users, t, receiptSettings, lowStockThreshold,
        sales, deposits, currentUser, permissions, onUpdateWithdrawalStatus, onUpdateDepositStatus,
        onApproveSale, onRejectSale, onMarkWithdrawalPaid, onApproveClientOrder, onRejectClientOrder,
        handleInitiateCustomPayment, handleUpdateCustomPaymentStatus, expenseRequests, onUpdateExpenseRequestStatus,
        ownerSettings, businessSettings, expenses, businessProfile
    } = props;
    const cs = receiptSettings.currencySymbol;
    const [isLowStockAlertVisible, setIsLowStockAlertVisible] = useState(true);
    const [copySuccess, setCopySuccess] = useState('');
    const shopfrontUrl = businessProfile ? `${window.location.origin}${window.location.pathname}#/public-shopfront/${businessProfile.id}` : '';

    const handleCopyLink = () => {
        if (!shopfrontUrl) return;
        navigator.clipboard.writeText(shopfrontUrl).then(() => {
            setCopySuccess('Copied!');
            setTimeout(() => setCopySuccess(''), 2000);
        }, () => {
            alert('Failed to copy link.');
        });
    };

    const { lowStockProducts, outOfStockProducts } = useMemo(() => {
        const lowStock = products.filter(p => p.stock > 0 && p.stock <= lowStockThreshold);
        const outOfStock = products.filter(p => p.stock === 0);
        return { lowStockProducts: lowStock, outOfStockProducts: outOfStock };
    }, [products, lowStockThreshold]);

    const totalCustomers = useMemo(() => customers.length, [customers]);
    const totalProducts = useMemo(() => products.length, [products]);
    const totalStockUnits = useMemo(() => products.reduce((sum, p) => sum + p.stock, 0), [products]);
    const totalStaff = useMemo(() => users.filter(u => u.role !== 'Investor' && u.role !== 'Owner').length, [users]);
    const totalInvestors = useMemo(() => users.filter(u => u.role === 'Investor').length, [users]);

    const stockValueCost = useMemo(() => 
        products.reduce((sum, p) => sum + (p.stock * p.costPrice), 0), 
    [products]);

    const stockValueSelling = useMemo(() => 
        products.reduce((sum, p) => sum + (p.stock * p.price), 0), 
    [products]);

    const potentialProfit = useMemo(() => stockValueSelling - stockValueCost, [stockValueSelling, stockValueCost]);

    const transactionsByPaymentMethod = useMemo(() => {
        const completedSales = sales.filter(s => s.status === 'completed');
        // FIX: Use a generic type argument for `reduce` to correctly type the accumulator.
        const stats = completedSales.reduce<Record<string, { count: number; total: number }>>((acc, sale) => {
            const method = sale.paymentMethod || 'Other';
            if (!acc[method]) {
                acc[method] = { count: 0, total: 0 };
            }
            acc[method].count += 1;
            acc[method].total += sale.total;
            return acc;
        }, {});

        return Object.entries(stats).map(([name, data]) => ({
            name,
            count: data.count,
            total: data.total,
        })).sort((a, b) => b.total - a.total);
    }, [sales]);

    const canManageUsers = useMemo(() => hasAccess(currentUser, '/users', 'edit', permissions), [currentUser, permissions]);
    
    const canManageRequests = useMemo(() => {
        if (!currentUser || !permissions) return false;
        return (
            canManageUsers || // for withdrawals
            hasAccess(currentUser, '/expense-requests', 'edit', permissions) ||
            hasAccess(currentUser, '/proforma', 'edit', permissions) ||
            hasAccess(currentUser, '/receipts', 'edit', permissions) ||
            hasAccess(currentUser, '/transactions', 'edit', permissions)
        );
    }, [currentUser, permissions, canManageUsers]);

    // --- Owner Specific Calculations ---
    const ownerPerformance = useMemo(() => {
        if (currentUser.role !== 'Owner') return null;
        const ownerSales = sales.filter(s => s.userId === currentUser.id && s.status === 'completed');
        const totalCommission = ownerSales.reduce((sum, s) => sum + (s.commission || 0), 0);
        const totalWithdrawals = (currentUser.withdrawals || []).filter(w => ['approved', 'paid', 'completed'].includes(w.status)).reduce((sum, w) => sum + w.amount, 0);
        return { totalCommission, totalWithdrawals, availableCommission: totalCommission - totalWithdrawals };
    }, [currentUser, sales]);

    const ownerInvestment = useMemo(() => {
        if (currentUser.role !== 'Owner' || !currentUser.initialInvestment) return null;
        const allInvestorsAndOwner = users.filter(u => u.role === 'Investor' || u.role === 'Owner');
        const totalCapital = allInvestorsAndOwner.reduce((sum, u) => sum + (u.initialInvestment || 0), 0);
        const ownership = totalCapital > 0 ? (currentUser.initialInvestment / totalCapital) * 100 : 0;
        const totalNetProfit = sales.filter(s => s.status === 'completed').reduce((profit, sale) => {
            const cogs = sale.items.reduce((sum, item) => sum + (item.product.costPrice * item.quantity), 0);
            return profit + (sale.subtotal - sale.discount - cogs);
        }, 0) - expenses.reduce((sum, e) => sum + e.amount, 0);

        const profitShare = totalNetProfit * (ownership / 100);
        return { ownership, profitShare };
    }, [currentUser, users, sales, expenses]);


    return (
        <div className="space-y-6">
            {currentUser.role === 'Owner' && <OwnerGreeting currentUser={currentUser} sales={sales} users={users} />}
            
            {/* Low Stock Alert */}
            {(lowStockProducts.length > 0 || outOfStockProducts.length > 0) && isLowStockAlertVisible && (
                <div className="bg-yellow-50 dark:bg-yellow-900/50 border-l-4 border-yellow-400 dark:border-yellow-500 p-4 rounded-r-lg shadow-md flex justify-between items-center" role="alert">
                    <div className="flex items-center">
                        <div className="flex-shrink-0 text-yellow-500 dark:text-yellow-400">
                            <WarningIcon />
                        </div>
                        <div className="ml-3">
                            <p className="text-sm font-medium text-yellow-800 dark:text-yellow-200">
                                Inventory Alert
                            </p>
                            <div className="text-sm text-yellow-700 dark:text-yellow-300 mt-1">
                                {lowStockProducts.length > 0 && (
                                    <span>You have <strong>{lowStockProducts.length}</strong> item(s) low on stock. </span>
                                )}
                                {outOfStockProducts.length > 0 && (
                                    <span>You have <strong>{outOfStockProducts.length}</strong> item(s) out of stock. </span>
                                )}
                                <NavLink to="/inventory" className="ml-2 font-semibold underline hover:text-yellow-900 dark:hover:text-yellow-100">
                                    View Items
                                </NavLink>
                            </div>
                        </div>
                    </div>
                    <button onClick={() => setIsLowStockAlertVisible(false)} className="p-1 rounded-full text-yellow-500 dark:text-yellow-300 hover:bg-yellow-100 dark:hover:bg-yellow-800/60" aria-label="Dismiss inventory alert">
                        <CloseIcon />
                    </button>
                </div>
            )}

            {hasAccess(currentUser, '/settings/business', 'edit', permissions) && businessProfile && (
                <Card title="Your Public Shopfront">
                    <div className="grid grid-cols-1 md:grid-cols-2 gap-6 items-center">
                        <div className="space-y-3">
                            <div>
                                <label htmlFor="shopfront-url" className="block text-sm font-medium text-neutral-dark dark:text-gray-300">Your unique shopfront link</label>
                                <div className="mt-1 flex rounded-md shadow-sm">
                                    <input
                                        id="shopfront-url"
                                        type="text"
                                        readOnly
                                        value={shopfrontUrl}
                                        className="flex-1 min-w-0 block w-full px-3 py-2 rounded-none rounded-l-md bg-gray-100 dark:bg-gray-700 border-gray-300 dark:border-gray-600 text-gray-500 dark:text-gray-400"
                                    />
                                    <button
                                        onClick={handleCopyLink}
                                        className="inline-flex items-center px-4 py-2 border border-l-0 border-gray-300 dark:border-gray-600 rounded-r-md bg-gray-50 dark:bg-gray-700/50 text-sm font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-600"
                                    >
                                        {copySuccess || 'Copy Link'}
                                    </button>
                                </div>
                            </div>
                            <NavLink to="/settings/business" className="text-sm font-medium text-primary hover:underline">
                                Go to Business Settings to manage visibility →
                            </NavLink>
                        </div>
                        <div className="bg-neutral-light/60 dark:bg-gray-700/50 p-4 rounded-lg border dark:border-gray-600 text-center space-y-2">
                            <h4 className="font-semibold text-neutral-dark dark:text-gray-200">Shop Status</h4>
                            <div className="flex justify-center gap-4 flex-wrap">
                                <span className={`px-2 py-1 text-xs font-semibold rounded-full ${businessProfile.isPublic ? 'bg-green-100 text-green-800 dark:bg-green-900/50 dark:text-green-300' : 'bg-red-100 text-red-800 dark:bg-red-900/50 dark:text-red-300'}`}>
                                    {businessProfile.isPublic ? 'Publicly Listed' : 'Not Listed'}
                                </span>
                                <span className={`px-2 py-1 text-xs font-semibold rounded-full ${businessSettings.acceptRemoteOrders ? 'bg-green-100 text-green-800 dark:bg-green-900/50 dark:text-green-300' : 'bg-red-100 text-red-800 dark:bg-red-900/50 dark:text-red-300'}`}>
                                    {businessSettings.acceptRemoteOrders ? 'Accepting Orders' : 'Not Accepting Orders'}
                                </span>
                            </div>
                        </div>
                    </div>
                </Card>
            )}

            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
                <MetricCard 
                    title="Total Customers" 
                    value={totalCustomers.toString()} 
                    icon={<CustomersIcon />} 
                />
                <MetricCard 
                    title="Total Staff" 
                    value={totalStaff.toString()} 
                    icon={<StaffIcon />} 
                />
                <MetricCard 
                    title="Total Investors" 
                    value={totalInvestors.toString()} 
                    icon={<InvestorIcon />} 
                />
                <MetricCard 
                    title="Unique Items" 
                    value={totalProducts.toString()} 
                    subtext={`${totalStockUnits} units in stock`}
                    icon={<InventoryIcon />} 
                />
                 <MetricCard 
                    title="Shopfront Items" 
                    value={totalProducts.toString()} 
                    subtext="Number of items available for sale"
                    icon={<InventoryIcon />} 
                />
            </div>
            
            {currentUser.role === 'Owner' && (ownerSettings.commissionTrackingEnabled || ownerInvestment) && (
                 <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                    {ownerSettings.commissionTrackingEnabled && ownerPerformance && (
                        <Card title="Owner's Commission Summary">
                             <div className="space-y-3">
                                <div className="flex justify-between items-center p-3 bg-gray-50 rounded-lg" title={formatCurrency(ownerPerformance.totalCommission, cs)}>
                                    <span className="font-medium text-gray-600">Total Earned</span>
                                    <span className="font-bold text-lg text-green-600">{cs}{formatAbbreviatedNumber(ownerPerformance.totalCommission)}</span>
                                </div>
                                <div className="flex justify-between items-center p-3 bg-gray-50 rounded-lg" title={formatCurrency(ownerPerformance.availableCommission, cs)}>
                                    <span className="font-medium text-gray-600">Available Balance</span>
                                    <span className="font-bold text-lg text-primary">{cs}{formatAbbreviatedNumber(ownerPerformance.availableCommission)}</span>
                                </div>
                            </div>
                        </Card>
                    )}
                    {ownerInvestment && (
                        <Card title="Owner's Investment Overview">
                            <div className="space-y-3">
                                <div className="flex justify-between items-center p-3 bg-gray-50 rounded-lg">
                                    <span className="font-medium text-gray-600">Ownership</span>
                                    <span className="font-bold text-lg text-neutral-dark">{ownerInvestment.ownership.toFixed(2)}%</span>
                                </div>
                                <div className="flex justify-between items-center p-3 bg-gray-50 rounded-lg" title={formatCurrency(ownerInvestment.profitShare, cs)}>
                                    <span className="font-medium text-gray-600">Net Profit Share</span>
                                    <span className={`font-bold text-lg ${ownerInvestment.profitShare >= 0 ? 'text-green-600' : 'text-red-600'}`}>{cs}{formatAbbreviatedNumber(ownerInvestment.profitShare)}</span>
                                </div>
                            </div>
                        </Card>
                    )}
                </div>
            )}


            <Card title="Transactions by Payment Method">
                {transactionsByPaymentMethod.length > 0 ? (
                    <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
                        {transactionsByPaymentMethod.map((method) => (
                            <div key={method.name} className="bg-neutral-light/60 dark:bg-gray-700 p-4 rounded-lg border border-neutral-light dark:border-gray-600" title={formatCurrency(method.total, cs)}>
                                <p className="font-semibold text-neutral-dark dark:text-gray-200">{method.name}</p>
                                <p className="text-2xl font-bold text-primary mt-1">{cs}{formatAbbreviatedNumber(method.total)}</p>
                                <p className="text-sm text-neutral-medium dark:text-gray-400">{method.count} transaction{method.count !== 1 ? 's' : ''}</p>
                            </div>
                        ))}
                    </div>
                ) : (
                    <p className="text-center text-neutral-medium dark:text-gray-400 py-4">No completed transactions found.</p>
                )}
            </Card>

            {canManageRequests && (
                <Card title="Action Center">
                    <RequestsDashboard 
                        users={users}
                        sales={sales}
                        deposits={deposits}
                        expenseRequests={expenseRequests}
                        receiptSettings={receiptSettings}
                        onUpdateWithdrawalStatus={onUpdateWithdrawalStatus}
                        onUpdateDepositStatus={onUpdateDepositStatus}
                        onUpdateExpenseRequestStatus={onUpdateExpenseRequestStatus}
                        onApproveSale={onApproveSale}
                        onRejectSale={onRejectSale}
                        onMarkWithdrawalPaid={onMarkWithdrawalPaid}
                        onApproveClientOrder={onApproveClientOrder}
                        onRejectClientOrder={onRejectClientOrder}
                        customers={customers}
                        t={t}
                        currentUser={currentUser}
                        permissions={permissions}
                    />
                </Card>
            )}

            {canManageUsers && (
                 <Card title="Staff Payment Management">
                    <StaffPaymentManager
                        users={users}
                        receiptSettings={receiptSettings}
                        handleInitiateCustomPayment={handleInitiateCustomPayment}
                        handleUpdateCustomPaymentStatus={handleUpdateCustomPaymentStatus}
                    />
                </Card>
            )}

             <Card title="Inventory Valuation">
                <div className="grid grid-cols-1 md:grid-cols-3 gap-4 text-center">
                    <div className="p-4 bg-red-50 dark:bg-red-900/30 rounded-lg border border-red-200 dark:border-red-800" title={formatCurrency(stockValueCost, cs)}>
                        <p className="text-sm text-red-700 dark:text-red-300">Stock Value (Cost)</p>
                        <p className="text-2xl font-bold text-red-900 dark:text-red-200">{cs}{formatAbbreviatedNumber(stockValueCost)}</p>
                    </div>
                    <div className="p-4 bg-green-50 dark:bg-green-900/30 rounded-lg border border-green-200 dark:border-green-800" title={formatCurrency(stockValueSelling, cs)}>
                        <p className="text-sm text-green-700 dark:text-green-300">Stock Value (Selling)</p>
                        <p className="text-2xl font-bold text-green-900 dark:text-green-200">{cs}{formatAbbreviatedNumber(stockValueSelling)}</p>
                    </div>
                     <div className="p-4 bg-blue-50 dark:bg-blue-900/30 rounded-lg border border-primary dark:border-blue-800" title={formatCurrency(potentialProfit, cs)}>
                        <p className="text-sm text-primary dark:text-blue-300">Potential Profit</p>
                        <p className="text-2xl font-bold text-blue-900 dark:text-blue-200">{cs}{formatAbbreviatedNumber(potentialProfit)}</p>
                    </div>
                </div>
            </Card>

        </div>
    );
};

export default Dashboard;