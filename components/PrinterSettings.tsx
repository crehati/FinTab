import React, { useState } from 'react';
import type { PrinterSettingsData } from '../types';
import Card from './Card';
import { PrintIcon } from '../constants';

interface PrinterSettingsProps {
    settings: PrinterSettingsData;
    onUpdateSettings: (settings: PrinterSettingsData) => void;
}

const PrinterSettings: React.FC<PrinterSettingsProps> = ({ settings, onUpdateSettings }) => {
    const [draft, setDraft] = useState(settings);

    const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
        const { name, checked } = e.target;
        setDraft(prev => ({ ...prev, [name]: checked }));
    };

    const handleSave = () => {
        onUpdateSettings(draft);
        alert('Printer settings saved!');
    };

    return (
        <div className="max-w-2xl mx-auto space-y-6">
            <Card title="Printer Settings">
                <div className="space-y-6">
                    <div className="flex items-center justify-between p-4 border rounded-lg bg-gray-50 dark:bg-gray-700/50">
                        <label htmlFor="autoPrint" className="font-medium text-gray-700 dark:text-gray-200">
                            Automatic Browser Printing After Sale
                            <p className="text-sm text-gray-500 dark:text-gray-400 font-normal">Automatically open the browser's print dialog after a sale is completed.</p>
                        </label>
                        <input
                            type="checkbox"
                            id="autoPrint"
                            name="autoPrint"
                            checked={draft.autoPrint}
                            onChange={handleChange}
                            className="h-6 w-6 rounded text-primary focus:ring-primary border-gray-300"
                        />
                    </div>
                    
                    <div className="p-4 border-l-4 border-primary bg-blue-50/60 dark:bg-gray-700/50 dark:border-accent-sky rounded-r-lg">
                        <h4 className="font-semibold text-primary dark:text-accent-sky">Understanding Printing Methods</h4>
                        <div className="mt-2 text-sm text-neutral-dark dark:text-gray-300 space-y-4">
                           <div>
                                <strong className="block">1. Direct Printing (Recommended for Mobile)</strong>
                                <p className="mt-1">
                                    Uses your device's Bluetooth to connect directly to a printer. This provides the best formatting for thermal receipts.
                                </p>
                                <ul className="list-disc list-inside text-xs mt-2 space-y-1 pl-2">
                                    <li><strong className="text-green-600 dark:text-green-400">Requires a Bluetooth LE (BLE) compatible printer.</strong> Many older or cheaper models use "Bluetooth Classic" (SPP) which is <strong className="text-red-600 dark:text-red-400">not supported</strong> by web browsers.</li>
                                    <li>Works best in Chrome/Edge on Android, macOS, and Windows. Not supported on iOS.</li>
                                    <li>Find this option under the <PrintIcon /> icon in the receipt view.</li>
                                </ul>
                           </div>
                           <div>
                                <strong className="block">2. Browser Printing (Universal Fallback)</strong>
                                 <p className="mt-1">
                                    Uses your device's standard print dialog. This works for any printer your computer or phone can see, including USB, Wi-Fi, and some Bluetooth models configured at the OS level.
                                </p>
                                <ul className="list-disc list-inside text-xs mt-2 space-y-1 pl-2">
                                   <li>Receipt formatting may be less precise than Direct Printing.</li>
                                   <li>This is the method used by the "Automatic Printing" toggle above.</li>
                                </ul>
                           </div>
                        </div>
                    </div>

                    <div className="pt-4 border-t text-right">
                        <button onClick={handleSave} className="bg-primary text-white px-6 py-2 rounded-lg font-semibold hover:bg-blue-700 shadow-sm">
                            Save Settings
                        </button>
                    </div>
                </div>
            </Card>
        </div>
    );
};

export default PrinterSettings;