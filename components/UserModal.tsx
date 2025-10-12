import React, { useState, useEffect } from 'react';
import type { User, Role, ReceiptSettingsData } from '../types';

interface UserModalProps {
    isOpen: boolean;
    onClose: () => void;
    onSave: (userData: Omit<User, 'id' | 'avatarUrl'>, isEditing: boolean) => void;
    userToEdit: User | null;
    receiptSettings: ReceiptSettingsData;
    defaultRole?: Role;
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

const manageableRoles: Role[] = ['Manager', 'Cashier', 'SellerAgent', 'Investor', 'Custom'];

const UserModal: React.FC<UserModalProps> = ({ isOpen, onClose, onSave, userToEdit, receiptSettings, defaultRole }) => {
    const [formData, setFormData] = useState(getInitialFormData());

    const isEditing = !!userToEdit;
    const cs = receiptSettings.currencySymbol;

    useEffect(() => {
        if (isOpen) {
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
                    role: defaultRole || 'Cashier' // Use defaultRole if provided
                }));
            }
        }
    }, [isOpen, userToEdit, defaultRole]);
    
    // Auto-set user type when role is 'Investor'
    useEffect(() => {
        if (formData.role === 'Investor') {
            setFormData(prev => ({ ...prev, type: 'commission' }));
        }
    }, [formData.role]);

    const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
        const { name, value } = e.target;
        setFormData(prev => ({
            ...prev,
            [name]: value,
        }));
    };

    const handleTypeChange = (type: 'commission' | 'hourly') => {
        setFormData(prev => ({ ...prev, type }));
    };

    const handleSubmit = (e: React.FormEvent) => {
        e.preventDefault();
        const dataToSave = {
            ...formData,
            hourlyRate: parseFloat(String(formData.hourlyRate)) || 0,
            initialInvestment: parseFloat(String(formData.initialInvestment)) || 0,
        };
        onSave(dataToSave, isEditing);
    };

    if (!isOpen) return null;

    const isInvestorRole = formData.role === 'Investor';

    return (
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4">
            <div className="bg-white rounded-lg shadow-2xl max-w-lg w-full max-h-[90vh] flex flex-col">
                <header className="p-6 border-b flex-shrink-0">
                    <h2 className="text-2xl font-bold text-gray-800">{isEditing ? 'Edit User' : 'Invite New User'}</h2>
                </header>
                <form onSubmit={handleSubmit}>
                    <main className="p-6 space-y-4 overflow-y-auto">
                        <div>
                            <label htmlFor="name" className="block text-sm font-medium text-gray-700">Full Name</label>
                            <input type="text" name="name" id="name" value={formData.name} onChange={handleChange} required className="mt-1" />
                        </div>
                        <div>
                            <label htmlFor="email" className="block text-sm font-medium text-gray-700">Email Address</label>
                            <input type="email" name="email" id="email" value={formData.email} onChange={handleChange} required disabled={isEditing} className="mt-1 disabled:bg-gray-100" />
                        </div>
                        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                            <div>
                                <label htmlFor="role" className="block text-sm font-medium text-gray-700">Role</label>
                                <select name="role" id="role" value={formData.role} onChange={handleChange} required disabled={!!defaultRole} className="mt-1 bg-white disabled:bg-gray-100">
                                    {manageableRoles.map(role => (
                                        <option key={role} value={role}>{role}</option>
                                    ))}
                                </select>
                            </div>
                            {formData.role === 'Custom' && (
                                <div>
                                    <label htmlFor="customRoleName" className="block text-sm font-medium text-gray-700">Custom Role Name</label>
                                    <input type="text" name="customRoleName" id="customRoleName" value={formData.customRoleName} onChange={handleChange} required className="mt-1" placeholder="e.g., Graphic Designer" />
                                </div>
                            )}
                        </div>

                        {!isInvestorRole && (
                            <div>
                                <label className="block text-sm font-medium text-gray-700">Pay Type</label>
                                <div className="mt-2 grid grid-cols-2 gap-3">
                                    <label className={`flex items-center justify-center p-3 rounded-md border cursor-pointer transition-colors duration-200 ${formData.type === 'commission' ? 'bg-primary-50 border-primary text-primary' : 'bg-white border-gray-300 hover:bg-gray-50'}`}>
                                        <input type="radio" name="type" checked={formData.type === 'commission'} onChange={() => handleTypeChange('commission')} className="sr-only" />
                                        <span className="font-semibold">Commission</span>
                                    </label>
                                    <label className={`flex items-center justify-center p-3 rounded-md border cursor-pointer transition-colors duration-200 ${formData.type === 'hourly' ? 'bg-primary-50 border-primary text-primary' : 'bg-white border-gray-300 hover:bg-gray-50'}`}>
                                        <input type="radio" name="type" checked={formData.type === 'hourly'} onChange={() => handleTypeChange('hourly')} className="sr-only" />
                                        <span className="font-semibold">Hourly</span>
                                    </label>
                                </div>
                            </div>
                        )}

                        {formData.type === 'hourly' && !isInvestorRole && (
                            <div>
                                <label htmlFor="hourlyRate" className="block text-sm font-medium text-gray-700">Hourly Rate ({cs})</label>
                                <input type="number" name="hourlyRate" id="hourlyRate" value={formData.hourlyRate} onChange={handleChange} required min="0" step="0.01" className="mt-1" />
                            </div>
                        )}
                        
                        {isInvestorRole && (
                            <div>
                                <label htmlFor="initialInvestment" className="block text-sm font-medium text-gray-700">Initial Investment ({cs})</label>
                                <input type="number" name="initialInvestment" id="initialInvestment" value={formData.initialInvestment} onChange={handleChange} required min="0" step="1" className="mt-1" />
                            </div>
                        )}
                    </main>
                    <footer className="p-4 bg-gray-50 rounded-b-lg flex sm:justify-center flex-shrink-0">
                        <div className="responsive-btn-group sm:flex-row-reverse">
                            <button type="submit" className="bg-primary text-white hover:bg-blue-700">
                                {isEditing ? 'Save Changes' : 'Send Invitation'}
                            </button>
                            <button type="button" onClick={onClose} className="bg-gray-200 text-gray-800 hover:bg-gray-300">
                                Cancel
                            </button>
                        </div>
                    </footer>
                </form>
            </div>
        </div>
    );
};

export default UserModal;