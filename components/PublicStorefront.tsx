import React, { useState, useMemo, useEffect } from 'react';
import { NavLink, useParams } from 'react-router-dom';
import type { Product, CartItem, BusinessProfile, ReceiptSettingsData, Customer, Sale, User, ProductVariant, AdminBusinessData } from '../types';
import { translations } from '../lib/translations';
import { formatCurrency, setStoredItemAndDispatchEvent, getStoredItem } from '../lib/utils';
import { COUNTRIES, ChatBubbleIcon, PhoneIcon, EmailIcon, CartIcon, SearchIcon, ChevronDownIcon } from '../constants';
import VariantSelectionModal from './VariantSelectionModal';
import QuantityModal from './QuantityModal';

const ArrowLeftIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10 19l-7-7m0 0l7-7m-7 7h18" />
    </svg>
);

const getEffectivePrice = (item: CartItem): number => {
    if (item.variant) {
        return item.variant.price;
    }
    const { product, quantity } = item;
    if (!product.tieredPricing || product.tieredPricing.length === 0) {
        return product.price;
    }
    const sortedTiers = [...product.tieredPricing].sort((a, b) => b.quantity - a.quantity);
    const applicableTier = sortedTiers.find(tier => quantity >= tier.quantity);
    return applicableTier ? applicableTier.price : product.price;
};


const PublicStorefront: React.FC = () => {
    const { businessId } = useParams<{ businessId: string }>();
    const [business, setBusiness] = useState<AdminBusinessData | null>(null);
    const [products, setProducts] = useState<Product[]>([]);
    const [receiptSettings, setReceiptSettings] = useState<ReceiptSettingsData | null>(null);
    const [cart, setCart] = useState<CartItem[]>([]);
    const [isOrderModalOpen, setIsOrderModalOpen] = useState(false);
    const [isSuccessModalOpen, setIsSuccessModalOpen] = useState(false);
    const [selectedProductForModal, setSelectedProductForModal] = useState<Product | null>(null);
    const [isLoading, setIsLoading] = useState(true);
    const [toastMessage, setToastMessage] = useState<string | null>(null);
    const [searchTerm, setSearchTerm] = useState('');
    const [collapsedCategories, setCollapsedCategories] = useState<Set<string>>(new Set());

    const t = (key: string) => translations.en[key as keyof typeof translations.en] || key;

    useEffect(() => {
        setIsLoading(true);
        // Load data from central registry and namespaced storage
        const allBusinesses = getStoredItem<AdminBusinessData[]>('marketup_businesses_registry', []);
        const businessData = allBusinesses.find(b => b.id === businessId);
        
        if (businessData) {
            setBusiness(businessData);
            const businessProducts = getStoredItem<Product[]>(`marketup_${businessId}_products`, []);
            setProducts(businessProducts);
            const businessReceiptSettings = getStoredItem<ReceiptSettingsData | null>(`marketup_${businessId}_receipt_settings`, null);
            setReceiptSettings(businessReceiptSettings);
        } else {
            setBusiness(null);
            setProducts([]);
            setReceiptSettings(null);
        }
        setIsLoading(false);
    }, [businessId]);
    
     const handleUpdateCart = (product: Product, variant: ProductVariant | undefined, quantity: number) => {
        setCart(prevCart => {
            const cartItemId = variant ? variant.id : product.id;
            const existingItemIndex = prevCart.findIndex(item => (item.variant ? item.variant.id : item.product.id) === cartItemId);
            
            const stock = variant ? variant.stock : product.stock;
            const newQuantity = Math.min(quantity, stock);

            if (newQuantity <= 0) {
                 if (existingItemIndex > -1) {
                    const newCart = [...prevCart];
                    newCart.splice(existingItemIndex, 1);
                    return newCart;
                }
                return prevCart;
            }

            if (existingItemIndex > -1) {
                const newCart = [...prevCart];
                newCart[existingItemIndex].quantity = newQuantity;
                return newCart;
            } else {
                return [...prevCart, { product, variant, quantity: newQuantity }];
            }
        });
    };
    
    const handleProductClick = (product: Product) => {
        if (product.stock > 0) {
            setSelectedProductForModal(product);
        }
    };
    
    const handleSetSimpleQuantity = (product: Product, quantity: number) => {
        handleUpdateCart(product, undefined, quantity);
        setToastMessage(`${quantity} x ${product.name} added to order`);
        setTimeout(() => setToastMessage(null), 2500);
        setSelectedProductForModal(null);
    };

    const handleSetVariantQuantity = (product: Product, variant: ProductVariant, quantity: number) => {
        handleUpdateCart(product, variant, quantity);
        const variantName = variant.attributes.map(a => a.value).join(' / ');
        setToastMessage(`${quantity} x ${product.name} (${variantName}) added to order`);
        setTimeout(() => setToastMessage(null), 2500);
        setSelectedProductForModal(null);
    };

    const subtotal = useMemo(() => 
        cart.reduce((sum, item) => sum + getEffectivePrice(item) * item.quantity, 0), 
    [cart]);
    
    const totalCartQuantity = useMemo(() => cart.reduce((sum, item) => sum + item.quantity, 0), [cart]);

    const handleScrollToCart = () => {
        document.getElementById('order-summary')?.scrollIntoView({ behavior: 'smooth' });
    };
    
    const isVariableProduct = selectedProductForModal?.productType === 'variable';

    const groupedProducts = useMemo(() => {
        return products.reduce((acc, product) => {
            const category = product.category || 'Uncategorized';
            if (!acc[category]) {
                acc[category] = [];
            }
            acc[category].push(product);
            return acc;
        }, {} as Record<string, Product[]>);
    }, [products]);

    const categoryNames = useMemo(() => Object.keys(groupedProducts).sort(), [groupedProducts]);

    const anyProductMatches = useMemo(() => 
        products.some(p => p.name.toLowerCase().includes(searchTerm.toLowerCase())),
    [products, searchTerm]);

    const toggleCategory = (category: string) => {
        setCollapsedCategories(prev => {
            const newSet = new Set(prev);
            if (newSet.has(category)) {
                newSet.delete(category);
            } else {
                newSet.add(category);
            }
            return newSet;
        });
    };


    if (isLoading) {
         return <div className="flex items-center justify-center min-h-screen bg-gray-100">Loading...</div>;
    }

    if (!business || !receiptSettings) {
        return (
            <div className="flex items-center justify-center min-h-screen bg-gray-100">
                <div className="text-center">
                    <h1 className="text-2xl font-bold text-gray-700">Business Not Found</h1>
                    <p className="text-gray-500 mt-2">The shopfront you are looking for does not exist or is not public.</p>
                     <NavLink to="/directory" className="mt-6 inline-block bg-primary text-white px-6 py-2 rounded-lg font-semibold hover:bg-blue-700">
                        Back to Directory
                    </NavLink>
                </div>
            </div>
        );
    }

    const cs = receiptSettings.currencySymbol;
    const acceptsOrders = business.settings.acceptRemoteOrders;

    return (
        <div className="bg-gray-100 min-h-screen font-sans">
             <header className="bg-gradient-to-r from-blue-700 to-blue-900 text-white shadow-lg">
                <div className="container mx-auto px-4 py-8 md:py-12 relative">
                    <NavLink 
                        to="/directory" 
                        className="absolute top-4 left-4 flex items-center gap-2 text-blue-200 hover:text-white transition-colors z-10"
                        aria-label="Back to Business Directory"
                    >
                        <ArrowLeftIcon />
                        <span className="font-semibold hidden sm:inline">Back to Directory</span>
                    </NavLink>
                    <div className="flex flex-col md:flex-row justify-between items-center gap-6 text-center md:text-left pt-10 sm:pt-4 md:pt-0">
                        <div className="flex items-center gap-4">
                            {business.profile.logo && <img src={business.profile.logo} alt="Logo" className="h-20 w-20 object-contain rounded-lg bg-white/20 p-1 shadow-md" />}
                            <div>
                                <h1 className="text-3xl md:text-5xl font-extrabold tracking-tight">{business.profile.businessName}</h1>
                                <p className="text-lg text-blue-200">{business.profile.businessType}</p>
                            </div>
                        </div>
                        <div className="text-sm text-blue-100 flex flex-col items-center md:items-end gap-2">
                            <span className="flex items-center gap-2">
                                <PhoneIcon className="w-5 h-5" />
                                {business.profile.businessPhone}
                            </span>
                            <span className="flex items-center gap-2">
                                <EmailIcon className="w-5 h-5" />
                                {business.profile.businessEmail}
                            </span>
                        </div>
                    </div>
                </div>
            </header>
            
            <main className="container mx-auto p-4 md:p-6 grid grid-cols-1 lg:grid-cols-3 gap-6">
                <div className="lg:col-span-2 space-y-8">
                    <h2 className="text-2xl font-bold text-gray-700">{t('publicShopfront.title')}</h2>
                    
                    <div className="relative">
                        <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                            <SearchIcon />
                        </div>
                        <input
                            type="text"
                            placeholder="Search products..."
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                            className="w-full pl-10 pr-4 py-3 bg-white border border-gray-200 rounded-lg shadow-sm text-neutral-dark placeholder-neutral-medium focus:outline-none focus:ring-2 focus:ring-offset-1 focus:ring-primary"
                            aria-label="Search products"
                        />
                    </div>

                    {products.length > 0 ? (
                        <>
                            {categoryNames.map(category => {
                                const productsInCategory = groupedProducts[category];
                                const filteredProductsInCategory = productsInCategory.filter(p =>
                                    p.name.toLowerCase().includes(searchTerm.toLowerCase())
                                );

                                if (filteredProductsInCategory.length === 0) {
                                    return null;
                                }

                                const isCollapsed = collapsedCategories.has(category);

                                return (
                                    <div key={category}>
                                        <button
                                            onClick={() => toggleCategory(category)}
                                            className="w-full flex justify-between items-center p-4 bg-gray-200/50 hover:bg-gray-200/80 rounded-lg cursor-pointer transition-colors duration-200"
                                            aria-expanded={!isCollapsed}
                                        >
                                            <h2 className="text-xl font-bold text-gray-700">{category} ({filteredProductsInCategory.length})</h2>
                                            <ChevronDownIcon className={`w-6 h-6 text-gray-500 transition-transform duration-300 ${isCollapsed ? '' : 'rotate-180'}`} />
                                        </button>
                                        {!isCollapsed && (
                                            <div className="mt-4 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
                                                {filteredProductsInCategory.map(product => (
                                                    <button 
                                                        key={product.id} 
                                                        onClick={() => acceptsOrders && handleProductClick(product)}
                                                        disabled={product.stock === 0 || !acceptsOrders}
                                                        className="bg-white rounded-xl shadow-md flex flex-col overflow-hidden text-left transition-transform transform hover:scale-105 focus:outline-none focus:ring-2 focus:ring-primary active:scale-100 disabled:opacity-60 disabled:cursor-not-allowed disabled:transform-none"
                                                    >
                                                        <img src={product.imageUrl} alt={product.name} className="w-full aspect-square object-cover" />
                                                        <div className="p-4 flex flex-col flex-grow">
                                                            <h3 className="text-lg font-bold text-gray-800">{product.name}</h3>
                                                            <p className="text-sm text-gray-500 flex-grow mt-1">{product.description}</p>
                                                            <div className="mt-4 flex items-end justify-between">
                                                                <div className="text-left">
                                                                    <p className="text-lg font-semibold text-primary">
                                                                        {product.productType === 'variable' && product.variants && product.variants.length > 0
                                                                            ? `From ${formatCurrency(Math.min(...product.variants.map(v => v.price)), cs)}`
                                                                            : formatCurrency(product.price, cs)}
                                                                    </p>
                                                                    <p className={`text-xs font-medium mt-1 ${product.stock > 10 ? 'text-success' : product.stock > 0 ? 'text-warning' : 'text-error'}`}>
                                                                        {product.stock > 0 ? `${product.stock} in stock` : 'Out of Stock'}
                                                                    </p>
                                                                </div>
                                                                {acceptsOrders && (
                                                                    <div className="px-4 py-2 rounded-lg font-semibold bg-primary/10 text-primary">
                                                                        {product.stock === 0 ? 'Out of Stock' : (product.productType === 'variable' ? 'Options' : 'Add')}
                                                                    </div>
                                                                )}
                                                            </div>
                                                        </div>
                                                    </button>
                                                ))}
                                            </div>
                                        )}
                                    </div>
                                );
                            })}
                            {!anyProductMatches && searchTerm && (
                                <div className="col-span-full text-center py-16 bg-white rounded-lg">
                                    <p className="text-gray-500 text-lg">No products found for "{searchTerm}".</p>
                                </div>
                            )}
                        </>
                    ) : (
                        <div className="bg-white rounded-xl shadow-md p-12 text-center">
                            <p className="text-gray-500">This business has not listed any products yet. Please check back later.</p>
                        </div>
                    )}
                </div>

                <div className="lg:col-span-1" id="order-summary">
                    <div className="sticky top-6">
                        <div className="bg-white rounded-xl shadow-md p-4">
                             <h3 className="text-xl font-bold text-gray-700 mb-4">{t('publicShopfront.yourOrder')}</h3>
                            {acceptsOrders ? (
                                <>
                                    {cart.length === 0 ? (
                                        <p className="text-sm text-gray-500 text-center py-8">{t('publicShopfront.empty')}</p>
                                    ) : (
                                        <>
                                            <ul className="divide-y divide-gray-200 max-h-80 overflow-y-auto">
                                                {cart.map(item => (
                                                    <li key={item.variant ? item.variant.id : item.product.id} className="py-3 flex items-center">
                                                        <div className="flex-grow">
                                                            <p className="font-semibold text-gray-800">{item.product.name}</p>
                                                            {item.variant && <p className="text-xs text-gray-500">{item.variant.attributes.map(a => a.value).join(' / ')}</p>}
                                                            <p className="text-sm text-gray-500">{formatCurrency(getEffectivePrice(item), cs)}</p>
                                                        </div>
                                                        <div className="flex items-center">
                                                             <input 
                                                                type="number" 
                                                                value={item.quantity}
                                                                onChange={(e) => handleUpdateCart(item.product, item.variant, parseInt(e.target.value))}
                                                                className="w-16 text-center p-1 border rounded-md"
                                                                min="0"
                                                            />
                                                        </div>
                                                    </li>
                                                ))}
                                            </ul>
                                            <div className="mt-4 pt-4 border-t flex justify-between font-bold text-lg">
                                                <span>Subtotal:</span>
                                                <span>{formatCurrency(subtotal, cs)}</span>
                                            </div>
                                            <button onClick={() => setIsOrderModalOpen(true)} className="w-full mt-4 bg-green-500 text-white py-3 rounded-lg font-semibold text-lg hover:bg-green-600 transition-colors">
                                                {t('publicShopfront.placeOrder')}
                                            </button>
                                        </>
                                    )}
                                </>
                            ) : (
                                <div className="text-center py-8">
                                    <p className="text-gray-600 font-semibold">Online ordering is currently unavailable.</p>
                                    <p className="text-sm text-gray-500 mt-2">Please contact the business directly to place an order.</p>
                                </div>
                            )}
                        </div>
                    </div>
                </div>
            </main>
            
            <button
                onClick={() => alert('Chat with business feature coming soon!')}
                className="fixed bottom-24 right-6 md:bottom-10 md:right-10 bg-primary text-white rounded-full p-4 shadow-xl hover:bg-blue-700 transition-transform transform hover:scale-110 z-20"
                aria-label="Chat with business"
                title="Chat with business"
            >
                <ChatBubbleIcon />
            </button>
            
            {totalCartQuantity > 0 && acceptsOrders && (
                <button
                    onClick={handleScrollToCart}
                    className="fixed bottom-24 right-24 md:bottom-10 md:right-28 bg-primary text-white rounded-full p-4 shadow-xl hover:bg-blue-700 transition-transform transform hover:scale-110 z-20 flex items-center justify-center"
                    aria-label={`View your order, ${totalCartQuantity} items`}
                    title="View your order"
                >
                    <CartIcon className="h-8 w-8" />
                    <span className="absolute -top-1 -right-1 flex h-6 w-6">
                        <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-accent-teal opacity-75"></span>
                        <span className="relative inline-flex rounded-full h-6 w-6 bg-accent-teal text-white text-xs font-bold items-center justify-center">{totalCartQuantity}</span>
                    </span>
                </button>
            )}

             {isVariableProduct ? (
                <VariantSelectionModal
                    isOpen={!!selectedProductForModal}
                    onClose={() => setSelectedProductForModal(null)}
                    product={selectedProductForModal}
                    onConfirm={handleSetVariantQuantity}
                    receiptSettings={receiptSettings}
                />
            ) : (
                <QuantityModal
                    isOpen={!!selectedProductForModal}
                    onClose={() => setSelectedProductForModal(null)}
                    product={selectedProductForModal}
                    cart={cart}
                    onConfirm={handleSetSimpleQuantity}
                    receiptSettings={receiptSettings}
                />
            )}


            <OrderFormModal 
                isOpen={isOrderModalOpen}
                onClose={() => setIsOrderModalOpen(false)}
                cart={cart}
                subtotal={subtotal}
                onSuccess={() => {
                    setIsOrderModalOpen(false);
                    setIsSuccessModalOpen(true);
                    setCart([]);
                }}
                t={t}
                businessId={business.id}
            />
            <SuccessModal 
                isOpen={isSuccessModalOpen}
                onClose={() => setIsSuccessModalOpen(false)}
                t={t}
            />
             {toastMessage && (
                <div className="fixed bottom-24 md:bottom-10 left-1/2 -translate-x-1/2 bg-neutral-dark text-white px-4 py-2 rounded-lg shadow-lg z-30 animate-pulse">
                    {toastMessage}
                </div>
            )}
        </div>
    );
};


// --- Modals for PublicStorefront ---

const OrderFormModal: React.FC<{ isOpen: boolean, onClose: () => void, cart: CartItem[], subtotal: number, onSuccess: () => void, t: (key: string) => string, businessId: string }> = ({ isOpen, onClose, cart, subtotal, onSuccess, t, businessId }) => {
    const [customerInfo, setCustomerInfo] = useState({ name: '', email: '', countryCode: '+1', localPhone: '' });

    // FIX: Added missing handleChange function to update customerInfo state.
    const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
        const { name, value } = e.target;
        setCustomerInfo(prev => ({ ...prev, [name]: value }));
    };

    const handleSubmit = (e: React.FormEvent) => {
        e.preventDefault();
        
        const salesKey = `marketup_${businessId}_sales`;
        const customersKey = `marketup_${businessId}_customers`;
        const usersKey = `marketup_${businessId}_users`;

        const allSales = getStoredItem<Sale[]>(salesKey, []);
        const allCustomers = getStoredItem<Customer[]>(customersKey, []);
        const allUsers = getStoredItem<User[]>(usersKey, []);

        const owner = allUsers.find(u => u.role === 'Owner');
        if (!owner) {
            alert("Error: Business owner not found. Cannot place order.");
            return;
        }

        const newCustomer: Customer = {
            id: `cust-${Date.now()}`,
            name: customerInfo.name,
            email: customerInfo.email,
            phone: `${customerInfo.countryCode}${customerInfo.localPhone.replace(/\D/g, '')}`,
            joinDate: new Date().toISOString(),
            purchaseHistory: []
        };
        
        const newSale: Sale = {
            id: `sale-client-${Date.now()}`,
            date: new Date().toISOString(),
            items: cart,
            customerId: newCustomer.id,
            userId: owner.id,
            subtotal,
            tax: 0,
            discount: 0,
            total: subtotal,
            status: 'client_order',
            businessId: businessId
        };

        setStoredItemAndDispatchEvent(customersKey, [newCustomer, ...allCustomers]);
        setStoredItemAndDispatchEvent(salesKey, [newSale, ...allSales]);
        
        onSuccess();
    };

    if (!isOpen) return null;

    return (
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4">
            <div className="bg-white rounded-lg shadow-2xl w-full max-w-md">
                <form onSubmit={handleSubmit}>
                    <header className="p-6 border-b">
                        <h2 className="text-2xl font-bold text-gray-800">{t('publicShopfront.placeOrder')}</h2>
                    </header>
                    <main className="p-6 space-y-4">
                        <div>
                            <label htmlFor="name" className="block text-sm font-medium text-gray-700">{t('publicShopfront.fullName')}</label>
                            <input type="text" name="name" id="name" value={customerInfo.name} onChange={handleChange} required className="mt-1" />
                        </div>
                        <div>
                            <label htmlFor="email" className="block text-sm font-medium text-gray-700">{t('publicShopfront.email')}</label>
                            <input type="email" name="email" id="email" value={customerInfo.email} onChange={handleChange} required className="mt-1" />
                        </div>
                        <div>
                            <label htmlFor="localPhone" className="block text-sm font-medium text-gray-700">{t('publicShopfront.phone')}</label>
                            <div className="mt-1 flex rounded-md shadow-sm input-group">
                                <select name="countryCode" value={customerInfo.countryCode} onChange={handleChange} className="w-40">
                                    {COUNTRIES.map(c => <option key={c.code} value={c.dial_code}>{c.flag} {c.dial_code}</option>)}
                                </select>
                                <input type="tel" name="localPhone" id="localPhone" value={customerInfo.localPhone} onChange={handleChange} required className="flex-1 min-w-0" placeholder="5551234567" />
                            </div>
                        </div>
                    </main>
                    <footer className="p-4 bg-gray-50 flex justify-between items-center">
                        <button type="button" onClick={onClose} className="text-gray-600 font-semibold">Cancel</button>
                        <button type="submit" className="bg-green-500 text-white px-6 py-2 rounded-lg font-semibold hover:bg-green-600">
                            {t('publicShopfront.submitOrder')}
                        </button>
                    </footer>
                </form>
            </div>
        </div>
    );
};

const SuccessModal: React.FC<{ isOpen: boolean, onClose: () => void, t: (key: string) => string }> = ({ isOpen, onClose, t }) => {
    if (!isOpen) return null;
    return (
         <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4">
            <div className="bg-white rounded-lg shadow-2xl w-full max-w-sm text-center p-8">
                 <svg xmlns="http://www.w3.org/2000/svg" className="mx-auto h-16 w-16 text-green-500" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                <h2 className="mt-4 text-2xl font-bold text-gray-800">{t('publicShopfront.orderSuccessTitle')}</h2>
                <p className="mt-2 text-gray-600">{t('publicShopfront.orderSuccessMessage')}</p>
                <button onClick={onClose} className="mt-6 w-full bg-primary text-white py-2 rounded-lg font-semibold hover:bg-blue-700">
                    {t('publicShopfront.close')}
                </button>
            </div>
        </div>
    )
};

export default PublicStorefront;