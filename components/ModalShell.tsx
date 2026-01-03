
import React, { useEffect, useCallback } from 'react';
import SafePortal from './SafePortal';
import { CloseIcon } from '../constants';

interface ModalShellProps {
    isOpen: boolean;
    onClose: () => void;
    title: string;
    description?: string;
    children: React.ReactNode;
    footer?: React.ReactNode;
    maxWidth?: string;
    closeOnBackdropClick?: boolean;
}

const ModalShell: React.FC<ModalShellProps> = ({ 
    isOpen, 
    onClose, 
    title, 
    description, 
    children, 
    footer, 
    maxWidth = 'max-w-lg',
    closeOnBackdropClick = true
}) => {
    const handleKeyDown = useCallback((e: KeyboardEvent) => {
        if (e.key === 'Escape') onClose();
    }, [onClose]);

    useEffect(() => {
        if (isOpen) {
            document.body.style.overflow = 'hidden';
            document.body.classList.add('no-scroll');
            window.addEventListener('keydown', handleKeyDown);
        } else {
            document.body.style.overflow = '';
            document.body.classList.remove('no-scroll');
            window.removeEventListener('keydown', handleKeyDown);
        }
        return () => {
            document.body.style.overflow = '';
            document.body.classList.remove('no-scroll');
            window.removeEventListener('keydown', handleKeyDown);
        };
    }, [isOpen, handleKeyDown]);

    if (!isOpen) return null;

    return (
        <SafePortal containerId="modal-root">
            <div 
                className="fixed inset-0 z-[100] flex items-center justify-center p-3 sm:p-6 font-sans overflow-hidden"
                role="dialog"
                aria-modal="true"
                aria-labelledby="modal-title"
            >
                {/* Backdrop with enhanced blur */}
                <div 
                    className="absolute inset-0 bg-slate-950/70 backdrop-blur-md animate-fade-in" 
                    onClick={closeOnBackdropClick ? onClose : undefined}
                    aria-hidden="true"
                />
                
                <div 
                    className={`relative w-full ${maxWidth} max-h-[92vh] flex flex-col bg-white dark:bg-gray-950 rounded-[2.5rem] sm:rounded-[3.5rem] shadow-[0_35px_60px_-15px_rgba(0,0,0,0.5)] overflow-hidden animate-scale-in border border-white/20 dark:border-white/5`}
                    onClick={(e) => e.stopPropagation()}
                >
                    {/* Unique Gradient Accent at Top */}
                    <div className="absolute top-0 left-0 right-0 h-1.5 bg-gradient-to-r from-primary via-blue-400 to-primary opacity-50"></div>
                    
                    <header className="flex-shrink-0 p-7 sm:p-10 border-b dark:border-gray-900 flex justify-between items-start bg-white/80 dark:bg-gray-950/80 backdrop-blur-md z-20">
                        <div className="pr-12 min-w-0">
                            <h2 id="modal-title" className="text-xl sm:text-3xl font-black text-slate-900 dark:text-white uppercase tracking-tighter leading-none truncate drop-shadow-sm">{title}</h2>
                            {description && (
                                <p className="text-[10px] font-black text-slate-400 uppercase tracking-[0.25em] mt-3 truncate opacity-80">{description}</p>
                            )}
                        </div>
                        {/* High-Target Close Button */}
                        <button 
                            onClick={onClose} 
                            className="p-3 sm:p-4 -mr-3 sm:-mr-4 -mt-3 rounded-2xl text-slate-400 hover:text-slate-900 dark:hover:text-white hover:bg-slate-50 dark:hover:bg-gray-900 transition-all active:scale-90 flex-shrink-0 no-print group"
                            aria-label="Close modal"
                        >
                            <CloseIcon className="w-6 h-6 sm:w-7 sm:h-7 transition-transform group-hover:rotate-90" />
                        </button>
                    </header>

                    <main className="flex-1 overflow-y-auto p-7 sm:p-10 custom-scrollbar min-h-0 bg-slate-50/20 dark:bg-gray-950 relative z-10">
                        {children}
                    </main>

                    {footer && (
                        <footer className="flex-shrink-0 p-7 sm:p-10 border-t dark:border-gray-900 bg-white/50 dark:bg-gray-900/50 backdrop-blur-lg flex flex-col sm:flex-row-reverse gap-4 z-20 no-print">
                            {footer}
                        </footer>
                    )}
                </div>
            </div>
        </SafePortal>
    );
};

export default ModalShell;
