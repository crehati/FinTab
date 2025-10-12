import React, { useMemo, useState } from 'react';
import { PieChart, Pie, Cell, BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer, LineChart, Line } from 'recharts';
import type { Sale, Product, Expense, ReceiptSettingsData, User, Customer, AppPermissions, OwnerSettings } from '../types';
import Card from './Card';
import { hasAccess } from '../lib/permissions';
import { formatCurrency, formatAbbreviatedNumber } from '../lib/utils';

interface ReportsProps {
    sales: Sale[];
    products: Product[];
    expenses: Expense[];
    customers: Customer[];
    users: User[];
    t: (key: string) => string;
    lowStockThreshold: number;
    setLowStockThreshold: (value: number) => void;
    receiptSettings: ReceiptSettingsData;
    currentUser: User;
    permissions: AppPermissions;
    ownerSettings: OwnerSettings;
}

const LeaderboardList: React.FC<{ title: string, items: {primary: string, secondary: string, secondaryTitle?: string}[] }> = ({ title, items }) => (
    <Card title={title}>
        {items.length > 0 ? (
            <ul className="space-y-3">
                {items.map((item, index) => (
                    <li key={index} className="flex justify-between items-center text-sm py-1 border-b border-gray-100 last:border-b-0">
                        <span className="font-medium text-gray-700">{item.primary}</span>
                        <span className="font-bold text-primary" title={item.secondaryTitle}>{item.secondary}</span>
                    </li>
                ))}
            </ul>
        ) : (
            <p className="text-gray-500 text-sm">No data available for the selected period.</p>
        )}
    </Card>
);

const formatDateForInput = (date: Date | null): string => {
    if (!date) return '';
    return date.toISOString().split('T')[0];
};

const Reports: React.FC<ReportsProps> = ({ sales, products, expenses, customers, users, t, lowStockThreshold, setLowStockThreshold, receiptSettings, currentUser, permissions, ownerSettings }) => {
    const [startDate, setStartDate] = useState<Date | null>(null);
    const [endDate, setEndDate] = useState<Date | null>(null);
    const [activePreset, setActivePreset] = useState<string | null>(null);

    const cs = receiptSettings.currencySymbol;

    const completedSales = useMemo(() => sales.filter(s => s.status === 'completed'), [sales]);

    // Date Filtering Logic
    const filteredSales = useMemo(() => {
        if (!startDate || !endDate) return completedSales;
        const adjustedEndDate = new Date(endDate);
        adjustedEndDate.setHours(23, 59, 59, 999);
        return completedSales.filter(sale => {
            const saleDate = new Date(sale.date);
            return saleDate >= startDate && saleDate <= adjustedEndDate;
        });
    }, [completedSales, startDate, endDate]);

    const filteredExpenses = useMemo(() => {
        if (!startDate || !endDate) return expenses;
        const adjustedEndDate = new Date(endDate);
        adjustedEndDate.setHours(23, 59, 59, 999);
        return expenses.filter(expense => {
            const expenseDate = new Date(expense.date);
            return expenseDate >= startDate && expenseDate <= adjustedEndDate;
        });
    }, [expenses, startDate, endDate]);
    
    const handleSetDateRange = (start: Date, end: Date, preset: string) => {
        setStartDate(start);
        setEndDate(end);
        setActivePreset(preset);
    };

    const handleDatePreset = (preset: string) => {
        const now = new Date();
        let start = new Date(now);
        let end = new Date(now);

        start.setHours(0, 0, 0, 0);
        end.setHours(23, 59, 59, 999);

        switch(preset) {
            case 'today':
                // already set
                break;
            case 'yesterday':
                start.setDate(start.getDate() - 1);
                end.setDate(end.getDate() - 1);
                break;
            case 'this_week':
                start.setDate(start.getDate() - start.getDay());
                end.setDate(start.getDate() + 6);
                break;
            case 'last_week':
                start.setDate(start.getDate() - start.getDay() - 7);
                end.setDate(start.getDate() + 6);
                break;
            case 'this_month':
                start = new Date(now.getFullYear(), now.getMonth(), 1);
                end = new Date(now.getFullYear(), now.getMonth() + 1, 0, 23, 59, 59, 999);
                break;
            case 'last_month':
                start = new Date(now.getFullYear(), now.getMonth() - 1, 1);
                end = new Date(now.getFullYear(), now.getMonth(), 0, 23, 59, 59, 999);
                break;
            case 'this_year':
                start = new Date(now.getFullYear(), 0, 1);
                end = new Date(now.getFullYear(), 11, 31, 23, 59, 59, 999);
                break;
            case 'last_year':
                 start = new Date(now.getFullYear() - 1, 0, 1);
                 end = new Date(now.getFullYear() - 1, 11, 31, 23, 59, 59, 999);
                 break;
        }
        handleSetDateRange(start, end, preset);
    };
    
    const clearFilter = () => {
        setStartDate(null);
        setEndDate(null);
        setActivePreset(null);
    }
    
    const handleManualDateChange = () => {
        setActivePreset(null);
    }

    const presetsCol1 = [
        { label: 'Today', value: 'today' },
        { label: 'This Week', value: 'this_week' },
        { label: 'This Month', value: 'this_month' },
        { label: 'This Year', value: 'this_year' },
    ];
    
    const presetsCol2 = [
        { label: 'Yesterday', value: 'yesterday' },
        { label: 'Last Week', value: 'last_week' },
        { label: 'Last Month', value: 'last_month' },
        { label: 'Last Year', value: 'last_year' },
    ];

    // Financial Summary Calculations
    const totalRevenue = useMemo(() => filteredSales.reduce((sum, sale) => sum + sale.total, 0), [filteredSales]);
    const totalReceipts = useMemo(() => filteredSales.length, [filteredSales]);
    const totalDiscounts = useMemo(() => filteredSales.reduce((sum, sale) => sum + sale.discount, 0), [filteredSales]);
    const totalExpenses = useMemo(() => filteredExpenses.reduce((sum, expense) => sum + expense.amount, 0), [filteredExpenses]);
    
    const grossProfit = useMemo(() => {
        const totalRevenueFromItems = filteredSales.reduce((sum, sale) => sum + sale.subtotal, 0);
        const totalCOGS = filteredSales.reduce((sum, sale) => {
            const saleCOGS = sale.items.reduce((cogs, item) => cogs + (item.product.costPrice * item.quantity), 0);
            return sum + saleCOGS;
        }, 0);
        return totalRevenueFromItems - totalDiscounts - totalCOGS;
    }, [filteredSales, totalDiscounts]);
    
    const netProfit = useMemo(() => grossProfit - totalExpenses, [grossProfit, totalExpenses]);

    // Sales Analysis Calculations
    const salesOverTime = useMemo(() => {
        const salesByDate: { [key: string]: number } = {};
        filteredSales.forEach(sale => {
            const date = new Date(sale.date).toLocaleDateString();
            if (!salesByDate[date]) {
                salesByDate[date] = 0;
            }
            salesByDate[date] += sale.total;
        });
        return Object.entries(salesByDate)
            .map(([date, total]) => ({ date, total }))
            .sort((a, b) => new Date(a.date).getTime() - new Date(b.date).getTime());
    }, [filteredSales]);
    
    const paymentModes = useMemo(() => {
        if (filteredSales.length === 0) return [];
        const modeCounts = filteredSales.reduce((acc, sale) => {
            const method = sale.paymentMethod || 'Unknown';
            acc[method] = (acc[method] || 0) + 1;
            return acc;
        }, {} as Record<string, number>);
        return Object.entries(modeCounts).map(([name, value]) => ({ name, value }));
    }, [filteredSales]);

    const soldBy = useMemo(() => {
        // FIX: Explicitly typed the accumulator `acc` to resolve property access errors.
        const staffSales = filteredSales.reduce((acc: Record<string, number>, sale) => {
            const user = users.find(u => u.id === sale.userId);
            if (!user) return acc;
            
            if (user.role === 'Owner' && ownerSettings && !ownerSettings.showOnLeaderboard) {
                return acc; // Skip owner if setting is off
            }

            const name = user.name;
            acc[name] = (acc[name] || 0) + sale.total;
            return acc;
        }, {});

        return Object.entries(staffSales)
            .map(([name, total]) => ({ name, total: parseFloat(total.toFixed(2)) }))
            .sort((a, b) => b.total - a.total);
    }, [filteredSales, users, ownerSettings]);

    const salesByPaymentMethod = useMemo(() => {
        if (filteredSales.length === 0) return [];
        // FIX: Explicitly typed the accumulator `acc` to resolve property access errors.
        const methods = filteredSales.reduce((acc: Record<string, { count: number; revenue: number; }>, sale) => {
            const method = sale.paymentMethod || 'Other';
            if (!acc[method]) {
                acc[method] = { count: 0, revenue: 0 };
            }
            acc[method].count += 1;
            acc[method].revenue += sale.total;
            return acc;
        }, {});
    
        return Object.entries(methods)
            .map(([name, data]) => ({ name, count: data.count, revenue: data.revenue }))
            .sort((a, b) => b.revenue - a.revenue);
    }, [filteredSales]);

    // Inventory Alert Calculations
    const lowStockProducts = useMemo(() => 
        products.filter(p => p.stock > 0 && p.stock <= lowStockThreshold)
            .sort((a, b) => a.stock - b.stock), 
    [products, lowStockThreshold]);

    const outOfStockProducts = useMemo(() => 
        products.filter(p => p.stock === 0), 
    [products]);

    const allAlertProducts = [...outOfStockProducts, ...lowStockProducts];

    const handleThresholdChange = (e: React.ChangeEvent<HTMLInputElement>) => {
        const value = parseInt(e.target.value, 10);
        if (!isNaN(value) && value >= 0) {
            setLowStockThreshold(value);
        }
    };

    // Leaderboard Calculations
    const topCategories = useMemo(() => {
        const categorySales = filteredSales.reduce((acc, sale) => {
            sale.items.forEach(item => {
                const category = item.product.category || 'Uncategorized';
                acc[category] = (acc[category] || 0) + Number(item.quantity);
            });
            return acc;
        }, {} as Record<string, number>);
        return Object.entries(categorySales)
            .map(([name, quantity]) => ({ name, quantity: Number(quantity) }))
            .sort((a, b) => b.quantity - a.quantity)
            .slice(0, 5)
            .map(item => ({ primary: item.name, secondary: `${item.quantity} units` }));
    }, [filteredSales]);

    const topCustomers = useMemo(() => {
        // FIX: Explicitly typed the accumulator `acc` to resolve property access errors.
        const customerSpending = filteredSales.reduce((acc: Record<string, { name: string; total: number }>, sale) => {
            const customer = customers.find(c => c.id === sale.customerId);
            const id = sale.customerId;
            if (!acc[id]) {
                acc[id] = { name: customer ? customer.name : 'Unknown', total: 0 };
            }
            acc[id].total += sale.total;
            return acc;
        }, {});
        return Object.values(customerSpending)
            .sort((a, b) => b.total - a.total)
            .slice(0, 5)
            .map(item => ({ 
                primary: item.name, 
                secondary: `${cs}${formatAbbreviatedNumber(item.total)}`,
                secondaryTitle: formatCurrency(item.total, cs) 
            }));
    }, [filteredSales, cs, customers]);
    
    const topStock = useMemo(() => 
        [...products].sort((a, b) => b.stock - a.stock)
        .slice(0, 5)
        .map(item => ({ primary: item.name, secondary: `${item.stock} units` })), 
    [products]);

    const COLORS = ['#1E88E5', '#009688', '#f59e0b', '#ef4444', '#3b82f6'];

    return (
        <div className="space-y-6">
            {/* Date Filter */}
            <Card title="Filter Reports">
                <div className="grid grid-cols-1 md:grid-cols-3 gap-6 items-start">
                    {/* Manual Date Selection */}
                    <div className="space-y-4">
                        <h3 className="text-md font-semibold text-gray-700">Custom Date Range</h3>
                        <div>
                            <label htmlFor="start-date" className="block text-sm font-medium text-gray-600">Start Date</label>
                            <input
                                id="start-date"
                                type="date"
                                value={formatDateForInput(startDate)}
                                onChange={e => { setStartDate(new Date(e.target.value)); handleManualDateChange(); }}
                                className="mt-1 block w-full px-3 py-2 bg-white border border-gray-300 rounded-lg shadow-sm text-gray-800"
                            />
                        </div>
                         <div>
                            <label htmlFor="end-date" className="block text-sm font-medium text-gray-600">End Date</label>
                            <input
                                id="end-date"
                                type="date"
                                value={formatDateForInput(endDate)}
                                onChange={e => { setEndDate(new Date(e.target.value)); handleManualDateChange(); }}
                                className="mt-1 block w-full px-3 py-2 bg-white border border-gray-300 rounded-lg shadow-sm text-gray-800"
                            />
                        </div>
                    </div>
                    {/* Presets */}
                    <div className="md:col-span-2 space-y-4">
                        <h3 className="text-md font-semibold text-gray-700">Presets</h3>
                        <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
                             {[...presetsCol1, ...presetsCol2].map(preset => (
                                <button
                                    key={preset.value}
                                    onClick={() => handleDatePreset(preset.value)}
                                    className={`px-3 py-2 text-sm font-medium rounded-lg transition-colors duration-200 ${
                                        activePreset === preset.value
                                            ? 'bg-primary text-white shadow'
                                            : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
                                    }`}
                                >
                                    {preset.label}
                                </button>
                            ))}
                        </div>
                        <div className="flex justify-end pt-2">
                             <button onClick={clearFilter} className="text-sm font-medium text-gray-500 hover:text-primary">Clear Filter</button>
                        </div>
                    </div>
                </div>
            </Card>

            {/* Financial Summary */}
            <Card title="Financial Summary">
                 <div className="grid grid-cols-2 md:grid-cols-4 gap-4 text-center">
                    <div className="p-4 bg-gray-50 rounded-lg" title={formatCurrency(totalRevenue, cs)}>
                        <p className="text-sm text-gray-500">Total Revenue</p>
                        <p className="text-2xl font-bold text-gray-800">{cs}{formatAbbreviatedNumber(totalRevenue)}</p>
                    </div>
                    <div className="p-4 bg-gray-50 rounded-lg" title={formatCurrency(grossProfit, cs)}>
                        <p className="text-sm text-gray-500">Gross Profit</p>
                        <p className={`text-2xl font-bold ${grossProfit >= 0 ? 'text-green-600' : 'text-red-600'}`}>{cs}{formatAbbreviatedNumber(grossProfit)}</p>
                    </div>
                    <div className="p-4 bg-gray-50 rounded-lg" title={formatCurrency(totalExpenses, cs)}>
                        <p className="text-sm text-gray-500">Total Expenses</p>
                        <p className="text-2xl font-bold text-red-600">{cs}{formatAbbreviatedNumber(totalExpenses)}</p>
                    </div>
                    {hasAccess(currentUser, '/reports/net-profit', 'view', permissions) && (
                        <div className="p-4 bg-blue-50 rounded-lg border border-primary" title={formatCurrency(netProfit, cs)}>
                            <p className="text-sm text-primary">Net Profit</p>
                            <p className={`text-2xl font-bold ${netProfit >= 0 ? 'text-primary' : 'text-red-700'}`}>{cs}{formatAbbreviatedNumber(netProfit)}</p>
                        </div>
                    )}
                </div>
                 <div className="mt-4 grid grid-cols-2 md:grid-cols-4 gap-4 text-center">
                     <div className="p-4 bg-gray-50 rounded-lg">
                        <p className="text-sm text-gray-500">Total Receipts</p>
                        <p className="text-2xl font-bold text-gray-800">{totalReceipts}</p>
                    </div>
                      <div className="p-4 bg-gray-50 rounded-lg" title={formatCurrency(totalDiscounts, cs)}>
                        <p className="text-sm text-gray-500">Total Discounts</p>
                        <p className="text-2xl font-bold text-yellow-600">{cs}{formatAbbreviatedNumber(totalDiscounts)}</p>
                    </div>
                </div>
            </Card>

            <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
                <LeaderboardList title="Top Categories by Units Sold" items={topCategories} />
                <LeaderboardList title="Top Customers by Spending" items={topCustomers} />
                <LeaderboardList title="Top Products by Stock" items={topStock} />
            </div>

            {/* Sales Analysis */}
            <Card title="Sales Analysis">
                 <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
                     <div>
                        <h4 className="font-semibold mb-2">Sales Over Time</h4>
                        <div className="h-80">
                            <ResponsiveContainer width="100%" height="100%">
                                <LineChart data={salesOverTime}>
                                    <CartesianGrid strokeDasharray="3 3" />
                                    <XAxis dataKey="date" fontSize={12} />
                                    <YAxis fontSize={12} tickFormatter={(val) => `${cs}${formatAbbreviatedNumber(val as number)}`} />
                                    <Tooltip formatter={(value) => formatCurrency(Number(value), cs)} />
                                    <Line type="monotone" dataKey="total" stroke="#4f46e5" strokeWidth={2} />
                                </LineChart>
                            </ResponsiveContainer>
                        </div>
                    </div>
                     <div>
                        <h4 className="font-semibold mb-2">Sales by Payment Method</h4>
                        <div className="h-80">
                            <ResponsiveContainer width="100%" height="100%">
                                 <BarChart data={salesByPaymentMethod} layout="vertical">
                                    <CartesianGrid strokeDasharray="3 3" />
                                    <XAxis type="number" fontSize={12} tickFormatter={(val) => `${cs}${formatAbbreviatedNumber(val as number)}`} />
                                    <YAxis dataKey="name" type="category" width={100} fontSize={12} />
                                    <Tooltip formatter={(value) => formatCurrency(Number(value), cs)} />
                                    <Bar dataKey="revenue" fill="#10b981" name="Revenue" />
                                </BarChart>
                            </ResponsiveContainer>
                        </div>
                    </div>
                </div>
            </Card>
        </div>
    );
};

export default Reports;