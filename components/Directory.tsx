import React, { useMemo, useState, useEffect } from 'react';
import { NavLink } from 'react-router-dom';
import { SearchIcon } from '../constants';
import type { AdminBusinessData } from '../types';
import Card from './Card';
import { getStoredItem } from '../lib/utils';

const Directory: React.FC = () => {
    const [searchTerm, setSearchTerm] = useState('');
    const [businesses, setBusinesses] = useState<AdminBusinessData[]>([]);

    useEffect(() => {
        // Load the central business registry from localStorage
        setBusinesses(getStoredItem('marketup_businesses_registry', []));
    }, []);

    const filteredBusinesses = useMemo(() => 
        businesses.filter(b => 
            b.profile.isPublic &&
            b.profile.businessName.toLowerCase().includes(searchTerm.toLowerCase())
        ), 
    [businesses, searchTerm]);

    return (
        <div className="space-y-6">
            <Card title="Business Directory">
                <p className="mb-6 text-neutral-medium">
                    Explore public businesses on the MakètUp platform. Click on any business to view their products and place an order request.
                </p>

                <div className="relative mb-6">
                    <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                        <SearchIcon />
                    </div>
                    <input
                        type="text"
                        placeholder="Search businesses by name..."
                        value={searchTerm}
                        onChange={(e) => setSearchTerm(e.target.value)}
                        className="w-full pl-10 pr-4 py-3 bg-white border border-gray-200 rounded-lg shadow-sm text-neutral-dark placeholder-neutral-medium focus:outline-none focus:ring-2 focus:ring-offset-1 focus:ring-primary"
                        aria-label="Search businesses"
                    />
                </div>


                {filteredBusinesses.length > 0 ? (
                    <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
                        {filteredBusinesses.map(business => (
                            <div key={business.id} className="bg-white rounded-xl shadow-md flex flex-col overflow-hidden group transition-all duration-300 hover:shadow-xl hover:-translate-y-1">
                                <div className="p-4 border-b bg-gray-50 flex items-center gap-4">
                                    <img 
                                        src={business.profile.logo || `https://ui-avatars.com/api/?name=${business.profile.businessName.charAt(0)}&background=e0e7ff&color=4f46e5`} 
                                        alt={`${business.profile.businessName} logo`}
                                        className="w-16 h-16 rounded-lg object-cover bg-gray-200"
                                    />
                                    <div>
                                        <h3 className="text-lg font-bold text-neutral-dark">{business.profile.businessName}</h3>
                                        <p className="text-sm text-neutral-medium">{business.profile.businessType}</p>
                                    </div>
                                </div>
                                <div className="p-4 flex flex-col flex-grow">
                                    <p className="text-xs text-neutral-medium">Owner: {business.owner.name}</p>
                                    <p className="text-xs text-neutral-medium">Joined: {new Date(business.stats.joinedDate).toLocaleDateString()}</p>
                                    <div className="flex-grow" />
                                    <NavLink 
                                        to={`/public-shopfront/${business.id}`}
                                        className="mt-4 w-full bg-primary text-white text-center px-4 py-2 rounded-lg font-semibold hover:bg-blue-700 transition-colors"
                                    >
                                        View Shopfront
                                    </NavLink>
                                </div>
                            </div>
                        ))}
                    </div>
                ) : (
                    <div className="text-center py-16">
                        <p className="text-neutral-medium">
                            {searchTerm 
                                ? `No businesses found for "${searchTerm}".`
                                : 'No public businesses are listed in the directory yet.'
                            }
                        </p>
                    </div>
                )}
            </Card>
        </div>
    );
};

export default Directory;