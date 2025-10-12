import React, { useState, useMemo } from 'react';
import type { User } from '../types';
import { SearchIcon } from '../constants';

interface UserSelectionModalProps {
    isOpen: boolean;
    onClose: () => void;
    users: User[];
    onSelect: (userId: string) => void;
}

const CloseIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
    </svg>
);

const UserSelectionModal: React.FC<UserSelectionModalProps> = ({ isOpen, onClose, users, onSelect }) => {
    const [searchTerm, setSearchTerm] = useState('');

    const filteredUsers = useMemo(() => {
        // Exclude investors from the seller list
        const eligibleUsers = users.filter(u => u.role !== 'Investor');
        if (!searchTerm.trim()) return eligibleUsers;

        const lowercasedFilter = searchTerm.toLowerCase();
        return eligibleUsers.filter(user =>
            user.name.toLowerCase().includes(lowercasedFilter) ||
            user.email.toLowerCase().includes(lowercasedFilter)
        );
    }, [users, searchTerm]);

    if (!isOpen) return null;

    const displayRole = (user: User) => user.role === 'Custom' && user.customRoleName ? user.customRoleName : user.role;

    return (
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4" role="dialog" aria-modal="true">
            <div className="bg-white rounded-lg shadow-2xl w-full max-w-lg max-h-[90vh] flex flex-col">
                <header className="p-4 border-b flex justify-between items-center flex-shrink-0">
                    <h2 className="text-xl font-bold text-gray-800">Select Seller</h2>
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
                            placeholder="Search by name or email..."
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                            className="w-full pl-10 pr-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary"
                            aria-label="Search users"
                        />
                    </div>
                </div>

                <main className="flex-grow overflow-y-auto">
                    {filteredUsers.length > 0 ? (
                        <ul>
                            {filteredUsers.map(user => (
                                <li key={user.id}>
                                    <button 
                                        onClick={() => onSelect(user.id)}
                                        className="w-full text-left p-4 hover:bg-gray-50 transition-colors border-b flex items-center gap-4"
                                    >
                                        <img src={user.avatarUrl} alt={user.name} className="w-10 h-10 rounded-full object-cover flex-shrink-0" />
                                        <div>
                                            <p className="font-semibold text-gray-800">{user.name}</p>
                                            <p className="text-sm text-gray-500">{displayRole(user)}</p>
                                        </div>
                                    </button>
                                </li>
                            ))}
                        </ul>
                    ) : (
                         <div className="text-center py-10 px-4">
                            <p className="text-gray-500">No users found.</p>
                        </div>
                    )}
                </main>
            </div>
        </div>
    );
};

export default UserSelectionModal;
