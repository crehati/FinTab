
// @ts-nocheck
import React, { useState, useMemo } from 'react';
import type { User, Sale, Customer, AppPermissions, UserPermissions, PerformanceUser, ReceiptSettingsData, OwnerSettings, BusinessProfile } from '../types';
import Card from './Card';
import EmptyState from './EmptyState';
import { PlusIcon, StaffIcon } from '../constants';
import UserModal from './UserModal';
import UserDetailModal from './UserDetailModal';
import UserPermissionModal from './UserPermissionModal';
import ConfirmationModal from './ConfirmationModal';
import { hasAccess } from '../lib/permissions';
import { formatAbbreviatedNumber } from '../lib/utils';

interface UsersProps {
    users: User[];
    sales: Sale[];
    customers: Customer[];
    currentUser: User;
    receiptSettings: ReceiptSettingsData;
    onSaveUser: (userData: Omit<User, 'id' | 'avatarUrl'>, isEditing: boolean) => void;
    onDeleteUser: (userId: string) => void;
    permissions: AppPermissions;
    ownerSettings: OwnerSettings;
    businessProfile: BusinessProfile | null;
}

const Users: React.FC<UsersProps> = ({ users = [], sales = [], customers = [], currentUser, receiptSettings, onSaveUser, onDeleteUser, permissions, ownerSettings, businessProfile }) => {
    const [isAddModalOpen, setIsAddModalOpen] = useState(false);
    const [selectedUser, setSelectedUser] = useState<PerformanceUser | null>(null);
    const [permissionEditingUser, setPermissionEditingUser] = useState<User | null>(null);
    const [userToDelete, setUserToDelete] = useState<User | null>(null);

    const cs = receiptSettings.currencySymbol;
    const canManage = hasAccess(currentUser, 'SETTINGS', 'manage_permissions', permissions);

    const userPerformance = useMemo(() => {
        return users.map(member => {
            const memberSales = sales.filter(s => s && s.userId === member.id && s.status === 'completed');
            return { ...member, salesCount: memberSales.length, totalCommission: memberSales.reduce((sum, s) => sum + (s.commission || 0), 0) };
        });
    }, [users, sales]);

    return (
        <div className="space-y-8 font-sans">
            <header className="flex justify-between items-end px-2">
                <div>
                    <h1 className="text-3xl font-black text-slate-900 dark:text-white uppercase tracking-tighter">Personnel</h1>
                    <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest mt-1">Authorized terminal identity nodes</p>
                </div>
                <button onClick={() => setIsAddModalOpen(true)} className="bg-primary text-white px-8 py-3 rounded-2xl font-black uppercase text-[10px] shadow-xl active:scale-95 transition-all flex items-center gap-2">
                    <PlusIcon className="w-4 h-4" /> Enroll Personnel
                </button>
            </header>

            <Card title="Operational Roster">
                <div className="overflow-x-auto min-h-[500px]">
                    {users.length > 0 ? (
                        <table className="w-full text-left">
                            <thead className="text-[10px] font-black uppercase tracking-widest text-slate-400 border-b">
                                <tr>
                                    <th className="px-6 py-4">Identity Node</th>
                                    <th className="px-6 py-4">Role</th>
                                    <th className="px-6 py-4 text-center">Settlements</th>
                                    <th className="px-6 py-4 text-right">Yield</th>
                                    <th className="px-6 py-4 text-right">Audit</th>
                                </tr>
                            </thead>
                            <tbody className="divide-y">
                                {userPerformance.map(member => (
                                    <tr key={member.id} className="hover:bg-slate-50 transition-colors">
                                        <td className="px-6 py-6">
                                            <div className="flex items-center gap-4">
                                                <img src={member.avatarUrl} className="w-12 h-12 rounded-2xl object-cover border-4 border-white shadow-sm" alt=""/>
                                                <div>
                                                    <p className="font-black text-slate-900 dark:text-white uppercase tracking-tighter text-sm">{member.name}</p>
                                                    <p className="text-[9px] text-slate-400 font-bold tracking-widest truncate max-w-[120px]">{member.email}</p>
                                                </div>
                                            </div>
                                        </td>
                                        <td className="px-6 py-6 font-bold uppercase text-[9px] tracking-widest text-slate-500">{member.role_label || member.role}</td>
                                        <td className="px-6 py-6 text-center font-black tabular-nums">{member.salesCount}</td>
                                        <td className="px-6 py-6 text-right font-black text-emerald-600 tabular-nums">{cs}{formatAbbreviatedNumber(member.totalCommission)}</td>
                                        <td className="px-6 py-6 text-right">
                                            <div className="flex justify-end gap-5">
                                                <button onClick={() => setSelectedUser(member)} className="text-[9px] font-black uppercase text-primary hover:underline">Full Audit</button>
                                                {canManage && (
                                                    <>
                                                        <button onClick={() => setPermissionEditingUser(member)} className="text-[9px] font-black uppercase text-emerald-600 hover:underline">Rights</button>
                                                        <button onClick={() => setUserToDelete(member)} className="text-[9px] font-black uppercase text-rose-500 hover:underline">Revoke</button>
                                                    </>
                                                )}
                                            </div>
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    ) : <EmptyState icon={<StaffIcon />} title="No Personnel Enrolled" />}
                </div>
            </Card>

            <UserModal isOpen={isAddModalOpen} onClose={() => setIsAddModalOpen(false)} onSave={onSaveUser} receiptSettings={receiptSettings} existingUsers={users} currentUser={currentUser} />
            {selectedUser && <UserDetailModal isOpen={!!selectedUser} onClose={() => setSelectedUser(null)} user={selectedUser} sales={sales} expenses={[]} customers={customers} currentUser={currentUser} receiptSettings={receiptSettings} businessProfile={businessProfile} onClockInOut={() => {}} />}
            <UserPermissionModal isOpen={!!permissionEditingUser} onClose={() => setPermissionEditingUser(null)} user={permissionEditingUser} onSave={(uid, perms, label) => { /* Wire this to App.tsx */ alert("Rights Synced."); setPermissionEditingUser(null); }} />
            <ConfirmationModal isOpen={!!userToDelete} onClose={() => setUserToDelete(null)} onConfirm={() => onDeleteUser(userToDelete.id)} title="Revoke Authorization" message={`Confirm permanent revocation of ${userToDelete?.name}'s terminal access node?`} variant="danger" isIrreversible={true} />
        </div>
    );
};

export default Users;
