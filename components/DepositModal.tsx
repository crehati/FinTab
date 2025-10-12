import React, { useState, useEffect } from 'react';

interface DepositModalProps {
    isOpen: boolean;
    onClose: () => void;
    onRequestDeposit: (amount: number, description: string) => void;
    maxAmount: number;
    currencySymbol: string;
}

const DepositModal: React.FC<DepositModalProps> = ({ isOpen, onClose, onRequestDeposit, maxAmount, currencySymbol }) => {
    const [amount, setAmount] = useState('');
    const [description, setDescription] = useState('');
    const [error, setError] = useState('');

    useEffect(() => {
        if (isOpen) {
            setAmount('');
            setDescription('');
            setError('');
        }
    }, [isOpen]);
    
    const handleAmountChange = (e: React.ChangeEvent<HTMLInputElement>) => {
        const value = e.target.value;
        setError('');
        setAmount(value);
    };

    const handleSubmit = (e: React.FormEvent) => {
        e.preventDefault();
        const numericAmount = parseFloat(amount);

        if (isNaN(numericAmount) || numericAmount <= 0) {
            setError('Please enter a valid amount greater than zero.');
            return;
        }
        if (numericAmount > maxAmount) {
            setError(`Amount cannot exceed available cash of ${currencySymbol}${maxAmount.toFixed(2)}.`);
            return;
        }
        if (!description.trim()) {
            setError('Please provide a brief description for the deposit.');
            return;
        }

        onRequestDeposit(numericAmount, description.trim());
        onClose();
    };

    if (!isOpen) return null;

    return (
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4" role="dialog" aria-modal="true">
            <form onSubmit={handleSubmit} className="bg-white rounded-lg shadow-2xl w-full max-w-md">
                <header className="p-6 border-b">
                    <h2 className="text-2xl font-bold text-gray-800">Request Cash Deposit</h2>
                </header>
                <main className="p-6 space-y-4">
                    <div>
                        <p className="text-sm text-gray-600">Available Cash on Hand: <span className="font-bold text-primary">{currencySymbol}{maxAmount.toFixed(2)}</span></p>
                    </div>
                    <div>
                        <label htmlFor="deposit-amount" className="block text-sm font-medium text-gray-700">Deposit Amount</label>
                        <div className="mt-1 relative rounded-md shadow-sm">
                            <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                                <span className="text-gray-500 sm:text-lg">{currencySymbol}</span>
                            </div>
                            <input
                                type="number"
                                id="deposit-amount"
                                value={amount}
                                onChange={handleAmountChange}
                                className="focus:ring-primary focus:border-primary block w-full pl-8 pr-4 sm:text-lg border-gray-300 rounded-md py-2 text-center font-semibold"
                                placeholder="0.00"
                                step="0.01"
                                min="0.01"
                                max={maxAmount.toFixed(2)}
                                autoFocus
                                required
                            />
                        </div>
                    </div>
                     <div>
                        <label htmlFor="description" className="block text-sm font-medium text-gray-700">Description</label>
                        <textarea
                            id="description"
                            value={description}
                            onChange={(e) => setDescription(e.target.value)}
                            rows={3}
                            className="mt-1 block w-full border border-gray-300 rounded-md shadow-sm p-2"
                            placeholder="e.g., Deposit for morning sales"
                            required
                        />
                    </div>
                    {error && <p className="text-sm text-red-600">{error}</p>}
                </main>
                <footer className="p-4 bg-gray-50 rounded-b-lg flex sm:justify-center">
                    <div className="responsive-btn-group sm:flex-row-reverse">
                        <button type="submit" className="bg-primary text-white hover:bg-blue-700">
                            Send Request
                        </button>
                        <button type="button" onClick={onClose} className="bg-gray-200 text-gray-800 hover:bg-gray-300">
                            Cancel
                        </button>
                    </div>
                </footer>
            </form>
        </div>
    );
};

export default DepositModal;