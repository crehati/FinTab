
import React, { memo, useState } from 'react';
import { NavLink } from 'react-router-dom';
import { TodayIcon, StorefrontIcon, CounterIcon, DirectoryIcon, BriefcaseIcon, CloseIcon, InventoryIcon, DashboardIcon } from '../constants';
import type { CartItem, User, AppPermissions, ModuleKey } from '../types';
import { hasAccess } from '../lib/permissions';

interface BottomNavBarProps {
    t: (key: string) => string;
    cart: CartItem[];
    currentUser: User;
    permissions: AppPermissions;
}

interface TypedNavItem {
    to: string;
    text: string;
    icon?: React.ReactNode;
    module?: ModuleKey;
    action?: string;
    badge?: number;
}

const BottomNavBar: React.FC<BottomNavBarProps> = ({ t, cart, currentUser, permissions }) => {
    const [isMenuOpen, setIsMenuOpen] = useState(false);
    const cartItemCount = cart.reduce((sum, item) => sum + item.quantity, 0);

    // Optimized Tabs for clear visual hierarchy on mobile
    const navItems: TypedNavItem[] = [
        { to: '/dashboard', text: 'Home', icon: <DashboardIcon className="w-6 h-6" /> },
        { to: '/today', text: 'Live', icon: <TodayIcon className="w-6 h-6" />, module: 'REPORTS', action: 'view_sales_reports' },
        { to: '/items', text: 'Assets', icon: <InventoryIcon className="w-6 h-6" />, module: 'SALES', action: 'view_counter' },
        { to: '/counter', text: 'POS', icon: <CounterIcon className="w-6 h-6" />, badge: cartItemCount, module: 'SALES', action: 'view_counter' },
    ];
    
    const filteredNavItems = navItems.filter(item => {
        if (!item.module || !item.action) return true;
        return hasAccess(currentUser, item.module, item.action, permissions);
    });

    const rawFinanceItems: TypedNavItem[] = [
        { to: '/reports', text: 'Global Reports', module: 'REPORTS', action: 'view_sales_reports' },
        { to: '/cash-count', text: 'Daily Cash Audit', module: 'FINANCE', action: 'cash_count_enter' },
        { to: '/goods-costing', text: 'Unit Costing', module: 'FINANCE', action: 'goods_costing_view' },
        { to: '/goods-receiving', text: 'Logistics / Recv', module: 'FINANCE', action: 'goods_receiving_enter' },
        { to: '/transactions', text: 'Vault Ledger', module: 'SALES', action: 'view_transactions' },
    ];

    const financeItems = rawFinanceItems.filter(item => {
        if (!item.module || !item.action) return true;
        return hasAccess(currentUser, item.module, item.action, permissions);
    });

    return (
        <>
            {isMenuOpen && (
                <div className="fixed inset-0 z-[100] flex items-end justify-center p-4 sm:p-6 animate-fade-in font-sans">
                    <div className="absolute inset-0 bg-slate-950/80 backdrop-blur-md" onClick={() => setIsMenuOpen(false)} />
                    <div className="relative w-full max-w-md bg-white dark:bg-gray-900 rounded-[3rem] shadow-[0_-20px_50px_rgba(0,0,0,0.3)] overflow-hidden border border-white/10 animate-scale-in">
                        <header className="p-8 border-b dark:border-gray-800 flex justify-between items-center bg-slate-50/50 dark:bg-gray-800/50">
                            <div>
                                <p className="text-[9px] font-black text-primary uppercase tracking-[0.4em] mb-1">Terminal Nodes</p>
                                <h3 className="text-xl font-black text-slate-900 dark:text-white uppercase tracking-tighter">Finance Hub</h3>
                            </div>
                            <button onClick={() => setIsMenuOpen(false)} className="p-4 bg-white dark:bg-gray-800 rounded-2xl text-slate-400 shadow-sm active:scale-90 transition-all">
                                <CloseIcon className="w-5 h-5" />
                            </button>
                        </header>
                        <div className="p-6 grid grid-cols-1 gap-3 max-h-[60vh] overflow-y-auto no-scrollbar">
                            {financeItems.map(item => (
                                <NavLink
                                    key={item.to}
                                    to={item.to}
                                    onClick={() => setIsMenuOpen(false)}
                                    className={({ isActive }) => 
                                        `flex items-center justify-between p-6 rounded-2xl transition-all active:scale-[0.98] ${
                                            isActive 
                                            ? 'bg-primary text-white shadow-xl shadow-primary/20' 
                                            : 'bg-slate-50 dark:bg-gray-800/50 text-slate-600 dark:text-slate-300 hover:bg-slate-100 border border-slate-100 dark:border-gray-800'
                                        }`
                                    }
                                >
                                    <span className="text-[11px] font-black uppercase tracking-widest">{item.text}</span>
                                    <svg className="w-5 h-5 opacity-40" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
                                        <path strokeLinecap="round" strokeLinejoin="round" d="M9 5l7 7-7 7" />
                                    </svg>
                                </NavLink>
                            ))}
                        </div>
                        <div className="p-4 bg-slate-900">
                             <p className="text-[8px] font-bold text-center text-slate-500 uppercase tracking-[0.4em]">FinTab Authorized Access Only</p>
                        </div>
                    </div>
                </div>
            )}

            <footer className="lg:hidden w-full h-[84px] bg-white/90 dark:bg-gray-900/90 backdrop-blur-2xl border-t border-slate-100 dark:border-white/5 flex z-50 fixed bottom-0 left-0 right-0 shadow-[0_-8px_30px_rgba(0,0,0,0.05)] pb-[env(safe-area-inset-bottom)] px-2 overflow-visible">
                <div className="flex items-center justify-around w-full overflow-visible">
                    {filteredNavItems.map(item => (
                        <NavLink
                            key={item.to}
                            to={item.to}
                            className={({ isActive }) => 
                                `flex flex-col items-center justify-center flex-1 h-full transition-all duration-300 gap-1.5 relative overflow-visible ${
                                    isActive 
                                    ? 'text-primary' 
                                    : 'text-slate-400 dark:text-slate-500 hover:text-slate-600'
                                }`
                            }
                        >
                            <div className="relative overflow-visible flex items-center justify-center transition-transform active:scale-75 duration-200">
                                {item.icon}
                                {item.badge !== undefined && item.badge > 0 && (
                                    <span className="absolute -top-1.5 -right-2 bg-rose-500 text-white text-[8px] font-black min-w-[18px] h-[18px] flex items-center justify-center rounded-full border-2 border-white dark:border-gray-900 shadow-sm">
                                        {item.badge > 99 ? '99+' : item.badge}
                                    </span>
                                )}
                            </div>
                            <span className="text-[9px] font-black uppercase tracking-widest text-center px-1">
                                {item.text}
                            </span>
                            <div className={`absolute top-0 w-12 h-1 bg-primary rounded-b-full transition-all duration-500 ${location.pathname === item.to ? 'opacity-100' : 'opacity-0 scale-x-0'}`}></div>
                        </NavLink>
                    ))}
                    
                    <button
                        onClick={() => setIsMenuOpen(true)}
                        className={`flex flex-col items-center justify-center flex-1 h-full transition-all duration-300 gap-1.5 relative overflow-visible ${
                            isMenuOpen ? 'text-primary' : 'text-slate-400 dark:text-slate-500'
                        }`}
                    >
                        <div className="relative overflow-visible flex items-center justify-center transition-transform active:scale-75 duration-200">
                            <BriefcaseIcon className="w-6 h-6" />
                            {financeItems.length > 0 && (
                                <span className="absolute -top-0.5 -right-0.5 w-2.5 h-2.5 bg-primary rounded-full ring-2 ring-white dark:ring-gray-900 animate-pulse"></span>
                            )}
                        </div>
                        <span className="text-[9px] font-black uppercase tracking-widest text-center px-1">
                            More
                        </span>
                        <div className={`absolute top-0 w-12 h-1 bg-primary rounded-b-full transition-all duration-500 ${isMenuOpen ? 'opacity-100' : 'opacity-0 scale-x-0'}`}></div>
                    </button>
                </div>
            </footer>
        </>
    );
};

export default memo(BottomNavBar);
