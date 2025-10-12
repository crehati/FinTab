import React, { useState, useEffect, useMemo, useRef } from 'react';
import { NavLink } from 'react-router-dom';
import type { User, Sale, Product, Expense, ReceiptSettingsData, AppPermissions } from '../types';
import { formatCurrency } from '../lib/utils';
import { ReportsIcon, WarningIcon, ExpensesIcon, InventoryIcon, AIIcon } from '../constants';
import { hasAccess } from '../lib/permissions';

interface AIAssistantProps {
    currentUser: User;
    sales: Sale[];
    products: Product[];
    expenses: Expense[];
    lowStockThreshold: number;
    t: (key: string) => string;
    receiptSettings: ReceiptSettingsData;
    permissions: AppPermissions;
}

interface Message {
    sender: 'user' | 'ai';
    text: string;
}

const SuggestionCard: React.FC<{ to: string, icon: React.ReactNode, title: string, children: React.ReactNode }> = ({ to, icon, title, children }) => (
    <NavLink to={to} className="bg-white p-4 rounded-xl shadow-md flex flex-col gap-3 hover:shadow-lg hover:scale-[1.02] transition-all duration-200">
        <div className="flex items-center gap-3">
            <div className="bg-primary/10 text-primary p-2 rounded-lg">{icon}</div>
            <h3 className="font-bold text-neutral-dark">{title}</h3>
        </div>
        <div className="text-neutral-medium text-sm flex-grow">{children}</div>
        <div className="text-right font-semibold text-primary text-sm">View →</div>
    </NavLink>
);

const AIAssistant: React.FC<AIAssistantProps> = ({ currentUser, sales, products, expenses, lowStockThreshold, t, receiptSettings, permissions }) => {
    const [messages, setMessages] = useState<Message[]>([]);
    const [userInput, setUserInput] = useState('');
    const [isLoading, setIsLoading] = useState(false);
    const [aiTip, setAiTip] = useState('');
    const [isTipLoading, setIsTipLoading] = useState(true);
    const chatEndRef = useRef<HTMLDivElement>(null);
    const [ai, setAi] = useState<any | null>(undefined); // undefined: initializing, null: failed, object: success

    useEffect(() => {
        // Set initial greeting
        setMessages([{ sender: 'ai', text: `Hi ${currentUser.name.split(' ')[0]}! I'm your personal business assistant. You can ask me anything about your sales, inventory, or for business advice.` }]);
        
        // Dynamically import and initialize the AI client.
        const initializeAi = async () => {
            try {
                const { GoogleGenAI } = await import('@google/genai');
                // This will throw an error in the browser because process.env is not defined, which we will catch.
                const genAI = new GoogleGenAI({ apiKey: process.env.API_KEY });
                setAi(genAI);
            } catch (error) {
                console.warn("AI Initialization failed. This is expected in a browser environment without a build step. AI features will be disabled.", error);
                setAi(null); // Mark initialization as failed
            }
        };

        initializeAi();
    }, [currentUser.name]);
    
    // Effect to fetch AI tip once AI initialization is attempted
    useEffect(() => {
        const fetchTip = async () => {
            if (!ai) return; // ai is initialized and not null
            
            setIsTipLoading(true);
            try {
                const response = await ai.models.generateContent({
                    model: 'gemini-2.5-flash',
                    contents: "Provide a short, actionable business growth tip for a small retail shop owner. Make it encouraging and concise (2-3 sentences max)."
                });
                setAiTip(response.text);
            } catch (error) {
                console.error("Error fetching AI tip:", error);
                setAiTip("Could not fetch a tip right now. Make sure your business is running efficiently!");
            } finally {
                setIsTipLoading(false);
            }
        };

        if (ai === null) { // Explicitly check for failed initialization
            setAiTip("AI Assistant is not configured. AI features are unavailable.");
            setIsTipLoading(false);
        } else if (ai) { // Check if ai object exists
            fetchTip();
        }
        // If ai is undefined, we are still waiting for initialization.
    }, [ai]);

    const getGreeting = () => {
        const hour = new Date().getHours();
        const name = currentUser.name.split(' ')[0];
        if (hour < 12) return `${t('ai.greeting.morning')} ${name}!`;
        if (hour < 18) return `${t('ai.greeting.afternoon')} ${name}!`;
        return `${t('ai.greeting.evening')} ${name}!`;
    };

    // --- Data for suggestions ---
    const todayString = new Date().toISOString().split('T')[0];
    const todaysSales = useMemo(() => sales.filter(sale => new Date(sale.date).toISOString().startsWith(todayString) && sale.status === 'completed'), [sales, todayString]);
    const todaysRevenue = useMemo(() => todaysSales.reduce((sum, sale) => sum + sale.total, 0), [todaysSales]);
    const lowStockProducts = useMemo(() => products.filter(p => p.stock > 0 && p.stock <= lowStockThreshold), [products, lowStockThreshold]);
    const topTodaysProduct = useMemo(() => {
        // FIX: Explicitly typed the accumulator `acc` to resolve an arithmetic operation error.
        const productQuantities = todaysSales.reduce((acc: Record<string, number>, sale) => {
            sale.items.forEach(item => {
                acc[item.product.id] = (acc[item.product.id] || 0) + item.quantity;
            });
            return acc;
        }, {});
        const topEntry = Object.entries(productQuantities).sort(([, qtyA], [, qtyB]) => qtyB - qtyA)[0];
        if (!topEntry) return null;
        const product = products.find(p => p.id === topEntry[0]);
        return product ? { name: product.name, quantity: topEntry[1] } : null;
    }, [todaysSales, products]);
    const hasRecentExpenses = useMemo(() => {
        const oneWeekAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);
        return expenses.some(e => new Date(e.date) > oneWeekAgo);
    }, [expenses]);
    
    // Scroll to bottom of chat
    useEffect(() => {
        chatEndRef.current?.scrollIntoView({ behavior: 'smooth' });
    }, [messages]);

    const handleSendMessage = async (e: React.FormEvent) => {
        e.preventDefault();
        if (!userInput.trim() || isLoading) return;

        const newMessages: Message[] = [...messages, { sender: 'user', text: userInput }];
        setMessages(newMessages);
        const currentInput = userInput;
        setUserInput('');
        setIsLoading(true);

        if (!ai) {
            setMessages([...newMessages, { sender: 'ai', text: "Sorry, the AI assistant is not configured correctly." }]);
            setIsLoading(false);
            return;
        }

        try {
            const roleDescription = currentUser.role === 'Custom' ? currentUser.customRoleName : currentUser.role;
            const response = await ai.models.generateContent({
                model: 'gemini-2.5-flash',
                contents: `You are a helpful assistant in a Point-of-Sale app. The user you are talking to has the role of "${roleDescription}". Keep your answers concise and relevant to their role. Answer the user's question: "${currentInput}"`
            });
            setMessages([...newMessages, { sender: 'ai', text: response.text }]);
        } catch (error) {
            console.error("Chat error:", error);
            setMessages([...newMessages, { sender: 'ai', text: "Sorry, I'm having trouble connecting right now. Please try again in a moment." }]);
        } finally {
            setIsLoading(false);
        }
    };
    
    const canViewReports = hasAccess(currentUser, '/reports', 'view', permissions);
    const canViewInventory = hasAccess(currentUser, '/inventory', 'view', permissions);
    const canViewExpenses = hasAccess(currentUser, '/expenses', 'view', permissions);

    return (
        <div className="space-y-6">
            <h1 className="text-3xl font-bold text-neutral-dark">{getGreeting()}</h1>

            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
                {canViewReports && (
                    <SuggestionCard to="/today" icon={<ReportsIcon />} title={t('ai.suggestion.salesTitle')}>
                        <p className="text-2xl font-bold text-success">{formatCurrency(todaysRevenue, receiptSettings.currencySymbol)}</p>
                        <p>{t('ai.suggestion.salesValue')}</p>
                    </SuggestionCard>
                )}
                {canViewInventory && (
                    <SuggestionCard to="/inventory" icon={<WarningIcon />} title={t('ai.suggestion.stockTitle')}>
                        {lowStockProducts.length > 0 ? (
                            <>
                                <p className="text-2xl font-bold text-warning">{lowStockProducts.length}</p>
                                <p>{t('ai.suggestion.stockValue')}</p>
                            </>
                        ) : (
                            <p className="text-green-600">All items are well-stocked!</p>
                        )}
                    </SuggestionCard>
                )}
                {canViewReports && (
                    <SuggestionCard to="/reports" icon={<InventoryIcon />} title={t('ai.suggestion.topProductTitle')}>
                        {topTodaysProduct ? (
                            <>
                                <p className="text-lg font-bold text-primary truncate">{topTodaysProduct.name}</p>
                                <p>{topTodaysProduct.quantity} {t('ai.suggestion.topProductValue')}</p>
                            </>
                        ) : (
                            <p>No sales recorded yet today.</p>
                        )}
                    </SuggestionCard>
                )}
                
                {(!hasRecentExpenses && canViewExpenses) ? (
                    <SuggestionCard to="/expenses" icon={<ExpensesIcon />} title={t('ai.suggestion.expensesTitle')}>
                        <p>{t('ai.suggestion.expensesValue')}</p>
                    </SuggestionCard>
                ) : (
                     <div className="bg-white p-4 rounded-xl shadow-md flex flex-col gap-3">
                        <div className="flex items-center gap-3">
                            <div className="bg-primary/10 text-primary p-2 rounded-lg"><AIIcon /></div>
                            <h3 className="font-bold text-neutral-dark">{t('ai.suggestion.aiTipTitle')}</h3>
                        </div>
                        <div className="text-neutral-medium text-sm flex-grow">
                            {isTipLoading ? <p className="animate-pulse">Fetching today's tip...</p> : <p>{aiTip}</p>}
                        </div>
                    </div>
                )}
            </div>
            
            <div className="bg-white rounded-xl shadow-md p-4">
                <h2 className="text-xl font-bold text-neutral-dark mb-4">{t('ai.title')}</h2>
                <div className="h-[40vh] bg-gray-50 rounded-lg overflow-y-auto p-4 flex flex-col gap-4">
                    {messages.map((msg, index) => (
                        <div key={index} className={`flex ${msg.sender === 'user' ? 'justify-end' : 'justify-start'}`}>
                            <div className={`max-w-md p-3 rounded-xl ${msg.sender === 'user' ? 'bg-primary text-white' : 'bg-gray-200 text-neutral-dark'}`}>
                                <p className="text-sm" style={{ whiteSpace: 'pre-wrap' }}>{msg.text}</p>
                            </div>
                        </div>
                    ))}
                    {isLoading && (
                        <div className="flex justify-start">
                            <div className="max-w-md p-3 rounded-xl bg-gray-200 text-neutral-dark">
                                <p className="text-sm animate-pulse">Thinking...</p>
                            </div>
                        </div>
                    )}
                    <div ref={chatEndRef} />
                </div>
                <form onSubmit={handleSendMessage} className="mt-4 flex gap-2">
                    <input
                        type="text"
                        value={userInput}
                        onChange={e => setUserInput(e.target.value)}
                        placeholder={ai === null ? "AI is disabled" : "Ask me anything..."}
                        className="flex-grow p-3 bg-white border border-gray-300 rounded-lg shadow-sm text-neutral-dark placeholder-gray-400"
                        disabled={isLoading || ai === null}
                    />
                    <button type="submit" className="bg-primary text-white px-6 py-3 rounded-lg font-semibold hover:bg-blue-700 disabled:bg-gray-400" disabled={isLoading || ai === null}>
                        Send
                    </button>
                </form>
            </div>
        </div>
    );
};

export default AIAssistant;