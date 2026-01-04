
// @ts-nocheck
import React, { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { supabase, isSupabaseConfigured } from '../lib/supabase';
import PasswordStrengthIndicator from './PasswordStrengthIndicator';
import { getStoredItem, setStoredItemAndDispatchEvent } from '../lib/utils';
import { EmailIcon, BuildingIcon, FINTAB_LOGO_SVG, DUMMY_ADMIN_BUSINESS_DATA } from '../constants';
import { notify } from './Toast';

const Login: React.FC<any> = ({ language, setLanguage, t }) => {
    const navigate = useNavigate();
    const [isLoginMode, setIsLoginMode] = useState(true);
    const [isForgotPasswordMode, setIsForgotPasswordMode] = useState(false);
    const [isLoading, setIsLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [showVerificationNotice, setShowVerificationNotice] = useState(false);

    // Identity State
    const [email, setEmail] = useState('');
    const [password, setPassword] = useState('');
    const [fullName, setFullName] = useState('');

    // Business Logic State
    const [businessName, setBusinessName] = useState('');

    const handleRedirect = () => {
        const joinToken = sessionStorage.getItem('fintab_join_token');
        if (joinToken) {
            sessionStorage.removeItem('fintab_join_token');
            navigate(`/join/${joinToken}`);
            return;
        }

        const activeBid = localStorage.getItem('fintab_active_business_id');
        if (activeBid) navigate('/dashboard');
        else navigate('/select-business');
    };

    useEffect(() => {
        const checkSession = async () => {
            const { data: { session } } = await supabase.auth.getSession();
            if (session) handleRedirect();
        };
        if (isSupabaseConfigured) checkSession();
    }, [navigate]);

    const handleAuth = async (e: React.FormEvent) => {
        if (e) e.preventDefault();
        setIsLoading(true);
        setError(null);

        try {
            if (isSupabaseConfigured) {
                if (isForgotPasswordMode) {
                    const { error } = await supabase.auth.resetPasswordForEmail(email, {
                        redirectTo: window.location.origin,
                    });
                    if (error) throw error;
                    notify("Rescue link transmitted.", "info");
                } else if (isLoginMode) {
                    const { error } = await supabase.auth.signInWithPassword({ email, password });
                    if (error) throw error;
                    handleRedirect();
                } else {
                    const { data, error } = await supabase.auth.signUp({ 
                        email, 
                        password, 
                        options: { 
                            data: { 
                                full_name: fullName,
                                biz_name: businessName,
                                pref_lang: language 
                            } 
                        } 
                    });
                    if (error) throw error;
                    
                    if (data?.session) {
                        handleRedirect();
                    } else {
                        setShowVerificationNotice(true);
                    }
                }
            }
        } catch (err) {
            setError(err.message || "Authorization failed.");
            notify(err.message || "Protocol Error", "error");
        } finally {
            setIsLoading(false);
        }
    };

    const handleDemoMode = () => {
        setIsLoading(true);
        const demoUser = {
            id: 'u-demo',
            name: 'Demo Principal',
            email: 'demo@fintab.io',
            avatarUrl: 'https://ui-avatars.com/api/?name=Demo+Principal&background=2563EB&color=fff',
            role: 'Owner',
            status: 'Active',
            type: 'commission'
        };
        const demoBizId = 'biz-demo';
        localStorage.setItem('fintab_active_business_id', demoBizId);
        setStoredItemAndDispatchEvent('fintab_simulator_session', demoUser);
        const registry = getStoredItem('fintab_businesses_registry', []);
        if (!registry.find(b => b.id === demoBizId)) {
            const demoBiz = DUMMY_ADMIN_BUSINESS_DATA.find(b => b.id === demoBizId);
            if (demoBiz) setStoredItemAndDispatchEvent('fintab_businesses_registry', [...registry, demoBiz]);
        }
        sessionStorage.setItem('fintab_welcome_message', "Welcome Mr. Demo to FinTab Demo Node");
        setTimeout(() => {
            navigate('/dashboard');
            window.location.reload();
        }, 600);
    };

    if (showVerificationNotice) {
        return (
            <div className="fixed inset-0 bg-slate-50 dark:bg-gray-950 flex flex-col items-center justify-center p-4 sm:p-6 z-[100] animate-fade-in overflow-y-auto">
                <div className="bg-white dark:bg-gray-900 p-8 sm:p-12 rounded-[3rem] sm:rounded-[4rem] shadow-2xl text-center max-w-md border border-slate-100 dark:border-gray-800 animate-scale-in w-full my-auto">
                    <div className="w-20 h-20 bg-primary/10 rounded-3xl flex items-center justify-center mx-auto mb-8">
                        <EmailIcon className="w-10 h-10 text-primary" />
                    </div>
                    <h2 className="text-2xl sm:text-3xl font-black uppercase tracking-tighter text-slate-900 dark:text-white">Verify Identity</h2>
                    <div className="text-slate-500 dark:text-slate-400 mt-4 leading-relaxed font-medium text-sm">
                        Verification protocol transmitted to:<br/>
                        <span className="font-black text-slate-900 dark:text-white">{email}</span>
                    </div>
                    <div className="space-y-4 mt-10">
                        <button onClick={() => window.location.reload()} className="w-full bg-primary text-white py-5 rounded-2xl font-black uppercase text-[10px] tracking-widest shadow-xl active:scale-95 transition-all">
                            Check Handshake Status
                        </button>
                        <button onClick={() => { setShowVerificationNotice(false); setIsLoginMode(true); }} className="w-full bg-white border border-slate-100 dark:bg-gray-800 dark:border-gray-700 text-slate-400 py-4 rounded-2xl font-black uppercase text-[10px] tracking-widest active:scale-95 transition-all">
                            Abort to Login
                        </button>
                    </div>
                </div>
            </div>
        );
    }

    const inputClass = "w-full bg-slate-50 dark:bg-gray-800 border-2 border-transparent rounded-2xl p-4 sm:p-5 text-sm font-bold text-slate-900 dark:text-white placeholder-slate-400 focus:border-primary/20 focus:ring-4 focus:ring-primary/5 transition-all outline-none caret-primary shadow-sm";

    return (
        <div className="min-h-screen bg-[#F8FAFC] dark:bg-gray-950 flex flex-col font-sans relative overflow-x-hidden">
            {/* Background Grid Pattern */}
            <div className="fixed inset-0 pointer-events-none opacity-[0.03] dark:opacity-[0.05]" 
                 style={{ backgroundImage: `radial-gradient(#000 1px, transparent 1px)`, backgroundSize: '32px 32px' }}></div>
            
            {/* Dynamic Glow Orbs */}
            <div className="fixed inset-0 pointer-events-none overflow-hidden">
                <div className="absolute top-[-10%] right-[-10%] w-[50%] h-[50%] bg-primary/10 rounded-full blur-[120px] animate-pulse"></div>
                <div className="absolute bottom-[-10%] left-[-10%] w-[40%] h-[40%] bg-blue-500/10 rounded-full blur-[100px]"></div>
            </div>

            <main className="relative z-10 flex-1 flex flex-col items-center justify-center px-4 py-12 sm:px-6 lg:px-8">
                <div className="w-full max-w-md lg:max-w-lg xl:max-w-xl flex flex-col items-center space-y-10">
                    
                    {/* Brand Identity */}
                    <div className="text-center w-full">
                        <div className="w-20 h-20 sm:w-24 sm:h-24 mx-auto mb-6 bg-white dark:bg-gray-900 rounded-[2.5rem] shadow-2xl p-4 sm:p-5 flex items-center justify-center border border-slate-100 dark:border-gray-800 animate-scale-in">
                            <img src={FINTAB_LOGO_SVG} alt="FinTab Logo" className="w-full h-full object-contain" />
                        </div>
                        <h1 className="text-3xl sm:text-4xl font-black text-slate-900 dark:text-white uppercase tracking-tighter">FinTab</h1>
                        <p className="text-[9px] sm:text-[10px] font-bold text-slate-400 dark:text-slate-500 uppercase tracking-[0.6em] mt-4 ml-[0.6em]">
                            {isForgotPasswordMode ? 'Emergency Recovery' : (isLoginMode ? 'Terminal Authorization' : 'Node Enrollment')}
                        </p>
                    </div>

                    {/* Auth Component Card */}
                    <div className="w-full bg-white/80 dark:bg-gray-900/90 backdrop-blur-3xl p-8 sm:p-12 md:p-14 rounded-[3rem] sm:rounded-[4rem] shadow-2xl border border-white dark:border-gray-800 transition-all duration-500">
                        <form onSubmit={handleAuth} className="space-y-6 sm:space-y-8">
                            {error && (
                                <div className="p-4 bg-rose-50 dark:bg-rose-950/30 text-rose-600 dark:text-rose-400 text-[10px] font-black uppercase tracking-widest rounded-2xl text-center border border-rose-100 dark:border-rose-900/30 animate-shake">
                                    {error}
                                </div>
                            )}
                            
                            {!isLoginMode && !isForgotPasswordMode && (
                                <div className="space-y-2 animate-fade-in">
                                    <label className="text-[9px] font-black uppercase tracking-widest text-slate-400 px-1">Legal Identity</label>
                                    <input 
                                        type="text" 
                                        placeholder="Full Name" 
                                        required 
                                        value={fullName} 
                                        onChange={e => setFullName(e.target.value)} 
                                        className={inputClass} 
                                    />
                                </div>
                            )}

                            <div className="space-y-6">
                                <div className="space-y-2">
                                    <label className="text-[9px] font-black uppercase tracking-widest text-slate-400 px-1">Identity Endpoint</label>
                                    <input 
                                        type="email" 
                                        placeholder="Email Address" 
                                        required 
                                        value={email} 
                                        onChange={e => setEmail(e.target.value)} 
                                        className={inputClass} 
                                    />
                                </div>
                                
                                {!isForgotPasswordMode && (
                                    <div className="space-y-2">
                                        <div className="flex justify-between items-center px-1">
                                            <label className="text-[9px] font-black uppercase tracking-widest text-slate-400">Security Key</label>
                                            {isLoginMode && (
                                                <button type="button" onClick={() => setIsForgotPasswordMode(true)} className="text-[9px] font-black text-primary uppercase tracking-widest hover:underline">Lost Protocol?</button>
                                            )}
                                        </div>
                                        <input 
                                            type="password" 
                                            placeholder="••••••••" 
                                            required 
                                            value={password} 
                                            onChange={e => setPassword(e.target.value)} 
                                            className={inputClass} 
                                        />
                                        {!isLoginMode && <div className="mt-4"><PasswordStrengthIndicator password={password} /></div>}
                                    </div>
                                )}
                            </div>

                            {!isLoginMode && !isForgotPasswordMode && !sessionStorage.getItem('fintab_join_token') && (
                                <div className="space-y-2 pt-6 border-t dark:border-gray-800 animate-fade-in">
                                    <label className="text-[9px] font-black text-primary uppercase tracking-[0.3em] px-1">Organization Logic</label>
                                    <input 
                                        type="text" 
                                        placeholder="Business Name" 
                                        required 
                                        value={businessName} 
                                        onChange={e => setBusinessName(e.target.value)} 
                                        className={inputClass} 
                                    />
                                </div>
                            )}
                            
                            <div className="space-y-4 pt-4">
                                <button 
                                    type="submit" 
                                    disabled={isLoading} 
                                    className="w-full bg-slate-900 dark:bg-primary text-white py-5 sm:py-6 rounded-[2rem] font-black uppercase text-[11px] tracking-[0.25em] shadow-xl active:scale-95 transition-all flex items-center justify-center gap-3 disabled:opacity-50"
                                >
                                    {isLoading ? (
                                        <div className="w-5 h-5 border-3 border-white/30 border-t-white rounded-full animate-spin"></div>
                                    ) : (
                                        isForgotPasswordMode ? 'Transmit Reset Protocol' : (isLoginMode ? 'Authorize Entry' : 'Finalize Enrollment')
                                    )}
                                </button>
                                
                                {isLoginMode && !isForgotPasswordMode && (
                                    <button 
                                        type="button"
                                        onClick={handleDemoMode}
                                        disabled={isLoading}
                                        className="w-full bg-amber-50 dark:bg-amber-900/10 text-amber-700 dark:text-amber-400 py-4 rounded-[2rem] font-black uppercase text-[9px] sm:text-[10px] tracking-[0.3em] border-2 border-amber-100 dark:border-amber-900/30 hover:bg-amber-100 transition-all active:scale-95 flex items-center justify-center gap-2"
                                    >
                                        {isLoading ? (
                                            <div className="w-5 h-5 border-3 border-amber-400/30 border-t-amber-500 rounded-full animate-spin"></div>
                                        ) : (
                                            <>✨ Explore Demo Node</>
                                        )}
                                    </button>
                                )}
                            </div>
                        </form>

                        <div className="mt-10 pt-8 border-t dark:border-gray-800 text-center">
                            <button 
                                onClick={() => { setIsForgotPasswordMode(false); setIsLoginMode(!isLoginMode); }} 
                                className="text-[10px] font-black uppercase text-slate-400 hover:text-primary transition-colors tracking-widest"
                            >
                                {isForgotPasswordMode ? 'Return to Authorization' : (isLoginMode ? 'Initialize New Node' : 'Already Enrolled? Sign In')}
                            </button>
                        </div>
                    </div>

                    {/* Footer Trust Elements */}
                    <div className="flex flex-col sm:flex-row items-center gap-6 text-[9px] font-black text-slate-400 uppercase tracking-[0.3em] opacity-60">
                        <div className="flex items-center gap-2">
                            <div className="w-1.5 h-1.5 rounded-full bg-emerald-500"></div>
                            Secure Tunnel 256-bit
                        </div>
                        <span className="hidden sm:block text-slate-200">|</span>
                        <div>Verified Node Protocol</div>
                    </div>
                </div>
            </main>
            
            {/* Version Signature */}
            <footer className="relative z-10 py-8 px-6 text-center lg:text-right">
                <p className="text-[8px] font-black text-slate-300 dark:text-slate-700 uppercase tracking-[0.5em]">FinTab OS v1.2.4 &bull; Distributed Accounting Core</p>
            </footer>
        </div>
    );
};

export default Login;
