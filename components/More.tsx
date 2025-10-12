import React from 'react';
import { NavLink } from 'react-router-dom';
import { 
    DashboardIcon, 
    TodayIcon,
    StorefrontIcon, 
    InventoryIcon, 
    CustomersIcon, 
    StaffIcon, 
    ReceiptsIcon, 
    ProformaIcon, 
    ExpensesIcon, 
    SettingsIcon, 
    ChatHelpIcon, 
    CommissionIcon, 
    InvestorIcon,
    ProfileIcon,
    TransactionIcon
} from '../constants';
import Card from './Card';
import { AppPermissions, User } from '../types';
import { hasAccess } from '../lib/permissions';


interface MoreProps {
    t: (key: string) => string;
    currentUser: User;
    permissions: AppPermissions;
}

const ArrowIcon = () => (
    <svg className="h-5 w-5 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" /></svg>
);

const More: React.FC<MoreProps> = ({ t, currentUser, permissions }) => {
    const managementItems = [
        { to: '/today', text: t('today.title'), icon: <TodayIcon /> },
        { to: '/shopfront', text: t('sidebar.shopfront'), icon: <StorefrontIcon /> },
        { to: '/receipts', text: t('sidebar.receipts'), icon: <ReceiptsIcon /> },
        { to: '/proforma', text: t('sidebar.proforma'), icon: <ProformaIcon /> },
        { to: '/transactions', text: t('transactions.title'), icon: <TransactionIcon /> },
        { to: '/commission', text: t('sidebar.commission'), icon: <CommissionIcon /> },
        { to: '/inventory', text: t('sidebar.inventory'), icon: <InventoryIcon /> },
        { to: '/expenses', text: t('sidebar.expenses'), icon: <ExpensesIcon /> },
        { to: '/expense-requests', text: t('sidebar.expenseII'), icon: <ExpensesIcon /> },
        { to: '/customer-management', text: t('sidebar.customerManagement'), icon: <CustomersIcon /> },
        { to: '/users', text: t('sidebar.staffManagement'), icon: <StaffIcon /> },
        { to: '/investors', text: t('sidebar.investors'), icon: <InvestorIcon /> },
    ];
    
    const applicationItems = [
        { to: '/chat-help', text: t('sidebar.chatHelp'), icon: <ChatHelpIcon /> },
        { to: '/settings', text: t('sidebar.settings'), icon: <SettingsIcon /> },
    ];

    const accountItems = [
        { to: currentUser.role === 'Investor' ? '/investor-profile' : '/profile', text: 'My Profile', icon: <ProfileIcon /> },
    ];

    const filteredManagementItems = managementItems.filter(item => hasAccess(currentUser, item.to, 'view', permissions));
    const filteredApplicationItems = applicationItems.filter(item => hasAccess(currentUser, item.to, 'view', permissions));
    const filteredAccountItems = accountItems.filter(item => hasAccess(currentUser, item.to, 'view', permissions));

    const MenuCard: React.FC<{ title: string; items: typeof managementItems }> = ({ title, items }) => {
        if (items.length === 0) return null;
        return (
            <Card title={title}>
                <div className="divide-y divide-gray-200">
                    {items.map(item => (
                        <NavLink
                            key={item.to}
                            to={item.to}
                            className="flex items-center justify-between p-4 hover:bg-gray-50 cursor-pointer transition-colors duration-150"
                        >
                            <div className="flex items-center">
                                {item.icon}
                                <span className="ml-4 text-lg text-gray-700 font-medium">{item.text}</span>
                            </div>
                            <ArrowIcon />
                        </NavLink>
                    ))}
                </div>
            </Card>
        );
    };

    return (
        <div className="space-y-6">
            <MenuCard title="My Account" items={filteredAccountItems} />
            <MenuCard title="Management" items={filteredManagementItems} />
            <MenuCard title="Application" items={filteredApplicationItems} />
        </div>
    );
};

export default More;