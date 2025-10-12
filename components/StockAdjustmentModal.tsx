import React, { useState, useEffect } from 'react';
import type { Product } from '../types';

interface StockAdjustmentModalProps {
    isOpen: boolean;
    onClose: () => void;
    onSave: (adjustment: { type: 'add' | 'remove'; quantity: number; reason: string }) => void;
    product: Product | null;
}

const adjustmentReasons = [
    "Stock Count Correction",
    "Damaged Goods",
    "Returned Item",
    "Lost / Stolen",
    "New Shipment Received",
    "Other"
];

const StockAdjustmentModal: React.FC<StockAdjustmentModalProps> = ({ isOpen, onClose, onSave, product }) => {
    const [adjustmentType, setAdjustmentType] = useState<'add' | 'remove'>('add');
    const [quantity, setQuantity] = useState<string | number>(0);
    const [reason, setReason] = useState(adjustmentReasons[0]);
    const [otherReason, setOtherReason] = useState('');

    useEffect(() => {
        if (!isOpen) {
            setAdjustmentType('add');
            setQuantity(0);
            setReason(adjustmentReasons[0]);
            setOtherReason('');
        }
    }, [isOpen]);

    if (!isOpen || !product) return null;

    const handleSubmit = (e: React.FormEvent) => {
        e.preventDefault();
        const numericQuantity = Number(quantity) || 0;
        if (numericQuantity <= 0) {
            alert("Please enter a quantity greater than zero.");
            return;
        }
        if (adjustmentType === 'remove' && numericQuantity > product.stock) {
            alert("Cannot remove more stock than is available.");
            return;
        }

        const finalReason = reason === 'Other' ? otherReason.trim() : reason;
        if (!finalReason) {
            alert("Please provide a reason for the adjustment.");
            return;
        }

        onSave({ type: adjustmentType, quantity: numericQuantity, reason: finalReason });
    };

    return (
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50">
            <div className="bg-white rounded-lg shadow-2xl max-w-lg w-full max-h-[90vh] flex flex-col">
                <header className="p-6 border-b flex-shrink-0">
                    <h2 className="text-2xl font-bold text-gray-800">Adjust Stock</h2>
                    <p className="text-sm text-gray-500">For: {product.name}</p>
                </header>
                <form onSubmit={handleSubmit}>
                    <div className="p-6 space-y-4 overflow-y-auto">
                        <div className="text-center bg-gray-100 p-3 rounded-md">
                            <span className="text-sm font-medium text-gray-600">Current Stock: </span>
                            <span className="text-lg font-bold text-primary">{product.stock} units</span>
                        </div>
                        <div>
                            <label className="block text-sm font-medium text-gray-700">Adjustment Type</label>
                            <div className="mt-2 grid grid-cols-2 gap-3">
                                <label className={`flex items-center justify-center p-3 rounded-md border cursor-pointer ${adjustmentType === 'add' ? 'bg-primary-50 border-primary text-primary' : 'bg-white border-gray-300'}`}>
                                    <input type="radio" name="adjustmentType" value="add" checked={adjustmentType === 'add'} onChange={() => setAdjustmentType('add')} className="sr-only" />
                                    <span className="font-semibold">Add to Stock</span>
                                </label>
                                <label className={`flex items-center justify-center p-3 rounded-md border cursor-pointer ${adjustmentType === 'remove' ? 'bg-red-50 border-red-500 text-red-600' : 'bg-white border-gray-300'}`}>
                                    <input type="radio" name="adjustmentType" value="remove" checked={adjustmentType === 'remove'} onChange={() => setAdjustmentType('remove')} className="sr-only" />
                                    <span className="font-semibold">Remove from Stock</span>
                                </label>
                            </div>
                        </div>
                        <div>
                            <label htmlFor="quantity" className="block text-sm font-medium text-gray-700">Quantity</label>
                            <input
                                type="number"
                                id="quantity"
                                value={quantity}
                                onChange={(e) => setQuantity(e.target.value)}
                                onBlur={(e) => setQuantity(Math.max(0, parseInt(e.target.value, 10) || 0))}
                                min="0"
                                required
                                className="mt-1 block w-full border border-gray-300 rounded-md shadow-sm p-2"
                            />
                        </div>
                        <div>
                            <label htmlFor="reason" className="block text-sm font-medium text-gray-700">Reason</label>
                            <select
                                id="reason"
                                value={reason}
                                onChange={(e) => setReason(e.target.value)}
                                className="mt-1 block w-full border border-gray-300 rounded-md shadow-sm p-2 bg-white"
                            >
                                {adjustmentReasons.map(r => <option key={r} value={r}>{r}</option>)}
                            </select>
                        </div>
                        {reason === 'Other' && (
                            <div>
                                <label htmlFor="otherReason" className="block text-sm font-medium text-gray-700">Please Specify</label>
                                <input
                                    type="text"
                                    id="otherReason"
                                    value={otherReason}
                                    onChange={(e) => setOtherReason(e.target.value)}
                                    required
                                    className="mt-1 block w-full border border-gray-300 rounded-md shadow-sm p-2"
                                    placeholder="e.g., Promotional giveaway"
                                />
                            </div>
                        )}
                    </div>
                    <footer className="p-6 bg-gray-50 rounded-b-lg flex justify-end gap-4 flex-shrink-0">
                        <button type="button" onClick={onClose} className="bg-primary text-white px-4 py-2 rounded-lg font-semibold hover:bg-blue-700 transition-colors">
                            Cancel
                        </button>
                        <button type="submit" className="bg-primary text-white px-4 py-2 rounded-lg font-semibold hover:bg-blue-700 transition-colors">
                            Save Adjustment
                        </button>
                    </footer>
                </form>
            </div>
        </div>
    );
};

export default StockAdjustmentModal;