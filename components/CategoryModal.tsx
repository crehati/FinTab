
import React, { useState } from 'react';

interface CategoryModalProps {
    isOpen: boolean;
    onClose: () => void;
    categories: string[];
    onAddCategory: (category: string) => void;
}

const CategoryModal: React.FC<CategoryModalProps> = ({ isOpen, onClose, categories, onAddCategory }) => {
    const [newCategory, setNewCategory] = useState('');

    if (!isOpen) return null;

    const handleAdd = (e: React.FormEvent) => {
        e.preventDefault();
        if (newCategory.trim()) {
            onAddCategory(newCategory.trim());
            setNewCategory('');
        }
    };

    return (
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50" role="dialog" aria-modal="true">
            <div className="bg-white rounded-lg shadow-2xl max-w-md w-full m-4">
                <header className="p-6 border-b">
                    <h2 className="text-2xl font-bold text-gray-800">Manage Categories</h2>
                </header>
                <main className="p-6">
                    <div className="mb-6">
                        <h3 className="font-semibold text-gray-700 mb-2">Existing Categories</h3>
                        <div className="max-h-40 overflow-y-auto bg-gray-50 p-3 rounded-md border">
                            {categories.length > 0 ? (
                                <ul className="space-y-1">
                                    {categories.map(cat => <li key={cat} className="text-gray-800 px-2 py-1">{cat}</li>)}
                                </ul>
                            ) : (
                                <p className="text-gray-500 text-sm p-2">No categories added yet.</p>
                            )}
                        </div>
                    </div>
                    <form onSubmit={handleAdd}>
                        <label htmlFor="new-category" className="block text-sm font-medium text-gray-700">Add New Category</label>
                        <div className="mt-1 flex gap-2">
                            <input
                                type="text"
                                id="new-category"
                                value={newCategory}
                                onChange={e => setNewCategory(e.target.value)}
                                className="flex-grow border border-gray-300 rounded-md shadow-sm p-2 bg-white"
                                placeholder="e.g., Bakery"
                            />
                            <button type="submit" className="bg-primary text-white px-4 py-2 rounded-lg font-semibold hover:bg-blue-700 transition-colors">
                                Add
                            </button>
                        </div>
                    </form>
                </main>
                <footer className="p-6 bg-gray-50 rounded-b-lg flex justify-end">
                    <button type="button" onClick={onClose} className="bg-primary text-white px-4 py-2 rounded-lg font-semibold hover:bg-blue-700 transition-colors">
                        Done
                    </button>
                </footer>
            </div>
        </div>
    );
};

export default CategoryModal;
