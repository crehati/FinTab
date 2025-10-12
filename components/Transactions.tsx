import React, { useState, useMemo } from 'react';
import type { Sale, Deposit, User, ReceiptSettingsData } from '../types';
import Card from './Card';
import DepositModal from './DepositModal';
import { PlusIcon } from '../constants';

interface TransactionsProps {
    sales: Sale[];
    deposits: Deposit[];
    users: User[];
    receiptSettings: ReceiptSettingsData;
    currentUser: User;
    onRequestDeposit: (amount: number, description: string) => void;
    t: (key: string) => string;
}

const Transactions: React.FC<TransactionsProps> = ({ sales, deposits, users, receiptSettings, currentUser, onRequestDeposit, t }) => {
    const [isModalOpen, setIsModalOpen] = useState(false);
    const cs = receiptSettings.currencySymbol;

    const totalCashReceived = useMemo(() =>
        sales
            .filter(s => s.paymentMethod === 'Cash' && s.status === 'completed')
            .reduce((sum, sale) => sum + (sale.cashReceived || sale.total), 0),
    [sales]);

    const totalCashDeposited = useMemo(() =>
        deposits
            .filter(d => d.status === 'approved')
            .reduce((sum, d) => sum + d.amount, 0),
    [deposits]);
    
    const cashOnHand = totalCashReceived - totalCashDeposited;
    
    const sortedDepositsWithUser = useMemo(() => {
        return deposits
            .map(deposit => {
                const user = users.find(u => u.id === deposit.userId);
                return { ...deposit, userName: user ? user.name : 'Unknown User' };
            })
            .sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime());
    }, [deposits, users]);

    const getStatusBadge = (status: Deposit['status']) => {
        switch (status) {
            case 'pending':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-yellow-100 text-yellow-800">Pending</span>;
            case 'approved':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-green-100 text-green-800">Approved</span>;
            case 'rejected':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-red-100 text-red-800">Rejected</span>;
            default:
                return null;
        }
    };

    return (
        <>
            <div className="space-y-6">
                <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
                    <Card title="Total Cash Received">
                        <p className="text-3xl font-bold text-gray-800">{cs}{totalCashReceived.toFixed(2)}</p>
                    </Card>
                    <Card title="Total Cash Deposited">
                        <p className="text-3xl font-bold text-gray-800">{cs}{totalCashDeposited.toFixed(2)}</p>
                    </Card>
                    <Card title="Cash on Hand">
                        <p className="text-3xl font-bold text-primary">{cs}{cashOnHand.toFixed(2)}</p>
                    </Card>
                </div>

                <Card title="Deposit History">
                     <div className="overflow-x-auto">
                        {/* Desktop Table */}
                        <table className="hidden md:table w-full text-sm text-left text-gray-500">
                            <thead className="text-xs text-gray-700 uppercase bg-gray-50">
                                <tr>
                                    <th scope="col" className="px-6 py-3">Date</th>
                                    <th scope="col" className="px-6 py-3">Requested By</th>
                                    <th scope="col" className="px-6 py-3">Description</th>
                                    <th scope="col" className="px-6 py-3 text-right">Amount</th>
                                    <th scope="col" className="px-6 py-3 text-center">Status</th>
                                </tr>
                            </thead>
                            <tbody>
                                {sortedDepositsWithUser.map(deposit => (
                                    <tr key={deposit.id} className="bg-white border-b hover:bg-gray-50">
                                        <td className="px-6 py-4">{new Date(deposit.date).toLocaleString()}</td>
                                        <td className="px-6 py-4 font-medium text-gray-900">{deposit.userName}</td>
                                        <td className="px-6 py-4">{deposit.description}</td>
                                        <td className="px-6 py-4 text-right font-semibold">{cs}{deposit.amount.toFixed(2)}</td>
                                        <td className="px-6 py-4 text-center">{getStatusBadge(deposit.status)}</td>
                                    </tr>
                                ))}
                                {sortedDepositsWithUser.length === 0 && (
                                    <tr>
                                        <td colSpan={5} className="text-center py-10 text-gray-500">
                                            No deposit requests have been made.
                                        </td>
                                    </tr>
                                )}
                            </tbody>
                        </table>
                        {/* Mobile Cards */}
                        <div className="md:hidden space-y-3">
                            {sortedDepositsWithUser.map(deposit => (
                                <div key={deposit.id} className="bg-white p-4 rounded-xl shadow border">
                                    <div className="flex justify-between items-start mb-2">
                                        <div>
                                            <p className="font-semibold text-gray-800">{deposit.description}</p>
                                            <p className="text-sm text-gray-500">
                                                {new Date(deposit.date).toLocaleString()} by {deposit.userName}
                                            </p>
                                        </div>
                                        <p className="font-semibold text-lg text-gray-800">{cs}{deposit.amount.toFixed(2)}</p>
                                    </div>
                                    <div className="text-right">
                                        {getStatusBadge(deposit.status)}
                                    </div>
                                </div>
                            ))}
                            {sortedDepositsWithUser.length === 0 && (
                                <div className="text-center py-10">
                                    <p className="text-gray-500">No deposit requests have been made.</p>
                                </div>
                            )}
                        </div>
                    </div>
                </Card>
            </div>
            
             <button
                onClick={() => setIsModalOpen(true)}
                disabled={cashOnHand <= 0}
                className="fixed bottom-24 right-6 md:bottom-10 md:right-10 bg-primary text-white rounded-full p-4 shadow-lg hover:bg-primary-700 transition-transform transform hover:scale-110 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-primary z-20 disabled:bg-gray-400 disabled:cursor-not-allowed"
                aria-label="Make a deposit request"
            >
                <PlusIcon />
            </button>

            <DepositModal
                isOpen={isModalOpen}
                onClose={() => setIsModalOpen(false)}
                onRequestDeposit={onRequestDeposit}
                maxAmount={cashOnHand}
                currencySymbol={cs}
            />
        </>
    );
};

export default Transactions;