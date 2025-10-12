import React, { useMemo } from 'react';
import type { Sale, Customer, ReceiptSettingsData, Expense, Product } from '../types';
import Card from './Card';
import { formatCurrency, formatAbbreviatedNumber } from '../lib/utils';

interface TodayProps {
    sales: Sale[];
    customers: Customer[];
    expenses: Expense[];
    products: Product[];
    t: (key: string) => string;
    receiptSettings: ReceiptSettingsData;
}

const Today: React.FC<TodayProps> = ({ sales, customers, expenses, products, t, receiptSettings }) => {
    const today = new Date();
    const todayString = today.toISOString().split('T')[0];

    const todaysSales = useMemo(() => 
        sales.filter(sale => 
            new Date(sale.date).toISOString().startsWith(todayString) && sale.status === 'completed'
        ).sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime()), 
    [sales, todayString]);

    const todaysRevenue = useMemo(() => 
        todaysSales.reduce((sum, sale) => sum + sale.total, 0),
    [todaysSales]);
    
    const todaysGrossProfit = useMemo(() => {
        // FIX: Explicitly typed `totalProfit` to resolve type inference errors.
        return todaysSales.reduce((totalProfit: number, sale) => {
            const saleRevenue = sale.subtotal - sale.discount;
            // FIX: Explicitly typed the accumulator 'cogs' as a number to resolve an arithmetic operation error.
            const costOfGoodsSold = sale.items.reduce((cogs: number, item) => {
                // FIX: Look up product from the main products list to ensure costPrice is up-to-date.
                const product = products.find(p => p.id === item.product.id);
                const costPrice = product ? product.costPrice : 0;
                return cogs + (costPrice * item.quantity);
            }, 0);
            return totalProfit + (saleRevenue - costOfGoodsSold);
        }, 0);
    }, [todaysSales, products]);

    const todaysExpenses = useMemo(() =>
        expenses
            .filter(expense => new Date(expense.date).toISOString().startsWith(todayString))
            .reduce((sum, expense) => sum + expense.amount, 0),
    [expenses, todayString]);

    const todaysNewCustomers = useMemo(() => 
        customers.filter(c => new Date(c.joinDate).toISOString().startsWith(todayString)).length,
    [customers, todayString]);
    
    const todaysDiscounts = useMemo(() =>
        todaysSales.reduce((sum, sale) => sum + sale.discount, 0),
    [todaysSales]);

    const topTodaysProducts = useMemo(() => {
        // FIX: Explicitly typed the accumulator `acc` to resolve an arithmetic operation error.
        const productQuantities = todaysSales.reduce((acc: Record<string, number>, sale) => {
            sale.items.forEach(item => {
                acc[item.product.id] = (acc[item.product.id] || 0) + item.quantity;
            });
            return acc;
        }, {});

        return Object.entries(productQuantities)
            .sort(([, qtyA], [, qtyB]) => qtyB - qtyA)
            .slice(0, 3) // Top 3 products
            .map(([productId, quantity]) => {
                const product = products.find(p => p.id === productId);
                return {
                    name: product ? product.name : 'Unknown Product',
                    quantity,
                };
            });
    }, [todaysSales, products]);

    const topTodaysCategory = useMemo(() => {
        if (todaysSales.length === 0) {
            return null;
        }
        // FIX: Explicitly typed the accumulator `acc` to resolve an arithmetic operation error.
        const categoryQuantities = todaysSales.reduce((acc: Record<string, number>, sale) => {
            sale.items.forEach(item => {
                const product = products.find(p => p.id === item.product.id);
                if (product) {
                    const category = product.category || 'Uncategorized';
                    acc[category] = (acc[category] || 0) + item.quantity;
                }
            });
            return acc;
        }, {});

        const topCategoryEntry = Object.entries(categoryQuantities).sort(([, qtyA], [, qtyB]) => qtyB - qtyA)[0];

        if (!topCategoryEntry) {
            return null;
        }

        return {
            name: topCategoryEntry[0],
            quantity: topCategoryEntry[1]
        };
    }, [todaysSales, products]);

    const StatCard: React.FC<{ title: string; value: string; fullValue?: string; colorClass?: string }> = ({ title, value, fullValue, colorClass = 'text-primary' }) => (
        <div className="bg-white p-4 rounded-xl shadow-md text-center" title={fullValue}>
            <p className="text-sm text-neutral-medium">{title}</p>
            <p className={`text-3xl font-bold mt-1 ${colorClass}`}>{value}</p>
        </div>
    );

    return (
        <div className="space-y-6">
            <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
                <StatCard title="Revenue" value={`${receiptSettings.currencySymbol}${formatAbbreviatedNumber(todaysRevenue)}`} fullValue={formatCurrency(todaysRevenue, receiptSettings.currencySymbol)} colorClass="text-success" />
                <StatCard title="Gross Profit" value={`${receiptSettings.currencySymbol}${formatAbbreviatedNumber(todaysGrossProfit)}`} fullValue={formatCurrency(todaysGrossProfit, receiptSettings.currencySymbol)} colorClass="text-green-500" />
                <StatCard title="Expenses" value={`${receiptSettings.currencySymbol}${formatAbbreviatedNumber(todaysExpenses)}`} fullValue={formatCurrency(todaysExpenses, receiptSettings.currencySymbol)} colorClass="text-error" />
                <StatCard title="New Customers" value={todaysNewCustomers.toString()} />
                <StatCard title="Discounts" value={`${receiptSettings.currencySymbol}${formatAbbreviatedNumber(todaysDiscounts)}`} fullValue={formatCurrency(todaysDiscounts, receiptSettings.currencySymbol)} colorClass="text-warning" />
            </div>
            
            <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
                <div className="md:col-span-2">
                    <Card title={`Today's Sales (${todaysSales.length})`}>
                        {todaysSales.length > 0 ? (
                            <div className="overflow-x-auto max-h-96">
                                <table className="w-full text-sm">
                                    <thead className="text-xs text-neutral-medium uppercase bg-neutral-light sticky top-0">
                                        <tr>
                                            <th className="px-4 py-2 text-left">Time</th>
                                            <th className="px-4 py-2 text-left">Customer</th>
                                            <th className="px-4 py-2 text-right">Total</th>
                                        </tr>
                                    </thead>
                                    <tbody className="divide-y divide-gray-200">
                                        {todaysSales.map(sale => {
                                            const customer = customers.find(c => c.id === sale.customerId);
                                            return (
                                                <tr key={sale.id}>
                                                    <td className="px-4 py-3 whitespace-nowrap">{new Date(sale.date).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</td>
                                                    <td className="px-4 py-3">{customer?.name || 'N/A'}</td>
                                                    <td className="px-4 py-3 text-right font-semibold">{formatCurrency(sale.total, receiptSettings.currencySymbol)}</td>
                                                </tr>
                                            );
                                        })}
                                    </tbody>
                                </table>
                            </div>
                        ) : (
                            <p className="text-center text-neutral-medium py-10">No sales recorded yet today.</p>
                        )}
                    </Card>
                </div>
                <div className="space-y-6">
                    <Card title="Top Products Today">
                        {topTodaysProducts.length > 0 ? (
                            <ul className="space-y-3">
                                {topTodaysProducts.map(p => (
                                    <li key={p.name} className="flex justify-between items-center text-sm pb-2 border-b last:border-b-0">
                                        <span className="font-medium text-neutral-dark truncate pr-2">{p.name}</span>
                                        <span className="font-bold text-primary flex-shrink-0">{p.quantity} units</span>
                                    </li>
                                ))}
                            </ul>
                        ) : (
                            <p className="text-center text-sm text-neutral-medium py-4">No products sold yet today.</p>
                        )}
                    </Card>
                    <Card title="Top Category Today">
                        {topTodaysCategory ? (
                            <div className="text-center">
                                <p className="text-2xl font-bold text-primary">{topTodaysCategory.name}</p>
                                <p className="text-neutral-medium mt-1">{topTodaysCategory.quantity} units sold</p>
                            </div>
                        ) : (
                            <p className="text-center text-sm text-neutral-medium py-4">No top category today.</p>
                        )}
                    </Card>
                </div>
            </div>
        </div>
    );
};

export default Today;