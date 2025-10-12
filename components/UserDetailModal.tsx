import React, { useMemo, useState, useEffect } from 'react';
import type { User, Sale, AttendanceRecord, PerformanceUser, ReceiptSettingsData, CustomPayment, Customer, Withdrawal, BusinessProfile } from '../types';
import { formatCurrency, formatAbbreviatedNumber } from '../lib/utils';
import WithdrawalReceiptModal from './WithdrawalReceiptModal';
import PaymentReceiptModal from './PaymentReceiptModal';


interface UserDetailModalProps {
    isOpen: boolean;
    onClose: () => void;
    user: PerformanceUser | null;
    sales: Sale[];
    customers: Customer[];
    onClockInOut: (userId: string) => void;
    currentUser: User | null; // For permission checks
    receiptSettings: ReceiptSettingsData;
    businessProfile: BusinessProfile | null;
}

const CloseIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
    </svg>
);

const MetricCard: React.FC<{ title: string; value: string; fullValue?: string; color?: string }> = ({ title, value, fullValue, color = 'text-gray-900 dark:text-gray-100' }) => (
    <div className="bg-gray-50 dark:bg-gray-700/50 p-4 rounded-lg text-center shadow-sm border dark:border-gray-700" title={fullValue}>
        <p className="text-sm font-medium text-gray-500 dark:text-gray-400 truncate">{title}</p>
        <p className={`text-2xl font-bold mt-1 ${color}`}>{value}</p>
    </div>
);

const getWithdrawalStatusBadge = (status: Withdrawal['status']) => {
    const styles: Record<Withdrawal['status'], string> = {
        pending: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/50 dark:text-yellow-300',
        approved: 'bg-blue-100 text-blue-800 dark:bg-blue-900/50 dark:text-blue-300',
        paid: 'bg-purple-100 text-purple-800 dark:bg-purple-900/50 dark:text-purple-300',
        completed: 'bg-green-100 text-green-800 dark:bg-green-900/50 dark:text-green-300',
        rejected: 'bg-red-100 text-red-800 dark:bg-red-900/50 dark:text-red-300',
    };
    return <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${styles[status]}`}>{status.charAt(0).toUpperCase() + status.slice(1)}</span>;
};

const getPaymentStatusBadge = (status: CustomPayment['status']) => {
    const styles: Record<CustomPayment['status'], string> = {
        pending_user_approval: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/50 dark:text-yellow-300',
        rejected_by_user: 'bg-red-100 text-red-800 dark:bg-red-900/50 dark:text-red-300',
        approved_by_user: 'bg-blue-100 text-blue-800 dark:bg-blue-900/50 dark:text-blue-300',
        paid: 'bg-purple-100 text-purple-800 dark:bg-purple-900/50 dark:text-purple-300',
        completed: 'bg-green-100 text-green-800 dark:bg-green-900/50 dark:text-green-300',
    };
    const text: Record<CustomPayment['status'], string> = {
        pending_user_approval: 'Pending User Approval',
        rejected_by_user: 'Rejected by User',
        approved_by_user: 'Approved by User',
        paid: 'Paid',
        completed: 'Completed',
    };
    return <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${styles[status]}`}>{text[status]}</span>;
};


const UserDetailModal: React.FC<UserDetailModalProps> = ({ isOpen, onClose, user, sales, customers, onClockInOut, currentUser, receiptSettings, businessProfile }) => {
    const [activeTab, setActiveTab] = useState<'financial' | 'attendance' | 'sales'>('financial');
    const [withdrawalReceiptToShow, setWithdrawalReceiptToShow] = useState<Withdrawal | null>(null);
    const [paymentReceiptToShow, setPaymentReceiptToShow] = useState<CustomPayment | null>(null);
    
    // Reset to financial tab when a new user is selected
    useEffect(() => {
        if (isOpen) {
            setActiveTab('financial');
        }
    }, [isOpen, user]);

    if (!isOpen || !user) return null;
    
    const cs = receiptSettings.currencySymbol;

    const availableBalance = user.type === 'commission' 
        ? user.totalCommission - user.totalWithdrawals 
        : user.totalHourlyEarnings - user.totalWithdrawals;

    const lastAttendance = user.attendance?.[user.attendance.length - 1];
    const isClockedIn = !!(lastAttendance && !lastAttendance.clockOut);
    
    const canManage = currentUser && ['Owner', 'Manager'].includes(currentUser.role);
    
    const sortedWithdrawals = [...(user.withdrawals || [])].sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime());
    const sortedCustomPayments = [...(user.customPayments || [])].sort((a, b) => new Date(b.dateInitiated).getTime() - new Date(a.dateInitiated).getTime());
    const recentSales = sales
        .filter(sale => sale.userId === user.id && sale.status === 'completed')
        .sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime())
        .slice(0, 10);
    
    const displayRole = user.role === 'Custom' && user.customRoleName ? user.customRoleName : user.role;

    return (
        <>
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4" role="dialog" aria-modal="true">
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow-2xl w-full max-w-4xl max-h-[90vh] flex flex-col">
                <header className="p-4 sm:p-6 border-b dark:border-gray-700 flex justify-between items-center flex-shrink-0">
                    <div className="flex items-center gap-4">
                        <img src={user.avatarUrl} alt={user.name} className="w-12 h-12 rounded-full object-cover" />
                        <div>
                            <h2 className="text-xl sm:text-2xl font-bold text-gray-800 dark:text-gray-100">{user.name}</h2>
                            <p className="text-sm text-gray-500 dark:text-gray-400">{displayRole}</p>
                        </div>
                    </div>
                    <button onClick={onClose} className="text-gray-500 dark:text-gray-400 hover:text-gray-800 dark:hover:text-gray-200" aria-label="Close user details">
                        <CloseIcon />
                    </button>
                </header>
                
                <main className="flex-grow overflow-y-auto p-4 sm:p-6 bg-gray-50 dark:bg-gray-900">
                    <div className="border-b border-gray-200 dark:border-gray-700 mb-6">
                        <nav className="-mb-px flex space-x-6" aria-label="Tabs">
                            <button onClick={() => setActiveTab('financial')} className={`whitespace-nowrap py-3 px-1 border-b-2 font-medium text-sm ${activeTab === 'financial' ? 'border-primary text-primary' : 'border-transparent text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-300'}`}>Financial Overview</button>
                            {user.type === 'hourly' && (
                                <button onClick={() => setActiveTab('attendance')} className={`whitespace-nowrap py-3 px-1 border-b-2 font-medium text-sm ${activeTab === 'attendance' ? 'border-primary text-primary' : 'border-transparent text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-300'}`}>Attendance Log</button>
                            )}
                            <button onClick={() => setActiveTab('sales')} className={`whitespace-nowrap py-3 px-1 border-b-2 font-medium text-sm ${activeTab === 'sales' ? 'border-primary text-primary' : 'border-transparent text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-300'}`}>Recent Sales</button>
                        </nav>
                    </div>
                    
                    {activeTab === 'financial' && (
                        <div className="space-y-6">
                            <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
                                {user.type === 'commission' ? (
                                    <>
                                        <MetricCard title="Total Sales Value" value={`${cs}${formatAbbreviatedNumber(user.totalSalesValue)}`} fullValue={formatCurrency(user.totalSalesValue, cs)} />
                                        <MetricCard title="Commission Earned" value={`${cs}${formatAbbreviatedNumber(user.totalCommission)}`} fullValue={formatCurrency(user.totalCommission, cs)} color="text-green-600 dark:text-green-400" />
                                    </>
                                ) : (
                                    <>
                                        <MetricCard title="Hours Worked" value={`${user.totalHours.toFixed(2)}`} />
                                        <MetricCard title="Total Earnings" value={`${cs}${formatAbbreviatedNumber(user.totalHourlyEarnings)}`} fullValue={formatCurrency(user.totalHourlyEarnings, cs)} color="text-green-600 dark:text-green-400" />
                                    </>
                                )}
                                <MetricCard title="Withdrawals" value={`${cs}${formatAbbreviatedNumber(user.totalWithdrawals)}`} fullValue={formatCurrency(user.totalWithdrawals, cs)} color="text-red-600 dark:text-red-400" />
                                <MetricCard title="Available Balance" value={`${cs}${formatAbbreviatedNumber(availableBalance)}`} fullValue={formatCurrency(availableBalance, cs)} color="text-primary dark:text-accent-sky" />
                            </div>
                            <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
                                <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow-sm border dark:border-gray-700">
                                    <h4 className="font-semibold text-gray-700 dark:text-gray-200 mb-2">Withdrawal History</h4>
                                    {sortedWithdrawals.length > 0 ? (
                                        <ul className="space-y-2 max-h-60 overflow-y-auto">
                                            {sortedWithdrawals.map(w => (
                                                <li key={w.id} className="text-sm p-2 bg-gray-50 dark:bg-gray-700/50 rounded-md flex justify-between items-center">
                                                    <div>
                                                        <p className="font-medium text-gray-600 dark:text-gray-300">{new Date(w.date).toLocaleDateString()}</p>
                                                        <p className="font-bold text-red-600 dark:text-red-400">-{formatCurrency(w.amount, cs)}</p>
                                                    </div>
                                                    <div className="flex flex-col items-end gap-1 text-right">
                                                        {getWithdrawalStatusBadge(w.status)}
                                                        {w.status === 'completed' && (
                                                            <button onClick={() => setWithdrawalReceiptToShow(w)} className="text-xs font-semibold text-primary hover:underline">View Receipt</button>
                                                        )}
                                                    </div>
                                                </li>
                                            ))}
                                        </ul>
                                    ) : <p className="text-sm text-gray-500 dark:text-gray-400 text-center py-4">No withdrawal history.</p>}
                                </div>
                                <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow-sm border dark:border-gray-700">
                                    <h4 className="font-semibold text-gray-700 dark:text-gray-200 mb-2">Custom Payment History</h4>
                                    {sortedCustomPayments.length > 0 ? (
                                        <ul className="space-y-2 max-h-60 overflow-y-auto">
                                            {sortedCustomPayments.map(p => (
                                                <li key={p.id} className="text-sm p-2 bg-gray-50 dark:bg-gray-700/50 rounded-md flex justify-between items-center">
                                                    <div>
                                                        <p className="font-medium text-gray-600 dark:text-gray-300">{p.description}</p>
                                                        <p className="font-bold text-primary dark:text-accent-sky">{formatCurrency(p.amount, cs)}</p>
                                                    </div>
                                                    <div className="flex flex-col items-end gap-1 text-right">
                                                        {getPaymentStatusBadge(p.status)}
                                                        {p.status === 'completed' && (
                                                            <button onClick={() => setPaymentReceiptToShow(p)} className="text-xs font-semibold text-primary hover:underline">View Receipt</button>
                                                        )}
                                                    </div>
                                                </li>
                                            ))}
                                        </ul>
                                    ) : <p className="text-sm text-gray-500 dark:text-gray-400 text-center py-4">No custom payment history.</p>}
                                </div>
                            </div>
                        </div>
                    )}

                    {activeTab === 'attendance' && user.type === 'hourly' && (
                        <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow-sm border dark:border-gray-700">
                            <div className="flex justify-between items-center mb-3">
                                <h3 className="text-lg font-semibold text-gray-700 dark:text-gray-200">Attendance Log</h3>
                                <span className={`px-2.5 py-1 text-xs font-semibold rounded-full ${isClockedIn ? 'bg-green-100 text-green-800 dark:bg-green-900/50 dark:text-green-300' : 'bg-gray-200 text-gray-800 dark:bg-gray-700 dark:text-gray-300'}`}>
                                    {isClockedIn ? 'Clocked In' : 'Clocked Out'}
                                </span>
                            </div>
                            {canManage && (
                                <button onClick={() => onClockInOut(user.id)} className={`w-full mb-4 px-4 py-2 text-sm font-semibold rounded-md text-white ${isClockedIn ? 'bg-red-500 hover:bg-red-600' : 'bg-green-500 hover:bg-green-600'}`}>
                                    Manually {isClockedIn ? 'Clock Out' : 'Clock In'}
                                </button>
                            )}
                            {user.attendance && user.attendance.length > 0 ? (
                                <ul className="space-y-2 max-h-96 overflow-y-auto">
                                    {[...user.attendance].reverse().map((record, index) => (
                                        <li key={index} className="text-sm p-2 rounded-md bg-gray-50 dark:bg-gray-700/50">
                                            <p><strong className="text-gray-600 dark:text-gray-400">Clock In:</strong> {new Date(record.clockIn).toLocaleString()}</p>
                                            <p><strong className="text-gray-600 dark:text-gray-400">Clock Out:</strong> {record.clockOut ? new Date(record.clockOut).toLocaleString() : 'N/A'}</p>
                                        </li>
                                    ))}
                                </ul>
                            ) : (
                                <p className="text-center text-sm text-gray-500 dark:text-gray-400 py-4">No attendance records found.</p>
                            )}
                        </div>
                    )}

                    {activeTab === 'sales' && (
                        <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow-sm border dark:border-gray-700">
                            <h3 className="text-lg font-semibold text-gray-700 dark:text-gray-200 mb-3">Recent Sales</h3>
                            {recentSales.length > 0 ? (
                                <ul className="space-y-3 divide-y divide-gray-100 dark:divide-gray-700 max-h-96 overflow-y-auto">
                                    {recentSales.map(sale => {
                                        const customer = customers.find(c => c.id === sale.customerId);
                                        return (
                                            <li key={sale.id} className="pt-3 first:pt-0">
                                                <div className="flex justify-between items-center text-sm">
                                                    <div>
                                                        <p className="font-medium text-gray-600 dark:text-gray-300">{new Date(sale.date).toLocaleString()}</p>
                                                        <p className="text-xs text-gray-500 dark:text-gray-400">to {customer?.name || 'Unknown Client'}</p>
                                                    </div>
                                                    <p className="font-bold text-gray-800 dark:text-gray-100">{formatCurrency(sale.total, cs)}</p>
                                                </div>
                                                <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">{sale.items.length} items sold</p>
                                            </li>
                                        );
                                    })}
                                </ul>
                            ) : (
                                <p className="text-center text-sm text-gray-500 dark:text-gray-400 py-4">No recent sales found.</p>
                            )}
                        </div>
                    )}
                </main>
            </div>
        </div>
        <WithdrawalReceiptModal
            isOpen={!!withdrawalReceiptToShow}
            onClose={() => setWithdrawalReceiptToShow(null)}
            withdrawal={withdrawalReceiptToShow}
            user={user}
            businessProfile={businessProfile}
            receiptSettings={receiptSettings}
        />
        <PaymentReceiptModal
            isOpen={!!paymentReceiptToShow}
            onClose={() => setPaymentReceiptToShow(null)}
            payment={paymentReceiptToShow}
            user={user}
            businessProfile={businessProfile}
            receiptSettings={receiptSettings}
        />
        </>
    );
};

export default UserDetailModal;
