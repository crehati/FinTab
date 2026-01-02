
// @ts-nocheck
import React, { useState, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import { supabase, isSupabaseConfigured } from '../lib/supabase';
import PasswordStrengthIndicator from './PasswordStrengthIndicator';
import { getStoredItem, setStoredItemAndDispatchEvent } from '../lib/utils';
import { EmailIcon } from '../constants';

const Login: React.FC<any> = ({ onEnterDemo }) => {
    const navigate = useNavigate();
    const [isLoginMode, setIsLoginMode] = useState(true);
    const [isForgotPasswordMode, setIsForgotPasswordMode] = useState(false);
    const [isLoading, setIsLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [showVerificationNotice, setShowVerificationNotice] = useState(false);

    const [email, setEmail] = useState('');
    const [password, setPassword] = useState('');
    const [fullName, setFullName] = useState('');

    const handleAuth = async (e: React.FormEvent) => {
        e.preventDefault();
        setIsLoading(true);
        setError(null);

        try {
            if (isSupabaseConfigured) {
                if (isForgotPasswordMode) {
                    await supabase.auth.resetPasswordForEmail(email);
                    alert("Sync: Reset link dispatched.");
                    setIsForgotPasswordMode(false);
                } else if (isLoginMode) {
                    const { error } = await supabase.auth.signInWithPassword({ email, password });
                    if (error) throw error;
                } else {
                    const { error } = await supabase.auth.signUp({ 
                        email, 
                        password, 
                        options: { data: { full_name: fullName } } 
                    });
                    if (error) throw error;
                    setShowVerificationNotice(true);
                }
            } else {
                // Local Simulator Logic
                const mockUsers = getStoredItem('fintab_mock_auth_users', []);
                if (isLoginMode) {
                    const found = mockUsers.find(u => u.email === email && u.password === password);
                    if (found) {
                         setStoredItemAndDispatchEvent('fintab_simulator_session', found);
                         window.location.reload(); // Force app initialization
                    }
                    else setError("Invalid credentials in local node.");
                } else {
                    const newUser = { id: `u-${Date.now()}`, email, password, name: fullName };
                    mockUsers.push(newUser);
                    localStorage.setItem('fintab_mock_auth_users', JSON.stringify(mockUsers));
                    setStoredItemAndDispatchEvent('fintab_simulator_session', newUser);
                    window.location.reload();
                }
            }
        } catch (err) {
            setError(err.message || "Authorization failed.");
        } finally {
            setIsLoading(false);
        }
    };

    const handleGoogleAuth = async () => {
        if (!isSupabaseConfigured) { onEnterDemo(); return; }
        await supabase.auth.signInWithOAuth({ provider: 'google' });
    };

    if (showVerificationNotice) {
        return (
            <div className="min-h-screen bg-slate-50 dark:bg-gray-950 flex flex-col items-center justify-center p-8 font-sans">
                <div className="bg-white dark:bg-gray-900 p-12 rounded-[3rem] shadow-2xl text-center max-w-md border border-slate-100 dark:border-gray-800">
                    <div className="w-20 h-20 bg-primary/10 rounded-3xl flex items-center justify-center mx-auto mb-8">
                        <EmailIcon className="w-10 h-10 text-primary" />
                    </div>
                    <h2 className="text-3xl font-black uppercase tracking-tighter text-slate-900 dark:text-white">Check Protocol</h2>
                    <p className="text-slate-500 dark:text-slate-400 mt-4 leading-relaxed font-medium">Verification node dispatched to:<br/><span className="font-black text-slate-900 dark:text-white">{email}</span></p>
                    
                    <div className="space-y-4 mt-12">
                        <button onClick={() => setShowVerificationNotice(false)} className="w-full bg-slate-900 text-white py-4 rounded-2xl font-black uppercase text-[10px] tracking-widest active:scale-95 transition-all">Back to Sign In</button>
                        <div className="flex items-center gap-4 py-4">
                            <div className="h-px bg-slate-100 dark:bg-gray-800 flex-1"></div>
                            <span className="text-[9px] font-black text-slate-400 uppercase tracking-widest">OR</span>
                            <div className="h-px bg-slate-100 dark:bg-gray-800 flex-1"></div>
                        </div>
                        <button onClick={onEnterDemo} className="w-full py-4 bg-amber-50 dark:bg-amber-900/20 border-2 border-amber-200 dark:border-amber-800 text-amber-700 dark:text-amber-400 rounded-2xl font-black uppercase text-[10px] tracking-widest hover:bg-amber-100 transition-all flex items-center justify-center gap-3">
                            <span>✨</span> Launch Demo Node Instead
                        </button>
                    </div>
                </div>
            </div>
        );
    }

    return (
        <div className="min-h-screen bg-slate-50 dark:bg-gray-950 flex flex-col items-center justify-center p-6 font-sans">
            <div className="w-full max-w-[440px] space-y-8">
                <div className="text-center">
                    <h1 className="text-5xl font-black text-slate-900 dark:text-white tracking-tighter">FINTAB</h1>
                    <p className="text-[10px] font-bold text-slate-400 uppercase tracking-[0.4em] mt-4">Authorized Entry Node</p>
                </div>

                <div className="bg-white dark:bg-gray-900 p-10 rounded-[3rem] shadow-2xl border border-slate-100 dark:border-gray-800">
                    <form onSubmit={handleAuth} className="space-y-6">
                        {error && <div className="p-4 bg-rose-50 text-rose-600 text-xs font-bold rounded-xl text-center">{error}</div>}
                        
                        {!isLoginMode && (
                            <input type="text" placeholder="Full Identity Name" required value={fullName} onChange={e => setFullName(e.target.value)} className="w-full bg-slate-50 dark:bg-gray-800 rounded-xl p-4 text-sm font-bold outline-none border-2 border-transparent focus:border-primary/20 transition-all" />
                        )}
                        <input type="email" placeholder="Identity Email" required value={email} onChange={e => setEmail(e.target.value)} className="w-full bg-slate-50 dark:bg-gray-800 rounded-xl p-4 text-sm font-bold outline-none border-2 border-transparent focus:border-primary/20 transition-all" />
                        <input type="password" placeholder="Protocol Password" required value={password} onChange={e => setPassword(e.target.value)} className="w-full bg-slate-50 dark:bg-gray-800 rounded-xl p-4 text-sm font-bold outline-none border-2 border-transparent focus:border-primary/20 transition-all" />
                        
                        <button type="submit" disabled={isLoading} className="w-full bg-slate-900 text-white py-4 rounded-xl font-black uppercase text-[10px] tracking-widest shadow-xl active:scale-95 transition-all">
                            {isLoading ? 'Processing...' : isLoginMode ? 'Authorize Entry' : 'Enroll Identity'}
                        </button>
                    </form>

                    <div className="mt-8 pt-8 border-t dark:border-gray-800 space-y-6">
                        <button onClick={onEnterDemo} className="w-full py-4 bg-amber-50 dark:bg-amber-900/20 border-2 border-amber-200 dark:border-amber-800 rounded-2xl flex items-center justify-center gap-3 group hover:bg-amber-100 transition-all active:scale-95">
                            <span className="text-xl group-hover:rotate-12 transition-transform">✨</span>
                            <span className="text-[11px] font-black uppercase tracking-widest text-amber-700 dark:text-amber-400">Launch Demo Node</span>
                        </button>

                        <button onClick={handleGoogleAuth} className="w-full bg-white dark:bg-gray-800 border-2 border-slate-100 dark:border-gray-700 py-4 rounded-xl font-black uppercase text-[10px] tracking-widest flex items-center justify-center gap-3">
                            <span className="text-blue-500">G</span> Google Authorization
                        </button>
                        
                        <button onClick={() => setIsLoginMode(!isLoginMode)} className="w-full text-center text-[10px] font-black uppercase text-slate-400 hover:text-primary transition-colors">
                            {isLoginMode ? 'Request New Enrollment' : 'Already Enrolled? Sign In'}
                        </button>
                    </div>
                </div>
            </div>
        </div>
    );
};

export default Login;
