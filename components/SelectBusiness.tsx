
// @ts-nocheck
import React, { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import type { User, AdminBusinessData } from '../types';
import { getStoredItem, setStoredItemAndDispatchEvent } from '../lib/utils';
import { BuildingIcon, LogoutIcon, PlusIcon, FINTAB_LOGO_SVG } from '../constants';
import { notify } from './Toast';

interface SelectBusinessProps {
    currentUser: User | null;
    onSelect: (businessId: string) => void;
    onLogout: () => void;
}

const SelectBusiness: React.FC<SelectBusinessProps> = ({ currentUser, onSelect, onLogout }) => {
    const navigate = useNavigate();
    const [inviteCode, setInviteCode] = useState('');
    const [isCreating, setIsCreating] = useState(false);

    const myBusinesses = useMemo(() => {
        if (!currentUser?.email) return [];
        const registry = getStoredItem<AdminBusinessData[]>('fintab_businesses_registry', []);
        return registry.filter(b => {
            if (b.owner.email.toLowerCase() === currentUser.email.toLowerCase()) return true;
            const users = getStoredItem<User[]>(`fintab_${b.id}_users`, []);
            return users.some(u => u.email.toLowerCase() === currentUser.email.toLowerCase());
        });
    }, [currentUser?.email]);

    const handleCreateNewNode = () => {
        setIsCreating(true);
        const businessId = `biz-${Date.now()}`;
        const newEntry: AdminBusinessData = {
            id: businessId,
            profile: { 
                businessName: `${currentUser.name.split(' ')[0]}'s Node`, 
                businessType: 'Retail', 
                logo: FINTAB_LOGO_SVG,
                dateEstablished: new Date().toISOString(),
                employeeCount: '1-5',
                businessEmail: currentUser.email,
                businessPhone: '000-000-0000',
                isPublic: true
            },
            licensingInfo: { licenseType: 'Trial', enrollmentDate: new Date().toISOString(), trialEndDate: new Date(Date.now() + 14 * 24 * 60 * 60 * 1000).toISOString() },
            settings: { acceptRemoteOrders: true },
            owner: { name: currentUser.name, email: currentUser.email },
            stats: { totalRevenue: 0, salesCount: 0, userCount: 1, joinedDate: new Date().toISOString(), status: 'Active' }
        };

        const registry = getStoredItem<AdminBusinessData[]>('fintab_businesses_registry', []);
        setStoredItemAndDispatchEvent('fintab_businesses_registry', [...registry, newEntry]);
        setStoredItemAndDispatchEvent(`fintab_${businessId}_users`, [currentUser]);
        
        notify("Secure Node Initialized", "success");
        onSelect(businessId);
    };

    return (
        <div className="min-h-screen bg-slate-50 dark:bg-gray-950 flex flex-col items-center justify-center p-6 font-sans">
            <div className="w-full max-w-[640px] space-y-12 animate-fade-in py-10">
                <header className="text-center space-y-6">
                    <div className="w-20 h-20 bg-white dark:bg-gray-900 rounded-[2rem] shadow-2xl border border-slate-100 dark:border-gray-800 flex items-center justify-center mx-auto">
                        <BuildingIcon className="w-10 h-10 text-primary" />
                    </div>
                    <h1 className="text-4xl font-black tracking-tighter text-slate-900 dark:text-white uppercase">Identity Hub</h1>
                    <p className="text-[10px] font-bold text-slate-400 uppercase tracking-[0.4em]">Select authorized node or initialize instance</p>
                </header>

                <div className="space-y-6">
                    {myBusinesses.length > 0 ? (
                        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                            {myBusinesses.map(biz => (
                                <button
                                    key={biz.id}
                                    onClick={() => onSelect(biz.id)}
                                    className="w-full flex flex-col items-start p-8 bg-white dark:bg-gray-900 border-2 border-slate-50 dark:border-gray-800 rounded-[2.5rem] hover:border-primary hover:shadow-2xl transition-all group active:scale-[0.98] relative overflow-hidden"
                                >
                                    <div className="p-4 rounded-2xl bg-slate-50 dark:bg-gray-800 text-slate-400 group-hover:bg-primary group-hover:text-white transition-all mb-8">
                                        <BuildingIcon className="w-6 h-6" />
                                    </div>
                                    <p className="font-black text-slate-900 dark:text-white uppercase tracking-tighter text-xl truncate w-full text-left">{biz.profile.businessName}</p>
                                    <p className="text-[9px] font-bold text-slate-400 uppercase tracking-widest mt-2">Verified Endpoint</p>
                                </button>
                            ))}
                        </div>
                    ) : (
                        <div className="bg-white dark:bg-gray-900 p-12 rounded-[3.5rem] border-2 border-dashed border-slate-200 dark:border-gray-800 text-center space-y-8">
                            <p className="text-sm font-black text-slate-400 uppercase tracking-[0.3em]">No Active Nodes Found</p>
                            <button 
                                onClick={handleCreateNewNode} 
                                disabled={isCreating}
                                className="px-12 py-5 bg-primary text-white rounded-2xl text-[11px] font-black uppercase tracking-widest shadow-2xl active:scale-95 transition-all flex items-center justify-center gap-3 mx-auto"
                            >
                                {isCreating ? <div className="w-4 h-4 border-2 border-white/30 border-t-white rounded-full animate-spin"></div> : <PlusIcon className="w-4 h-4" />}
                                Initialize New Node
                            </button>
                        </div>
                    )}
                </div>

                <div className="flex justify-center pt-8">
                    <button onClick={onLogout} className="flex items-center gap-4 px-10 py-5 bg-white dark:bg-gray-900 rounded-2xl text-slate-400 hover:text-rose-500 font-black uppercase text-[10px] tracking-[0.4em] transition-all border border-slate-100 dark:border-gray-800 shadow-sm active:scale-95 group">
                        <LogoutIcon className="w-5 h-5 group-hover:-translate-x-1 transition-transform" /> Terminate Session
                    </button>
                </div>
            </div>
        </div>
    );
};

export default SelectBusiness;
