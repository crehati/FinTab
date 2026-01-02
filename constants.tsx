
import type { Product, Customer, User, Sale, Expense, CompanyValuation, Deposit, AdminBusinessData, ReceiptSettingsData, OwnerSettings, BusinessSettingsData, AnomalySettings } from './types';
import React from 'react';

// FINTAB Brand Mark (SVG) - High Fidelity Version
export const FINTAB_LOGO_SVG = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 4000 4000'%3E%3Cdefs%3E%3Cstyle%3E.fil0%7Bfill:%231A457E%7D.fil1%7Bfill:%232563EB%7D.fil2%7Bfill:%23666666%7D.fil3%7Bfill:%231A457E;fill-rule:nonzero%7D.fnt0%7Bfont-weight:bold;font-size:1046.33px;font-family:'Arial'%7D.fnt1%7Bfont-weight:bold;font-size:1009.87px;font-family:'Arial'%7D.fnt2%7Bfont-weight:normal;font-size:261.56px;font-family:'Arial'%7D%3C/style%3E%3C/defs%3E%3Cg id='Layer_x0020_1'%3E%3Ctext x='366.91' y='3541.37' class='fil0 fnt0'%3EFin%3C/text%3E%3Ctext x='1875.45' y='3530.88' class='fil1 fnt1'%3ETab%3C/text%3E%3Ctext x='432.85' y='3855.85' class='fil2 fnt2'%3ESell Smarter. Serve Faster.%3C/text%3E%3Cpath class='fil0' d='M1901.62 1656.8l1.71-278.74c-78.46 4.17-163.06 0.98-242.21 0.82l-174.91 0.6c-53.52 0.46-43.37 1.52-50.65-10.65 10.89-246.14-87.98-635.78 298.33-638.92 315.95-2.56 632.53-0.25 948.54 0.02 37.21-74.66 116.8-206.72 140.99-280.28-152.85-7.35-322.89-0.47-477.67-0.39-162.66 0.08-325.31-0-487.97 0.04-154.21 0.04-286.91-2.17-408.27 69.42-102.65 60.54-181.42 135.99-238.16 249.76-66.83 134.01-53.09 268.83-53.28 427.8-0.22 196.06-7.98 1371.84 2.15 1461.39l274.36 0.36 1.5-1002.3 465.56 1.07z'/%3E%3Cpath class='fil1' d='M1506.54 1239.43l535.95 1.17 0.47 887.57c-0.06 318.61 231.6 529.78 544.41 535.06l-1.27-271.63c-317.19-17.81-264.99-297.4-265.48-576.49l-0.48-571.66 369.31-2.36 139.33-278.15-1182.99 0.1-139.25 276.39z'/%3E%3Cpath class='fil3' d='M734.72 374.02l59.86 0 8.07 5.76c-21.99 30.73-39.41 62.74-52.96 98.03l-55.94-20.99c11.09-29.1 24.76-56.58 40.98-82.79zm2576.58 1897.2l-61.07 0c7.43-32.86 10.44-64.84 10.44-98.98l59.76 0c0 33.96-2.72 66.33-9.13 98.98zm-2636.26-1753.61c-10.19 43.17-13.06 81.13-13.06 125.33l59.76 0c0-39.68 2.35-73.03 11.5-111.8l-58.2-13.53zm-13.06 185.08l59.76 0 0 119.52-59.76 0 0-119.52zm0 179.27l59.76 0 0 119.52-59.76 0 0-119.52zm0 179.27l59.76 0 0 119.51-59.76 0 0-119.51zm0 179.27l59.76 0 0 119.51-59.76 0 0-119.51zm0 179.27l59.76 0 0 119.52-59.76 0 0-119.52zm0 179.27l59.76 0 0 119.52-59.76 0 0-119.52zm0 179.27l59.76 0 0 119.52-59.76 0 0-119.52zm0 179.27l59.76 0 0 119.52-59.76 0 0-119.52zm0 179.27l59.76 0c0 40.6-0.69 74.17 6.34 113.85l-58.81 10.55c-7.87-42.66-7.29-80.98-7.29-124.4zm2658.45-24.37l-59.76 0 0-119.52 59.76 0 0 119.52zm0-179.27l-59.76 0 0-119.52 59.76 0 0 119.52zm0-179.27l-59.76 0 0-119.51 59.76 0 0 119.51zm0-179.27l-59.76 0 0-119.51 59.76 0 0 119.51zm0-179.27l-59.76 0 0-119.51 59.76 0 0 119.51zm0-179.27l-59.76 0 0-119.52 59.76 0 0 119.52zm0-179.27l-59.76 0 0-119.52 59.76 0 0 119.52zm0-179.27l-59.76 0 0-119.52 59.76 0 0 119.52zm0-179.27l-59.76 0c0-39.42 1.22-75.77-5.09-114.5l59.01-9.46c6.85 42.54 5.85 80.57 5.85 123.96zm-19.8-186.05c-11.86-40.16-29.48-80.45-51.55-116.07l-50.84 31.39c19.36 31.34 34.72 66.48 45.14 101.78l57.26-17.11z'/%3E%3Cpath class='fil3' d='M1150.67 141.01l1681.07 0c134.42 0 256.6 54.98 345.16 143.53 88.56 88.56 143.53 210.74 143.53 345.16l0 773.86-59.76 0 0-773.86c0-117.93-48.27-225.16-126.01-302.91-77.76-77.74-184.99-126.01-302.91-126.01l-1681.07 0c-117.93 0-225.16 48.27-302.91 126.01-77.74 77.75-126.01 184.99-126.01 302.91l0 773.86-59.76 0 0-773.86c0-134.42 54.98-256.6 143.53-345.16 88.56-88.55 210.74-143.53 345.16-143.53z'/%3E%3C/g%3E%3C/svg%3E";

const Icon = ({ children, className = '', ...props }: React.SVGProps<SVGSVGElement> & { children: React.ReactNode }) => (
    <svg 
        xmlns="http://www.w3.org/2000/svg" 
        fill="none" 
        viewBox="0 0 24 24" 
        stroke="currentColor" 
        strokeWidth={2} 
        strokeLinecap="round" 
        strokeLinejoin="round" 
        className={`h-5 w-5 ${className}`} 
        {...props}
    >
        {children}
    </svg>
);

export const DashboardIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <rect x="3" y="3" width="7" height="7" />
        <rect x="14" y="3" width="7" height="7" />
        <rect x="14" y="14" width="7" height="7" />
        <rect x="3" y="14" width="7" height="7" />
    </Icon>
);

export const AIIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M12 3c.132 0 .263 0 .393 0a7.5 7.5 0 0 0 7.92 12.446a9 9 0 1 1-8.313-12.454z" />
        <path d="M15 5.5l.5-.5.5.5-.5.5z" />
        <path d="M18 7l.5-.5.5.5-.5.5z" />
        <path d="M20.2 4.5l.3-.3.3.3-.3.3z" />
    </Icon>
);

export const TodayIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <rect x="3" y="4" width="18" height="18" rx="2" ry="2" />
        <line x1="16" y1="2" x2="16" y2="6" />
        <line x1="8" y1="2" x2="8" y2="6" />
        <line x1="3" y1="10" x2="21" y2="10" />
        <path d="M12 14v4" />
        <path d="M10 16h4" />
    </Icon>
);

export const ReportsIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M21.21 15.89A10 10 0 1 1 8 2.83" />
        <path d="M22 12A10 10 0 0 0 12 2v10z" />
    </Icon>
);

export const StorefrontIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="m2 7 4.41-4.41A2 2 0 0 1 7.83 2h8.34a2 2 0 0 1 1.42.59L22 7" />
        <path d="M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8" />
        <path d="M15 22v-4a2 2 0 0 0-2-2h-2a2 2 0 0 0-2 2v4" />
        <path d="M2 7h20" />
        <path d="M22 7v3a2 2 0 0 1-2 2v0a2.7 2.7 0 0 1-1.59-.63.7.7 0 0 0-.82 0A2.7 2.7 0 0 1 16 12a2.7 2.7 0 0 1-1.59-.63.7.7 0 0 0-.82 0A2.7 2.7 0 0 1 12 12a2.7 2.7 0 0 1-1.59-.63.7.7 0 0 0-.82 0A2.7 2.7 0 0 1 8 12a2.7 2.7 0 0 1-1.59-.63.7.7 0 0 0-.82 0A2.7 2.7 0 0 1 4 12a2 2 0 0 1-2-2V7" />
    </Icon>
);

export const DirectoryIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <rect x="3" y="3" width="18" height="18" rx="2" ry="2" />
        <path d="M3 9h18" />
        <path d="M9 21V9" />
    </Icon>
);

export const InventoryIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z" />
        <path d="m3.3 7 8.7 5 8.7-5" />
        <path d="M12 22V12" />
    </Icon>
);

export const ReceiptsIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M4 2v20l2-1 2 1 2-1 2 1 2-1 2 1 2-1 2 1V2l-2 1-2-1-2 1-2-1-2 1-2-1-2 1-2-1Z" />
        <path d="M16 8h-8" />
        <path d="M16 12h-8" />
        <path d="M13 16h-5" />
    </Icon>
);

export const ProformaIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
        <polyline points="14 2 14 8 20 8" />
        <circle cx="12" cy="15" r="2" />
        <path d="M12 13v2h2" />
    </Icon>
);

export const TransactionIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <rect x="2" y="6" width="20" height="12" rx="2" />
        <circle cx="12" cy="12" r="2" />
        <path d="M6 12h.01M18 12h.01" />
    </Icon>
);

export const CommissionIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <circle cx="12" cy="12" r="10" />
        <path d="m16 16-3.89-3.89a2 2 0 0 1 0-2.83l3.89-3.89" />
        <path d="M6 12h12" />
        <path d="M12 12 8.11 8.11a2 2 0 0 0 0 2.83L12 14.89" />
    </Icon>
);

export const ExpensesIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <rect x="2" y="4" width="20" height="16" rx="2" />
        <path d="M7 12h10" />
        <path d="M7 8h2" />
        <path d="M7 16h6" />
    </Icon>
);

export const ExpenseRequestIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M16 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V6z" />
        <path d="M12 18V14" />
        <path d="M10 16h4" />
        <path d="M16 2v4a2 2 0 0 0 2 2h4" />
    </Icon>
);

export const CustomersIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" />
        <circle cx="9" cy="7" r="4" />
        <path d="M23 21v-2a4 4 0 0 0-3-3.87" />
        <path d="M16 3.13a4 4 0 0 1 0 7.75" />
    </Icon>
);

export const StaffIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" />
        <circle cx="9" cy="7" r="4" />
        <circle cx="19" cy="11" r="2" />
        <path d="M19 8v1" />
        <path d="M19 13v1" />
    </Icon>
);

export const InvestorIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <polyline points="23 6 13.5 15.5 8.5 10.5 1 18" />
        <polyline points="17 6 23 6 23 12" />
    </Icon>
);

export const ProfileIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2" />
        <circle cx="12" cy="7" r="4" />
    </Icon>
);

export const ChatHelpIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
        <path d="M12 7v4" />
        <path d="M12 15h.01" />
    </Icon>
);

export const SettingsIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z" />
        <circle cx="12" cy="12" r="3" />
    </Icon>
);

export const LogoutIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
        <polyline points="16 17 21 12 16 7" />
        <line x1="21" y1="12" x2="9" y2="12" />
    </Icon>
);

export const FilePdfIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
        <polyline points="14 2 14 8 20 8" />
        <path d="M9 15h3" />
        <path d="M9 11h6" />
        <path d="M9 19h6" />
    </Icon>
);

export const WeeklyCheckIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="m9 11 3 3L22 4" />
        <path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11" />
    </Icon>
);

export const BriefcaseIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <rect x="2" y="7" width="20" height="14" rx="2" ry="2" />
        <path d="M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16" />
    </Icon>
);

export const BellIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9" />
        <path d="M10.3 21a1.94 1.94 0 0 0 3.4 0" />
    </Icon>
);

export const MenuIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <line x1="3" y1="12" x2="21" y2="12" />
        <line x1="3" y1="6" x2="21" y2="6" />
        <line x1="3" y1="18" x2="21" y2="18" />
    </Icon>
);

export const CloseIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <line x1="18" y1="6" x2="6" y2="18" />
        <line x1="6" y1="6" x2="18" y2="18" />
    </Icon>
);

export const CalculatorIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <rect x="4" y="2" width="16" height="20" rx="2" />
        <line x1="8" y1="6" x2="16" y2="6" />
        <line x1="16" y1="14" x2="16" y2="14.01" />
        <line x1="12" y1="14" x2="12" y2="14.01" />
        <line x1="8" y1="14" x2="8" y2="14.01" />
        <line x1="16" y1="18" x2="16" y2="18.01" />
        <line x1="12" y1="18" x2="12" y2="18.01" />
        <line x1="8" y1="18" x2="8" y2="18.01" />
        <line x1="16" y1="10" x2="16" y2="10.01" />
        <line x1="12" y1="10" x2="12" y2="10.01" />
        <line x1="8" y1="10" x2="8" y2="10.01" />
    </Icon>
);

export const TruckIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <rect x="1" y="3" width="15" height="13" />
        <polygon points="16 8 20 8 23 11 23 16 16 16 16 8" />
        <circle cx="5.5" cy="18.5" r="2.5" />
        <circle cx="18.5" cy="18.5" r="2.5" />
    </Icon>
);

export const ChevronDownIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <svg xmlns="http://www.w3.org/2000/svg" className={`h-4 w-4 ${props.className || ''}`} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" {...props}>
        <polyline points="6 9 12 15 18 9" />
    </svg>
);

export const PlusIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <line x1="12" y1="5" x2="12" y2="19" />
        <line x1="5" y1="12" x2="19" y2="12" />
    </Icon>
);

export const WarningIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z" />
        <line x1="12" y1="9" x2="12" y2="13" />
        <line x1="12" y1="17" x2="12.01" y2="17" />
    </Icon>
);

export const PrintIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <polyline points="6 9 6 2 18 2 18 9" />
        <path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 v5a2 2 0 0 1-2 2h-2" />
        <rect x="6" y="14" width="12" height="8" />
    </Icon>
);

export const DownloadJpgIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
        <polyline points="7 10 12 15 17 10" />
        <line x1="12" y1="15" x2="12" y2="3" />
    </Icon>
);

export const DeleteIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <polyline points="3 6 5 6 21 6" />
        <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
        <line x1="10" y1="11" x2="10" y2="17" />
        <line x1="14" y1="11" x2="14" y2="17" />
    </Icon>
);

export const CartIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <circle cx="8" cy="21" r="1" />
        <circle cx="19" cy="21" r="1" />
        <path d="M2.05 2.05h2l2.66 12.42a2 2 0 0 0 2 1.58h9.78a2 2 0 0 0 1.95-1.57l1.65-7.43H5.12" />
    </Icon>
);

export const BarcodeIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M3 5v14" />
        <path d="M8 5v14" />
        <path d="M12 5v14" />
        <path d="M17 5v14" />
        <path d="M21 5v14" />
    </Icon>
);

export const MoreVertIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <circle cx="12" cy="12" r="1" />
        <circle cx="12" cy="5" r="1" />
        <circle cx="12" cy="19" r="1" />
    </Icon>
);

export const CrownIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="m2 4 3 12h14l3-12-6 7-4-7-4 7-6-7Z" />
        <path d="M12 17H12" />
    </Icon>
);

export const PhoneIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z" />
    </Icon>
);

export const EmailIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7" />
        <rect x="2" y="5" width="20" height="14" rx="2" />
    </Icon>
);

export const CounterIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <rect x="2" y="3" width="20" height="14" rx="2" ry="2" />
        <line x1="8" y1="21" x2="16" y2="21" />
        <line x1="12" y1="17" x2="12" y2="21" />
    </Icon>
);

export const SearchIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <svg xmlns="http://www.w3.org/2000/svg" className={`h-5 w-5 ${props.className || 'text-gray-400'}`} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" {...props}>
        <circle cx="11" cy="11" r="8" />
        <line x1="21" y1="21" x2="16.65" y2="16.65" />
    </svg>
);

export const LinkIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71" />
        <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71" />
    </Icon>
);

export const CreditCardIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <rect x="1" y="4" width="22" height="16" rx="2" ry="2" />
        <line x1="1" y1="10" x2="23" y2="10" />
    </Icon>
);

export const BuildingIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <rect x="4" y="2" width="16" height="20" rx="2" ry="2" />
        <path d="M9 22v-4h6v4" />
        <path d="M8 6h.01M16 6h.01M8 10h.01M16 10h.01M8 14h.01M16 14h.01" />
    </Icon>
);

export const LightBulbIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .5 2.2 1.5 3.1.7.7 1.3 1.5 1.5 2.5" />
        <path d="M9 18h6" />
        <path d="M10 22h4" />
    </Icon>
);

export const UsersGroupIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" />
        <circle cx="9" cy="7" r="4" />
        <path d="M23 21v-2a4 4 0 0 0-3-3.87" />
        <path d="M16 3.13a4 4 0 0 1 0 7.75" />
    </Icon>
);

export const AdminDashboardIcon = DashboardIcon;

export const QRCodeIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <rect x="3" y="3" width="7" height="7" />
        <rect x="14" y="3" width="7" height="7" />
        <rect x="14" y="14" width="7" height="7" />
        <rect x="3" y="14" width="7" height="7" />
        <path d="M7 7h.01M17 7h.01M7 17h.01M17 17h.01" />
    </Icon>
);

export const ChatBubbleIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z" />
    </Icon>
);

export const BankIcon = (props: React.SVGProps<SVGSVGElement>) => (
    <Icon {...props}>
        <path d="M3 21h18" />
        <path d="M3 10h18" />
        <path d="M5 6l7-3 7 3" />
        <path d="M4 10v11" />
        <path d="M20 10v11" />
        <path d="M8 14v3" />
        <path d="M12 14v3" />
        <path d="M16 14v3" />
    </Icon>
);

// --- DUMMY DATA ---

/**
 * Fix: Export DUMMY_ADMIN_BUSINESS_DATA to resolve import error in AdminDashboard.tsx
 */
export const DUMMY_ADMIN_BUSINESS_DATA: AdminBusinessData[] = [
    {
        id: 'biz-001',
        profile: {
            businessName: 'FinTab HQ',
            businessType: 'Retail',
            logo: null,
            businessEmail: 'hq@fintab.io',
            businessPhone: '555-0100',
            dateEstablished: '2023-01-01',
            employeeCount: '10'
        },
        licensingInfo: {
            licenseType: 'Premium',
            enrollmentDate: '2023-01-01',
            trialEndDate: '2024-01-01'
        },
        settings: {
            acceptRemoteOrders: true
        },
        owner: {
            name: 'Admin Principal',
            email: 'admin@fintab.io'
        },
        stats: {
            totalRevenue: 150000,
            salesCount: 1200,
            userCount: 5,
            joinedDate: '2023-01-01',
            status: 'Active'
        }
    },
    {
        id: 'biz-demo',
        profile: {
            businessName: 'FinTab Demo Node',
            businessType: 'Retail',
            logo: FINTAB_LOGO_SVG,
            businessEmail: 'demo@fintab.io',
            businessPhone: '555-0101',
            dateEstablished: '2023-06-01',
            employeeCount: '1-5'
        },
        licensingInfo: {
            licenseType: 'Trial',
            enrollmentDate: '2023-06-01',
            trialEndDate: new Date(Date.now() + 14 * 24 * 60 * 60 * 1000).toISOString()
        },
        settings: {
            acceptRemoteOrders: true
        },
        owner: {
            name: 'Demo Admin',
            email: 'demo@fintab.io'
        },
        stats: {
            totalRevenue: 0,
            salesCount: 0,
            userCount: 1,
            joinedDate: '2023-06-01',
            status: 'Active'
        }
    }
];

export const DUMMY_PRODUCTS: Product[] = [
    {
        id: 'prod-001',
        sku: 'IPH-15P-256',
        name: 'iPhone 15 Pro (256GB)',
        description: 'Advanced mobile terminal with titanium chassis and A17 Pro logic chip.',
        category: 'Electronics',
        price: 1099.00,
        costPrice: 850.00,
        stock: 24,
        imageUrl: 'https://images.unsplash.com/photo-1695048133142-1a20484d256e?q=80&w=400&h=400&auto=format&fit=crop',
        commissionPercentage: 2,
        tieredPricing: [
            { quantity: 5, price: 1049.00 },
            { quantity: 10, price: 999.00 }
        ]
    }
];

export const FINALIZED_SALE_STATUSES: Sale['status'][] = [
    'completed',
    'completed_bank_verified',
    'approved_by_owner'
];

export const COUNTRIES = [
    { name: 'United States', code: 'US', dial_code: '+1', flag: '🇺🇸' },
    { name: 'Canada', code: 'CA', dial_code: '+1', flag: '🇨🇦' },
    { name: 'Haiti', code: 'HT', dial_code: '+509', flag: '🇭🇹' },
];

export const DEFAULT_ANOMALY_SETTINGS: AnomalySettings = {
    cashDiffThreshold: 10,
    cashDiffPercentage: 1,
    receivingMismatchThreshold: 0,
    marginMin: 10,
    marginMax: 200,
    costChangeThreshold: 30,
    expectedSubmissionHourEnd: 21,
    weeklyCheckCount: 5
};

export const DEFAULT_RECEIPT_SETTINGS: ReceiptSettingsData = {
    businessName: 'My Store',
    logo: null,
    slogan: 'Welcome',
    address: '',
    phone: '',
    email: '',
    website: '',
    currencySymbol: '$',
    receiptPrefix: 'RE',
    social: { twitter: '', instagram: '' },
    receiptTitle: 'Sales Receipt',
    thankYouNote: 'Thank you for your business!',
    termsAndConditions: '',
    labels: {
        receiptNumber: 'Receipt #',
        proformaNumber: 'Proforma #',
        date: 'Date',
        time: 'Time',
        customer: 'Customer',
        cashier: 'Cashier',
        payment: 'Payment',
        item: 'Item',
        total: 'Total',
        subtotal: 'Subtotal',
        tax: 'Tax',
        discount: 'Discount',
        grandTotal: 'Grand Total',
        itemCode: 'Code',
        quantity: 'Qty',
        price: 'Price',
        cashReceived: 'Cash Received',
        change: 'Change',
        pMode: 'Mode',
        itemCount: 'Items',
        unitCount: 'Units',
        amount: 'Amount'
    }
};

export const DEFAULT_OWNER_SETTINGS: OwnerSettings = {
    commissionTrackingEnabled: true,
    includeInStaffReports: true,
    showOnLeaderboard: true
};

export const DEFAULT_BUSINESS_SETTINGS: BusinessSettingsData = {
    paymentMethods: ['Cash', 'Card', 'Bank Receipt', 'Mobile Payment'],
    defaultTaxRate: 0,
    rounding: { enabled: false, toNearest: 0.05 },
    delivery: { enabled: false, fee: 0 },
    investorProfitWithdrawalRate: 10,
    investorDistributionPercentage: 100,
    includeOwnerInProfitSharing: true,
    acceptRemoteOrders: true,
    anomalies: DEFAULT_ANOMALY_SETTINGS
};
