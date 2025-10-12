import React, { useState, useMemo } from 'react';
import type { Product, CartItem, Sale, Customer, User, ReceiptSettingsData, BusinessSettingsData, PrinterSettingsData, ProductVariant } from '../types';
import Card from './Card';
import ReceiptModal from './ReceiptModal';
import CustomerModal from './CustomerModal';
import CustomerSelectionModal from './CustomerSelectionModal';
import UserSelectionModal from './UserSelectionModal';
import PaymentConfirmationModal from './PaymentConfirmationModal';
import ConfirmationModal from './ConfirmationModal';
import { formatCurrency } from '../lib/utils';

interface CounterProps {
    cart: CartItem[];
    customers: Customer[];
    users: User[];
    onUpdateCartItem: (product: Product, variant: ProductVariant | undefined, quantity: number) => void;
    onProcessSale: (sale: Sale) => void;
    onDeleteSale: (saleId: string) => void;
    onClearCart: () => void;
    receiptSettings: ReceiptSettingsData;
    t: (key: string) => string;
    onAddCustomer: (customerData: Omit<Customer, 'id' | 'joinDate' | 'purchaseHistory'>) => Customer;
    currentUser: User;
    businessSettings: BusinessSettingsData;
    printerSettings: PrinterSettingsData;
    isTrialExpired: boolean;
}


const getEffectivePrice = (product: Product, quantity: number): number => {
    if (!product.tieredPricing || product.tieredPricing.length === 0) {
        return product.price;
    }
    const sortedTiers = [...product.tieredPricing].sort((a, b) => b.quantity - a.quantity);
    const applicableTier = sortedTiers.find(tier => quantity >= tier.quantity);
    return applicableTier ? applicableTier.price : product.price;
};

const Counter: React.FC<CounterProps> = ({ cart, customers, users, onUpdateCartItem, onProcessSale, onDeleteSale, onClearCart, receiptSettings, t, onAddCustomer, currentUser, businessSettings, printerSettings, isTrialExpired }) => {
    const [completedSale, setCompletedSale] = useState<Sale | null>(null);
    const [proformaInvoice, setProformaInvoice] = useState<Sale | null>(null);
    const [isConfirmModalOpen, setIsConfirmModalOpen] = useState(false);
    const [isClearConfirmOpen, setIsClearConfirmOpen] = useState(false);
    const [selectedCustomerId, setSelectedCustomerId] = useState<string | null>(null);
    const [selectedUserId, setSelectedUserId] = useState<string | null>(null);
    const [discount, setDiscount] = useState<string | number>(0);
    const [paymentMethod, setPaymentMethod] = useState<string | null>(null);
    const [validationError, setValidationError] = useState('');
    
    const [isCustomerSelectModalOpen, setIsCustomerSelectModalOpen] = useState(false);
    const [isUserSelectModalOpen, setIsUserSelectModalOpen] = useState(false);
    const [isAddCustomerModalOpen, setIsAddCustomerModalOpen] = useState(false);

    const [taxRate, setTaxRate] = useState<string | number>(businessSettings.defaultTaxRate); // Editable tax rate
    const cs = receiptSettings.currencySymbol;

    const subtotal = useMemo(() => 
        cart.reduce((sum, item) => {
            const price = item.variant ? item.variant.price : getEffectivePrice(item.product, item.quantity);
            return sum + price * item.quantity;
        }, 0), 
    [cart]);

    const numericDiscount = Number(discount) || 0;
    const numericTaxRate = Number(taxRate) || 0;

    const subtotalAfterDiscount = useMemo(() => subtotal - numericDiscount, [subtotal, numericDiscount]);
    const tax = useMemo(() => subtotalAfterDiscount > 0 ? subtotalAfterDiscount * (numericTaxRate / 100) : 0, [subtotalAfterDiscount, numericTaxRate]);
    const total = useMemo(() => subtotalAfterDiscount + tax, [subtotalAfterDiscount, tax]);

    const selectedCustomer = useMemo(() => customers.find(c => c.id === selectedCustomerId), [customers, selectedCustomerId]);
    const selectedUser = useMemo(() => users.find(u => u.id === selectedUserId), [users, selectedUserId]);


    const handleCheckout = () => {
        if (cart.length === 0) {
            setValidationError("Please add items to the order.");
            return;
        }
        if (!selectedCustomerId || !selectedUserId || !paymentMethod) {
            setValidationError("Please select a client, seller, and payment method.");
            return;
        }
        setValidationError('');
        setIsConfirmModalOpen(true);
    };

    const handleConfirmSale = (paymentDetails: { cashReceived?: number; change?: number }) => {
        const discountPercentage = subtotal > 0 ? (numericDiscount / subtotal) * 100 : 0;
        
        const totalCommission = cart.reduce((commissionSum, item) => {
            const price = item.variant ? item.variant.price : getEffectivePrice(item.product, item.quantity);
            const itemSubtotal = price * item.quantity;
            const proportionalDiscount = subtotal > 0 ? (itemSubtotal / subtotal) * numericDiscount : 0;
            const commissionableValue = itemSubtotal - proportionalDiscount;
            const itemCommission = commissionableValue * (item.product.commissionPercentage / 100);
            return commissionSum + itemCommission;
        }, 0);

        const sale: Sale = {
            id: `sale-${Date.now()}`,
            date: new Date().toISOString(),
            items: cart,
            customerId: selectedCustomerId!,
            userId: selectedUserId!,
            subtotal,
            tax,
            discount: numericDiscount,
            total,
            paymentMethod: paymentMethod!,
            taxRate: numericTaxRate,
            discountPercentage,
            status: paymentMethod === 'Bank Transfer' ? 'pending_approval' : 'completed',
            commission: totalCommission,
            ...paymentDetails
        };
        onProcessSale(sale);
        setIsConfirmModalOpen(false);
        setCompletedSale(sale);
    };
    
    const handleGenerateProforma = () => {
        if (cart.length === 0 || !selectedCustomerId) {
            setValidationError("Please add items to the order and select a customer.");
            return;
        }
        
        // Proforma can be generated without a seller or payment method
        const selectedSellerOrDefault = selectedUserId ? users.find(s => s.id === selectedUserId)! : users[0];

        setValidationError('');

        const discountPercentage = subtotal > 0 ? (numericDiscount / subtotal) * 100 : 0;

        const proforma: Sale = {
            id: `prof-${Date.now()}`,
            date: new Date().toISOString(),
            items: cart,
            customerId: selectedCustomerId!,
            userId: selectedSellerOrDefault.id,
            subtotal,
            tax,
            discount: numericDiscount,
            total,
            taxRate: numericTaxRate,
            discountPercentage,
            status: 'proforma',
        };
        onProcessSale(proforma);
        setProformaInvoice(proforma);
    };

    const handleSaveAndSelectCustomer = (customerData: Omit<Customer, 'id' | 'joinDate' | 'purchaseHistory'>) => {
        const newCustomer = onAddCustomer(customerData);
        setSelectedCustomerId(newCustomer.id);
        setIsAddCustomerModalOpen(false);
    };

    const handleSelectCustomer = (customerId: string) => {
        setSelectedCustomerId(customerId);
        setIsCustomerSelectModalOpen(false);
        setValidationError('');
    };
    
    const handleSelectUser = (userId: string) => {
        setSelectedUserId(userId);
        setIsUserSelectModalOpen(false);
        setValidationError('');
    };


    return (
        <div className="max-w-4xl mx-auto">
            <Card title={t('counter.title')} className="flex flex-col">
                <div className="flex-grow overflow-y-auto -mx-4 px-4">
                    {cart.length === 0 ? (
                        <div className="text-center py-20">
                            <svg xmlns="http://www.w3.org/2000/svg" className="mx-auto h-16 w-16 text-gray-300" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M3 3h2l.4 2M7 13h10l4-8H5.4M7 13L5.4 5M7 13l-2.293 2.293c-.63.63-.184 1.707.707 1.707H17m0 0a2 2 0 100 4 2 2 0 000-4zm-8 2a2 2 0 11-4 0 2 2 0 014 0z" />
                            </svg>
                            <p className="text-gray-500 mt-4">Your order is empty.</p>
                            <p className="text-sm text-gray-400">Add products from the 'Items' page.</p>
                        </div>
                    ) : (
                        <ul className="divide-y divide-gray-200">
                            {cart.map(item => {
                                const price = item.variant ? item.variant.price : getEffectivePrice(item.product, item.quantity);
                                const basePrice = item.product.price;
                                return (
                                <li key={item.variant ? item.variant.id : item.product.id} className="py-4 flex items-center">
                                    <img src={item.product.imageUrl} alt={item.product.name} className="w-16 h-16 rounded-md object-cover" />
                                    <div className="ml-4 flex-grow">
                                        <p className="font-semibold text-gray-800">{item.product.name}</p>
                                        {item.variant && (
                                            <p className="text-sm text-gray-500">
                                                {item.variant.attributes.map(attr => attr.value).join(' / ')}
                                            </p>
                                        )}
                                        <p className="text-sm text-gray-600">
                                            {price < basePrice ? (
                                                <>
                                                    <span className="line-through mr-1">{formatCurrency(basePrice, cs)}</span>
                                                    <span className="text-green-600 font-bold">{formatCurrency(price, cs)}</span>
                                                </>
                                            ) : (
                                                formatCurrency(price, cs)
                                            )}
                                        </p>
                                    </div>
                                    <div className="flex items-center space-x-2">
                                        <button onClick={() => onUpdateCartItem(item.product, item.variant, item.quantity - 1)} className="w-8 h-8 rounded-full border text-lg font-bold text-primary hover:bg-gray-100 transition-colors">-</button>
                                        <span className="w-10 text-center font-bold text-gray-800">{item.quantity}</span>
                                        <button onClick={() => onUpdateCartItem(item.product, item.variant, item.quantity + 1)} className="w-8 h-8 rounded-full border text-lg font-bold text-primary hover:bg-gray-100 transition-colors">+</button>
                                    </div>
                                </li>
                            )})}
                        </ul>
                    )}
                </div>
                {cart.length > 0 && (
                    <div className="mt-6 border-t pt-4">
                         <div className="space-y-2 text-sm text-gray-600">
                            <div className="flex justify-between"><span>Subtotal:</span> <span>{formatCurrency(subtotal, cs)}</span></div>
                            <div className="flex justify-between items-center">
                                <span>Discount:</span>
                                <input 
                                    type="number"
                                    value={discount}
                                    onChange={(e) => setDiscount(e.target.value)}
                                    onBlur={(e) => setDiscount(parseFloat(e.target.value) || 0)}
                                    className="w-24 text-right bg-white border border-gray-300 rounded-lg shadow-sm px-2 py-1 text-gray-800 placeholder-gray-400"
                                    placeholder={`${cs}0.00`}
                                    aria-label="Discount amount"
                                />
                            </div>
                            {numericDiscount > 0 && (
                                <div className="flex justify-between font-medium pt-1 mt-1 border-t border-dashed">
                                    <span>Subtotal After Discount:</span>
                                    <span>{formatCurrency(subtotalAfterDiscount, cs)}</span>
                                </div>
                            )}
                            <div className="flex justify-between items-center">
                                <span>Tax ({formatCurrency(tax, cs)}):</span>
                                <div className="flex items-center">
                                    <input
                                        type="number"
                                        value={taxRate}
                                        onChange={(e) => setTaxRate(e.target.value)}
                                        onBlur={(e) => setTaxRate(parseFloat(e.target.value) || 0)}
                                        className="w-20 text-right bg-white border border-gray-300 rounded-lg shadow-sm px-2 py-1 text-gray-800 placeholder-gray-400"
                                        placeholder="0"
                                        aria-label="Tax rate percentage"
                                        step="0.01"
                                        min="0"
                                    />
                                    <span className="ml-1 text-gray-500">%</span>
                                </div>
                            </div>
                            <div className="flex justify-between font-bold text-xl text-gray-800 pt-2 border-t mt-2"><span>Total:</span> <span>{formatCurrency(total, cs)}</span></div>
                        </div>
                        <div className="mt-6 space-y-4">
                            <div>
                                <label className="block text-sm font-medium text-gray-700 mb-1">Client:</label>
                                <button
                                    type="button"
                                    onClick={() => { setIsCustomerSelectModalOpen(true); setValidationError(''); }}
                                    className={`w-full p-3 border rounded-lg bg-white text-gray-800 text-left shadow-sm transition-colors duration-200 hover:bg-gray-50 ${validationError && !selectedCustomerId ? 'border-red-500' : 'border-gray-300'}`}
                                >
                                    {selectedCustomer ? selectedCustomer.name : <span className="text-gray-500">Select a client</span>}
                                </button>
                            </div>
                            <div>
                                <label className="block text-sm font-medium text-gray-700 mb-1">Sell by:</label>
                                 <button
                                    type="button"
                                    onClick={() => { setIsUserSelectModalOpen(true); setValidationError(''); }}
                                    className={`w-full p-3 border rounded-lg bg-white text-gray-800 text-left shadow-sm transition-colors duration-200 hover:bg-gray-50 ${validationError && !selectedUserId ? 'border-red-500' : 'border-gray-300'}`}
                                >
                                    {selectedUser ? selectedUser.name : <span className="text-gray-500">Select seller</span>}
                                </button>
                            </div>
                            <div>
                                <label htmlFor="payment-method" className="block text-sm font-medium text-gray-700 mb-1">Payment method:</label>
                                <select
                                    id="payment-method"
                                    value={paymentMethod || ''}
                                    onChange={e => { setPaymentMethod(e.target.value); setValidationError(''); }}
                                    required
                                    className={`w-full p-3 pr-10 bg-white border rounded-lg shadow-sm text-gray-800 transition-colors duration-200 ${validationError && !paymentMethod ? 'border-red-500' : 'border-gray-300'}`}
                                >
                                    <option value="" disabled>Select a payment method</option>
                                    {businessSettings.paymentMethods.map(method => (
                                        <option key={method} value={method}>{method}</option>
                                    ))}
                                </select>
                            </div>
                        </div>
                        <div className="mt-6 space-y-4">
                            {validationError && <div className="p-3 bg-red-50 text-red-700 rounded-lg text-center text-sm">{validationError}</div>}
                            <div className="responsive-btn-group">
                                <button onClick={handleCheckout} className="bg-primary text-white hover:bg-blue-700 transition-colors">
                                    Process Sale
                                </button>
                                <button onClick={handleGenerateProforma} className="bg-neutral-dark text-white hover:bg-gray-700 transition-colors">
                                    Generate Proforma
                                </button>
                            </div>
                            <div className="pt-2">
                                <button
                                    type="button"
                                    onClick={() => setIsClearConfirmOpen(true)}
                                    className="btn-responsive bg-red-100 text-red-700 hover:bg-red-200 disabled:bg-gray-200 disabled:text-gray-400 disabled:cursor-not-allowed font-semibold"
                                    disabled={cart.length === 0}
                                >
                                    Clear Order
                                </button>
                            </div>
                        </div>
                    </div>
                )}
                <PaymentConfirmationModal
                    isOpen={isConfirmModalOpen}
                    onClose={() => setIsConfirmModalOpen(false)}
                    onConfirm={handleConfirmSale}
                    total={total}
                    paymentMethod={paymentMethod}
                    receiptSettings={receiptSettings}
                />
                {completedSale && <ReceiptModal sale={completedSale} customers={customers} users={users} onClose={() => setCompletedSale(null)} receiptSettings={receiptSettings} onDelete={onDeleteSale} currentUser={currentUser} t={t} isTrialExpired={isTrialExpired} printerSettings={printerSettings} />}
                {proformaInvoice && <ReceiptModal sale={proformaInvoice} customers={customers} users={users} onClose={() => setProformaInvoice(null)} receiptSettings={receiptSettings} onDelete={onDeleteSale} currentUser={currentUser} t={t} isTrialExpired={isTrialExpired} printerSettings={printerSettings} />}
                
                <CustomerSelectionModal
                    isOpen={isCustomerSelectModalOpen}
                    onClose={() => setIsCustomerSelectModalOpen(false)}
                    customers={customers}
                    onSelect={handleSelectCustomer}
                    onAddNew={() => {
                        setIsCustomerSelectModalOpen(false);
                        setIsAddCustomerModalOpen(true);
                    }}
                />
                 <CustomerModal
                    isOpen={isAddCustomerModalOpen}
                    onClose={() => setIsAddCustomerModalOpen(false)}
                    onSave={handleSaveAndSelectCustomer}
                    customerToEdit={null}
                />
                <UserSelectionModal
                    isOpen={isUserSelectModalOpen}
                    onClose={() => setIsUserSelectModalOpen(false)}
                    users={users}
                    onSelect={handleSelectUser}
                />
                 <ConfirmationModal
                    isOpen={isClearConfirmOpen}
                    onClose={() => setIsClearConfirmOpen(false)}
                    onConfirm={() => {
                        onClearCart();
                        setIsClearConfirmOpen(false);
                    }}
                    title="Clear Order"
                    message="Are you sure you want to clear the entire order? All items will be removed from the cart."
                />
            </Card>
        </div>
    );
};

export default Counter;