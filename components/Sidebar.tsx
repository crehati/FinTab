import React, { memo, useMemo } from 'react';
import { NavLink } from 'react-router-dom';
import { 
    AIIcon, 
    DashboardIcon,
    StorefrontIcon, 
    InventoryIcon, 
    CustomersIcon, 
    StaffIcon, 
    ReceiptsIcon,
    ProformaIcon,
    ExpensesIcon, 
    SettingsIcon, 
    ChatHelpIcon, 
    LogoutIcon,
    TodayIcon,
    ReportsIcon,
    CloseIcon,
    CounterIcon,
    CommissionIcon,
    InvestorIcon,
    ProfileIcon,
    TransactionIcon,
    DirectoryIcon
} from '../constants';
import type { CartItem, User, AppPermissions, BusinessProfile, OwnerSettings } from '../types';
import { hasAccess } from '../lib/permissions';


interface SidebarProps {
    t: (key: string) => string;
    isOpen: boolean;
    setIsOpen: (isOpen: boolean) => void;
    cart: CartItem[];
    currentUser: User;
    onLogout: () => void;
    permissions: AppPermissions;
    businessProfile: BusinessProfile | null;
    ownerSettings: OwnerSettings;
}

const Sidebar: React.FC<SidebarProps> = ({ t, isOpen, setIsOpen, cart, currentUser, onLogout, permissions, businessProfile, ownerSettings }) => {
    const cartItemCount = cart.reduce((sum, item) => sum + item.quantity, 0);

    const allNavItems = useMemo(() => {
        const canSell = hasAccess(currentUser, '/features/canSell', 'view', permissions);
        const isInvestor = currentUser.role === 'Investor';

        const appNavItemsList = [];
        if (isInvestor) {
            // Primary profile for investor is 'My Investment'
            appNavItemsList.push({ to: '/investor-profile', text: 'My Investment', icon: <InvestorIcon /> });
            // If they can also sell, add the staff profile link
            if (canSell) {
                appNavItemsList.push({ to: '/profile', text: 'My Staff Profile', icon: <ProfileIcon /> });
            }
        } else {
            // Standard user profile
            appNavItemsList.push({ to: '/profile', text: 'My Profile', icon: <ProfileIcon /> });
        }
        
        // Add common app items
        appNavItemsList.push(
            { to: '/chat-help', text: t('sidebar.chatHelp'), icon: <ChatHelpIcon /> },
            { to: '/settings', text: t('sidebar.settings'), icon: <SettingsIcon /> },
        );

        return {
            main: [
                { to: '/dashboard', text: t('sidebar.dashboard'), icon: <DashboardIcon /> },
                { to: '/assistant', text: t('sidebar.aiAssistant'), icon: <AIIcon /> },
                { to: '/today', text: t('today.title'), icon: <TodayIcon /> },
                { to: '/reports', text: t('reports.title'), icon: <ReportsIcon /> },
                { to: '/shopfront', text: t('sidebar.shopfront'), icon: <StorefrontIcon /> },
                { to: '/directory', text: t('sidebar.directory'), icon: <DirectoryIcon /> },
            ],
            management: [
                { to: '/inventory', text: t('sidebar.inventory'), icon: <InventoryIcon /> },
                { to: '/receipts', text: t('sidebar.receipts'), icon: <ReceiptsIcon /> },
                { to: '/proforma', text: t('sidebar.proforma'), icon: <ProformaIcon /> },
                { to: '/transactions', text: t('transactions.title'), icon: <TransactionIcon /> },
                { to: '/commission', text: t('sidebar.commission'), icon: <CommissionIcon /> },
                { to: '/expenses', text: t('sidebar.expenses'), icon: <ExpensesIcon /> },
                { to: '/expense-requests', text: t('sidebar.expenseII'), icon: <ExpensesIcon /> },
                { to: '/customer-management', text: t('sidebar.customerManagement'), icon: <CustomersIcon /> },
                { to: '/users', text: t('sidebar.staffManagement'), icon: <StaffIcon /> },
                { to: '/investors', text: t('sidebar.investors'), icon: <InvestorIcon /> },
            ],
            app: appNavItemsList
        };
    }, [t, currentUser, permissions]);

    const filterNavItems = (items: typeof allNavItems.main) => {
        return items.filter(item => {
            // Special rule for Owner's commission link
            if (currentUser.role === 'Owner' && item.to === '/commission') {
                return ownerSettings.commissionTrackingEnabled;
            }
            return hasAccess(currentUser, item.to, 'view', permissions)
        });
    }

    const mainNavItems = filterNavItems(allNavItems.main);
    const managementNavItems = filterNavItems(allNavItems.management);
    const appNavItems = filterNavItems(allNavItems.app);

    const NavSection: React.FC<{title?: string, items: {to: string, text: string, icon: React.ReactNode, badge?: number}[]}> = ({ title, items }) => {
        if (items.length === 0) return null;
        return (
            <div>
                {title && <h3 className="px-4 pt-4 pb-2 text-xs font-semibold text-neutral-medium dark:text-gray-400 uppercase tracking-wider">{title}</h3>}
                {items.map(item => (
                    <NavLink
                        key={item.to}
                        to={item.to}
                        end={item.to === '/'}
                        onClick={() => setIsOpen(false)}
                        className={({ isActive }) => 
                            `flex items-center px-4 py-3 rounded-lg transition-colors duration-200 group ${
                                isActive 
                                ? 'bg-primary/10' 
                                : 'hover:bg-primary/5 dark:hover:bg-gray-700'
                            }`
                        }
                    >
                        {({ isActive }) => (
                            <>
                                <div className={`transition-colors duration-200 ${isActive ? 'text-primary' : 'text-neutral-medium group-hover:text-primary dark:text-gray-400 dark:group-hover:text-primary'}`}>
                                    {item.icon}
                                </div>
                                <span className={`ml-4 font-medium transition-colors duration-200 ${isActive ? 'text-primary' : 'text-neutral-dark dark:text-gray-200 group-hover:text-primary dark:group-hover:text-primary'}`}>
                                    {item.text}
                                </span>
                                {item.badge > 0 && (
                                    <span className="ml-auto bg-accent-teal text-white text-xs font-bold px-2 py-0.5 rounded-full">{item.badge}</span>
                                )}
                            </>
                        )}
                    </NavLink>
                ))}
            </div>
        );
    };

    const LogoutButton = () => (
         <button className="flex items-center w-full px-4 py-3 rounded-lg transition-colors duration-200 group hover:bg-primary/5 dark:hover:bg-gray-700" onClick={onLogout}>
            <div className="text-neutral-medium dark:text-gray-400 group-hover:text-primary dark:group-hover:text-primary transition-colors duration-200">
                <LogoutIcon />
            </div>
            <span className="ml-4 font-medium text-neutral-dark dark:text-gray-200 group-hover:text-primary dark:group-hover:text-primary transition-colors duration-200">{t('sidebar.logout')}</span>
        </button>
    );

    return (
        <>
            {isOpen && <div onClick={() => setIsOpen(false)} className="fixed inset-0 bg-black bg-opacity-50 z-20 md:hidden" aria-hidden="true"></div>}
            <aside 
                className={`fixed inset-y-0 left-0 w-64 flex-shrink-0 bg-white dark:bg-gray-800 flex flex-col z-30 transform transition-transform duration-300 ease-in-out md:static md:translate-x-0 shadow-xl ${
                isOpen ? 'translate-x-0' : '-translate-x-full'
            }`}>
                <div className="h-20 flex items-center justify-between px-4 flex-shrink-0 border-b border-neutral-light dark:border-gray-700">
                    <div className="flex items-center gap-2 overflow-hidden">
                        {businessProfile?.logo && (
                            <img src={businessProfile.logo} alt="Business Logo" className="h-10 w-10 rounded-md object-contain flex-shrink-0" />
                        )}
                        <h1 className="text-2xl font-bold tracking-wider text-primary truncate">
                            {businessProfile?.businessName || 'FinTab'}
                        </h1>
                    </div>
                    <button onClick={() => setIsOpen(false)} className="md:hidden text-neutral-medium dark:text-gray-400 hover:text-primary" aria-label="Close sidebar">
                        <CloseIcon />
                    </button>
                </div>
                <nav className="flex-1 px-4 py-6 overflow-y-auto">
                    <div className="space-y-4">
                        <NavSection items={mainNavItems} />
                        <NavSection title="Management" items={managementNavItems} />
                    </div>
                    <div className="mt-4 pt-3 border-t border-neutral-light dark:border-gray-700 space-y-2">
                        <NavSection items={appNavItems} />
                        <LogoutButton />
                    </div>
                </nav>
                <div className="p-4 border-t border-neutral-light dark:border-gray-700">
                    <p className="text-sm text-neutral-medium dark:text-gray-500">&copy; 2024 FinTab</p>
                </div>
            </aside>
        </>
    );
};

export default memo(Sidebar);