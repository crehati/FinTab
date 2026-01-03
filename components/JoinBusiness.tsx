
// @ts-nocheck
import React, { useEffect, useState } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { supabase, isSupabaseConfigured } from '../lib/supabase';
import { notify } from './Toast';
import { getStoredItem, setStoredItemAndDispatchEvent } from '../lib/utils';
import { FINTAB_LOGO_SVG, BuildingIcon } from '../constants';

const JoinBusiness: React.FC = () => {
    const { token } = useParams<{ token: string }>();
    const navigate = useNavigate();
    const [isLoading, setIsLoading] = useState(true);
    const [isAccepting, setIsAccepting] = useState(false);
    const [invite, setInvite] = useState<any>(null);
    const [error, setError] = useState<string | null>(null);

    useEffect(() => {
        const fetchInvite = async () => {
            if (!token || !isSupabaseConfigured) {
                setError("Protocol Error: Malformed link or connection offline.");
                setIsLoading(false);
                return;
            }

            try {
                const { data, error } = await supabase
                    .from('fintab_invitations')
                    .select('*')
                    .eq('id', token)
                    .single();

                if (error || !data) throw new Error("Invite expired or invalidated.");
                if (data.status !== 'pending') throw new Error("Protocol already finalized.");

                setInvite(data);
            } catch (err) {
                setError(err.message);
            } finally {
                setIsLoading(false);
            }
        };

        fetchInvite();
    }, [token]);

    const handleAccept = async () => {
        if (isAccepting) return;
        setIsAccepting(true);
        
        try {
            const { data: { session } } = await supabase.auth.getSession();
            
            if (!session) {
                // Persistent Teleportation
                sessionStorage.setItem('fintab_join_token', token);
                notify("Verification Required: Sign in or create account.", "info");
                navigate('/login');
                return;
            }

            const user = session.user;
            
            // 1. Mark invite finalized in cloud
            const { error: updateErr } = await supabase
                .from('fintab_invitations')
                .update({ status: 'accepted' })
                .eq('id', token);

            if (updateErr) throw updateErr;

            // 2. Sync Identity to Business Personnel Ledger
            const { data: recordData } = await supabase
                .from('fintab_records')
                .select('data')
                .eq('business_id', invite.business_id)
                .eq('key', 'users')
                .maybeSingle();

            const existingUsers = recordData?.data || [];
            
            const newUserIdentity = {
                id: user.id,
                name: user.user_metadata?.full_name || invite.email.split('@')[0],
                email: user.email,
                role: invite.role,
                role_label: invite.role_label,
                type: invite.user_type,
                hourlyRate: invite.hourly_rate || 0,
                initialInvestment: invite.initial_investment || 0,
                avatarUrl: user.user_metadata?.avatar_url || `https://ui-avatars.com/api/?name=${encodeURIComponent(user.email)}`,
                status: 'Active',
                joined_at: new Date().toISOString()
            };

            const updatedUsers = [...existingUsers.filter(u => u.email !== user.email), newUserIdentity];

            // 3. Update Business Records
            const { error: saveErr } = await supabase
                .from('fintab_records')
                .upsert({
                    business_id: invite.business_id,
                    key: 'users',
                    data: updatedUsers,
                    updated_at: new Date().toISOString()
                }, { onConflict: 'business_id,key' });

            if (saveErr) throw saveErr;

            // 4. Update Business Profile Node
            const registry = getStoredItem('fintab_businesses_registry', []);
            if (!registry.some(b => b.id === invite.business_id)) {
                const newRegistryEntry = {
                    id: invite.business_id,
                    profile: { businessName: invite.business_name, logo: null, businessType: 'Authorized Node' },
                    owner: { name: invite.invited_by || 'Principal', email: '' },
                    stats: { joinedDate: new Date().toISOString(), status: 'Active' }
                };
                setStoredItemAndDispatchEvent('fintab_businesses_registry', [...registry, newRegistryEntry]);
            }

            // 5. Finalize Routing
            localStorage.setItem('fintab_active_business_id', invite.business_id);
            sessionStorage.setItem('fintab_welcome_message', `Protocol Synchronized: Welcome ${newUserIdentity.name} to ${invite.business_name}`);
            
            navigate('/dashboard');
            window.location.reload();
            
        } catch (err) {
            setError(err.message);
            notify("Identity Handshake Failed", "error");
        } finally {
            setIsAccepting(false);
        }
    };

    if (isLoading) {
        return (
            <div className="min-h-screen bg-slate-950 flex flex-col items-center justify-center">
                <div className="w-16 h-16 border-4 border-primary border-t-transparent rounded-full animate-spin"></div>
                <p className="text-[10px] font-black text-slate-500 uppercase tracking-[0.4em] mt-8">Establishing Handshake...</p>
            </div>
        );
    }

    if (error) {
        return (
            <div className="min-h-screen bg-[#F8FAFC] dark:bg-gray-950 flex items-center justify-center p-6">
                <div className="bg-white dark:bg-gray-900 p-12 rounded-[3rem] shadow-2xl text-center max-w-md border border-rose-100 dark:border-rose-900/30 animate-scale-in">
                    <div className="w-16 h-16 bg-rose-50 dark:bg-rose-900/20 rounded-2xl flex items-center justify-center mx-auto mb-6 text-rose-500">
                        <svg className="w-8 h-8" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}><path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" /></svg>
                    </div>
                    <h2 className="text-xl font-black uppercase text-slate-900 dark:text-white tracking-tighter">Protocol Failure</h2>
                    <p className="text-xs text-slate-400 font-bold uppercase mt-4 leading-relaxed">{error}</p>
                    <button onClick={() => navigate('/login')} className="mt-10 w-full py-4 bg-slate-900 text-white rounded-xl font-black uppercase text-[10px] tracking-widest shadow-xl">Return to Hub</button>
                </div>
            </div>
        );
    }

    return (
        <div className="min-h-screen bg-[#F8FAFC] dark:bg-gray-950 flex items-center justify-center p-6 font-sans">
             <div className="fixed inset-0 pointer-events-none overflow-hidden opacity-40">
                <div className="absolute top-[-10%] right-[-10%] w-[60%] h-[60%] bg-primary/20 rounded-full blur-[120px]"></div>
            </div>

            <div className="w-full max-w-md relative z-10 animate-fade-in">
                <div className="text-center mb-10">
                    <div className="w-16 h-16 mx-auto mb-6 bg-white dark:bg-gray-900 rounded-3xl shadow-xl p-3 flex items-center justify-center">
                        <img src={FINTAB_LOGO_SVG} className="w-full h-full object-contain" />
                    </div>
                    <h1 className="text-4xl font-black uppercase tracking-tighter text-slate-900 dark:text-white leading-none">Authorization</h1>
                    <p className="text-[10px] font-bold text-slate-400 uppercase tracking-[0.4em] mt-4">Verified Business Handshake</p>
                </div>

                <div className="bg-white dark:bg-gray-900 p-10 rounded-[3.5rem] shadow-2xl border border-slate-50 dark:border-gray-800">
                    <div className="flex items-center gap-6 mb-10 p-6 bg-slate-50 dark:bg-gray-800/50 rounded-[2rem] border border-slate-100 dark:border-gray-700">
                        <div className="p-4 bg-white dark:bg-gray-900 rounded-2xl text-primary shadow-sm">
                            <BuildingIcon className="w-8 h-8" />
                        </div>
                        <div className="min-w-0 text-left">
                            <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest">Target Node</p>
                            <h2 className="text-xl font-black text-slate-900 dark:text-white uppercase truncate tracking-tighter">{invite.business_name}</h2>
                        </div>
                    </div>

                    <div className="space-y-6 mb-10">
                        <div className="flex justify-between items-center px-2">
                            <span className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">Protocol Assignment</span>
                            <span className="px-4 py-1 bg-primary text-white text-[9px] font-black rounded-full uppercase tracking-widest">{invite.role_label}</span>
                        </div>
                        <div className="flex justify-between items-center px-2">
                            <span className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">Issuing Principal</span>
                            <span className="text-[10px] font-black text-slate-900 dark:text-white uppercase tracking-tighter">{invite.invited_by}</span>
                        </div>
                    </div>

                    <button 
                        onClick={handleAccept}
                        disabled={isAccepting}
                        className="w-full py-6 bg-primary text-white rounded-[2rem] font-black uppercase text-[11px] tracking-[0.3em] shadow-2xl shadow-primary/30 active:scale-95 transition-all hover:bg-blue-700 flex items-center justify-center gap-4 disabled:opacity-50"
                    >
                        {isAccepting ? (
                            <div className="w-5 h-5 border-3 border-white/30 border-t-white rounded-full animate-spin"></div>
                        ) : (
                            'Authorize Final Connection'
                        )}
                    </button>

                    <button 
                        onClick={() => navigate('/login')}
                        disabled={isAccepting}
                        className="w-full mt-4 py-4 text-slate-400 font-black uppercase text-[9px] tracking-widest hover:text-slate-600 transition-colors"
                    >
                        Decline Node
                    </button>
                </div>

                <footer className="mt-12 text-center">
                    <p className="text-[9px] font-black text-slate-300 uppercase tracking-[0.5em]">Terminal Verified • FinTab app</p>
                </footer>
            </div>
        </div>
    );
};

export default JoinBusiness;
