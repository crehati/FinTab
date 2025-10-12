import React, { useState, useMemo, useEffect } from 'react';
import type { ExpenseRequest, User, ReceiptSettingsData, Expense } from '../types';
import Card from './Card';
import { PlusIcon } from '../constants';
import ExpenseRequestModal from './ExpenseRequestModal';
import { formatCurrency } from '../lib/utils';

interface ExpenseRequestPageProps {
    expenseRequests: ExpenseRequest[];
    expenses: Expense[];
    currentUser: User;
    handleRequestExpense: (requestData: Omit<ExpenseRequest, 'id' | 'date' | 'userId' | 'status'>) => void;
    receiptSettings: ReceiptSettingsData;
    t: (key: string) => string;
}

const DEFAULT_EXPENSE_CATEGORIES = ['Rent', 'Utilities', 'Supplies', 'Marketing', 'Salaries'];

const ExpenseRequestPage: React.FC<ExpenseRequestPageProps> = ({ expenseRequests, expenses, currentUser, handleRequestExpense, receiptSettings, t }) => {
    const [isModalOpen, setIsModalOpen] = useState(false);
    const cs = receiptSettings.currencySymbol;

    const myRequests = useMemo(() => 
        expenseRequests
            .filter(req => req.userId === currentUser.id)
            .sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime()),
    [expenseRequests, currentUser.id]);
    
    const expenseCategories = useMemo(() => {
        const uniqueExistingCategories = [...new Set(expenses.map(e => e.category).filter(Boolean))];
        const allCategories = [...new Set([...DEFAULT_EXPENSE_CATEGORIES, ...uniqueExistingCategories])];
        return allCategories.sort();
    }, [expenses]);

    const getStatusBadge = (status: ExpenseRequest['status']) => {
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
            <Card title="My Expense Requests">
                <div className="overflow-x-auto">
                    {/* Desktop Table */}
                    <table className="hidden md:table w-full text-sm text-left text-gray-500">
                        <thead className="text-xs text-gray-700 uppercase bg-gray-50">
                            <tr>
                                <th scope="col" className="px-6 py-3">Date</th>
                                <th scope="col" className="px-6 py-3">Category</th>
                                <th scope="col" className="px-6 py-3">Description</th>
                                <th scope="col" className="px-6 py-3 text-right">Amount</th>
                                <th scope="col" className="px-6 py-3 text-center">Status</th>
                            </tr>
                        </thead>
                        <tbody>
                            {myRequests.map(req => (
                                <tr key={req.id} className="bg-white border-b hover:bg-gray-50">
                                    <td className="px-6 py-4">{new Date(req.date).toLocaleDateString()}</td>
                                    <td className="px-6 py-4">{req.category}</td>
                                    <td className="px-6 py-4">{req.description}</td>
                                    <td className="px-6 py-4 text-right font-semibold">{formatCurrency(req.amount, cs)}</td>
                                    <td className="px-6 py-4 text-center">{getStatusBadge(req.status)}</td>
                                </tr>
                            ))}
                            {myRequests.length === 0 && (
                                <tr>
                                    <td colSpan={5} className="text-center py-10 text-gray-500">
                                        You have not made any expense requests.
                                    </td>
                                </tr>
                            )}
                        </tbody>
                    </table>
                     {/* Mobile Cards */}
                    <div className="md:hidden space-y-3">
                        {myRequests.map(req => (
                            <div key={req.id} className="bg-white p-4 rounded-xl shadow border">
                                <div className="flex justify-between items-start">
                                    <div>
                                        <p className="font-semibold text-gray-800">{req.description}</p>
                                        <p className="text-sm text-gray-500">{new Date(req.date).toLocaleDateString()}</p>
                                    </div>
                                    <p className="font-semibold text-lg text-red-600">{formatCurrency(req.amount, cs)}</p>
                                </div>
                                <div className="flex justify-between items-center mt-2 pt-2 border-t">
                                    <span className="px-2 py-0.5 inline-flex text-xs leading-5 font-semibold rounded-full bg-blue-100 text-blue-800">
                                        {req.category}
                                    </span>
                                    {getStatusBadge(req.status)}
                                </div>
                            </div>
                        ))}
                        {myRequests.length === 0 && (
                            <div className="text-center py-10">
                                <p className="text-gray-500">You have not made any expense requests.</p>
                            </div>
                        )}
                    </div>
                </div>
            </Card>

            <button
                onClick={() => setIsModalOpen(true)}
                className="fixed bottom-24 right-6 md:bottom-10 md:right-10 bg-primary text-white rounded-full p-4 shadow-lg hover:bg-blue-700 transition-transform transform hover:scale-110"
                aria-label="Request New Expense"
            >
                <PlusIcon />
            </button>

            <ExpenseRequestModal
                isOpen={isModalOpen}
                onClose={() => setIsModalOpen(false)}
                onSave={handleRequestExpense}
                categories={expenseCategories}
                receiptSettings={receiptSettings}
            />
        </>
    );
};

export default ExpenseRequestPage;
