import React, { useRef, useState, useEffect } from 'react';
import ReactDOM from 'react-dom';
import type { Sale, Product, ReceiptSettingsData, User, Customer, PrinterSettingsData, CartItem } from '../types';
import ConfirmationModal from './ConfirmationModal';
import { CloseIcon, PrintIcon, DownloadJpgIcon, WhatsAppBusinessIcon, EmailIcon, DeleteIcon } from '../constants';
import { loadScript } from '../lib/dom-utils';
import { formatCurrency, formatPhoneNumberForWhatsApp } from '../lib/utils';


interface ReceiptModalProps {
    sale: Sale | null;
    onClose: () => void;
    receiptSettings: ReceiptSettingsData;
    onDelete: (saleId: string) => void;
    currentUser: User;
    t: (key: string) => string;
    users: User[];
    customers: Customer[];
    isTrialExpired: boolean;
    printerSettings: PrinterSettingsData;
}

const getEffectivePrice = (item: CartItem): number => {
    if (item.variant) {
        return item.variant.price;
    }
    const { product, quantity } = item;
    if (!product.tieredPricing || product.tieredPricing.length === 0) {
        return product.price;
    }
    const sortedTiers = [...product.tieredPricing].sort((a, b) => b.quantity - a.quantity);
    const applicableTier = sortedTiers.find(tier => quantity >= tier.quantity);
    return applicableTier ? applicableTier.price : product.price;
};

// --- ESC/POS and Plain Text Generation ---
// This function generates a raw text string with ESC/POS (Epson Standard Code for Printers)
// commands embedded. This is the standard protocol for most thermal receipt printers,
// ensuring cross-brand compatibility.
const encoder = new TextEncoder(); // Use UTF-8 encoding as requested
const ESC = '\x1B';
const GS = '\x1D';
const INIT_PRINTER = ESC + '@';
const JUSTIFY_CENTER = ESC + 'a' + '\x01';
const JUSTIFY_LEFT = ESC + 'a' + '\x00';
const BOLD_ON = ESC + 'E' + '\x01';
const BOLD_OFF = ESC + 'E' + '\x00';
const CUT_PAPER = GS + 'V' + '\x00';

const generatePlainTextReceiptForPrinter = (sale: Sale, customer: Customer, user: User, settings: ReceiptSettingsData, isProforma: boolean): string => {
    const cs = settings.currencySymbol;
    const lineWidth = 42; // Standard for 80mm paper

    const center = (text: string) => text.padStart((lineWidth + text.length) / 2, ' ').padEnd(lineWidth, ' ');
    const line = (left: string, right: string) => left.padEnd(lineWidth - right.length, ' ') + right;
    const divider = '-'.repeat(lineWidth) + '\n';

    let output = '';

    // Header
    output += JUSTIFY_CENTER;
    if (settings.businessName) output += BOLD_ON + settings.businessName + BOLD_OFF + '\n';
    if (settings.address) output += settings.address + '\n';
    if (settings.phone) output += settings.phone + '\n';
    output += '\n';

    // Title
    output += BOLD_ON + (isProforma ? 'PROFORMA INVOICE' : settings.receiptTitle) + BOLD_OFF + '\n';
    output += divider;

    // Details
    output += JUSTIFY_LEFT;
    output += line(`${settings.labels.receiptNumber}`, `${settings.receiptPrefix}${sale.id.slice(-6).toUpperCase()}`) + '\n';
    output += line(`${settings.labels.date}:`, `${new Date(sale.date).toLocaleDateString()}`) + '\n';
    output += line(`${settings.labels.time}:`, `${new Date(sale.date).toLocaleTimeString()}`) + '\n';
    output += line(`${settings.labels.customer}:`, customer.name) + '\n';
    if (!isProforma) output += line(`${settings.labels.cashier}:`, user.name) + '\n';
    output += divider;

    // Items Header
    output += BOLD_ON + line('Item', 'Total') + BOLD_OFF + '\n';
    output += line('Qty x Price', '') + '\n';
    output += divider;

    // Items
    sale.items.forEach(item => {
        const price = getEffectivePrice(item);
        const itemTotal = price * item.quantity;
        let itemName = item.product.name;
        if (item.variant) {
            const variantName = item.variant.attributes.map(a => a.value).join(' / ');
            itemName += ` (${variantName})`;
        }
        output += line(itemName, formatCurrency(itemTotal, cs)) + '\n';
        output += line(` ${item.quantity} x ${formatCurrency(price, cs)}`, '') + '\n';
    });
    output += divider;

    // Totals
    output += line(`${settings.labels.subtotal}:`, formatCurrency(sale.subtotal, cs)) + '\n';
    if (sale.discount > 0) output += line(`${settings.labels.discount}:`, `-${formatCurrency(sale.discount, cs)}`) + '\n';
    output += BOLD_ON + line(`${settings.labels.grandTotal}:`, formatCurrency(sale.total, cs)) + BOLD_OFF + '\n';
    
    if (sale.paymentMethod === 'Cash' && sale.cashReceived && sale.change) {
         output += '\n';
         output += line(`${settings.labels.cashReceived}:`, formatCurrency(sale.cashReceived, cs)) + '\n';
         output += line(`${settings.labels.change}:`, formatCurrency(sale.change, cs)) + '\n';
    }
    output += '\n';

    // Footer
    output += JUSTIFY_CENTER;
    output += settings.thankYouNote + '\n';

    // Final commands
    output += '\n\n\n\n'; // Feed paper
    output += CUT_PAPER;

    return INIT_PRINTER + output;
};


const generateReceiptText = (sale: Sale, customer: Customer, user: User, settings: ReceiptSettingsData): string => {
    const isProforma = sale.status === 'proforma';
    const cs = settings.currencySymbol;
    let text = '';

    // Header
    text += `*${settings.businessName}*\n`;
    text += `${settings.address}\n`;
    text += `${settings.phone}\n`;
    if (!isProforma) text += `Sold by: ${user.name}\n`;
    text += "--------------------------------\n\n";

    // Client Info
    text += `*${customer.name}*\n`;
    text += `${customer.phone}\n\n`;

    // Receipt Details
    const receiptNum = isProforma 
        ? `${settings.labels.proformaNumber} ${settings.receiptPrefix}${sale.id.slice(-6).toUpperCase()}`
        : `${settings.labels.receiptNumber} ${settings.receiptPrefix}${sale.id.slice(-6).toUpperCase()}`;
    text += `${receiptNum}\n`;
    text += `${new Date(sale.date).toLocaleString()}\n\n`;

    // Summary Box
    const itemCount = sale.items.length;
    const unitCount = sale.items.reduce((sum, item) => sum + item.quantity, 0);
    text += `*${settings.labels.pMode}:* ${sale.paymentMethod || 'N/A'}\n`;
    text += `*${settings.labels.itemCount}:* ${itemCount}\n`;
    text += `*${settings.labels.unitCount}:* ${unitCount}\n`;
    text += `*${settings.labels.amount}:* ${formatCurrency(sale.total, cs)}\n`;
    text += "--------------------------------\n";

    // Items
    sale.items.forEach(item => {
        const price = getEffectivePrice(item);
        const itemTotal = price * item.quantity;
        let itemName = item.product.name;
        if (item.variant) {
            const variantName = item.variant.attributes.map(a => a.value).join(' / ');
            itemName += ` (${variantName})`;
        }
        text += `${itemName}\n`;
        if (item.product.description && !item.variant) {
            text += `  (${item.product.description})\n`;
        }
        text += `  ${item.quantity} x ${formatCurrency(price, cs)} -> ${formatCurrency(itemTotal, cs)}\n`;
    });
    text += "--------------------------------\n";

    // Totals
    text += `${settings.labels.subtotal}: ${formatCurrency(sale.subtotal, cs)}\n`;
    if (sale.discount > 0) {
        text += `${settings.labels.discount}: -${formatCurrency(sale.discount, cs)}\n`;
    }
    text += `*${settings.labels.grandTotal}: ${formatCurrency(sale.total, cs)}*\n\n`;
    
    // Footer
    text += `${settings.thankYouNote}\n`;

    return text;
};


const ActionButton: React.FC<{ children: React.ReactNode; onClick: () => void; title: string; className?: string; }> = ({ children, onClick, title, className = '' }) => (
    <button
        onClick={onClick}
        title={title}
        className={`p-2 rounded-full text-gray-600 hover:bg-gray-100 hover:text-primary transition-colors focus:outline-none focus:ring-2 focus:ring-primary ${className}`}
        aria-label={title}
    >
        {children}
    </button>
);


const ReceiptModal: React.FC<ReceiptModalProps> = ({ sale, onClose, receiptSettings, onDelete, currentUser, t, users, customers, isTrialExpired, printerSettings }) => {
    const receiptRef = useRef<HTMLDivElement>(null);
    const printInitiated = useRef(false);
    const [isConfirmOpen, setIsConfirmOpen] = useState(false);
    const [toastMessage, setToastMessage] = useState<string | null>(null);
    const [printStatus, setPrintStatus] = useState<{type: 'info' | 'success' | 'error', message: string} | null>(null);


    useEffect(() => {
        let timer: number;
        if (toastMessage) {
            timer = window.setTimeout(() => {
                setToastMessage(null);
            }, 4000); // 4 seconds
        }
        return () => clearTimeout(timer);
    }, [toastMessage]);
    
    // Auto-print logic
    useEffect(() => {
        // Only auto-print for new sales, not when viewing old ones.
        // We guess it's a "new" sale if it was created in the last 10 seconds.
        const isRecent = sale && (new Date().getTime() - new Date(sale.date).getTime()) < 10000;

        if (sale && printerSettings.autoPrint && isRecent && !printInitiated.current) {
            printInitiated.current = true;
            // A short delay to allow the modal content to render before printing
            const timer = setTimeout(() => {
                window.print();
            }, 500);
            return () => clearTimeout(timer);
        }
    }, [sale, printerSettings.autoPrint]);

    const modalRoot = document.getElementById('modal-root');

    if (!sale || !modalRoot) return null;
    
    const customer = customers.find(c => c.id === sale.customerId);
    const user = users.find(u => u.id === sale.userId);

    if (!customer || !user) {
        // Handle case where customer or user might not be found (e.g., deleted)
        return null; 
    }
    
    const isProforma = sale.status === 'proforma';
    const canDelete = currentUser && ['Owner', 'Manager'].includes(currentUser.role);

    const handleBrowserPrint = () => {
        window.print();
    };

    const handleDirectPrint = async () => {
        if (!('bluetooth' in navigator)) {
            setPrintStatus({ type: 'error', message: 'Web Bluetooth is not supported on this browser. Try Chrome or Edge on a desktop or Android device.' });
            setTimeout(() => setPrintStatus(null), 8000);
            return;
        }

        let device: any;
        try {
            setPrintStatus({ type: 'info', message: 'Searching for compatible BLE printers... Please choose from the popup.' });
            device = await (navigator as any).bluetooth.requestDevice({
                acceptAllDevices: true,
                optionalServices: ['000018f0-0000-1000-8000-00805f9b34fb'] // A common service for some printers
            });

            setPrintStatus({ type: 'info', message: `Connecting to ${device.name || 'device'}...` });
            const server = await device.gatt.connect();

            setPrintStatus({ type: 'info', message: 'Discovering services...' });
            const services = await server.getPrimaryServices();

            if (!services || services.length === 0) {
                device.gatt.disconnect();
                throw new Error("No compatible services found. This is likely a Bluetooth Classic (SPP) printer (like Epson, Xprinter, Sunmi) which is not supported by web browsers for direct printing. Please use the 'Browser Print' option instead.");
            }

            setPrintStatus({ type: 'info', message: 'Finding printable service...' });
            let writableChar = null;
            for (const service of services) {
                const characteristics = await service.getCharacteristics();
                // Find a characteristic that supports 'write' or 'write without response'
                const foundChar = characteristics.find((c: any) => c.properties.write || c.properties.writeWithoutResponse);
                if (foundChar) {
                    writableChar = foundChar;
                    break; 
                }
            }
            
            if (!writableChar) {
                device.gatt.disconnect();
                throw new Error("Found a BLE device, but it has no writable service for printing. This printer is not compatible with direct web printing. Try 'Browser Print'.");
            }
            
            setPrintStatus({ type: 'info', message: 'Generating receipt data...' });
            const receiptText = generatePlainTextReceiptForPrinter(sale, customer, user, receiptSettings, isProforma);
            const data = encoder.encode(receiptText);

            setPrintStatus({ type: 'info', message: 'Sending data to printer...' });
            // Send data in chunks to avoid overwhelming the printer's buffer
            const chunkSize = 100; 
            for (let i = 0; i < data.length; i += chunkSize) {
                // Use writeWithoutResponse for faster printing, as we don't need an ack for each chunk.
                await writableChar.writeValueWithoutResponse(data.subarray(i, i + chunkSize));
            }
            
            setPrintStatus({ type: 'success', message: 'Print successful!' });
            device.gatt.disconnect();
            setTimeout(() => setPrintStatus(null), 5000);

        } catch (error: any) {
            console.error('Bluetooth printing error:', error);
            if (device && device.gatt.connected) {
                device.gatt.disconnect();
            }
            
            let errorMessage = `Printing failed: ${error.message}`;
            if (error.name === 'NotFoundError') {
                errorMessage = "Print cancelled. If you couldn't find your printer in the list, it's likely not a compatible Bluetooth LE (BLE) model. Please try the 'Browser Print' option.";
            } else if (error.name === 'NotAllowedError') {
                 errorMessage = 'Bluetooth access was denied. Please allow it in your browser settings.';
            }
            
            setPrintStatus({ type: 'error', message: errorMessage });
            setTimeout(() => setPrintStatus(null), 8000);
        }
    };


    const generateAndDownloadJpg = async (): Promise<boolean> => {
        if (!receiptRef.current) return false;
        try {
            await loadScript('https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js', 'html2canvas');
            const canvas = await (window as any).html2canvas(receiptRef.current, { scale: 3, useCORS: true, backgroundColor: '#ffffff' });
            const link = document.createElement('a');
            link.download = `${isProforma ? 'proforma' : 'receipt'}-${sale.id.slice(-6).toUpperCase()}.jpg`;
            link.href = canvas.toDataURL('image/jpeg', 0.95);
            link.click();
            return true;
        } catch (error) {
            console.error('Error generating image:', error);
            setToastMessage(t('whatsapp.error'));
            return false;
        }
    };

    const handleDownloadJpg = () => {
        generateAndDownloadJpg();
    };
    
    const handleWhatsAppShare = async () => {
        const formattedPhone = formatPhoneNumberForWhatsApp(customer.phone);
        if (!formattedPhone) {
            setToastMessage(t('whatsapp.phoneError'));
            return;
        }
        
        const jpgGenerated = await generateAndDownloadJpg();

        if (jpgGenerated) {
            setToastMessage(t('whatsapp.downloading'));
            const message = t('whatsapp.shareMessage').replace('[Client Name]', customer.name);
            const whatsappUrl = `https://wa.me/${formattedPhone}?text=${encodeURIComponent(message)}`;
            window.open(whatsappUrl, '_blank');
        }
    };
    
    const handleEmailShare = () => {
        if (!customer.email) {
            alert("Customer email is not available.");
            return;
        }
        const subject = isProforma ? `Proforma Invoice #${sale.id.slice(-6).toUpperCase()}` : `Receipt #${sale.id.slice(-6).toUpperCase()}`;
        const body = generateReceiptText(sale, customer, user, receiptSettings);
        const mailtoUrl = `mailto:${customer.email}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
        window.location.href = mailtoUrl;
    };

    const handleDeleteConfirmed = () => {
        onDelete(sale.id);
        setIsConfirmOpen(false);
        onClose();
    };

    const cs = receiptSettings.currencySymbol;
    const totalItems = sale.items.length;
    const totalUnits = sale.items.reduce((sum, item) => sum + item.quantity, 0);

    const isCompletedSale = sale.status === 'completed';

    const confirmationMessage = () => {
        if (isCompletedSale) {
            return "Are you sure you want to delete this receipt? This will permanently remove the sale record AND RESTORE the items to your inventory. This action cannot be undone.";
        }
        if (isProforma) {
            return "Are you sure you want to delete this proforma invoice? This action will not affect your inventory levels and cannot be undone.";
        }
        // Default message for other statuses like 'pending_approval' or 'rejected'
        return "Are you sure you want to delete this record? This action cannot be undone.";
    };

    const confirmationTitle = isProforma ? "Delete Proforma Invoice" : "Delete Receipt";


    return ReactDOM.createPortal(
        <>
            <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4 font-sans printable-area" role="dialog" aria-modal="true">
                <div className="bg-white rounded-lg shadow-2xl w-full max-w-lg max-h-[90vh] flex flex-col">
                    <header className="p-3 border-b flex justify-between items-center flex-shrink-0 no-print">
                        <div className="flex items-center gap-1">
                            <ActionButton title="Direct Print (Bluetooth LE)" onClick={handleDirectPrint}><PrintIcon /></ActionButton>
                            <button onClick={handleBrowserPrint} className="px-3 py-1.5 text-xs font-semibold text-gray-700 bg-gray-100 rounded-md hover:bg-gray-200">Browser Print</button>
                            <ActionButton title="Download as JPG" onClick={handleDownloadJpg}><DownloadJpgIcon /></ActionButton>
                            <ActionButton title="Share via WhatsApp" onClick={handleWhatsAppShare}><WhatsAppBusinessIcon /></ActionButton>
                            <ActionButton title="Share via Email" onClick={handleEmailShare}><EmailIcon /></ActionButton>
                            {canDelete && <ActionButton title="Delete Receipt" onClick={() => setIsConfirmOpen(true)} className="hover:text-red-600"><DeleteIcon /></ActionButton>}
                        </div>
                        <button onClick={onClose} className="p-2 rounded-full text-gray-500 hover:bg-gray-100" aria-label="Close modal">
                            <CloseIcon />
                        </button>
                    </header>

                    <div className="overflow-y-auto bg-gray-100">
                        <div ref={receiptRef} className="font-sans text-gray-800 bg-white max-w-xs mx-auto text-sm shadow-lg my-6 py-6 px-4" style={{ fontFamily: 'Arial, sans-serif' }}>
                            {/* Header */}
                            <div className="text-center pt-6">
                                {receiptSettings.logo && (
                                    <img src={receiptSettings.logo} alt="Business Logo" className="w-20 h-auto mx-auto mb-4 object-contain" />
                                )}
                                <h2 className="text-xl font-bold">{receiptSettings.businessName}</h2>
                                <p className="text-xs italic text-gray-600">{receiptSettings.slogan}</p>
                                <p className="text-xs mt-2">{receiptSettings.address}</p>
                                <p className="text-xs">{receiptSettings.phone}</p>
                                {!isProforma && <p className="text-[10px] mt-2">Sold by: {user.name}</p>}
                            </div>
                             {/* Title */}
                            <div className="text-center pt-4 pb-2 border-b border-black">
                                {isProforma ? (
                                    <h3 className="text-lg font-bold uppercase text-blue-900">Proforma Invoice</h3>
                                ) : (
                                    <h3 className="text-lg font-bold">{receiptSettings.receiptTitle}</h3>
                                )}
                            </div>


                             {/* Customer/Sale Info */}
                            <div className="text-center mt-3">
                                <p className="font-bold text-base">{customer.name}</p>
                                <p className="text-xs">{customer.phone}</p>
                            </div>
                            
                            <div className="text-center mt-3 text-xs space-y-1">
                                <p>{isProforma ? receiptSettings.labels.proformaNumber : receiptSettings.labels.receiptNumber} {receiptSettings.receiptPrefix}{sale.id.slice(-6).toUpperCase()}</p>
                                <p>{new Date(sale.date).toLocaleString()}</p>
                            </div>
                            
                            {/* Summary Box */}
                            {!isProforma && (
                                <div className="mt-3 text-xs text-center">
                                    <div className="grid grid-cols-4 gap-1 p-1 font-bold text-black bg-gray-100 rounded-t-md">
                                        <div>{receiptSettings.labels.pMode}</div>
                                        <div>{receiptSettings.labels.itemCount}</div>
                                        <div>{receiptSettings.labels.unitCount}</div>
                                        <div>{receiptSettings.labels.amount}</div>
                                    </div>
                                    <div className="grid grid-cols-4 gap-1 p-1 border border-t-0 border-gray-200 rounded-b-md">
                                        <div>{sale.paymentMethod || 'N/A'}</div>
                                        <div className="tabular-nums">{totalItems}</div>
                                        <div className="tabular-nums">{totalUnits.toFixed(0)}</div>
                                        <div className="font-semibold tabular-nums">{formatCurrency(sale.total, cs)}</div>
                                    </div>
                                </div>
                            )}
                            
                            <div className="my-2 border-t border-black" />

                            {/* Items */}
                            <div className="text-xs">
                                <div className="grid grid-cols-12 gap-x-2 p-1 font-bold text-black text-left bg-gray-100 rounded-t-md">
                                    <div className="col-span-3">{receiptSettings.labels.item}</div>
                                    <div className="col-span-3 text-center">{receiptSettings.labels.price}</div>
                                    <div className="col-span-3 text-center">{receiptSettings.labels.quantity}</div>
                                    <div className="col-span-3 text-right">{receiptSettings.labels.total}</div>
                                </div>
                                {sale.items.map(item => {
                                    const effectivePrice = getEffectivePrice(item);
                                    return (
                                        <div key={item.variant ? item.variant.id : item.product.id} className="grid grid-cols-12 gap-x-2 py-2 border-b border-dashed border-gray-300 items-start last:border-b-0">
                                            <div className="col-span-3 break-words">
                                                <p className="leading-snug font-semibold whitespace-normal line-clamp-3">{item.product.name}</p>
                                                {item.variant ? (
                                                    <p className="text-gray-500 text-[10px] leading-snug mt-0.5 whitespace-normal">
                                                        {item.variant.attributes.map(a => a.value).join(' / ')}
                                                    </p>
                                                ) : item.product.description && (
                                                    <p className="text-gray-500 text-[10px] leading-snug mt-0.5 whitespace-normal">{item.product.description}</p>
                                                )}
                                            </div>
                                            <div className="col-span-3 text-center tabular-nums">{formatCurrency(effectivePrice, cs)}</div>
                                            <div className="col-span-3 text-center tabular-nums">{item.quantity}</div>
                                            <div className="col-span-3 text-right font-semibold tabular-nums">{formatCurrency(effectivePrice * item.quantity, cs)}</div>
                                        </div>
                                    );
                                })}
                            </div>

                            {/* Totals */}
                            <div className="mt-4 text-xs space-y-1">
                                <div className="flex justify-between">
                                    <span className="font-semibold">{receiptSettings.labels.subtotal}</span>
                                    <span className="tabular-nums">{formatCurrency(sale.subtotal, cs)}</span>
                                </div>
                                
                                {sale.discount > 0 && (
                                     <div className="flex justify-between">
                                        <span className="font-semibold">{receiptSettings.labels.discount}</span>
                                        <span className="tabular-nums">-{formatCurrency(sale.discount, cs)}</span>
                                    </div>
                                )}

                                <div className="flex justify-between font-bold text-base mt-2 pt-2 border-t border-black">
                                    <span>{receiptSettings.labels.grandTotal}</span>
                                    <span className="tabular-nums">{formatCurrency(sale.total, cs)}</span>
                                </div>
                                
                                {sale.paymentMethod === 'Cash' && sale.cashReceived && (
                                  <div className="flex justify-between mt-2 pt-2 border-t border-dashed">
                                      <span className="font-semibold">{receiptSettings.labels.cashReceived}</span>
                                      <span className="tabular-nums">{formatCurrency(sale.cashReceived, cs)}</span>
                                  </div>
                                )}
                                {sale.paymentMethod === 'Cash' && sale.change && (
                                    <div className="flex justify-between">
                                        <span className="font-semibold">{receiptSettings.labels.change}</span>
                                        <span className="tabular-nums">{formatCurrency(sale.change, cs)}</span>
                                    </div>
                                )}
                            </div>
                             <div className="my-2 border-t border-black" />

                            {/* Footer */}
                            <div className="text-center mt-4 text-xs">
                                <p>{receiptSettings.thankYouNote}</p>
                            </div>
                             {isTrialExpired && (
                                <div className="text-center mt-4 pt-4 border-t border-dashed">
                                    <p className="text-xs text-gray-500 font-sans">Powered by FinTab</p>
                                </div>
                            )}
                        </div>
                    </div>
                </div>
            </div>
            {toastMessage && (
                <div className="fixed bottom-10 left-1/2 -translate-x-1/2 bg-neutral-dark text-white px-4 py-2 rounded-lg shadow-lg z-[60] text-sm">
                    {toastMessage}
                </div>
            )}
            {printStatus && (
                <div className={`fixed top-20 left-1/2 -translate-x-1/2 px-4 py-2 rounded-lg shadow-lg z-[60] text-sm text-white ${
                    printStatus.type === 'success' ? 'bg-green-500' : printStatus.type === 'error' ? 'bg-red-500' : 'bg-blue-500'
                }`}>
                    {printStatus.message}
                </div>
            )}
            <ConfirmationModal
                isOpen={isConfirmOpen}
                onClose={() => setIsConfirmOpen(false)}
                onConfirm={handleDeleteConfirmed}
                title={confirmationTitle}
                message={confirmationMessage()}
            />
        </>,
        modalRoot
    );
};

export default ReceiptModal;