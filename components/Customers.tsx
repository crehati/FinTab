

import React, { useState, useMemo, useRef, useEffect } from 'react';
import type { Customer, ReceiptSettingsData } from '../types';
import Card from './Card';
import { PlusIcon, MoreVertIcon } from '../constants';
import CustomerModal from './CustomerModal';
import CustomerDetailModal from './CustomerDetailModal';
import { formatCurrency } from '../lib/utils';

interface CustomersProps {
    customers: Customer[];
    setCustomers: React.Dispatch<React.SetStateAction<Customer[]>>;
    t: (key: string) => string;
    receiptSettings: ReceiptSettingsData;
    trialLimits: { canAddCustomer: boolean };
}

// Helper function for time formatting
const timeAgo = (dateString: string): string => {
    if (!dateString) return '';
    const date = new Date(dateString);
    const now = new Date();
    const seconds = Math.floor((now.getTime() - date.getTime()) / 1000);

    if (seconds < 60) return 'Just now';
    let interval = seconds / 31536000;
    if (interval > 1) return `${Math.floor(interval)} years ago`;
    interval = seconds / 2592000;
    if (interval > 1) return `${Math.floor(interval)} months ago`;
    interval = seconds / 86400;
    if (interval > 1) return `${Math.floor(interval)} days ago`;
    interval = seconds / 3600;
    if (interval > 1) return `${Math.floor(interval)} hours ago`;
    interval = seconds / 60;
    if (interval > 1) return `${Math.floor(interval)} minutes ago`;
    return `${Math.floor(seconds)} seconds ago`;
};

const SearchIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-5 w-5 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
    </svg>
);

const SortArrowIcon: React.FC<{ direction: 'asc' | 'desc' }> = ({ direction }) => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-4 w-4 inline-block ml-1" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        {direction === 'asc' ? (
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 15l7-7 7 7" />
        ) : (
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
        )}
    </svg>
);


const Customers: React.FC<CustomersProps> = ({ customers, setCustomers, t, receiptSettings, trialLimits }) => {
    const [isCustomerModalOpen, setIsCustomerModalOpen] = useState(false);
    const [editingCustomer, setEditingCustomer] = useState<Customer | null>(null);
    const [selectedCustomer, setSelectedCustomer] = useState<Customer | null>(null);
    const [searchTerm, setSearchTerm] = useState('');
    const [openActionMenuId, setOpenActionMenuId] = useState<string | null>(null);
    const actionMenuRef = useRef<HTMLDivElement>(null);
    
    type SortKey = 'name' | 'joinDate' | 'totalSpent';
    const [sortConfig, setSortConfig] = useState<{ key: SortKey; direction: 'asc' | 'desc' }>({ key: 'totalSpent', direction: 'desc' });

    useEffect(() => {
        const handleClickOutside = (event: MouseEvent) => {
            if (actionMenuRef.current && !actionMenuRef.current.contains(event.target as Node)) {
                setOpenActionMenuId(null);
            }
        };
        if (openActionMenuId) {
            document.addEventListener('mousedown', handleClickOutside);
        }
        return () => {
            document.removeEventListener('mousedown', handleClickOutside);
        };
    }, [openActionMenuId]);
    
    const getTotalSpent = (customer: Customer) => {
        return customer.purchaseHistory.reduce((sum, sale) => sum + sale.total, 0);
    }

    const sortedCustomers = useMemo(() => {
        const sorted = [...customers];
        sorted.sort((a, b) => {
            let aValue: string | number;
            let bValue: string | number;

            if (sortConfig.key === 'totalSpent') {
                aValue = getTotalSpent(a);
                bValue = getTotalSpent(b);
            } else if (sortConfig.key === 'joinDate') {
                aValue = new Date(a.joinDate).getTime();
                bValue = new Date(b.joinDate).getTime();
            } else { // 'name'
                aValue = a.name;
                bValue = b.name;
            }

            if (typeof aValue === 'string' && typeof bValue === 'string') {
                if (sortConfig.direction === 'asc') {
                    return aValue.localeCompare(bValue);
                }
                return bValue.localeCompare(aValue);
            }
            if (sortConfig.direction === 'asc') {
                return (aValue as number) - (bValue as number);
            }
            return (bValue as number) - (aValue as number);
        });
        return sorted;
    }, [customers, sortConfig]);

    const filteredCustomers = useMemo(() => {
        if (!searchTerm.trim()) {
            return sortedCustomers;
        }
        const lowercasedFilter = searchTerm.toLowerCase();
        return sortedCustomers.filter(customer =>
            customer.name.toLowerCase().includes(lowercasedFilter) ||
            customer.email.toLowerCase().includes(lowercasedFilter) ||
            customer.phone.includes(searchTerm)
        );
    }, [sortedCustomers, searchTerm]);

    const handleOpenAddModal = () => {
        setEditingCustomer(null);
        setIsCustomerModalOpen(true);
    };

    const handleOpenEditModal = (customer: Customer) => {
        setEditingCustomer(customer);
        setIsCustomerModalOpen(true);
    };

    const handleCloseModal = () => {
        setIsCustomerModalOpen(false);
        setEditingCustomer(null);
    };

    const handleSaveCustomer = (customerData: Omit<Customer, 'id' | 'joinDate' | 'purchaseHistory'>) => {
        if (editingCustomer) {
            // Edit mode: update existing customer
            setCustomers(prevCustomers =>
                prevCustomers.map(c =>
                    c.id === editingCustomer.id ? { ...c, ...customerData } : c
                )
            );
        } else {
            // Add mode: create new customer
            const newCustomer: Customer = {
                ...customerData,
                id: `cust-${Date.now()}`,
                joinDate: new Date().toISOString(),
                purchaseHistory: [],
            };
            setCustomers(prev => [newCustomer, ...prev]);
        }
        handleCloseModal();
    };
    
    const handleSort = (key: SortKey) => {
        let direction: 'asc' | 'desc' = 'asc';
        if (sortConfig.key === key && sortConfig.direction === 'asc') {
            direction = 'desc';
        }
        setSortConfig({ key, direction });
    };
    
    const handleMobileSortChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
        const value = e.target.value;
        const [key, direction] = value.split(':');
        setSortConfig({ key: key as SortKey, direction: direction as 'asc' | 'desc' });
    };

    const SortableHeader: React.FC<{ sortKey: SortKey, children: React.ReactNode, className?: string }> = ({ sortKey, children, className = '' }) => {
        const isSorting = sortConfig.key === sortKey;
        return (
            <th scope="col" className={`px-6 py-3 cursor-pointer select-none ${className}`} onClick={() => handleSort(sortKey)} aria-sort={isSorting ? (sortConfig.direction === 'asc' ? 'ascending' : 'descending') : 'none'}>
                {children}
                {isSorting && <SortArrowIcon direction={sortConfig.direction} />}
            </th>
        );
    };

    return (
        <>
            <Card title={t('customerManagement.title')}>
                 <div className="mb-4 flex flex-col md:flex-row gap-4">
                    <div className="relative flex-grow">
                        <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                            <SearchIcon />
                        </div>
                        <input
                            type="text"
                            placeholder="Search by name, email, or phone..."
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                            className="w-full pl-10 pr-4 py-2 bg-white border border-gray-200 rounded-lg shadow-sm text-neutral-dark placeholder-neutral-medium focus:outline-none focus:ring-2 focus:ring-offset-1 focus:ring-primary"
                            aria-label="Search customers"
                        />
                    </div>
                     <div className="relative md:hidden">
                         <label htmlFor="sort-customers" className="sr-only">Sort Customers By</label>
                         <select
                            id="sort-customers"
                            value={`${sortConfig.key}:${sortConfig.direction}`}
                            onChange={handleMobileSortChange}
                            className="w-full py-2 pl-3 pr-10 bg-white border border-gray-200 rounded-lg shadow-sm text-neutral-dark focus:outline-none focus:ring-2 focus:ring-offset-1 focus:ring-primary"
                        >
                            <option value="totalSpent:desc">Total Spent (High to Low)</option>
                            <option value="totalSpent:asc">Total Spent (Low to High)</option>
                            <option value="name:asc">Name (A-Z)</option>
                            <option value="name:desc">Name (Z-A)</option>
                            <option value="joinDate:desc">Join Date (Newest First)</option>
                            <option value="joinDate:asc">Join Date (Oldest First)</option>
                        </select>
                    </div>
                </div>

                {filteredCustomers.length === 0 ? (
                     <div className="text-center py-10">
                        <p className="text-neutral-medium">No customers found matching your filters.</p>
                    </div>
                ) : (
                    <>
                        {/* Desktop Table View */}
                        <div className="hidden md:block overflow-x-auto">
                            <table className="w-full text-sm text-left text-neutral-medium">
                                <thead className="text-xs text-neutral-medium uppercase bg-neutral-light">
                                    <tr>
                                        <SortableHeader sortKey="name">Name</SortableHeader>
                                        <th scope="col" className="px-6 py-3">Email</th>
                                        <th scope="col" className="px-6 py-3">Phone</th>
                                        <SortableHeader sortKey="joinDate">Join Date</SortableHeader>
                                        <SortableHeader sortKey="totalSpent">Total Spent</SortableHeader>
                                        <th scope="col" className="px-6 py-3 text-right">Actions</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    {filteredCustomers.map(customer => (
                                        <tr key={customer.id} className="bg-white border-b border-neutral-light hover:bg-accent-sky/5">
                                            <td className="px-6 py-4 font-medium text-neutral-dark">{customer.name}</td>
                                            <td className="px-6 py-4 text-neutral-dark">{customer.email}</td>
                                            <td className="px-6 py-4 text-neutral-dark">{customer.phone}</td>
                                            <td className="px-6 py-4 text-neutral-dark">{new Date(customer.joinDate).toLocaleDateString()}</td>
                                            <td className="px-6 py-4 font-semibold text-accent-teal">{formatCurrency(getTotalSpent(customer), receiptSettings.currencySymbol)}</td>
                                            <td className="px-6 py-4 text-right whitespace-nowrap">
                                                <button
                                                    onClick={() => setSelectedCustomer(customer)}
                                                    className="font-medium text-accent-teal hover:underline mr-4"
                                                >
                                                    View
                                                </button>
                                                <button
                                                    onClick={() => handleOpenEditModal(customer)}
                                                    className="font-medium text-primary hover:underline"
                                                >
                                                    Edit
                                                </button>
                                            </td>
                                        </tr>
                                    ))}
                                </tbody>
                            </table>
                        </div>
                        
                        {/* Mobile Card View */}
                        <div className="md:hidden space-y-3">
                            {filteredCustomers.map(customer => {
                                const lastOrder = customer.purchaseHistory.length > 0
                                    ? [...customer.purchaseHistory].sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime())[0]
                                    : null;
                                
                                const lastOrderText = lastOrder ? timeAgo(lastOrder.date) : 'No orders yet';
                                const orderCount = customer.purchaseHistory.length;
                                
                                return (
                                    <div key={customer.id} className="bg-white p-4 rounded-xl shadow-md border border-neutral-light relative">
                                        <div className="pr-10"> {/* Add padding to prevent text overlap with icon */}
                                            <p className="font-bold text-lg text-neutral-dark truncate">{customer.name}</p>
                                            <p className="text-sm text-neutral-medium mt-1">{customer.phone}</p>
                                            <p className="text-xs text-neutral-medium mt-2">
                                                <span className="font-medium">{orderCount} {orderCount === 1 ? 'Order' : 'Orders'}</span>
                                                {lastOrder && <span className="mx-1">&middot;</span>}
                                                {lastOrder && `Last: ${lastOrderText}`}
                                            </p>
                                        </div>

                                        <div className="absolute top-2 right-2">
                                            <div className="relative" ref={openActionMenuId === customer.id ? actionMenuRef : null}>
                                                <button
                                                    onClick={(e) => {
                                                        e.stopPropagation();
                                                        setOpenActionMenuId(openActionMenuId === customer.id ? null : customer.id);
                                                    }}
                                                    className="p-2 rounded-full text-neutral-medium hover:bg-gray-100"
                                                    aria-label="More actions"
                                                >
                                                    <MoreVertIcon />
                                                </button>
                                                {openActionMenuId === customer.id && (
                                                    <div className="absolute right-0 mt-2 w-40 bg-white rounded-md shadow-lg border z-10 py-1">
                                                        <button
                                                            onClick={() => { setSelectedCustomer(customer); setOpenActionMenuId(null); }}
                                                            className="w-full text-left block px-4 py-2 text-sm text-neutral-dark hover:bg-gray-100"
                                                        >
                                                            View Profile
                                                        </button>
                                                        <button
                                                            onClick={() => { handleOpenEditModal(customer); setOpenActionMenuId(null); }}
                                                            className="w-full text-left block px-4 py-2 text-sm text-neutral-dark hover:bg-gray-100"
                                                        >
                                                            Edit
                                                        </button>
                                                    </div>
                                                )}
                                            </div>
                                        </div>
                                    </div>
                                );
                            })}
                        </div>
                    </>
                )}
            </Card>

            <button
                onClick={handleOpenAddModal}
                disabled={!trialLimits.canAddCustomer}
                title={!trialLimits.canAddCustomer ? "Customer limit reached for trial period" : "Add new customer"}
                className="fixed bottom-24 right-6 md:bottom-10 md:right-10 bg-primary text-white rounded-full p-4 shadow-xl hover:bg-blue-700 transition-transform transform hover:scale-110 z-20 disabled:bg-gray-400 disabled:cursor-not-allowed"
                aria-label="Add new customer"
            >
                <PlusIcon />
            </button>

            <CustomerModal 
                isOpen={isCustomerModalOpen}
                onClose={handleCloseModal}
                onSave={handleSaveCustomer}
                customerToEdit={editingCustomer}
            />
            
            <CustomerDetailModal
                customer={selectedCustomer}
                onClose={() => setSelectedCustomer(null)}
                receiptSettings={receiptSettings}
            />
        </>
    );
};

export default Customers;