import React, { useState, useEffect, useRef } from 'react';
import ReactDOM from 'react-dom';
import type { Product, ReceiptSettingsData } from '../types';
import { CloseIcon, PrintIcon } from '../constants';
import { formatCurrency } from '../lib/utils';

declare var JsBarcode: any;

interface LabelPrintModalProps {
    isOpen: boolean;
    onClose: () => void;
    product: Product | null;
    receiptSettings: ReceiptSettingsData;
}

const LabelPrintModal: React.FC<LabelPrintModalProps> = ({ isOpen, onClose, product, receiptSettings }) => {
    const [labelCount, setLabelCount] = useState<number>(1);
    const [include, setInclude] = useState({
        name: true,
        price: true,
        business: false,
        barcode: true,
    });
    
    const barcodePreviewRef = useRef<SVGSVGElement>(null);
    const sheetContentRef = useRef<HTMLDivElement>(null);

    useEffect(() => {
        if (isOpen && barcodePreviewRef.current && product && include.barcode) {
            try {
                JsBarcode(barcodePreviewRef.current, product.id, {
                    format: "CODE128",
                    displayValue: true,
                    fontSize: 14,
                    height: 40,
                    margin: 0,
                });
            } catch (e) {
                console.error("Barcode generation failed:", e);
                // You could display an error in the preview
            }
        }
    }, [isOpen, product, include.barcode]);
    
    const handleIncludeChange = (e: React.ChangeEvent<HTMLInputElement>) => {
        const { name, checked } = e.target;
        setInclude(prev => ({ ...prev, [name]: checked }));
    };
    
    const handlePrint = () => {
        if (!sheetContentRef.current || !product) return;

        let labelContent = '';
        if (include.business) labelContent += `<div style="font-size: 8px; font-weight: bold; text-align: center; margin-bottom: 2px;">${receiptSettings.businessName}</div>`;
        if (include.name) labelContent += `<div style="font-size: 10px; font-weight: 600; text-align: center; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin-bottom: 2px;">${product.name}</div>`;
        if (include.price) labelContent += `<div style="font-size: 12px; font-weight: bold; text-align: center; margin-bottom: 4px;">${formatCurrency(product.price, receiptSettings.currencySymbol)}</div>`;
        if (include.barcode) {
            const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
            JsBarcode(svg, product.id, { format: "CODE128", displayValue: true, fontSize: 10, height: 30, margin: 0, width: 1.5 });
            labelContent += `<div style="display: flex; justify-content: center;">${svg.outerHTML}</div>`;
        }
        
        const labelHTML = `
            <div style="width: 2.25in; height: 1.25in; border: 1px dotted #ccc; padding: 4px; box-sizing: border-box; overflow: hidden; display: flex; flex-direction: column; justify-content: center; background: white; color: black; font-family: sans-serif;">
                ${labelContent}
            </div>
        `;
        
        const labels = Array(labelCount).fill(labelHTML).join('');
        
        sheetContentRef.current.innerHTML = `<div style="display: flex; flex-wrap: wrap; gap: 0;">${labels}</div>`;
        
        const onAfterPrint = () => {
            document.body.classList.remove('printing-labels');
            window.removeEventListener('afterprint', onAfterPrint);
            if (sheetContentRef.current) {
                sheetContentRef.current.innerHTML = ''; // Clean up
            }
        };

        window.addEventListener('afterprint', onAfterPrint);
        document.body.classList.add('printing-labels');
        window.print();
    };

    const modalRoot = document.getElementById('modal-root');
    if (!isOpen || !product || !modalRoot) return null;
    
    return ReactDOM.createPortal(
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4" role="dialog" aria-modal="true">
            <div className="bg-white rounded-lg shadow-2xl w-full max-w-2xl max-h-[90vh] flex flex-col">
                <header className="p-4 border-b flex justify-between items-center flex-shrink-0">
                    <div>
                        <h2 className="text-xl font-bold text-gray-800">Print Product Label</h2>
                        <p className="text-sm text-gray-500 mt-1">For: {product.name}</p>
                    </div>
                    <button onClick={onClose} className="p-2 rounded-full text-gray-500 hover:bg-gray-100" aria-label="Close modal">
                        <CloseIcon />
                    </button>
                </header>

                <main className="flex-grow overflow-y-auto grid grid-cols-1 md:grid-cols-2 gap-6 p-6">
                    {/* Configuration Panel */}
                    <div className="space-y-6">
                        <div>
                            <label htmlFor="label-count" className="block text-sm font-medium text-gray-700">Number of Labels to Print</label>
                            <input
                                type="number"
                                id="label-count"
                                value={labelCount}
                                onChange={e => setLabelCount(Math.max(1, parseInt(e.target.value) || 1))}
                                className="mt-1"
                                min="1"
                            />
                        </div>
                        
                        <div>
                            <h4 className="text-sm font-medium text-gray-700 mb-2">Include on Label:</h4>
                            <div className="space-y-2">
                                <label className="flex items-center"><input type="checkbox" name="name" checked={include.name} onChange={handleIncludeChange} className="h-4 w-4 text-primary rounded" /><span className="ml-2 text-sm">Product Name</span></label>
                                <label className="flex items-center"><input type="checkbox" name="price" checked={include.price} onChange={handleIncludeChange} className="h-4 w-4 text-primary rounded" /><span className="ml-2 text-sm">Price</span></label>
                                <label className="flex items-center"><input type="checkbox" name="business" checked={include.business} onChange={handleIncludeChange} className="h-4 w-4 text-primary rounded" /><span className="ml-2 text-sm">Business Name</span></label>
                                <label className="flex items-center"><input type="checkbox" name="barcode" checked={include.barcode} onChange={handleIncludeChange} className="h-4 w-4 text-primary rounded" /><span className="ml-2 text-sm">Barcode (Product ID)</span></label>
                            </div>
                        </div>
                    </div>

                    {/* Preview Panel */}
                    <div className="space-y-4">
                        <h4 className="text-sm font-medium text-gray-700">Live Preview (approx. 2.25 x 1.25 in)</h4>
                        <div className="bg-gray-100 p-4 rounded-lg flex items-center justify-center">
                            <div className="w-[216px] h-[120px] bg-white border border-dashed p-1 shadow-md flex flex-col justify-center">
                                {include.business && <p className="text-[8px] font-bold text-center mb-0.5">{receiptSettings.businessName}</p>}
                                {include.name && <p className="text-[10px] font-semibold text-center truncate mb-0.5">{product.name}</p>}
                                {include.price && <p className="text-xs font-bold text-center mb-1">{formatCurrency(product.price, receiptSettings.currencySymbol)}</p>}
                                {include.barcode && <div className="flex justify-center"><svg ref={barcodePreviewRef}></svg></div>}
                            </div>
                        </div>
                    </div>
                </main>
                
                <footer className="p-4 bg-gray-50 border-t flex justify-end gap-4 flex-shrink-0">
                    <button onClick={onClose} className="bg-gray-200 text-gray-800 px-4 py-2 rounded-lg font-semibold hover:bg-gray-300">Cancel</button>
                    <button onClick={handlePrint} className="flex items-center gap-2 bg-primary text-white px-4 py-2 rounded-lg font-semibold hover:bg-blue-700">
                        <PrintIcon />
                        Print Labels
                    </button>
                </footer>
            </div>
            {/* Hidden div for generating the full print sheet */}
            <div id="label-sheet-to-print" ref={sheetContentRef} className="hidden"></div>
        </div>,
        modalRoot
    );
};

export default LabelPrintModal;