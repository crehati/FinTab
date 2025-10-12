

import React, { useState, useMemo, useEffect, useRef } from 'react';
import type { Product, ReceiptSettingsData, User, StockAdjustment } from '../types';
import Card from './Card';
import ProductModal from './ProductModal';
import ConfirmationModal from './ConfirmationModal';
import CategoryModal from './CategoryModal';
import StockAdjustmentModal from './StockAdjustmentModal';
import StockHistoryModal from './StockHistoryModal';
import LabelPrintModal from './LabelPrintModal';
import { PlusIcon, MoreVertIcon, BarcodeIcon } from '../constants';
import { formatCurrency } from '../lib/utils';

interface InventoryProps {
    products: Product[];
    setProducts: React.Dispatch<React.SetStateAction<Product[]>>;
    t: (key: string) => string;
    receiptSettings: ReceiptSettingsData;
    onSaveStockAdjustment: (productId: string, adjustment: Omit<StockAdjustment, 'date' | 'userId' | 'newStockLevel'>, userId: string) => void;
    currentUser: User;
    users: User[];
    trialLimits: { canAddProduct: boolean };
}

const SearchIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-5 w-5 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
    </svg>
);

const Inventory: React.FC<InventoryProps> = ({ products, setProducts, t, receiptSettings, onSaveStockAdjustment, currentUser, users, trialLimits }) => {
    const [searchTerm, setSearchTerm] = useState('');
    const [selectedCategory, setSelectedCategory] = useState<string>('all');
    const [isModalOpen, setIsModalOpen] = useState(false);
    const [editingProduct, setEditingProduct] = useState<Product | null>(null);
    const [isConfirmModalOpen, setIsConfirmModalOpen] = useState(false);
    const [productToDelete, setProductToDelete] = useState<string | null>(null);
    const [categories, setCategories] = useState<string[]>([]);
    const [isCategoryModalOpen, setIsCategoryModalOpen] = useState(false);
    const [isAdjustModalOpen, setIsAdjustModalOpen] = useState(false);
    const [adjustingProduct, setAdjustingProduct] = useState<Product | null>(null);
    const [historyProduct, setHistoryProduct] = useState<Product | null>(null);
    const [labelProduct, setLabelProduct] = useState<Product | null>(null);
    const [openActionMenuId, setOpenActionMenuId] = useState<string | null>(null);
    const actionMenuRef = useRef<HTMLDivElement>(null);

    const baseInputStyle = "block w-full px-4 py-2 bg-white border border-gray-200 rounded-lg shadow-sm text-neutral-dark placeholder-neutral-medium focus:outline-none focus:ring-2 focus:ring-offset-1 focus:ring-primary";

    useEffect(() => {
        const uniqueCategories = [...new Set(products.map(p => p.category).filter(Boolean))];
        setCategories(uniqueCategories.sort());
    }, [products]);

    useEffect(() => {
        const handleClickOutside = (event: MouseEvent) => {
            if (actionMenuRef.current && !actionMenuRef.current.contains(event.target as Node)) {
                setOpenActionMenuId(null);
            }
        };
        if (openActionMenuId) {
            document.addEventListener('mousedown', handleClickOutside);
        }
        return () => {
            document.removeEventListener('mousedown', handleClickOutside);
        };
    }, [openActionMenuId]);

    const handleAddCategory = (newCategory: string) => {
        const trimmedCategory = newCategory.trim();
        if (trimmedCategory && !categories.includes(trimmedCategory)) {
            setCategories(prev => [...prev, trimmedCategory].sort());
        }
    };

    const filteredProducts = useMemo(() => {
        return products
            .filter(product => {
                if (selectedCategory === 'all') {
                    return true;
                }
                return product.category === selectedCategory;
            })
            .filter(product => {
                if (!searchTerm.trim()) {
                    return true;
                }
                return product.name.toLowerCase().includes(searchTerm.toLowerCase());
            });
    }, [products, searchTerm, selectedCategory]);

    const handleOpenAddModal = () => {
        setEditingProduct(null);
        setIsModalOpen(true);
    };

    const handleOpenEditModal = (product: Product) => {
        setEditingProduct(product);
        setIsModalOpen(true);
    };

    const handleOpenAdjustModal = (product: Product) => {
        setAdjustingProduct(product);
        setIsAdjustModalOpen(true);
    };

    const handleOpenHistoryModal = (product: Product) => {
        setHistoryProduct(product);
    };

    const handleDeleteProduct = (productId: string) => {
        setProductToDelete(productId);
        setIsConfirmModalOpen(true);
    };

    const handleConfirmDelete = () => {
        if (productToDelete) {
            setProducts(prev => prev.filter(p => p.id !== productToDelete));
            setProductToDelete(null);
        }
    };

    const handleSaveProduct = (productData: Product, isEditing: boolean) => {
        if (isEditing) {
            // Edit existing product
            setProducts(prev => prev.map(p => p.id === productData.id ? { ...p, ...productData } : p));
        } else {
            // Add new product
            if (products.some(p => p.id === productData.id)) {
                alert('Product ID already exists. Please use a unique ID.');
                return;
            }
            const newProduct: Product = {
                ...productData,
                stockHistory: [],
            };
            setProducts(prev => [newProduct, ...prev]);
        }
        // Add category to the list if it's new
        handleAddCategory(productData.category);

        setIsModalOpen(false);
        setEditingProduct(null);
    };
    
    const handleSaveStockAdjustment = (adjustment: { type: 'add' | 'remove'; quantity: number; reason: string }) => {
        if (!adjustingProduct || !currentUser) return;

        onSaveStockAdjustment(adjustingProduct.id, adjustment, currentUser.id);

        setIsAdjustModalOpen(false);
        setAdjustingProduct(null);
    };

    const getStatusBadge = (product: Product) => {
        if (product.stock > 10) {
            return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-green-100 text-success">In Stock</span>;
        }
        if (product.stock > 0) {
            return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-yellow-100 text-warning">Low Stock</span>;
        }
        return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-red-100 text-error">Out of Stock</span>;
    };


    return (
        <>
            <Card title={t('inventory.title')}>
                <div className="flex flex-col sm:flex-row justify-between items-center mb-4 gap-4 flex-wrap">
                    <div className="w-full sm:w-auto flex-grow flex flex-col sm:flex-row gap-4">
                        <div className="relative flex-grow">
                            <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                                <SearchIcon />
                            </div>
                            <input
                                type="text"
                                placeholder="Search products by name..."
                                value={searchTerm}
                                onChange={(e) => setSearchTerm(e.target.value)}
                                className={`${baseInputStyle} pl-10`}
                                aria-label="Search products"
                            />
                        </div>
                        <div className="relative sm:w-64">
                             <select
                                value={selectedCategory}
                                onChange={e => setSelectedCategory(e.target.value)}
                                className={baseInputStyle}
                                aria-label="Filter by category"
                            >
                                <option value="all">All Categories</option>
                                {categories.map(cat => (
                                    <option key={cat} value={cat}>{cat}</option>
                                ))}
                            </select>
                        </div>
                    </div>
                    <div className="w-full sm:w-auto flex gap-2">
                        <button onClick={() => setIsCategoryModalOpen(true)} className="flex-1 sm:flex-none bg-primary text-white px-4 py-2 rounded-lg font-semibold hover:bg-blue-700 text-sm">
                            Manage Categories
                        </button>
                    </div>
                </div>

                <div className="overflow-x-auto">
                     {/* Desktop Table View */}
                    <table className="hidden md:table w-full text-sm text-left text-neutral-medium">
                        <thead className="text-xs text-neutral-medium uppercase bg-neutral-light">
                            <tr>
                                <th scope="col" className="px-6 py-3">Product</th>
                                <th scope="col" className="px-6 py-3">Category</th>
                                <th scope="col" className="px-6 py-3">Price</th>
                                <th scope="col" className="px-6 py-3">Stock</th>
                                <th scope="col" className="px-6 py-3">Status</th>
                                <th scope="col" className="px-6 py-3 text-right">Actions</th>
                            </tr>
                        </thead>
                        <tbody>
                            {filteredProducts.map(product => (
                                <tr key={product.id} className="bg-white border-b border-neutral-light hover:bg-accent-sky/5">
                                    <td className="px-6 py-4 font-medium text-neutral-dark flex items-center">
                                        <img src={product.imageUrl} alt={product.name} className="w-10 h-10 rounded-lg mr-4 object-cover" />
                                        {product.name}
                                    </td>
                                    <td className="px-6 py-4">{product.category}</td>
                                    <td className="px-6 py-4">{formatCurrency(product.price, receiptSettings.currencySymbol)}</td>
                                    <td className="px-6 py-4 font-bold">{product.stock}</td>
                                    <td className="px-6 py-4">{getStatusBadge(product)}</td>
                                    <td className="px-6 py-4 text-right whitespace-nowrap space-x-4">
                                        <button onClick={() => handleOpenHistoryModal(product)} className="font-medium text-accent-teal hover:underline">History</button>
                                        <button onClick={() => handleOpenAdjustModal(product)} className="font-medium text-primary hover:underline">Adjust</button>
                                        <button onClick={() => handleOpenEditModal(product)} className="font-medium text-primary hover:underline">Edit</button>
                                        <button onClick={() => handleDeleteProduct(product.id)} className="font-medium text-error hover:underline">Delete</button>
                                        <button onClick={() => setLabelProduct(product)} title="Print Label" className="text-neutral-medium hover:text-primary inline-flex items-center">
                                            <BarcodeIcon />
                                        </button>
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                    
                    {/* Mobile Card View */}
                    <div className="md:hidden space-y-4">
                        {filteredProducts.map(product => (
                            <div key={product.id} className="bg-white p-3 rounded-xl shadow-md border border-neutral-light/80 flex gap-4 relative">
                                <img src={product.imageUrl} alt={product.name} className="w-24 h-24 rounded-lg object-cover flex-shrink-0" />
                                
                                <div className="flex-grow flex flex-col justify-between py-1">
                                    <div>
                                        <p className="font-bold text-base leading-tight text-neutral-dark line-clamp-2">{product.name}</p>
                                        <p className="text-xs text-neutral-medium mt-1">{product.category}</p>
                                    </div>
                                    <div className="flex justify-between items-end">
                                        <div>
                                            <p className="text-lg font-semibold text-primary">{formatCurrency(product.price, receiptSettings.currencySymbol)}</p>
                                            <div className="flex items-center gap-2 mt-1">
                                                {getStatusBadge(product)}
                                                <p className="text-xs text-neutral-medium">Stock: <span className="font-bold text-neutral-dark">{product.stock}</span></p>
                                            </div>
                                        </div>
                                    </div>
                                </div>
                                <div className="absolute top-2 right-2">
                                    <div className="relative" ref={openActionMenuId === product.id ? actionMenuRef : null}>
                                        <button
                                            onClick={(e) => {
                                                e.stopPropagation();
                                                setOpenActionMenuId(openActionMenuId === product.id ? null : product.id);
                                            }}
                                            className="p-2 rounded-full text-neutral-medium hover:bg-gray-100"
                                            aria-label="More actions"
                                        >
                                            <MoreVertIcon />
                                        </button>
                                        {openActionMenuId === product.id && (
                                            <div className="absolute right-0 mt-2 w-40 bg-white rounded-md shadow-lg border z-10 py-1">
                                                <button onClick={() => { handleOpenHistoryModal(product); setOpenActionMenuId(null); }} className="w-full text-left block px-4 py-2 text-sm text-neutral-dark hover:bg-gray-100">History</button>
                                                <button onClick={() => { handleOpenAdjustModal(product); setOpenActionMenuId(null); }} className="w-full text-left block px-4 py-2 text-sm text-neutral-dark hover:bg-gray-100">Adjust Stock</button>
                                                <button onClick={() => { handleOpenEditModal(product); setOpenActionMenuId(null); }} className="w-full text-left block px-4 py-2 text-sm text-neutral-dark hover:bg-gray-100">Edit Product</button>
                                                <button onClick={() => { setLabelProduct(product); setOpenActionMenuId(null); }} className="w-full text-left block px-4 py-2 text-sm text-neutral-dark hover:bg-gray-100">Print Label</button>
                                                <div className="my-1 border-t"></div>
                                                <button onClick={() => { handleDeleteProduct(product.id); setOpenActionMenuId(null); }} className="w-full text-left block px-4 py-2 text-sm text-error hover:bg-red-50">Delete</button>
                                            </div>
                                        )}
                                    </div>
                                </div>
                            </div>
                        ))}
                    </div>

                </div>

                 {filteredProducts.length === 0 && (
                     <div className="text-center py-16">
                        <p className="text-neutral-medium">No products found. Try adjusting your search or filters.</p>
                    </div>
                )}
            </Card>

            <button
                onClick={handleOpenAddModal}
                disabled={!trialLimits.canAddProduct}
                title={!trialLimits.canAddProduct ? "Product limit reached for trial period" : "Add new product"}
                className="fixed bottom-24 right-6 md:bottom-10 md:right-10 bg-primary text-white rounded-full p-4 shadow-xl hover:bg-blue-700 transition-transform transform hover:scale-110 z-20 disabled:bg-gray-400 disabled:cursor-not-allowed"
                aria-label="Add new product"
            >
                <PlusIcon />
            </button>
            
            <ProductModal 
                isOpen={isModalOpen}
                onClose={() => setIsModalOpen(false)}
                onSave={handleSaveProduct}
                product={editingProduct}
                t={t}
                categories={categories}
                receiptSettings={receiptSettings}
            />

            <ConfirmationModal
                isOpen={isConfirmModalOpen}
                onClose={() => setIsConfirmModalOpen(false)}
                onConfirm={handleConfirmDelete}
                title="Delete Product"
                message="Are you sure you want to delete this product? This action cannot be undone."
            />
            
             <CategoryModal
                isOpen={isCategoryModalOpen}
                onClose={() => setIsCategoryModalOpen(false)}
                categories={categories}
                onAddCategory={handleAddCategory}
            />
            
            <StockAdjustmentModal
                isOpen={isAdjustModalOpen}
                onClose={() => setIsAdjustModalOpen(false)}
                onSave={handleSaveStockAdjustment}
                product={adjustingProduct}
            />
             {historyProduct && (
                <StockHistoryModal
                    isOpen={!!historyProduct}
                    onClose={() => setHistoryProduct(null)}
                    product={historyProduct}
                    users={users}
                />
            )}
            <LabelPrintModal
                isOpen={!!labelProduct}
                onClose={() => setLabelProduct(null)}
                product={labelProduct}
                receiptSettings={receiptSettings}
            />
        </>
    );
};

export default Inventory;