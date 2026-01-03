
import React from 'react';
import ModalShell from './ModalShell';
import { WarningIcon } from '../constants';

interface ConfirmationModalProps {
  isOpen: boolean;
  onClose: () => void;
  onConfirm: () => void;
  title: string;
  message: string;
  amount?: number | string;
  currencySymbol?: string;
  variant?: 'primary' | 'danger';
  isIrreversible?: boolean;
  isProcessing?: boolean;
  confirmLabel?: string;
}

const ConfirmationModal: React.FC<ConfirmationModalProps> = ({ 
    isOpen, 
    onClose, 
    onConfirm, 
    title, 
    message, 
    amount, 
    currencySymbol = '$',
    variant = 'primary',
    isIrreversible = false,
    isProcessing = false,
    confirmLabel = 'Confirm Action'
}) => {
  const isDanger = variant === 'danger';

  const footer = (
    <>
      <button
        type="button"
        className={`btn-base flex-1 py-5 text-[11px] font-black uppercase tracking-widest shadow-xl transition-all active:scale-95 ${isDanger ? 'bg-rose-600 text-white hover:bg-rose-700 shadow-rose-200' : 'bg-primary text-white hover:bg-blue-700 shadow-primary/20'}`}
        onClick={onConfirm}
        disabled={isProcessing}
      >
        {isProcessing && <div className="w-4 h-4 border-2 border-white/30 border-t-white rounded-full animate-spin mr-2"></div>}
        {confirmLabel}
      </button>
      <button
        type="button"
        className="btn-base px-10 py-5 text-[11px] font-black uppercase tracking-widest text-slate-400 bg-white dark:bg-gray-900 border border-slate-100 dark:border-gray-800 hover:bg-slate-50 transition-all"
        onClick={onClose}
        disabled={isProcessing}
      >
        Abort Protocol
      </button>
    </>
  );

  return (
    <ModalShell 
        isOpen={isOpen} 
        onClose={onClose} 
        title={title} 
        maxWidth="max-w-md"
        footer={footer}
    >
        <div className="flex flex-col items-center text-center font-sans">
            {/* Status Icon with Context-Tinted Glow */}
            <div className={`w-24 h-24 rounded-[2.5rem] flex items-center justify-center mb-8 relative ${
                isDanger ? 'bg-rose-50 text-rose-500 dark:bg-rose-950/30' : 'bg-primary/5 text-primary dark:bg-primary/20'
            }`}>
                <div className={`absolute inset-0 rounded-[2.5rem] animate-pulse-subtle blur-xl opacity-40 ${isDanger ? 'bg-rose-400' : 'bg-primary'}`}></div>
                {isDanger ? <WarningIcon className="w-12 h-12 relative z-10" /> : (
                    <svg className="w-12 h-12 relative z-10" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={3} d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
                    </svg>
                )}
            </div>
            
            {/* High-Impact Value Viewer */}
            {amount !== undefined && (
                <div className="mb-8 p-8 bg-slate-900 dark:bg-black rounded-[3rem] border border-white/5 w-full shadow-2xl relative overflow-hidden group">
                    <div className={`absolute top-0 right-0 w-32 h-32 rounded-full -mr-16 -mt-16 blur-3xl opacity-20 ${isDanger ? 'bg-rose-500' : 'bg-primary'}`}></div>
                    <p className="text-[10px] font-black text-slate-500 uppercase tracking-[0.4em] mb-3 relative z-10">Audit Valuation</p>
                    <p className={`text-5xl font-black tabular-nums tracking-tighter relative z-10 ${isDanger ? 'text-rose-500' : 'text-primary'}`}>
                        {typeof amount === 'number' ? `${currencySymbol}${amount.toFixed(2)}` : amount}
                    </p>
                </div>
            )}

            <p className="text-sm sm:text-base text-slate-500 dark:text-slate-400 font-bold leading-relaxed mb-8 uppercase tracking-tight">
                {message}
            </p>

            {isIrreversible && (
                <div className={`flex items-center justify-center gap-3 px-8 py-4 rounded-2xl text-[10px] font-black uppercase tracking-[0.2em] border shadow-sm ${
                    isDanger 
                    ? 'bg-rose-50 dark:bg-rose-950/20 text-rose-600 dark:text-rose-400 border-rose-100 dark:border-rose-900/50' 
                    : 'bg-amber-50 dark:bg-amber-900/20 text-amber-600 dark:text-amber-400 border-amber-100 dark:border-amber-900/50'
                }`}>
                    <WarningIcon className="w-5 h-5" />
                    Protocol Lock: Final Sequence
                </div>
            )}
        </div>
    </ModalShell>
  );
};

export default ConfirmationModal;
