
// @ts-nocheck
import React, { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { supabase, isSupabaseConfigured } from '../lib/supabase';
import PasswordStrengthIndicator from './PasswordStrengthIndicator';
import { getStoredItem, setStoredItemAndDispatchEvent } from '../lib/utils';
import { EmailIcon, WarningIcon, BuildingIcon, FINTAB_LOGO_SVG, DUMMY_ADMIN_BUSINESS_DATA } from '../constants';
import { notify } from './Toast';

const LANGUAGES = [
    { name: 'English', code: 'en', flag: '🇺🇸' },
    { name: 'Español', code: 'es', flag: '🇪🇸' },
    { name: 'Français', code: 'fr', flag: '🇫🇷' },
    { name: 'Kreyòl', code: 'ht', flag: '🇭🇹' },
];

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

        const redirectPath = sessionStorage.getItem('fintab_redirect_after_login');
        if (redirectPath) {
            sessionStorage.removeItem('fintab_redirect_after_login');
            navigate(redirectPath.startsWith('/') ? redirectPath : '/' + redirectPath);
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
        
        // Manual Local Bypass: Do NOT call handleAuth or Supabase
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
        
        // Injecting authorization markers directly into storage
        localStorage.setItem('fintab_active_business_id', demoBizId);
        setStoredItemAndDispatchEvent('fintab_simulator_session', demoUser);
        
        // Ensure the registry contains the demo node definition
        const registry = getStoredItem('fintab_businesses_registry', []);
        if (!registry.find(b => b.id === demoBizId)) {
            const demoBiz = DUMMY_ADMIN_BUSINESS_DATA.find(b => b.id === demoBizId);
            if (demoBiz) {
                setStoredItemAndDispatchEvent('fintab_businesses_registry', [...registry, demoBiz]);
            }
        }
        
        sessionStorage.setItem('fintab_welcome_message', "Welcome Mr. Demo to FinTab Demo Node");
        
        // Synchronized Teleportation
        setTimeout(() => {
            navigate('/dashboard');
            window.location.reload();
        }, 600);
    };

    if (showVerificationNotice) {
        return (
            <div className="fixed inset-0 bg-slate-50 dark:bg-gray-950 flex flex-col items-center justify-center p-6 z-[100] animate-fade-in overflow-y-auto">
                <div className="bg-white dark:bg-gray-900 p-8 sm:p-12 rounded-[3.5rem] shadow-2xl text-center max-w-md border border-slate-100 dark:border-gray-800 animate-scale-in w-full my-auto">
                    <div className="w-20 h-20 bg-primary/10 rounded-3xl flex items-center justify-center mx-auto mb-8">
                        <EmailIcon className="w-10 h-10 text-primary" />
                    </div>
                    <h2 className="text-3xl font-black uppercase tracking-tighter text-slate-900 dark:text-white">Verify Email</h2>
                    <div className="text-slate-500 dark:text-slate-400 mt-4 leading-relaxed font-medium">
                        We sent an activation link to:<br/>
                        <span className="font-black text-slate-900 dark:text-white">{email}</span>
                    </div>
                    <div className="space-y-4 mt-10">
                        <button onClick={() => window.location.reload()} className="w-full bg-primary text-white py-5 rounded-2xl font-black uppercase text-[10px] tracking-widest shadow-xl active:scale-95 transition-all">
                            I've Verified My Email
                        </button>
                        <button onClick={() => { setShowVerificationNotice(false); setIsLoginMode(true); }} className="w-full bg-white border border-slate-100 dark:bg-gray-800 dark:border-gray-700 text-slate-400 py-4 rounded-2xl font-black uppercase text-[10px] tracking-widest active:scale-95 transition-all">
                            Back to Login
                        </button>
                    </div>
                </div>
            </div>
        );
    }

    const inputClass = "w-full bg-slate-50 dark:bg-gray-800 border-none rounded-2xl p-5 text-sm font-bold text-slate-900 dark:text-white placeholder-slate-400 focus:ring-4 focus:ring-primary/10 transition-all outline-none caret-primary";

    return (
        <div className="fixed inset-0 bg-[#F8FAFC] dark:bg-gray-950 overflow-y-auto custom-scrollbar font-sans">
            <div className="fixed inset-0 pointer-events-none overflow-hidden opacity-40 dark:opacity-20">
                <div className="absolute top-[-10%] right-[-10%] w-[60%] h-[60%] bg-primary/20 rounded-full blur-[120px]"></div>
            </div>

            <div className="min-h-full flex flex-col items-center justify-center p-8 sm:p-12 lg:p-20">
                <div className="w-full max-w-[480px] relative z-10 flex flex-col items-center">
                    <div className="text-center mb-10 w-full">
                        <div className="w-20 h-20 mx-auto mb-6 drop-shadow-xl animate-scale-in">
                            <img src={FINTAB_LOGO_SVG} alt="Logo" className="w-full h-full object-contain" />
                        </div>
                        <p className="text-[10px] font-bold text-slate-400 dark:text-slate-500 uppercase tracking-[0.6em] mt-4 ml-[0.6em]">
                            Authorization Hub
                        </p>
                    </div>

                    <div className="bg-white/80 dark:bg-gray-900/90 backdrop-blur-2xl p-8 sm:p-12 rounded-[4rem] shadow-xl border border-white dark:border-gray-800 w-full">
                        <form onSubmit={handleAuth} className="space-y-8">
                            {error && (
                                <div className="p-4 bg-rose-50 text-rose-600 text-[10px] font-black uppercase tracking-widest rounded-2xl text-center border border-rose-100 animate-shake">
                                    {error}
                                </div>
                            )}
                            
                            {!isLoginMode && !isForgotPasswordMode && (
                                <div className="space-y-6 animate-fade-in">
                                    <input 
                                        type="text" 
                                        placeholder="Full Legal Name" 
                                        required 
                                        value={fullName} 
                                        onChange={e => setFullName(e.target.value)} 
                                        className={inputClass} 
                                    />
                                </div>
                            )}

                            <div className="space-y-4">
                                <input 
                                    type="email" 
                                    placeholder="Identity Email" 
                                    required 
                                    value={email} 
                                    onChange={e => setEmail(e.target.value)} 
                                    className={inputClass} 
                                />
                                {!isForgotPasswordMode && (
                                    <div className="space-y-2">
                                        <input 
                                            type="password" 
                                            placeholder="Security Password" 
                                            required 
                                            value={password} 
                                            onChange={e => setPassword(e.target.value)} 
                                            className={inputClass} 
                                        />
                                        {!isLoginMode && <PasswordStrengthIndicator password={password} />}
                                    </div>
                                )}
                            </div>

                            {!isLoginMode && !isForgotPasswordMode && !sessionStorage.getItem('fintab_join_token') && (
                                <div className="space-y-4 pt-8 border-t dark:border-gray-800 animate-fade-in">
                                    <p className="text-[10px] font-black text-primary uppercase tracking-[0.3em] px-1">Organization Protocol</p>
                                    <input 
                                        type="text" 
                                        placeholder="Organization Name" 
                                        required 
                                        value={businessName} 
                                        onChange={e => setBusinessName(e.target.value)} 
                                        className={inputClass} 
                                    />
                                </div>
                            )}
                            
                            <div className="space-y-4">
                                <button 
                                    type="submit" 
                                    disabled={isLoading} 
                                    className="w-full bg-slate-900 dark:bg-primary text-white py-6 rounded-[2rem] font-black uppercase text-[11px] tracking-[0.25em] shadow-xl active:scale-95 transition-all flex items-center justify-center gap-3"
                                >
                                    {isLoading ? <div className="w-5 h-5 border-3 border-white/30 border-t-white rounded-full animate-spin"></div> : (isForgotPasswordMode ? 'Transmit Rescue Link' : (isLoginMode ? 'Authorize Entry' : 'Enroll Identity'))}
                                </button>
                                
                                {isLoginMode && !isForgotPasswordMode && (
                                    <button 
                                        type="button"
                                        onClick={handleDemoMode}
                                        disabled={isLoading}
                                        className="w-full bg-amber-50 dark:bg-amber-900/10 text-amber-700 dark:text-amber-400 py-4 rounded-[2rem] font-black uppercase text-[10px] tracking-[0.3em] border-2 border-amber-100 dark:border-amber-900/30 hover:bg-amber-100 transition-all active:scale-95 flex items-center justify-center gap-2"
                                    >
                                        {isLoading ? <div className="w-5 h-5 border-3 border-amber-400/30 border-t-amber-500 rounded-full animate-spin"></div> : <><span className="text-lg">✨</span> Explore Demo Node</>}
                                    </button>
                                )}
                            </div>
                        </form>

                        <div className="mt-10 pt-8 border-t dark:border-gray-800 text-center">
                            <button 
                                onClick={() => { setIsForgotPasswordMode(false); setIsLoginMode(!isLoginMode); }} 
                                className="text-[10px] font-black uppercase text-slate-400 hover:text-primary transition-colors tracking-widest"
                            >
                                {isForgotPasswordMode ? 'Return to Authorization' : (isLoginMode ? 'Request New Enrollment' : 'Already Enrolled? Sign In')}
                            </button>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    );
};

export default Login;
