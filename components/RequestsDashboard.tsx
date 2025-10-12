import React, { useState, useMemo, useEffect } from 'react';
import { useLocation } from 'react-router-dom';
import type { User, Sale, Withdrawal, Deposit, ReceiptSettingsData, Customer, ExpenseRequest, AppPermissions } from '../types';
import { ChevronDownIcon } from '../constants';
import { hasAccess } from '../lib/permissions';

interface RequestsDashboardProps {
    users: User[];
    customers: Customer[];
    sales: Sale[];
    deposits: Deposit[];
    expenseRequests: ExpenseRequest[];
    receiptSettings: ReceiptSettingsData;
    onUpdateWithdrawalStatus: (userId: string, withdrawalId: string, status: 'approved' | 'rejected') => void;
    onUpdateDepositStatus: (depositId: string, status: 'approved' | 'rejected') => void;
    onUpdateExpenseRequestStatus: (requestId: string, status: 'approved' | 'rejected') => void;
    onApproveSale: (saleId: string) => void;
    onRejectSale: (saleId: string) => void;
    onMarkWithdrawalPaid: (userId: string, withdrawalId: string) => void;
    onApproveClientOrder: (saleId: string) => void;
    onRejectClientOrder: (saleId: string) => void;
    t: (key: string) => string;
    currentUser: User;
    permissions: AppPermissions;
}

const RequestsDashboard: React.FC<RequestsDashboardProps> = ({
    users, sales, deposits, customers, receiptSettings, onUpdateWithdrawalStatus, onUpdateDepositStatus, onApproveSale, onRejectSale, onMarkWithdrawalPaid, onApproveClientOrder, onRejectClientOrder, t, expenseRequests, onUpdateExpenseRequestStatus, currentUser, permissions
}) => {
    const location = useLocation();
    const [activeRequestTab, setActiveRequestTab] = useState<'clientOrders' | 'saleApprovals' | 'withdrawals' | 'deposits' | 'expenseRequests'>('clientOrders');
    const [expandedOrderId, setExpandedOrderId] = useState<string | null>(null);

    const cs = receiptSettings.currencySymbol;

    // --- Permission Checks ---
    const canManageClientOrders = useMemo(() => hasAccess(currentUser, '/proforma', 'edit', permissions), [currentUser, permissions]);
    const canManageSaleApprovals = useMemo(() => hasAccess(currentUser, '/receipts', 'edit', permissions), [currentUser, permissions]);
    const canManageWithdrawals = useMemo(() => hasAccess(currentUser, '/users', 'edit', permissions), [currentUser, permissions]);
    const canManageDeposits = useMemo(() => hasAccess(currentUser, '/transactions', 'edit', permissions), [currentUser, permissions]);
    const canManageExpenseRequests = useMemo(() => hasAccess(currentUser, '/expense-requests', 'edit', permissions), [currentUser, permissions]);

    const availableTabs = useMemo(() => {
        const tabs: ('clientOrders' | 'saleApprovals' | 'withdrawals' | 'deposits' | 'expenseRequests')[] = [];
        if (canManageExpenseRequests) tabs.push('expenseRequests');
        if (canManageClientOrders) tabs.push('clientOrders');
        if (canManageSaleApprovals) tabs.push('saleApprovals');
        if (canManageWithdrawals) tabs.push('withdrawals');
        if (canManageDeposits) tabs.push('deposits');
        return tabs;
    }, [canManageClientOrders, canManageSaleApprovals, canManageWithdrawals, canManageDeposits, canManageExpenseRequests]);

    useEffect(() => {
        const requestedTab = location.state?.openTab === 'requests' ? location.state.openSubTab : null;
        
        // If there's a requested tab from a notification and the user has access to it, show it.
        if (requestedTab && availableTabs.includes(requestedTab)) {
            setActiveRequestTab(requestedTab);
        } 
        // If the current active tab is not one the user has access to, switch to the first available one.
        else if (!availableTabs.includes(activeRequestTab) && availableTabs.length > 0) {
            setActiveRequestTab(availableTabs[0]);
        }
    }, [location.state, availableTabs, activeRequestTab]);


    // Expense Request Memos
    const pendingExpenseRequests = useMemo(() => expenseRequests.filter(er => er.status === 'pending').sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime()), [expenseRequests]);
    const historyExpenseRequests = useMemo(() => expenseRequests.filter(er => er.status !== 'pending').sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime()), [expenseRequests]);

    // Withdrawal Memos
    const allWithdrawals = useMemo(() => {
        return users.flatMap(user => 
            (user.withdrawals || []).map(w => ({ ...w, user }))
        ).sort((a,b) => new Date(b.date).getTime() - new Date(a.date).getTime());
    }, [users]);
    
    const pendingWithdrawals = useMemo(() => allWithdrawals.filter(w => w.status === 'pending'), [allWithdrawals]);
    const approvedWithdrawals = useMemo(() => allWithdrawals.filter(w => w.status === 'approved'), [allWithdrawals]);
    const historyWithdrawals = useMemo(() => allWithdrawals.filter(w => !['pending', 'approved'].includes(w.status)), [allWithdrawals]);

    // Deposit Memos
    const allDepositsWithUser = useMemo(() => {
        return deposits
            .map(deposit => {
                const user = users.find(u => u.id === deposit.userId);
                if (!user) return null;
                return { ...deposit, user };
            })
            .filter((d): d is (Deposit & { user: User }) => d !== null);
    }, [deposits, users]);

    const pendingDeposits = useMemo(() => allDepositsWithUser.filter(d => d.status === 'pending').sort((a,b) => new Date(b.date).getTime() - new Date(a.date).getTime()), [allDepositsWithUser]);
    const historyDeposits = useMemo(() => allDepositsWithUser.filter(d => d.status !== 'pending').sort((a,b) => new Date(b.date).getTime() - new Date(a.date).getTime()), [allDepositsWithUser]);

    // Sale Approval Memos
    const pendingSales = useMemo(() => sales.filter(s => s.status === 'pending_approval').sort((a,b) => new Date(b.date).getTime() - new Date(a.date).getTime()), [sales]);
    const historySales = useMemo(() => sales.filter(s => s.paymentMethod === 'Bank Transfer' && ['completed', 'rejected'].includes(s.status)).sort((a,b) => new Date(b.date).getTime() - new Date(a.date).getTime()), [sales]);
    
    // Client Order Memos
    const pendingClientOrders = useMemo(() => sales.filter(s => s.status === 'client_order').sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime()), [sales]);


    const getStatusBadge = (status: Withdrawal['status'] | Deposit['status'] | Sale['status'] | ExpenseRequest['status']) => {
        switch (status) {
            case 'pending':
            case 'pending_approval':
            case 'client_order':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-yellow-100 text-yellow-800">Pending</span>;
            case 'approved':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-blue-100 text-blue-800">Approved</span>;
            case 'paid':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-purple-100 text-purple-800">Paid</span>;
            case 'completed':
            case 'proforma':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-green-100 text-green-800">{status === 'proforma' ? 'Approved' : 'Completed'}</span>;
            case 'rejected':
                return <span className="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-red-100 text-red-800">Rejected</span>;
            default:
                return null;
        }
    };
    
    return (
        <div>
            <div className="border-b border-gray-200">
                <nav className="flex -mb-px space-x-6 overflow-x-auto" aria-label="Request Tabs">
                    {canManageExpenseRequests && (
                        <button
                            onClick={() => setActiveRequestTab('expenseRequests')}
                            className={`relative whitespace-nowrap py-3 px-1 border-b-2 font-medium text-sm transition-colors duration-200 ${activeRequestTab === 'expenseRequests' ? 'border-primary text-primary' : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'}`}
                        >
                            Expense Requests
                            {pendingExpenseRequests.length > 0 && (
                                <span className="ml-2 inline-flex items-center justify-center px-2 py-1 text-xs font-bold leading-none text-red-100 bg-red-600 rounded-full">{pendingExpenseRequests.length}</span>
                            )}
                        </button>
                    )}
                    {canManageClientOrders && (
                        <button
                            onClick={() => setActiveRequestTab('clientOrders')}
                            className={`relative whitespace-nowrap py-3 px-1 border-b-2 font-medium text-sm transition-colors duration-200 ${activeRequestTab === 'clientOrders' ? 'border-primary text-primary' : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'}`}
                        >
                            {t('requests.clientOrders')}
                            {pendingClientOrders.length > 0 && (
                                <span className="ml-2 inline-flex items-center justify-center px-2 py-1 text-xs font-bold leading-none text-red-100 bg-red-600 rounded-full">{pendingClientOrders.length}</span>
                            )}
                        </button>
                    )}
                    {canManageSaleApprovals && (
                        <button
                            onClick={() => setActiveRequestTab('saleApprovals')}
                            className={`relative whitespace-nowrap py-3 px-1 border-b-2 font-medium text-sm transition-colors duration-200 ${activeRequestTab === 'saleApprovals' ? 'border-primary text-primary' : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'}`}
                        >
                            {t('saleApprovals.title')}
                            {pendingSales.length > 0 && (
                                <span className="ml-2 inline-flex items-center justify-center px-2 py-1 text-xs font-bold leading-none text-red-100 bg-red-600 rounded-full">{pendingSales.length}</span>
                            )}
                        </button>
                    )}
                    {canManageWithdrawals && (
                        <button
                            onClick={() => setActiveRequestTab('withdrawals')}
                            className={`relative whitespace-nowrap py-3 px-1 border-b-2 font-medium text-sm transition-colors duration-200 ${activeRequestTab === 'withdrawals' ? 'border-primary text-primary' : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'}`}
                        >
                            Withdrawal Requests
                            {pendingWithdrawals.length > 0 && (
                                <span className="ml-2 inline-flex items-center justify-center px-2 py-1 text-xs font-bold leading-none text-red-100 bg-red-600 rounded-full">{pendingWithdrawals.length}</span>
                            )}
                        </button>
                    )}
                    {canManageDeposits && (
                        <button
                            onClick={() => setActiveRequestTab('deposits')}
                            className={`relative whitespace-nowrap py-3 px-1 border-b-2 font-medium text-sm transition-colors duration-200 ${activeRequestTab === 'deposits' ? 'border-primary text-primary' : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'}`}
                        >
                            Deposit Requests
                            {pendingDeposits.length > 0 && (
                                <span className="ml-2 inline-flex items-center justify-center px-2 py-1 text-xs font-bold leading-none text-red-100 bg-red-600 rounded-full">{pendingDeposits.length}</span>
                            )}
                        </button>
                    )}
                </nav>
            </div>

            <div className="mt-6">
                {activeRequestTab === 'expenseRequests' && (
                     <div className="space-y-6">
                        <div>
                            <h3 className="text-lg font-semibold text-gray-800 mb-2">Pending Expense Requests</h3>
                             {/* Desktop Table */}
                             <div className="hidden md:block overflow-x-auto rounded-lg border">
                                <table className="w-full text-sm text-left text-gray-500">
                                    <thead className="text-xs text-gray-700 uppercase bg-gray-50">
                                        <tr>
                                            <th scope="col" className="px-6 py-3">User</th>
                                            <th scope="col" className="px-6 py-3">Date</th>
                                            <th scope="col" className="px-6 py-3">Amount</th>
                                            <th scope="col" className="px-6 py-3">Description</th>
                                            <th scope="col" className="px-6 py-3 text-center">Actions</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {pendingExpenseRequests.map(req => {
                                            const user = users.find(u => u.id === req.userId);
                                            return (
                                            <tr key={req.id} className="bg-white border-b hover:bg-yellow-50">
                                                <td className="px-6 py-4 font-medium text-gray-900">{user?.name || 'Unknown'}</td>
                                                <td className="px-6 py-4">{new Date(req.date).toLocaleDateString()}</td>
                                                <td className="px-6 py-4 font-semibold">{cs}{req.amount.toFixed(2)}</td>
                                                <td className="px-6 py-4">{req.description}</td>
                                                <td className="px-6 py-4 text-center">
                                                    <div className="flex items-center justify-center gap-2">
                                                        <button onClick={() => onUpdateExpenseRequestStatus(req.id, 'approved')} className="px-3 py-1 text-xs font-semibold text-white bg-green-500 rounded-md hover:bg-green-600">Approve</button>
                                                        <button onClick={() => onUpdateExpenseRequestStatus(req.id, 'rejected')} className="px-3 py-1 text-xs font-semibold text-white bg-red-500 rounded-md hover:bg-red-600">Reject</button>
                                                    </div>
                                                </td>
                                            </tr>
                                        )})}
                                        {pendingExpenseRequests.length === 0 && (
                                            <tr><td colSpan={5} className="text-center py-6 text-gray-500">No pending expense requests.</td></tr>
                                        )}
                                    </tbody>
                                </table>
                            </div>
                            {/* Mobile Cards */}
                            <div className="space-y-3 md:hidden">
                                {pendingExpenseRequests.map(req => {
                                     const user = users.find(u => u.id === req.userId);
                                     return (
                                     <div key={req.id} className="bg-white p-4 rounded-xl shadow-md border">
                                         <div className="flex justify-between items-start">
                                             <div>
                                                 <p className="font-bold text-gray-800">{user?.name || 'Unknown'}</p>
                                                 <p className="text-xs text-gray-500">{new Date(req.date).toLocaleDateString()}</p>
                                             </div>
                                             <p className="font-semibold text-lg text-primary">{cs}{req.amount.toFixed(2)}</p>
                                         </div>
                                         <p className="text-sm text-gray-600 mt-2 border-t pt-2">{req.description}</p>
                                         <div className="flex items-center justify-end gap-2 mt-3 pt-3 border-t">
                                             <button onClick={() => onUpdateExpenseRequestStatus(req.id, 'rejected')} className="px-4 py-2 text-sm font-semibold text-white bg-red-500 rounded-lg hover:bg-red-600">Reject</button>
                                             <button onClick={() => onUpdateExpenseRequestStatus(req.id, 'approved')} className="px-4 py-2 text-sm font-semibold text-white bg-green-500 rounded-lg hover:bg-green-600">Approve</button>
                                         </div>
                                     </div>
                                 )})}
                                 {pendingExpenseRequests.length === 0 && (
                                    <div className="text-center py-6 text-gray-500">No pending expense requests.</div>
                                )}
                            </div>
                        </div>
                    </div>
                )}
                {activeRequestTab === 'clientOrders' && (
                     <div className="space-y-6">
                        <div>
                            <h3 className="text-lg font-semibold text-gray-800 mb-2">Pending Client Orders</h3>
                            {/* Desktop Table */}
                            <div className="hidden md:block overflow-x-auto rounded-lg border">
                                <table className="w-full text-sm text-left text-gray-500">
                                    <thead className="text-xs text-gray-700 uppercase bg-gray-50">
                                        <tr>
                                            <th scope="col" className="px-2 py-3 w-8"></th>
                                            <th scope="col" className="px-6 py-3">Date</th>
                                            <th scope="col" className="px-6 py-3">Client</th>
                                            <th scope="col" className="px-6 py-3">Amount</th>
                                            <th scope="col" className="px-6 py-3 text-center">Actions</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {pendingClientOrders.map(sale => {
                                            const customer = customers.find(c => c.id === sale.customerId);
                                            const isExpanded = expandedOrderId === sale.id;
                                            return (
                                            <React.Fragment key={sale.id}>
                                                <tr className="bg-white border-b hover:bg-yellow-50 cursor-pointer" onClick={() => setExpandedOrderId(isExpanded ? null : sale.id)}>
                                                    <td className="px-2 py-4">
                                                        <ChevronDownIcon className={`w-5 h-5 text-gray-400 transition-transform duration-200 ${isExpanded ? 'rotate-180' : ''}`} />
                                                    </td>
                                                    <td className="px-6 py-4">{new Date(sale.date).toLocaleString()}</td>
                                                    <td className="px-6 py-4 font-medium text-gray-900">{customer?.name || 'N/A'}</td>
                                                    <td className="px-6 py-4 font-semibold">{cs}{sale.total.toFixed(2)}</td>
                                                    <td className="px-6 py-4 text-center">
                                                        <div className="flex items-center justify-center gap-2" onClick={e => e.stopPropagation()}>
                                                            <button onClick={() => onApproveClientOrder(sale.id)} className="px-3 py-1 text-xs font-semibold text-white bg-green-500 rounded-md hover:bg-green-600 transition-all">Approve as Proforma</button>
                                                            <button onClick={() => onRejectClientOrder(sale.id)} className="px-3 py-1 text-xs font-semibold text-white bg-red-500 rounded-md hover:bg-red-600 transition-all">Reject</button>
                                                        </div>
                                                    </td>
                                                </tr>
                                                {isExpanded && (
                                                     <tr className="bg-gray-50 border-b">
                                                        <td colSpan={5} className="p-4">
                                                            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                                                                <div>
                                                                    <h5 className="font-semibold text-gray-700 mb-2">Client Details</h5>
                                                                    <div className="text-sm space-y-1">
                                                                        <p><strong>Name:</strong> {customer?.name}</p>
                                                                        <p><strong>Phone:</strong> {customer?.phone}</p>
                                                                        <p><strong>Email:</strong> {customer?.email}</p>
                                                                    </div>
                                                                </div>
                                                                <div>
                                                                    <h5 className="font-semibold text-gray-700 mb-2">Order Items ({sale.items.reduce((sum, item) => sum + item.quantity, 0)})</h5>
                                                                    <ul className="text-sm space-y-1 max-h-40 overflow-y-auto">
                                                                        {sale.items.map(item => {
                                                                            const price = item.variant ? item.variant.price : item.product.price;
                                                                            return (
                                                                                <li key={item.variant ? item.variant.id : item.product.id} className="flex justify-between border-b pb-1">
                                                                                    <span>{item.quantity} x {item.product.name} {item.variant && `(${item.variant.attributes.map(a=>a.value).join('/')})`}</span>
                                                                                    <span>{cs}{(price * item.quantity).toFixed(2)}</span>
                                                                                </li>
                                                                            )
                                                                        })}
                                                                    </ul>
                                                                </div>
                                                            </div>
                                                        </td>
                                                    </tr>
                                                )}
                                            </React.Fragment>
                                        )})}
                                        {pendingClientOrders.length === 0 && (
                                            <tr><td colSpan={5} className="text-center py-6 text-gray-500">No new client orders.</td></tr>
                                        )}
                                    </tbody>
                                </table>
                            </div>
                            {/* Mobile Cards */}
                            <div className="space-y-3 md:hidden">
                                {pendingClientOrders.map(sale => {
                                    const customer = customers.find(c => c.id === sale.customerId);
                                    const isExpanded = expandedOrderId === sale.id;
                                    return (
                                    <div key={sale.id} className="bg-white p-4 rounded-xl shadow-md border border-gray-100">
                                        <div className="flex justify-between items-start cursor-pointer" onClick={() => setExpandedOrderId(isExpanded ? null : sale.id)}>
                                            <div>
                                                <p className="font-bold text-gray-800">{customer?.name || 'N/A'}</p>
                                                <p className="text-xs text-gray-500">{new Date(sale.date).toLocaleString()}</p>
                                            </div>
                                            <div className="text-right">
                                                <p className="font-semibold text-lg text-primary flex-shrink-0 ml-2">{cs}{sale.total.toFixed(2)}</p>
                                                 <span className="text-xs text-gray-500 flex items-center justify-end gap-1">
                                                    Details <ChevronDownIcon className={`w-4 h-4 transition-transform duration-200 ${isExpanded ? 'rotate-180' : ''}`} />
                                                </span>
                                            </div>
                                        </div>
                                        {isExpanded && (
                                            <div className="mt-3 pt-3 border-t space-y-3">
                                                <div>
                                                    <h5 className="font-semibold text-sm text-gray-700">Client Details</h5>
                                                    <p className="text-xs"><strong>Phone:</strong> {customer?.phone}</p>
                                                    <p className="text-xs"><strong>Email:</strong> {customer?.email}</p>
                                                </div>
                                                <div>
                                                    <h5 className="font-semibold text-sm text-gray-700">Order Items</h5>
                                                    <ul className="list-disc list-inside text-xs pl-2">
                                                        {sale.items.map(item => (
                                                            <li key={item.variant ? item.variant.id : item.product.id}>
                                                                {item.quantity} x {item.product.name} {item.variant && `(${item.variant.attributes.map(a=>a.value).join('/')})`}
                                                            </li>
                                                        ))}
                                                    </ul>
                                                </div>
                                            </div>
                                        )}
                                        <div className="flex items-center justify-end flex-wrap gap-2 mt-3 pt-3 border-t">
                                            <button onClick={() => onRejectClientOrder(sale.id)} className="px-4 py-2 text-sm font-semibold text-white bg-red-500 rounded-lg hover:bg-red-600">Reject</button>
                                            <button onClick={() => onApproveClientOrder(sale.id)} className="px-4 py-2 text-sm font-semibold text-white bg-green-500 rounded-lg hover:bg-green-600">Approve as Proforma</button>
                                        </div>
                                    </div>
                                )})}
                                {pendingClientOrders.length === 0 && (
                                    <div className="text-center py-6 text-gray-500">No new client orders.</div>
                                )}
                            </div>
                        </div>
                    </div>
                )}
                {activeRequestTab === 'saleApprovals' && (
                     <div className="space-y-6">
                        <div>
                            <h3 className="text-lg font-semibold text-gray-800 mb-2">Pending Sale Approvals</h3>
                            {/* Desktop Table */}
                            <div className="hidden md:block overflow-x-auto rounded-lg border">
                                <table className="w-full text-sm text-left text-gray-500 table-fixed">
                                    <thead className="text-xs text-gray-700 uppercase bg-gray-50">
                                        <tr>
                                            <th scope="col" className="px-6 py-3 w-1/4">Date</th>
                                            <th scope="col" className="px-6 py-3 w-1/6">Receipt #</th>
                                            <th scope="col" className="px-6 py-3 w-1/3">Customer</th>
                                            <th scope="col" className="px-6 py-3 w-1/6">Amount</th>
                                            <th scope="col" className="px-6 py-3 text-center">Actions</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {pendingSales.map(sale => {
                                            const customer = customers.find(c => c.id === sale.customerId);
                                            return (
                                            <tr key={sale.id} className="bg-white border-b hover:bg-yellow-50">
                                                <td className="px-6 py-4 break-words">{new Date(sale.date).toLocaleString()}</td>
                                                <td className="px-6 py-4 font-mono text-xs break-words">{sale.id.slice(-6).toUpperCase()}</td>
                                                <td className="px-6 py-4 font-medium text-gray-900 break-words">{customer?.name || 'N/A'}</td>
                                                <td className="px-6 py-4 font-semibold">{cs}{sale.total.toFixed(2)}</td>
                                                <td className="px-6 py-4 text-center">
                                                    <div className="flex items-center justify-center gap-2">
                                                        <button onClick={() => onApproveSale(sale.id)} className="px-3 py-1 text-xs font-semibold text-white bg-green-500 rounded-md hover:bg-green-600 transition-all">Approve</button>
                                                        <button onClick={() => onRejectSale(sale.id)} className="px-3 py-1 text-xs font-semibold text-white bg-red-500 rounded-md hover:bg-red-600 transition-all">Reject</button>
                                                    </div>
                                                </td>
                                            </tr>
                                        )})}
                                        {pendingSales.length === 0 && (
                                            <tr><td colSpan={5} className="text-center py-6 text-gray-500">No pending sale approvals.</td></tr>
                                        )}
                                    </tbody>
                                </table>
                            </div>
                             {/* Mobile Cards */}
                            <div className="space-y-3 md:hidden">
                                {pendingSales.map(sale => {
                                    const customer = customers.find(c => c.id === sale.customerId);
                                    return (
                                     <div key={sale.id} className="bg-white p-4 rounded-xl shadow-md border border-gray-100">
                                        <div className="flex justify-between items-start">
                                            <div>
                                                <p className="font-bold text-gray-800">{customer?.name || 'N/A'}</p>
                                                <p className="text-xs text-gray-500 font-mono">#{sale.id.slice(-6).toUpperCase()}</p>
                                                <p className="text-xs text-gray-500">{new Date(sale.date).toLocaleString()}</p>
                                            </div>
                                            <p className="font-semibold text-lg text-primary flex-shrink-0 ml-2">{cs}{sale.total.toFixed(2)}</p>
                                        </div>
                                        <div className="flex items-center justify-end flex-wrap gap-2 mt-3 pt-3 border-t">
                                            <button onClick={() => onRejectSale(sale.id)} className="px-4 py-2 text-sm font-semibold text-white bg-red-500 rounded-lg hover:bg-red-600">Reject</button>
                                            <button onClick={() => onApproveSale(sale.id)} className="px-4 py-2 text-sm font-semibold text-white bg-green-500 rounded-lg hover:bg-green-600">Approve</button>
                                        </div>
                                    </div>
                                )})}
                                {pendingSales.length === 0 && (
                                    <div className="text-center py-6 text-gray-500">No pending sale approvals.</div>
                                )}
                            </div>
                        </div>
                        <div>
                            <h3 className="text-lg font-semibold text-gray-800 mb-2">Sale Approval History</h3>
                             {/* Desktop Table */}
                            <div className="hidden md:block overflow-x-auto rounded-lg border">
                                <table className="w-full text-sm text-left text-gray-500 table-fixed">
                                    <thead className="text-xs text-gray-700 uppercase bg-gray-50">
                                        <tr>
                                            <th scope="col" className="px-6 py-3 w-1/4">Date</th>
                                            <th scope="col" className="px-6 py-3 w-1/6">Receipt #</th>
                                            <th scope="col" className="px-6 py-3 w-1/3">Customer</th>
                                            <th scope="col" className="px-6 py-3 w-1/6">Amount</th>
                                            <th scope="col" className="px-6 py-3 text-center">Status</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {historySales.map(sale => {
                                            const customer = customers.find(c => c.id === sale.customerId);
                                            return (
                                            <tr key={sale.id} className="bg-white border-b hover:bg-gray-50 last:border-b-0">
                                                <td className="px-6 py-4 break-words">{new Date(sale.date).toLocaleString()}</td>
                                                <td className="px-6 py-4 font-mono text-xs break-words">{sale.id.slice(-6).toUpperCase()}</td>
                                                <td className="px-6 py-4 font-medium text-gray-900 break-words">{customer?.name || 'N/A'}</td>
                                                <td className="px-6 py-4 font-semibold">{cs}{sale.total.toFixed(2)}</td>
                                                <td className="px-6 py-4 text-center">{getStatusBadge(sale.status)}</td>
                                            </tr>
                                        )})}
                                        {historySales.length === 0 && (
                                            <tr><td colSpan={5} className="text-center py-6 text-gray-500">No sale approval history.</td></tr>
                                        )}
                                    </tbody>
                                </table>
                            </div>
                             {/* Mobile Cards */}
                            <div className="space-y-3 md:hidden">
                                {historySales.map(sale => {
                                    const customer = customers.find(c => c.id === sale.customerId);
                                    return (
                                    <div key={sale.id} className="bg-white p-4 rounded-xl shadow-md border border-gray-100">
                                        <div className="flex justify-between items-start">
                                            <div>
                                                <p className="font-bold text-gray-800">{customer?.name || 'N/A'}</p>
                                                <p className="text-xs text-gray-500 font-mono">#{sale.id.slice(-6).toUpperCase()}</p>
                                            </div>
                                            <div className="text-right">
                                                <p className="font-semibold text-lg text-primary flex-shrink-0 ml-2">{cs}{sale.total.toFixed(2)}</p>
                                                <div className="mt-1">{getStatusBadge(sale.status)}</div>
                                            </div>
                                        </div>
                                    </div>
                                )})}
                                {historySales.length === 0 && (
                                    <div className="text-center py-6 text-gray-500">No sale approval history.</div>
                                )}
                            </div>
                        </div>
                    </div>
                )}
                {activeRequestTab === 'withdrawals' && (
                    <div className="space-y-6">
                        <div>
                            <h3 className="text-lg font-semibold text-gray-800 mb-2">Pending Requests</h3>
                            {/* Desktop Table */}
                            <div className="hidden md:block overflow-x-auto rounded-lg border">
                                <table className="w-full text-sm text-left text-gray-500 table-fixed">
                                    <thead className="text-xs text-gray-700 uppercase bg-gray-50">
                                        <tr>
                                            <th scope="col" className="px-6 py-3 w-1/3">User</th>
                                            <th scope="col" className="px-6 py-3 w-1/4">Date</th>
                                            <th scope="col" className="px-6 py-3 w-1/6">Amount</th>
                                            <th scope="col" className="px-6 py-3 text-center">Actions</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {pendingWithdrawals.map(w => (
                                            <tr key={w.id} className="bg-white border-b hover:bg-yellow-50 last:border-b-0">
                                                <td className="px-6 py-4 font-medium text-gray-900 break-words">
                                                    <div className="flex items-center">
                                                        <img src={w.user.avatarUrl} alt={w.user.name} className="w-8 h-8 rounded-full mr-3 object-cover flex-shrink-0" />
                                                        <span className="truncate">{w.user.name}</span>
                                                    </div>
                                                </td>
                                                <td className="px-6 py-4 break-words">{new Date(w.date).toLocaleDateString()}</td>
                                                <td className="px-6 py-4 font-semibold">{cs}{w.amount.toFixed(2)}</td>
                                                <td className="px-6 py-4 text-center">
                                                    <div className="flex items-center justify-center gap-2">
                                                        <button onClick={() => onUpdateWithdrawalStatus(w.user.id, w.id, 'approved')} className="px-3 py-1 text-xs font-semibold text-white bg-green-500 rounded-md hover:bg-green-600 transition-all">Approve</button>
                                                        <button onClick={() => onUpdateWithdrawalStatus(w.user.id, w.id, 'rejected')} className="px-3 py-1 text-xs font-semibold text-white bg-red-500 rounded-md hover:bg-red-600 transition-all">Reject</button>
                                                    </div>
                                                </td>
                                            </tr>
                                        ))}
                                        {pendingWithdrawals.length === 0 && (
                                            <tr><td colSpan={4} className="text-center py-6 text-gray-500">No pending withdrawal requests.</td></tr>
                                        )}
                                    </tbody>
                                </table>
                            </div>
                            {/* Mobile Cards */}
                            <div className="space-y-3 md:hidden">
                                {pendingWithdrawals.map(w => (
                                    <div key={w.id} className="bg-white p-4 rounded-xl shadow-md border border-gray-100">
                                        <div className="flex justify-between items-start">
                                            <div className="flex items-center gap-3">
                                                <img src={w.user.avatarUrl} alt={w.user.name} className="w-10 h-10 rounded-full object-cover" />
                                                <div>
                                                    <p className="font-bold text-gray-800">{w.user.name}</p>
                                                    <p className="text-xs text-gray-500">{new Date(w.date).toLocaleDateString()}</p>
                                                </div>
                                            </div>
                                            <p className="font-semibold text-lg text-primary">{cs}{w.amount.toFixed(2)}</p>
                                        </div>
                                        <div className="flex items-center justify-end flex-wrap gap-2 mt-3 pt-3 border-t">
                                            <button onClick={() => onUpdateWithdrawalStatus(w.user.id, w.id, 'rejected')} className="px-4 py-2 text-sm font-semibold text-white bg-red-500 rounded-lg hover:bg-red-600">Reject</button>
                                            <button onClick={() => onUpdateWithdrawalStatus(w.user.id, w.id, 'approved')} className="px-4 py-2 text-sm font-semibold text-white bg-green-500 rounded-lg hover:bg-green-600">Approve</button>
                                        </div>
                                    </div>
                                ))}
                                 {pendingWithdrawals.length === 0 && (
                                    <div className="text-center py-6 text-gray-500">No pending withdrawal requests.</div>
                                )}
                            </div>
                        </div>
                        <div>
                            <h3 className="text-lg font-semibold text-gray-800 mb-2">Approved - Pending Payout</h3>
                             {/* Desktop Table */}
                             <div className="hidden md:block overflow-x-auto rounded-lg border">
                                <table className="w-full text-sm text-left text-gray-500 table-fixed">
                                    <thead className="text-xs text-gray-700 uppercase bg-gray-50">
                                        <tr>
                                            <th scope="col" className="px-6 py-3 w-1/3">User</th>
                                            <th scope="col" className="px-6 py-3 w-1/4">Date</th>
                                            <th scope="col" className="px-6 py-3 w-1/6">Amount</th>
                                            <th scope="col" className="px-6 py-3 text-center">Actions</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {approvedWithdrawals.map(w => (
                                            <tr key={w.id} className="bg-white border-b hover:bg-blue-50 last:border-b-0">
                                                <td className="px-6 py-4 font-medium text-gray-900 break-words">
                                                    <div className="flex items-center">
                                                        <img src={w.user.avatarUrl} alt={w.user.name} className="w-8 h-8 rounded-full mr-3 object-cover flex-shrink-0" />
                                                        <span className="truncate">{w.user.name}</span>
                                                    </div>
                                                </td>
                                                <td className="px-6 py-4 break-words">{new Date(w.date).toLocaleDateString()}</td>
                                                <td className="px-6 py-4 font-semibold">{cs}{w.amount.toFixed(2)}</td>
                                                <td className="px-6 py-4 text-center">
                                                    <button onClick={() => onMarkWithdrawalPaid(w.user.id, w.id)} className="px-3 py-1 text-xs font-semibold text-white bg-primary rounded-md hover:bg-blue-700 transition-all">Mark as Paid</button>
                                                </td>
                                            </tr>
                                        ))}
                                        {approvedWithdrawals.length === 0 && (
                                            <tr><td colSpan={4} className="text-center py-6 text-gray-500">No approved withdrawals awaiting payment.</td></tr>
                                        )}
                                    </tbody>
                                </table>
                            </div>
                            {/* Mobile Cards */}
                             <div className="space-y-3 md:hidden">
                                {approvedWithdrawals.map(w => (
                                    <div key={w.id} className="bg-white p-4 rounded-xl shadow-md border border-gray-100">
                                        <div className="flex justify-between items-start">
                                            <div className="flex items-center gap-3">
                                                <img src={w.user.avatarUrl} alt={w.user.name} className="w-10 h-10 rounded-full object-cover" />
                                                <div>
                                                    <p className="font-bold text-gray-800">{w.user.name}</p>
                                                    <p className="text-xs text-gray-500">{new Date(w.date).toLocaleDateString()}</p>
                                                </div>
                                            </div>
                                            <p className="font-semibold text-lg text-primary">{cs}{w.amount.toFixed(2)}</p>
                                        </div>
                                        <div className="flex items-center justify-end mt-3 pt-3 border-t">
                                            <button onClick={() => onMarkWithdrawalPaid(w.user.id, w.id)} className="px-3 py-1.5 text-xs font-semibold text-white bg-primary rounded-full hover:bg-blue-700">Mark as Paid</button>
                                        </div>
                                    </div>
                                ))}
                                {approvedWithdrawals.length === 0 && (
                                    <div className="text-center py-6 text-gray-500">No approved withdrawals awaiting payment.</div>
                                )}
                            </div>
                        </div>
                        <div>
                            <h3 className="text-lg font-semibold text-gray-800 mb-2">History</h3>
                             {/* Desktop Table */}
                             <div className="hidden md:block overflow-x-auto rounded-lg border">
                                <table className="w-full text-sm text-left text-gray-500 table-fixed">
                                     <thead className="text-xs text-gray-700 uppercase bg-gray-50">
                                        <tr>
                                            <th scope="col" className="px-6 py-3 w-1/3">User</th>
                                            <th scope="col" className="px-6 py-3 w-1/4">Date</th>
                                            <th scope="col" className="px-6 py-3 w-1/6">Amount</th>
                                            <th scope="col" className="px-6 py-3 text-center">Status</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {historyWithdrawals.map(w => (
                                            <tr key={w.id} className="bg-white border-b hover:bg-gray-50 last:border-b-0">
                                                <td className="px-6 py-4 font-medium text-gray-900 break-words">
                                                    <div className="flex items-center">
                                                        <img src={w.user.avatarUrl} alt={w.user.name} className="w-8 h-8 rounded-full mr-3 object-cover flex-shrink-0" />
                                                        <span className="truncate">{w.user.name}</span>
                                                    </div>
                                                </td>
                                                <td className="px-6 py-4 break-words">{new Date(w.date).toLocaleDateString()}</td>
                                                <td className="px-6 py-4 font-semibold">{cs}{w.amount.toFixed(2)}</td>
                                                <td className="px-6 py-4 text-center">{getStatusBadge(w.status)}</td>
                                            </tr>
                                        ))}
                                        {historyWithdrawals.length === 0 && (
                                            <tr><td colSpan={4} className="text-center py-6 text-gray-500">No withdrawal history.</td></tr>
                                        )}
                                    </tbody>
                                </table>
                            </div>
                            {/* Mobile Cards */}
                            <div className="space-y-3 md:hidden">
                                {historyWithdrawals.map(w => (
                                    <div key={w.id} className="bg-white p-4 rounded-xl shadow-md border border-gray-100">
                                        <div className="flex justify-between items-start">
                                            <div className="flex items-center gap-3">
                                                <img src={w.user.avatarUrl} alt={w.user.name} className="w-10 h-10 rounded-full object-cover" />
                                                <div>
                                                    <p className="font-bold text-gray-800">{w.user.name}</p>
                                                    <p className="text-xs text-gray-500">{new Date(w.date).toLocaleDateString()}</p>
                                                </div>
                                            </div>
                                            <div className="text-right">
                                                <p className="font-semibold text-lg text-primary">{cs}{w.amount.toFixed(2)}</p>
                                                <div className="mt-1">{getStatusBadge(w.status)}</div>
                                            </div>
                                        </div>
                                    </div>
                                ))}
                                {historyWithdrawals.length === 0 && (
                                    <div className="text-center py-6 text-gray-500">No withdrawal history.</div>
                                )}
                            </div>
                        </div>
                    </div>
                )}
                {activeRequestTab === 'deposits' && (
                    <div className="space-y-6">
                        <div>
                            <h3 className="text-lg font-semibold text-gray-800 mb-2">Pending Deposit Requests</h3>
                             {/* Desktop Table */}
                            <div className="hidden md:block overflow-x-auto rounded-lg border">
                                <table className="w-full text-sm text-left text-gray-500 table-fixed">
                                     <thead className="text-xs text-gray-700 uppercase bg-gray-50">
                                        <tr>
                                            <th scope="col" className="px-6 py-3 w-1/4">User</th>
                                            <th scope="col" className="px-6 py-3 w-1/4">Date</th>
                                            <th scope="col" className="px-6 py-3 w-1/6">Amount</th>
                                            <th scope="col" className="px-6 py-3 w-1/3">Description</th>
                                            <th scope="col" className="px-6 py-3 text-center">Actions</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {pendingDeposits.map(d => (
                                            <tr key={d.id} className="bg-white border-b hover:bg-yellow-50">
                                                <td className="px-6 py-4 font-medium text-gray-900 break-words">
                                                    <div className="flex items-center">
                                                        <img src={d.user.avatarUrl} alt={d.user.name} className="w-8 h-8 rounded-full mr-3 object-cover flex-shrink-0" />
                                                        <span className="truncate">{d.user.name}</span>
                                                    </div>
                                                </td>
                                                <td className="px-6 py-4 break-words">{new Date(d.date).toLocaleDateString()}</td>
                                                <td className="px-6 py-4 font-semibold">{cs}{d.amount.toFixed(2)}</td>
                                                <td className="px-6 py-4 break-words">{d.description}</td>
                                                <td className="px-6 py-4 text-center">
                                                    <div className="flex items-center justify-center gap-2">
                                                        <button onClick={() => onUpdateDepositStatus(d.id, 'approved')} className="px-3 py-1 text-xs font-semibold text-white bg-green-500 rounded-md hover:bg-green-600 transition-all">Approve</button>
                                                        <button onClick={() => onUpdateDepositStatus(d.id, 'rejected')} className="px-3 py-1 text-xs font-semibold text-white bg-red-500 rounded-md hover:bg-red-600 transition-all">Reject</button>
                                                    </div>
                                                </td>
                                            </tr>
                                        ))}
                                        {pendingDeposits.length === 0 && (
                                            <tr><td colSpan={5} className="text-center py-6 text-gray-500">No pending deposit requests.</td></tr>
                                        )}
                                    </tbody>
                                </table>
                            </div>
                            {/* Mobile Cards */}
                            <div className="space-y-3 md:hidden">
                                {pendingDeposits.map(d => (
                                    <div key={d.id} className="bg-white p-4 rounded-xl shadow-md border border-gray-100">
                                        <div className="flex justify-between items-start">
                                            <div className="flex items-center gap-3">
                                                <img src={d.user.avatarUrl} alt={d.user.name} className="w-10 h-10 rounded-full object-cover" />
                                                <div>
                                                    <p className="font-bold text-gray-800">{d.user.name}</p>
                                                    <p className="text-xs text-gray-500">{new Date(d.date).toLocaleDateString()}</p>
                                                </div>
                                            </div>
                                            <p className="font-semibold text-lg text-primary">{cs}{d.amount.toFixed(2)}</p>
                                        </div>
                                        <p className="text-sm text-gray-600 mt-2 border-t pt-2">{d.description}</p>
                                        <div className="flex items-center justify-end flex-wrap gap-2 mt-3 pt-3 border-t">
                                            <button onClick={() => onUpdateDepositStatus(d.id, 'rejected')} className="px-4 py-2 text-sm font-semibold text-white bg-red-500 rounded-lg hover:bg-red-600">Reject</button>
                                            <button onClick={() => onUpdateDepositStatus(d.id, 'approved')} className="px-4 py-2 text-sm font-semibold text-white bg-green-500 rounded-lg hover:bg-green-600">Approve</button>
                                        </div>
                                    </div>
                                ))}
                                {pendingDeposits.length === 0 && (
                                    <div className="text-center py-6 text-gray-500">No pending deposit requests.</div>
                                )}
                            </div>
                        </div>
                        <div>
                            <h3 className="text-lg font-semibold text-gray-800 mb-2">Deposit History</h3>
                            {/* Desktop Table */}
                            <div className="hidden md:block overflow-x-auto rounded-lg border">
                                <table className="w-full text-sm text-left text-gray-500 table-fixed">
                                     <thead className="text-xs text-gray-700 uppercase bg-gray-50">
                                        <tr>
                                            <th scope="col" className="px-6 py-3 w-1/4">User</th>
                                            <th scope="col" className="px-6 py-3 w-1/4">Date</th>
                                            <th scope="col" className="px-6 py-3 w-1/6">Amount</th>
                                            <th scope="col" className="px-6 py-3 w-1/3">Description</th>
                                            <th scope="col" className="px-6 py-3 text-center">Status</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {historyDeposits.map(d => (
                                            <tr key={d.id} className="bg-white border-b hover:bg-gray-50 last:border-b-0">
                                                <td className="px-6 py-4 font-medium text-gray-900 break-words">
                                                    <div className="flex items-center">
                                                        <img src={d.user.avatarUrl} alt={d.user.name} className="w-8 h-8 rounded-full mr-3 object-cover flex-shrink-0" />
                                                        <span className="truncate">{d.user.name}</span>
                                                    </div>
                                                </td>
                                                <td className="px-6 py-4 break-words">{new Date(d.date).toLocaleDateString()}</td>
                                                <td className="px-6 py-4 font-semibold">{cs}{d.amount.toFixed(2)}</td>
                                                <td className="px-6 py-4 break-words">{d.description}</td>
                                                <td className="px-6 py-4 text-center">{getStatusBadge(d.status)}</td>
                                            </tr>
                                        ))}
                                        {historyDeposits.length === 0 && (
                                            <tr><td colSpan={5} className="text-center py-6 text-gray-500">No deposit history.</td></tr>
                                        )}
                                    </tbody>
                                </table>
                            </div>
                            {/* Mobile Cards */}
                             <div className="space-y-3 md:hidden">
                                {historyDeposits.map(d => (
                                    <div key={d.id} className="bg-white p-4 rounded-xl shadow-md border border-gray-100">
                                        <div className="flex justify-between items-start">
                                            <div className="flex items-center gap-3">
                                                <img src={d.user.avatarUrl} alt={d.user.name} className="w-10 h-10 rounded-full object-cover" />
                                                <div>
                                                    <p className="font-bold text-gray-800">{d.user.name}</p>
                                                    <p className="text-xs text-gray-500">{new Date(d.date).toLocaleDateString()}</p>
                                                </div>
                                            </div>
                                            <div className="text-right">
                                                <p className="font-semibold text-lg text-primary">{cs}{d.amount.toFixed(2)}</p>
                                                <div className="mt-1">{getStatusBadge(d.status)}</div>
                                            </div>
                                        </div>
                                        <p className="text-sm text-gray-600 mt-2 border-t pt-2">{d.description}</p>
                                    </div>
                                ))}
                                {historyDeposits.length === 0 && (
                                    <div className="text-center py-6 text-gray-500">No deposit history.</div>
                                )}
                            </div>
                        </div>
                    </div>
                )}
            </div>
        </div>
    );
};

export default RequestsDashboard;