
// @ts-nocheck
import React, { useState, useMemo } from 'react';
import type { CashCount, User, Sale, ReceiptSettingsData, AppPermissions, CashCountSignature, CashCountStatus, BusinessSettingsData, BusinessProfile } from '../types';
import Card from './Card';
import EmptyState from './EmptyState';
import ModalShell from './ModalShell';
import { CalculatorIcon, PlusIcon, FilePdfIcon } from '../constants';
import FinanceReportModal from './FinanceReportModal';

interface CashCountProps {
    cashCounts: CashCount[];
    setCashCounts: (update: any) => void;
    users: User[];
    sales: Sale[];
    currentUser: User;
    receiptSettings: ReceiptSettingsData;
    businessSettings: BusinessSettingsData;
    businessProfile: BusinessProfile | null;
}

const CashCountPage: React.FC<CashCountProps> = ({ cashCounts, setCashCounts, users, sales, currentUser, receiptSettings, businessSettings, businessProfile }) => {
    const [isAddModalOpen, setIsAddModalOpen] = useState(false);
    const [reportToShow, setReportToShow] = useState<CashCount | null>(null);
    const [formData, setFormData] = useState({
        date: new Date().toISOString().split('T')[0],
        countedTotal: '',
        notes: ''
    });

    const cs = receiptSettings.currencySymbol;
    
    const calculatedSystemTotal = useMemo(() => {
        return (sales || [])
            .filter(s => s && s.status === 'completed' && s.paymentMethod === 'Cash' && s.date.startsWith(formData.date))
            .reduce((sum, s) => sum + s.total, 0);
    }, [sales, formData.date]);

    const difference = useMemo(() => (parseFloat(formData.countedTotal) || 0) - calculatedSystemTotal, [formData.countedTotal, calculatedSystemTotal]);

    const handleCreateCount = () => {
        const signature: CashCountSignature = {
            userId: currentUser.id,
            userName: currentUser.name,
            role: currentUser.role,
            timestamp: new Date().toISOString()
        };

        const newCount: CashCount = {
            id: `cc-${Date.now()}`,
            date: formData.date,
            systemTotal: calculatedSystemTotal,
            countedTotal: parseFloat(formData.countedTotal) || 0,
            difference,
            status: 'first_signed',
            notes: formData.notes,
            signatures: { first: signature },
            auditLog: [{ timestamp: signature.timestamp, status: 'first_signed', actorId: currentUser.id, actorName: currentUser.name, note: 'Initial count submitted.' }]
        };

        setCashCounts(prev => [newCount, ...(prev || [])]);
        setIsAddModalOpen(false);
    };

    const handleSecondSign = (count: CashCount) => {
        const signature: CashCountSignature = { userId: currentUser.id, userName: currentUser.name, role: currentUser.role, timestamp: new Date().toISOString() };
        setCashCounts(prev => prev.map(c => c.id === count.id ? {
            ...c, status: 'second_signed', signatures: { ...c.signatures, second: signature },
            auditLog: [...c.auditLog, { timestamp: signature.timestamp, status: 'second_signed', actorId: currentUser.id, actorName: currentUser.name, note: 'Second signature confirmed.' }]
        } : c));
    };

    const handleApprove = (count: CashCount, status: 'accepted' | 'rejected') => {
        setCashCounts(prev => prev.map(c => c.id === count.id ? {
            ...c, status,
            ownerAudit: { userId: currentUser.id, userName: currentUser.name, timestamp: new Date().toISOString(), status },
            auditLog: [...c.auditLog, { timestamp: new Date().toISOString(), status, actorId: currentUser.id, actorName: currentUser.name, note: `Final audit: ${status}` }]
        } : c));
    };

    return (
        <div className="space-y-8 font-sans">
            <header className="flex justify-between items-end">
                <div>
                    <h1 className="text-3xl font-black text-slate-900 dark:text-white uppercase tracking-tighter">Cash Verification</h1>
                    <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest mt-1">Dual-signature integrity protocol</p>
                </div>
                <button onClick={() => setIsAddModalOpen(true)} className="bg-primary text-white px-8 py-3 rounded-2xl font-black uppercase text-[10px] shadow-xl active:scale-95 transition-all flex items-center gap-2">
                    <PlusIcon className="w-4 h-4" /> New Count
                </button>
            </header>

            <Card title="Audit Ledger">
                <div className="overflow-x-auto min-h-[400px]">
                    {cashCounts.length > 0 ? (
                        <table className="w-full text-left">
                            <thead className="text-[10px] font-black uppercase tracking-widest text-slate-400 border-b">
                                <tr>
                                    <th className="px-6 py-4">Date</th>
                                    <th className="px-6 py-4">System</th>
                                    <th className="px-6 py-4">Counted</th>
                                    <th className="px-6 py-4 text-center">Variance</th>
                                    <th className="px-6 py-4 text-center">Status</th>
                                    <th className="px-6 py-4 text-right">Workflow</th>
                                </tr>
                            </thead>
                            <tbody className="divide-y">
                                {cashCounts.map(count => (
                                    <tr key={count.id} className="hover:bg-slate-50 transition-colors">
                                        <td className="px-6 py-6 font-black uppercase text-xs">{count.date}</td>
                                        <td className="px-6 py-6 font-bold tabular-nums">{cs}{count.systemTotal.toFixed(2)}</td>
                                        <td className="px-6 py-6 font-black text-primary tabular-nums">{cs}{count.countedTotal.toFixed(2)}</td>
                                        <td className={`px-6 py-6 text-center font-black tabular-nums ${count.difference === 0 ? 'text-emerald-500' : 'text-rose-500'}`}>
                                            {count.difference > 0 ? '+' : ''}{cs}{count.difference.toFixed(2)}
                                        </td>
                                        <td className="px-6 py-6 text-center">
                                            <span className={`status-badge ${count.status === 'accepted' ? 'status-approved' : count.status === 'rejected' ? 'status-rejected' : 'status-pending'}`}>{count.status.replace('_', ' ')}</span>
                                        </td>
                                        <td className="px-6 py-6 text-right">
                                            <div className="flex justify-end gap-2">
                                                {count.status === 'first_signed' && count.signatures.first.userId !== currentUser.id && (
                                                    <button onClick={() => handleSecondSign(count)} className="px-4 py-2 bg-primary text-white rounded-xl text-[9px] font-black uppercase shadow-lg">Verify</button>
                                                )}
                                                {count.status === 'second_signed' && currentUser.role === 'Owner' && (
                                                    <>
                                                        <button onClick={() => handleApprove(count, 'accepted')} className="px-4 py-2 bg-emerald-500 text-white rounded-xl text-[9px] font-black uppercase shadow-lg">Accept</button>
                                                        <button onClick={() => handleApprove(count, 'rejected')} className="px-4 py-2 bg-rose-500 text-white rounded-xl text-[9px] font-black uppercase shadow-lg">Reject</button>
                                                    </>
                                                )}
                                                {(count.status === 'accepted' || count.status === 'rejected') && (
                                                    <button onClick={() => setReportToShow(count)} className="p-2.5 bg-slate-900 text-white rounded-xl"><FilePdfIcon className="w-4 h-4"/></button>
                                                )}
                                            </div>
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    ) : <EmptyState icon={<CalculatorIcon />} title="No Counts Recorded" />}
                </div>
            </Card>

            <ModalShell isOpen={isAddModalOpen} onClose={() => setIsAddModalOpen(false)} title="New Cash Entry">
                <div className="space-y-6 p-2">
                    <div className="bg-slate-50 p-6 rounded-[2rem] border shadow-inner">
                        <p className="text-[9px] font-black uppercase text-slate-400 mb-1">Calculated Protocol Balance</p>
                        <p className="text-3xl font-black text-slate-900 tabular-nums">{cs}{calculatedSystemTotal.toFixed(2)}</p>
                    </div>
                    <div>
                        <label className="text-[9px] font-black uppercase text-slate-400 mb-2 block">Physical Hand Count</label>
                        <input type="number" value={formData.countedTotal} onChange={e => setFormData({...formData, countedTotal: e.target.value})} className="w-full bg-slate-50 rounded-2xl p-5 text-2xl font-black focus:ring-4 focus:ring-primary/10 transition-all outline-none" placeholder="0.00" autoFocus />
                    </div>
                    <button onClick={handleCreateCount} className="w-full py-5 bg-primary text-white rounded-2xl font-black uppercase text-[10px] tracking-widest shadow-xl">Authorize Signature</button>
                </div>
            </ModalShell>

            {reportToShow && <FinanceReportModal isOpen={!!reportToShow} onClose={() => setReportToShow(null)} record={reportToShow} type="cash" businessProfile={businessProfile} receiptSettings={receiptSettings} />}
        </div>
    );
};

export default CashCountPage;
