import React, { useState, useEffect } from 'react';
import type { Role, User, AppPermissions, UserPermissions, PermissionAction } from '../types';
import { PERMISSION_ACTIONS } from '../types';
import { PERMISSION_CONFIG } from '../lib/permissions';

interface UserPermissionModalProps {
    isOpen: boolean;
    onClose: () => void;
    onSave: (userId: string, userPermissions: UserPermissions) => void;
    user: User | null;
    allPermissions: AppPermissions;
}

const manageableRoles: Role[] = ['Manager', 'Cashier', 'SellerAgent', 'Investor'];

const InfoIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
    </svg>
);

const CloseIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
    </svg>
);

const Tooltip: React.FC<{ text: string }> = ({ text }) => (
    <span className="absolute left-1/2 -translate-x-1/2 bottom-full mb-2 w-max max-w-xs p-2 bg-gray-800 text-white text-xs rounded-md shadow-lg opacity-0 group-hover:opacity-100 transition-opacity duration-200 z-10">
        {text}
    </span>
);

const ToggleSwitch: React.FC<{ checked: boolean; onChange: (checked: boolean) => void; disabled?: boolean; isOverride?: boolean; }> = ({ checked, onChange, disabled, isOverride }) => {
    const baseBg = disabled ? 'bg-gray-200' : (checked ? 'bg-primary' : 'bg-gray-300');
    const overrideRing = isOverride ? 'ring-2 ring-offset-1 ring-yellow-400' : '';
    return (
        <label className={`relative inline-flex items-center cursor-pointer ${disabled ? 'cursor-not-allowed' : ''}`}>
            <input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} className="sr-only peer" disabled={disabled} />
            <div className={`w-11 h-6 rounded-full peer peer-focus:outline-none ${overrideRing} ${baseBg} peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:border-gray-300 after:border after:rounded-full after:h-5 after:w-5 after:transition-all`}></div>
        </label>
    );
};

const UserPermissionModal: React.FC<UserPermissionModalProps> = ({ isOpen, onClose, onSave, user, allPermissions }) => {
    const [draftPermissions, setDraftPermissions] = useState<UserPermissions>({});

    useEffect(() => {
        if (user) {
            setDraftPermissions(JSON.parse(JSON.stringify(allPermissions.users[user.id] || {})));
        }
    }, [user, allPermissions, isOpen]);

    if (!isOpen || !user) return null;

    const handleToggle = (path: string, action: PermissionAction, enabled: boolean) => {
        setDraftPermissions(prev => {
            const newPerms = JSON.parse(JSON.stringify(prev));
            if (!newPerms[path]) {
                newPerms[path] = {};
            }
            newPerms[path][action] = enabled;
            return newPerms;
        });
    };
    
    const handleApplyTemplate = (role: Role) => {
        setDraftPermissions(JSON.parse(JSON.stringify(allPermissions.roles[role] || {})));
    };

    const handleSaveChanges = () => {
        onSave(user.id, draftPermissions);
    };

    const getPermissionValue = (path: string, action: PermissionAction): { checked: boolean, isOverride: boolean } => {
        const userOverride = draftPermissions[path]?.[action];
        const rolePermission = allPermissions.roles[user.role]?.[path]?.[action] ?? false;
        
        return {
            checked: userOverride !== undefined ? userOverride : rolePermission,
            isOverride: userOverride !== undefined && userOverride !== rolePermission
        };
    };

    return (
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4" role="dialog" aria-modal="true">
            <div className="bg-white rounded-lg shadow-2xl w-full max-w-4xl max-h-[90vh] flex flex-col">
                <header className="p-4 border-b flex justify-between items-center flex-shrink-0">
                    <div>
                        <h2 className="text-xl font-bold text-gray-800">Permissions for {user.name}</h2>
                        <p className="text-sm text-gray-500">Role: {user.role}</p>
                    </div>
                    <button onClick={onClose} className="p-2 rounded-full text-gray-500 hover:bg-gray-100" aria-label="Close modal">
                        <CloseIcon />
                    </button>
                </header>

                <main className="flex-grow overflow-y-auto p-6 bg-gray-50">
                    <div className="mb-4 p-3 bg-blue-50 border border-blue-200 rounded-lg flex items-center gap-4 flex-wrap">
                        <label htmlFor="role-template" className="text-sm font-medium text-gray-700">Apply Template:</label>
                        <select id="role-template" onChange={e => handleApplyTemplate(e.target.value as Role)} defaultValue="" className="bg-white border-gray-300 rounded-md shadow-sm p-2 text-sm">
                            <option value="" disabled>Select a role template...</option>
                            {manageableRoles.map(role => <option key={role} value={role}>{role}</option>)}
                        </select>
                        <p className="text-xs text-gray-600 flex-1">This will overwrite current custom permissions for this user.</p>
                    </div>
                    
                    {/* Desktop Table */}
                    <div className="hidden md:block overflow-x-auto border rounded-lg bg-white">
                        <table className="w-full text-sm">
                            <thead className="bg-gray-100">
                                <tr>
                                    <th className="px-4 py-3 text-left font-semibold text-gray-600">Section</th>
                                    {PERMISSION_ACTIONS.map(action => (
                                        <th key={action} className="px-4 py-3 text-center font-semibold text-gray-600 capitalize">{action}</th>
                                    ))}
                                </tr>
                            </thead>
                            <tbody className="divide-y">
                                {PERMISSION_CONFIG.map(section => (
                                    <tr key={section.path}>
                                        <td className="px-4 py-3 font-medium text-gray-800">
                                            <div className="flex items-center gap-1.5">
                                                {section.name}
                                                <div className="relative group text-gray-400">
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
                            <div key={section.path} className="p-4 rounded-lg border bg-white shadow-sm">
                                <h4 className="font-semibold text-gray-800 mb-1">{section.name}</h4>
                                <p className="text-xs text-gray-500 mb-3">{section.description}</p>
                                <div className="grid grid-cols-2 sm:grid-cols-3 gap-x-4 gap-y-3">
                                    {PERMISSION_ACTIONS.map(action => {
                                        const { checked, isOverride } = getPermissionValue(section.path, action);
                                        const isDisabled = !section.availableActions.includes(action);
                                        return (
                                            <div key={action} className={`flex items-center justify-between p-2 rounded-md ${isDisabled ? 'opacity-40' : ''}`}>
                                                <label htmlFor={`${section.path}-${action}`} className="text-sm capitalize text-gray-700">{action}</label>
                                                <ToggleSwitch checked={checked} onChange={enabled => handleToggle(section.path, action, enabled)} disabled={isDisabled} isOverride={isOverride} />
                                            </div>
                                        );
                                    })}
                                </div>
                            </div>
                        ))}
                    </div>
                </main>

                <footer className="p-4 bg-white border-t flex justify-end gap-4 flex-shrink-0">
                    <button onClick={onClose} className="px-6 py-2 rounded-lg font-semibold bg-gray-200 text-gray-800 hover:bg-gray-300">Cancel</button>
                    <button onClick={handleSaveChanges} className="px-6 py-2 rounded-lg font-semibold bg-primary text-white hover:bg-blue-700 shadow-sm">Save Permissions</button>
                </footer>
            </div>
        </div>
    );
};

export default UserPermissionModal;
