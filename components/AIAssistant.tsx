
// @ts-nocheck
import React, { useState, useEffect, useRef, useMemo } from 'react';
import { GoogleGenAI, Type } from "@google/genai";
import { formatCurrency, getStoredItem } from '../lib/utils';
import { AIIcon, CloseIcon, PlusIcon, WarningIcon } from '../constants';
import type { User, Sale, Product, Expense, Customer, ExpenseRequest, CashCount, GoodsCosting, GoodsReceiving, AnomalyAlert, BusinessSettingsData, ReceiptSettingsData, AppPermissions, AppNotification } from '../types';
import { hasAccess } from '../lib/permissions';
import { notify } from './Toast';

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
    setProducts: (products: Product[]) => void;
    setSales: (sales: Sale[]) => void;
    createNotification: (targetUserId: string, title: string, message: string, type: string, link: string) => void;
    notifications: AppNotification[];
}

const AIAssistant: React.FC<AIAssistantProps> = ({
    currentUser, sales, products, expenses, customers, users,
    expenseRequests, cashCounts, goodsCosting, goodsReceiving,
    anomalyAlerts, businessSettings, lowStockThreshold, t,
    receiptSettings, permissions, setProducts, setSales, createNotification, notifications
}) => {
    const [messages, setMessages] = useState<{ role: 'user' | 'model' | 'system', text: string, type?: 'anomaly' }[]>([]);
    const [input, setInput] = useState('');
    const [isLoading, setIsLoading] = useState(false);
    const [isAuditing, setIsAuditing] = useState(false);
    const scrollRef = useRef<HTMLDivElement>(null);

    // SYSTEM TOOL DEFINITIONS (AGENTIC ACTIONS)
    const tools = [
        {
            functionDeclarations: [
                {
                    name: 'adjust_stock',
                    description: 'Adjust the stock levels for a specific product in the inventory.',
                    parameters: {
                        type: Type.OBJECT,
                        properties: {
                            productId: { type: Type.STRING, description: 'The unique identifier of the product.' },
                            quantity: { type: Type.NUMBER, description: 'Number of units to add or remove (negative to remove).' },
                            reason: { type: Type.STRING, description: 'The rationale for the adjustment.' }
                        },
                        required: ['productId', 'quantity', 'reason']
                    }
                },
                {
                    name: 'issue_notification',
                    description: 'Send a high-priority system notification to a user or node.',
                    parameters: {
                        type: Type.OBJECT,
                        properties: {
                            targetUserId: { type: Type.STRING, description: 'The user ID to receive the alert.' },
                            title: { type: Type.STRING },
                            message: { type: Type.STRING },
                            priority: { type: Type.STRING, enum: ['info', 'warning', 'error', 'success'] }
                        },
                        required: ['targetUserId', 'title', 'message', 'priority']
                    }
                }
            ]
        }
    ];

    const contextStr = useMemo(() => {
        const cs = receiptSettings?.currencySymbol || '$';
        let str = `[FINTAB OS CONTEXT: ${receiptSettings?.businessName || 'Business Portal'}]\n`;
        str += `- Active Personnel: ${users?.length || 0} units\n`;
        str += `- Customer Registry: ${customers?.length || 0} identities\n`;
        const totalRev = (sales || []).filter(s => s.status === 'completed').reduce((s, x) => s + x.total, 0);
        str += `\n[FINANCIALS]\n- Revenue: ${cs}${totalRev.toFixed(2)}\n`;
        str += `\n[INVENTORY SKUS]\n` + (products || []).slice(0, 10).map(p => `- ${p.name} (ID: ${p.id}): ${p.stock} units, Price: ${cs}${p.price}`).join('\n');
        return str;
    }, [sales, products, users, customers, receiptSettings]);

    // ANOMALY SCAN (FEATURE #4)
    useEffect(() => {
        const runSecurityAudit = async () => {
            if (isAuditing) return;
            setIsAuditing(true);
            
            try {
                const ai = new GoogleGenAI({ apiKey: process.env.API_KEY });
                const recentSales = (sales || []).slice(0, 50).map(s => ({ id: s.id, total: s.total, status: s.status, user: s.userId }));
                const staffRates = (users || []).map(u => ({ id: u.id, name: u.name, role: u.role, type: u.type }));

                const auditPrompt = `Perform a security audit on this POS operational data. Look for:
                1. High refund/rejection patterns by specific staff members.
                2. Unusual transaction values.
                3. Operational discrepancies.
                
                Data:
                Sales History: ${JSON.stringify(recentSales)}
                Staff Roster: ${JSON.stringify(staffRates)}
                
                Return a concise summary of any anomalies found or state "Status: Nominal" if everything looks standard.`;

                const response = await ai.models.generateContent({
                    model: 'gemini-3-pro-preview',
                    contents: auditPrompt,
                    config: { systemInstruction: "You are the FinTab Security Audit Node. Be blunt, data-driven, and brief." }
                });

                if (response.text && !response.text.includes("Nominal")) {
                    setMessages(prev => [{ role: 'system', text: `SECURITY ALERT: ${response.text}`, type: 'anomaly' }, ...prev]);
                }
            } catch (e) {
                console.error("Audit Protocol Interrupted", e);
            } finally {
                setIsAuditing(false);
            }
        };

        if (messages.length === 0) runSecurityAudit();
    }, [sales, users]);

    const handleSend = async () => {
        if (!input.trim() || isLoading) return;
        
        const currentInput = input;
        setMessages(prev => [...prev, { role: 'user', text: currentInput }]);
        setInput('');
        setIsLoading(true);

        try {
            const ai = new GoogleGenAI({ apiKey: process.env.API_KEY });
            
            const response = await ai.models.generateContent({
                model: 'gemini-3-pro-preview',
                contents: `Context:\n${contextStr}\n\nUser Action: ${currentInput}`,
                config: {
                    tools: tools,
                    systemInstruction: "You are the FinTab Intelligence Agent. You can perform actions on inventory and issue alerts. When a user asks to change stock or notify someone, use your tools. Otherwise, analyze the provided context."
                }
            });

            // Handle Function Calls (FEATURE #3)
            if (response.functionCalls) {
                for (const fc of response.functionCalls) {
                    if (fc.name === 'adjust_stock') {
                        const { productId, quantity, reason } = fc.args;
                        const product = products.find(p => p.id === productId);
                        if (product) {
                            const newStock = (product.stock || 0) + quantity;
                            const updated = products.map(p => p.id === productId ? { 
                                ...p, 
                                stock: newStock,
                                stockHistory: [{
                                    date: new Date().toISOString(),
                                    userId: currentUser.id,
                                    type: quantity > 0 ? 'add' : 'remove',
                                    quantity: Math.abs(quantity),
                                    reason: `AI Action: ${reason}`,
                                    newStockLevel: newStock
                                }, ...(p.stockHistory || [])]
                            } : p);
                            setProducts(updated);
                            setMessages(prev => [...prev, { role: 'model', text: `AUTHORIZED: Stock for ${product.name} updated to ${newStock} units. Reason: ${reason}` }]);
                        }
                    } else if (fc.name === 'issue_notification') {
                        const { targetUserId, title, message, priority } = fc.args;
                        createNotification(targetUserId, title, message, priority, '/dashboard');
                        setMessages(prev => [...prev, { role: 'model', text: `PROTOCOL: Alert dispatched to target node ${targetUserId}.` }]);
                    }
                }
            } else if (response.text) {
                setMessages(prev => [...prev, { role: 'model', text: response.text }]);
            }
        } catch (error) {
            console.error("AI Node Connection Failure:", error);
            setMessages(prev => [...prev, { role: 'model', text: "Protocol Error: Intelligence node connection failed. Verify authorization." }]);
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
                        <div className="flex items-center gap-2 mt-1">
                            <span className={`w-1.5 h-1.5 rounded-full ${isAuditing ? 'bg-amber-500 animate-pulse' : 'bg-emerald-500'}`}></span>
                            <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">{isAuditing ? 'Auditing Ledger...' : 'Intelligence Node Active'}</p>
                        </div>
                    </div>
                </div>
            </header>

            <main className="flex-1 overflow-y-auto p-6 space-y-6 custom-scrollbar bg-slate-50/30 dark:bg-gray-950/30">
                {messages.length === 0 && !isAuditing && (
                    <div className="h-full flex flex-col items-center justify-center text-center opacity-30">
                        <AIIcon className="w-16 h-16 mb-4" />
                        <p className="text-sm font-black uppercase tracking-[0.4em]">Awaiting Instruction</p>
                    </div>
                )}
                {messages.map((m, i) => (
                    <div key={i} className={`flex ${m.role === 'user' ? 'justify-end' : 'justify-start'}`}>
                        <div className={`max-w-[85%] p-4 rounded-3xl ${
                            m.role === 'user' ? 'bg-primary text-white rounded-br-none shadow-lg' : 
                            m.type === 'anomaly' ? 'bg-rose-50 dark:bg-rose-950/20 border border-rose-200 dark:border-rose-900/40 text-rose-700 dark:text-rose-300 rounded-bl-none italic' :
                            'bg-white dark:bg-gray-800 text-slate-900 dark:text-white rounded-bl-none shadow-sm border border-slate-100 dark:border-gray-700'
                        }`}>
                            {m.type === 'anomaly' && <WarningIcon className="w-4 h-4 mb-2" />}
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

            <footer className="p-6 border-t dark:border-gray-800 bg-white dark:bg-gray-900">
                <div className="flex gap-4">
                    <input 
                        type="text" 
                        value={input}
                        onChange={(e) => setInput(e.target.value)}
                        onKeyDown={(e) => e.key === 'Enter' && handleSend()}
                        placeholder="Try: 'Notify Owner about low stock' or 'Adjust stock for IPH-15P to 20 units'..."
                        className="flex-1 bg-slate-50 dark:bg-gray-950 border-none rounded-2xl px-6 py-4 text-sm font-bold text-slate-900 dark:text-white placeholder-slate-400 shadow-sm focus:ring-4 focus:ring-primary/10 transition-all outline-none caret-primary"
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
