import React, { useState, useEffect, useMemo } from 'react';
import type { Role, User, AppPermissions, UserPermissions, PermissionSet, PermissionAction } from '../types';
import { PERMISSION_ACTIONS } from '../types';
import { PERMISSION_CONFIG } from '../lib/permissions';
import Card from './Card';

interface PermissionsProps {
    permissions: AppPermissions;
    onUpdatePermissions: (newPermissions: AppPermissions) => void;
    t: (key: string) => string;
    users: User[];
}

const manageableRoles: Role[] = ['Manager', 'Cashier', 'SellerAgent', 'Investor'];

const InfoIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
    </svg>
);

const ShieldCheckIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-10 w-10" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
        <path strokeLinecap="round" strokeLinejoin="round" d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 20.944A12.02 12.02 0 0012 22.444a12.02 12.02 0 009-1.499A11.955 11.955 0 0112 2.944a11.955 11.955 0 018.618 3.04z" />
    </svg>
);


const Tooltip: React.FC<{ text: string }> = ({ text }) => (
    <span className="absolute left-1/2 -translate-x-1/2 bottom-full mb-2 w-max max-w-xs p-2 bg-gray-800 text-white text-xs rounded-md shadow-lg opacity-0 group-hover:opacity-100 transition-opacity duration-200 z-10">
        {text}
    </span>
);

const ToggleSwitch: React.FC<{ checked: boolean; onChange: (checked: boolean) => void; disabled?: boolean; isOverride?: boolean; }> = ({ checked, onChange, disabled, isOverride }) => {
    const baseBg = disabled ? 'bg-gray-200 dark:bg-gray-600' : (checked ? 'bg-primary' : 'bg-gray-300 dark:bg-gray-500');
    const overrideRing = isOverride ? 'ring-2 ring-offset-1 ring-yellow-400 dark:ring-offset-gray-800' : '';
    return (
        <label className={`relative inline-flex items-center cursor-pointer ${disabled ? 'cursor-not-allowed' : ''}`}>
            <input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} className="sr-only peer" disabled={disabled} />
            <div className={`w-11 h-6 rounded-full peer peer-focus:outline-none ${overrideRing} ${baseBg} peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:border-gray-300 after:border after:rounded-full after:h-5 after:w-5 after:transition-all`}></div>
        </label>
    );
};

const Permissions: React.FC<PermissionsProps> = ({ permissions, onUpdatePermissions, t, users }) => {
    const [draftPermissions, setDraftPermissions] = useState<AppPermissions>(permissions);
    const [mode, setMode] = useState<'roles' | 'users'>('roles');
    const [selectedId, setSelectedId] = useState<Role | string>('Manager');

    const hasChanges = useMemo(() => JSON.stringify(permissions) !== JSON.stringify(draftPermissions), [permissions, draftPermissions]);

    const handleToggle = (path: string, action: PermissionAction, enabled: boolean) => {
        setDraftPermissions(prev => {
            const newPerms = JSON.parse(JSON.stringify(prev)); // Deep copy
            const target = mode === 'roles' ? newPerms.roles[selectedId] : (newPerms.users[selectedId] = newPerms.users[selectedId] || {});

            if (!target[path]) {
                target[path] = {};
            }
            target[path][action] = enabled;
            
            // Clean up empty objects
            if (Object.keys(target[path]).length === 0) delete target[path];
            if (mode === 'users' && Object.keys(target).length === 0) delete newPerms.users[selectedId];

            return newPerms;
        });
    };
    
    const handleApplyTemplate = (role: Role) => {
        if (mode !== 'users' || !selectedId) return;
        
        setDraftPermissions(prev => {
            const newPerms = JSON.parse(JSON.stringify(prev));
            newPerms.users[selectedId] = JSON.parse(JSON.stringify(prev.roles[role] || {}));
            return newPerms;
        });
    };

    const handleSaveChanges = () => {
        onUpdatePermissions(draftPermissions);
    };

    const handleCancelChanges = () => {
        setDraftPermissions(permissions);
    };
    
    const getPermissionValue = (path: string, action: PermissionAction): { checked: boolean, isOverride: boolean } => {
        if (mode === 'roles') {
            return { checked: draftPermissions.roles[selectedId as Role]?.[path]?.[action] ?? false, isOverride: false };
        }
        
        // User mode
        const user = users.find(u => u.id === selectedId);
        if (!user) return { checked: false, isOverride: false };

        const userOverride = draftPermissions.users[selectedId]?.[path]?.[action];
        const rolePermission = draftPermissions.roles[user.role]?.[path]?.[action] ?? false;
        
        return {
            checked: userOverride !== undefined ? userOverride : rolePermission,
            isOverride: userOverride !== undefined && userOverride !== rolePermission
        };
    };

    const eligibleUsers = useMemo(() => users.filter(u => u.role !== 'Owner' && u.role !== 'Super Admin'), [users]);

    const selectedUser = useMemo(() => users.find(u => u.id === selectedId), [users, selectedId]);

    const handleSelectAll = (action: PermissionAction, checked: boolean) => {
        setDraftPermissions(prev => {
            const newPerms = JSON.parse(JSON.stringify(prev));
            const target = mode === 'roles' ? newPerms.roles[selectedId as Role] : (newPerms.users[selectedId] = newPerms.users[selectedId] || {});
            
            PERMISSION_CONFIG.forEach(section => {
                if (section.availableActions.includes(action)) {
                    if (!target[section.path]) target[section.path] = {};
                    target[section.path][action] = checked;
                }
            });
            return newPerms;
        });
    };

    return (
        <div className="space-y-6">
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow-md p-6">
                <div className="flex items-start gap-4">
                    <div className="flex-shrink-0 text-primary dark:text-accent-sky">
                        <ShieldCheckIcon />
                    </div>
                    <div>
                        <h1 className="text-2xl font-bold text-neutral-dark dark:text-gray-100">Permission Management</h1>
                        <p className="mt-1 text-lg text-neutral-medium dark:text-gray-400">
                            Take full control of your business operations. Here, you can manage what each staff member is allowed to view, edit, create, or delete across your POS system.
                        </p>
                    </div>
                </div>
                <hr className="my-4 border-neutral-light dark:border-gray-700" />
                <p className="text-sm text-neutral-dark dark:text-gray-300">
                    Assign custom permissions to your team members and define their access levels for each section — such as Clients, Receipts, Proforma, Sales, and Reports.
                    Toggle each permission ON or OFF to control what actions a user can perform. You can also create role-based templates like Cashier, Manager, or Sales Staff to apply predefined permissions to new users in just one click.
                    Your changes are drafted here and take effect immediately once saved, ensuring your data stays protected and your operations run smoothly.
                </p>
                <div className="mt-4 text-xs text-neutral-medium dark:text-gray-400 bg-neutral-light/70 dark:bg-gray-700/50 p-2 rounded-md">
                    💡 <strong>Tip:</strong> You can customize permissions per user or apply templates for faster setup. If a user doesn’t have access to a specific feature, it will automatically be hidden or disabled in their account.
                </div>
            </div>

            <div className="grid grid-cols-1 lg:grid-cols-4 gap-6">
                <div className="lg:col-span-1">
                    <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow-md sticky top-6">
                        <div className="border-b border-neutral-light dark:border-gray-700">
                            <nav className="flex -mb-px space-x-4" aria-label="Tabs">
                                <button onClick={() => { setMode('roles'); setSelectedId('Manager'); }} className={`whitespace-nowrap py-3 px-1 border-b-2 font-medium text-sm ${mode === 'roles' ? 'border-primary text-primary' : 'border-transparent text-neutral-medium dark:text-gray-400 hover:text-neutral-dark dark:hover:text-gray-200'}`}>Manage by Role</button>
                                <button onClick={() => { setMode('users'); setSelectedId(eligibleUsers[0]?.id || ''); }} className={`whitespace-nowrap py-3 px-1 border-b-2 font-medium text-sm ${mode === 'users' ? 'border-primary text-primary' : 'border-transparent text-neutral-medium dark:text-gray-400 hover:text-neutral-dark dark:hover:text-gray-200'}`}>Manage by User</button>
                            </nav>
                        </div>
                        <ul className="mt-4 space-y-1 max-h-[60vh] overflow-y-auto">
                            {mode === 'roles' ? (
                                manageableRoles.map(role => (
                                    <li key={role}>
                                        <button onClick={() => setSelectedId(role)} className={`w-full text-left px-3 py-2 rounded-md text-sm font-medium ${selectedId === role ? 'bg-primary/10 text-primary' : 'text-neutral-dark dark:text-gray-200 hover:bg-neutral-light/50 dark:hover:bg-gray-700/50'}`}>
                                            {role}
                                        </button>
                                    </li>
                                ))
                            ) : (
                                eligibleUsers.map(user => (
                                    <li key={user.id}>
                                        <button onClick={() => setSelectedId(user.id)} className={`w-full text-left px-3 py-2 rounded-md ${selectedId === user.id ? 'bg-primary/10 text-primary' : 'hover:bg-neutral-light/50 dark:hover:bg-gray-700/50'}`}>
                                            <div className="flex items-center gap-2">
                                                <img src={user.avatarUrl} alt={user.name} className="w-6 h-6 rounded-full object-cover" />
                                                <div>
                                                    <p className="font-medium text-sm text-neutral-dark dark:text-gray-200">{user.name}</p>
                                                    <p className="text-xs text-neutral-medium dark:text-gray-400">{user.role}</p>
                                                </div>
                                            </div>
                                        </button>
                                    </li>
                                ))
                            )}
                        </ul>
                    </div>
                </div>
                <div className="lg:col-span-3">
                    <Card title={mode === 'roles' ? `Editing Permissions for ${selectedId}` : `Editing Permissions for ${selectedUser?.name || '...'}`}>
                        {mode === 'users' && selectedUser && (
                            <div className="mb-4 p-3 bg-neutral-light/70 dark:bg-gray-700/50 rounded-lg flex items-center gap-4 flex-wrap">
                                <label htmlFor="role-template" className="text-sm font-medium text-neutral-dark dark:text-gray-200">Apply Template:</label>
                                <select id="role-template" onChange={e => handleApplyTemplate(e.target.value as Role)} value={selectedUser.role} className="bg-white dark:bg-gray-800 border-neutral-light dark:border-gray-600 rounded-md shadow-sm p-2 text-sm">
                                    {manageableRoles.map(role => <option key={role} value={role}>{role}</option>)}
                                </select>
                                <p className="text-xs text-neutral-medium dark:text-gray-400 flex-1">Applies a role's permissions to this user. You can then customize them further.</p>
                            </div>
                        )}
                        {/* Desktop Table */}
                        <div className="hidden md:block overflow-x-auto">
                            <table className="w-full text-sm">
                                <thead className="bg-neutral-light dark:bg-gray-700/50">
                                    <tr>
                                        <th className="px-4 py-3 text-left font-semibold text-neutral-dark dark:text-gray-300">Section</th>
                                        {PERMISSION_ACTIONS.map(action => (
                                            <th key={action} className="px-4 py-3 text-center font-semibold text-neutral-dark dark:text-gray-300 capitalize">
                                                {action}
                                                <div className="mt-1"><input type="checkbox" onChange={e => handleSelectAll(action, e.target.checked)} title={`Select all for ${action}`} /></div>
                                            </th>
                                        ))}
                                    </tr>
                                </thead>
                                <tbody>
                                    {PERMISSION_CONFIG.map(section => (
                                        <tr key={section.path} className="border-b dark:border-gray-700">
                                            <td className="px-4 py-3 font-medium text-neutral-dark dark:text-gray-200">
                                                <div className="flex items-center gap-1.5">
                                                    {section.name}
                                                    <div className="relative group text-neutral-medium dark:text-gray-400">
                                                        <InfoIcon />
                                                        <Tooltip text={section.description} />
                                                    </div>
                                                </div>
                                            </td>
                                            {PERMISSION_ACTIONS.map(action => {
                                                const { checked, isOverride } = getPermissionValue(section.path, action);
                                                const isDisabled = !section.availableActions.includes(action);
                                                return (
                                                    <td key={action} className="px-4 py-3 text-center">
                                                        <ToggleSwitch checked={checked} onChange={enabled => handleToggle(section.path, action, enabled)} disabled={isDisabled} isOverride={isOverride} />
                                                    </td>
                                                );
                                            })}
                                        </tr>
                                    ))}
                                </tbody>
                            </table>
                        </div>
                        {/* Mobile Cards */}
                        <div className="md:hidden space-y-4">
                            {PERMISSION_CONFIG.map(section => (
                                <div key={section.path} className="p-4 rounded-lg border bg-white dark:bg-gray-800 dark:border-gray-700 shadow-sm">
                                    <h4 className="font-semibold text-neutral-dark dark:text-gray-200 mb-1">{section.name}</h4>
                                    <p className="text-xs text-neutral-medium dark:text-gray-400 mb-3">{section.description}</p>
                                    <div className="grid grid-cols-2 sm:grid-cols-3 gap-x-4 gap-y-3">
                                        {PERMISSION_ACTIONS.map(action => {
                                            const { checked, isOverride } = getPermissionValue(section.path, action);
                                            const isDisabled = !section.availableActions.includes(action);
                                            return (
                                                <div key={action} className={`flex items-center justify-between p-2 rounded-md ${isDisabled ? 'opacity-40' : ''}`}>
                                                    <label htmlFor={`${section.path}-${action}`} className="text-sm capitalize text-neutral-dark dark:text-gray-300">{action}</label>
                                                    <ToggleSwitch checked={checked} onChange={enabled => handleToggle(section.path, action, enabled)} disabled={isDisabled} isOverride={isOverride} />
                                                </div>
                                            );
                                        })}
                                    </div>
                                </div>
                            ))}
                        </div>
                    </Card>
                </div>
                {hasChanges && (
                    <div className="fixed bottom-16 md:bottom-0 left-0 right-0 p-4 bg-white/95 dark:bg-gray-900/95 backdrop-blur-sm border-t dark:border-gray-700 shadow-[0_-2px_10px_rgba(0,0,0,0.1)] z-20">
                        <div className="max-w-6xl mx-auto flex justify-center md:justify-end gap-4">
                            <button onClick={handleCancelChanges} className="px-6 py-2 rounded-lg font-semibold bg-neutral-light dark:bg-gray-700 text-neutral-dark dark:text-gray-200 hover:bg-gray-300 dark:hover:bg-gray-600">Discard</button>
                            <button onClick={handleSaveChanges} className="px-6 py-2 rounded-lg font-semibold bg-primary text-white hover:bg-blue-700 shadow-sm">Save Changes</button>
                        </div>
                    </div>
                )}
            </div>
        </div>
    );
};

export default Permissions;