import React, { useMemo, useState, useEffect, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import type { User, Sale, ReceiptSettingsData, PerformanceUser, Withdrawal, BusinessProfile, Customer, CustomPayment, OwnerSettings, BusinessSettingsData, Expense } from '../types';
import Card from './Card';
import WithdrawalRequestModal from './WithdrawalRequestModal';
import WithdrawalReceiptModal from './WithdrawalReceiptModal';
import PaymentReceiptModal from './PaymentReceiptModal';
import { formatCurrency, formatAbbreviatedNumber } from '../lib/utils';
import { COUNTRIES } from '../constants';

interface MyProfileProps {
    currentUser: User;
    users: User[];
    sales: Sale[];
    expenses: Expense[];
    customers: Customer[];
    receiptSettings: ReceiptSettingsData;
    t: (key: string) => string;
    onRequestWithdrawal: (userId: string, amount: number) => void;
    onConfirmWithdrawalReceived: (userId: string, withdrawalId: string) => void;
    handleUpdateCustomPaymentStatus: (targetUserId: string, paymentId: string, status: CustomPayment['status']) => void;
    businessProfile: BusinessProfile | null;
    ownerSettings: OwnerSettings;
    setOwnerSettings: (settings: OwnerSettings) => void;
    businessSettings: BusinessSettingsData;
    onUpdateCurrentUserProfile: (profileData: { name?: string; avatarUrl?: string; phone?: string; initialInvestment?: number; }) => void;
}

// Helper from Users.tsx to keep calculations consistent
const calculateTotalHours = (attendance: any[] = []): number => {
    return attendance.reduce((total, record) => {
        if (record.clockOut) {
            const clockInTime = new Date(record.clockIn).getTime();
            const clockOutTime = new Date(record.clockOut).getTime();
            const hours = (clockOutTime - clockInTime) / (1000 * 60 * 60);
            return total + hours;
        }
        return total;
    }, 0);
};

const MetricDisplay: React.FC<{ label: string; value: string; fullValue?: string; className?: string }> = ({ label, value, fullValue, className }) => (
    <div className={`bg-gray-50 p-4 rounded-lg border flex justify-between items-center ${className}`} title={fullValue}>
        <span className="text-md font-medium text-gray-600">{label}</span>
        <span className="text-xl font-bold text-gray-800">{value}</span>
    </div>
);

const RoleBadge: React.FC<{ role: string; icon: string; color: string; }> = ({ role, icon, color }) => (
    <span className={`inline-flex items-center gap-2 px-3 py-1 rounded-full text-sm font-semibold ${color}`}>
        {icon} {role}
    </span>
);

const ToggleSwitch: React.FC<{ label: string; description: string; checked: boolean; onChange: (checked: boolean) => void; }> = ({ label, description, checked, onChange }) => (
    <div className="flex items-center justify-between p-4 border rounded-lg bg-gray-50">
        <div>
            <label htmlFor={label} className="font-medium text-gray-700">{label}</label>
            <p className="text-sm text-gray-500 font-normal">{description}</p>
        </div>
        <label htmlFor={label} className="flex items-center cursor-pointer">
            <div className="relative">
                <input type="checkbox" id={label} className="sr-only" checked={checked} onChange={e => onChange(e.target.checked)} />
                <div className={`block ${checked ? 'bg-primary' : 'bg-gray-300'} w-14 h-8 rounded-full`}></div>
                <div className={`dot absolute left-1 top-1 bg-white w-6 h-6 rounded-full transition-transform transform ${checked ? 'translate-x-6' : ''}`}></div>
            </div>
        </label>
    </div>
);

// --- REWRITTEN EDIT PROFILE MODAL ---
const EditProfileModal: React.FC<{
    isOpen: boolean;
    onClose: () => void;
    currentUser: User;
    onSave: (profileData: { name: string; avatarUrl: string; phone: string; initialInvestment?: number; }) => void;
    receiptSettings: ReceiptSettingsData;
}> = ({ isOpen, onClose, currentUser, onSave, receiptSettings }) => {
    const [name, setName] = useState(currentUser.name);
    const [avatarUrl, setAvatarUrl] = useState(currentUser.avatarUrl);
    const [countryCode, setCountryCode] = useState('+1');
    const [localPhone, setLocalPhone] = useState('');
    const [initialInvestment, setInitialInvestment] = useState<string | number>(currentUser.initialInvestment || 0);
    const fileInputRef = useRef<HTMLInputElement>(null);

    useEffect(() => {
        if (isOpen) {
            setName(currentUser.name);
            setAvatarUrl(currentUser.avatarUrl);
            setInitialInvestment(currentUser.initialInvestment || 0);
            
            // Parse phone number
            const phone = currentUser.phone || '';
            const country = COUNTRIES.find(c => phone.startsWith(c.dial_code));
            if (country) {
                setCountryCode(country.dial_code);
                setLocalPhone(phone.substring(country.dial_code.length));
            } else {
                setCountryCode('+1'); // Default
                setLocalPhone(phone.replace(/\D/g, ''));
            }
        }
    }, [isOpen, currentUser]);

    const handleAvatarUpload = (e: React.ChangeEvent<HTMLInputElement>) => {
        const file = e.target.files?.[0];
        if (file) {
            const reader = new FileReader();
            reader.onloadend = () => {
                setAvatarUrl(reader.result as string);
            };
            reader.readAsDataURL(file);
        }
    };

    const handleSave = () => {
        const fullPhoneNumber = localPhone ? `${countryCode}${localPhone.replace(/\D/g, '')}` : '';
        const saveData: { name: string; avatarUrl: string; phone: string; initialInvestment?: number; } = { 
            name, 
            avatarUrl, 
            phone: fullPhoneNumber 
        };
        if(currentUser.role === 'Owner') {
            saveData.initialInvestment = Number(initialInvestment) || 0;
        }
        onSave(saveData);
    };

    if (!isOpen) return null;

    return (
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4">
            <div className="bg-white rounded-lg shadow-2xl w-full max-w-lg">
                <header className="p-6 border-b">
                    <h2 className="text-2xl font-bold text-gray-800">Edit Profile</h2>
                </header>
                <main className="p-6 space-y-4 max-h-[70vh] overflow-y-auto">
                    <div className="flex items-center gap-4">
                        <img src={avatarUrl} alt="Avatar Preview" className="w-20 h-20 rounded-full object-cover" />
                        <div className="flex-grow">
                            <label htmlFor="name" className="block text-sm font-medium text-gray-700">Full Name</label>
                            <input id="name" type="text" value={name} onChange={(e) => setName(e.target.value)} required className="mt-1" />
                        </div>
                    </div>
                    <div>
                        <label className="block text-sm font-medium text-gray-700">Avatar Image</label>
                        <div className="mt-1 flex items-center gap-4">
                             <input id="avatarUrl" type="text" value={avatarUrl} onChange={(e) => setAvatarUrl(e.target.value)} className="flex-grow" placeholder="Enter image URL or upload" />
                             <input type="file" accept="image/*" ref={fileInputRef} onChange={handleAvatarUpload} className="hidden" />
                            <button type="button" onClick={() => fileInputRef.current?.click()} className="px-4 py-2 bg-gray-100 text-gray-700 text-sm font-semibold rounded-md hover:bg-gray-200">
                                Upload
                            </button>
                        </div>
                    </div>
                     <div>
                        <label htmlFor="localPhone" className="block text-sm font-medium text-gray-700">Phone Number</label>
                        <div className="mt-1 flex rounded-md shadow-sm input-group">
                            <select
                                name="countryCode"
                                value={countryCode}
                                onChange={(e) => setCountryCode(e.target.value)}
                                className="w-40"
                                aria-label="Country code"
                            >
                                {COUNTRIES.map(country => (
                                    <option key={country.code} value={country.dial_code}>
                                        {country.flag} {country.name} ({country.dial_code})
                                    </option>
                                ))}
                            </select>
                            <input
                                type="tel"
                                name="localPhone"
                                id="localPhone"
                                value={localPhone}
                                onChange={(e) => setLocalPhone(e.target.value)}
                                className="flex-1 min-w-0"
                                placeholder="5551234567"
                            />
                        </div>
                    </div>
                    {currentUser.role === 'Owner' && (
                         <div>
                            <label htmlFor="initialInvestment" className="block text-sm font-medium text-gray-700">Initial Investment ({receiptSettings.currencySymbol})</label>
                            <input 
                                type="number" 
                                name="initialInvestment" 
                                id="initialInvestment" 
                                value={initialInvestment} 
                                onChange={(e) => setInitialInvestment(e.target.value)} 
                                required 
                                min="0" 
                                step="1" 
                                className="mt-1" 
                            />
                        </div>
                    )}
                </main>
                <footer className="p-4 bg-gray-50 rounded-b-lg flex justify-end gap-3">
                    <button type="button" onClick={onClose} className="px-4 py-2 rounded-lg font-semibold bg-gray-200 text-gray-800 hover:bg-gray-300">Cancel</button>
                    <button type="button" onClick={handleSave} className="px-4 py-2 rounded-lg font-semibold bg-primary text-white hover:bg-blue-700">Save Changes</button>
                </footer>
            </div>
        </div>
    );
};


// --- OWNER-SPECIFIC PROFILE COMPONENT ---
const OwnerProfile: React.FC<MyProfileProps> = (props) => {
    const { currentUser, users, sales, expenses, receiptSettings, ownerSettings, setOwnerSettings, businessSettings, businessProfile, onRequestWithdrawal, onConfirmWithdrawalReceived, onUpdateCurrentUserProfile, handleUpdateCustomPaymentStatus } = props;
    const [activeTab, setActiveTab] = useState<'info' | 'financial' | 'permissions'>('info');
    const [isWithdrawalModalOpen, setIsWithdrawalModalOpen] = useState(false);
    const [withdrawalReceiptToShow, setWithdrawalReceiptToShow] = useState<Withdrawal | null>(null);
    const [paymentReceiptToShow, setPaymentReceiptToShow] = useState<CustomPayment | null>(null);

    const cs = receiptSettings.currencySymbol;

    const getWithdrawalStatusBadge = (status: Withdrawal['status']) => {
        const styles = { pending: 'bg-yellow-100 text-yellow-800', approved: 'bg-blue-100 text-blue-800', paid: 'bg-purple-100 text-purple-800', completed: 'bg-green-100 text-green-800', rejected: 'bg-red-100 text-red-800' };
        return <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${styles[status]}`}>{status.charAt(0).toUpperCase() + status.slice(1)}</span>;
    };
    
    const getPaymentStatusBadge = (status: CustomPayment['status']) => {
        const styles = {
            pending_user_approval: 'bg-yellow-100 text-yellow-800',
            rejected_by_user: 'bg-red-100 text-red-800',
            approved_by_user: 'bg-blue-100 text-blue-800',
            paid: 'bg-purple-100 text-purple-800',
            completed: 'bg-green-100 text-green-800',
        };
        const text = {
            pending_user_approval: 'Pending Your Approval',
            rejected_by_user: 'You Rejected',
            approved_by_user: 'You Approved',
            paid: 'Paid by Manager',
            completed: 'You Confirmed Receipt',
        };
        return <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${styles[status]}`}>{text[status]}</span>;
    };

    // --- Financial Calculations ---
    const ownerSales = useMemo(() => sales.filter(s => s.userId === currentUser.id && s.status === 'completed'), [sales, currentUser.id]);
    const totalCommission = useMemo(() => ownerSales.reduce((sum, s) => sum + (s.commission || 0), 0), [ownerSales]);
    const totalWithdrawals = useMemo(() => (currentUser.withdrawals || []).filter(w => ['approved', 'paid', 'completed'].includes(w.status)).reduce((sum, w) => sum + w.amount, 0), [currentUser.withdrawals]);
    const availableCommission = totalCommission - totalWithdrawals;

    const allInvestorsAndOwner = useMemo(() => users.filter(u => u.role === 'Investor' || u.role === 'Owner'), [users]);
    const totalCapital = useMemo(() => allInvestorsAndOwner.reduce((sum, u) => sum + (u.initialInvestment || 0), 0), [allInvestorsAndOwner]);
    const ownership = useMemo(() => totalCapital > 0 ? ((currentUser.initialInvestment || 0) / totalCapital) * 100 : 0, [currentUser.initialInvestment, totalCapital]);

    const totalNetProfit = useMemo(() => {
        const totalRevenue = sales.filter(s => s.status === 'completed').reduce((sum, sale) => sum + (sale.subtotal - sale.discount), 0);
        const totalCOGS = sales.filter(s => s.status === 'completed').reduce((sum, sale) => sum + sale.items.reduce((cogs, item) => cogs + (item.product.costPrice * item.quantity), 0), 0);
        const totalExpenses = expenses.reduce((sum, e) => sum + e.amount, 0);
        return totalRevenue - totalCOGS - totalExpenses;
    }, [sales, expenses]);
    
    const profitShare = totalNetProfit * (ownership / 100);
    const withdrawableProfitShare = profitShare * (businessSettings.investorProfitWithdrawalRate / 100);
    const availableProfitShare = Math.max(0, withdrawableProfitShare - totalWithdrawals);
    
    const sortedWithdrawals = useMemo(() => [...(currentUser.withdrawals || [])].sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime()), [currentUser.withdrawals]);
    const sortedCustomPayments = useMemo(() => [...(currentUser.customPayments || [])].sort((a, b) => new Date(b.dateInitiated).getTime() - new Date(a.dateInitiated).getTime()), [currentUser.customPayments]);

    const handleRequestSubmit = (amount: number) => {
        onRequestWithdrawal(currentUser.id, amount);
    };

    return (
        <div className="space-y-6">
            <Card title="Owner Command Center">
                <div className="flex flex-col sm:flex-row items-center gap-6">
                    <img src={currentUser.avatarUrl} alt={currentUser.name} className="w-24 h-24 rounded-full object-cover shadow-lg" />
                    <div className="text-center sm:text-left">
                        <h2 className="text-3xl font-bold text-gray-800">{currentUser.name}</h2>
                        <div className="mt-2 flex flex-wrap justify-center sm:justify-start gap-2">
                            <RoleBadge role="Owner" icon="💼" color="bg-yellow-200 text-yellow-800" />
                            <RoleBadge role="Investor" icon="💰" color="bg-green-200 text-green-800" />
                            <RoleBadge role="Seller Agent" icon="🛍️" color="bg-blue-200 text-blue-800" />
                        </div>
                    </div>
                </div>
            </Card>

            <div>
                <div className="border-b border-gray-200">
                    <nav className="-mb-px flex space-x-6" aria-label="Tabs">
                        <button onClick={() => setActiveTab('info')} className={`whitespace-nowrap py-4 px-1 border-b-2 font-medium text-sm ${activeTab === 'info' ? 'border-primary text-primary' : 'border-transparent text-gray-500 hover:text-gray-700'}`}>Personal Info</button>
                        <button onClick={() => setActiveTab('financial')} className={`whitespace-nowrap py-4 px-1 border-b-2 font-medium text-sm ${activeTab === 'financial' ? 'border-primary text-primary' : 'border-transparent text-gray-500 hover:text-gray-700'}`}>Financial Overview</button>
                        <button onClick={() => setActiveTab('permissions')} className={`whitespace-nowrap py-4 px-1 border-b-2 font-medium text-sm ${activeTab === 'permissions' ? 'border-primary text-primary' : 'border-transparent text-gray-500 hover:text-gray-700'}`}>Permissions & Control</button>
                    </nav>
                </div>

                <div className="mt-6">
                    {activeTab === 'info' && (
                        <Card title="Personal & Business Information">
                            <div className="space-y-4 text-gray-700">
                                <p><strong>Email:</strong> {currentUser.email}</p>
                                <p><strong>Phone:</strong> {currentUser.phone || 'Not set'}</p>
                                <p><strong>Initial Investment:</strong> {formatCurrency(currentUser.initialInvestment || 0, cs)}</p>
                                <hr className="dark:border-gray-600"/>
                                <p><strong>Business Name:</strong> {businessProfile?.businessName}</p>
                                <p><strong>Business Contact:</strong> {businessProfile?.businessEmail} / {businessProfile?.businessPhone}</p>
                            </div>
                        </Card>
                    )}
                    {activeTab === 'financial' && (
                        <div className="space-y-6">
                            <Card title="Investment & Profit Share">
                                <div className="space-y-4">
                                    <MetricDisplay label="Initial Investment" value={`${cs}${formatAbbreviatedNumber(currentUser.initialInvestment || 0)}`} fullValue={formatCurrency(currentUser.initialInvestment || 0, cs)} />
                                    <MetricDisplay label="Ownership of Capital" value={`${ownership.toFixed(2)}%`} />
                                    <MetricDisplay label="Net Profit Share Earned" value={`${cs}${formatAbbreviatedNumber(profitShare)}`} fullValue={formatCurrency(profitShare, cs)} className={profitShare >= 0 ? 'bg-green-50 border-green-200' : 'bg-red-50 border-red-200'}/>
                                    <MetricDisplay label="Available for Withdrawal" value={`${cs}${formatAbbreviatedNumber(availableProfitShare)}`} fullValue={formatCurrency(availableProfitShare, cs)} className="bg-blue-50 border-blue-200" />
                                    <button onClick={() => setIsWithdrawalModalOpen(true)} disabled={availableProfitShare <= 0} className="w-full mt-2 bg-blue-600 text-white py-2 rounded-lg font-semibold hover:bg-blue-700 disabled:bg-gray-300">Request Profit Share Withdrawal</button>
                                </div>
                            </Card>
                             {ownerSettings.commissionTrackingEnabled && (
                                <Card title="Seller Agent Commission">
                                    <div className="space-y-4">
                                        <MetricDisplay label="Total Commission Earned" value={`${cs}${formatAbbreviatedNumber(totalCommission)}`} fullValue={formatCurrency(totalCommission, cs)} />
                                        <MetricDisplay label="Total Withdrawn" value={`${cs}${formatAbbreviatedNumber(totalWithdrawals)}`} fullValue={formatCurrency(totalWithdrawals, cs)} />
                                        <MetricDisplay label="Available Commission" value={`${cs}${formatAbbreviatedNumber(availableCommission)}`} fullValue={formatCurrency(availableCommission, cs)} className="bg-primary-50 border-primary" />
                                        <button onClick={() => setIsWithdrawalModalOpen(true)} disabled={availableCommission <= 0} className="w-full mt-2 bg-primary text-white py-2 rounded-lg font-semibold hover:bg-blue-700 disabled:bg-gray-300">Request Commission Withdrawal</button>
                                    </div>
                                </Card>
                            )}
                             <Card title="Withdrawal History">
                                 {sortedWithdrawals.length > 0 ? (
                                    <div className="space-y-3 max-h-96 overflow-y-auto">
                                        {sortedWithdrawals.map(w => (
                                            <div key={w.id} className="text-sm p-3 bg-gray-50 rounded-md border">
                                                <div className="flex justify-between items-center">
                                                    <div>
                                                        <p className="font-medium text-gray-600">{new Date(w.date).toLocaleDateString()}</p>
                                                        <span className="font-bold text-red-600">-{formatCurrency(w.amount, cs)}</span>
                                                    </div>
                                                    <div>
                                                        {w.status === 'paid' ? (
                                                            <button onClick={() => {
                                                                onConfirmWithdrawalReceived(currentUser.id, w.id);
                                                                setWithdrawalReceiptToShow({ ...w, status: 'completed' });
                                                            }} className="px-3 py-1.5 text-xs font-bold text-white bg-green-500 rounded-md hover:bg-green-600">Confirm Receipt</button>
                                                        ) : getWithdrawalStatusBadge(w.status)}
                                                        {w.status === 'completed' && (
                                                             <button onClick={() => setWithdrawalReceiptToShow(w)} className="px-3 py-1.5 text-xs font-bold text-primary bg-primary/10 rounded-md hover:bg-primary/20">View Receipt</button>
                                                        )}
                                                    </div>
                                                </div>
                                            </div>
                                        ))}
                                    </div>
                                ) : (
                                    <p className="text-center text-sm text-gray-500 py-4">You have no withdrawal history.</p>
                                )}
                            </Card>
                            <Card title="Custom Payments">
                                {sortedCustomPayments.length > 0 ? (
                                    <div className="space-y-3">
                                        {sortedCustomPayments.map(payment => (
                                            <div key={payment.id} className="text-sm p-3 bg-gray-50 rounded-md">
                                                <div className="flex justify-between items-start">
                                                    <div>
                                                        <p className="font-semibold text-gray-800">{payment.description}</p>
                                                        <p className="text-xs text-gray-500 mt-1">Initiated: {new Date(payment.dateInitiated).toLocaleDateString()}</p>
                                                    </div>
                                                    <p className="font-bold text-lg text-primary">{formatCurrency(payment.amount, cs)}</p>
                                                </div>
                                                <div className="mt-3 pt-3 border-t flex justify-between items-center">
                                                    {getPaymentStatusBadge(payment.status)}
                                                    {payment.status === 'pending_user_approval' && (
                                                        <div className="flex items-center gap-2">
                                                            <button onClick={() => handleUpdateCustomPaymentStatus(currentUser.id, payment.id, 'rejected_by_user')} className="px-4 py-2 text-sm font-semibold text-white bg-red-500 rounded-lg hover:bg-red-600">Reject</button>
                                                            <button onClick={() => handleUpdateCustomPaymentStatus(currentUser.id, payment.id, 'approved_by_user')} className="px-4 py-2 text-sm font-semibold text-white bg-green-500 rounded-lg hover:bg-green-600">Accept</button>
                                                        </div>
                                                    )}
                                                    {payment.status === 'paid' && (
                                                        <button onClick={() => {
                                                                handleUpdateCustomPaymentStatus(currentUser.id, payment.id, 'completed');
                                                                setPaymentReceiptToShow({ ...payment, status: 'completed' });
                                                            }} className="px-3 py-1.5 text-xs font-bold text-white bg-green-500 rounded-md hover:bg-green-600">
                                                            Confirm Receipt
                                                        </button>
                                                    )}
                                                    {payment.status === 'completed' && (
                                                        <button onClick={() => setPaymentReceiptToShow(payment)} className="px-3 py-1.5 text-xs font-bold text-primary bg-primary/10 rounded-md hover:bg-primary/20">
                                                            View Receipt
                                                        </button>
                                                    )}
                                                </div>
                                            </div>
                                        ))}
                                    </div>
                                ) : (
                                    <p className="text-center text-sm text-gray-500 py-4">You have no custom payments.</p>
                                )}
                            </Card>
                        </div>
                    )}
                    {activeTab === 'permissions' && (
                        <Card title="My Visibility & Tracking">
                            <div className="space-y-4">
                                <ToggleSwitch label="Enable Owner Commission Tracking" description="Allow your sales to generate commission like a Seller Agent." checked={ownerSettings.commissionTrackingEnabled} onChange={checked => setOwnerSettings({...ownerSettings, commissionTrackingEnabled: checked })} />
                                <ToggleSwitch label="Include Owner in Staff Reports" description="Show your sales performance in general staff reports." checked={ownerSettings.includeInStaffReports} onChange={checked => setOwnerSettings({...ownerSettings, includeInStaffReports: checked })} />
                                <ToggleSwitch label="Show Owner on Sales Leaderboard" description="Display your name and sales on the public leaderboards." checked={ownerSettings.showOnLeaderboard} onChange={checked => setOwnerSettings({...ownerSettings, showOnLeaderboard: checked })} />
                            </div>
                        </Card>
                    )}
                </div>
            </div>
             <WithdrawalRequestModal isOpen={isWithdrawalModalOpen} onClose={() => setIsWithdrawalModalOpen(false)} onConfirm={handleRequestSubmit} availableBalance={availableCommission + availableProfitShare} currencySymbol={cs} />
             <WithdrawalReceiptModal isOpen={!!withdrawalReceiptToShow} onClose={() => setWithdrawalReceiptToShow(null)} withdrawal={withdrawalReceiptToShow} user={currentUser} businessProfile={businessProfile} receiptSettings={receiptSettings} />
             <PaymentReceiptModal isOpen={!!paymentReceiptToShow} onClose={() => setPaymentReceiptToShow(null)} payment={paymentReceiptToShow} user={currentUser} businessProfile={businessProfile} receiptSettings={receiptSettings} />
        </div>
    );
}


// --- STANDARD PROFILE COMPONENT FOR OTHER ROLES ---
const StandardProfile: React.FC<MyProfileProps> = (props) => {
    const { currentUser, sales, customers, receiptSettings, t, onRequestWithdrawal, onConfirmWithdrawalReceived, handleUpdateCustomPaymentStatus, businessProfile, onUpdateCurrentUserProfile } = props;
    const [isWithdrawalModalOpen, setIsWithdrawalModalOpen] = useState(false);
    const [withdrawalReceiptToShow, setWithdrawalReceiptToShow] = useState<Withdrawal | null>(null);
    const [paymentReceiptToShow, setPaymentReceiptToShow] = useState<CustomPayment | null>(null);
    const [isEditModalOpen, setIsEditModalOpen] = useState(false);
    const navigate = useNavigate();
    const cs = receiptSettings.currencySymbol;

    const handleSaveProfile = (profileData: { name: string; avatarUrl: string; phone: string; }) => {
        onUpdateCurrentUserProfile(profileData);
        setIsEditModalOpen(false); // Explicitly close the modal
        // Use a small timeout to allow the UI to update before the alert, preventing UI blocking.
        setTimeout(() => {
            alert('Profile updated successfully.');
        }, 100);
    };

    const performanceData: PerformanceUser = useMemo(() => {
        const userSales = sales.filter(sale => sale.userId === currentUser.id && sale.status === 'completed');
        const totalCommission = userSales.reduce((sum, sale) => sum + (sale.commission || 0), 0);
        const totalSalesValue = userSales.reduce((sum, sale) => sum + sale.total, 0);

        const totalHours = calculateTotalHours(currentUser.attendance);
        const totalHourlyEarnings = (currentUser.hourlyRate || 0) * totalHours;
        
        // FIX: Replaced `totalWithdrawals` with `totalCommissionWithdrawals` and `totalInvestmentWithdrawals` to match the `PerformanceUser` type definition.
        const totalCommissionWithdrawals = (currentUser.withdrawals || [])
            .filter(w => ['approved', 'paid', 'completed'].includes(w.status) && w.source === 'commission')
            .reduce((sum, w) => sum + w.amount, 0);
        
        const totalInvestmentWithdrawals = (currentUser.withdrawals || [])
            .filter(w => ['approved', 'paid', 'completed'].includes(w.status) && w.source === 'investment')
            .reduce((sum, w) => sum + w.amount, 0);

        return {
            ...currentUser,
            salesCount: userSales.length,
            totalSalesValue,
            totalCommission,
            totalHours,
            totalHourlyEarnings,
            totalCommissionWithdrawals,
            totalInvestmentWithdrawals,
        };
    }, [currentUser, sales]);

    const availableBalance = useMemo(() => {
        const totalEarnings = performanceData.type === 'commission'
            ? performanceData.totalCommission
            : performanceData.totalHourlyEarnings;
        
        const totalDeducted = (currentUser.withdrawals || [])
            .filter(w => ['approved', 'paid', 'completed'].includes(w.status))
            .reduce((sum, w) => sum + w.amount, 0);
            
        return totalEarnings - totalDeducted;
    }, [performanceData, currentUser.withdrawals]);
    
    const recentSales = useMemo(() => {
        return sales
            .filter(sale => sale.userId === currentUser.id && sale.status === 'completed')
            .sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime())
            .slice(0, 5);
    }, [sales, currentUser.id]);

    const sortedWithdrawals = useMemo(() => {
        return [...(currentUser.withdrawals || [])]
            .sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime());
    }, [currentUser.withdrawals]);

    const sortedCustomPayments = useMemo(() => 
        [...(currentUser.customPayments || [])].sort((a, b) => new Date(b.dateInitiated).getTime() - new Date(a.dateInitiated).getTime()),
    [currentUser.customPayments]);
    
    const handleRequestSubmit = (amount: number) => {
        onRequestWithdrawal(currentUser.id, amount);
    };

    const getWithdrawalStatusBadge = (status: Withdrawal['status']) => {
        switch (status) {
            case 'pending':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-yellow-100 text-yellow-800">Pending</span>;
            case 'approved':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-blue-100 text-blue-800">Approved</span>;
            case 'paid':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-purple-100 text-purple-800">Paid</span>;
            case 'completed':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-green-100 text-green-800">Completed</span>;
            case 'rejected':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-red-100 text-red-800">Rejected</span>;
            default:
                return null;
        }
    };

    const getPaymentStatusBadge = (status: CustomPayment['status']) => {
        const styles = {
            pending_user_approval: 'bg-yellow-100 text-yellow-800',
            rejected_by_user: 'bg-red-100 text-red-800',
            approved_by_user: 'bg-blue-100 text-blue-800',
            paid: 'bg-purple-100 text-purple-800',
            completed: 'bg-green-100 text-green-800',
        };
        const text = {
            pending_user_approval: 'Pending Your Approval',
            rejected_by_user: 'You Rejected',
            approved_by_user: 'You Approved',
            paid: 'Paid by Manager',
            completed: 'You Confirmed Receipt',
        };
        return <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${styles[status]}`}>{text[status]}</span>;
    };

    const displayRole = performanceData.role === 'Custom' && performanceData.customRoleName ? performanceData.customRoleName : performanceData.role;
    // FIX: Calculated the total withdrawals by summing commission and investment withdrawals to resolve a property access error on the `PerformanceUser` type.
    const totalWithdrawals = performanceData.totalCommissionWithdrawals + performanceData.totalInvestmentWithdrawals;

    return (
        <div className="max-w-4xl mx-auto space-y-6">
            <Card title="My Profile" headerContent={<button onClick={() => setIsEditModalOpen(true)} className="text-sm font-semibold text-primary hover:underline">Edit Profile</button>}>
                 <div className="flex flex-col sm:flex-row items-center gap-6">
                    <img src={performanceData.avatarUrl} alt={performanceData.name} className="w-24 h-24 rounded-full object-cover shadow-lg" />
                    <div className="text-center sm:text-left">
                        <h2 className="text-3xl font-bold text-gray-800">{performanceData.name}</h2>
                        <p className="text-lg text-gray-500">{displayRole}</p>
                        <p className="text-sm text-gray-500 mt-2">{currentUser.email}</p>
                        <p className="text-sm text-gray-500">{currentUser.phone || 'No phone number set'}</p>
                    </div>
                </div>
            </Card>

            <Card title="Financial Overview">
                 <div className="space-y-4">
                    {performanceData.type === 'commission' ? (
                        <>
                            <MetricDisplay label="Total Sales Value" value={`${cs}${formatAbbreviatedNumber(performanceData.totalSalesValue)}`} fullValue={formatCurrency(performanceData.totalSalesValue, cs)} />
                            <MetricDisplay label="Total Commission Earned" value={`${cs}${formatAbbreviatedNumber(performanceData.totalCommission)}`} fullValue={formatCurrency(performanceData.totalCommission, cs)} />
                        </>
                    ) : (
                        <>
                             <MetricDisplay label="Total Hours Logged" value={`${performanceData.totalHours.toFixed(2)} hrs`} />
                             <MetricDisplay label="Total Earnings" value={`${cs}${formatAbbreviatedNumber(performanceData.totalHourlyEarnings)}`} fullValue={formatCurrency(performanceData.totalHourlyEarnings, cs)} />
                        </>
                    )}
                    <MetricDisplay label="Total Withdrawn & Approved" value={`${cs}${formatAbbreviatedNumber(totalWithdrawals)}`} fullValue={formatCurrency(totalWithdrawals, cs)} />
                    <MetricDisplay label="Available Balance" value={`${cs}${formatAbbreviatedNumber(availableBalance)}`} fullValue={formatCurrency(availableBalance, cs)} className="bg-primary-50 border-primary text-primary-800" />
                    <button
                        onClick={() => setIsWithdrawalModalOpen(true)}
                        disabled={availableBalance <= 0}
                        className="w-full mt-4 bg-primary text-white py-3 rounded-lg font-semibold hover:bg-blue-700 transition-colors disabled:bg-gray-300 disabled:cursor-not-allowed"
                    >
                        Request Withdrawal
                    </button>
                </div>
            </Card>

            <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
                 <Card title="Recent Sales">
                    {recentSales.length > 0 ? (
                        <ul className="space-y-3">
                            {recentSales.map(sale => {
                                const customer = customers.find(c => c.id === sale.customerId);
                                return (
                                <li key={sale.id} className="flex justify-between items-center text-sm p-2 bg-gray-50 rounded-md">
                                    <div>
                                        <p className="font-medium text-gray-600">{new Date(sale.date).toLocaleDateString()}</p>
                                        <p className="text-xs text-gray-500">{sale.items.length} items to {customer?.name || 'Unknown'}</p>
                                    </div>
                                    <span className="font-bold text-gray-800" title={formatCurrency(sale.total, cs)}>{cs}{formatAbbreviatedNumber(sale.total)}</span>
                                </li>
                            )})}
                        </ul>
                    ) : (
                        <p className="text-center text-sm text-gray-500 py-4">You have no recent sales.</p>
                    )}
                </Card>

                <Card title="Withdrawal History">
                    {sortedWithdrawals.length > 0 ? (
                        <div className="space-y-3">
                             {sortedWithdrawals.map((withdrawal) => (
                                <div key={withdrawal.id} className="text-sm p-3 bg-gray-50 rounded-md">
                                    <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-2">
                                        <div className="flex-grow">
                                            <div className="flex justify-between items-center">
                                                <p className="font-medium text-gray-600">{new Date(withdrawal.date).toLocaleDateString()}</p>
                                                <span className="font-bold text-red-600 sm:hidden">-{formatCurrency(withdrawal.amount, cs)}</span>
                                            </div>
                                            <div className="mt-2 flex items-center gap-4">
                                                {getWithdrawalStatusBadge(withdrawal.status)}
                                                {withdrawal.status === 'paid' && <span className="text-xs text-purple-800 animate-pulse hidden sm:inline">Awaiting Confirmation</span>}
                                            </div>
                                        </div>
                                        <div className="text-right hidden sm:block">
                                             <span className="font-bold text-red-600">-{formatCurrency(withdrawal.amount, cs)}</span>
                                        </div>
                                    </div>
                                    {(withdrawal.status === 'paid' || withdrawal.status === 'completed') && (
                                    <div className="mt-3 pt-3 border-t border-gray-200">
                                        {withdrawal.status === 'paid' && (
                                            <button 
                                                onClick={() => {
                                                    onConfirmWithdrawalReceived(currentUser.id, withdrawal.id);
                                                    setWithdrawalReceiptToShow({ ...withdrawal, status: 'completed' });
                                                }}
                                                className="w-full sm:w-auto px-3 py-1.5 text-xs font-bold text-white bg-green-500 rounded-md hover:bg-green-600 transition-all shadow transform active:scale-95"
                                            >
                                                Confirm I've Received Payment
                                            </button>
                                        )}
                                        {withdrawal.status === 'completed' && (
                                            <button 
                                                onClick={() => setWithdrawalReceiptToShow(withdrawal)}
                                                className="w-full sm:w-auto px-3 py-1.5 text-xs font-bold text-primary bg-primary/10 rounded-md hover:bg-primary/20 transition-all"
                                            >
                                                View Receipt
                                            </button>
                                        )}
                                    </div>
                                    )}
                                </div>
                            ))}
                             <div className="mt-4 pt-4 border-t text-xs text-gray-600">
                                <p><strong>Info:</strong> Your available balance is your total earnings minus any withdrawals that are approved for payout or already paid.</p>
                            </div>
                        </div>
                    ) : (
                         <p className="text-center text-sm text-gray-500 py-4">You have no withdrawal history.</p>
                    )}
                </Card>
            </div>

            <Card title="Custom Payments">
                {sortedCustomPayments.length > 0 ? (
                    <div className="space-y-3">
                        {sortedCustomPayments.map(payment => (
                             <div key={payment.id} className="text-sm p-3 bg-gray-50 rounded-md">
                                <div className="flex justify-between items-start">
                                    <div>
                                        <p className="font-semibold text-gray-800">{payment.description}</p>
                                        <p className="text-xs text-gray-500 mt-1">Initiated: {new Date(payment.dateInitiated).toLocaleDateString()}</p>
                                    </div>
                                    <p className="font-bold text-lg text-primary">{formatCurrency(payment.amount, cs)}</p>
                                </div>
                                <div className="mt-3 pt-3 border-t flex justify-between items-center">
                                    {getPaymentStatusBadge(payment.status)}
                                    
                                    {payment.status === 'pending_user_approval' && (
                                        <div className="flex items-center gap-2">
                                            <button onClick={() => handleUpdateCustomPaymentStatus(currentUser.id, payment.id, 'rejected_by_user')} className="px-4 py-2 text-sm font-semibold text-white bg-red-500 rounded-lg hover:bg-red-600">Reject</button>
                                            <button onClick={() => handleUpdateCustomPaymentStatus(currentUser.id, payment.id, 'approved_by_user')} className="px-4 py-2 text-sm font-semibold text-white bg-green-500 rounded-lg hover:bg-green-600">Accept</button>
                                        </div>
                                    )}
                                    {payment.status === 'paid' && (
                                        <button onClick={() => {
                                                handleUpdateCustomPaymentStatus(currentUser.id, payment.id, 'completed');
                                                setPaymentReceiptToShow({ ...payment, status: 'completed' });
                                            }} className="px-3 py-1.5 text-xs font-bold text-white bg-green-500 rounded-md hover:bg-green-600">
                                            Confirm Receipt
                                        </button>
                                    )}
                                    {payment.status === 'completed' && (
                                         <button 
                                            onClick={() => setPaymentReceiptToShow(payment)}
                                            className="px-3 py-1.5 text-xs font-bold text-primary bg-primary/10 rounded-md hover:bg-primary/20"
                                        >
                                            View Receipt
                                        </button>
                                    )}
                                </div>
                            </div>
                        ))}
                    </div>
                ) : (
                    <p className="text-center text-sm text-gray-500 py-4">You have no custom payments.</p>
                )}
            </Card>

            <WithdrawalRequestModal
                isOpen={isWithdrawalModalOpen}
                onClose={() => setIsWithdrawalModalOpen(false)}
                onConfirm={handleRequestSubmit}
                availableBalance={availableBalance}
                currencySymbol={cs}
            />
             <WithdrawalReceiptModal
                isOpen={!!withdrawalReceiptToShow}
                onClose={() => setWithdrawalReceiptToShow(null)}
                withdrawal={withdrawalReceiptToShow}
                user={currentUser}
                businessProfile={businessProfile}
                receiptSettings={receiptSettings}
            />
            <PaymentReceiptModal
                isOpen={!!paymentReceiptToShow}
                onClose={() => setPaymentReceiptToShow(null)}
                payment={paymentReceiptToShow}
                user={currentUser}
                businessProfile={businessProfile}
                receiptSettings={receiptSettings}
            />
            <EditProfileModal isOpen={isEditModalOpen} onClose={() => setIsEditModalOpen(false)} currentUser={currentUser} onSave={handleSaveProfile} receiptSettings={receiptSettings} />
        </div>
    );
};


// --- MAIN PROFILE COMPONENT (SWITCHER) ---
const MyProfile: React.FC<MyProfileProps> = (props) => {
    if (props.currentUser.role === 'Owner') {
        return <OwnerProfile {...props} />;
    }
    return <StandardProfile {...props} />;
}


export default MyProfile;