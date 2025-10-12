import React, { useState, useMemo } from 'react';
import type { User, Sale, AttendanceRecord, PerformanceUser, ReceiptSettingsData, Role, CustomPayment, Customer, AppPermissions, UserPermissions, OwnerSettings, BusinessProfile } from '../types';
import Card from './Card';
import { QRCodeIcon, PrintIcon, PlusIcon } from '../constants';
import PrintQRModal from './PrintQRModal';
import QRScannerModal from './QRScannerModal';
import UserDetailModal from './UserDetailModal';
import UserModal from './UserModal';
import ConfirmationModal from './ConfirmationModal';
import UserPermissionModal from './UserPermissionModal'; // Import the new modal
import { hasAccess } from '../lib/permissions';
import { formatCurrency, formatAbbreviatedNumber } from '../lib/utils';

interface UsersProps {
    users: User[];
    sales: Sale[];
    customers: Customer[];
    t: (key: string) => string;
    currentUser: User | null;
    receiptSettings: ReceiptSettingsData;
    onSaveUser: (userData: Omit<User, 'id' | 'avatarUrl'>, isEditing: boolean, existingUserId?: string) => void;
    onDeleteUser: (userId: string) => void;
    trialLimits: { canAddStaff: boolean };
    permissions: AppPermissions;
    setPermissions: (permissions: AppPermissions) => void;
    ownerSettings: OwnerSettings;
    businessProfile: BusinessProfile | null;
}

const calculateTotalHours = (attendance: AttendanceRecord[] = []): number => {
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

const displayRole = (user: User) => user.role === 'Custom' && user.customRoleName ? user.customRoleName : user.role;


const Users: React.FC<UsersProps> = ({ users, sales, customers, t, currentUser, receiptSettings, onSaveUser, onDeleteUser, trialLimits, permissions, setPermissions, ownerSettings, businessProfile }) => {
    const [activeTab, setActiveTab] = useState<'commission' | 'hourly'>('commission');
    const [isPrintQRModalOpen, setIsPrintQRModalOpen] = useState(false);
    const [isQRScannerModalOpen, setIsQRScannerModalOpen] = useState(false);
    const [isDetailModalOpen, setIsDetailModalOpen] = useState(false);
    const [isUserModalOpen, setIsUserModalOpen] = useState(false);
    const [isConfirmModalOpen, setIsConfirmModalOpen] = useState(false);
    const [isPermissionModalOpen, setIsPermissionModalOpen] = useState(false); // New state for permission modal
    
    const [selectedUser, setSelectedUser] = useState<PerformanceUser | null>(null);
    const [editingUser, setEditingUser] = useState<User | null>(null);
    const [userToDelete, setUserToDelete] = useState<User | null>(null);
    const [permissionEditingUser, setPermissionEditingUser] = useState<User | null>(null); // New state for user being edited in permission modal

    const cs = receiptSettings.currencySymbol;

    const handleClockInOut = (userId: string) => {
        alert("Manual clock-in/out from this screen to be implemented.");
    };
    
    const handleCurrentUserClockInOut = () => {
        if (currentUser && currentUser.type === 'hourly') {
            alert("Clock-in via scanner to be fully implemented with state propagation.");
        } else {
            alert('Clock in/out is only available for the logged in hourly user.');
        }
    };
    
    const handleOpenInviteModal = () => {
        setEditingUser(null);
        setIsUserModalOpen(true);
    };

    const handleOpenEditModal = (user: User) => {
        setEditingUser(user);
        setIsUserModalOpen(true);
    };

    const handleSaveUser = (userData: Omit<User, 'id' | 'avatarUrl'>, isEditing: boolean) => {
        onSaveUser(userData, isEditing, editingUser?.id);
        setIsUserModalOpen(false);
        setEditingUser(null);
    };

    const handleDeleteClick = (user: User) => {
        setUserToDelete(user);
        setIsConfirmModalOpen(true);
    };

    const handleConfirmDelete = () => {
        if (userToDelete) {
            onDeleteUser(userToDelete.id);
        }
        setIsConfirmModalOpen(false);
        setUserToDelete(null);
    };

    const handleOpenPermissionModal = (user: User) => {
        setPermissionEditingUser(user);
        setIsPermissionModalOpen(true);
    };

    const handleSavePermissions = (userId: string, userPermissions: UserPermissions) => {
        setPermissions(prev => {
            const newPerms = JSON.parse(JSON.stringify(prev));
            if (Object.keys(userPermissions).length === 0) {
                delete newPerms.users[userId];
            } else {
                newPerms.users[userId] = userPermissions;
            }
            return newPerms;
        });
        setIsPermissionModalOpen(false);
    };

    const userPerformance = useMemo((): PerformanceUser[] => {
        return users.map(member => {
            const memberSales = sales.filter(sale => sale.userId === member.id && sale.status !== 'proforma');
            const totalCommission = memberSales.reduce((sum, sale) => sum + (sale.commission || 0), 0);
            const totalSalesValue = memberSales.reduce((sum, sale) => sum + sale.total, 0);

            const totalHours = calculateTotalHours(member.attendance);
            const totalHourlyEarnings = (member.hourlyRate || 0) * totalHours;
            
            const totalCommissionWithdrawals = (member.withdrawals || [])
                .filter(w => (w.status === 'approved' || w.status === 'paid' || w.status === 'completed') && w.source === 'commission')
                .reduce((sum, w) => sum + w.amount, 0);
            const totalInvestmentWithdrawals = (member.withdrawals || [])
                .filter(w => (w.status === 'approved' || w.status === 'paid' || w.status === 'completed') && w.source === 'investment')
                .reduce((sum, w) => sum + w.amount, 0);

            return {
                ...member,
                salesCount: memberSales.length,
                totalSalesValue,
                totalCommission,
                totalHours,
                totalHourlyEarnings,
                totalCommissionWithdrawals,
                totalInvestmentWithdrawals,
            };
        });
    }, [users, sales]);

    const commissionUsers = useMemo(() => 
        userPerformance.filter(s => 
            s.type === 'commission' && 
            (s.role !== 'Investor' || hasAccess(s, '/features/canSell', 'view', permissions)) &&
            (s.role !== 'Owner' || (ownerSettings && ownerSettings.includeInStaffReports))
        ), 
    [userPerformance, permissions, ownerSettings]);

    const hourlyUsers = userPerformance.filter(s => s.type === 'hourly');
    
    const canManage = currentUser && ['Owner', 'Manager'].includes(currentUser.role);
    
    const renderCommission = () => (
        <>
            {/* Desktop Table */}
            <table className="hidden md:table w-full text-sm text-left text-gray-500">
                <thead className="text-xs text-gray-700 uppercase bg-gray-50">
                    <tr>
                        <th scope="col" className="px-6 py-3">User</th>
                        <th scope="col" className="px-6 py-3">Role</th>
                        <th scope="col" className="px-6 py-3">Status</th>
                        <th scope="col" className="px-6 py-3">Total Sales</th>
                        <th scope="col" className="px-6 py-3">Commission</th>
                        <th scope="col" className="px-6 py-3">Available</th>
                        {canManage && <th scope="col" className="px-6 py-3">Actions</th>}
                    </tr>
                </thead>
                <tbody>
                    {commissionUsers.map(member => {
                        const availableCommission = member.totalCommission - member.totalCommissionWithdrawals;
                        return (
                            <tr key={member.id} className="bg-white border-b hover:bg-gray-50">
                                <td className="px-6 py-4 font-medium text-gray-900 flex items-center">
                                    <img src={member.avatarUrl} alt={member.name} className="w-10 h-10 rounded-full mr-3 object-cover" />
                                    {member.name}
                                </td>
                                <td className="px-6 py-4 text-gray-800">{displayRole(member)}</td>
                                <td className="px-6 py-4">
                                    <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${member.status === 'Active' ? 'bg-green-100 text-green-800' : 'bg-yellow-100 text-yellow-800'}`}>
                                        {member.status || 'Active'}
                                    </span>
                                </td>
                                <td className="px-6 py-4 text-gray-800" title={formatCurrency(member.totalSalesValue, cs)}>{cs}{formatAbbreviatedNumber(member.totalSalesValue)}</td>
                                <td className="px-6 py-4 font-semibold text-green-600" title={formatCurrency(member.totalCommission, cs)}>{cs}{formatAbbreviatedNumber(member.totalCommission)}</td>
                                <td className="px-6 py-4 font-bold text-primary" title={formatCurrency(availableCommission, cs)}>{cs}{formatAbbreviatedNumber(availableCommission)}</td>
                                {canManage && (
                                    <td className="px-6 py-4 whitespace-nowrap space-x-3">
                                        <button onClick={() => { setSelectedUser(member); setIsDetailModalOpen(true); }} className="font-medium text-blue-600 hover:text-blue-800">View</button>
                                        <button onClick={() => handleOpenEditModal(member)} className="font-medium text-primary hover:underline">Edit</button>
                                        <button onClick={() => handleOpenPermissionModal(member)} className="font-medium text-accent-teal hover:underline">🔐 Permissions</button>
                                        <button onClick={() => handleDeleteClick(member)} className="font-medium text-red-600 hover:underline">Delete</button>
                                    </td>
                                )}
                            </tr>
                        )
                    })}
                    {commissionUsers.length === 0 && (
                        <tr><td colSpan={canManage ? 7 : 6} className="text-center py-10 text-gray-500">No commission-based users found.</td></tr>
                    )}
                </tbody>
            </table>
            {/* Mobile Cards */}
            <div className="space-y-3 md:hidden">
                {commissionUsers.map(member => {
                    const availableCommission = member.totalCommission - member.totalCommissionWithdrawals;
                    return (
                        <div key={member.id} className="bg-white p-4 rounded-xl shadow-md border border-gray-100">
                            <div className="flex items-center gap-4 mb-3">
                                <img src={member.avatarUrl} alt={member.name} className="w-12 h-12 rounded-full object-cover" />
                                <div>
                                    <p className="font-bold text-lg text-gray-800">{member.name}</p>
                                    <p className="text-sm text-gray-500">{displayRole(member)}</p>
                                </div>
                            </div>
                            <div className="grid grid-cols-2 gap-3 text-sm mb-3">
                                <div className="bg-gray-50 p-2 rounded-md" title={formatCurrency(member.totalCommission, cs)}>
                                    <p className="text-gray-500">Commission</p>
                                    <p className="font-semibold text-green-600">{cs}{formatAbbreviatedNumber(member.totalCommission)}</p>
                                </div>
                                <div className="bg-gray-50 p-2 rounded-md" title={formatCurrency(availableCommission, cs)}>
                                    <p className="text-gray-500">Available</p>
                                    <p className="font-bold text-primary">{cs}{formatAbbreviatedNumber(availableCommission)}</p>
                                </div>
                            </div>
                            {canManage && (
                                <div className="flex items-center justify-end gap-2 pt-2 border-t flex-wrap">
                                    <button onClick={() => { setSelectedUser(member); setIsDetailModalOpen(true); }} className="px-3 py-1 text-xs font-semibold text-blue-600 bg-blue-50 rounded-full hover:bg-blue-100">View</button>
                                    <button onClick={() => handleOpenEditModal(member)} className="px-3 py-1 text-xs font-semibold text-primary bg-primary/10 rounded-full hover:bg-primary/20">Edit</button>
                                    <button onClick={() => handleOpenPermissionModal(member)} className="px-3 py-1 text-xs font-semibold text-accent-teal bg-accent-teal/10 rounded-full hover:bg-accent-teal/20">🔐 Permissions</button>
                                    <button onClick={() => handleDeleteClick(member)} className="px-3 py-1 text-xs font-semibold text-red-600 bg-red-50 rounded-full hover:bg-red-100">Delete</button>
                                </div>
                            )}
                        </div>
                    )
                })}
                {commissionUsers.length === 0 && (
                    <div className="text-center py-10 text-gray-500">No commission-based users found.</div>
                )}
            </div>
        </>
    );

    const renderHourly = () => (
        <>
            {/* Desktop Table */}
            <table className="hidden md:table w-full text-sm text-left text-gray-500">
                <thead className="text-xs text-gray-700 uppercase bg-gray-50">
                    <tr>
                        <th scope="col" className="px-6 py-3">User</th>
                        <th scope="col" className="px-6 py-3">Role</th>
                        <th scope="col" className="px-6 py-3">Status</th>
                        <th scope="col" className="px-6 py-3">Clock-In Status</th>
                        <th scope="col" className="px-6 py-3">Earned</th>
                        <th scope="col" className="px-6 py-3">Available</th>
                        {canManage && <th scope="col" className="px-6 py-3">Actions</th>}
                    </tr>
                </thead>
                <tbody>
                    {hourlyUsers.map(member => {
                        const lastAttendance = member.attendance?.[member.attendance.length - 1];
                        const isClockedIn = lastAttendance && !lastAttendance.clockOut;
                        const availableBalance = member.totalHourlyEarnings - member.totalCommissionWithdrawals;
                        return (
                            <tr key={member.id} className="bg-white border-b hover:bg-gray-50">
                                <td className="px-6 py-4 font-medium text-gray-900 flex items-center">
                                    <img src={member.avatarUrl} alt={member.name} className="w-10 h-10 rounded-full mr-3 object-cover" />
                                    {member.name}
                                </td>
                                <td className="px-6 py-4 text-gray-800">{displayRole(member)}</td>
                                <td className="px-6 py-4">
                                    <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${member.status === 'Active' ? 'bg-green-100 text-green-800' : 'bg-yellow-100 text-yellow-800'}`}>
                                        {member.status || 'Active'}
                                    </span>
                                </td>
                                <td className="px-6 py-4">
                                    <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${isClockedIn ? 'bg-green-100 text-green-800' : 'bg-gray-100 text-gray-800'}`}>
                                        {isClockedIn ? 'Clocked In' : 'Clocked Out'}
                                    </span>
                                </td>
                                <td className="px-6 py-4 font-semibold text-green-600" title={formatCurrency(member.totalHourlyEarnings, cs)}>{cs}{formatAbbreviatedNumber(member.totalHourlyEarnings)}</td>
                                <td className="px-6 py-4 font-bold text-primary" title={formatCurrency(availableBalance, cs)}>{cs}{formatAbbreviatedNumber(availableBalance)}</td>
                                {canManage && (
                                    <td className="px-6 py-4 whitespace-nowrap space-x-3">
                                        <button onClick={() => { setSelectedUser(member); setIsDetailModalOpen(true); }} className="font-medium text-blue-600 hover:text-blue-800">View</button>
                                        <button onClick={() => handleOpenEditModal(member)} className="font-medium text-primary hover:underline">Edit</button>
                                        <button onClick={() => handleOpenPermissionModal(member)} className="font-medium text-accent-teal hover:underline">🔐 Permissions</button>
                                        <button onClick={() => handleDeleteClick(member)} className="font-medium text-red-600 hover:underline">Delete</button>
                                    </td>
                                )}
                            </tr>
                        )
                    })}
                    {hourlyUsers.length === 0 && (
                        <tr><td colSpan={canManage ? 7 : 6} className="text-center py-10 text-gray-500">No hourly-based users found.</td></tr>
                    )}
                </tbody>
            </table>
            {/* Mobile Cards */}
            <div className="space-y-3 md:hidden">
                {hourlyUsers.map(member => {
                    const lastAttendance = member.attendance?.[member.attendance.length - 1];
                    const isClockedIn = lastAttendance && !lastAttendance.clockOut;
                    const availableBalance = member.totalHourlyEarnings - member.totalCommissionWithdrawals;
                    return (
                        <div key={member.id} className="bg-white p-4 rounded-xl shadow-md border border-gray-100">
                            <div className="flex items-center gap-4 mb-3">
                                <img src={member.avatarUrl} alt={member.name} className="w-12 h-12 rounded-full object-cover" />
                                <div>
                                    <p className="font-bold text-lg text-gray-800">{member.name}</p>
                                    <div className="flex items-center gap-2 mt-1">
                                        <p className="text-sm text-gray-500">{displayRole(member)}</p>
                                        <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${isClockedIn ? 'bg-green-100 text-green-800' : 'bg-gray-100 text-gray-800'}`}>
                                            {isClockedIn ? 'Clocked In' : 'Clocked Out'}
                                        </span>
                                    </div>
                                </div>
                            </div>
                            <div className="grid grid-cols-2 gap-3 text-sm mb-3">
                                <div className="bg-gray-50 p-2 rounded-md" title={formatCurrency(member.totalHourlyEarnings, cs)}>
                                    <p className="text-gray-500">Earned</p>
                                    <p className="font-semibold text-green-600">{cs}{formatAbbreviatedNumber(member.totalHourlyEarnings)}</p>
                                </div>
                                <div className="bg-gray-50 p-2 rounded-md" title={formatCurrency(availableBalance, cs)}>
                                    <p className="text-gray-500">Available</p>
                                    <p className="font-bold text-primary">{cs}{formatAbbreviatedNumber(availableBalance)}</p>
                                </div>
                            </div>
                            {canManage && (
                                <div className="flex items-center justify-end gap-2 pt-2 border-t flex-wrap">
                                    <button onClick={() => { setSelectedUser(member); setIsDetailModalOpen(true); }} className="px-3 py-1 text-xs font-semibold text-blue-600 bg-blue-50 rounded-full hover:bg-blue-100">View</button>
                                    <button onClick={() => handleOpenEditModal(member)} className="px-3 py-1 text-xs font-semibold text-primary bg-primary/10 rounded-full hover:bg-primary/20">Edit</button>
                                    <button onClick={() => handleOpenPermissionModal(member)} className="px-3 py-1 text-xs font-semibold text-accent-teal bg-accent-teal/10 rounded-full hover:bg-accent-teal/20">🔐 Permissions</button>
                                    <button onClick={() => handleDeleteClick(member)} className="px-3 py-1 text-xs font-semibold text-red-600 bg-red-50 rounded-full hover:bg-red-100">Delete</button>
                                </div>
                            )}
                        </div>
                    )
                })}
                {hourlyUsers.length === 0 && (
                    <div className="text-center py-10 text-gray-500">No hourly-based users found.</div>
                )}
            </div>
        </>
    );

    return (
        <>
            <Card title={t('staffManagement.title')}>
                <div className="flex flex-col sm:flex-row sm:justify-between sm:items-center mb-4 gap-4">
                    <div className="border-b border-gray-200">
                        <nav className="flex -mb-px space-x-6" aria-label="Tabs">
                            <button 
                                onClick={() => setActiveTab('commission')} 
                                className={`whitespace-nowrap py-3 px-1 border-b-2 font-medium text-sm transition-colors duration-200 ${activeTab === 'commission' ? 'border-primary text-primary' : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'}`}
                                aria-current={activeTab === 'commission' ? 'page' : undefined}
                            >
                                Commission Based ({commissionUsers.length})
                            </button>
                            <button 
                                onClick={() => setActiveTab('hourly')} 
                                className={`whitespace-nowrap py-3 px-1 border-b-2 font-medium text-sm transition-colors duration-200 ${activeTab === 'hourly' ? 'border-primary text-primary' : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'}`}
                                aria-current={activeTab === 'hourly' ? 'page' : undefined}
                            >
                                Hourly Based ({hourlyUsers.length})
                            </button>
                        </nav>
                    </div>
                    <div className="flex items-center gap-2">
                        {canManage && (
                             <button onClick={handleOpenInviteModal} 
                                title="Invite User"
                                className="flex-1 sm:flex-none flex items-center justify-center gap-2 bg-primary text-white px-4 py-2 rounded-lg font-semibold hover:bg-blue-700 transition-colors shadow">
                                <PlusIcon />
                                <span>Invite User</span>
                            </button>
                        )}
                        {activeTab === 'hourly' && (
                            <>
                            {currentUser && currentUser.type === 'hourly' && (
                                <button onClick={() => setIsQRScannerModalOpen(true)} className="flex-1 sm:flex-none flex items-center justify-center gap-2 bg-primary text-white px-4 py-2 rounded-lg font-semibold hover:bg-blue-700 transition-colors shadow">
                                    <QRCodeIcon />
                                    <span>Scan</span>
                                </button>
                            )}
                             <button onClick={() => setIsPrintQRModalOpen(true)} className="hidden sm:flex items-center justify-center gap-2 bg-gray-600 text-white px-4 py-2 rounded-lg font-semibold hover:bg-gray-700 transition-colors shadow">
                                <PrintIcon />
                            </button>
                            </>
                        )}
                    </div>
                </div>
                <div className="overflow-x-auto">
                    {activeTab === 'commission' && renderCommission()}
                    {activeTab === 'hourly' && renderHourly()}
                </div>
            </Card>

            <PrintQRModal 
                isOpen={isPrintQRModalOpen}
                onClose={() => setIsPrintQRModalOpen(false)}
            />
            <QRScannerModal
                isOpen={isQRScannerModalOpen}
                onClose={() => setIsQRScannerModalOpen(false)}
                currentUser={currentUser}
                onClockInOut={handleCurrentUserClockInOut}
            />
            <UserDetailModal
                isOpen={isDetailModalOpen}
                onClose={() => setIsDetailModalOpen(false)}
                user={selectedUser}
                sales={sales}
                customers={customers}
                onClockInOut={handleClockInOut}
                currentUser={currentUser}
                receiptSettings={receiptSettings}
                businessProfile={businessProfile}
            />
            <UserModal
                isOpen={isUserModalOpen}
                onClose={() => setIsUserModalOpen(false)}
                onSave={handleSaveUser}
                userToEdit={editingUser}
                receiptSettings={receiptSettings}
            />
             <ConfirmationModal
                isOpen={isConfirmModalOpen}
                onClose={() => setIsConfirmModalOpen(false)}
                onConfirm={handleConfirmDelete}
                title="Delete User"
                message={`Are you sure you want to delete ${userToDelete?.name}? This action cannot be undone.`}
            />
            <UserPermissionModal
                isOpen={isPermissionModalOpen}
                onClose={() => setIsPermissionModalOpen(false)}
                onSave={handleSavePermissions}
                user={permissionEditingUser}
                allPermissions={permissions}
            />
        </>
    );
};

export default Users;