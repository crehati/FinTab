import React from 'react';
import { useNavigate } from 'react-router-dom';

const ArrowLeftIcon = () => (
    <svg xmlns="http://www.w3.org/2000/svg" className="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10 19l-7-7m0 0l7-7m-7 7h18" />
    </svg>
);

const GoBackButton: React.FC = () => {
    const navigate = useNavigate();

    const handleGoBack = () => {
        // This check determines if there's a page to go back to in the session history.
        // If not (e.g., page was opened in a new tab or refreshed), it defaults to the homepage.
        if (window.history.state && window.history.state.idx > 0) {
            navigate(-1);
        } else {
            navigate('/', { replace: true });
        }
    };

    return (
        <button
            onClick={handleGoBack}
            className="p-2 rounded-full text-neutral-medium hover:bg-neutral-light dark:text-gray-400 dark:hover:bg-gray-700 hover:text-primary dark:hover:text-primary transition-colors duration-200"
            aria-label="Go back to previous page"
            title="Go Back"
        >
            <ArrowLeftIcon />
        </button>
    );
};

export default GoBackButton;
