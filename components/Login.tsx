
// @ts-nocheck
import React, { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { supabase, isSupabaseConfigured } from '../lib/supabase';
import PasswordStrengthIndicator from './PasswordStrengthIndicator';
import { getStoredItem, setStoredItemAndDispatchEvent } from '../lib/utils';
import { EmailIcon, WarningIcon, BuildingIcon, FINTAB_LOGO_SVG } from '../constants';
import { notify } from './Toast';

const BUSINESS_TYPES = ['Retail', 'Restaurant', 'Service', 'Wholesale', 'Healthcare', 'Tech', 'Other'];
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
    const [showResetSuccess, setShowResetSuccess] = useState(false);

    // Identity State
    const [email, setEmail] = useState('');
    const [password, setPassword] = useState('');
    const [fullName, setFullName] = useState('');

    // Business Logic State
    const [businessName, setBusinessName] = useState('');
    const [businessType, setBusinessType] = useState('Retail');
    const [businessPhone, setBusinessPhone] = useState('');

    const handleRedirect = () => {
        const invitePath = sessionStorage.getItem('fintab_redirect_after_login');
        if (invitePath) {
            sessionStorage.removeItem('fintab_redirect_after_login');
            // If the path already has a slash, don't add another
            navigate(invitePath.startsWith('/') ? invitePath : '/' + invitePath);
        } else {
            navigate('/dashboard');
        }
    };

    // Redirect Check on Mount
    useEffect(() => {
        const checkSession = async () => {
            const { data: { session } } = await supabase.auth.getSession();
            if (session) handleRedirect();
        };
        if (isSupabaseConfigured) checkSession();
    }, [navigate]);

    const handleAuth = async (e: React.FormEvent) => {
        e.preventDefault();
        setIsLoading(true);
        setError(null);

        try {
            if (isSupabaseConfigured) {
                if (isForgotPasswordMode) {
                    const { error } = await supabase.auth.resetPasswordForEmail(email, {
                        redirectTo: window.location.origin,
                    });
                    if (error) throw error;
                    setShowResetSuccess(true);
                    notify("Reset Link Dispatched", "success");
                } else if (isLoginMode) {
                    const { error } = await supabase.auth.signInWithPassword({ email, password });
                    if (error) throw error;
                    notify("Authorization Verified", "success");
                    handleRedirect();
                } else {
                    // ACCOUNT CREATION (SIGN UP)
                    const { data, error } = await supabase.auth.signUp({ 
                        email, 
                        password, 
                        options: { 
                            data: { 
                                full_name: fullName,
                                biz_name: businessName, // Only present for Owners
                                biz_type: businessType,
                                biz_phone: businessPhone,
                                pref_lang: language 
                            } 
                        } 
                    });
                    if (error) throw error;
                    
                    // If user is automatically logged in (email confirm disabled in Supabase)
                    if (data?.session) {
                        notify("Identity Created", "success");
                        handleRedirect();
                    } else {
                        setShowVerificationNotice(true);
                        notify("Verification Required", "info");
                    }
                }
            } else {
                // Mock logic for demo mode...
                if (isLoginMode) {
                    const mockUsers = getStoredItem('fintab_mock_auth_users', []);
                    const found = mockUsers.find(u => u.email === email && u.password === password);
                    if (found) {
                         setStoredItemAndDispatchEvent('fintab_simulator_session', found);
                         window.location.reload(); 
                    } else {
                        setError("Invalid credentials.");
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

    const StatusNotice = ({ icon: Icon, title, message, actionLabel, onAction, secondaryActionLabel, onSecondaryAction }) => (
        <div className="fixed inset-0 bg-slate-50 dark:bg-gray-950 flex flex-col items-center justify-center p-6 z-[100] animate-fade-in overflow-y-auto">
            <div className="bg-white dark:bg-gray-900 p-8 sm:p-12 rounded-[3.5rem] shadow-2xl text-center max-w-md border border-slate-100 dark:border-gray-800 animate-scale-in w-full my-auto">
                <div className="w-20 h-20 bg-primary/10 rounded-3xl flex items-center justify-center mx-auto mb-8">
                    <Icon className="w-10 h-10 text-primary" />
                </div>
                <h2 className="text-3xl font-black uppercase tracking-tighter text-slate-900 dark:text-white">{title}</h2>
                <div className="text-slate-500 dark:text-slate-400 mt-4 leading-relaxed font-medium">{message}</div>
                
                <div className="space-y-4 mt-10">
                    <button onClick={onAction} className="w-full bg-primary text-white py-5 rounded-2xl font-black uppercase text-[10px] tracking-widest shadow-xl shadow-primary/20 active:scale-95 transition-all">
                        {actionLabel}
                    </button>
                    {secondaryActionLabel && (
                        <button onClick={onSecondaryAction} className="w-full bg-white border border-slate-100 dark:bg-gray-800 dark:border-gray-700 text-slate-400 py-4 rounded-2xl font-black uppercase text-[10px] tracking-widest active:scale-95 transition-all">
                            {secondaryActionLabel}
                        </button>
                    )}
                </div>
            </div>
        </div>
    );

    if (showVerificationNotice) {
        return (
            <StatusNotice 
                icon={EmailIcon}
                title="Verify Identity"
                message={<>Authentication sent to:<br/><span className="font-black text-slate-900 dark:text-white">{email}</span></>}
                actionLabel="I've Verified My Email"
                onAction={() => window.location.reload()}
                secondaryActionLabel="Back to Login"
                onSecondaryAction={() => { setShowVerificationNotice(false); setIsLoginMode(true); }}
            />
        );
    }

    if (showResetSuccess) {
        return (
            <StatusNotice 
                icon={EmailIcon}
                title="Link Sent"
                message={<>Reset link sent to:<br/><span className="font-black text-slate-900 dark:text-white">{email}</span></>}
                actionLabel="Return to Sign In"
                onAction={() => { setShowResetSuccess(false); setIsForgotPasswordMode(false); setIsLoginMode(true); }}
            />
        );
    }

    return (
        <div className="fixed inset-0 bg-[#F8FAFC] dark:bg-gray-950 overflow-y-auto custom-scrollbar font-sans">
            <div className="fixed inset-0 pointer-events-none overflow-hidden opacity-40 dark:opacity-20">
                <div className="absolute top-[-10%] right-[-10%] w-[60%] h-[60%] bg-primary/20 rounded-full blur-[120px] animate-pulse"></div>
            </div>

            <div className="min-h-full flex flex-col items-center justify-center p-8 sm:p-12 lg:p-20">
                <div className="w-full max-w-[480px] relative z-10 flex flex-col items-center">
                    <div className="text-center mb-10 w-full">
                        <div className="w-20 h-20 mx-auto mb-6 drop-shadow-xl animate-scale-in">
                            <img src={FINTAB_LOGO_SVG} alt="Logo" className="w-full h-full object-contain" />
                        </div>
                        <p className="text-[10px] font-bold text-slate-400 dark:text-slate-500 uppercase tracking-[0.6em] mt-4 ml-[0.6em]">
                            {isForgotPasswordMode ? 'Credential Rescue' : 'Authorization Hub'}
                        </p>
                    </div>

                    <div className="bg-white/80 dark:bg-gray-900/90 backdrop-blur-2xl p-8 sm:p-12 rounded-[4rem] shadow-[0_32px_64px_-16px_rgba(0,0,0,0.1)] border border-white dark:border-gray-800 w-full">
                        <form onSubmit={handleAuth} className="space-y-8">
                            {error && (
                                <div className="p-4 bg-rose-50 dark:bg-rose-950/30 text-rose-600 dark:text-rose-400 text-[10px] font-black uppercase tracking-widest rounded-2xl text-center border border-rose-100 dark:border-rose-900/50 animate-shake">
                                    {error}
                                </div>
                            )}
                            
                            {!isLoginMode && !isForgotPasswordMode && (
                                <div className="space-y-6 animate-fade-in">
                                    <div className="space-y-4">
                                        <h3 className="text-[10px] font-black uppercase tracking-[0.3em] text-slate-400 px-1">Identity</h3>
                                        <input 
                                            type="text" 
                                            placeholder="Full Legal Name" 
                                            required 
                                            value={fullName} 
                                            onChange={e => setFullName(e.target.value)} 
                                            className="w-full bg-slate-50 dark:bg-gray-800 border-2 border-transparent focus:border-primary/20 focus:bg-white dark:focus:bg-gray-700 rounded-[1.5rem] p-5 text-sm font-bold outline-none transition-all" 
                                        />
                                    </div>
                                </div>
                            )}

                            <div className="space-y-4">
                                <input 
                                    type="email" 
                                    placeholder="Identity Email" 
                                    required 
                                    value={email} 
                                    onChange={e => setEmail(e.target.value)} 
                                    className="w-full bg-slate-50 dark:bg-gray-800 border-2 border-transparent focus:border-primary/20 focus:bg-white dark:focus:bg-gray-700 rounded-[1.5rem] p-5 text-sm font-bold outline-none transition-all" 
                                />
                                {!isForgotPasswordMode && (
                                    <div className="space-y-2">
                                        <input 
                                            type="password" 
                                            placeholder="Security Password" 
                                            required 
                                            value={password} 
                                            onChange={e => setPassword(e.target.value)} 
                                            className="w-full bg-slate-50 dark:bg-gray-800 border-2 border-transparent focus:border-primary/20 focus:bg-white dark:focus:bg-gray-700 rounded-[1.5rem] p-5 text-sm font-bold outline-none transition-all" 
                                        />
                                        {!isLoginMode && <PasswordStrengthIndicator password={password} />}
                                    </div>
                                )}
                            </div>

                            {!isLoginMode && !isForgotPasswordMode && !sessionStorage.getItem('fintab_redirect_after_login') && (
                                <div className="space-y-4 pt-8 border-t dark:border-gray-800 animate-fade-in">
                                    <div className="flex items-center gap-3 px-1 mb-2">
                                        <div className="w-1.5 h-1.5 rounded-full bg-primary animate-pulse"></div>
                                        <h3 className="text-[10px] font-black uppercase tracking-[0.3em] text-primary">New Business Node</h3>
                                    </div>
                                    <div className="p-6 bg-slate-50 dark:bg-gray-800/50 rounded-[2.5rem] border border-slate-100 dark:border-gray-800 space-y-4">
                                        <input 
                                            type="text" 
                                            placeholder="Organization Name" 
                                            required={!sessionStorage.getItem('fintab_redirect_after_login')} 
                                            value={businessName} 
                                            onChange={e => setBusinessName(e.target.value)} 
                                            className="w-full bg-white dark:bg-gray-800 border-2 border-transparent focus:border-primary/20 rounded-2xl p-4 text-sm font-bold outline-none" 
                                        />
                                    </div>
                                </div>
                            )}
                            
                            <button 
                                type="submit" 
                                disabled={isLoading} 
                                className="w-full bg-slate-900 dark:bg-primary text-white py-6 rounded-[2rem] font-black uppercase text-[11px] tracking-[0.25em] shadow-xl active:scale-95 transition-all flex items-center justify-center gap-3"
                            >
                                {isLoading ? (
                                    <div className="w-5 h-5 border-3 border-white/30 border-t-white rounded-full animate-spin"></div>
                                ) : (
                                    isForgotPasswordMode ? 'Get Reset Link' : (isLoginMode ? 'Authorize Entry' : 'Create Account')
                                )}
                            </button>
                        </form>

                        <div className="mt-12 pt-8 border-t dark:border-gray-800">
                            <button 
                                onClick={() => { setIsForgotPasswordMode(false); setIsLoginMode(!isLoginMode); }} 
                                className="w-full text-[10px] font-black uppercase text-slate-400 hover:text-primary transition-colors tracking-widest"
                            >
                                {isForgotPasswordMode ? 'Back to Sign In' : (isLoginMode ? 'Need an account?' : 'Already have an account? Sign In')}
                            </button>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    );
};

export default Login;
