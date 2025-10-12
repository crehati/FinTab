import React, { memo } from 'react';
import { NavLink } from 'react-router-dom';
import { ReportsIcon, TodayIcon, StorefrontIcon, CounterIcon, DirectoryIcon } from '../constants';
import type { CartItem, User, AppPermissions } from '../types';
import { hasAccess } from '../lib/permissions';

interface BottomNavBarProps {
    t: (key: string) => string;
    cart: CartItem[];
    currentUser: User;
    permissions: AppPermissions;
}

const BottomNavBar: React.FC<BottomNavBarProps> = ({ t, cart, currentUser, permissions }) => {
    const cartItemCount = cart.reduce((sum, item) => sum + item.quantity, 0);

    const navItems = [
        { to: '/today', text: t('bottomNav.today'), icon: <TodayIcon /> },
        { to: '/reports', text: t('bottomNav.reports'), icon: <ReportsIcon /> },
        { to: '/shopfront', text: t('bottomNav.items'), icon: <StorefrontIcon /> },
        { to: '/counter', text: t('counter.title'), icon: <CounterIcon />, badge: cartItemCount },
        { to: '/directory', text: t('bottomNav.directory'), icon: <DirectoryIcon /> },
    ];
    
    const filteredNavItems = navItems.filter(item => hasAccess(currentUser, item.to, 'view', permissions));

    const linkClasses = "flex flex-col items-center justify-center w-full pt-2 pb-1 text-neutral-medium dark:text-gray-400 hover:text-primary transition-colors duration-200";
    const activeLinkClasses = "text-primary";

    return (
        <footer className="fixed bottom-0 left-0 right-0 h-16 bg-white dark:bg-gray-800 border-t border-neutral-light dark:border-gray-700 flex z-20 shadow-[0_-2px_10px_-3px_rgba(0,0,0,0.05)] dark:shadow-[0_-2px_10px_-3px_rgba(0,0,0,0.25)]">
            {filteredNavItems.map(item => (
                <NavLink
                    key={item.to}
                    to={item.to}
                    className={({ isActive }) => `${linkClasses} ${isActive ? activeLinkClasses : ''}`}
                >
                    <div className="relative">
                        {item.icon}
                        {item.badge > 0 && (
                             <span className="absolute -top-1 -right-2 bg-accent-teal text-white text-xs rounded-full h-4 w-4 flex items-center justify-center border-2 border-white">
                                {item.badge}
                            </span>
                        )}
                    </div>
                    <span className="text-xs mt-1 font-medium">{item.text}</span>
                </NavLink>
            ))}
        </footer>
    );
};

export default memo(BottomNavBar);