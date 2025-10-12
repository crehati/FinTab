import type { Role, AppPermissions, UserPermissions, PermissionAction, User } from '../types';
import { PERMISSION_ACTIONS } from '../types';

export const PERMISSION_CONFIG: { path: string; name: string; description: string; availableActions: PermissionAction[] }[] = [
    { path: '/dashboard', name: 'Main Dashboard', description: 'View high-level overview of the entire business.', availableActions: ['view'] },
    { path: '/assistant', name: 'AI Assistant', description: 'Interact with an AI to get business insights and suggestions.', availableActions: ['view'] },
    { path: '/today', name: 'Today\'s Summary', description: 'View the daily dashboard with key metrics.', availableActions: ['view'] },
    { path: '/reports', name: 'Reports', description: 'Access financial, sales, and inventory reports.', availableActions: ['view', 'share', 'export'] },
    { path: '/reports/net-profit', name: 'View Net Profit', description: 'Allows viewing the Net Profit calculation in reports.', availableActions: ['view'] },
    { path: '/shopfront', name: 'Shopfront/Items', description: 'View products and add them to the cart for a new sale.', availableActions: ['view', 'add'] },
    { path: '/directory', name: 'Business Directory', description: 'Explore other public businesses on the platform.', availableActions: ['view'] },
    { path: '/inventory', name: 'Inventory Management', description: 'Add, edit, and delete products and manage stock levels.', availableActions: ['view', 'add', 'edit', 'delete'] },
    { path: '/receipts', name: 'Sales Receipts', description: 'View, share, or delete past sales receipts.', availableActions: ['view', 'delete', 'share'] },
    { path: '/proforma', name: 'Proforma Invoices', description: 'View, share, or delete proforma invoices.', availableActions: ['view', 'delete', 'share'] },
    { path: '/commission', name: 'Commission Settings', description: 'View and edit product-specific commission rates.', availableActions: ['view', 'edit'] },
    { path: '/expenses', name: 'Expense Management', description: 'Log, track, and delete business expenses.', availableActions: ['view', 'add', 'delete'] },
    { path: '/expense-requests', name: 'Expense Requests', description: 'Request expenses for approval. Managers can approve/reject.', availableActions: ['view', 'add'] },
    { path: '/customer-management', name: 'Customer Management', description: 'View, add, and edit customer information.', availableActions: ['view', 'add', 'edit'] },
    { path: '/users', name: 'User Management', description: 'View staff performance and manage user roles and access.', availableActions: ['view', 'add', 'edit', 'delete'] },
    { path: '/investors', name: 'Investor Dashboard', description: 'View investor-specific financial data and manage investors.', availableActions: ['view', 'add', 'edit', 'delete'] },
    { path: '/counter', name: 'Counter / Cart', description: 'View cart and finalize sales from the main counter view.', availableActions: ['view', 'add'] },
    { path: '/transactions', name: 'Cash Transactions', description: 'Manage cash flow, request deposits, and view history.', availableActions: ['view', 'add'] },
    { path: '/settings/business', name: 'Business Settings', description: 'Manage business-wide operational settings.', availableActions: ['view', 'edit'] },
    { path: '/settings/receipts', name: 'Receipt Settings', description: 'Customize receipt and proforma appearance.', availableActions: ['view', 'edit'] },
    { path: '/features/canSell', name: 'Act as Staff (Commission)', description: 'Allows an investor to make sales and earn commission. Grants access to relevant sales pages.', availableActions: ['view'] },
];

const fullAccess: UserPermissions = PERMISSION_CONFIG.reduce((acc, section) => {
    acc[section.path] = section.availableActions.reduce((actions, action) => {
        actions[action] = true;
        return actions;
    }, {} as Record<PermissionAction, boolean>);
    return acc;
}, {} as UserPermissions);

const cashierAccess: UserPermissions = {
    '/assistant': { view: true },
    '/today': { view: true },
    '/shopfront': { view: true, add: true },
    '/receipts': { view: true, share: true },
    '/proforma': { view: true, share: true },
    '/customer-management': { view: true, add: true, edit: true },
    '/counter': { view: true, add: true },
    '/transactions': { view: true, add: true },
    '/expense-requests': { view: true, add: true },
};

const sellerAgentAccess: UserPermissions = {
    ...cashierAccess,
    '/commission': { view: true },
};

const investorAccess: UserPermissions = {
    '/assistant': { view: true },
    '/reports': { view: true, share: true },
    '/investors': { view: true },
    '/investor-profile': { view: true },
};

export const DEFAULT_PERMISSIONS: AppPermissions = {
    roles: {
        'Manager': fullAccess,
        'Cashier': cashierAccess,
        'SellerAgent': sellerAgentAccess,
        'Investor': investorAccess,
        'Custom': {}, // Custom roles start with no permissions
    },
    users: {}
};

export const hasAccess = (user: User | null, path: string, action: PermissionAction, permissions: AppPermissions): boolean => {
    if (!user) return false;
    // Owner and Super Admin have access to everything by default.
    if (user.role === 'Owner' || user.role === 'Super Admin') return true;

    // Universal paths accessible to all logged-in users (view only)
    if (action === 'view') {
        const universalPaths = ['/profile', '/chat-help', '/more', '/access-denied', '/investor-profile', '/directory'];
        if (universalPaths.includes(path) || path.startsWith('/shopfront')) {
            return true;
        }
    }

    // 1. Check for user-specific override for the requested path/action
    const userOverride = permissions.users[user.id]?.[path]?.[action];
    if (typeof userOverride === 'boolean') {
        return userOverride;
    }

    // 2. If no direct override, check for 'canSell' inheritance for Investors
    if (user.role === 'Investor') {
        // Check if this user has the specific '/features/canSell' override enabled.
        const canSell = permissions.users[user.id]?.['/features/canSell']?.['view'] === true;

        if (canSell) {
            // If they can sell, check if the SellerAgent role has the requested permission.
            const sellerPermission = permissions.roles['SellerAgent']?.[path]?.[action];
            if (sellerPermission === true) {
                // We grant access based on SellerAgent role, but ONLY if there wasn't a specific user override denying it (checked in step 1).
                return true;
            }
        }
    }


    // 3. Fallback to the user's primary role-based permission
    const rolePermission = permissions.roles[user.role]?.[path]?.[action];
    if (typeof rolePermission === 'boolean') {
        return rolePermission;
    }

    // 4. Default to false
    return false;
};