
import React from 'react';
import ReactDOM from 'react-dom';
import type { Product, User, StockAdjustment } from '../types';
import { CloseIcon } from '../constants';

interface StockHistoryModalProps {
    isOpen: boolean;
    onClose: () => void;
    product: Product | null;
    users: User[];
}

const StockHistoryModal: React.FC<StockHistoryModalProps> = ({ isOpen, onClose, product, users }) => {
    const modalRoot = document.getElementById('modal-root');
    if (!isOpen || !product || !modalRoot) return null;

    const userMap = new Map(users.map(u => [u.id, u.name]));

    const sortedHistory = product.stockHistory 
        ? [...product.stockHistory].sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime())
        : [];

    return ReactDOM.createPortal(
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4" role="dialog" aria-modal="true">
            <div className="bg-white rounded-lg shadow-2xl w-full max-w-3xl max-h-[90vh] flex flex-col">
                <header className="p-4 sm:p-6 border-b flex justify-between items-center flex-shrink-0">
                    <div>
                        <h2 className="text-xl sm:text-2xl font-bold text-gray-800">Stock History</h2>
                        <p className="text-sm text-gray-500 mt-1">For: {product.name}</p>
                    </div>
                    <button onClick={onClose} className="p-2 rounded-full text-gray-500 hover:bg-gray-100" aria-label="Close modal">
                        <CloseIcon />
                    </button>
                </header>

                <main className="flex-grow overflow-y-auto">
                    {sortedHistory.length > 0 ? (
                        <div className="overflow-x-auto">
                            <table className="w-full text-sm text-left text-gray-500">
                                <thead className="text-xs text-gray-700 uppercase bg-gray-50 sticky top-0">
                                    <tr>
                                        <th scope="col" className="px-6 py-3">Date</th>
                                        <th scope="col" className="px-6 py-3">User</th>
                                        <th scope="col" className="px-6 py-3 text-center">Change</th>
                                        <th scope="col" className="px-6 py-3 text-center">New Stock</th>
                                        <th scope="col" className="px-6 py-3">Reason</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    {sortedHistory.map((adj, index) => {
                                        const isAdd = adj.type === 'add';
                                        return (
                                            <tr key={index} className="bg-white border-b hover:bg-gray-50">
                                                <td className="px-6 py-4 whitespace-nowrap">{new Date(adj.date).toLocaleString()}</td>
                                                <td className="px-6 py-4 font-medium text-gray-800">{userMap.get(adj.userId) || 'Unknown User'}</td>
                                                <td className={`px-6 py-4 text-center font-bold ${isAdd ? 'text-green-600' : 'text-red-600'}`}>
                                                    {isAdd ? '+' : '-'}{adj.quantity}
                                                </td>
                                                <td className="px-6 py-4 text-center font-semibold text-primary">{adj.newStockLevel}</td>
                                                <td className="px-6 py-4">{adj.reason}</td>
                                            </tr>
                                        );
                                    })}
                                </tbody>
                            </table>
                        </div>
                    ) : (
                        <div className="text-center p-10">
                            <p className="text-gray-500">No stock adjustment history for this product.</p>
                        </div>
                    )}
                </main>
                
                <footer className="p-4 bg-gray-50 rounded-b-lg flex justify-end flex-shrink-0">
                    <button type="button" onClick={onClose} className="bg-gray-600 text-white px-4 py-2 rounded-lg font-semibold hover:bg-gray-700 transition-colors">
                        Done
                    </button>
                </footer>
            </div>
        </div>,
        modalRoot
    );
};

export default StockHistoryModal;