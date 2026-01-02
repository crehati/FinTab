
import React, { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';

export type ToastType = 'success' | 'error' | 'info';

interface ToastProps {
    message: string;
    type: ToastType;
    duration?: number;
    onClose: () => void;
}

const Toast: React.FC<ToastProps> = ({ message, type, duration = 3000, onClose }) => {
    const [isVisible, setIsVisible] = useState(true);

    useEffect(() => {
        const timer = setTimeout(() => {
            setIsVisible(false);
            setTimeout(onClose, 300); // Allow animation to finish
        }, duration);
        return () => clearTimeout(timer);
    }, [duration, onClose]);

    const getStyles = () => {
        switch (type) {
            case 'success':
                return {
                    bg: 'bg-slate-900 dark:bg-primary',
                    icon: (
                        <svg className="w-5 h-5 text-emerald-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
                            <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                        </svg>
                    ),
                    label: 'PROTOCOL VERIFIED'
                };
            case 'error':
                return {
                    bg: 'bg-rose-600',
                    icon: (
                        <svg className="w-5 h-5 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
                            <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
                        </svg>
                    ),
                    label: 'SYSTEM HALT'
                };
            default:
                return {
                    bg: 'bg-slate-800 backdrop-blur-md',
                    icon: (
                        <svg className="w-5 h-5 text-blue-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
                            <path strokeLinecap="round" strokeLinejoin="round" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                        </svg>
                    ),
                    label: 'TERMINAL INFO'
                };
        }
    };

    const styles = getStyles();

    return createPortal(
        <div className={`fixed bottom-24 left-1/2 -translate-x-1/2 z-[1000] px-6 py-4 rounded-3xl shadow-2xl transition-all duration-300 transform flex items-center gap-4 ${isVisible ? 'animate-fade-in-up' : 'opacity-0 translate-y-4'} ${styles.bg}`}>
            <div className="flex-shrink-0">
                {styles.icon}
            </div>
            <div className="min-w-0">
                <p className="text-[8px] font-black text-white/50 uppercase tracking-[0.3em] mb-0.5">{styles.label}</p>
                <p className="text-xs font-bold text-white uppercase tracking-tight truncate max-w-[280px]">{message}</p>
            </div>
        </div>,
        document.body
    );
};

export default Toast;

/**
 * Global helper to trigger a notification from anywhere
 */
export const notify = (message: string, type: ToastType = 'success') => {
    window.dispatchEvent(new CustomEvent('fintab-notify', { detail: { message, type } }));
};
