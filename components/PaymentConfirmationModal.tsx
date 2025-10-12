import React, { useState, useMemo, useEffect } from 'react';
import ReactDOM from 'react-dom';
import type { ReceiptSettingsData } from '../types';
import { formatCurrency } from '../lib/utils';

interface PaymentConfirmationModalProps {
    isOpen: boolean;
    onClose: () => void;
    onConfirm: (paymentDetails: { cashReceived?: number; change?: number }) => void;
    total: number;
    paymentMethod: string | null;
    receiptSettings: ReceiptSettingsData;
}

const PaymentConfirmationModal: React.FC<PaymentConfirmationModalProps> = ({ isOpen, onClose, onConfirm, total, paymentMethod, receiptSettings }) => {
    const [cashReceived, setCashReceived] = useState<string>('');
    const cs = receiptSettings.currencySymbol;

    const parsedCashReceived = useMemo(() => parseFloat(cashReceived), [cashReceived]);
    const isCashPayment = paymentMethod === 'Cash';

    const change = useMemo(() => {
        if (!isCashPayment || isNaN(parsedCashReceived) || parsedCashReceived < total) {
            return 0;
        }
        return parsedCashReceived - total;
    }, [parsedCashReceived, total, isCashPayment]);

    useEffect(() => {
        if (isOpen) {
            // Pre-fill cash received with total for convenience, allowing user to edit
            setCashReceived(total.toFixed(2));
        }
    }, [isOpen, total]);

    const handleConfirm = () => {
        if (isCashPayment) {
            if (isNaN(parsedCashReceived) || parsedCashReceived < total) {
                alert("Cash received must be equal to or greater than the total amount.");
                return;
            }
            onConfirm({ cashReceived: parsedCashReceived, change: change });
        } else {
            onConfirm({});
        }
    };

    const modalRoot = document.getElementById('modal-root');
    if (!isOpen || !modalRoot) return null;

    return ReactDOM.createPortal(
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4" role="dialog" aria-modal="true">
            <div className="bg-white rounded-lg shadow-2xl w-full max-w-sm">
                <header className="p-6 border-b text-center">
                    <h2 className="text-2xl font-bold text-gray-800">Confirm Payment</h2>
                </header>
                <main className="p-6 space-y-4">
                    <div className="text-center">
                        <p className="text-sm font-medium text-gray-500">Total Amount Due</p>
                        <p className="text-5xl font-bold text-primary mt-1">{formatCurrency(total, cs)}</p>
                    </div>

                    {isCashPayment && (
                        <div className="space-y-4 pt-4 border-t">
                            <div>
                                <label htmlFor="cash-received" className="block text-sm font-medium text-gray-700">Cash Received</label>
                                <div className="mt-1 relative rounded-md shadow-sm">
                                    <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                                        <span className="text-gray-500 sm:text-sm">{cs}</span>
                                    </div>
                                    <input
                                        type="number"
                                        name="cash-received"
                                        id="cash-received"
                                        value={cashReceived}
                                        onChange={(e) => setCashReceived(e.target.value)}
                                        className="focus:ring-primary focus:border-primary block w-full pl-7 pr-12 sm:text-lg border-gray-300 rounded-md py-2 text-center font-semibold"
                                        placeholder="0.00"
                                        step="0.01"
                                        min={total.toFixed(2)}
                                        autoFocus
                                    />
                                </div>
                            </div>
                            <div className="flex justify-between items-center bg-gray-50 p-3 rounded-md">
                                <span className="text-lg font-medium text-gray-700">Change Due:</span>
                                <span className="text-2xl font-bold text-green-600">{formatCurrency(change, cs)}</span>
                            </div>
                        </div>
                    )}
                </main>
                <footer className="p-4 bg-gray-50 rounded-b-lg flex sm:justify-center">
                    <div className="responsive-btn-group-fill-horizontal sm:flex-row-reverse">
                        <button type="button" onClick={handleConfirm} className="bg-primary text-white hover:bg-blue-700">
                            Confirm Payment
                        </button>
                        <button type="button" onClick={onClose} className="bg-gray-200 text-gray-800 hover:bg-gray-300">
                            Cancel
                        </button>
                    </div>
                </footer>
            </div>
        </div>,
        modalRoot
    );
};

export default PaymentConfirmationModal;