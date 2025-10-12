

import React, { useState, useMemo } from 'react';
import type { Sale, ReceiptSettingsData, User, Customer, PrinterSettingsData } from '../types';
import ReceiptModal from './ReceiptModal';
import { formatCurrency } from '../lib/utils';

interface ReceiptsProps {
    sales: Sale[];
    customers: Customer[];
    users: User[];
    t: (key: string) => string;
    receiptSettings: ReceiptSettingsData;
    onDeleteSale: (saleId: string) => void;
    currentUser: User;
    isTrialExpired: boolean;
    printerSettings: PrinterSettingsData;
}

const Receipts: React.FC<ReceiptsProps> = ({ sales, customers, users, t, receiptSettings, onDeleteSale, currentUser, isTrialExpired, printerSettings }) => {
    const [selectedSale, setSelectedSale] = useState<Sale | null>(null);
    const [startDate, setStartDate] = useState('');
    const [endDate, setEndDate] = useState('');

    const filteredAndSortedSales = useMemo(() => {
        let filteredSales = sales.filter(sale => sale.status !== 'proforma');

        if (startDate) {
            const start = new Date(`${startDate}T00:00:00`);
            filteredSales = filteredSales.filter(sale => new Date(sale.date) >= start);
        }

        if (endDate) {
            const end = new Date(`${endDate}T23:59:59`);
            filteredSales = filteredSales.filter(sale => new Date(sale.date) <= end);
        }

        return filteredSales.sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime());
    }, [sales, startDate, endDate]);
    
    const getStatusBadge = (status: Sale['status']) => {
        switch(status) {
            case 'completed':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-green-100 text-green-800">Completed</span>;
            case 'pending_approval':
                 return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-yellow-100 text-yellow-800">Pending Approval</span>;
            default:
                return null;
        }
    }

    const renderDesktopTable = () => (
        <table className="hidden md:table w-full text-sm text-left text-gray-500">
            <thead className="text-xs text-gray-700 uppercase bg-gray-50">
                <tr>
                    <th scope="col" className="px-6 py-3">Receipts #</th>
                    <th scope="col" className="px-6 py-3">Date</th>
                    <th scope="col" className="px-6 py-3">Customer</th>
                    <th scope="col" className="px-6 py-3">Staff</th>
                    <th scope="col" className="px-6 py-3">Total</th>
                    <th scope="col" className="px-6 py-3">Status</th>
                </tr>
            </thead>
            <tbody>
                {filteredAndSortedSales.map(sale => {
                    const customer = customers.find(c => c.id === sale.customerId);
                    const user = users.find(u => u.id === sale.userId);
                    return (
                        <tr key={sale.id} className={`border-b transition-colors duration-150 ${
                            sale.status === 'pending_approval' ? 'bg-yellow-50 hover:bg-yellow-100' : 'bg-white hover:bg-gray-50'
                        }`}>
                            <td className="px-6 py-4">
                                <button
                                    onClick={() => setSelectedSale(sale)}
                                    className="font-mono text-xs font-semibold text-primary hover:underline"
                                    aria-label={`View receipt ${sale.id.slice(-6).toUpperCase()}`}
                                >
                                    {sale.id.slice(-6).toUpperCase()}
                                </button>
                            </td>
                            <td className="px-6 py-4 text-gray-800">{new Date(sale.date).toLocaleString()}</td>
                            <td className="px-6 py-4 text-gray-800">{customer?.name || 'N/A'}</td>
                            <td className="px-6 py-4 text-gray-800">{user?.name || 'N/A'}</td>
                            <td className="px-6 py-4 font-semibold text-gray-800">{formatCurrency(sale.total, receiptSettings.currencySymbol)}</td>
                            <td className="px-6 py-4">
                                {getStatusBadge(sale.status)}
                            </td>
                        </tr>
                    )
                })}
            </tbody>
        </table>
    );

    const renderMobileCards = () => (
        <div className="md:hidden space-y-3">
            {filteredAndSortedSales.map(sale => {
                const customer = customers.find(c => c.id === sale.customerId);
                return (
                    <div key={sale.id} className={`p-4 rounded-xl shadow-lg border ${
                        sale.status === 'pending_approval' ? 'bg-yellow-50 border-yellow-200' : 'bg-white border-gray-100'
                    }`}>
                        <div className="flex justify-between items-start">
                            <div className="flex-grow">
                                <button
                                    onClick={() => setSelectedSale(sale)}
                                    className="font-mono text-sm font-semibold text-primary hover:underline text-left"
                                    aria-label={`View receipt ${sale.id.slice(-6).toUpperCase()}`}
                                >
                                    #{sale.id.slice(-6).toUpperCase()}
                                </button>
                                <p className="text-gray-800 font-medium mt-1">{customer?.name || 'N/A'}</p>
                                <p className="text-xs text-gray-500 mt-2">
                                    {sale.items.length} {sale.items.length === 1 ? 'item' : 'items'} &bull; {new Date(sale.date).toLocaleString()}
                                </p>
                            </div>
                            <div className="text-right flex-shrink-0 ml-4">
                                <p className="font-bold text-lg text-gray-800">{formatCurrency(sale.total, receiptSettings.currencySymbol)}</p>
                                <div className="mt-1">{getStatusBadge(sale.status)}</div>
                            </div>
                        </div>
                    </div>
                )
            })}
        </div>
    );

    return (
        <>
            <div className="bg-white rounded-lg shadow p-6">
                 <div className="flex flex-col md:flex-row md:justify-between md:items-center mb-4 gap-4">
                    <h2 className="text-xl font-bold text-gray-700 shrink-0">{t('receipts.title')}</h2>
                    <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 w-full md:w-auto">
                        <div>
                            <label htmlFor="start-date" className="block text-sm font-medium text-gray-600">From</label>
                            <input
                                type="date"
                                id="start-date"
                                value={startDate}
                                onChange={(e) => setStartDate(e.target.value)}
                                className="mt-1 block w-full border border-gray-300 rounded-md shadow-sm p-2 text-sm focus:ring-primary focus:border-primary"
                                aria-label="Start date for filtering receipts"
                            />
                        </div>
                        <div>
                            <label htmlFor="end-date" className="block text-sm font-medium text-gray-600">To</label>
                            <input
                                type="date"
                                id="end-date"
                                value={endDate}
                                onChange={(e) => setEndDate(e.target.value)}
                                className="mt-1 block w-full border border-gray-300 rounded-md shadow-sm p-2 text-sm focus:ring-primary focus:border-primary"
                                aria-label="End date for filtering receipts"
                            />
                        </div>
                    </div>
                </div>

                <div className="overflow-x-auto">
                    {filteredAndSortedSales.length > 0 ? (
                        <>
                            {renderDesktopTable()}
                            {renderMobileCards()}
                        </>
                    ) : (
                        <div className="text-center py-10">
                            <p className="text-gray-500">No receipts found for the selected date range.</p>
                        </div>
                    )}
                </div>
            </div>
            {selectedSale && <ReceiptModal sale={selectedSale} customers={customers} users={users} onClose={() => setSelectedSale(null)} receiptSettings={receiptSettings} onDelete={onDeleteSale} currentUser={currentUser} t={t} isTrialExpired={isTrialExpired} printerSettings={printerSettings} />}
        </>
    );
};

export default Receipts;