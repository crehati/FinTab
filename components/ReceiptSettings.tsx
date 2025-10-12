import React, { useState, useRef, useEffect } from 'react';
import type { ReceiptSettingsData, Sale, Customer, User, Product } from '../types';
import Card from './Card';

// Create a detailed dummy sale object for a realistic preview
const DUMMY_PREVIEW_PRODUCT_1: Product = { id: 'prev-1', name: 'Artisan Sourdough Loaf', description: 'Naturally leavened bread.', category: 'Bakery', price: 6.50, costPrice: 2.50, stock: 1, imageUrl: '', commissionPercentage: 0 };
const DUMMY_PREVIEW_PRODUCT_2: Product = { id: 'prev-2', name: 'Gourmet Coffee Beans (Extra Long Name To Test Wrapping)', description: 'Single-origin, medium roast.', category: 'Pantry', price: 25.00, costPrice: 15.00, stock: 1, imageUrl: '', commissionPercentage: 0 };
const DUMMY_PREVIEW_CUSTOMER: Customer = { id: 'prev-cust', name: 'Jane Doe (Customer)', email: '', phone: '(555) 123-4567', joinDate: '', purchaseHistory: [] };
const DUMMY_PREVIEW_USER: User = { id: 'prev-user', name: 'John Smith (Cashier)', role: 'Cashier', email: '', avatarUrl: '', type: 'commission' };

// FIX: Changed 'customer' and 'user' properties to 'customerId' and 'userId' to conform to the 'Sale' type.
const DUMMY_SALE_FOR_PREVIEW: Sale = {
    id: 'sale-preview',
    date: new Date().toISOString(),
    items: [
        { product: DUMMY_PREVIEW_PRODUCT_1, quantity: 2 },
        { product: DUMMY_PREVIEW_PRODUCT_2, quantity: 1 }
    ],
    customerId: DUMMY_PREVIEW_CUSTOMER.id,
    userId: DUMMY_PREVIEW_USER.id,
    subtotal: (6.50 * 2) + 25.00,
    tax: ((((6.50 * 2) + 25.00) - 5.00) * 0.08),
    discount: 5.00,
    total: (((6.50 * 2) + 25.00) - 5.00) * 1.08,
    paymentMethod: 'Cash',
    status: 'completed'
};


// Simplified receipt preview component
const ReceiptPreview: React.FC<{ settings: ReceiptSettingsData; isProforma: boolean }> = ({ settings, isProforma }) => {
    const cs = settings.currencySymbol || '$';
    const sale = DUMMY_SALE_FOR_PREVIEW; // Use the detailed dummy sale
    // FIX: Directly use the dummy customer and user objects for preview data, as they are available in this scope.
    const customer = DUMMY_PREVIEW_CUSTOMER;
    const user = DUMMY_PREVIEW_USER;
    const totalItems = sale.items.length;
    const totalUnits = sale.items.reduce((sum, item) => sum + item.quantity, 0);

    return (
        <div className="p-4 border rounded-lg font-sans text-gray-800 bg-white shadow-inner h-full overflow-y-auto max-w-[280px] mx-auto text-[10px]" style={{ fontFamily: 'Arial, sans-serif' }}>
            {/* Header */}
            <div className="text-center mb-2 pt-4">
                {settings.logo ? (
                    <img src={settings.logo} alt="Logo Preview" className="w-16 h-auto mx-auto mb-2 object-contain" />
                ) : (
                    <div className="w-12 h-12 bg-gray-200 mx-auto mb-2 flex items-center justify-center text-gray-400 text-[8px]">Logo</div>
                )}
                <h2 className="text-base font-bold">{settings.businessName}</h2>
                <p className="text-[9px] italic text-gray-600">{settings.slogan}</p>
                <p className="text-[9px] mt-1">{settings.address}</p>
                <p className="text-[9px]">{settings.phone}</p>
                {!isProforma && <p className="text-[8px] mt-1">Sold by: {user.name}</p>}
            </div>

            {/* Title */}
            <div className="text-center px-2 pb-1 border-b border-black">
                {isProforma ? (
                    <h3 className="text-sm font-bold uppercase text-blue-900">Proforma Invoice</h3>
                ) : (
                    <h3 className="text-sm font-bold">{settings.receiptTitle}</h3>
                )}
            </div>

            {/* Client Info */}
            <div className="text-center mt-3">
                <p className="font-bold text-sm">{customer.name}</p>
                <p className="text-[9px]">{customer.phone}</p>
            </div>

            {/* Receipt Details */}
            <div className="text-center text-[9px] mb-2">
                <p>{isProforma ? settings.labels.proformaNumber : settings.labels.receiptNumber} {settings.receiptPrefix}XXXXXX</p>
                <p>{new Date(sale.date).toLocaleString()}</p>
            </div>

            {/* Summary Box */}
            {!isProforma && (
                <div className="my-2 text-[9px] text-center">
                    <div className="grid grid-cols-4 gap-1 p-1 font-bold text-black bg-gray-100 rounded-t-md">
                        <div>{settings.labels.pMode}</div>
                        <div>{settings.labels.itemCount}</div>
                        <div>{settings.labels.unitCount}</div>
                        <div>{settings.labels.amount}</div>
                    </div>
                    <div className="grid grid-cols-4 gap-1 p-1 border border-t-0 border-gray-200 rounded-b-md">
                        <div>{sale.paymentMethod}</div>
                        <div className="tabular-nums">{totalItems}</div>
                        <div className="tabular-nums">{totalUnits}</div>
                        <div className="font-semibold tabular-nums">{cs}{sale.total.toFixed(2)}</div>
                    </div>
                </div>
            )}
            
            <div className="my-2 border-t border-black" />

             {/* Items List */}
             <div className="text-[9px]">
                 <div className="grid grid-cols-12 gap-x-2 p-1 font-bold text-black text-left bg-gray-100 rounded-t-md">
                    <div className="col-span-3">{settings.labels.item}</div>
                    <div className="col-span-3 text-center">{settings.labels.price}</div>
                    <div className="col-span-3 text-center">{settings.labels.quantity}</div>
                    <div className="col-span-3 text-right">{settings.labels.total}</div>
                </div>
                {sale.items.map(item => (
                     <div key={item.product.id} className="grid grid-cols-12 gap-x-2 py-1 border-b border-dashed border-gray-300 items-start last:border-b-0">
                        <div className="col-span-3 break-words">
                            <p className="font-semibold whitespace-normal leading-snug line-clamp-3">{item.product.name}</p>
                            {item.product.description && (
                                <p className="text-gray-500 text-[8px] mt-0.5 whitespace-normal leading-snug">{item.product.description}</p>
                            )}
                        </div>
                        <div className="col-span-3 text-center tabular-nums">{cs}{item.product.price.toFixed(2)}</div>
                        <div className="col-span-3 text-center tabular-nums">{item.quantity}</div>
                        <div className="col-span-3 text-right font-semibold tabular-nums">{cs}{(item.product.price * item.quantity).toFixed(2)}</div>
                    </div>
                ))}
            </div>


            {/* Totals */}
            <div className="mt-2 text-[9px] space-y-0.5">
                <div className="flex justify-between">
                    <span className="font-semibold">{settings.labels.subtotal}</span>
                    <span className="tabular-nums">{cs}{sale.subtotal.toFixed(2)}</span>
                </div>
                {sale.discount > 0 && (
                    <div className="flex justify-between">
                        <span className="font-semibold">{settings.labels.discount}</span>
                        <span className="tabular-nums">-{cs}{sale.discount.toFixed(2)}</span>
                    </div>
                )}
                <div className="flex justify-between font-bold text-sm mt-1 pt-1 border-t border-black">
                    <span>{settings.labels.grandTotal}</span>
                    <span className="tabular-nums">{cs}{sale.total.toFixed(2)}</span>
                </div>
            </div>

            <div className="my-2 border-t border-black" />
            
            <div className="text-center mt-2 text-[9px]">
                <p>{settings.thankYouNote}</p>
            </div>
        </div>
    );
};

interface ReceiptSettingsProps {
    settings: ReceiptSettingsData;
    setSettings: (settings: ReceiptSettingsData) => void;
    t: (key: string) => string;
}

const InputField: React.FC<{
    labelKey: string;
    name: string;
    value: string;
    onChange: (e: React.ChangeEvent<HTMLInputElement>) => void;
    t: (key: string) => string;
    placeholder?: string;
    maxLength?: number;
}> = ({ labelKey, name, value, onChange, t, placeholder, maxLength }) => (
    <div>
        <label htmlFor={name} className="block text-sm font-medium text-gray-700">{t(labelKey as any)}</label>
        <input
            type="text"
            id={name}
            name={name}
            value={value}
            onChange={onChange}
            placeholder={placeholder || ''}
            maxLength={maxLength}
            className="mt-1"
        />
    </div>
);

const ReceiptSettings: React.FC<ReceiptSettingsProps> = ({ settings, setSettings, t }) => {
    const [localSettings, setLocalSettings] = useState<ReceiptSettingsData>(settings);
    const [activePreview, setActivePreview] = useState<'receipt' | 'proforma'>('receipt');
    const fileInputRef = useRef<HTMLInputElement>(null);

    useEffect(() => {
        setLocalSettings(settings);
    }, [settings]);

    const handleInputChange = (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => {
        const { name, value } = e.target;
        if (name.startsWith('social.')) {
            const socialKey = name.split('.')[1] as keyof ReceiptSettingsData['social'];
            setLocalSettings(prev => ({
                ...prev,
                social: { ...prev.social, [socialKey]: value }
            }));
        } else if (name.startsWith('labels.')) {
            const labelKey = name.split('.')[1] as keyof ReceiptSettingsData['labels'];
            setLocalSettings(prev => ({
                ...prev,
                labels: { ...prev.labels, [labelKey]: value }
            }));
        }
        else {
            setLocalSettings(prev => ({ ...prev, [name]: value }));
        }
    };

    const handleLogoUpload = (e: React.ChangeEvent<HTMLInputElement>) => {
        const file = e.target.files?.[0];
        if (file) {
            const reader = new FileReader();
            reader.onloadend = () => {
                setLocalSettings(prev => ({ ...prev, logo: reader.result as string }));
            };
            reader.readAsDataURL(file);
        }
    };

    const handleSave = () => {
        setSettings(localSettings);
        alert('Settings saved!');
    };

    return (
        <div className="grid grid-cols-1 lg:grid-cols-5 gap-6">
            <div className="lg:col-span-3">
                <Card title={t('settings.receipts.editTitle')}>
                    <div className="space-y-6">
                        {/* Logo */}
                        <div>
                            <label className="block text-sm font-medium text-gray-700">{t('settings.receipts.logo')}</label>
                            <div className="mt-1 flex items-center">
                                <span className="inline-block h-16 w-16 rounded-md overflow-hidden bg-gray-100 border flex-shrink-0">
                                    {localSettings.logo ? <img src={localSettings.logo} alt="Logo" className="h-full w-full object-contain" /> : <svg className="h-full w-full text-gray-300" fill="currentColor" viewBox="0 0 24 24"><path d="M24 20.993V24H0v-2.993A1 1 0 001 18h22a1 1 0 001 2.993zM2.5 13.5l3-3 3 3-3 3-3-3zM18 10.5l-3 3 3 3 3-3-3-3zM21.5 6l-3 3 3 3 3-3-3-3zM8.5 6l-3 3 3 3 3-3-3-3z"/></svg>}
                                </span>
                                <input type="file" accept="image/*" ref={fileInputRef} onChange={handleLogoUpload} className="hidden" />
                                <button type="button" onClick={() => fileInputRef.current?.click()} className="ml-5 bg-primary text-white py-2 px-3 border border-transparent rounded-md shadow-sm text-sm leading-4 font-medium hover:bg-blue-700">
                                    {t('settings.receipts.uploadLogo')}
                                </button>
                                {localSettings.logo && <button type="button" onClick={() => setLocalSettings(p => ({...p, logo: null}))} className="ml-2 text-sm text-gray-500 hover:text-red-600">Remove</button>}
                            </div>
                        </div>

                        {/* Business Details */}
                        <div className="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-6">
                            <InputField labelKey="settings.receipts.businessName" name="businessName" value={localSettings.businessName} onChange={handleInputChange} t={t} />
                            <InputField labelKey="settings.receipts.slogan" name="slogan" value={localSettings.slogan} onChange={handleInputChange} t={t} />
                            <InputField labelKey="settings.receipts.address" name="address" value={localSettings.address} onChange={handleInputChange} t={t} />
                            <InputField labelKey="settings.receipts.phone" name="phone" value={localSettings.phone} onChange={handleInputChange} t={t} />
                            <InputField labelKey="settings.receipts.email" name="email" value={localSettings.email} onChange={handleInputChange} t={t} />
                            <InputField labelKey="settings.receipts.website" name="website" value={localSettings.website} onChange={handleInputChange} t={t} />
                            <InputField labelKey="settings.receipts.currencySymbol" name="currencySymbol" value={localSettings.currencySymbol} onChange={handleInputChange} t={t} />
                            <InputField labelKey="settings.receipts.receiptPrefix" name="receiptPrefix" value={localSettings.receiptPrefix} onChange={handleInputChange} t={t} placeholder="e.g., RE" maxLength={2} />
                        </div>

                        {/* Social Media */}
                        <div className="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-6">
                            <InputField labelKey="settings.receipts.twitter" name="social.twitter" value={localSettings.social.twitter} onChange={handleInputChange} t={t} placeholder="@username" />
                            <InputField labelKey="settings.receipts.instagram" name="social.instagram" value={localSettings.social.instagram} onChange={handleInputChange} t={t} placeholder="@username" />
                        </div>

                        {/* Receipt Text */}
                        <InputField labelKey="settings.receipts.receiptTitle" name="receiptTitle" value={localSettings.receiptTitle} onChange={handleInputChange} t={t} />
                        <div>
                            <label htmlFor="thankYouNote" className="block text-sm font-medium text-gray-700">{t('settings.receipts.thankYouNote')}</label>
                            <textarea id="thankYouNote" name="thankYouNote" value={localSettings.thankYouNote} onChange={handleInputChange} rows={2} className="mt-1"></textarea>
                        </div>
                        <div>
                            <label htmlFor="termsAndConditions" className="block text-sm font-medium text-gray-700">{t('settings.receipts.termsAndConditions')}</label>
                            <textarea id="termsAndConditions" name="termsAndConditions" value={localSettings.termsAndConditions} onChange={handleInputChange} rows={3} className="mt-1"></textarea>
                        </div>

                        {/* Customizable Labels */}
                        <div className="pt-6 border-t">
                            <h3 className="text-lg font-medium text-gray-900 mb-4">{t('settings.receipts.customizeLabels')}</h3>
                            <div className="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-6">
                                <InputField labelKey="settings.receipts.labelReceiptNumber" name="labels.receiptNumber" value={localSettings.labels.receiptNumber} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelProformaNumber" name="labels.proformaNumber" value={localSettings.labels.proformaNumber} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelDate" name="labels.date" value={localSettings.labels.date} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelTime" name="labels.time" value={localSettings.labels.time} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelCustomer" name="labels.customer" value={localSettings.labels.customer} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelCashier" name="labels.cashier" value={localSettings.labels.cashier} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelPayment" name="labels.payment" value={localSettings.labels.payment} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelItem" name="labels.item" value={localSettings.labels.item} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelTotal" name="labels.total" value={localSettings.labels.total} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelSubtotal" name="labels.subtotal" value={localSettings.labels.subtotal} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelTax" name="labels.tax" value={localSettings.labels.tax} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelDiscount" name="labels.discount" value={localSettings.labels.discount} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelGrandTotal" name="labels.grandTotal" value={localSettings.labels.grandTotal} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelItemCode" name="labels.itemCode" value={localSettings.labels.itemCode} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelQuantity" name="labels.quantity" value={localSettings.labels.quantity} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelPrice" name="labels.price" value={localSettings.labels.price} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelCashReceived" name="labels.cashReceived" value={localSettings.labels.cashReceived} onChange={handleInputChange} t={t} />
                                <InputField labelKey="settings.receipts.labelChange" name="labels.change" value={localSettings.labels.change} onChange={handleInputChange} t={t} />
                            </div>
                        </div>


                        {/* Save Button */}
                        <div className="text-right pt-4 border-t">
                             <button onClick={handleSave} className="bg-primary text-white px-6 py-2 rounded-lg font-semibold hover:bg-blue-700 transition-colors shadow-sm">
                                {t('settings.receipts.saveButton')}
                            </button>
                        </div>
                    </div>
                </Card>
            </div>
            <div className="lg:col-span-2">
                <div className="lg:sticky top-6">
                    <Card title={t('settings.receipts.previewTitle')}>
                        <div className="mb-4 flex justify-center p-1 bg-gray-200 rounded-lg">
                            <button 
                                onClick={() => setActivePreview('receipt')}
                                className={`w-1/2 py-2 text-sm font-semibold rounded-md transition-colors ${activePreview === 'receipt' ? 'bg-white text-primary shadow' : 'text-gray-600'}`}
                            >
                                Receipt
                            </button>
                            <button 
                                onClick={() => setActivePreview('proforma')}
                                className={`w-1/2 py-2 text-sm font-semibold rounded-md transition-colors ${activePreview === 'proforma' ? 'bg-white text-primary shadow' : 'text-gray-600'}`}
                            >
                                Proforma
                            </button>
                        </div>
                        <div className="h-[75vh] bg-gray-100 p-2 rounded-lg">
                           <ReceiptPreview settings={localSettings} isProforma={activePreview === 'proforma'} />
                        </div>
                    </Card>
                </div>
            </div>
        </div>
    );
};

export default ReceiptSettings;