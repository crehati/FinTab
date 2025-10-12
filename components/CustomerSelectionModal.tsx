
import React, { useState, useMemo } from 'react';
import type { Customer } from '../types';
import { SearchIcon, PlusIcon } from '../constants';

interface CustomerSelectionModalProps {
    isOpen: boolean;
    onClose: () => void;
    customers: Customer[];
    onSelect: (customerId: string) => void;
    onAddNew: () => void;
}

const CloseIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
    </svg>
);

const CustomerSelectionModal: React.FC<CustomerSelectionModalProps> = ({ isOpen, onClose, customers, onSelect, onAddNew }) => {
    const [searchTerm, setSearchTerm] = useState('');

    const filteredCustomers = useMemo(() => {
        if (!searchTerm.trim()) return customers;
        const lowercasedFilter = searchTerm.toLowerCase();
        return customers.filter(customer =>
            customer.name.toLowerCase().includes(lowercasedFilter) ||
            customer.email.toLowerCase().includes(lowercasedFilter) ||
            customer.phone.includes(searchTerm)
        );
    }, [customers, searchTerm]);

    if (!isOpen) return null;

    return (
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4" role="dialog" aria-modal="true">
            <div className="bg-white rounded-lg shadow-2xl w-full max-w-lg max-h-[90vh] flex flex-col">
                <header className="p-4 border-b flex justify-between items-center flex-shrink-0">
                    <h2 className="text-xl font-bold text-gray-800">Select Client</h2>
                    <button onClick={onClose} className="p-2 rounded-full text-gray-500 hover:bg-gray-100" aria-label="Close modal">
                        <CloseIcon />
                    </button>
                </header>

                <div className="p-4 flex-shrink-0 border-b">
                    <div className="relative">
                        <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                            <SearchIcon />
                        </div>
                        <input
                            type="text"
                            placeholder="Search by name, email, or phone..."
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                            className="w-full pl-10 pr-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary"
                            aria-label="Search customers"
                        />
                    </div>
                </div>

                <main className="flex-grow overflow-y-auto">
                    {filteredCustomers.length > 0 ? (
                        <ul>
                            {filteredCustomers.map(customer => (
                                <li key={customer.id}>
                                    <button 
                                        onClick={() => onSelect(customer.id)}
                                        className="w-full text-left p-4 hover:bg-gray-50 transition-colors border-b"
                                    >
                                        <p className="font-semibold text-gray-800">{customer.name}</p>
                                        <p className="text-sm text-gray-500">{customer.phone}</p>
                                    </button>
                                </li>
                            ))}
                        </ul>
                    ) : (
                         <div className="text-center py-10 px-4">
                            <p className="text-gray-500">No customers found.</p>
                        </div>
                    )}
                </main>

                <footer className="p-4 bg-gray-50 border-t flex-shrink-0">
                     <button
                        type="button"
                        onClick={onAddNew}
                        className="w-full flex items-center justify-center gap-2 p-3 border-0 bg-primary text-white rounded-lg font-semibold hover:bg-blue-700 transition-colors"
                    >
                        <PlusIcon />
                        Add New Client
                    </button>
                </footer>
            </div>
        </div>
    );
};

export default CustomerSelectionModal;
