import React, { useState } from 'react';
import type { User, BusinessProfile } from '../types';

interface LoginProps {
    onLogin: (email: string, password: string) => boolean;
}

const Login: React.FC<LoginProps> = ({ onLogin }) => {
    const [email, setEmail] = useState('');
    const [password, setPassword] = useState('');
    const [error, setError] = useState('');

    const handleSubmit = (e: React.FormEvent) => {
        e.preventDefault();
        setError('');
        const success = onLogin(email, password);
        if (!success) {
            setError('Invalid email or password. Please try again.');
        }
    };

    return (
        <div className="flex items-center justify-center min-h-screen bg-neutral-light dark:bg-gray-900 p-4">
            <div className="w-full max-w-md p-8 space-y-6 bg-white dark:bg-gray-800 rounded-2xl shadow-xl">
                <div className="text-center">
                    <h1 className="text-4xl font-bold tracking-wider text-primary">FinTab</h1>
                    <p className="mt-2 text-neutral-medium dark:text-gray-400">Smart, Simple, and Professional POS for Your Business</p>
                </div>
                <form className="mt-8 space-y-6" onSubmit={handleSubmit}>
                    <div className="space-y-4">
                        <div>
                            <label htmlFor="email-address" className="block text-sm font-medium text-gray-700 dark:text-gray-300">Email address</label>
                            <input
                                id="email-address"
                                name="email"
                                type="email"
                                autoComplete="email"
                                required
                                value={email}
                                onChange={(e) => setEmail(e.target.value)}
                                className="mt-1"
                                placeholder="you@example.com"
                            />
                        </div>
                        <div>
                            <label htmlFor="password"  className="block text-sm font-medium text-gray-700 dark:text-gray-300">Password</label>
                            <input
                                id="password"
                                name="password"
                                type="password"
                                autoComplete="current-password"
                                required
                                value={password}
                                onChange={(e) => setPassword(e.target.value)}
                                className="mt-1"
                                placeholder="••••••••"
                            />
                        </div>
                    </div>

                    {error && (
                        <div className="p-3 bg-red-50 dark:bg-red-900/30 border border-red-200 dark:border-red-700 rounded-md text-center">
                            <p className="text-sm text-red-600 dark:text-red-300">{error}</p>
                        </div>
                    )}

                    <div>
                        <button
                            type="submit"
                            className="btn-responsive bg-primary text-white hover:bg-blue-700 transition-colors shadow-sm"
                        >
                            Sign In
                        </button>
                    </div>
                     <div className="text-center text-sm text-gray-500 dark:text-gray-400 space-y-2">
                        <p>Hint: For the demo account, log in with: <br />
                            <span className="font-mono">owner@fintab.com</span> / <span className="font-mono">password</span>
                        </p>
                    </div>
                </form>
            </div>
        </div>
    );
};

export default Login;