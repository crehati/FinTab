
// @ts-nocheck
import React, { useState, useEffect, useRef, useMemo } from 'react';
import { GoogleGenAI, Type } from "@google/genai";
import { formatCurrency, getStoredItem } from '../lib/utils';
import { AIIcon, CloseIcon, PlusIcon, WarningIcon, SearchIcon } from '../constants';
import type { User, Sale, Product, Expense, Customer, ExpenseRequest, CashCount, GoodsCosting, GoodsReceiving, AnomalyAlert, BusinessSettingsData, ReceiptSettingsData, AppPermissions, AppNotification } from '../types';
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
    const [messages, setMessages] = useState<{ role: 'user' | 'model' | 'system', text: string, type?: 'anomaly' | 'error' | 'success' }[]>([]);
    const [input, setInput] = useState('');
    const [isLoading, setIsLoading] = useState(false);
    const [isAuditing, setIsAuditing] = useState(false);
    const scrollRef = useRef<HTMLDivElement>(null);

    const API_KEY = process.env.API_KEY;

    // Agentic Toolset for FinTab OS
    const tools = useMemo(() => [
        {
            functionDeclarations: [
                {
                    name: 'adjust_stock',
                    description: 'Directly modify inventory levels for a product.',
                    parameters: {
                        type: Type.OBJECT,
                        properties: {
                            productId: { type: Type.STRING, description: 'The product ID or SKU.' },
                            quantity: { type: Type.NUMBER, description: 'Amount to change (positive or negative).' },
                            reason: { type: Type.STRING, description: 'Rationale for the manual shift.' }
                        },
                        required: ['productId', 'quantity', 'reason']
                    }
                }
            ]
        }
    ], []);

    const contextStr = useMemo(() => {
        const cs = receiptSettings?.currencySymbol || '$';
        let str = `[FINTAB OS CONTEXT: ${receiptSettings?.businessName || 'Active Node'}]\n`;
        str += `- Operator: ${currentUser.name} (${currentUser.role})\n`;
        str += `- Inventory Size: ${products?.length || 0} items\n`;
        const rev = (sales || []).filter(s => s.status === 'completed').reduce((s, x) => s + (x.total || 0), 0);
        str += `- Lifetime Revenue: ${cs}${rev.toFixed(2)}\n`;
        str += `\n[LEDGER DATA]\n` + (products || []).slice(0, 10).map(p => `- ${p.name}: ${p.stock} units @ ${cs}${p.price}`).join('\n');
        return str;
    }, [sales, products, receiptSettings, currentUser]);

    // Cold Boot Sequence
    useEffect(() => {
        if (messages.length === 0) {
            setMessages([{ role: 'model', text: "Intelligence Node Initialized. Systems nominal. How can I assist with your terminal logic today?", type: 'success' }]);
        }
    }, []);

    const handleSend = async () => {
        if (!input.trim() || isLoading) return;
        
        const operatorInput = input;
        setMessages(prev => [...prev, { role: 'user', text: operatorInput }]);
        setInput('');
        setIsLoading(true);

        if (!API_KEY || API_KEY.length < 5) {
            setMessages(prev => [...prev, { 
                role: 'model', 
                text: "CRITICAL FAULT: API Key not detected in production environment. Verify Vercel secrets and rebuild node.", 
                type: 'error' 
            }]);
            setIsLoading(false);
            return;
        }

        try {
            const ai = new GoogleGenAI({ apiKey: API_KEY });
            const response = await ai.models.generateContent({
                model: 'gemini-3-pro-preview',
                contents: [
                    { text: `OS CONTEXT:\n${contextStr}` },
                    { text: `OPERATOR CMD: ${operatorInput}` }
                ],
                config: {
                    tools: tools,
                    systemInstruction: "You are the FinTab POS Intelligence core. Be technical, efficient, and proactive. Use the adjust_stock tool if the operator asks to change inventory levels."
                }
            });

            if (response.functionCalls && response.functionCalls.length > 0) {
                for (const fc of response.functionCalls) {
                    if (fc.name === 'adjust_stock') {
                        const { productId, quantity, reason } = fc.args;
                        const product = products.find(p => p.id === productId || p.sku === productId || p.name === productId);
                        if (product) {
                            const nextStock = (product.stock || 0) + quantity;
                            const updated = products.map(p => p.id === product.id ? { ...p, stock: nextStock } : p);
                            setProducts(updated);
                            setMessages(prev => [...prev, { role: 'model', text: `PROTOCOL SYNC: Authorized ${quantity} unit shift for "${product.name}". New Balance: ${nextStock}. Rationale: ${reason}.` }]);
                            notify("Inventory logic updated by AI", "success");
                        } else {
                            setMessages(prev => [...prev, { role: 'model', text: `SYNC FAILURE: Identifer "${productId}" not found in current ledger.` }]);
                        }
                    }
                }
            } else if (response.text) {
                setMessages(prev => [...prev, { role: 'model', text: response.text }]);
            }
        } catch (error) {
            console.error("AI Node Breach:", error);
            setMessages(prev => [...prev, { 
                role: 'model', 
                text: `Protocol Error: Intelligence node connection failed. Ensure your API Key is correctly set in the environment and that the model 'gemini-3-pro-preview' is accessible.`, 
                type: 'error' 
            }]);
        } finally {
            setIsLoading(false);
        }
    };

    useEffect(() => {
        scrollRef.current?.scrollIntoView({ behavior: 'smooth' });
    }, [messages, isLoading]);

    return (
        <div className="flex flex-col h-[calc(100vh-14rem)] bg-slate-50 dark:bg-gray-950 rounded-[3rem] shadow-2xl border border-slate-200 dark:border-gray-800 overflow-hidden font-sans relative">
            {/* Telemetry Header */}
            <header className="px-10 py-8 border-b dark:border-gray-800 bg-white/80 dark:bg-gray-900/80 backdrop-blur-xl flex items-center justify-between z-20">
                <div className="flex items-center gap-6">
                    <div className="bg-slate-900 p-4 rounded-[1.5rem] text-primary shadow-2xl relative">
                        <AIIcon className="w-8 h-8" />
                        <div className="absolute -top-1 -right-1 w-4 h-4 bg-emerald-500 border-4 border-white dark:border-gray-900 rounded-full animate-pulse"></div>
                    </div>
                    <div>
                        <h2 className="text-2xl font-black uppercase tracking-tighter text-slate-900 dark:text-white">OS Intelligence Node</h2>
                        <div className="flex items-center gap-2 mt-1">
                            <span className="text-[9px] font-black text-slate-400 uppercase tracking-widest">Protocol Version: 3.1.Pro-Vercel</span>
                        </div>
                    </div>
                </div>
                <div className="hidden md:flex items-center gap-4 bg-slate-50 dark:bg-gray-800 px-6 py-2 rounded-full border dark:border-gray-700">
                    <p className="text-[9px] font-black uppercase tracking-widest text-slate-400">Status:</p>
                    <span className="text-[9px] font-black text-emerald-500 uppercase tracking-widest">Active & Synced</span>
                </div>
            </header>

            {/* Content Stream */}
            <main className="flex-1 overflow-y-auto p-10 space-y-10 custom-scrollbar relative z-10">
                {messages.map((m, i) => (
                    <div key={i} className={`flex ${m.role === 'user' ? 'justify-end' : 'justify-start'} animate-fade-in`}>
                        <div className={`max-w-[85%] p-6 rounded-[2.5rem] shadow-sm ${
                            m.role === 'user' 
                                ? 'bg-primary text-white rounded-br-none shadow-xl shadow-primary/20' 
                                : m.type === 'error'
                                    ? 'bg-rose-50 dark:bg-rose-950/30 border-2 border-rose-100 dark:border-rose-900/30 text-rose-700 dark:text-rose-400 rounded-bl-none'
                                    : m.type === 'success'
                                        ? 'bg-emerald-50 dark:bg-emerald-950/30 border-2 border-emerald-100 dark:border-emerald-900/30 text-emerald-700 dark:text-emerald-400 rounded-bl-none'
                                        : 'bg-white dark:bg-gray-900 text-slate-800 dark:text-slate-200 rounded-bl-none border border-slate-200 dark:border-gray-800 shadow-xl'
                        }`}>
                            <div className="flex items-start gap-4">
                                {m.role === 'model' && <AIIcon className="w-5 h-5 mt-1 flex-shrink-0 opacity-40" />}
                                <p className="text-sm font-bold leading-relaxed whitespace-pre-wrap tracking-tight uppercase">{m.text}</p>
                            </div>
                        </div>
                    </div>
                ))}
                
                {isLoading && (
                    <div className="flex justify-start animate-fade-in">
                        <div className="bg-white dark:bg-gray-900 p-8 rounded-[2.5rem] rounded-bl-none border border-slate-200 dark:border-gray-800 shadow-xl">
                            <div className="flex gap-2">
                                <div className="w-2.5 h-2.5 bg-primary rounded-full animate-bounce"></div>
                                <div className="w-2.5 h-2.5 bg-primary rounded-full animate-bounce [animation-delay:0.2s]"></div>
                                <div className="w-2.5 h-2.5 bg-primary rounded-full animate-bounce [animation-delay:0.4s]"></div>
                            </div>
                        </div>
                    </div>
                )}
                <div ref={scrollRef} className="h-4" />
            </main>

            {/* Operator Input */}
            <footer className="p-10 border-t dark:border-gray-800 bg-white dark:bg-gray-950 z-20">
                <div className="flex gap-4">
                    <div className="relative flex-1 group">
                        <div className="absolute inset-y-0 left-6 flex items-center pointer-events-none">
                            <SearchIcon className="w-5 h-5 text-slate-300 group-focus-within:text-primary transition-colors" />
                        </div>
                        <input 
                            type="text" 
                            value={input}
                            onChange={(e) => setInput(e.target.value)}
                            onKeyDown={(e) => e.key === 'Enter' && handleSend()}
                            placeholder="Inquire about sales, inventory, or trends..."
                            className="w-full bg-slate-50 dark:bg-gray-900 border-2 border-transparent focus:border-primary/20 rounded-3xl pl-16 pr-8 py-5 text-sm font-bold text-slate-900 dark:text-white placeholder-slate-400 shadow-inner transition-all outline-none"
                        />
                    </div>
                    <button 
                        onClick={handleSend}
                        disabled={isLoading || !input.trim()}
                        className="bg-primary text-white px-12 rounded-3xl font-black uppercase text-[11px] tracking-[0.3em] shadow-2xl shadow-primary/30 hover:bg-blue-700 active:scale-95 transition-all disabled:opacity-30 disabled:grayscale flex-shrink-0"
                    >
                        {isLoading ? 'Syncing...' : 'Send'}
                    </button>
                </div>
                <div className="mt-4 text-center">
                    <p className="text-[8px] font-black text-slate-300 dark:text-slate-700 uppercase tracking-[0.5em]">Authorized Data Extraction Node • Gemini 3.0 Engine</p>
                </div>
            </footer>
        </div>
    );
};

export default AIAssistant;
