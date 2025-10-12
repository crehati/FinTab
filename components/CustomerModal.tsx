import React, { useState, useEffect } from 'react';
import type { Customer } from '../types';
import { COUNTRIES } from '../constants';

interface CustomerModalProps {
    isOpen: boolean;
    onClose: () => void;
    onSave: (customerData: Omit<Customer, 'id' | 'joinDate' | 'purchaseHistory'>) => void;
    customerToEdit: Customer | null;
}

interface FormData {
    name: string;
    email: string;
    countryCode: string;
    localPhone: string;
}

const getInitialFormData = (): FormData => ({
    name: '',
    email: '',
    countryCode: '+1',
    localPhone: '',
});

const CustomerModal: React.FC<CustomerModalProps> = ({ isOpen, onClose, onSave, customerToEdit }) => {
    const [formData, setFormData] = useState<FormData>(getInitialFormData());

    useEffect(() => {
        if (isOpen) {
            if (customerToEdit) {
                // Try to parse existing number
                const phone = customerToEdit.phone;
                const country = COUNTRIES.find(c => phone.startsWith(c.dial_code));
                if (country) {
                    setFormData({
                        name: customerToEdit.name,
                        email: customerToEdit.email,
                        countryCode: country.dial_code,
                        localPhone: phone.substring(country.dial_code.length),
                    });
                } else {
                     setFormData({
                        name: customerToEdit.name,
                        email: customerToEdit.email,
                        countryCode: '+1', // default
                        localPhone: phone.replace(/\D/g, ''), // strip non-digits
                    });
                }
            } else {
                setFormData(getInitialFormData());
            }
        }
    }, [isOpen, customerToEdit]);

    const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
        const { name, value } = e.target;
        setFormData(prev => ({
            ...prev,
            [name]: value,
        }));
    };

    const handleSubmit = (e: React.FormEvent) => {
        e.preventDefault();
        const fullPhoneNumber = `${formData.countryCode}${formData.localPhone.replace(/\D/g, '')}`;
        const customerData: Omit<Customer, 'id' | 'joinDate' | 'purchaseHistory'> = {
            name: formData.name,
            email: formData.email,
            phone: fullPhoneNumber,
        };
        onSave(customerData);
    };

    if (!isOpen) return null;

    return (
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50">
            <div className="bg-white rounded-lg shadow-2xl max-w-lg w-full">
                <div className="p-6 border-b">
                    <h2 className="text-2xl font-bold text-gray-800">{customerToEdit ? 'Edit Customer' : 'Add New Customer'}</h2>
                </div>
                <form onSubmit={handleSubmit}>
                    <div className="p-6 space-y-4">
                        <div>
                            <label htmlFor="name" className="block text-sm font-medium text-gray-700">Customer Name</label>
                            <input type="text" name="name" id="name" value={formData.name} onChange={handleChange} required className="mt-1" />
                        </div>
                        <div>
                            <label htmlFor="email" className="block text-sm font-medium text-gray-700">Email Address</label>
                            <input type="email" name="email" id="email" value={formData.email} onChange={handleChange} required className="mt-1" />
                        </div>
                        <div>
                            <label htmlFor="phone" className="block text-sm font-medium text-gray-700">Phone Number</label>
                             <div className="mt-1 flex rounded-md shadow-sm input-group">
                                <select
                                    name="countryCode"
                                    value={formData.countryCode}
                                    onChange={handleChange}
                                    className="block w-40"
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
                                    id="phone"
                                    value={formData.localPhone}
                                    onChange={handleChange}
                                    required
                                    className="flex-1 min-w-0"
                                    placeholder="5551234567"
                                />
                            </div>
                            <p className="mt-1 text-xs text-gray-500">Select country code and enter local number for WhatsApp messaging.</p>
                        </div>
                    </div>
                    <div className="p-4 bg-gray-50 rounded-b-lg flex sm:justify-center">
                        <div className="responsive-btn-group sm:flex-row-reverse">
                            <button type="submit" className="bg-primary text-white hover:bg-blue-700">
                                {customerToEdit ? 'Save Changes' : 'Save Customer'}
                            </button>
                            <button type="button" onClick={onClose} className="bg-gray-200 text-gray-800 hover:bg-gray-300">
                                Cancel
                            </button>
                        </div>
                    </div>
                </form>
            </div>
        </div>
    );
};

export default CustomerModal;