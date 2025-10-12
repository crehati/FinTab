import React, { useState, useEffect } from 'react';
import type { ExpenseRequest, ReceiptSettingsData } from '../types';

interface ExpenseRequestModalProps {
    isOpen: boolean;
    onClose: () => void;
    onSave: (requestData: Omit<ExpenseRequest, 'id' | 'date' | 'userId' | 'status'>) => void;
    categories: string[];
    receiptSettings: ReceiptSettingsData;
}

const getInitialFormData = () => ({
    category: '',
    description: '',
    amount: '' as string | number,
});

const ADD_NEW_CATEGORY_VALUE = '__ADD_NEW__';

const ExpenseRequestModal: React.FC<ExpenseRequestModalProps> = ({ isOpen, onClose, onSave, categories, receiptSettings }) => {
    const [formData, setFormData] = useState(getInitialFormData());
    const [isAddingNewCategory, setIsAddingNewCategory] = useState(false);
    const [newCategoryValue, setNewCategoryValue] = useState('');

    useEffect(() => {
        if (isOpen) {
            setFormData(getInitialFormData());
            setIsAddingNewCategory(false);
            setNewCategoryValue('');
        }
    }, [isOpen]);

    const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
        const { name, value } = e.target;
        if (name === 'category' && e.target instanceof HTMLSelectElement) {
            if (value === ADD_NEW_CATEGORY_VALUE) {
                setIsAddingNewCategory(true);
                setFormData(prev => ({ ...prev, category: '' }));
            } else {
                setIsAddingNewCategory(false);
                setFormData(prev => ({ ...prev, category: value }));
            }
        } else {
            setFormData(prev => ({
                ...prev,
                [name]: value,
            }));
        }
    };

    const handleSubmit = (e: React.FormEvent) => {
        e.preventDefault();
        const finalCategory = isAddingNewCategory ? newCategoryValue.trim() : formData.category;
        const numericAmount = parseFloat(String(formData.amount)) || 0;

        if (!finalCategory) {
            alert("Please select or add a category.");
            return;
        }
        if (numericAmount <= 0) {
            alert("Please enter an amount greater than zero.");
            return;
        }
        onSave({ ...formData, category: finalCategory, amount: numericAmount });
        onClose();
    };

    if (!isOpen) return null;

    return (
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4">
            <div className="bg-white rounded-lg shadow-2xl max-w-lg w-full">
                <form onSubmit={handleSubmit}>
                    <div className="p-6 border-b">
                        <h2 className="text-2xl font-bold text-gray-800">Request New Expense</h2>
                    </div>
                    <div className="p-6 space-y-4">
                        <div>
                            <label htmlFor="category" className="block text-sm font-medium text-gray-700">Category</label>
                            <select
                                id="category"
                                name="category"
                                value={isAddingNewCategory ? ADD_NEW_CATEGORY_VALUE : formData.category}
                                onChange={handleChange}
                                required={!isAddingNewCategory}
                                className="mt-1"
                            >
                                <option value="" disabled>Select a category</option>
                                {categories.map(cat => <option key={cat} value={cat}>{cat}</option>)}
                                <option value={ADD_NEW_CATEGORY_VALUE} className="font-bold text-primary">
                                    + Add New Category
                                </option>
                            </select>
                        </div>
                        
                        {isAddingNewCategory && (
                            <div>
                                <label htmlFor="newCategory" className="block text-sm font-medium text-gray-700">New Category Name</label>
                                <input
                                    type="text"
                                    id="newCategory"
                                    value={newCategoryValue}
                                    onChange={(e) => setNewCategoryValue(e.target.value)}
                                    required
                                    className="mt-1"
                                    placeholder="e.g., Office Snacks"
                                />
                            </div>
                        )}
                        <div>
                            <label htmlFor="description" className="block text-sm font-medium text-gray-700">Description</label>
                            <input type="text" name="description" id="description" value={formData.description} onChange={handleChange} required className="mt-1" />
                        </div>
                        <div>
                            <label htmlFor="amount" className="block text-sm font-medium text-gray-700">Amount ({receiptSettings.currencySymbol})</label>
                            <input type="number" name="amount" id="amount" value={formData.amount} onChange={handleChange} required className="mt-1" step="0.01" min="0" />
                        </div>
                    </div>
                    <div className="p-4 bg-gray-50 rounded-b-lg flex sm:justify-center">
                        <div className="responsive-btn-group sm:flex-row-reverse">
                            <button type="submit" className="bg-primary text-white hover:bg-blue-700">
                                Submit Request
                            </button>
                            <button type="button" onClick={onClose} className="bg-gray-200 text-gray-800 hover:bg-gray-300">
                                Cancel
                            </button>
                        </div>
                    </div>
                </form>
            </div>
        </div>
    );
};

export default ExpenseRequestModal;