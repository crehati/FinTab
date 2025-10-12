import React, { useState, useEffect } from 'react';
import { NavLink } from 'react-router-dom';
import type { Expense, ReceiptSettingsData } from '../types';
import Card from './Card';
import { PlusIcon, DeleteIcon, ReportsIcon, LinkIcon } from '../constants';
import ExpenseModal from './ExpenseModal';
import ConfirmationModal from './ConfirmationModal';
import { formatCurrency } from '../lib/utils';

interface ExpensesProps {
    expenses: Expense[];
    setExpenses: React.Dispatch<React.SetStateAction<Expense[]>>;
    t: (key: string) => string;
    receiptSettings: ReceiptSettingsData;
}

const DEFAULT_EXPENSE_CATEGORIES = ['Rent', 'Utilities', 'Supplies', 'Marketing', 'Salaries', 'Staff Payout', 'Investor Payout', 'Staff Payment'];

const Expenses: React.FC<ExpensesProps> = ({ expenses, setExpenses, t, receiptSettings }) => {
    const [isModalOpen, setIsModalOpen] = useState(false);
    const [categories, setCategories] = useState<string[]>(DEFAULT_EXPENSE_CATEGORIES);
    const [isConfirmModalOpen, setIsConfirmModalOpen] = useState(false);
    const [expenseToDelete, setExpenseToDelete] = useState<Expense | null>(null);

    useEffect(() => {
        const uniqueExistingCategories = [...new Set(expenses.map(e => e.category).filter(Boolean))];
        const allCategories = [...new Set([...DEFAULT_EXPENSE_CATEGORIES, ...uniqueExistingCategories])];
        setCategories(allCategories.sort());
    }, [expenses]);

    const sortedExpenses = [...expenses].sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime());

    const handleSaveExpense = (expenseData: Omit<Expense, 'id' | 'date'>) => {
        const newExpense: Expense = {
            ...expenseData,
            id: `exp-${Date.now()}`,
            date: new Date().toISOString(),
        };
        setExpenses(prev => [newExpense, ...prev]);

        const trimmedCategory = expenseData.category.trim();
        if (trimmedCategory && !categories.includes(trimmedCategory)) {
            setCategories(prev => [...prev, trimmedCategory].sort());
        }

        setIsModalOpen(false);
    };

    const handleDeleteClick = (expense: Expense) => {
        setExpenseToDelete(expense);
        setIsConfirmModalOpen(true);
    };

    const handleConfirmDelete = () => {
        if (expenseToDelete) {
            setExpenses(prevExpenses => prevExpenses.filter(exp => exp.id !== expenseToDelete.id));
        }
        setIsConfirmModalOpen(false);
        setExpenseToDelete(null);
    };


    return (
        <>
            <Card 
                title={t('expenses.title')}
                headerContent={
                    <NavLink to="/expenses/reports" className="flex items-center gap-2 text-sm bg-primary text-white px-3 py-1 rounded-lg font-semibold hover:bg-blue-700 transition-colors">
                        <ReportsIcon /> 
                        <span>View Report</span>
                    </NavLink>
                }
            >
                <div className="overflow-x-auto">
                    {/* Desktop Table */}
                    <table className="hidden md:table w-full text-sm text-left text-gray-500">
                        <thead className="text-xs text-gray-700 uppercase bg-gray-50">
                            <tr>
                                <th scope="col" className="px-6 py-3">Date</th>
                                <th scope="col" className="px-6 py-3">Category</th>
                                <th scope="col" className="px-6 py-3">Description</th>
                                <th scope="col" className="px-6 py-3 text-right">Amount</th>
                                <th scope="col" className="px-6 py-3 text-center">Actions</th>
                            </tr>
                        </thead>
                        <tbody>
                            {sortedExpenses.map(expense => {
                                const isAutomated = expense.id.startsWith('exp-wd-') || expense.id.startsWith('exp-cp-') || expense.id.startsWith('exp-req-');
                                return (
                                <tr key={expense.id} className="bg-white border-b hover:bg-gray-50">
                                    <td className="px-6 py-4 text-gray-800">{new Date(expense.date).toLocaleDateString()}</td>
                                    <td className="px-6 py-4">
                                        <span className="px-2 py-1 inline-flex text-xs leading-5 font-semibold rounded-full bg-blue-100 text-blue-800">
                                            {expense.category}
                                        </span>
                                    </td>
                                    <td className="px-6 py-4 text-gray-800 flex items-center gap-2">
                                        {isAutomated && (
                                            <span title="This is an automated expense from a payout or request." className="text-gray-400">
                                                <LinkIcon />
                                            </span>
                                        )}
                                        {expense.description}
                                    </td>
                                    <td className="px-6 py-4 font-semibold text-right text-gray-800">{formatCurrency(expense.amount, receiptSettings.currencySymbol)}</td>
                                    <td className="px-6 py-4 text-center">
                                        <button 
                                            onClick={() => handleDeleteClick(expense)}
                                            className={`p-1 rounded-full transition-colors ${isAutomated ? 'text-gray-300 cursor-not-allowed' : 'text-red-500 hover:text-red-700'}`}
                                            aria-label={`Delete expense: ${expense.description}`}
                                            disabled={isAutomated}
                                            title={isAutomated ? "Automated expenses cannot be deleted" : "Delete expense"}
                                        >
                                            <DeleteIcon />
                                        </button>
                                    </td>
                                </tr>
                            )})}
                             {sortedExpenses.length === 0 && (
                                <tr>
                                    <td colSpan={5} className="text-center py-10">
                                        <p className="text-gray-500">No expenses recorded yet.</p>
                                    </td>
                                </tr>
                            )}
                        </tbody>
                    </table>
                     {/* Mobile Cards */}
                    <div className="md:hidden space-y-3">
                        {sortedExpenses.map(expense => {
                            const isAutomated = expense.id.startsWith('exp-wd-') || expense.id.startsWith('exp-cp-') || expense.id.startsWith('exp-req-');
                            return (
                            <div key={expense.id} className="bg-white p-4 rounded-xl shadow border">
                                <div className="flex justify-between items-start">
                                    <div>
                                        <p className="font-semibold text-gray-800 flex items-center gap-2">
                                            {isAutomated && (
                                                <span title="Automated expense from a payout or request." className="text-gray-400">
                                                    <LinkIcon />
                                                </span>
                                            )}
                                            {expense.description}
                                        </p>
                                        <p className="text-sm text-gray-500">{new Date(expense.date).toLocaleDateString()}</p>
                                        <span className="mt-1 px-2 py-0.5 inline-flex text-xs leading-5 font-semibold rounded-full bg-blue-100 text-blue-800">
                                            {expense.category}
                                        </span>
                                    </div>
                                    <div className="text-right">
                                        <p className="font-semibold text-lg text-red-600">{formatCurrency(expense.amount, receiptSettings.currencySymbol)}</p>
                                        <button 
                                            onClick={() => handleDeleteClick(expense)}
                                            className={`p-1 rounded-full mt-1 ${isAutomated ? 'text-gray-300 cursor-not-allowed' : 'text-red-500 hover:text-red-700'}`}
                                            aria-label={`Delete expense: ${expense.description}`}
                                            disabled={isAutomated}
                                            title={isAutomated ? "Automated expenses cannot be deleted" : "Delete expense"}
                                        >
                                            <DeleteIcon />
                                        </button>
                                    </div>
                                </div>
                            </div>
                        )})}
                        {sortedExpenses.length === 0 && (
                            <div className="text-center py-10">
                                <p className="text-gray-500">No expenses recorded yet.</p>
                            </div>
                        )}
                    </div>
                </div>
            </Card>

            <button
                onClick={() => setIsModalOpen(true)}
                className="fixed bottom-24 right-6 md:bottom-10 md:right-10 bg-primary text-white rounded-full p-4 shadow-lg hover:bg-primary-700 transition-transform transform hover:scale-110 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-primary z-20"
                aria-label="Add new expense"
            >
                <PlusIcon />
            </button>
            
            <ExpenseModal
                isOpen={isModalOpen}
                onClose={() => setIsModalOpen(false)}
                onSave={handleSaveExpense}
                categories={categories}
                receiptSettings={receiptSettings}
            />

            <ConfirmationModal
                isOpen={isConfirmModalOpen}
                onClose={() => setIsConfirmModalOpen(false)}
                onConfirm={handleConfirmDelete}
                title="Delete Expense"
                message={`Are you sure you want to delete the expense "${expenseToDelete?.description}"? This action cannot be undone.`}
            />
        </>
    );
};

export default Expenses;
