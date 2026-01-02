
import { FINTAB_LOGO_SVG } from '../constants';

export const getStoredItem = <T,>(key: string, defaultValue: T): T => {
    const item = localStorage.getItem(key);
    if (item === null || item === 'undefined' || item === 'null') return defaultValue;
    try {
        return JSON.parse(item) as T;
    } catch (error) {
        if (typeof defaultValue === 'string') {
            return item as unknown as T;
        }
        console.error(`Error reading ${key} from localStorage`, error);
        return defaultValue;
    }
};

export const SYSTEM_BRANDING_LOGO_KEY = 'fintab_system_branding_logo';

export const getSystemLogo = (): string => {
    // Fail-safe logic: attempt to get from storage, but strictly default to FINTAB_LOGO_SVG constant if null
    const stored = getStoredItem(SYSTEM_BRANDING_LOGO_KEY, null);
    return stored || FINTAB_LOGO_SVG;
};

export const formatCurrency = (amount: number, currencySymbol: string): string => {
    if (typeof amount !== 'number') {
        amount = 0;
    }
    const formattedAmount = amount.toLocaleString(undefined, {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
    });
    return `${currencySymbol}${formattedAmount}`;
};

export const formatAbbreviatedNumber = (amount: number): string => {
    if (typeof amount !== 'number') {
        amount = 0;
    }
    const sign = amount < 0 ? "-" : "";
    const absAmount = Math.abs(amount);
    if (absAmount >= 1_000_000) {
        return `${sign}${(absAmount / 1_000_000).toFixed(1).replace(/\.0$/, '')}M`;
    }
    if (absAmount >= 1_000) {
        return `${sign}${(absAmount / 1_000).toFixed(1).replace(/\.0$/, '')}K`;
    }
    return amount.toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 0 });
};

export const setStoredItemAndDispatchEvent = (key: string, value: any): void => {
    if (value === undefined) {
        console.warn(`Attempted to store undefined for key: ${key}. Protocol blocked.`);
        return;
    }
    try {
        const stringValue = typeof value === 'string' ? value : JSON.stringify(value);
        localStorage.setItem(key, stringValue);
    } catch (error) {
        console.error(`Error writing ${key} to localStorage`, error);
    }
};
