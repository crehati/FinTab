
// @ts-nocheck
import React, { useState, useEffect, useRef, useMemo } from 'react';
import { GoogleGenAI } from "@google/genai";
import { formatCurrency, getStoredItem } from '../lib/utils';
import { AIIcon, CloseIcon, PlusIcon, WarningIcon } from '../constants';
import type { User, Sale, Product, Expense, Customer, ExpenseRequest, CashCount, GoodsCosting, GoodsReceiving, AnomalyAlert, BusinessSettingsData, ReceiptSettingsData, AppPermissions } from '../types';
import { hasAccess } from '../lib/permissions';

interface AIAssistantProps {
    currentUser: User;
    sales: Sale[];
    products: Product[];
    expenses: Expense[];
    customers: Customer[];
    users: User[];
    expenseRequests: ExpenseRequest[];
    cashCounts: CashCount[];
    goodsCosting: GoodsCosting[];
    goodsReceiving: GoodsReceiving[];
    anomalyAlerts: AnomalyAlert[];
    businessSettings: BusinessSettingsData;
    lowStockThreshold: number;
    t: (key: string) => string;
    receiptSettings: ReceiptSettingsData;
    permissions: AppPermissions;
}

const AIAssistant: React.FC<AIAssistantProps> = ({
    currentUser, sales, products, expenses, customers, users,
    expenseRequests, cashCounts, goodsCosting, goodsReceiving,
    anomalyAlerts, businessSettings, lowStockThreshold, t,
    receiptSettings, permissions
}) => {
    const [messages, setMessages] = useState<{ role: 'user' | 'model', text: string }[]>([]);
    const [input, setInput] = useState('');
    const [isLoading, setIsLoading] = useState(false);
    const scrollRef = useRef<HTMLDivElement>(null);

    const contextStr = useMemo(() => {
        const safeSales = sales || [];
        const safeProducts = products || [];
        const safeExpenses = expenses || [];
        const cs = receiptSettings?.currencySymbol || '$';

        let str = `[TERMINAL CONTEXT: ${receiptSettings?.businessName || 'Business Portal'}]\n`;
        str += `- Operator: ${currentUser?.name} (${currentUser?.role})\n`;
        str += `- Active Personnel: ${users?.length || 0} units\n`;
        str += `- Customer Registry: ${customers?.length || 0} identities\n`;

        const totalStock = safeProducts.reduce((s, p) => s + (p.stock || 0), 0);
        const lowStockCount = safeProducts.filter(p => (p.stock || 0) <= lowStockThreshold).length;
        str += `\n[INVENTORY STATUS]\n- SKU Count: ${safeProducts.length}\n- Total Units: ${totalStock}\n- Low Stock Alerts: ${lowStockCount}\n`;

        const totalRev = safeSales.filter(s => s.status === 'completed').reduce((s, x) => s + x.total, 0);
        str += `\n[SALES PERFORMANCE]\n- Total Lifetime Sales: ${safeSales.length}\n- Verified Revenue: ${cs}${totalRev.toFixed(2)}\n`;

        const totalExp = safeExpenses.filter(e => e.status !== 'deleted').reduce((s, e) => s + e.amount, 0);
        str += `\n[EXPENSE LEDGER]\n- Active Debits: ${safeExpenses.length}\n- Total Outflow: ${cs}${totalExp.toFixed(2)}\n`;

        const netProfit = totalRev - totalExp;
        str += `\n[FINANCIAL HEALTH]\n- Current Net Balance: ${cs}${netProfit.toFixed(2)}\n`;

        const activeAlerts = anomalyAlerts?.filter(a => !a.isDismissed).length || 0;
        str += `\n[SECURITY PROTOCOLS]\n- Unresolved Anomalies: ${activeAlerts}\n`;

        if (hasAccess(currentUser, 'COMMISSIONS', 'view_all_commissions', permissions)) {
            const totalComm = safeSales.reduce((s, sale) => s + (sale.commission || 0), 0);
            str += `\n[COMMISSION DATA]\n- Total Staff Yield: ${cs}${totalComm.toFixed(2)}\n`;
        }
        
        return str;
    }, [currentUser, sales, products, expenses, users, customers, anomalyAlerts, receiptSettings, permissions, lowStockThreshold]);

    const handleSend = async () => {
        if (!input.trim() || isLoading) return;
        
        const currentInput = input;
        const newMessages = [...messages, { role: 'user' as const, text: currentInput }];
        setMessages(newMessages);
        setInput('');
        setIsLoading(true);

        try {
            // Initialize Core AI Instance using the required environment key
            const ai = new GoogleGenAI({ apiKey: process.env.API_KEY });
            
            // Simplified contents structure as required by @google/genai SDK for single turn
            const response = await ai.models.generateContent({
                model: 'gemini-3-pro-preview',
                contents: `Context:\n${contextStr}\n\nUser Question: ${currentInput}`,
                config: {
                    systemInstruction: "You are the FinTab Intelligence Agent. Help users analyze their business metrics and operational data. Be professional, data-driven, and concise. If sensitive profit data is requested, assume the operator has clearance."
                }
            });

            if (response && response.text) {
                setMessages(prev => [...prev, { role: 'model', text: response.text }]);
            } else {
                throw new Error("Empty response from model.");
            }
        } catch (error) {
            console.error("AI Node Connection Failure:", error);
            setMessages(prev => [...prev, { role: 'model', text: "Protocol Error: Intelligence node connection failed. Ensure your API Key is correctly set in the environment and that the model 'gemini-3-pro-preview' is accessible." }]);
        } finally {
            setIsLoading(false);
        }
    };

    useEffect(() => {
        scrollRef.current?.scrollIntoView({ behavior: 'smooth' });
    }, [messages]);

    return (
        <div className="flex flex-col h-[calc(100vh-14rem)] bg-white dark:bg-gray-900 rounded-[2.5rem] shadow-xl border border-slate-100 dark:border-gray-800 overflow-hidden font-sans">
            <header className="p-6 border-b dark:border-gray-800 bg-slate-50/50 dark:bg-gray-800/50 flex items-center justify-between">
                <div className="flex items-center gap-4">
                    <div className="bg-primary p-3 rounded-2xl text-white shadow-lg shadow-primary/20"><AIIcon className="w-6 h-6" /></div>
                    <div>
                        <h2 className="text-xl font-black uppercase tracking-tighter">AI Assistant</h2>
                        <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest mt-1">Intelligence Node Active</p>
                    </div>
                </div>
            </header>

            <main className="flex-1 overflow-y-auto p-6 space-y-6 custom-scrollbar">
                {messages.length === 0 && (
                    <div className="h-full flex flex-col items-center justify-center text-center opacity-30">
                        <AIIcon className="w-16 h-16 mb-4" />
                        <p className="text-sm font-black uppercase tracking-[0.4em]">Awaiting Instruction</p>
                    </div>
                )}
                {messages.map((m, i) => (
                    <div key={i} className={`flex ${m.role === 'user' ? 'justify-end' : 'justify-start'}`}>
                        <div className={`max-w-[85%] p-4 rounded-3xl ${m.role === 'user' ? 'bg-primary text-white rounded-br-none' : 'bg-slate-100 dark:bg-gray-800 text-slate-900 dark:text-white rounded-bl-none shadow-sm'}`}>
                            <p className="text-sm font-medium leading-relaxed">{m.text}</p>
                        </div>
                    </div>
                ))}
                {isLoading && (
                    <div className="flex justify-start">
                        <div className="bg-slate-50 dark:bg-gray-800 p-4 rounded-3xl rounded-bl-none animate-pulse">
                            <div className="flex gap-1">
                                <div className="w-1.5 h-1.5 bg-slate-300 rounded-full"></div>
                                <div className="w-1.5 h-1.5 bg-slate-300 rounded-full"></div>
                                <div className="w-1.5 h-1.5 bg-slate-300 rounded-full"></div>
                            </div>
                        </div>
                    </div>
                )}
                <div ref={scrollRef} />
            </main>

            <footer className="p-6 border-t dark:border-gray-800 bg-slate-50/50 dark:bg-gray-800/50">
                <div className="flex gap-4">
                    <input 
                        type="text" 
                        value={input}
                        onChange={(e) => setInput(e.target.value)}
                        onKeyDown={(e) => e.key === 'Enter' && handleSend()}
                        placeholder="Inquire about sales, inventory, or trends..."
                        className="flex-1 bg-white dark:bg-gray-950 border-none rounded-2xl px-6 py-4 text-sm font-bold shadow-sm focus:ring-4 focus:ring-primary/10 transition-all outline-none"
                    />
                    <button 
                        onClick={handleSend}
                        disabled={isLoading || !input.trim()}
                        className="bg-slate-900 dark:bg-primary text-white px-8 rounded-2xl font-black uppercase text-[10px] tracking-widest shadow-xl hover:opacity-90 active:scale-95 transition-all disabled:opacity-30"
                    >
                        Send
                    </button>
                </div>
            </footer>
        </div>
    );
};

export default AIAssistant;
