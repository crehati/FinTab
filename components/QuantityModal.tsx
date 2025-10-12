import React, { useState, useMemo, useEffect } from 'react';
import type { Product, CartItem, ReceiptSettingsData } from '../types';
import { formatCurrency } from '../lib/utils';
import { CloseIcon } from '../constants';


const QuantityModal: React.FC<{
    isOpen: boolean;
    onClose: () => void;
    product: Product | null;
    cart: CartItem[];
    onConfirm: (product: Product, quantity: number) => void;
    receiptSettings: ReceiptSettingsData;
}> = ({ isOpen, onClose, product, cart, onConfirm, receiptSettings }) => {
    
    const initialQuantity = useMemo(() => {
        if (!product) return 1;
        const existingItem = cart.find(item => item.product.id === product.id && !item.variant);
        return existingItem ? existingItem.quantity : 1;
    }, [product, cart]);

    const [quantity, setQuantity] = useState<string | number>(initialQuantity);

    useEffect(() => {
        if (isOpen) {
            setQuantity(initialQuantity);
        }
    }, [isOpen, initialQuantity]);

    if (!isOpen || !product) return null;

    const handleIncrement = () => setQuantity(q => Math.min(product.stock, (Number(q) || 0) + 1));
    const handleDecrement = () => setQuantity(q => Math.max(1, (Number(q) || 1) - 1));
    
    const handleInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
        const val = e.target.value;
        if (val === '' || /^[0-9]+$/.test(val)) {
            setQuantity(val);
        }
    };

    const handleBlur = () => {
        const num = parseInt(String(quantity)) || 1;
        setQuantity(Math.max(1, Math.min(product.stock, num)));
    };

    const handleConfirmClick = () => {
        onConfirm(product, Number(quantity) || 1);
    };

    return (
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4" onClick={onClose} role="dialog" aria-modal="true">
            <div className="bg-white rounded-2xl shadow-2xl w-full max-w-xs" onClick={e => e.stopPropagation()}>
                <header className="p-4 border-b flex justify-between items-center">
                    <h3 className="text-lg font-bold text-gray-800 truncate">{product.name}</h3>
                     <button onClick={onClose} className="p-1 rounded-full text-gray-500 hover:bg-gray-100" aria-label="Close">
                        <CloseIcon />
                    </button>
                </header>
                <main className="p-6 text-center">
                    <p className="text-2xl font-bold text-primary mb-4">{formatCurrency(product.price, receiptSettings.currencySymbol)}</p>
                    <label htmlFor="quantity-input" className="block text-sm font-medium text-gray-700 mb-2">Quantity</label>
                    <div className="flex items-center justify-center gap-2">
                        <button onClick={handleDecrement} className="w-12 h-12 rounded-full border text-2xl font-bold text-primary hover:bg-gray-100 transition-colors disabled:opacity-50" disabled={Number(quantity) <= 1}>-</button>
                        <input
                            id="quantity-input"
                            type="number"
                            value={quantity}
                            onBlur={handleBlur}
                            onChange={handleInputChange}
                            className="w-20 h-12 text-center text-xl font-bold border-gray-300 rounded-lg focus:ring-primary focus:border-primary"
                            min="1"
                            max={product.stock}
                            aria-label="Item quantity"
                        />
                        <button onClick={handleIncrement} className="w-12 h-12 rounded-full border text-2xl font-bold text-primary hover:bg-gray-100 transition-colors disabled:opacity-50" disabled={Number(quantity) >= product.stock}>+</button>
                    </div>
                    <p className="text-xs text-gray-500 mt-2">{product.stock} available</p>
                </main>
                <footer className="p-4 bg-gray-50 rounded-b-2xl">
                    <button onClick={handleConfirmClick} className="w-full bg-primary text-white py-3 rounded-lg font-semibold hover:bg-blue-700 transition-colors text-lg">
                        Add to Cart
                    </button>
                </footer>
            </div>
        </div>
    );
};

export default QuantityModal;