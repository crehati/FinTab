import React, { useEffect, useRef } from 'react';
import ReactDOM from 'react-dom';
import { CloseIcon, PrintIcon } from '../constants';
import { loadScript, loadStyle } from '../lib/dom-utils';

// Declare QRCode as it's loaded from a CDN
declare var QRCode: any;

interface PrintQRModalProps {
    isOpen: boolean;
    onClose: () => void;
}

const QR_CODE_VALUE = 'MAKETUP-CLOCK-IN-OUT-V1';

const PrintQRModal: React.FC<PrintQRModalProps> = ({ isOpen, onClose }) => {
    const canvasRef = useRef<HTMLCanvasElement>(null);
    const qrContainerRef = useRef<HTMLDivElement>(null);

    useEffect(() => {
        if (isOpen && canvasRef.current) {
            QRCode.toCanvas(canvasRef.current, QR_CODE_VALUE, { width: 256, margin: 2 }, (error: any) => {
                if (error) console.error('Error generating QR Code:', error);
            });
        }
    }, [isOpen]);

    const modalRoot = document.getElementById('modal-root');
    if (!isOpen || !modalRoot) return null;

    const handlePrint = () => {
        window.print();
    };

    return ReactDOM.createPortal(
        <div className="fixed inset-0 bg-black bg-opacity-60 flex items-center justify-center z-50 p-4 printable-area" role="dialog" aria-modal="true">
            <div className="bg-white rounded-lg shadow-2xl w-full max-w-md max-h-[90vh] flex flex-col">
                <header className="p-4 border-b flex justify-between items-center flex-shrink-0 no-print">
                    <h2 className="text-xl font-bold text-gray-800">Print Clock-In QR Code</h2>
                    <button onClick={onClose} className="p-2 rounded-full text-gray-500 hover:bg-gray-100" aria-label="Close modal">
                        <CloseIcon />
                    </button>
                </header>

                <div ref={qrContainerRef} className="overflow-y-auto bg-gray-50">
                    <div className="p-6 text-center">
                        <h3 className="text-lg font-semibold text-gray-700">Staff Clock-In/Out Point</h3>
                        <p className="text-sm text-gray-500 mt-2 mb-6">
                            Print this QR code and place it at a convenient location for your staff to scan when they clock in or out using the mobile app.
                        </p>
                        <canvas ref={canvasRef} className="mx-auto border rounded-lg shadow-sm" />
                        <p className="text-xs text-gray-400 mt-4">Code: {QR_CODE_VALUE}</p>
                    </div>
                </div>

                <footer className="p-4 bg-white border-t flex justify-end gap-4 flex-shrink-0 no-print">
                    <button onClick={onClose} type="button" className="bg-gray-200 text-gray-800 px-4 py-2 rounded-lg font-semibold hover:bg-gray-300 transition-colors">
                        Close
                    </button>
                    <button onClick={handlePrint} type="button" className="flex items-center gap-2 bg-primary text-white px-4 py-2 rounded-lg font-semibold hover:bg-primary-700 transition-colors">
                        <PrintIcon />
                        Print
                    </button>
                </footer>
            </div>
        </div>,
        modalRoot
    );
};

export default PrintQRModal;