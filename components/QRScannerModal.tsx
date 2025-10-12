
import React, { useState, useEffect, useRef } from 'react';
import type { User } from '../types';
import { CloseIcon } from '../constants';

// Declare Html5Qrcode as it's loaded from a CDN
declare var Html5Qrcode: any;

interface QRScannerModalProps {
    isOpen: boolean;
    onClose: () => void;
    currentUser: User | null;
    onClockInOut: () => void;
}

const QR_CODE_VALUE = 'MAKETUP-CLOCK-IN-OUT-V1';
const QR_READER_ID = 'qr-code-full-region';

const QRScannerModal: React.FC<QRScannerModalProps> = ({ isOpen, onClose, currentUser, onClockInOut }) => {
    const [scanMessage, setScanMessage] = useState<{ type: 'info' | 'success' | 'error'; text: string } | null>(null);
    const scannerRef = useRef<any>(null);

    useEffect(() => {
        if (isOpen) {
            if (!currentUser || currentUser.type !== 'hourly') {
                setScanMessage({ type: 'error', text: 'No hourly staff member is logged in.' });
                return;
            }
            
            setScanMessage({ type: 'info', text: `Ready for ${currentUser.name}. Point camera at the QR code.` });
            
            const html5QrCode = new Html5Qrcode(QR_READER_ID);
            scannerRef.current = html5QrCode;

            const qrCodeSuccessCallback = (decodedText: string) => {
                if (decodedText === QR_CODE_VALUE) {
                    html5QrCode.pause(true);
                    onClockInOut();
                    setScanMessage({ type: 'success', text: `Success! Clocked in/out for ${currentUser.name}.` });
                    setTimeout(() => {
                        onClose();
                    }, 1500);
                } else {
                    setScanMessage({ type: 'error', text: 'QR code not recognized. Please scan the correct code.' });
                }
            };
            
            const qrCodeErrorCallback = (errorMessage: string) => {
                // This callback is called frequently, so we don't want to spam the user.
                // It can be used for debugging if needed.
            };

            const config = { fps: 10, qrbox: { width: 250, height: 250 } };
            
            html5QrCode.start(
                { facingMode: "environment" }, 
                config, 
                qrCodeSuccessCallback, 
                qrCodeErrorCallback
            ).catch((err: any) => {
                setScanMessage({ type: 'error', text: 'Could not start camera. Please grant camera permission.' });
                console.error("Camera start error:", err);
            });
            
            return () => {
                if (scannerRef.current && scannerRef.current.isScanning) {
                    scannerRef.current.stop().catch((err: any) => {
                        console.error("Failed to stop scanner:", err);
                    });
                }
            };
        }
    }, [isOpen, currentUser, onClockInOut, onClose]);

    if (!isOpen) return null;
    
    const getMessageColor = () => {
        if (!scanMessage) return 'text-gray-500';
        switch (scanMessage.type) {
            case 'success': return 'text-green-600 bg-green-50 border-green-200';
            case 'error': return 'text-red-600 bg-red-50 border-red-200';
            case 'info':
            default: return 'text-gray-600 bg-gray-50 border-gray-200';
        }
    }

    return (
        <div className="fixed inset-0 bg-black bg-opacity-75 flex flex-col items-center justify-center z-50" role="dialog" aria-modal="true">
            <div className="bg-white rounded-lg shadow-2xl w-full max-w-md m-4 flex flex-col max-h-[90vh]">
                <header className="p-4 border-b flex justify-between items-center flex-shrink-0">
                    <h2 className="text-xl font-bold text-gray-800">Scan to Clock In/Out</h2>
                    <button onClick={onClose} className="p-2 rounded-full text-gray-500 hover:bg-gray-100" aria-label="Close scanner">
                        <CloseIcon />
                    </button>
                </header>

                <main className="p-6 flex-grow overflow-y-auto">
                    <div id={QR_READER_ID} className="w-full rounded-lg overflow-hidden border bg-white"></div>
                    
                    {scanMessage && (
                        <div className={`mt-4 p-3 rounded-md text-center text-sm font-medium border ${getMessageColor()}`}>
                            {scanMessage.text}
                        </div>
                    )}
                </main>
            </div>
        </div>
    );
};

export default QRScannerModal;