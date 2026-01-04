
// @ts-nocheck
import React, { useState, useEffect, useRef, useMemo } from 'react';
import { AIIcon, SearchIcon } from '../constants';
import type { User, Sale, Product, Expense, Customer, ExpenseRequest, CashCount, GoodsCosting, GoodsReceiving, AnomalyAlert, BusinessSettingsData, ReceiptSettingsData, AppPermissions, AppNotification } from '../types';

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
    const scrollRef = useRef<HTMLDivElement>(null);

    const contextStr = useMemo(() => {
        const cs = receiptSettings?.currencySymbol || '$';
        let str = `[FINTAB OS CONTEXT: ${receiptSettings?.businessName || 'Active Node'}]\n`;
        str += `- Operator: ${currentUser.name} (${currentUser.role})\n`;
        str += `- Inventory Size: ${products?.length || 0} items\n`;
        const rev = (sales || []).filter(s => s.status === 'completed').reduce((s, x) => s + (x.total || 0), 0);
        str += `- Lifetime Revenue: ${cs}${rev.toFixed(2)}\n`;
        str += `\n[TOP PRODUCTS]\n` + (products || []).slice(0, 5).map(p => `- ${p.name}: ${p.stock} in stock`).join('\n');
        return str;
    }, [sales, products, receiptSettings, currentUser]);

    useEffect(() => {
        if (messages.length === 0) {
            setMessages([{ role: 'model', text: "Intelligence Node Initialized. Secure backend bridge active. How can I assist with your operations today?", type: 'success' }]);
        }
    }, []);

    const handleSend = async () => {
        const operatorInput = input.trim();
        if (!operatorInput || isLoading) return;
        
        setMessages(prev => [...prev, { role: 'user', text: operatorInput }]);
        setInput('');
        setIsLoading(true);

        try {
            const prompt = `SYSTEM CONTEXT:\n${contextStr}\n\nOPERATOR INSTRUCTION: ${operatorInput}\n\nAct as the FinTab OS Intelligence Core. Provide concise, technical, and professional advice for terminal operations.`;

            const response = await fetch("/api/gemini", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ prompt }),
            });

            if (!response.ok) {
                const errorData = await response.json();
                throw new Error(errorData.error || "Backend Node Failure");
            }
            
            const data = await response.json();
            const finalResponseText = data.text || "Communication protocol timed out. No data received.";

            setMessages(prev => [...prev, { role: 'model', text: finalResponseText.trim() }]);
        } catch (error) {
            console.error("AI Communication Breach:", error);
            setMessages(prev => [...prev, { 
                role: 'model', 
                text: `Protocol Error: ${error.message || "Intelligence node handshake failed."}`, 
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
        <div className="flex flex-col h-[calc(100vh-12rem)] bg-slate-50 dark:bg-gray-950 rounded-[3rem] shadow-2xl border border-slate-200 dark:border-gray-800 overflow-hidden font-sans relative">
            <header className="px-10 py-8 border-b dark:border-gray-800 bg-white/80 dark:bg-gray-900/80 backdrop-blur-xl flex items-center justify-between z-20">
                <div className="flex items-center gap-6">
                    <div className="bg-slate-900 p-4 rounded-[1.5rem] text-primary shadow-2xl relative">
                        <AIIcon className="w-8 h-8" />
                        <div className="absolute -top-1 -right-1 w-4 h-4 bg-emerald-500 border-4 border-white dark:border-gray-900 rounded-full animate-pulse"></div>
                    </div>
                    <div>
                        <h2 className="text-2xl font-black uppercase tracking-tighter text-slate-900 dark:text-white">Intelligence Node</h2>
                        <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest mt-1">Status: Secure Backend Bridge</p>
                    </div>
                </div>
            </header>

            <main className="flex-1 overflow-y-auto p-8 sm:p-10 space-y-10 custom-scrollbar relative z-10">
                {messages.map((m, i) => (
                    <div key={i} className={`flex ${m.role === 'user' ? 'justify-end' : 'justify-start'} animate-fade-in`}>
                        <div className={`max-w-[85%] p-6 rounded-[2.5rem] shadow-sm ${
                            m.role === 'user' 
                                ? 'bg-primary text-white rounded-br-none shadow-xl shadow-primary/20' 
                                : m.type === 'error'
                                    ? 'bg-rose-50 dark:bg-rose-950/30 border-2 border-rose-100 dark:border-rose-900/30 text-rose-700 dark:text-rose-400 rounded-bl-none'
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

            <footer className="p-8 sm:p-10 border-t dark:border-gray-800 bg-white dark:bg-gray-950 z-20">
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
                            placeholder="Instruct the system intelligence..."
                            className="w-full bg-slate-50 dark:bg-gray-900 border-2 border-transparent focus:border-primary/20 rounded-3xl pl-16 pr-8 py-5 text-sm font-bold text-slate-900 dark:text-white placeholder-slate-400 shadow-inner transition-all outline-none"
                        />
                    </div>
                    <button 
                        onClick={handleSend}
                        disabled={isLoading || !input.trim()}
                        className="bg-primary text-white px-10 sm:px-14 rounded-3xl font-black uppercase text-[11px] tracking-[0.3em] shadow-2xl shadow-primary/30 hover:bg-blue-700 active:scale-95 transition-all disabled:opacity-30 disabled:grayscale flex-shrink-0"
                    >
                        {isLoading ? 'Syncing...' : 'Send'}
                    </button>
                </div>
            </footer>
        </div>
    );
};

export default AIAssistant;
