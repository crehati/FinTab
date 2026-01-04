
// @ts-nocheck
import React, { useState } from 'react';
import { supabase, isSupabaseConfigured } from '../lib/supabase';
import { getStoredItem, setStoredItemAndDispatchEvent } from '../lib/utils';
import { FINTAB_LOGO_SVG, DUMMY_ADMIN_BUSINESS_DATA } from '../constants';
import { notify } from './Toast';

const Login: React.FC<any> = ({ t }) => {
    const [isLoading, setIsLoading] = useState(false);
    const [email, setEmail] = useState('');
    const [password, setPassword] = useState('');

    const handleAuth = async (e: React.FormEvent) => {
        e.preventDefault();
        setIsLoading(true);
        try {
            if (isSupabaseConfigured) {
                const { error } = await supabase.auth.signInWithPassword({ email, password });
                if (error) throw error;
                // Success triggers App.tsx state change and automatic routing
            } else {
                notify("Cloud node offline. Use Simulation mode.", "info");
            }
        } catch (err) {
            notify(err.message || "Authorization failed.", "error");
        } finally {
            setIsLoading(false);
        }
    };

    const handleDemoMode = () => {
        setIsLoading(true);
        const demoUser = { 
            id: 'u-demo', 
            name: 'Demo Agent', 
            email: 'demo@fintab.io', 
            role: 'Owner', 
            avatarUrl: 'https://ui-avatars.com/api/?name=Demo+Agent&background=2563EB&color=fff' 
        };
        localStorage.setItem('fintab_active_business_id', 'biz-demo');
        setStoredItemAndDispatchEvent('fintab_simulator_session', demoUser);
        
        const registry = getStoredItem('fintab_businesses_registry', []);
        if (!registry.find(b => b.id === 'biz-demo')) {
            setStoredItemAndDispatchEvent('fintab_businesses_registry', [...registry, DUMMY_ADMIN_BUSINESS_DATA[1]]);
        }
        
        // Force app re-init
        window.location.reload();
    };

    const inputClass = "w-full bg-slate-50 dark:bg-gray-800 border-none rounded-2xl p-5 text-sm font-bold text-slate-900 dark:text-white placeholder-slate-400 focus:ring-4 focus:ring-primary/10 transition-all outline-none shadow-sm";

    return (
        <div className="fixed inset-0 bg-[#F8FAFC] dark:bg-gray-950 flex items-center justify-center p-8 font-sans overflow-y-auto">
            <div className="w-full max-w-[440px] space-y-12 animate-fade-in py-12">
                <div className="text-center">
                    <img src={FINTAB_LOGO_SVG} alt="Logo" className="w-24 h-24 mx-auto mb-8 drop-shadow-2xl" />
                    <h1 className="text-4xl font-black uppercase tracking-tighter text-slate-900 dark:text-white leading-none">Authorization</h1>
                    <p className="text-[10px] font-bold text-slate-400 dark:text-slate-500 uppercase tracking-[0.6em] mt-6">Authorized Node Entry</p>
                </div>

                <div className="bg-white dark:bg-gray-900 p-10 md:p-12 rounded-[4rem] shadow-2xl border border-slate-100 dark:border-gray-800">
                    <form onSubmit={handleAuth} className="space-y-6">
                        <input type="email" placeholder="Identity Email" required value={email} onChange={e => setEmail(e.target.value)} className={inputClass} />
                        <input type="password" placeholder="Security Password" required value={password} onChange={e => setPassword(e.target.value)} className={inputClass} />
                        <button 
                            type="submit" 
                            disabled={isLoading} 
                            className="w-full bg-slate-900 dark:bg-primary text-white py-6 rounded-[2rem] font-black uppercase text-[11px] tracking-widest shadow-2xl active:scale-95 transition-all hover:opacity-90 disabled:opacity-50 flex items-center justify-center gap-3"
                        >
                            {isLoading ? <div className="w-5 h-5 border-3 border-white/30 border-t-white rounded-full animate-spin"></div> : 'Authorize Entry'}
                        </button>
                    </form>
                    <div className="mt-10 pt-10 border-t border-slate-50 dark:border-gray-800">
                        <button onClick={handleDemoMode} className="w-full py-5 bg-amber-50 dark:bg-amber-900/10 text-amber-600 dark:text-amber-400 rounded-[2rem] font-black uppercase text-[10px] tracking-[0.2em] border border-amber-100 dark:border-amber-900/30 transition-all active:scale-95 hover:bg-amber-100">
                            Launch Simulation Node
                        </button>
                    </div>
                </div>
                
                <p className="text-center text-[9px] font-black uppercase text-slate-300 dark:text-slate-700 tracking-[0.4em]">FinTab OS v1.0.4 • Milestone Restored</p>
            </div>
        </div>
    );
};

export default Login;
