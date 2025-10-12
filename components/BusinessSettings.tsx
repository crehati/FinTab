import React, { useState, useEffect, useRef } from 'react';
import type { BusinessSettingsData, BusinessProfile, User } from '../types';
import Card from './Card';
import DestructiveConfirmationModal from './DestructiveConfirmationModal';
import { CreditCardIcon, TruckIcon, CalculatorIcon, PlusIcon, DeleteIcon, ChevronDownIcon, InvestorIcon, BuildingIcon, StorefrontIcon, ProfileIcon } from '../constants';
import { COUNTRIES } from '../constants';

interface BusinessSettingsProps {
    settings: BusinessSettingsData;
    onUpdateSettings: (settings: BusinessSettingsData) => void;
    businessProfile: BusinessProfile | null;
    onUpdateBusinessProfile: (profile: BusinessProfile | null) => void;
    onResetBusiness: () => void;
    t: (key: string) => string;
    currentUser: User;
    onUpdateCurrentUserProfile: (profileData: { name?: string; avatarUrl?: string; phone?: string; initialInvestment?: number; }) => void;
}

const SectionCard: React.FC<{ title: string; description: string; icon: React.ReactNode; children: React.ReactNode; }> = ({ title, description, icon, children }) => (
    <div className="bg-white dark:bg-gray-800 rounded-lg shadow-md overflow-hidden">
        <div className="p-6 border-b bg-gray-50/50 dark:bg-gray-700/50">
            <div className="flex items-start gap-4">
                <div className="flex-shrink-0 text-primary">{icon}</div>
                <div>
                    <h3 className="text-lg font-semibold text-gray-800 dark:text-gray-200">{title}</h3>
                    <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">{description}</p>
                </div>
            </div>
        </div>
        <div className="p-6 space-y-4">
            {children}
        </div>
    </div>
);

const Input: React.FC<any> = ({ name, label, ...props }) => (
  <div>
    <label htmlFor={name} className="block text-sm font-medium text-gray-700 dark:text-gray-300">{label}</label>
    <input
      id={name}
      name={name}
      className="mt-1"
      {...props}
    />
  </div>
);

const Toggle: React.FC<{ label: string; description: string; name: string; checked: boolean; onChange: (e: React.ChangeEvent<HTMLInputElement>) => void }> = ({ label, description, name, checked, onChange }) => (
    <div className="flex items-center justify-between p-3 rounded-md border bg-gray-50/50 dark:bg-gray-700/50 dark:border-gray-600">
        <div>
            <label htmlFor={name} className="font-medium text-gray-700 dark:text-gray-200">{label}</label>
            <p className="text-xs text-gray-500 dark:text-gray-400">{description}</p>
        </div>
        <label htmlFor={name} className="flex items-center cursor-pointer">
            <div className="relative">
                <input type="checkbox" id={name} name={name} checked={checked} onChange={onChange} className="sr-only" />
                <div className={`block ${checked ? 'bg-primary' : 'bg-gray-300 dark:bg-gray-600'} w-14 h-8 rounded-full`}></div>
                <div className={`dot absolute left-1 top-1 bg-white w-6 h-6 rounded-full transition-transform transform ${checked ? 'translate-x-6' : ''}`}></div>
            </div>
        </label>
    </div>
);

const BusinessSettings: React.FC<BusinessSettingsProps> = ({ settings, onUpdateSettings, businessProfile, onUpdateBusinessProfile, onResetBusiness, t, currentUser, onUpdateCurrentUserProfile }) => {
    const [draftSettings, setDraftSettings] = useState<any>(settings);
    const [draftProfile, setDraftProfile] = useState(businessProfile);
    const [draftOwner, setDraftOwner] = useState<any>({ name: '', avatarUrl: '', initialInvestment: 0 });
    const [ownerPhone, setOwnerPhone] = useState({ countryCode: '+1', localPhone: '' });
    const [newPaymentMethod, setNewPaymentMethod] = useState('');
    const [isResetModalOpen, setIsResetModalOpen] = useState(false);
    const [copySuccess, setCopySuccess] = useState('');
    const businessLogoInputRef = useRef<HTMLInputElement>(null);
    const ownerAvatarInputRef = useRef<HTMLInputElement>(null);

    const shopfrontUrl = `${window.location.origin}${window.location.pathname}#/public-shopfront/${businessProfile?.id}`;

    // Sync local state when props change
    useEffect(() => { setDraftSettings(settings); }, [settings]);
    useEffect(() => { setDraftProfile(businessProfile); }, [businessProfile]);
    useEffect(() => {
        if (currentUser) {
            setDraftOwner({
                name: currentUser.name,
                avatarUrl: currentUser.avatarUrl,
                initialInvestment: currentUser.initialInvestment || 0
            });
            const phone = currentUser.phone || '';
            const country = COUNTRIES.find(c => phone.startsWith(c.dial_code));
            if (country) {
                setOwnerPhone({ countryCode: country.dial_code, localPhone: phone.substring(country.dial_code.length) });
            } else {
                setOwnerPhone({ countryCode: '+1', localPhone: phone.replace(/\D/g, '') });
            }
        }
    }, [currentUser]);

    const handleSettingsChange = (e: React.ChangeEvent<HTMLInputElement>) => {
        const { name, value, type, checked } = e.target;
        const keys = name.split('.');
        
        setDraftSettings(prev => {
            const newSettings = JSON.parse(JSON.stringify(prev));
            let current = newSettings;
            for (let i = 0; i < keys.length - 1; i++) {
                current = current[keys[i]];
            }
            if (type === 'checkbox') {
                current[keys[keys.length - 1]] = checked;
            } else {
                current[keys[keys.length - 1]] = value;
            }
            return newSettings;
        });
    };
    
    const handleProfileChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
        const { name, value, type } = e.target;
        const isCheckbox = type === 'checkbox';
        setDraftProfile(prev => prev ? { ...prev, [name]: isCheckbox ? (e.target as HTMLInputElement).checked : value } : null);
    };

    const handleBusinessLogoUpload = (e: React.ChangeEvent<HTMLInputElement>) => {
        const file = e.target.files?.[0];
        if (file) {
            const reader = new FileReader();
            reader.onloadend = () => {
                setDraftProfile(prev => prev ? { ...prev, logo: reader.result as string } : null);
            };
            reader.readAsDataURL(file);
        }
    };

    const handleOwnerChange = (e: React.ChangeEvent<HTMLInputElement>) => {
        const { name, value } = e.target;
        setDraftOwner(prev => ({ ...prev, [name]: value }));
    };

    const handleOwnerPhoneChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
        setOwnerPhone({ ...ownerPhone, [e.target.name]: e.target.value });
    };

    const handleOwnerAvatarUpload = (e: React.ChangeEvent<HTMLInputElement>) => {
        const file = e.target.files?.[0];
        if (file) {
            const reader = new FileReader();
            reader.onloadend = () => {
                setDraftOwner(prev => ({ ...prev, avatarUrl: reader.result as string }));
            };
            reader.readAsDataURL(file);
        }
    };

    const handleAddPaymentMethod = () => {
        if (newPaymentMethod.trim() && !draftSettings.paymentMethods.includes(newPaymentMethod.trim())) {
            setDraftSettings(prev => ({ ...prev, paymentMethods: [...prev.paymentMethods, newPaymentMethod.trim()] }));
            setNewPaymentMethod('');
        }
    };

    const handleRemovePaymentMethod = (methodToRemove: string) => {
        setDraftSettings(prev => ({ ...prev, paymentMethods: prev.paymentMethods.filter(method => method !== methodToRemove) }));
    };
    
    const handleSave = () => {
        if (currentUser.role === 'Owner') {
            const ownerFullPhoneNumber = `${ownerPhone.countryCode}${ownerPhone.localPhone.replace(/\D/g, '')}`;
            onUpdateCurrentUserProfile({
                name: draftOwner.name,
                avatarUrl: draftOwner.avatarUrl,
                phone: ownerFullPhoneNumber,
                initialInvestment: parseFloat(String(draftOwner.initialInvestment)) || 0,
            });
        }
        
        const settingsToSave: BusinessSettingsData = {
            ...draftSettings,
            defaultTaxRate: parseFloat(String(draftSettings.defaultTaxRate)) || 0,
            investorProfitWithdrawalRate: parseInt(String(draftSettings.investorProfitWithdrawalRate)) || 0,
        };
        onUpdateSettings(settingsToSave);
        onUpdateBusinessProfile(draftProfile);
        alert('Settings saved successfully!');
    };

    const handleCopyLink = () => {
        navigator.clipboard.writeText(shopfrontUrl).then(() => {
            setCopySuccess(t('shopfront.copied'));
            setTimeout(() => setCopySuccess(''), 2000);
        }, () => {
            alert('Failed to copy link.');
        });
    };

    return (
        <div className="max-w-4xl mx-auto space-y-8 pb-24 md:pb-8">
            {currentUser.role === 'Owner' && (
                <SectionCard title="Owner Information" description="Update your personal information as the business owner." icon={<ProfileIcon />}>
                     <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                         <div className="md:col-span-2">
                             <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">Owner Avatar</label>
                             <div className="mt-1 flex items-center gap-4">
                                 <img src={draftOwner.avatarUrl} alt="Owner Avatar" className="w-16 h-16 rounded-full object-cover" />
                                 <input type="file" accept="image/*" ref={ownerAvatarInputRef} onChange={handleOwnerAvatarUpload} className="hidden" />
                                 <button type="button" onClick={() => ownerAvatarInputRef.current?.click()} className="bg-white dark:bg-gray-700 py-2 px-3 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm text-sm font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-600">Upload Avatar</button>
                             </div>
                         </div>
                        <Input name="name" label="Owner Full Name" value={draftOwner.name} onChange={handleOwnerChange} required />
                        <div>
                            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">Owner Phone</label>
                            <div className="mt-1 flex rounded-md shadow-sm input-group">
                                <select name="countryCode" value={ownerPhone.countryCode} onChange={handleOwnerPhoneChange} className="w-40">
                                    {COUNTRIES.map(c => <option key={c.code} value={c.dial_code}>{c.flag} {c.dial_code}</option>)}
                                </select>
                                <input type="tel" name="localPhone" value={ownerPhone.localPhone} onChange={handleOwnerPhoneChange} className="flex-1 min-w-0" placeholder="5551234567" />
                            </div>
                        </div>
                        <Input name="initialInvestment" label="Initial Investment" value={draftOwner.initialInvestment} onChange={handleOwnerChange} required type="number" />
                    </div>
                </SectionCard>
            )}

            <SectionCard title="Business Profile" description="Update your company's public information." icon={<BuildingIcon />}>
                 <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <Input name="businessName" label="Business Name" value={draftProfile?.businessName || ''} onChange={handleProfileChange} required />
                    <Input name="businessEmail" label="Business Email" value={draftProfile?.businessEmail || ''} onChange={handleProfileChange} required type="email" />
                    <Input name="businessPhone" label="Business Phone" value={draftProfile?.businessPhone || ''} onChange={handleProfileChange} required type="tel" />
                    <div className="md:col-span-2">
                        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">Business Logo</label>
                        <div className="mt-1 flex items-center">
                            <span className="inline-block h-12 w-12 rounded-full overflow-hidden bg-gray-100">
                                {draftProfile?.logo ? <img src={draftProfile.logo} alt="Logo" className="h-full w-full object-cover" /> : <svg className="h-full w-full text-gray-300" fill="currentColor" viewBox="0 0 24 24"><path d="M24 20.993V24H0v-2.993A1 1 0 001 18h22a1 1 0 001 2.993zM2.5 13.5l3-3 3 3-3 3-3-3zM18 10.5l-3 3 3 3 3-3-3-3zM21.5 6l-3 3 3 3 3-3-3-3zM8.5 6l-3 3 3 3 3-3-3-3z"/></svg>}
                            </span>
                            <input type="file" accept="image/*" ref={businessLogoInputRef} onChange={handleBusinessLogoUpload} className="hidden" />
                            <button type="button" onClick={() => businessLogoInputRef.current?.click()} className="ml-5 bg-white dark:bg-gray-700 py-2 px-3 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm text-sm font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-600">
                                Upload Logo
                            </button>
                        </div>
                    </div>
                </div>
            </SectionCard>
            
            <SectionCard
                title="Public Shopfront Settings"
                description="Control how your business appears to the public and manage online orders."
                icon={<StorefrontIcon />}
            >
                <div className="space-y-4">
                    <Toggle 
                        label="List in Public Directory"
                        description="Allow other users to find your business in the directory."
                        name="isPublic"
                        checked={draftProfile?.isPublic || false}
                        onChange={handleProfileChange}
                    />
                     <Toggle 
                        label="Accept Remote Orders"
                        description="Enable clients to place order requests from your public shopfront."
                        name="acceptRemoteOrders"
                        checked={draftSettings.acceptRemoteOrders || false}
                        onChange={handleSettingsChange}
                    />
                </div>
                <div className="pt-4 border-t dark:border-gray-700">
                    <label htmlFor="shopfront-url" className="block text-sm font-medium text-gray-700 dark:text-gray-300">Your unique shopfront link</label>
                    <div className="mt-1 flex rounded-md shadow-sm">
                        <input
                            id="shopfront-url"
                            type="text"
                            readOnly
                            value={shopfrontUrl}
                            className="flex-1 min-w-0 block w-full px-3 py-2 rounded-none rounded-l-md"
                        />
                        <button
                            onClick={handleCopyLink}
                            className="inline-flex items-center px-4 py-2 border border-l-0 border-gray-300 dark:border-gray-600 rounded-r-md bg-gray-50 dark:bg-gray-700/50 text-sm font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-600"
                        >
                            {copySuccess || t('shopfront.copyLink')}
                        </button>
                    </div>
                </div>
            </SectionCard>
            
            <SectionCard
                title={t('businessSettings.paymentMethods.title')}
                description={t('businessSettings.paymentMethods.description')}
                icon={<CreditCardIcon />}
            >
                <div className="flex flex-wrap gap-2">
                    {draftSettings.paymentMethods.map(method => (
                        <div key={method} className="flex items-center bg-primary/10 text-primary-800 dark:bg-primary/20 dark:text-primary-200 text-sm font-medium px-3 py-1 rounded-full">
                            {method}
                            <button onClick={() => handleRemovePaymentMethod(method)} className="ml-2 text-primary-600 hover:text-primary-800 dark:text-primary-300 dark:hover:text-primary-100">
                                <DeleteIcon />
                            </button>
                        </div>
                    ))}
                </div>
                <div className="flex gap-2 pt-4 border-t dark:border-gray-700 mt-4">
                    <input
                        type="text"
                        value={newPaymentMethod}
                        onChange={e => setNewPaymentMethod(e.target.value)}
                        placeholder="e.g., Mobile Money"
                        className="flex-grow"
                    />
                    <button onClick={handleAddPaymentMethod} className="bg-primary text-white px-4 py-2 rounded-lg font-semibold hover:bg-blue-700 flex-shrink-0">
                        {t('businessSettings.paymentMethods.add')}
                    </button>
                </div>
            </SectionCard>

            <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
                 <SectionCard title={t('businessSettings.tax.title')} description={t('businessSettings.tax.description')} icon={<CalculatorIcon />}>
                    <Input type="number" name="defaultTaxRate" value={draftSettings.defaultTaxRate} onChange={handleSettingsChange} step="0.01" min="0" />
                </SectionCard>
                <SectionCard title={t('businessSettings.investorProfitWithdrawalRate.title')} description={t('businessSettings.investorProfitWithdrawalRate.description')} icon={<InvestorIcon />}>
                    <Input type="number" name="investorProfitWithdrawalRate" value={draftSettings.investorProfitWithdrawalRate} onChange={handleSettingsChange} step="1" min="0" max="100" />
                </SectionCard>
            </div>

            {/* Sticky Save Button footer */}
            <div className="fixed bottom-16 left-0 right-0 p-4 bg-white/95 dark:bg-gray-900/95 backdrop-blur-sm border-t dark:border-gray-700 shadow-[0_-2px_10px_rgba(0,0,0,0.1)] md:static md:p-0 md:bg-transparent md:border-t-2 md:border-neutral-light dark:md:border-gray-700 md:pt-6 z-10">
                <div className="max-w-4xl mx-auto flex justify-end">
                    <button onClick={handleSave} className="btn-responsive bg-primary text-white hover:bg-blue-700 shadow-lg md:shadow-sm">
                        {t('businessSettings.saveButton')}
                    </button>
                </div>
            </div>


            {/* Danger Zone */}
            <div className="mt-12 border-t-4 border-red-400 pt-6">
                <h3 className="text-xl font-bold text-red-600">{t('businessSettings.dangerZone.title')}</h3>
                <div className="mt-4 bg-red-50 dark:bg-red-900/30 p-6 rounded-lg border border-red-200 dark:border-red-700 flex flex-col md:flex-row justify-between items-center gap-4">
                    <div>
                        <h4 className="font-semibold text-red-800 dark:text-red-200">{t('businessSettings.dangerZone.reset.title')}</h4>
                        <p className="text-sm text-red-700 dark:text-red-300 mt-1">{t('businessSettings.dangerZone.reset.description')}</p>
                    </div>
                    <button onClick={() => setIsResetModalOpen(true)} className="bg-red-600 text-white px-4 py-2 rounded-lg font-semibold hover:bg-red-700 transition-colors flex-shrink-0">
                        {t('businessSettings.dangerZone.reset.button')}
                    </button>
                </div>
            </div>

            <DestructiveConfirmationModal
                isOpen={isResetModalOpen}
                onClose={() => setIsResetModalOpen(false)}
                onConfirm={onResetBusiness}
                title={t('businessSettings.dangerZone.reset.title')}
                message={t('businessSettings.dangerZone.reset.description')}
                confirmationPhrase="RESET"
                t={t}
            />
        </div>
    );
};

export default BusinessSettings;