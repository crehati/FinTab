import React, { useState, useEffect, useRef, useMemo } from 'react';
import type { Product, ReceiptSettingsData, ProductVariant } from '../types';
import { formatCurrency } from '../lib/utils';

interface ProductModalProps {
    isOpen: boolean;
    onClose: () => void;
    onSave: (productData: Product, isEditing: boolean) => void;
    product: Product | null;
    t: (key: string) => string;
    categories: string[];
    receiptSettings: ReceiptSettingsData;
}

const getInitialFormData = (): Product => ({
    id: '',
    name: '',
    description: '',
    category: '',
    price: 0,
    costPrice: 0,
    stock: 0,
    imageUrl: '',
    commissionPercentage: 0,
    tieredPricing: [],
    stockHistory: [],
    productType: 'simple',
    variantOptions: [{ name: '', values: [] }],
    variants: [],
});

const ADD_NEW_CATEGORY_VALUE = '__ADD_NEW__';

const ProductModal: React.FC<ProductModalProps> = ({ isOpen, onClose, onSave, product, categories, receiptSettings }) => {
    const [formData, setFormData] = useState<Product>(getInitialFormData());
    const [imagePreview, setImagePreview] = useState<string | null>(null);
    const fileInputRef = useRef<HTMLInputElement>(null);
    const [isAddingNewCategory, setIsAddingNewCategory] = useState(false);
    const [newCategoryValue, setNewCategoryValue] = useState('');

    const cs = receiptSettings.currencySymbol;

    const liveProfit = useMemo(() => {
        return (formData.price || 0) - (formData.costPrice || 0);
    }, [formData.price, formData.costPrice]);

    useEffect(() => {
        if (isOpen) {
            if (product) {
                const productCategoryExists = categories.includes(product.category);
                setFormData({
                    ...getInitialFormData(),
                    ...product,
                    productType: product.productType || 'simple',
                    variantOptions: product.variantOptions && product.variantOptions.length > 0 ? product.variantOptions : [{ name: '', values: [] }],
                    variants: product.variants || [],
                    tieredPricing: product.tieredPricing || [],
                    stockHistory: product.stockHistory || [],
                });
                setImagePreview(product.imageUrl);
                if (!productCategoryExists && product.category) {
                    setIsAddingNewCategory(true);
                    setNewCategoryValue(product.category);
                } else {
                    setIsAddingNewCategory(false);
                    setNewCategoryValue('');
                }
            } else {
                setFormData(getInitialFormData());
                setImagePreview(null);
                setIsAddingNewCategory(false);
                setNewCategoryValue('');
            }
        }
    }, [product, isOpen, categories]);

    const handleProductTypeChange = (e: React.ChangeEvent<HTMLInputElement>) => {
        const type = e.target.value as 'simple' | 'variable';
        setFormData(prev => ({ ...prev, productType: type }));
    };

    const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) => {
        const { name, value } = e.target;

        if (name === 'category' && e.target instanceof HTMLSelectElement) {
            if (value === ADD_NEW_CATEGORY_VALUE) {
                setIsAddingNewCategory(true);
                setFormData(prev => ({ ...prev, category: '' }));
            } else {
                setIsAddingNewCategory(false);
                setFormData(prev => ({ ...prev, category: value }));
            }
        } else {
            const isNumeric = ['price', 'costPrice', 'stock', 'commissionPercentage'].includes(name);
            setFormData(prev => ({
                ...prev,
                [name]: isNumeric ? parseFloat(value) || 0 : value
            }));
        }
    };

    const handleImageUpload = (e: React.ChangeEvent<HTMLInputElement>) => {
        const file = e.target.files?.[0];
        if (file) {
            const reader = new FileReader();
            reader.onloadend = () => {
                const result = reader.result as string;
                setFormData(prev => ({ ...prev, imageUrl: result }));
                setImagePreview(result);
            };
            reader.readAsDataURL(file);
        }
    };
    
    // --- Variant Logic ---

    const handleAddOption = () => {
        setFormData(prev => ({ ...prev, variantOptions: [...(prev.variantOptions || []), { name: '', values: [] }] }));
    };

    const handleRemoveOption = (index: number) => {
        setFormData(prev => ({ ...prev, variantOptions: prev.variantOptions?.filter((_, i) => i !== index) }));
    };

    const handleOptionNameChange = (index: number, name: string) => {
        const newOptions = [...(formData.variantOptions || [])];
        newOptions[index].name = name;
        setFormData(prev => ({ ...prev, variantOptions: newOptions }));
    };

    const handleOptionValuesChange = (index: number, valuesStr: string) => {
        const newOptions = [...(formData.variantOptions || [])];
        newOptions[index].values = valuesStr.split(',').map(s => s.trim()).filter(Boolean);
        setFormData(prev => ({ ...prev, variantOptions: newOptions }));
    };

    const cartesian = (...a: string[][]): string[][] => a.reduce((acc: string[][], val: string[]) => acc.flatMap((d: string[]) => val.map((e: string) => [...d, e])), [[]]);

    const generateVariants = () => {
        if (!formData.variantOptions || formData.variantOptions.some(opt => opt.values.length === 0 || !opt.name.trim())) {
            alert("Please ensure all options have a name and at least one value before generating variants.");
            return;
        }

        const optionValuesArrays = formData.variantOptions.map(opt => opt.values).filter(arr => arr.length > 0);
        if (optionValuesArrays.length === 0) {
            setFormData(prev => ({ ...prev, variants: [] }));
            return;
        }

        const combinations = cartesian(...optionValuesArrays);

        const newVariants: ProductVariant[] = combinations.map((combo: string[]) => {
            const attributes = combo.map((value: string, index: number) => ({
                name: formData.variantOptions![index].name,
                value,
            }));
            
            const variantName = attributes.map(a => a.value).join('-');
            const id = `${formData.id || 'new'}-${variantName.toLowerCase().replace(/\s+/g, '-')}`;

            const existingVariant = formData.variants?.find(v => v.id === id);

            return {
                id,
                attributes,
                price: existingVariant?.price ?? formData.price ?? 0,
                costPrice: existingVariant?.costPrice ?? formData.costPrice ?? 0,
                stock: existingVariant?.stock ?? 0,
                sku: existingVariant?.sku ?? '',
            };
        });

        setFormData(prev => ({ ...prev, variants: newVariants }));
    };

    const handleVariantChange = (index: number, field: keyof ProductVariant, value: string) => {
        const newVariants = [...(formData.variants || [])];
        const isNumeric = ['price', 'costPrice', 'stock'].includes(field);
        (newVariants[index] as any)[field] = isNumeric ? parseFloat(value) || 0 : value;
        setFormData(prev => ({ ...prev, variants: newVariants }));
    };

    // Tiered Pricing Logic
    const handleTierChange = (index: number, field: 'quantity' | 'price', value: string) => {
        const newTiers = [...(formData.tieredPricing || [])];
        newTiers[index] = { ...newTiers[index], [field]: parseFloat(value) || 0 };
        setFormData(prev => ({ ...prev, tieredPricing: newTiers }));
    };

    const addTier = () => {
        const newTiers = [...(formData.tieredPricing || []), { quantity: 0, price: 0 }];
        setFormData(prev => ({ ...prev, tieredPricing: newTiers }));
    };

    const removeTier = (index: number) => {
        const newTiers = [...(formData.tieredPricing || [])];
        newTiers.splice(index, 1);
        setFormData(prev => ({ ...prev, tieredPricing: newTiers }));
    };

    const handleSubmit = (e: React.FormEvent) => {
        e.preventDefault();
        
        const finalCategory = isAddingNewCategory ? newCategoryValue.trim() : formData.category;
        if (!finalCategory) {
            alert("Please select or add a category for the product.");
            return;
        }

        let finalProductData = { ...formData, category: finalCategory };

        if (finalProductData.productType === 'variable') {
            if (!finalProductData.variants || finalProductData.variants.length === 0) {
                alert("Please generate variants for this variable product before saving.");
                return;
            }
            finalProductData.stock = finalProductData.variants.reduce((sum, v) => sum + (v.stock || 0), 0);
            finalProductData.price = finalProductData.variants[0]?.price || 0;
            finalProductData.costPrice = finalProductData.variants[0]?.costPrice || 0;
        } else {
            finalProductData.productType = 'simple';
            finalProductData.variantOptions = [];
            finalProductData.variants = [];
        }
        
        onSave(finalProductData, !!product);
    };

    if (!isOpen) return null;

    return (
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4">
            <div className="bg-white rounded-lg shadow-2xl w-full max-w-4xl max-h-[90vh] flex flex-col">
                <header className="p-6 border-b flex-shrink-0">
                    <h2 className="text-2xl font-bold text-gray-800">{product ? 'Edit Product' : 'Add New Product'}</h2>
                </header>
                <form onSubmit={handleSubmit} className="flex-grow overflow-y-auto">
                    <main className="p-6 grid grid-cols-1 md:grid-cols-3 gap-6">
                        <div className="md:col-span-1 space-y-2">
                            <label className="block text-sm font-medium text-gray-700">Product Image</label>
                            <div className="aspect-square w-full bg-gray-100 rounded-lg border-2 border-dashed flex items-center justify-center">
                                {imagePreview ? <img src={imagePreview} alt="Preview" className="w-full h-full object-cover rounded-md" /> : <span className="text-gray-400 text-sm">No Image</span>}
                            </div>
                            <input type="file" accept="image/*" ref={fileInputRef} onChange={handleImageUpload} className="hidden" />
                            <button type="button" onClick={() => fileInputRef.current?.click()} className="btn-responsive bg-primary text-white hover:bg-blue-700">Upload Image</button>
                        </div>

                        <div className="md:col-span-2 space-y-4">
                            <div>
                                <label htmlFor="name" className="block text-sm font-medium text-gray-700">Product Name</label>
                                <input type="text" name="name" id="name" value={formData.name} onChange={handleChange} required className="mt-1" />
                            </div>
                            <div>
                                <label htmlFor="description" className="block text-sm font-medium text-gray-700">Description</label>
                                <textarea name="description" id="description" value={formData.description || ''} onChange={handleChange} rows={2} className="mt-1"></textarea>
                            </div>
                            <div className="grid grid-cols-2 gap-4">
                                <div>
                                    <label htmlFor="category" className="block text-sm font-medium text-gray-700">Category</label>
                                    <select name="category" id="category" value={isAddingNewCategory ? ADD_NEW_CATEGORY_VALUE : formData.category} onChange={handleChange} required={!isAddingNewCategory} className="mt-1">
                                        <option value="" disabled>Select a category</option>
                                        {categories.map(cat => <option key={cat} value={cat}>{cat}</option>)}
                                        <option value={ADD_NEW_CATEGORY_VALUE} className="font-bold text-primary">+ Add New Category</option>
                                    </select>
                                </div>
                                {isAddingNewCategory && (
                                    <div>
                                        <label htmlFor="newCategory" className="block text-sm font-medium text-gray-700">New Category Name</label>
                                        <input type="text" id="newCategory" value={newCategoryValue} onChange={(e) => setNewCategoryValue(e.target.value)} required className="mt-1" />
                                    </div>
                                )}
                            </div>
                            <div>
                                <label className="block text-sm font-medium text-gray-700">Product Type</label>
                                <div className="mt-2 flex gap-4">
                                    <label className="flex items-center"><input type="radio" value="simple" name="productType" checked={formData.productType === 'simple' || !formData.productType} onChange={handleProductTypeChange} className="focus:ring-primary h-4 w-4 text-primary border-gray-300" /><span className="ml-2 text-sm text-gray-600">Simple Product</span></label>
                                    <label className="flex items-center"><input type="radio" value="variable" name="productType" checked={formData.productType === 'variable'} onChange={handleProductTypeChange} className="focus:ring-primary h-4 w-4 text-primary border-gray-300" /><span className="ml-2 text-sm text-gray-600">Variable Product</span></label>
                                </div>
                            </div>
                        </div>
                    </main>

                    <div className="px-6 pb-6 space-y-6">
                        {formData.productType === 'variable' ? (
                            <>
                                <div>
                                    <h4 className="text-md font-medium text-gray-700 mb-2">Variant Options</h4>
                                    <div className="space-y-3 p-3 bg-gray-50 border rounded-md">
                                        {formData.variantOptions?.map((option, index) => (
                                            <div key={index} className="grid grid-cols-1 md:grid-cols-3 gap-2 items-center">
                                                <input type="text" placeholder="Option name (e.g., Size)" value={option.name} onChange={(e) => handleOptionNameChange(index, e.target.value)} className="md:col-span-1" />
                                                <input type="text" placeholder="Comma-separated values (e.g., S, M, L)" value={option.values.join(', ')} onChange={(e) => handleOptionValuesChange(index, e.target.value)} className="md:col-span-2" />
                                                {formData.variantOptions && formData.variantOptions.length > 1 && <button type="button" onClick={() => handleRemoveOption(index)} className="text-red-500 hover:text-red-700 p-1 rounded-full justify-self-end md:col-start-4">&times;</button>}
                                            </div>
                                        ))}
                                        <button type="button" onClick={handleAddOption} className="mt-2 text-sm text-primary font-medium hover:underline">+ Add another option</button>
                                    </div>
                                    <button type="button" onClick={generateVariants} className="mt-3 w-full bg-blue-100 text-primary px-4 py-2 rounded-lg font-semibold hover:bg-blue-200">Generate Variants</button>
                                </div>

                                {formData.variants && formData.variants.length > 0 && (
                                    <div>
                                        <h4 className="text-md font-medium text-gray-700 my-4">Generated Variants ({formData.variants.length})</h4>
                                        <div className="max-h-60 overflow-y-auto border rounded-md">
                                            <table className="w-full text-sm">
                                                <thead className="bg-gray-100 sticky top-0"><tr className="text-left">
                                                    <th className="p-2 font-semibold">Variant</th><th className="p-2 font-semibold">Price ({cs})</th><th className="p-2 font-semibold">Cost ({cs})</th><th className="p-2 font-semibold">Stock</th><th className="p-2 font-semibold">SKU</th>
                                                </tr></thead>
                                                <tbody>{formData.variants.map((variant, index) => (
                                                    <tr key={variant.id} className="border-t">
                                                        <td className="p-2 font-medium text-gray-800">{variant.attributes.map(attr => attr.value).join(' / ')}</td>
                                                        <td className="p-1"><input type="number" value={variant.price} onChange={e => handleVariantChange(index, 'price', e.target.value)} className="w-full" step="0.01" /></td>
                                                        <td className="p-1"><input type="number" value={variant.costPrice} onChange={e => handleVariantChange(index, 'costPrice', e.target.value)} className="w-full" step="0.01" /></td>
                                                        <td className="p-1"><input type="number" value={variant.stock} onChange={e => handleVariantChange(index, 'stock', e.target.value)} className="w-full" step="1"/></td>
                                                        <td className="p-1"><input type="text" value={variant.sku || ''} onChange={e => handleVariantChange(index, 'sku', e.target.value)} className="w-full" /></td>
                                                    </tr>
                                                ))}</tbody>
                                            </table>
                                        </div>
                                    </div>
                                )}
                            </>
                        ) : (
                             <>
                                <div className="grid grid-cols-2 gap-4">
                                    <div><label htmlFor="price" className="block text-sm font-medium text-gray-700">Selling Price ({cs})</label><input type="number" name="price" id="price" value={formData.price} onChange={handleChange} required min="0" step="0.01" className="mt-1" /></div>
                                    <div><label htmlFor="costPrice" className="block text-sm font-medium text-gray-700">Cost Price ({cs})</label><input type="number" name="costPrice" id="costPrice" value={formData.costPrice} onChange={handleChange} required min="0" step="0.01" className="mt-1" /></div>
                                    <div className="col-span-2"><label className="block text-sm font-medium text-gray-700">Live Profit</label><div className={`mt-1 w-full px-3 py-2 bg-gray-100 border border-gray-200 rounded-lg shadow-inner text-lg font-bold text-center ${liveProfit >= 0 ? 'text-green-600' : 'text-red-600'}`}>{formatCurrency(liveProfit, cs)}</div></div>
                                    <div><label htmlFor="stock" className="block text-sm font-medium text-gray-700">Stock Quantity</label><input type="number" name="stock" id="stock" value={formData.stock} onChange={handleChange} required min="0" step="1" className="mt-1" /></div>
                                    <div><label htmlFor="commissionPercentage" className="block text-sm font-medium text-gray-700">Commission (%)</label><input type="number" name="commissionPercentage" id="commissionPercentage" value={formData.commissionPercentage} onChange={handleChange} required min="0" step="0.1" className="mt-1" /></div>
                                </div>
                                <div>
                                    <h4 className="text-sm font-medium text-gray-700 mb-2">Tiered Pricing (Optional)</h4>
                                    <div className="space-y-2 max-h-32 overflow-y-auto">{formData.tieredPricing?.map((tier, index) => (<div key={index} className="flex items-center gap-2"><span className="text-sm text-gray-500">Buy</span><input type="number" value={tier.quantity} onChange={(e) => handleTierChange(index, 'quantity', e.target.value)} min="1" className="w-20 px-2 py-1 bg-white border border-gray-300 rounded-md text-sm" placeholder="Qty" /><span className="text-sm text-gray-500">or more for</span><input type="number" value={tier.price} onChange={(e) => handleTierChange(index, 'price', e.target.value)} min="0" step="0.01" className="w-24 px-2 py-1 bg-white border border-gray-300 rounded-md text-sm" placeholder="Price" /><button type="button" onClick={() => removeTier(index)} className="text-red-500 hover:text-red-700 p-1 rounded-full">&times;</button></div>))}</div>
                                    <button type="button" onClick={addTier} className="mt-2 text-sm text-primary font-medium hover:underline">+ Add Price Tier</button>
                                </div>
                            </>
                        )}
                    </div>

                    <footer className="p-4 bg-gray-50 rounded-b-lg flex sm:justify-center flex-shrink-0">
                        <div className="responsive-btn-group sm:flex-row-reverse">
                            <button type="submit" className="bg-primary text-white hover:bg-blue-700">{product ? 'Save Changes' : 'Save Product'}</button>
                            <button type="button" onClick={onClose} className="bg-gray-200 text-gray-800 hover:bg-gray-300">Cancel</button>
                        </div>
                    </footer>
                </form>
            </div>
        </div>
    );
};

export default ProductModal;