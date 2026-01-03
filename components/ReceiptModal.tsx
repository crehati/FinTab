
import React, { useRef, useState } from 'react';
import type { Sale, Product, ReceiptSettingsData, User, Customer, PrinterSettingsData, CartItem } from '../types';
import ConfirmationModal from './ConfirmationModal';
import ModalShell from './ModalShell';
import { CloseIcon, PrintIcon, DownloadJpgIcon, DeleteIcon, WarningIcon } from '../constants';
import { loadScript } from '../lib/dom-utils';
import { formatCurrency } from '../lib/utils';

interface ReceiptModalProps {
    sale: Sale | null;
    onClose: () => void;
    receiptSettings: ReceiptSettingsData;
    onDelete: (saleId: string) => void;
    currentUser: User;
    t: (key: string) => string;
    users: User[];
    customers: Customer[];
    isTrialExpired: boolean;
    printerSettings: PrinterSettingsData;
}

const getEffectivePrice = (item: CartItem): number => {
    if (!item) return 0;
    if (item.variant) return Number(item.variant.price) || 0;
    const { product, quantity } = item;
    if (!product) return 0;
    const basePrice = Number(product.price) || 0;
    if (!product.tieredPricing?.length) return basePrice;
    const applicableTier = [...product.tieredPricing]
        .sort((a, b) => b.quantity - a.quantity)
        .find(tier => quantity >= tier.quantity);
    return applicableTier ? (Number(applicableTier.price) || 0) : basePrice;
};

const ReceiptModal: React.FC<ReceiptModalProps> = ({ sale, onClose, receiptSettings, onDelete, currentUser, t, users, customers, isTrialExpired, printerSettings }) => {
    const receiptRef = useRef<HTMLDivElement>(null);
    const [isConfirmOpen, setIsConfirmOpen] = useState(false);

    if (!sale) return null;
    
    const customer = customers.find(c => c.id === sale.customerId);
    const user = users.find(u => u.id === sale.userId);
    const customerName = customer?.name || 'Guest Identity';
    
    const isProforma = sale.status === 'proforma';
    const isFinalized = ['completed', 'completed_bank_verified', 'approved_by_owner', 'pending_bank_verification'].includes(sale.status);
    const canDelete = currentUser && ['Owner', 'Manager'].includes(currentUser.role);
    const cs = receiptSettings.currencySymbol;
    const labels = receiptSettings.labels;

    const totalUnits = (sale.items || []).reduce((sum, item) => sum + item.quantity, 0);

    const generateAndDownloadJpg = async () => {
        if (!receiptRef.current) return;
        try {
            await loadScript('https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js', 'html2canvas');
            const canvas = await (window as any).html2canvas(receiptRef.current, { scale: 3, useCORS: true, backgroundColor: '#f3f4f6' });
            const link = document.createElement('a');
            link.download = `${isProforma ? 'proforma' : 'receipt'}-${sale.id.slice(-6).toUpperCase()}.jpg`;
            link.href = canvas.toDataURL('image/jpeg', 0.95);
            link.click();
        } catch (error) { console.error('Export error:', error); }
    };

    return (
        <ModalShell 
            isOpen={!!sale} 
            onClose={onClose} 
            title={isProforma ? 'Proforma Hub' : 'Verified Receipt'}
            description={`Log Reference: ${receiptSettings.receiptPrefix}${sale.id.slice(-6).toUpperCase()}`}
            maxWidth="max-w-xl"
        >
            <div className="relative font-sans">
                {/* Master Actions Bar */}
                <div className="flex justify-center gap-4 mb-10 no-print sticky top-0 z-30">
                    <button 
                        onClick={() => window.print()} 
                        className="flex-1 flex items-center justify-center gap-3 py-4 bg-slate-900 text-white rounded-2xl font-black uppercase text-[10px] tracking-widest hover:bg-black transition-all shadow-xl active:scale-95"
                    >
                        <PrintIcon className="w-4 h-4" /> Print
                    </button>
                    <button 
                        onClick={generateAndDownloadJpg} 
                        className="flex-1 flex items-center justify-center gap-3 py-4 bg-white border-2 border-slate-100 text-slate-600 rounded-2xl font-black uppercase text-[10px] tracking-widest hover:bg-slate-50 transition-all shadow-sm active:scale-95"
                    >
                        <DownloadJpgIcon className="w-4 h-4" /> Save Image
                    </button>
                    {canDelete && (
                        <button 
                            onClick={() => setIsConfirmOpen(true)} 
                            className="p-4 bg-rose-50 text-rose-500 rounded-2xl hover:bg-rose-600 hover:text-white transition-all shadow-sm active:scale-95"
                        >
                            <DeleteIcon className="w-5 h-5" />
                        </button>
                    )}
                </div>

                {/* Physical Receipt Simulation */}
                <div className="bg-slate-200/50 dark:bg-gray-800/30 p-4 sm:p-10 rounded-[3rem] border border-slate-100 dark:border-gray-800">
                    <div ref={receiptRef} className="bg-white text-gray-950 max-w-[380px] mx-auto py-12 px-8 sm:px-12 shadow-[0_20px_50px_-10px_rgba(0,0,0,0.15)] rounded-sm relative overflow-hidden ring-8 ring-white">
                        {/* Header: Business Info */}
                        <div className="text-center mb-10">
                            {receiptSettings.logo && <img src={receiptSettings.logo} className="w-24 mx-auto mb-6 object-contain grayscale opacity-90" alt="Logo" />}
                            <h2 className="text-2xl font-black uppercase tracking-tighter leading-none mb-2">{receiptSettings.businessName}</h2>
                            {receiptSettings.slogan && <p className="text-[10px] italic text-gray-400 font-bold uppercase tracking-widest">{receiptSettings.slogan}</p>}
                            <div className="mt-8 pt-4 border-t border-gray-100">
                                <p className="text-[9px] font-black uppercase tracking-[0.3em] text-gray-300">Terminal Authorization Certificate</p>
                            </div>
                        </div>

                        {/* Title Section */}
                        <div className="py-4 border-y-2 border-gray-900 text-center mb-8 bg-gray-50/50">
                            <h3 className="text-xl font-black uppercase tracking-[0.2em]">{isProforma ? 'Proforma Estimate' : 'Verified Receipt'}</h3>
                        </div>

                        {/* Metadata */}
                        <div className="space-y-6 mb-10 text-center">
                            <div>
                                <p className="text-[9px] font-black text-gray-300 uppercase tracking-widest mb-1">Authenticated For</p>
                                <h4 className="text-lg font-black uppercase tracking-tight text-gray-900">{customerName}</h4>
                                {customer?.phone && <p className="text-[10px] font-bold text-gray-500 tracking-widest mt-1">{customer.phone}</p>}
                            </div>
                            <div className="grid grid-cols-2 gap-4 text-left border-t border-gray-100 pt-6">
                                <div>
                                    <p className="text-[8px] font-black text-gray-300 uppercase mb-1">Log Identifier</p>
                                    <p className="text-[10px] font-black">{receiptSettings.receiptPrefix}{sale.id.slice(-6).toUpperCase()}</p>
                                </div>
                                <div className="text-right">
                                    <p className="text-[8px] font-black text-gray-300 uppercase mb-1">Entry Timestamp</p>
                                    <p className="text-[10px] font-black tabular-nums">{new Date(sale.date).toLocaleDateString()} {new Date(sale.date).toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'})}</p>
                                </div>
                            </div>
                        </div>

                        {/* Items Table */}
                        <div className="border-t-2 border-gray-900 pt-4 mb-10">
                            <div className="grid grid-cols-12 gap-2 font-black text-[9px] uppercase tracking-widest border-b border-gray-100 pb-3 mb-4 text-gray-400">
                                <div className="col-span-6">Identity</div>
                                <div className="col-span-3 text-center">Qty</div>
                                <div className="col-span-3 text-right">Sum</div>
                            </div>
                            <div className="space-y-6">
                                {sale.items.map((item, i) => {
                                    const price = getEffectivePrice(item);
                                    return (
                                        <div key={i} className="grid grid-cols-12 gap-2 items-start text-[11px]">
                                            <div className="col-span-6">
                                                <p className="font-black uppercase tracking-tight leading-tight">{item.product?.name || 'Asset'}</p>
                                                <p className="text-[8px] text-gray-400 font-bold uppercase mt-1 tracking-widest">Val: {formatCurrency(price, cs)}</p>
                                            </div>
                                            <div className="col-span-3 text-center font-black tabular-nums">{item.quantity}</div>
                                            <div className="col-span-3 text-right font-black tabular-nums">{formatCurrency(price * item.quantity, cs)}</div>
                                        </div>
                                    );
                                })}
                            </div>
                        </div>

                        {/* Totals Section */}
                        <div className="space-y-3 border-t-2 border-gray-900 pt-6">
                            <div className="flex justify-between font-bold text-[10px] uppercase tracking-widest text-gray-400">
                                <span>Total Sub-sum</span>
                                <span className="tabular-nums">{formatCurrency(sale.subtotal, cs)}</span>
                            </div>
                            {sale.discount > 0 && (
                                <div className="flex justify-between font-bold text-[10px] uppercase tracking-widest text-rose-500">
                                    <span>Authorized Rebate</span>
                                    <span className="tabular-nums">-{formatCurrency(sale.discount, cs)}</span>
                                </div>
                            )}
                            <div className="flex justify-between items-end pt-4">
                                <span className="text-[10px] font-black uppercase tracking-[0.3em] pb-1">Final Settlement</span>
                                <span className="text-3xl font-black tabular-nums tracking-tighter">{formatCurrency(sale.total, cs)}</span>
                            </div>
                            
                            <div className="mt-8 pt-8 border-t border-dashed border-gray-200">
                                <div className="flex justify-between text-[10px] font-black uppercase tracking-widest text-gray-400 mb-2">
                                    <span>Protocol</span>
                                    <span>{sale.paymentMethod || 'Cash'}</span>
                                </div>
                                {sale.paymentMethod === 'Cash' && sale.cashReceived !== undefined && (
                                    <>
                                        <div className="flex justify-between text-[10px] font-black uppercase tracking-widest text-gray-400 mb-2">
                                            <span>Received</span>
                                            <span className="tabular-nums">{formatCurrency(sale.cashReceived, cs)}</span>
                                        </div>
                                        <div className="flex justify-between text-[10px] font-black uppercase tracking-widest text-gray-400">
                                            <span>Change</span>
                                            <span className="tabular-nums">{formatCurrency(sale.change || 0, cs)}</span>
                                        </div>
                                    </>
                                )}
                            </div>
                        </div>

                        {/* Official Stamp/Footer */}
                        <div className="text-center mt-16 pb-4">
                            <p className="text-[10px] font-black uppercase tracking-[0.2em] mb-4 text-gray-800">{receiptSettings.thankYouNote}</p>
                            <div className="inline-block border-2 border-gray-900 px-4 py-1.5 transform -rotate-2">
                                <p className="text-[9px] font-black uppercase tracking-[0.4em] leading-none">Verified • FT Node</p>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <ConfirmationModal 
                isOpen={isConfirmOpen} 
                onClose={() => setIsConfirmOpen(false)} 
                onConfirm={() => onDelete(sale.id)} 
                title="Purge Transaction" 
                message={`Permanently purge record #${sale.id.slice(-6).toUpperCase()}? This action is irreversible.`}
                amount={sale.total}
                currencySymbol={cs}
                variant="danger"
                isIrreversible={true}
                confirmLabel="Purge Record"
            />
        </ModalShell>
    );
};

export default ReceiptModal;
