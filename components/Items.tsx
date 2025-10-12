import React, { useState, useMemo, useEffect } from 'react';
import type { Product, ReceiptSettingsData, CartItem, ProductVariant } from '../types';
import { formatCurrency } from '../lib/utils';
import { SearchIcon, ChevronDownIcon } from '../constants';
import VariantSelectionModal from './VariantSelectionModal';
import QuantityModal from './QuantityModal';

interface ItemsProps {
    products: Product[];
    cart: CartItem[];
    t: (key: string) => string;
    receiptSettings: ReceiptSettingsData;
    onUpdateCartItem: (product: Product, variant: ProductVariant | undefined, quantity: number) => void;
}

const Items: React.FC<ItemsProps> = ({ products, cart, t, receiptSettings, onUpdateCartItem }) => {
    const [searchTerm, setSearchTerm] = useState('');
    const [toastMessage, setToastMessage] = useState<string | null>(null);
    const [selectedProductForModal, setSelectedProductForModal] = useState<Product | null>(null);

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
    const [collapsedCategories, setCollapsedCategories] = useState<Set<string>>(new Set());

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
    
    const anyProductMatches = useMemo(() => 
        products.some(p => p.name.toLowerCase().includes(searchTerm.toLowerCase())),
    [products, searchTerm]);

    const handleProductClick = (product: Product) => {
        if (product.stock > 0) {
            setSelectedProductForModal(product);
        }
    };
    
    const handleSetSimpleQuantity = (product: Product, quantity: number) => {
        onUpdateCartItem(product, undefined, quantity);
        setToastMessage(`${quantity} x ${product.name} set in cart`);
        setTimeout(() => setToastMessage(null), 2500);
        setSelectedProductForModal(null); // Close modal
    };

    const handleSetVariantQuantity = (product: Product, variant: ProductVariant, quantity: number) => {
        onUpdateCartItem(product, variant, quantity);
        const variantName = variant.attributes.map(a => a.value).join(' / ');
        setToastMessage(`${quantity} x ${product.name} (${variantName}) added to cart`);
        setTimeout(() => setToastMessage(null), 2500);
        setSelectedProductForModal(null); // Close modal
    };

    const isVariableProduct = selectedProductForModal?.productType === 'variable';

    return (
        <div className="space-y-6">
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

            <div className="space-y-8">
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
                                className="w-full flex justify-between items-center p-4 bg-gray-50 hover:bg-gray-100 rounded-lg cursor-pointer transition-colors duration-200"
                                aria-expanded={!isCollapsed}
                            >
                                <h2 className="text-xl font-bold text-gray-700">{category} ({filteredProductsInCategory.length})</h2>
                                <ChevronDownIcon className={`w-6 h-6 text-gray-500 transition-transform duration-300 ${isCollapsed ? '' : 'rotate-180'}`} />
                            </button>

                            {!isCollapsed && (
                                <div className="mt-4 grid grid-cols-3 gap-2 md:gap-4 lg:grid-cols-4 xl:grid-cols-5">
                                    {filteredProductsInCategory.map(product => {
                                        return (
                                            <button
                                                key={product.id}
                                                onClick={() => handleProductClick(product)}
                                                disabled={product.stock === 0}
                                                className="bg-white rounded-xl shadow-md flex flex-col overflow-hidden text-left transition-transform transform hover:scale-105 focus:outline-none focus:ring-2 focus:ring-primary active:scale-100 disabled:opacity-50 disabled:cursor-not-allowed disabled:transform-none"
                                                aria-label={`Add ${product.name} to cart`}
                                            >
                                                <div className="relative">
                                                    <img src={product.imageUrl} alt={product.name} className="w-full aspect-square object-cover" />
                                                </div>
                                                <div className="p-2 flex flex-col flex-grow text-center">
                                                    <h3 className="text-sm font-bold text-neutral-dark leading-tight h-10 flex items-center justify-center">{product.name}</h3>
                                                    <div className="flex-grow"></div>
                                                    <div className="mt-2 w-full">
                                                        <p className="font-semibold text-neutral-dark text-sm">
                                                            {product.productType === 'variable' && product.variants && product.variants.length > 0
                                                                ? `From ${formatCurrency(Math.min(...product.variants.map(v => v.price)), receiptSettings.currencySymbol)}`
                                                                : formatCurrency(product.price, receiptSettings.currencySymbol)}
                                                        </p>
                                                        <p className={`text-xs font-medium mt-1 ${product.stock > 10 ? 'text-success' : product.stock > 0 ? 'text-warning' : 'text-error'}`}>
                                                            {product.stock > 0 ? `${product.stock} in stock` : 'Out of Stock'}
                                                        </p>
                                                    </div>
                                                </div>
                                            </button>
                                        )
                                    })}
                                </div>
                            )}
                        </div>
                    );
                })}
                
                {!anyProductMatches && searchTerm && (
                    <div className="col-span-full text-center py-16">
                        <p className="text-gray-500 text-lg">No products found for "{searchTerm}".</p>
                    </div>
                )}
            </div>
            
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

            {toastMessage && (
                <div className="fixed bottom-20 left-1/2 -translate-x-1/2 bg-neutral-dark text-white px-4 py-2 rounded-lg shadow-lg z-30 animate-pulse">
                    {toastMessage}
                </div>
            )}
        </div>
    );
};

export default Items;