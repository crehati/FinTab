
import React, { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import type { User, AdminBusinessData } from '../types';
import { getStoredItem, setStoredItemAndDispatchEvent } from '../lib/utils';
import { BuildingIcon, LogoutIcon, PlusIcon, FINTAB_LOGO_SVG } from '../constants';

interface SelectBusinessProps {
    currentUser: User | null;
    onSelect: (businessId: string) => void;
    onLogout: () => void;
}

const SelectBusiness: React.FC<SelectBusinessProps> = ({ currentUser, onSelect, onLogout }) => {
    const navigate = useNavigate();
    const [inviteCode, setInviteCode] = useState('');
    const [error, setError] = useState<string | null>(null);

    const myBusinesses = useMemo(() => {
        if (!currentUser?.email) return [];
        
        const registry = getStoredItem<AdminBusinessData[]>('fintab_businesses_registry', []);
        
        if (currentUser.email === 'demo@fintab.io') {
            const demo = registry.find(b => b.id === 'biz-demo');
            if (demo) return [demo];
        }

        return registry.filter(b => {
            if (b.owner.email && b.owner.email.toLowerCase() === currentUser.email.toLowerCase()) return true;
            const users = getStoredItem<User[]>(`fintab_${b.id}_users`, []);
            return users.some(u => u.email && u.email.toLowerCase() === currentUser.email.toLowerCase());
        });
    }, [currentUser?.email]);

    const handleJoin = (e: React.FormEvent) => {
        e.preventDefault();
        setError(null);
        if (inviteCode.length < 4) {
            setError("Protocol Error: Access code invalid.");
            return;
        }
        setError("Sync Error: Node not discovered. Verify code with principal.");
    };

    const handleForceInitialize = () => {
        if (!currentUser) return;
        
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
                businessPhone: currentUser.phone || '000-000-0000',
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
        onSelect(businessId);
    };

    return (
        <div className="min-h-screen bg-slate-50 dark:bg-gray-950 flex flex-col items-center justify-center p-6 font-sans">
            <div className="w-full max-w-[640px] space-y-12 animate-fade-in py-10 overflow-y-auto no-scrollbar max-h-screen">
                <header className="text-center space-y-6">
                    <div className="w-20 h-20 bg-white dark:bg-gray-900 rounded-[2rem] shadow-2xl border border-slate-100 dark:border-gray-800 flex items-center justify-center mx-auto">
                        <BuildingIcon className="w-10 h-10 text-primary" />
                    </div>
                    <h1 className="text-4xl font-black tracking-tighter text-slate-900 dark:text-white uppercase">Terminal Authorization</h1>
                    <p className="text-[10px] font-bold text-slate-400 uppercase tracking-[0.4em]">Establish secure connection to business node</p>
                </header>

                <div className="space-y-10">
                    {myBusinesses.length > 0 ? (
                        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                            {myBusinesses.map(biz => (
                                <button
                                    key={biz.id}
                                    onClick={() => onSelect(biz.id)}
                                    className="w-full flex flex-col items-start p-8 bg-white dark:bg-gray-900 border-2 border-slate-50 dark:border-gray-800 rounded-[2.5rem] hover:border-primary hover:shadow-2xl transition-all group shadow-sm active:scale-[0.98] relative overflow-hidden"
                                >
                                    <div className="absolute top-0 right-0 w-24 h-24 bg-primary/5 rounded-full -mr-12 -mt-12 group-hover:scale-150 transition-transform duration-700"></div>
                                    <div className="p-4 rounded-2xl bg-slate-50 dark:bg-gray-800 text-slate-400 group-hover:bg-primary group-hover:text-white transition-all mb-8 shadow-inner">
                                        <BuildingIcon className="w-6 h-6" />
                                    </div>
                                    <div className="flex-1 min-w-0">
                                        <p className="font-black text-slate-900 dark:text-white uppercase tracking-tighter text-xl truncate">{biz.profile.businessName}</p>
                                        <p className="text-[9px] font-bold text-slate-400 uppercase tracking-widest mt-2">Principal: {biz.owner.name.split(' ')[0]}</p>
                                    </div>
                                    <div className="mt-8 pt-6 border-t dark:border-gray-800 w-full flex justify-between items-center">
                                        <span className="text-[8px] font-black text-primary uppercase tracking-[0.3em]">Authorize Sync</span>
                                        <svg className="w-5 h-5 text-primary opacity-0 group-hover:opacity-100 transition-all translate-x-4 group-hover:translate-x-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}><path d="M13 7l5 5m0 0l-5 5m5-5H6" /></svg>
                                    </div>
                                </button>
                            ))}
                        </div>
                    ) : (
                        <div className="bg-white dark:bg-gray-900 p-12 rounded-[3.5rem] border-2 border-dashed border-slate-200 dark:border-gray-800 text-center space-y-8 shadow-sm">
                            <div className="w-16 h-16 bg-slate-50 dark:bg-gray-800 rounded-3xl flex items-center justify-center mx-auto opacity-30">
                                <BuildingIcon className="w-8 h-8" />
                            </div>
                            <p className="text-sm font-black text-slate-400 uppercase tracking-[0.3em]">Identity Hub Isolated</p>
                            <button 
                                onClick={handleForceInitialize} 
                                className="inline-block px-12 py-5 bg-slate-900 dark:bg-primary text-white rounded-2xl text-[11px] font-black uppercase tracking-widest shadow-2xl active:scale-95 transition-all"
                            >
                                Initialize Node Instance
                            </button>
                        </div>
                    )}

                    <div className="bg-white dark:bg-gray-900 p-8 sm:p-10 rounded-[3rem] shadow-2xl border border-slate-100 dark:border-gray-800">
                        <h3 className="text-[10px] font-black uppercase tracking-[0.4em] text-slate-400 mb-8 px-1">Establish Guest connection</h3>
                        <form onSubmit={handleJoin} className="space-y-6">
                            <input 
                                type="text" 
                                value={inviteCode}
                                onChange={e => setInviteCode(e.target.value)}
                                placeholder="Terminal Protocol Code"
                                className="w-full bg-slate-50 dark:bg-gray-800 border-none rounded-2xl p-5 text-sm font-bold focus:ring-4 focus:ring-primary/10 outline-none uppercase text-center tracking-[0.6em] placeholder:tracking-normal placeholder:opacity-50"
                            />
                            {error && <p className="text-[10px] font-black text-rose-500 uppercase text-center animate-shake tracking-widest">{error}</p>}
                            <button type="submit" className="w-full py-5 bg-slate-100 dark:bg-gray-800 text-slate-600 dark:text-slate-300 rounded-2xl font-black uppercase text-[10px] tracking-widest hover:bg-slate-200 transition-all flex items-center justify-center gap-3">
                                <PlusIcon className="w-4 h-4" /> Link External Node
                            </button>
                        </form>
                    </div>
                </div>

                <div className="flex justify-center pt-8">
                    <button onClick={onLogout} className="flex items-center gap-4 px-10 py-5 bg-white dark:bg-gray-900 rounded-2xl text-slate-400 hover:text-rose-500 font-black uppercase text-[10px] tracking-[0.4em] transition-all border border-slate-100 dark:border-gray-800 shadow-sm active:scale-95 group">
                        <LogoutIcon className="w-5 h-5 group-hover:-translate-x-1 transition-transform" /> Sign Out Identity
                    </button>
                </div>
            </div>
        </div>
    );
};

export default SelectBusiness;
