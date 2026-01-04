
// @ts-nocheck
import React, { useState, useMemo } from 'react';
import type { BankAccount, BankTransaction, User, ReceiptSettingsData } from '../types';
import Card from './Card';
import ModalShell from './ModalShell';
import EmptyState from './EmptyState';
import { BankIcon, PlusIcon, TransactionIcon } from '../constants';
import { formatCurrency, formatAbbreviatedNumber } from '../lib/utils';

interface BankAccountsPageProps {
    bankAccounts: BankAccount[];
    setBankAccounts: (update: any) => void;
    bankTransactions: BankTransaction[];
    setBankTransactions: (update: any) => void;
    receiptSettings: ReceiptSettingsData;
    currentUser: User;
}

const BankAccountsPage: React.FC<BankAccountsPageProps> = ({ bankAccounts = [], setBankAccounts, bankTransactions = [], setBankTransactions, receiptSettings, currentUser }) => {
    const [isAddModalOpen, setIsAddModalOpen] = useState(false);
    const [isTransferModalOpen, setIsTransferModalOpen] = useState(false);
    const [selectedAccount, setSelectedAccount] = useState<BankAccount | null>(null);

    const [newAccData, setNewAccData] = useState({ bankName: '', accountName: '' });
    const [transferData, setTransferData] = useState({ fromId: '', toId: '', amount: '' });

    const cs = receiptSettings.currencySymbol;

    const handleAddAccount = () => {
        const account: BankAccount = { id: `bank-${Date.now()}`, ...newAccData, balance: 0, status: 'Active' };
        setBankAccounts(prev => [...(prev || []), account]);
        setIsAddModalOpen(false);
    };

    const handleTransfer = () => {
        const amt = parseFloat(transferData.amount);
        if (isNaN(amt) || amt <= 0) return;

        setBankAccounts(prev => prev.map(b => {
            if (b.id === transferData.fromId) return { ...b, balance: b.balance - amt };
            if (b.id === transferData.toId) return { ...b, balance: b.balance + amt };
            return b;
        }));

        setBankTransactions(prev => [{
            id: `bt-${Date.now()}`, date: new Date().toISOString(), bankAccountId: transferData.fromId,
            type: 'transfer_out', amount: -amt, description: `Transfer to node ${transferData.toId}`, userId: currentUser.id
        }, ...prev]);

        setIsTransferModalOpen(false);
    };

    const ledgerItems = useMemo(() => selectedAccount ? bankTransactions.filter(t => t.bankAccountId === selectedAccount.id) : [], [bankTransactions, selectedAccount]);

    return (
        <div className="space-y-8 font-sans">
            <header className="flex justify-between items-end px-2">
                <div>
                    <h1 className="text-3xl font-black text-slate-900 dark:text-white uppercase tracking-tighter">Bank Nodes</h1>
                    <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest mt-1">Enterprise liquidity distribution grid</p>
                </div>
                <div className="flex gap-3">
                    <button onClick={() => setIsTransferModalOpen(true)} className="px-6 py-2.5 bg-white border border-slate-100 rounded-xl text-[9px] font-black uppercase tracking-widest">Internal Transfer</button>
                    <button onClick={() => setIsAddModalOpen(true)} className="bg-primary text-white px-8 py-2.5 rounded-xl font-black uppercase text-[10px] shadow-xl active:scale-95 transition-all">+ Enroll Bank</button>
                </div>
            </header>

            <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
                <div className="lg:col-span-2 grid grid-cols-1 sm:grid-cols-2 gap-6">
                    {bankAccounts.map(account => (
                        <button key={account.id} onClick={() => setSelectedAccount(account)} className={`text-left p-8 rounded-[3rem] border-2 transition-all ${selectedAccount?.id === account.id ? 'bg-primary/5 border-primary shadow-xl' : 'bg-white border-slate-50'}`}>
                            <div className="p-3 bg-slate-50 rounded-2xl w-fit mb-8"><BankIcon className="w-6 h-6 text-slate-400" /></div>
                            <h3 className="text-xl font-black uppercase tracking-tighter">{account.bankName}</h3>
                            <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest mt-1">{account.accountName}</p>
                            <div className="mt-10 pt-8 border-t">
                                <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest">Yield Balance</p>
                                <p className="text-3xl font-black tabular-nums">{cs}{account.balance.toLocaleString()}</p>
                            </div>
                        </button>
                    ))}
                    {bankAccounts.length === 0 && <EmptyState icon={<BankIcon />} title="No Nodes Found" />}
                </div>

                <Card title="Node Ledger" className="h-fit">
                    <div className="space-y-4 max-h-[500px] overflow-y-auto no-scrollbar">
                        {ledgerItems.map(t => (
                            <div key={t.id} className="p-4 bg-slate-50 rounded-2xl flex justify-between items-center border border-slate-100">
                                <div>
                                    <p className="text-[10px] font-black uppercase text-slate-900">{t.type.replace('_', ' ')}</p>
                                    <p className="text-[8px] font-bold text-slate-400 uppercase">{new Date(t.date).toLocaleDateString()}</p>
                                </div>
                                <p className={`text-sm font-black tabular-nums ${t.amount > 0 ? 'text-emerald-600' : 'text-rose-600'}`}>{t.amount > 0 ? '+' : ''}{cs}{Math.abs(t.amount).toFixed(2)}</p>
                            </div>
                        ))}
                        {ledgerItems.length === 0 && <p className="text-center py-10 text-[10px] font-black uppercase text-slate-300 italic tracking-widest">Ledger Clear</p>}
                    </div>
                </Card>
            </div>

            <ModalShell isOpen={isAddModalOpen} onClose={() => setIsAddModalOpen(false)} title="Enroll Bank Node">
                <div className="space-y-6 p-2">
                    <input type="text" placeholder="Bank Name" value={newAccData.bankName} onChange={e => setNewAccData({...newAccData, bankName: e.target.value})} className="w-full bg-slate-50 rounded-2xl p-4 text-sm font-bold outline-none" />
                    <input type="text" placeholder="Account Description" value={newAccData.accountName} onChange={e => setNewAccData({...newAccData, accountName: e.target.value})} className="w-full bg-slate-50 rounded-2xl p-4 text-sm font-bold outline-none" />
                    <button onClick={handleAddAccount} className="w-full py-5 bg-primary text-white rounded-2xl font-black uppercase text-[10px] shadow-xl">Authorize Node</button>
                </div>
            </ModalShell>

            <ModalShell isOpen={isTransferModalOpen} onClose={() => setIsTransferModalOpen(false)} title="Internal Grid Shift">
                <div className="space-y-6 p-2">
                    <div className="grid grid-cols-2 gap-4">
                        <select value={transferData.fromId} onChange={e => setTransferData({...transferData, fromId: e.target.value})} className="w-full bg-slate-50 rounded-2xl p-4 text-[10px] font-black uppercase outline-none">
                            <option value="">Source Node...</option>
                            {bankAccounts.map(b => <option key={b.id} value={b.id}>{b.accountName}</option>)}
                        </select>
                        <select value={transferData.toId} onChange={e => setTransferData({...transferData, toId: e.target.value})} className="w-full bg-slate-50 rounded-2xl p-4 text-[10px] font-black uppercase outline-none">
                            <option value="">Target Node...</option>
                            {bankAccounts.map(b => <option key={b.id} value={b.id}>{b.accountName}</option>)}
                        </select>
                    </div>
                    <input type="number" placeholder="Transfer Amount" value={transferData.amount} onChange={e => setTransferData({...transferData, amount: e.target.value})} className="w-full bg-slate-50 rounded-2xl p-6 text-2xl font-black outline-none" />
                    <button onClick={handleTransfer} className="w-full py-5 bg-slate-900 text-white rounded-2xl font-black uppercase text-[10px] shadow-xl">Commit Transfer</button>
                </div>
            </ModalShell>
        </div>
    );
};

export default BankAccountsPage;
