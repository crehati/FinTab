
// @ts-nocheck
import React, { useState, useEffect } from 'react';
import type { User, Role, ReceiptSettingsData } from '../types';
import ModalShell from './ModalShell';
import { supabase, isSupabaseConfigured } from '../lib/supabase';
import { notify } from './Toast';

interface UserModalProps {
    isOpen: boolean;
    onClose: () => void;
    onSave: (userData: Omit<User, 'id' | 'avatarUrl'>, isEditing: boolean) => void;
    userToEdit: User | null;
    receiptSettings: ReceiptSettingsData;
    defaultRole?: Role;
    existingUsers?: User[];
    currentUser?: User;
}

const getInitialFormData = () => ({
    name: '',
    email: '',
    role: 'Cashier' as Role,
    customRoleName: '',
    type: 'commission' as 'commission' | 'hourly',
    hourlyRate: '' as string | number,
    initialInvestment: '' as string | number,
});

const manageableRoles: Role[] = ['Manager', 'Cashier', 'SellerAgent', 'BankVerifier', 'Investor', 'Custom'];

const UserModal: React.FC<UserModalProps> = ({ isOpen, onClose, onSave, userToEdit, receiptSettings, defaultRole, existingUsers = [], currentUser }) => {
    const [formData, setFormData] = useState(getInitialFormData());
    const [error, setError] = useState<string | null>(null);
    const [isSaving, setIsSaving] = useState(false);
    const [invitationLink, setInvitationLink] = useState<string | null>(null);

    const isEditing = !!userToEdit;
    const cs = receiptSettings.currencySymbol;
    const isInvestorRole = formData.role === 'Investor';

    useEffect(() => {
        if (isOpen) {
            setError(null);
            setIsSaving(false);
            setInvitationLink(null);
            if (userToEdit) {
                setFormData({
                    name: userToEdit.name,
                    email: userToEdit.email,
                    role: userToEdit.role,
                    customRoleName: userToEdit.customRoleName || '',
                    type: userToEdit.type,
                    hourlyRate: userToEdit.hourlyRate || 0,
                    initialInvestment: userToEdit.initialInvestment || 0,
                });
            } else {
                 setFormData(prev => ({
                    ...getInitialFormData(),
                    role: defaultRole || 'Cashier'
                }));
            }
        }
    }, [isOpen, userToEdit, defaultRole]);
    
    const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
        const { name, value } = e.target;
        setFormData(prev => ({ ...prev, [name]: value }));
    };

    const handleTypeChange = (type: 'commission' | 'hourly') => {
        setFormData(prev => ({ ...prev, type }));
    };

    const handleSubmit = async (e: React.FormEvent) => {
        e.preventDefault();
        
        if (!isEditing) {
            const emailTaken = existingUsers.some(u => u.email.toLowerCase() === formData.email.toLowerCase());
            if (emailTaken) {
                setError("Protocol Error: Email already registered in this node.");
                return;
            }
        }

        setIsSaving(true);
        const dataToSave = {
            ...formData,
            hourlyRate: parseFloat(String(formData.hourlyRate)) || 0,
            initialInvestment: parseFloat(String(formData.initialInvestment)) || 0,
        };

        try {
            if (!isEditing && isSupabaseConfigured) {
                const businessId = localStorage.getItem('fintab_active_business_id');
                const { data, error: inviteErr } = await supabase
                    .from('fintab_invitations')
                    .insert([{
                        business_id: businessId,
                        business_name: receiptSettings.businessName,
                        email: formData.email,
                        role: formData.role,
                        role_label: formData.customRoleName || formData.role,
                        user_type: formData.type,
                        hourly_rate: dataToSave.hourly_rate,
                        initial_investment: dataToSave.initial_investment,
                        invited_by: currentUser?.name || 'Owner'
                    }])
                    .select()
                    .single();

                if (inviteErr) throw inviteErr;

                // BULLETPROOF LINK GENERATION:
                // We take the full current URL and strip everything after the '#'
                // This handles cases where the app is in a subfolder or has 'index.html' in the URL.
                const baseUrl = window.location.href.split('#')[0];
                const link = `${baseUrl}#/join/${data.id}`;
                
                setInvitationLink(link);
                notify("Invitation Link Generated", "success");
            }
            
            await onSave(dataToSave, isEditing);
            if (isEditing) onClose();
        } catch (err) {
            setError(err.message || "Failed to initialize enrollment.");
            notify("Handshake Issuance Failure", "error");
        } finally {
            setIsSaving(false);
        }
    };

    const handleCopyLink = () => {
        if (!invitationLink) return;
        navigator.clipboard.writeText(invitationLink);
        notify("Link Copied to Clipboard", "success");
    };

    const footer = (
        <>
            {!invitationLink ? (
                <>
                    <button onClick={handleSubmit} className="btn-base btn-primary flex-1 py-4" disabled={isSaving}>
                        {isSaving && <div className="w-4 h-4 border-2 border-white/30 border-t-white rounded-full animate-spin mr-2"></div>}
                        {isEditing ? 'Confirm Update' : 'Generate Invite Link'}
                    </button>
                    <button onClick={onClose} className="btn-base btn-secondary px-8 py-4" disabled={isSaving}>
                        Abort
                    </button>
                </>
            ) : (
                <button onClick={onClose} className="btn-base btn-primary w-full py-4">Done</button>
            )}
        </>
    );

    return (
        <ModalShell
            isOpen={isOpen}
            onClose={onClose}
            title={isEditing ? 'Edit Identity' : 'Enroll Personnel'}
            description="System Authorization Handshake"
            maxWidth="max-w-md"
            footer={footer}
        >
            {invitationLink ? (
                <div className="space-y-8 py-4 animate-scale-in text-center">
                    <div className="w-20 h-20 bg-emerald-50 rounded-[2rem] flex items-center justify-center mx-auto text-emerald-500 shadow-inner">
                        <svg className="w-10 h-10" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}><path d="M5 13l4 4L19 7" /></svg>
                    </div>
                    <div>
                        <h3 className="text-xl font-black text-slate-900 uppercase tracking-tighter">Invite Ready</h3>
                        <p className="text-xs text-slate-400 font-bold uppercase tracking-widest mt-2 px-6">Send this link to {formData.name}. If they see a 404, ensure they are using a modern browser.</p>
                    </div>
                    <div className="bg-slate-50 p-4 rounded-2xl border-2 border-dashed border-slate-200 break-all text-[10px] font-mono font-bold text-primary select-all">
                        {invitationLink}
                    </div>
                    <button onClick={handleCopyLink} className="w-full py-4 bg-slate-900 text-white rounded-xl font-black uppercase text-[10px] tracking-widest shadow-xl active:scale-95 transition-all">Copy Invitation Link</button>
                </div>
            ) : (
                <div className="space-y-6">
                    {error && (
                        <div className="p-4 bg-rose-50 text-rose-600 text-[10px] font-bold uppercase tracking-widest rounded-xl border border-rose-100 text-center animate-shake">
                            {error}
                        </div>
                    )}
                    
                    <div>
                        <label className="block text-[9px] font-black text-slate-400 uppercase tracking-widest mb-2 px-1">Full Legal Name</label>
                        <input type="text" name="name" value={formData.name} onChange={handleChange} required className="w-full bg-slate-50 dark:bg-gray-900 border-none rounded-2xl p-4 text-sm font-bold outline-none focus:ring-4 focus:ring-primary/10 transition-all" placeholder="Staff Name" />
                    </div>

                    <div>
                        <label className="block text-[9px] font-black text-slate-400 uppercase tracking-widest mb-2 px-1">Email Address</label>
                        <input type="email" name="email" value={formData.email} onChange={handleChange} required disabled={isEditing} className="w-full bg-slate-50 dark:bg-gray-900 border-none rounded-2xl p-4 text-sm font-bold outline-none focus:ring-4 focus:ring-primary/10 transition-all disabled:opacity-50" placeholder="staff@business.com" />
                    </div>

                    <div className="grid grid-cols-2 gap-4">
                        <div>
                            <label className="block text-[9px] font-black text-slate-400 uppercase tracking-widest mb-2 px-1">Role</label>
                            <select name="role" value={formData.role} onChange={handleChange} className="w-full bg-slate-50 dark:bg-gray-900 border-none rounded-2xl p-4 text-sm font-bold outline-none focus:ring-4 focus:ring-primary/10">
                                {manageableRoles.map(role => <option key={role} value={role}>{role}</option>)}
                            </select>
                        </div>
                        {formData.role === 'Custom' && (
                            <div>
                                <label className="block text-[9px] font-black text-slate-400 uppercase tracking-widest mb-2 px-1">Label</label>
                                <input type="text" name="customRoleName" value={formData.customRoleName} onChange={handleChange} className="w-full bg-slate-50 dark:bg-gray-900 border-none rounded-2xl p-4 text-sm font-bold outline-none" placeholder="e.g. Sales Lead" />
                            </div>
                        )}
                    </div>

                    {!isInvestorRole && (
                        <div className="pt-2">
                            <label className="block text-[9px] font-black text-slate-400 uppercase tracking-widest mb-2 px-1">Payout Logic</label>
                            <div className="grid grid-cols-2 gap-4">
                                <button type="button" onClick={() => handleTypeChange('commission')} className={`p-4 rounded-2xl border-2 text-[10px] font-black uppercase tracking-widest transition-all ${formData.type === 'commission' ? 'bg-primary/5 border-primary text-primary shadow-inner' : 'bg-white dark:bg-gray-900 border-slate-100 dark:border-gray-800 text-slate-400'}`}>Commission %</button>
                                <button type="button" onClick={() => handleTypeChange('hourly')} className={`p-4 rounded-2xl border-2 text-[10px] font-black uppercase tracking-widest transition-all ${formData.type === 'hourly' ? 'bg-primary/5 border-primary text-primary shadow-inner' : 'bg-white dark:bg-gray-900 border-slate-100 dark:border-gray-800 text-slate-400'}`}>Hourly Rate</button>
                            </div>
                        </div>
                    )}

                    {formData.type === 'hourly' && !isInvestorRole && (
                        <div className="animate-fade-in">
                            <label className="block text-[9px] font-black text-slate-400 uppercase tracking-widest mb-2 px-1">Hourly Value ({cs})</label>
                            <input type="number" name="hourlyRate" value={formData.hourlyRate} onChange={handleChange} className="w-full bg-slate-50 dark:bg-gray-900 border-none rounded-2xl p-4 text-lg font-black outline-none tabular-nums" placeholder="0.00" />
                        </div>
                    )}
                    
                    {isInvestorRole && (
                        <div className="animate-fade-in">
                            <label className="block text-[9px] font-black text-slate-400 uppercase tracking-widest mb-2 px-1">Initial Investment ({cs})</label>
                            <input type="number" name="initialInvestment" value={formData.initialInvestment} onChange={handleChange} className="w-full bg-slate-50 dark:bg-gray-900 border-none rounded-2xl p-4 text-lg font-black outline-none tabular-nums" placeholder="0" />
                        </div>
                    )}
                </div>
            )}
        </ModalShell>
    );
};

export default UserModal;
