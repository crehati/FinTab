

export const getStoredItem = <T,>(key: string, defaultValue: T): T => {
    try {
        const item = localStorage.getItem(key);
        return item ? JSON.parse(item) : defaultValue;
    } catch (error) {
        console.error(`Error reading ${key} from localStorage`, error);
        return defaultValue;
    }
};

export const formatCurrency = (amount: number, currencySymbol: string): string => {
    if (typeof amount !== 'number') {
        amount = 0;
    }
    // Use toLocaleString to get thousand separators based on the user's locale.
    // It handles different conventions (e.g., 1,234.56 vs 1.234,56).
    const formattedAmount = amount.toLocaleString(undefined, {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
    });
    return `${currencySymbol}${formattedAmount}`;
};

/**
 * Formats a number into an abbreviated string (e.g., 1200 -> 1.2K).
 * @param amount The number to format.
 * @returns An abbreviated string representation of the number.
 */
export const formatAbbreviatedNumber = (amount: number): string => {
    if (typeof amount !== 'number') {
        amount = 0;
    }

    const sign = amount < 0 ? "-" : "";
    const absAmount = Math.abs(amount);

    if (absAmount >= 1_000_000) {
        // toFixed(1) gives one decimal, replace removes .0
        return `${sign}${(absAmount / 1_000_000).toFixed(1).replace(/\.0$/, '')}M`;
    }
    if (absAmount >= 1_000) {
        return `${sign}${(absAmount / 1_000).toFixed(1).replace(/\.0$/, '')}K`;
    }
    
    // For numbers less than 1000, show with no decimals for cleaner UI
    return amount.toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 0 });
};


export const formatPhoneNumberForWhatsApp = (fullPhoneNumber: string): string | null => {
    if (!fullPhoneNumber) return null;
    // Remove all non-digit characters, but keep the leading '+'
    let digits = fullPhoneNumber.replace(/[^\d+]/g, '');
    
    // Ensure it starts with a plus, and remove it for now
    if (digits.startsWith('+')) {
        digits = digits.substring(1);
    }
    
    // Remove any other non-numeric characters that might have slipped through
    digits = digits.replace(/\D/g, '');

    // Basic validation: check if it has a reasonable length (e.g., at least 7 digits)
    if (digits.length < 7) {
        return null;
    }
    
    return digits;
};

export const setStoredItemAndDispatchEvent = (key: string, value: any): void => {
    try {
        const stringValue = JSON.stringify(value);
        localStorage.setItem(key, stringValue);
        // The manual dispatch of the 'storage' event has been removed.
        // This was causing an infinite loop where a state update would trigger
        // a localStorage write, which would dispatch an event, which would be
        // caught by the listener in the same window, causing another state update.
        // The native 'storage' event will still fire for other tabs/windows,
        // ensuring cross-tab synchronization. The current tab's UI is updated
        // via React's state management, not this event.
    } catch (error) {
        console.error(`Error writing ${key} to localStorage`, error);
    }
};