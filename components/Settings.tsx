
import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import type { User, ReceiptSettingsData } from '../types';
import { SettingsIcon, CrownIcon, ReceiptsIcon, BriefcaseIcon, StaffIcon, PrintIcon } from '../constants';

interface SettingsProps {
    language: string;
    setLanguage: (langCode: string) => void;
    t: (key: string) => string;
    currentUser: User;
    receiptSettings: ReceiptSettingsData;
    setReceiptSettings: (settings: ReceiptSettingsData) => void;
    theme: 'light' | 'dark';
    setTheme: (theme: 'light' | 'dark') => void;
}

const Settings: React.FC<SettingsProps> = ({ language, setLanguage, t, currentUser, receiptSettings, setReceiptSettings, theme, setTheme }) => {
    const navigate = useNavigate();
    
    const isPrivileged = currentUser.role === 'Owner' || currentUser.role === 'Super Admin' || currentUser.role === 'Manager';

    const nodes = [
        { title: 'Receipt Design', desc: 'Visual identity & document logic', icon: <ReceiptsIcon />, to: '/settings/receipts', auth: true },
        { title: 'Business Profile', desc: 'Organization node data', icon: <BriefcaseIcon />, to: '/settings/business', auth: isPrivileged },
        { title: 'Access Control', desc: 'Authorization matrix & staff', icon: <StaffIcon />, to: '/settings/permissions', auth: isPrivileged },
        { title: 'Owner Controls', desc: 'Principal ledger overrides', icon: <CrownIcon />, to: '/settings/owner', auth: currentUser.role === 'Owner' },
        { title: 'Hardware Node', desc: 'Printer & POS integration', icon: <PrintIcon />, to: '/settings/printer', auth: true },
    ];

    return (
        <div className="max-w-5xl mx-auto space-y-12 pb-32 animate-fade-in font-sans">
            <div className="bg-slate-900 rounded-[3rem] p-12 text-white shadow-2xl relative overflow-hidden border border-white/5">
                <div className="absolute top-0 right-0 w-[400px] h-[400px] bg-primary/20 rounded-full -mr-40 -mt-40 blur-[120px]"></div>
                <div className="relative flex items-center gap-10">
                    <div className="w-20 h-20 bg-white/5 backdrop-blur-xl rounded-3xl flex items-center justify-center border border-white/10 shadow-inner">
                        <SettingsIcon className="w-10 h-10 text-primary" />
                    </div>
                    <div>
                        <h1 className="text-4xl font-black uppercase tracking-tighter leading-none">Settings</h1>
                        <p className="text-[11px] font-bold text-slate-500 uppercase tracking-[0.5em] mt-4">System Node Configuration</p>
                    </div>
                </div>
            </div>

            <div className="grid grid-cols-1 lg:grid-cols-12 gap-10">
                <div className="lg:col-span-4 space-y-8">
                    <div className="bg-white dark:bg-gray-900 p-8 rounded-[2.5rem] shadow-xl border border-slate-50">
                        <h3 className="text-[10px] font-black uppercase tracking-widest text-slate-400 mb-8 px-2">Interface Protocol</h3>
                        <div className="space-y-4">
                            <button onClick={() => setTheme(theme === 'light' ? 'dark' : 'light')} className="w-full flex items-center justify-between p-6 bg-slate-50 dark:bg-gray-800 rounded-2xl group transition-all active:scale-[0.98]">
                                <span className="text-xs font-black uppercase tracking-widest text-slate-900 dark:text-white">Dark Mode</span>
                                <div className={`w-12 h-7 rounded-full border-2 transition-all ${theme === 'dark' ? 'bg-primary border-primary' : 'bg-slate-200 border-slate-300'}`}>
                                    <div className={`w-5 h-5 bg-white rounded-full shadow-sm transform transition-transform ${theme === 'dark' ? 'translate-x-5' : ''}`}></div>
                                </div>
                            </button>
                        </div>
                    </div>
                </div>

                <div className="lg:col-span-8">
                    <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                        {nodes.filter(n => n.auth).map(node => (
                            <button 
                                key={node.to} 
                                onClick={() => navigate(node.to)}
                                className="p-8 bg-white dark:bg-gray-900 rounded-[2.5rem] border-2 border-slate-50 dark:border-gray-800 transition-all hover:border-primary/20 hover:shadow-2xl hover:-translate-y-1 text-left group flex flex-col justify-between h-56"
                            >
                                <div className="w-14 h-14 bg-slate-50 dark:bg-gray-800 rounded-2xl flex items-center justify-center text-slate-400 group-hover:text-primary transition-all shadow-inner">
                                    {node.icon}
                                </div>
                                <div>
                                    <h4 className="text-sm font-black text-slate-900 dark:text-white uppercase tracking-tight">{node.title}</h4>
                                    <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest mt-1">{node.desc}</p>
                                </div>
                            </button>
                        ))}
                    </div>
                </div>
            </div>
        </div>
    );
};

export default Settings;
