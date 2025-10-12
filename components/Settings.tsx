

import React, { useState, useRef, useEffect } from 'react';
import { NavLink } from 'react-router-dom';
import Card from './Card';
import { User, ReceiptSettingsData } from '../types';

// Icons for settings items
const ThemeIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-6 w-6 text-neutral-medium" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z" />
    </svg>
);
const LanguageIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-6 w-6 text-neutral-medium" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M3 5h12M9 3v2m4 13l4-4M19 17l-4-4m-4 4h4m-6 4H7a2 2 0 01-2-2V7a2 2 0 012-2h10a2 2 0 012 2v6a2 2 0 01-2 2h-1l-4 4z" /></svg>
);
const CurrencyIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-6 w-6 text-neutral-medium" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8c-1.657 0-3 .895-3 2s1.343 2 3 2 3 .895 3 2-1.343 2-3 2m0-8c1.11 0 2.08.402 2.599 1M12 8V7m0 10v-1m0 0c-1.11 0-2.08-.402-2.599-1M9.401 9a2.001 2.001 0 00-1.414-1.414M12 16c-1.657 0-3-.895-3-2s1.343-2 3-2m0 0c1.657 0 3 .895 3 2s-1.343 2-3 2m0-10a9 9 0 110 18 9 9 0 010-18z" /></svg>
);
const ReceiptIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-6 w-6 text-neutral-medium" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" /></svg>
);
const PermissionsIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-6 w-6 text-neutral-medium" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z" /></svg>
);
const BusinessIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-6 w-6 text-neutral-medium" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4" /></svg>
);
const GeneralIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-6 w-6 text-neutral-medium" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" /><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" /></svg>
);
const PrinterIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-6 w-6 text-neutral-medium" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17 17h2a2 2 0 002-2v-4a2 2 0 00-2-2H5a2 2 0 00-2 2v4a2 2 0 002 2h2m2 4h6a2 2 0 002-2v-4a2 2 0 00-2-2H9a2 2 0 00-2 2v4a2 2 0 002 2zm8-12V5a2 2 0 00-2-2H9a2 2 0 00-2 2v4h10z" /></svg>
);
const ChevronDownIcon = () => (
    <svg className="h-5 w-5 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" /></svg>
);
const ArrowIcon = () => (
    <svg className="h-5 w-5 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" /></svg>
);

interface SettingsProps {
    language: string;
    setLanguage: (langCode: any) => void;
    t: (key: string) => string;
    currentUser: User;
    receiptSettings: ReceiptSettingsData;
    setReceiptSettings: (settings: ReceiptSettingsData) => void;
    theme: 'light' | 'dark';
    setTheme: (theme: 'light' | 'dark') => void;
}

const languages = [
    { name: 'English', code: 'en' },
    { name: 'Español', code: 'es' },
    { name: 'Français', code: 'fr' },
    { name: 'Deutsch', code: 'de' },
    { name: '简体中文', code: 'zh' },
    { name: 'Kreyòl Ayisyen', code: 'ht' },
];

const currencies = [
    { name: 'USD ($)', symbol: '$' },
    { name: 'EUR (€)', symbol: '€' },
    { name: 'GBP (£)', symbol: '£' },
    { name: 'JPY (¥)', symbol: '¥' },
    { name: 'CAD (C$)', symbol: 'C$' },
    { name: 'AUD (A$)', symbol: 'A$' },
    { name: 'CHF (Fr)', symbol: 'Fr' },
    { name: 'CNY (CN¥)', symbol: 'CN¥' },
    { name: 'INR (₹)', symbol: '₹' },
    { name: 'BRL (R$)', symbol: 'R$' },
    { name: 'RUB (₽)', symbol: '₽' },
    { name: 'MXN (MX$)', symbol: 'MX$' },
    { name: 'KRW (₩)', symbol: '₩' },
    { name: 'ZAR (R)', symbol: 'R' },
    { name: 'HTG (G)', symbol: 'G' },
];


const Settings: React.FC<SettingsProps> = ({ language, setLanguage, t, currentUser, receiptSettings, setReceiptSettings, theme, setTheme }) => {
    const [languageDropdownOpen, setLanguageDropdownOpen] = useState(false);
    const [currencyDropdownOpen, setCurrencyDropdownOpen] = useState(false);
    const languageDropdownRef = useRef<HTMLDivElement>(null);
    const currencyDropdownRef = useRef<HTMLDivElement>(null);
    
    const selectedLanguage = languages.find(l => l.code === language) || languages[0];
    const selectedCurrency = currencies.find(c => c.symbol === receiptSettings.currencySymbol) || currencies[0];

    const otherSettings = [
        { key: 'settings.receipts', icon: <ReceiptIcon />, to: '/settings/receipts' },
        ...(currentUser.role === 'Owner' ? [{ key: 'settings.permissions', icon: <PermissionsIcon />, to: '/settings/permissions' }] : []),
        { key: 'settings.business', icon: <BusinessIcon />, to: '/settings/business' },
        { key: 'settings.general', icon: <GeneralIcon /> },
        { key: 'settings.printer', icon: <PrinterIcon />, to: '/settings/printer' }
    ];

    // Close dropdown when clicking outside
    useEffect(() => {
        const handleClickOutside = (event: MouseEvent) => {
            if (languageDropdownRef.current && !languageDropdownRef.current.contains(event.target as Node)) {
                setLanguageDropdownOpen(false);
            }
            if (currencyDropdownRef.current && !currencyDropdownRef.current.contains(event.target as Node)) {
                setCurrencyDropdownOpen(false);
            }
        };
        document.addEventListener("mousedown", handleClickOutside);
        return () => document.removeEventListener("mousedown", handleClickOutside);
    }, [languageDropdownRef, currencyDropdownRef]);

    const handleThemeToggle = () => {
        setTheme(theme === 'light' ? 'dark' : 'light');
    };

    return (
        <div className="max-w-4xl mx-auto">
            <Card title={t('settings.title')}>
                <div className="divide-y divide-neutral-light dark:divide-gray-700">
                    {/* Dark Mode Toggle */}
                    <div className="flex items-center justify-between p-4">
                        <div className="flex items-center">
                            <ThemeIcon />
                            <span className="ml-4 text-lg text-neutral-dark dark:text-gray-200 font-medium">Dark Mode</span>
                        </div>
                        <label htmlFor="theme-toggle" className="flex items-center cursor-pointer">
                            <div className="relative">
                                <input 
                                    type="checkbox" 
                                    id="theme-toggle" 
                                    className="sr-only"
                                    checked={theme === 'dark'}
                                    onChange={handleThemeToggle}
                                />
                                <div className="block bg-gray-300 dark:bg-gray-600 w-14 h-8 rounded-full"></div>
                                <div className={`dot absolute left-1 top-1 bg-white w-6 h-6 rounded-full transition-transform transform ${theme === 'dark' ? 'translate-x-6' : ''}`}></div>
                            </div>
                        </label>
                    </div>

                    {/* Language Setting with Dropdown */}
                    <div className="relative" ref={languageDropdownRef}>
                        <div 
                            className="flex items-center justify-between p-4 hover:bg-neutral-light/50 dark:hover:bg-gray-700/50 cursor-pointer transition-colors duration-150"
                            onClick={() => setLanguageDropdownOpen(!languageDropdownOpen)}
                        >
                            <div className="flex items-center">
                                <LanguageIcon />
                                <span className="ml-4 text-lg text-neutral-dark dark:text-gray-200 font-medium">{t('settings.language')}</span>
                            </div>
                            <div className="flex items-center">
                                <span className="text-neutral-medium dark:text-gray-400 mr-2">{selectedLanguage.name}</span>
                                <ChevronDownIcon />
                            </div>
                        </div>
                        {languageDropdownOpen && (
                            <div className="absolute z-10 w-full mt-1 bg-white dark:bg-gray-800 rounded-md shadow-lg border border-neutral-light dark:border-gray-700">
                                <ul className="py-1">
                                    {languages.map(lang => (
                                        <li 
                                            key={lang.code}
                                            onClick={() => {
                                                setLanguage(lang.code);
                                                setLanguageDropdownOpen(false);
                                            }}
                                            className="px-4 py-2 text-neutral-dark dark:text-gray-200 hover:bg-primary/10 dark:hover:bg-gray-700 hover:text-primary cursor-pointer"
                                        >
                                            {lang.name}
                                        </li>
                                    ))}
                                </ul>
                            </div>
                        )}
                    </div>

                    {/* Currency Setting with Dropdown */}
                    <div className="relative" ref={currencyDropdownRef}>
                        <div 
                            className="flex items-center justify-between p-4 hover:bg-neutral-light/50 dark:hover:bg-gray-700/50 cursor-pointer transition-colors duration-150"
                            onClick={() => setCurrencyDropdownOpen(!currencyDropdownOpen)}
                        >
                            <div className="flex items-center">
                                <CurrencyIcon />
                                <span className="ml-4 text-lg text-neutral-dark dark:text-gray-200 font-medium">{t('settings.currency')}</span>
                            </div>
                            <div className="flex items-center">
                                <span className="text-neutral-medium dark:text-gray-400 mr-2">{selectedCurrency.name}</span>
                                <ChevronDownIcon />
                            </div>
                        </div>
                        {currencyDropdownOpen && (
                            <div className="absolute z-10 w-full mt-1 bg-white dark:bg-gray-800 rounded-md shadow-lg border border-neutral-light dark:border-gray-700">
                                <ul className="py-1">
                                    {currencies.map(currency => (
                                        <li 
                                            key={currency.symbol}
                                            onClick={() => {
                                                setReceiptSettings({ ...receiptSettings, currencySymbol: currency.symbol });
                                                setCurrencyDropdownOpen(false);
                                            }}
                                            className="px-4 py-2 text-neutral-dark dark:text-gray-200 hover:bg-primary/10 dark:hover:bg-gray-700 hover:text-primary cursor-pointer"
                                        >
                                            {currency.name}
                                        </li>
                                    ))}
                                </ul>
                            </div>
                        )}
                    </div>

                    {/* Other Settings */}
                    {otherSettings.map(item => {
                        const content = (
                            <>
                                <div className="flex items-center">
                                    {item.icon}
                                    <span className="ml-4 text-lg text-neutral-dark dark:text-gray-200 font-medium">{t(item.key)}</span>
                                </div>
                                <ArrowIcon />
                            </>
                        );
                        
                        if (item.to) {
                            return (
                                <NavLink key={item.key} to={item.to} className="flex items-center justify-between p-4 hover:bg-neutral-light/50 dark:hover:bg-gray-700/50 cursor-pointer transition-colors duration-150">
                                    {content}
                                </NavLink>
                            );
                        }

                        return (
                            <div key={item.key} className="flex items-center justify-between p-4 hover:bg-neutral-light/50 dark:hover:bg-gray-700/50 cursor-not-allowed opacity-50 transition-colors duration-150">
                                {content}
                            </div>
                        );
                    })}
                </div>
            </Card>
        </div>
    );
};

export default Settings;