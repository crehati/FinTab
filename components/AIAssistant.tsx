
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
    const [messages, setMessages] = useState<{ role: 'user' | 'model' | 'system', text: string, type?: 'anomaly' | 'error' }[]>([]);
    const [input, setInput] = useState('');
    const [isLoading, setIsLoading] = useState(false);
    const [isAuditing, setIsAuditing] = useState(false);
    const scrollRef = useRef<HTMLDivElement>(null);

    // Get the baked-in API key from the build environment
    const API_KEY = process.env.API_KEY;

    // SYSTEM TOOL DEFINITIONS
    const tools = useMemo(() => [
        {
            functionDeclarations: [
                {
                    name: 'adjust_stock',
                    description: 'Modify the physical inventory quantity for a specific asset.',
                    parameters: {
                        type: Type.OBJECT,
                        properties: {
                            productId: { type: Type.STRING, description: 'The unique SKU or Product ID string.' },
                            quantity: { type: Type.NUMBER, description: 'Integer value to adjust by (e.g., -5 for removal, 10 for addition).' },
                            reason: { type: Type.STRING, description: 'The operational rationale for this adjustment.' }
                        },
                        required: ['productId', 'quantity', 'reason']
                    }
                },
                {
                    name: 'issue_notification',
                    description: 'Dispatch a high-priority system alert to another node (user).',
                    parameters: {
                        type: Type.OBJECT,
                        properties: {
                            targetUserId: { type: Type.STRING, description: 'The user ID of the recipient node.' },
                            title: { type: Type.STRING, description: 'Concise alert subject.' },
                            message: { type: Type.STRING, description: 'Detailed alert instructions.' },
                            priority: { type: Type.STRING, enum: ['info', 'warning', 'error', 'success'], description: 'Urgency tier.' }
                        },
                        required: ['targetUserId', 'title', 'message', 'priority']
                    }
                }
            ]
        }
    ], []);

    const contextStr = useMemo(() => {
        const cs = receiptSettings?.currencySymbol || '$';
        let str = `[FINTAB OS CONTEXT: ${receiptSettings?.businessName || 'Active Node'}]\n`;
        str += `- Operator: ${currentUser.name} (Role: ${currentUser.role})\n`;
        str += `- Staff Nodes: ${users?.length || 0}\n`;
        const totalRev = (sales || []).filter(s => s.status === 'completed').reduce((s, x) => s + (x.total || 0), 0);
        str += `\n[FINANCIAL TELEMETRY]\n- Lifetime Revenue: ${cs}${totalRev.toFixed(2)}\n`;
        str += `\n[INVENTORY LEDGER (TOP 10 SKUS)]\n` + (products || []).slice(0, 10).map(p => 
            `- ${p.name} [ID: ${p.id}]: Stock: ${p.stock}, Value: ${cs}${p.price}`
        ).join('\n');
        return str;
    }, [sales, products, users, receiptSettings, currentUser]);

    useEffect(() => {
        const runSecurityAudit = async () => {
            if (isAuditing || !API_KEY) return;
            setIsAuditing(true);
            try {
                const ai = new GoogleGenAI({ apiKey: API_KEY });
                const auditData = {
                    recentSales: (sales || []).slice(0, 20).map(s => ({ id: s.id, total: s.total, status: s.status, staff: s.userId })),
                    staffRoster: (users || []).map(u => ({ id: u.id, role: u.role }))
                };
                const response = await ai.models.generateContent({
                    model: 'gemini-3-pro-preview',
                    contents: `Audit this data for anomalies: ${JSON.stringify(auditData)}. Return one short sentence start with "SECURITY ALERT:" if risk found, else "Status: Nominal".`,
                    config: { systemInstruction: "FinTab Security Audit Layer." }
                });
                if (response.text && !response.text.includes("Nominal")) {
                    setMessages(prev => [{ role: 'system', text: response.text, type: 'anomaly' }, ...prev]);
                }
            } catch (e) {
                console.error("Security Scan Fault:", e);
            } finally {
                setIsAuditing(false);
            }
        };
        if (messages.length === 0 && API_KEY) runSecurityAudit();
    }, [API_KEY, sales, users]);

    const handleSend = async () => {
        if (!input.trim() || isLoading) return;
        
        const currentInput = input;
        setMessages(prev => [...prev, { role: 'user', text: currentInput }]);
        setInput('');

        if (!API_KEY) {
            setMessages(prev => [...prev, { role: 'model', text: "Critical Fault: Intelligence Node Key missing. Please check Vercel environment settings.", type: 'error' }]);
            return;
        }

        setIsLoading(true);

        try {
            const ai = new GoogleGenAI({ apiKey: API_KEY });
            const response = await ai.models.generateContent({
                model: 'gemini-3-pro-preview',
                contents: [
                    { text: `CONTEXT:\n${contextStr}` },
                    { text: `INSTRUCTION: ${currentInput}` }
                ],
                config: {
                    tools: tools,
                    systemInstruction: "You are FinTab Intelligence. Act as an OS agent. Use tools for stock or notifications. Analyze data for queries."
                }
            });

            if (response.functionCalls && response.functionCalls.length > 0) {
                for (const fc of response.functionCalls) {
                    if (fc.name === 'adjust_stock') {
                        const { productId, quantity, reason } = fc.args;
                        const product = products.find(p => p.id === productId || p.sku === productId);
                        if (product) {
                            const newStock = (product.stock || 0) + quantity;
                            const updated = products.map(p => (p.id === product.id) ? { 
                                ...p, 
                                stock: newStock,
                                stockHistory: [{
                                    date: new Date().toISOString(),
                                    userId: currentUser.id,
                                    type: quantity > 0 ? 'add' : 'remove',
                                    quantity: Math.abs(quantity),
                                    reason: `AI Override: ${reason}`,
                                    newStockLevel: newStock
                                }, ...(p.stockHistory || [])]
                            } : p);
                            setProducts(updated);
                            setMessages(prev => [...prev, { role: 'model', text: `PROTOCOL SUCCESS: Adjusted ${product.name} to ${newStock} units.` }]);
                            notify("Grid Synced", "success");
                        }
                    } else if (fc.name === 'issue_notification') {
                        const { targetUserId, title, message, priority } = fc.args;
                        createNotification(targetUserId, title, message, priority, '/dashboard');
                        setMessages(prev => [...prev, { role: 'model', text: `PROTOCOL SUCCESS: Alert dispatched to ${targetUserId}.` }]);
                        notify("Alert Transmitted", "info");
                    }
                }
            } else if (response.text) {
                setMessages(prev => [...prev, { role: 'model', text: response.text }]);
            }
        } catch (error) {
            console.error("AI Communication Failure:", error);
            setMessages(prev => [...prev, { role: 'model', text: "Connectivity Error: Intelligence node handshake failed.", type: 'error' }]);
        } finally {
            setIsLoading(false);
        }
    };

    useEffect(() => {
        scrollRef.current?.scrollIntoView({ behavior: 'smooth' });
    }, [messages, isLoading]);

    return (
        <div className="flex flex-col h-[calc(100vh-14rem)] bg-white dark:bg-gray-950 rounded-[2.5rem] shadow-2xl border border-slate-100 dark:border-gray-800 overflow-hidden font-sans relative">
            <header className="px-8 py-6 border-b dark:border-gray-800 bg-white/80 dark:bg-gray-950/80 backdrop-blur-xl flex items-center justify-between z-20">
                <div className="flex items-center gap-5">
                    <div className="bg-primary p-3.5 rounded-2xl text-white shadow-lg shadow-primary/20">
                        <AIIcon className="w-6 h-6" />
                    </div>
                    <div>
                        <h2 className="text-xl font-black uppercase tracking-tighter text-slate-900 dark:text-white">FinTab Intelligence</h2>
                        <div className="flex items-center gap-2 mt-1.5">
                            <span className={`w-1.5 h-1.5 rounded-full ${isAuditing || isLoading ? 'bg-amber-500 animate-pulse' : 'bg-emerald-500'}`}></span>
                            <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest">
                                {isAuditing ? 'Auditing Ledger...' : isLoading ? 'Processing...' : 'Online & Active'}
                            </p>
                        </div>
                    </div>
                </div>
            </header>

            <main className="flex-1 overflow-y-auto p-8 space-y-8 custom-scrollbar bg-slate-50/10 dark:bg-gray-950/10 relative z-10">
                {messages.length === 0 && !isAuditing && (
                    <div className="h-full flex flex-col items-center justify-center text-center opacity-30 select-none">
                        <AIIcon className="w-20 h-20 mb-6 text-slate-200 dark:text-gray-800" />
                        <p className="text-xs font-black uppercase tracking-[0.5em] text-slate-400">Awaiting Operator Instructions</p>
                    </div>
                )}
                {messages.map((m, i) => (
                    <div key={i} className={`flex ${m.role === 'user' ? 'justify-end' : 'justify-start'} animate-fade-in`}>
                        <div className={`max-w-[85%] p-5 rounded-[2rem] shadow-sm ${
                            m.role === 'user' 
                                ? 'bg-primary text-white rounded-br-none shadow-xl shadow-primary/10' 
                                : m.type === 'anomaly' 
                                    ? 'bg-rose-50 dark:bg-rose-950/20 border-2 border-rose-100 dark:border-rose-900/30 text-rose-700 dark:text-rose-300 rounded-bl-none italic' 
                                    : m.type === 'error'
                                        ? 'bg-rose-600 text-white rounded-bl-none shadow-lg'
                                        : 'bg-white dark:bg-gray-900 text-slate-800 dark:text-slate-200 rounded-bl-none border border-slate-100 dark:border-gray-800 shadow-xl'
                        }`}>
                            <div className="flex items-start gap-4">
                                {m.type === 'anomaly' && <WarningIcon className="w-5 h-5 mt-0.5 flex-shrink-0" />}
                                <p className="text-sm font-medium leading-relaxed whitespace-pre-wrap">{m.text}</p>
                            </div>
                        </div>
                    </div>
                ))}
                {isLoading && (
                    <div className="flex justify-start animate-fade-in">
                        <div className="bg-white dark:bg-gray-900 p-6 rounded-[2rem] rounded-bl-none border border-slate-100 dark:border-gray-800 shadow-xl flex gap-2">
                            <div className="w-2 h-2 bg-primary rounded-full animate-bounce"></div>
                            <div className="w-2 h-2 bg-primary rounded-full animate-bounce [animation-delay:0.2s]"></div>
                            <div className="w-2 h-2 bg-primary rounded-full animate-bounce [animation-delay:0.4s]"></div>
                        </div>
                    </div>
                )}
                <div ref={scrollRef} className="h-1" />
            </main>

            <footer className="p-8 border-t dark:border-gray-800 bg-white dark:bg-gray-950 z-20">
                <div className="flex gap-4">
                    <input 
                        type="text" 
                        value={input}
                        onChange={(e) => setInput(e.target.value)}
                        onKeyDown={(e) => e.key === 'Enter' && handleSend()}
                        placeholder="Instruct the system intelligence..."
                        className="flex-1 bg-slate-50 dark:bg-gray-900 border-none rounded-3xl px-8 py-5 text-sm font-bold text-slate-900 dark:text-white placeholder-slate-400 shadow-inner focus:ring-4 focus:ring-primary/10 transition-all outline-none caret-primary"
                    />
                    <button 
                        onClick={handleSend}
                        disabled={isLoading || !input.trim()}
                        className="bg-slate-900 dark:bg-primary text-white px-10 rounded-3xl font-black uppercase text-[10px] tracking-[0.2em] shadow-2xl shadow-primary/20 hover:opacity-90 active:scale-95 transition-all disabled:opacity-30 disabled:grayscale flex-shrink-0"
                    >
                        Execute
                    </button>
                </div>
            </footer>
        </div>
    );
};

export default AIAssistant;
