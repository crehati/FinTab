import React, { useState } from 'react';
import type { Product, ReceiptSettingsData } from '../types';
import Card from './Card';
import { formatCurrency } from '../lib/utils';

interface CommissionProps {
    products: Product[];
    setProducts: React.Dispatch<React.SetStateAction<Product[]>>;
    t: (key: string) => string;
    receiptSettings: ReceiptSettingsData;
}

const Commission: React.FC<CommissionProps> = ({ products, setProducts, t, receiptSettings }) => {
    const [editingState, setEditingState] = useState<{ id: string | null; value: string }>({ id: null, value: '' });

    const handleCommissionChange = (productId: string, newCommission: number) => {
        const commission = Math.max(0, newCommission); // Ensure commission is not negative
        setProducts(prevProducts =>
            prevProducts.map(p =>
                p.id === productId ? { ...p, commissionPercentage: commission } : p
            )
        );
    };

    const handleEditClick = (product: Product) => {
        setEditingState({ id: product.id, value: String(product.commissionPercentage) });
    };

    const handleCancelClick = () => {
        setEditingState({ id: null, value: '' });
    };

    const handleSaveClick = (productId: string) => {
        const newCommission = parseFloat(editingState.value);
        if (!isNaN(newCommission)) {
            handleCommissionChange(productId, newCommission);
        }
        setEditingState({ id: null, value: '' });
    };

    return (
        <Card title={t('commission.title')}>
            <p className="mb-4 text-sm text-gray-600">
                Set the commission rate for each product. This rate will be used to calculate staff earnings on completed sales after any discounts are applied.
            </p>
            <div className="overflow-x-auto">
                {/* Desktop Table */}
                <table className="hidden md:table w-full text-sm text-left text-gray-500">
                    <thead className="text-xs text-gray-700 uppercase bg-gray-50">
                        <tr>
                            <th scope="col" className="px-6 py-3">Product</th>
                            <th scope="col" className="px-6 py-3">Price</th>
                            <th scope="col" className="px-6 py-3" style={{ width: '300px' }}>Commission Rate (%)</th>
                        </tr>
                    </thead>
                    <tbody>
                        {products.map(product => (
                            <tr key={product.id} className="bg-white border-b hover:bg-gray-50">
                                <th scope="row" className="px-6 py-4 font-medium text-gray-900 whitespace-nowrap flex items-center">
                                    <img src={product.imageUrl} alt={product.name} className="w-10 h-10 rounded-lg mr-3 object-cover" />
                                    {product.name}
                                </th>
                                <td className="px-6 py-4 text-gray-800">{formatCurrency(product.price, receiptSettings.currencySymbol)}</td>
                                <td className="px-6 py-4">
                                    {editingState.id === product.id ? (
                                        <div className="flex items-center gap-2">
                                            <div className="relative">
                                                <input
                                                    type="number"
                                                    value={editingState.value}
                                                    onChange={(e) => setEditingState({ ...editingState, value: e.target.value })}
                                                    className="w-24 pl-3 pr-8 py-2 border border-primary rounded-md shadow-sm focus:ring-primary focus:border-primary"
                                                    autoFocus
                                                    onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); handleSaveClick(product.id); } if (e.key === 'Escape') handleCancelClick(); }}
                                                    min="0"
                                                    step="0.1"
                                                />
                                                <div className="absolute inset-y-0 right-0 pr-3 flex items-center pointer-events-none">
                                                    <span className="text-gray-500 sm:text-sm">%</span>
                                                </div>
                                            </div>
                                            <button onClick={() => handleSaveClick(product.id)} className="text-sm font-semibold text-green-600 hover:text-green-800">Save</button>
                                            <button onClick={handleCancelClick} className="text-sm font-semibold text-gray-500 hover:text-gray-700">Cancel</button>
                                        </div>
                                    ) : (
                                        <div className="flex items-center justify-start gap-4 h-[42px]">
                                            <span className="font-medium text-gray-800">{product.commissionPercentage}%</span>
                                            <button onClick={() => handleEditClick(product)} className="text-sm font-medium text-primary hover:underline">Edit</button>
                                        </div>
                                    )}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
                {/* Mobile Cards */}
                <div className="md:hidden space-y-3">
                    {products.map(product => (
                        <div key={product.id} className="bg-white p-4 rounded-xl shadow border">
                            <div className="flex items-center gap-4">
                                <img src={product.imageUrl} alt={product.name} className="w-16 h-16 rounded-lg object-cover" />
                                <div className="flex-grow">
                                    <p className="font-semibold text-gray-800">{product.name}</p>
                                    <p className="text-sm text-gray-500">{formatCurrency(product.price, receiptSettings.currencySymbol)}</p>
                                </div>
                            </div>
                            <div className="mt-3 pt-3 border-t">
                                <label className="text-sm font-medium text-gray-700">Commission Rate (%)</label>
                                {editingState.id === product.id ? (
                                    <div className="flex items-center gap-2 mt-1">
                                        <input
                                            type="number"
                                            value={editingState.value}
                                            onChange={(e) => setEditingState({ ...editingState, value: e.target.value })}
                                            className="w-24 px-2 py-1 border border-primary rounded-md shadow-sm"
                                            autoFocus
                                            min="0" step="0.1"
                                        />
                                        <button onClick={() => handleSaveClick(product.id)} className="text-sm font-semibold text-green-600 hover:text-green-800">Save</button>
                                        <button onClick={handleCancelClick} className="text-sm font-semibold text-gray-500 hover:text-gray-700">Cancel</button>
                                    </div>
                                ) : (
                                    <div className="flex items-center gap-4 mt-1">
                                        <span className="font-medium text-gray-800">{product.commissionPercentage}%</span>
                                        <button onClick={() => handleEditClick(product)} className="text-sm font-medium text-primary hover:underline">Edit</button>
                                    </div>
                                )}
                            </div>
                        </div>
                    ))}
                </div>
                {products.length === 0 && (
                    <div className="text-center py-10">
                        <p className="text-gray-500">No products found. Add products in the inventory page first.</p>
                    </div>
                )}
            </div>
        </Card>
    );
};

export default Commission;