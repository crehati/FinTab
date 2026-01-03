
import React, { useRef } from 'react';
import ReactDOM from 'react-dom';
import type { CashCount, GoodsCosting, GoodsReceiving, WeeklyInventoryCheck, BusinessProfile, ReceiptSettingsData } from '../types';
import { CloseIcon, PrintIcon, DownloadJpgIcon, WarningIcon } from '../constants';
import { loadScript } from '../lib/dom-utils';
import ModalShell from './ModalShell';

interface FinanceReportModalProps {
    isOpen: boolean;
    onClose: () => void;
    record: CashCount | GoodsCosting | GoodsReceiving | WeeklyInventoryCheck | null;
    type: 'cash' | 'costing' | 'receiving' | 'inventory_audit';
    businessProfile: BusinessProfile | null;
    receiptSettings: ReceiptSettingsData;
}

const FinanceReportModal: React.FC<FinanceReportModalProps> = ({ isOpen, onClose, record, type, businessProfile, receiptSettings }) => {
    const reportRef = useRef<HTMLDivElement>(null);
    
    if (!isOpen || !record) return null;
    const cs = receiptSettings.currencySymbol;

    const handleDownload = async () => {
        if (!reportRef.current) return;
        try {
            await loadScript('https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js', 'html2canvas');
            const canvas = await (window as any).html2canvas(reportRef.current, { scale: 3, useCORS: true, backgroundColor: '#ffffff' });
            const link = document.createElement('a');
            link.download = `Report_${type.toUpperCase()}_${record.id.slice(-6).toUpperCase()}.jpg`;
            link.href = canvas.toDataURL('image/jpeg', 0.95);
            link.click();
        } catch (error) { console.error('Export failed:', error); }
    };

    const renderCashCount = (data: CashCount) => (
        <div className="space-y-10">
            <div className="grid grid-cols-2 gap-10 border-b border-gray-100 pb-10">
                <div>
                    <p className="text-[10px] font-black text-gray-300 uppercase tracking-[0.3em] mb-2">Audit Timestamp</p>
                    <p className="text-sm font-black text-gray-900 uppercase tracking-tight">{data.date}</p>
                </div>
                <div className="text-right">
                    <p className="text-[10px] font-black text-gray-300 uppercase tracking-[0.3em] mb-2">Node Lifecycle</p>
                    <p className="text-sm font-black text-emerald-600 uppercase tracking-tight italic">Verified Acceptance</p>
                </div>
            </div>

            <div className="space-y-6">
                <div className="flex justify-between items-center text-sm font-bold text-gray-500 uppercase tracking-widest">
                    <span>System Protocol Sum</span>
                    <span className="tabular-nums">{cs}{data.systemTotal.toFixed(2)}</span>
                </div>
                <div className="flex justify-between items-center text-sm font-bold text-gray-900 uppercase tracking-widest">
                    <span>Physical Quantum Count</span>
                    <span className="tabular-nums">{cs}{data.countedTotal.toFixed(2)}</span>
                </div>
                <div className="p-10 bg-gray-900 text-white rounded-sm shadow-2xl relative overflow-hidden">
                    <div className="absolute top-0 right-0 w-32 h-32 bg-white/5 rounded-full -mr-16 -mt-16 blur-2xl"></div>
                    <p className="text-[10px] font-black text-gray-500 uppercase tracking-[0.4em] mb-4 text-center">Consolidated Variance Audit</p>
                    <p className={`text-6xl font-black text-center tabular-nums tracking-tighter ${data.difference === 0 ? 'text-emerald-400' : 'text-rose-400'}`}>
                        {data.difference > 0 ? '+' : ''}{cs}{data.difference.toFixed(2)}
                    </p>
                </div>
            </div>

            {data.notes && (
                <div className="pt-10 border-t border-gray-100">
                    <p className="text-[10px] font-black text-gray-300 uppercase tracking-[0.3em] mb-4">Audit Rationale</p>
                    <p className="text-sm text-gray-600 leading-relaxed italic border-l-4 border-gray-900 pl-6">"{data.notes}"</p>
                </div>
            )}
        </div>
    );

    const renderGoodsCosting = (data: GoodsCosting) => (
        <div className="space-y-10">
            <div className="p-8 bg-gray-50 border-2 border-gray-900 rounded-sm">
                <p className="text-[10px] font-black text-gray-400 uppercase tracking-[0.3em] mb-2 text-center">Unit Identification Protocol</p>
                <h3 className="text-2xl font-black text-gray-950 text-center uppercase tracking-tighter leading-none">{data.productName || 'Unnamed Asset'}</h3>
                <p className="text-center text-[11px] font-bold text-gray-400 uppercase mt-2 tracking-[0.2em]">SKU: {data.productNumber}</p>
            </div>

            <div className="grid grid-cols-2 gap-10">
                <div className="space-y-4">
                    <p className="text-[10px] font-black text-gray-300 uppercase tracking-[0.3em] border-b border-gray-100 pb-2">Acquisition Logistics</p>
                    <div className="flex justify-between text-xs font-bold text-gray-600"><span className="uppercase">Batch Quantum</span><span className="tabular-nums">{data.quantity} Units</span></div>
                    <div className="flex justify-between text-xs font-bold text-gray-600"><span className="uppercase">Unit Value (Acq)</span><span className="tabular-nums">{cs}{data.buyingUnitPrice.toFixed(2)}</span></div>
                </div>
                <div className="space-y-4">
                    <p className="text-[10px] font-black text-gray-300 uppercase tracking-[0.3em] border-b border-gray-100 pb-2">Landed Surcharges</p>
                    <div className="flex justify-between text-xs font-bold text-rose-500"><span className="uppercase">Aggregate Tax</span><span className="tabular-nums">{cs}{data.additionalCosts.taxes.toFixed(2)}</span></div>
                    <div className="flex justify-between text-xs font-bold text-rose-500"><span className="uppercase">Sea/Inland Freight</span><span className="tabular-nums">{cs}{data.additionalCosts.shipping.toFixed(2)}</span></div>
                </div>
            </div>

            <div className="pt-8 border-t-2 border-gray-950">
                 <div className="flex justify-between items-center bg-gray-950 text-white p-10 rounded-sm shadow-xl">
                    <div>
                        <p className="text-[10px] font-black uppercase tracking-[0.4em] text-gray-500 mb-2">Final Unit Cost (Landed)</p>
                        <p className="text-5xl font-black tracking-tighter text-rose-400 tabular-nums">{cs}{data.unitCost.toFixed(2)}</p>
                    </div>
                    <div className="text-right">
                        <p className="text-[10px] font-black uppercase tracking-[0.4em] text-gray-500 mb-2">Market Yield Multiplier</p>
                        <p className="text-3xl font-black text-white tabular-nums">+{data.marginPercentage}%</p>
                    </div>
                 </div>
            </div>

            <div className="text-center pt-8 border-t border-dashed border-gray-200">
                <p className="text-[10px] font-black uppercase tracking-[0.3em] text-gray-300 mb-3">Authorized Market Value</p>
                <p className="text-4xl font-black text-primary tracking-tighter tabular-nums">{cs}{data.suggestedSellingPrice.toFixed(2)}</p>
            </div>
        </div>
    );

    const renderGoodsReceiving = (data: GoodsReceiving) => (
        <div className="space-y-10">
            <div className="flex justify-between items-end border-b-2 border-gray-900 pb-8">
                <div>
                    <p className="text-[10px] font-black text-gray-300 uppercase tracking-[0.3em] mb-2">Document Reference</p>
                    <p className="text-2xl font-black text-gray-950 tracking-tighter">{data.refNumber}</p>
                </div>
                <div className="text-right">
                    <p className="text-[10px] font-black text-gray-300 uppercase tracking-[0.3em] mb-2">Audit Outcome</p>
                    <span className={`text-sm font-black uppercase tracking-widest px-4 py-1.5 border-2 ${data.status === 'accepted' ? 'border-emerald-600 text-emerald-600' : 'border-rose-600 text-rose-600'}`}>
                        {data.status.toUpperCase()}
                    </span>
                </div>
            </div>

            <div className="space-y-8">
                <div className="grid grid-cols-3 gap-6">
                    <div className="bg-gray-50 p-6 rounded-sm text-center">
                        <p className="text-[9px] font-black text-gray-400 uppercase tracking-widest mb-2">Manifest Expected</p>
                        <p className="text-3xl font-black tabular-nums">{data.expectedQty}</p>
                    </div>
                    <div className="bg-gray-900 text-white p-6 rounded-sm text-center">
                        <p className="text-[9px] font-black text-gray-500 uppercase tracking-widest mb-2">Authorized Recv</p>
                        <p className="text-3xl font-black tabular-nums text-primary">{data.receivedQty}</p>
                    </div>
                    <div className={`p-6 rounded-sm text-center border-2 ${data.difference === 0 ? 'bg-emerald-50 border-emerald-100 text-emerald-600' : 'bg-rose-50 border-rose-100 text-rose-600'}`}>
                        <p className="text-[9px] font-black uppercase tracking-widest mb-2">Net Variance</p>
                        <p className="text-3xl font-black tabular-nums">{data.difference > 0 ? '+' : ''}{data.difference}</p>
                    </div>
                </div>

                <div className="pt-10">
                    <p className="text-[10px] font-black text-gray-300 uppercase tracking-[0.3em] mb-4">Arrival Notes</p>
                    <p className="text-sm text-gray-600 leading-relaxed italic bg-gray-50 p-6 rounded-sm ring-1 ring-gray-100">"{data.notes || 'Manifest aligned with physical quantum count. No discrepancies recorded.'}"</p>
                </div>
            </div>
        </div>
    );

    const renderInventoryAudit = (data: WeeklyInventoryCheck) => (
        <div className="space-y-10">
            <p className="text-[11px] font-black text-gray-950 uppercase tracking-[0.4em] text-center mb-10 pb-6 border-b border-gray-100">Quantum Physical Verification Audit</p>
            
            <div className="space-y-4">
                {data.items.map((item, i) => (
                    <div key={i} className="p-8 bg-gray-50 rounded-sm border-l-8 border-gray-950 flex justify-between items-center group transition-colors hover:bg-gray-100">
                         <div className="min-w-0 pr-10">
                            <p className="text-[9px] font-black text-gray-400 uppercase tracking-widest mb-1">{item.productNumber}</p>
                            <h4 className="text-base font-black text-gray-950 uppercase tracking-tight leading-tight truncate">{item.productName}</h4>
                            {item.notes && <p className="text-[10px] text-gray-500 italic mt-3 leading-relaxed">Audit Memo: "{item.notes}"</p>}
                        </div>
                        <div className="text-right flex-shrink-0">
                            <div className="flex items-center gap-6">
                                <div className="text-center">
                                    <p className="text-[8px] font-black text-gray-300 uppercase mb-1">System</p>
                                    <p className="text-lg font-black tabular-nums">{item.systemQty}</p>
                                </div>
                                <div className="text-center">
                                    <p className="text-[8px] font-black text-gray-300 uppercase mb-1">Physical</p>
                                    <p className="text-lg font-black tabular-nums text-primary">{item.physicalQty}</p>
                                </div>
                                <div className="text-center min-w-[60px]">
                                    <p className="text-[8px] font-black text-gray-300 uppercase mb-1">Shift</p>
                                    <p className={`text-xl font-black tabular-nums ${item.difference === 0 ? 'text-emerald-500' : 'text-rose-500'}`}>
                                        {item.difference > 0 ? '+' : ''}{item.difference}
                                    </p>
                                </div>
                            </div>
                        </div>
                    </div>
                ))}
            </div>
        </div>
    );

    const auditTrail = [
        { label: 'Initialization Signer', name: (record as any).signatures?.first?.userName || (record as any).signatures?.manager?.userName, time: (record as any).signatures?.first?.timestamp || (record as any).signatures?.manager?.timestamp },
        { label: 'Verification Signer', name: (record as any).signatures?.second?.userName || (record as any).signatures?.verifier?.userName, time: (record as any).signatures?.second?.timestamp || (record as any).signatures?.verifier?.timestamp },
        { label: 'Audit Authorization', name: (record as any).ownerAudit?.userName || (record as any).signatures?.approver?.userName, time: (record as any).ownerAudit?.timestamp || (record as any).signatures?.approver?.timestamp }
    ].filter(a => a.name);

    const footer = (
        <>
            <button onClick={onClose} className="btn-base btn-primary flex-1 py-5 text-[11px] font-black uppercase tracking-widest shadow-xl">Exit Audit View</button>
            <button onClick={() => window.print()} className="btn-base btn-secondary px-8 py-5 text-[11px] font-black uppercase tracking-widest flex items-center gap-3"><PrintIcon className="w-4 h-4" /> Print Document</button>
            <button onClick={handleDownload} className="btn-base btn-secondary px-8 py-5 text-[11px] font-black uppercase tracking-widest flex items-center gap-3"><DownloadJpgIcon className="w-4 h-4" /> Save Export</button>
        </>
    );

    return (
        <ModalShell 
            isOpen={isOpen} 
            onClose={onClose} 
            title="Accounting Certificate" 
            description="Official Ledger Extract"
            maxWidth="max-w-2xl"
            footer={footer}
        >
            <div className="bg-gray-100 p-3 sm:p-8 rounded-[2rem] border border-gray-200">
                <div ref={reportRef} className="bg-white shadow-2xl py-16 px-8 sm:px-14 border border-gray-100 rounded-sm mx-auto relative overflow-hidden font-sans ring-[12px] ring-white">
                    {/* Security Overlay */}
                    <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 pointer-events-none opacity-[0.03] rotate-[-45deg] select-none">
                        <p className="text-[120px] font-black text-gray-900 uppercase">OFFICIAL</p>
                    </div>

                    <div className="text-center mb-16 relative">
                        <h2 className="text-3xl font-black uppercase tracking-tighter text-gray-950">{receiptSettings.businessName}</h2>
                        <div className="flex items-center justify-center gap-3 mt-4">
                            <div className="h-[2px] w-12 bg-gray-950"></div>
                            <p className="text-[10px] font-black text-gray-400 uppercase tracking-[0.5em]">
                                {type === 'cash' ? 'Cash Audit Certificate' : type === 'costing' ? 'Landed Cost Analysis' : type === 'receiving' ? 'Manifest arrival audit' : 'Inventory Quantum Audit'}
                            </p>
                            <div className="h-[2px] w-12 bg-gray-950"></div>
                        </div>
                        <p className="text-[9px] text-gray-300 font-bold uppercase tracking-widest mt-3">Verified Log: {record.id.toUpperCase()}</p>
                    </div>

                    {type === 'cash' && renderCashCount(record as CashCount)}
                    {type === 'costing' && renderGoodsCosting(record as GoodsCosting)}
                    {type === 'receiving' && renderGoodsReceiving(record as GoodsReceiving)}
                    {type === 'inventory_audit' && renderInventoryAudit(record as WeeklyInventoryCheck)}

                    <div className="mt-20 pt-10 border-t-2 border-gray-950">
                        <p className="text-[10px] font-black text-gray-950 uppercase tracking-[0.3em] mb-10 text-center">Official Digital Signature Chain</p>
                        <div className="space-y-6">
                            {auditTrail.map((entry, i) => (
                                <div key={i} className="flex justify-between items-center text-[10px] font-black border-b border-gray-50 pb-4 last:border-0">
                                    <div className="flex flex-col">
                                        <span className="text-gray-400 uppercase tracking-widest mb-1">{entry.label}</span>
                                        <span className="text-gray-300 font-bold">{new Date(entry.time!).toLocaleString()}</span>
                                    </div>
                                    <div className="text-right">
                                        <div className="mb-1">
                                            <span className="text-gray-950 uppercase ring-1 ring-gray-200 px-3 py-1 bg-gray-50">SIGNED: {entry.name}</span>
                                        </div>
                                        <p className="text-[8px] text-gray-300 uppercase tracking-widest">Authorized Identity verified</p>
                                    </div>
                                </div>
                            ))}
                        </div>
                    </div>

                    <div className="mt-20 text-center pt-10 border-t border-gray-100">
                        <p className="text-[10px] font-black text-gray-300 uppercase tracking-[0.5em]">System Node Extract • Generated {new Date().toLocaleDateString()}</p>
                    </div>
                </div>
            </div>
        </ModalShell>
    );
};

export default FinanceReportModal;
