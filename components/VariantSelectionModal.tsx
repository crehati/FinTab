import React, { useState, useEffect, useMemo } from 'react';
import type { Product, ProductVariant, ReceiptSettingsData } from '../types';
import { formatCurrency } from '../lib/utils';
import { CloseIcon } from '../constants';

interface VariantSelectionModalProps {
    isOpen: boolean;
    onClose: () => void;
    product: Product | null;
    onConfirm: (product: Product, variant: ProductVariant, quantity: number) => void;
    receiptSettings: ReceiptSettingsData;
}

const VariantSelectionModal: React.FC<VariantSelectionModalProps> = ({ isOpen, onClose, product, onConfirm, receiptSettings }) => {
    const [selectedOptions, setSelectedOptions] = useState<Record<string, string>>({});
    const [quantity, setQuantity] = useState<string | number>(1);

    useEffect(() => {
        if (isOpen) {
            setSelectedOptions({});
            setQuantity(1);
        }
    }, [isOpen]);

    const handleOptionSelect = (optionName: string, value: string) => {
        setSelectedOptions(prev => ({ ...prev, [optionName]: value }));
    };

    const selectedVariant = useMemo(() => {
        if (!product || !product.variants || product.variantOptions?.length !== Object.keys(selectedOptions).length) {
            return null;
        }
        return product.variants.find(variant => 
            variant.attributes.every(attr => selectedOptions[attr.name] === attr.value)
        );
    }, [product, selectedOptions]);

    const handleConfirmClick = () => {
        if (product && selectedVariant) {
            onConfirm(product, selectedVariant, Number(quantity) || 1);
        }
    };

    const handleQuantityChange = (e: React.ChangeEvent<HTMLInputElement>) => {
        const val = e.target.value;
        if (val === '' || /^[0-9]+$/.test(val)) {
            setQuantity(val);
        }
    };
    
    const handleBlur = () => {
        if (!selectedVariant) return;
        const num = parseInt(String(quantity)) || 1;
        setQuantity(Math.max(1, Math.min(selectedVariant.stock, num)));
    };
    
    if (!isOpen || !product) return null;

    return (
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4" onClick={onClose} role="dialog" aria-modal="true">
            <div className="bg-white rounded-2xl shadow-2xl w-full max-w-md" onClick={e => e.stopPropagation()}>
                <header className="p-4 border-b flex justify-between items-center">
                    <h3 className="text-lg font-bold text-gray-800 truncate">{product.name}</h3>
                    <button onClick={onClose} className="p-1 rounded-full text-gray-500 hover:bg-gray-100" aria-label="Close">
                        <CloseIcon />
                    </button>
                </header>
                <main className="p-6 space-y-4">
                    {product.variantOptions?.map(option => (
                        <div key={option.name}>
                            <label className="block text-sm font-medium text-gray-700 mb-2">{option.name}</label>
                            <div className="flex flex-wrap gap-2">
                                {option.values.map(value => (
                                    <button
                                        key={value}
                                        onClick={() => handleOptionSelect(option.name, value)}
                                        className={`px-4 py-2 text-sm font-semibold rounded-full border-2 transition-colors ${
                                            selectedOptions[option.name] === value
                                                ? 'bg-primary border-primary text-white'
                                                : 'bg-white border-gray-300 text-gray-700 hover:border-primary'
                                        }`}
                                    >
                                        {value}
                                    </button>
                                ))}
                            </div>
                        </div>
                    ))}
                    
                    {selectedVariant && (
                        <div className="pt-4 border-t mt-4 space-y-4">
                             <div className="flex items-center justify-between">
                                <span className="text-2xl font-bold text-primary">{formatCurrency(selectedVariant.price, receiptSettings.currencySymbol)}</span>
                                <span className={`text-sm font-semibold ${selectedVariant.stock > 0 ? 'text-green-600' : 'text-red-600'}`}>
                                    {selectedVariant.stock > 0 ? `${selectedVariant.stock} in stock` : 'Out of Stock'}
                                </span>
                            </div>
                            <div>
                                <label htmlFor="quantity-input" className="block text-sm font-medium text-gray-700 mb-2">Quantity</label>
                                <div className="flex items-center justify-center gap-2">
                                    <button onClick={() => setQuantity(q => Math.max(1, (Number(q) || 1) - 1))} className="w-10 h-10 rounded-full border text-xl font-bold text-primary hover:bg-gray-100 disabled:opacity-50" disabled={Number(quantity) <= 1}>-</button>
                                    <input
                                        id="quantity-input"
                                        type="number"
                                        value={quantity}
                                        onChange={handleQuantityChange}
                                        onBlur={handleBlur}
                                        className="w-20 h-10 text-center text-lg font-bold border-gray-300 rounded-lg"
                                        min="1"
                                        max={selectedVariant.stock}
                                    />
                                    <button onClick={() => setQuantity(q => Math.min(selectedVariant.stock, (Number(q) || 0) + 1))} className="w-10 h-10 rounded-full border text-xl font-bold text-primary hover:bg-gray-100 disabled:opacity-50" disabled={Number(quantity) >= selectedVariant.stock}>+</button>
                                </div>
                            </div>
                        </div>
                    )}
                </main>
                <footer className="p-4 bg-gray-50 rounded-b-2xl">
                    <button 
                        onClick={handleConfirmClick} 
                        className="w-full bg-primary text-white py-3 rounded-lg font-semibold hover:bg-blue-700 transition-colors text-lg disabled:bg-gray-400 disabled:cursor-not-allowed"
                        disabled={!selectedVariant || selectedVariant.stock === 0}
                    >
                        {!selectedVariant ? 'Please select options' : selectedVariant.stock === 0 ? 'Out of Stock' : 'Add to Cart'}
                    </button>
                </footer>
            </div>
        </div>
    );
};

export default VariantSelectionModal;