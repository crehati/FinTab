import React, { useRef, useState, useEffect } from 'react';
import ReactDOM from 'react-dom';
import type { CustomPayment, User, BusinessProfile, ReceiptSettingsData } from '../types';
import { CloseIcon, PrintIcon, EmailIcon, DownloadJpgIcon } from '../constants';
import { loadScript } from '../lib/dom-utils';

interface PaymentReceiptModalProps {
    isOpen: boolean;
    onClose: () => void;
    payment: CustomPayment | null;
    user: User;
    businessProfile: BusinessProfile | null;
    receiptSettings: ReceiptSettingsData;
}

const generateReceiptText = (payment: CustomPayment, user: User, businessProfile: BusinessProfile | null, settings: ReceiptSettingsData): string => {
    const cs = settings.currencySymbol;
    let text = '';
    
    text += `*${settings.businessName}*\n`;
    text += `--------------------------------\n\n`;
    text += `*PAYMENT CONFIRMATION*\n\n`;
    text += `Transaction ID: ${payment.id}\n`;
    text += `Date Completed: ${new Date().toLocaleString()}\n`;
    text += `Recipient: ${user.name}\n`;
    text += `Description: ${payment.description}\n`;
    text += `Amount: ${cs}${payment.amount.toFixed(2)}\n\n`;
    text += `This serves as a confirmation that the payment of ${cs}${payment.amount.toFixed(2)} has been successfully completed for ${user.name}.\n\n`;
    text += `Thank you,\n`;
    text += `${settings.businessName}`;

    return text;
}


const PaymentReceiptModal: React.FC<PaymentReceiptModalProps> = ({ isOpen, onClose, payment, user, businessProfile, receiptSettings }) => {
    const receiptRef = useRef<HTMLDivElement>(null);
    const [toastMessage, setToastMessage] = useState<string | null>(null);

    useEffect(() => {
        let timer: number;
        if (toastMessage) {
            timer = window.setTimeout(() => {
                setToastMessage(null);
            }, 3000);
        }
        return () => clearTimeout(timer);
    }, [toastMessage]);

    const modalRoot = document.getElementById('modal-root');
    if (!isOpen || !payment || !modalRoot) return null;

    const cs = receiptSettings.currencySymbol;

    const handlePrint = () => {
        window.print();
    };

    const generateAndDownloadJpg = async (): Promise<boolean> => {
        if (!receiptRef.current) return false;
        try {
            await loadScript('https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js', 'html2canvas');
            const canvas = await (window as any).html2canvas(receiptRef.current, { scale: 3, useCORS: true, backgroundColor: '#ffffff' });
            const link = document.createElement('a');
            link.download = `payment-receipt-${payment.id.slice(-6).toUpperCase()}.jpg`;
            link.href = canvas.toDataURL('image/jpeg', 0.95);
            link.click();
            return true;
        } catch (error) {
            console.error('Error generating image:', error);
            setToastMessage('Could not generate receipt image.');
            return false;
        }
    };

    const handleDownloadJpg = () => {
        generateAndDownloadJpg();
    };

    const handleEmailShare = () => {
        const subject = `Payment Confirmation - ${payment.id}`;
        const body = generateReceiptText(payment, user, businessProfile, receiptSettings);
        const mailtoUrl = `mailto:${user.email}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
        window.location.href = mailtoUrl;
    };

    return ReactDOM.createPortal(
        <>
            <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4 printable-area" role="dialog" aria-modal="true">
                <div className="bg-white rounded-lg shadow-2xl w-full max-w-md max-h-[90vh] flex flex-col">
                     <header className="p-3 border-b flex justify-between items-center flex-shrink-0 no-print">
                        <div className="flex items-center gap-1">
                            <button onClick={handlePrint} title="Print" className="p-2 rounded-full text-gray-600 hover:bg-gray-100"><PrintIcon /></button>
                            <button onClick={handleDownloadJpg} title="Download as JPG" className="p-2 rounded-full text-gray-600 hover:bg-gray-100"><DownloadJpgIcon /></button>
                            <button onClick={handleEmailShare} title="Share via Email" className="p-2 rounded-full text-gray-600 hover:bg-gray-100"><EmailIcon /></button>
                        </div>
                        <button onClick={onClose} className="p-2 rounded-full text-gray-500 hover:bg-gray-100" aria-label="Close modal">
                            <CloseIcon />
                        </button>
                    </header>
                     <div className="overflow-y-auto bg-gray-100">
                        <div ref={receiptRef} className="font-sans text-gray-800 bg-white max-w-sm mx-auto shadow-lg my-6 py-8 px-6">
                            <div className="text-center mb-6">
                                {receiptSettings.logo && (
                                    <img src={receiptSettings.logo} alt="Business Logo" className="w-20 h-auto mx-auto mb-4 object-contain" />
                                )}
                                <h2 className="text-2xl font-bold">{receiptSettings.businessName}</h2>
                                {receiptSettings.address && <p className="text-xs text-gray-500 mt-1">{receiptSettings.address}</p>}
                            </div>

                            <div className="text-center border-y-2 border-dashed border-gray-300 py-4 my-6">
                                <h3 className="text-xl font-semibold uppercase tracking-wider text-gray-700">Payment Confirmation</h3>
                            </div>
                            
                            <div className="space-y-3 text-sm">
                                <div className="flex justify-between">
                                    <span className="font-medium text-gray-500">Transaction ID:</span>
                                    <span className="font-mono text-xs">{payment.id}</span>
                                </div>
                                <div className="flex justify-between">
                                    <span className="font-medium text-gray-500">Date Completed:</span>
                                    <span>{new Date().toLocaleString()}</span>
                                </div>
                                <div className="flex justify-between">
                                    <span className="font-medium text-gray-500">Recipient:</span>
                                    <span>{user.name}</span>
                                </div>
                                 <div className="flex justify-between">
                                    <span className="font-medium text-gray-500">Description:</span>
                                    <span className="text-right">{payment.description}</span>
                                </div>
                            </div>

                            <div className="mt-8 pt-4 border-t-2 border-gray-300">
                                <div className="flex justify-between items-center">
                                    <span className="text-lg font-bold text-gray-800">Amount Paid:</span>
                                    <span className="text-3xl font-bold text-primary">{cs}{payment.amount.toFixed(2)}</span>
                                </div>
                            </div>

                            <div className="mt-8 text-center text-xs text-gray-500">
                                <p>This document confirms the successful payment.</p>
                                <p>{receiptSettings.thankYouNote}</p>
                            </div>
                        </div>
                     </div>
                </div>
            </div>
            {toastMessage && (
                <div className="fixed bottom-10 left-1/2 -translate-x-1/2 bg-neutral-dark text-white px-4 py-2 rounded-lg shadow-lg z-[60] text-sm">
                    {toastMessage}
                </div>
            )}
        </>,
        modalRoot
    );
};

export default PaymentReceiptModal;