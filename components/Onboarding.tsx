import React, { useState, useRef, useEffect } from 'react';
import type { BusinessProfile, Role, User } from '../types';
import PasswordStrengthIndicator from './PasswordStrengthIndicator';
import { COUNTRIES } from '../constants';

const STEPS = [
  { id: 1, name: 'Welcome' },
  { id: 2, name: 'Account Setup' },
  { id: 3, name: 'Verify Email' },
  { id: 4, name: 'Finish' },
];

const ProgressIndicator: React.FC<{ currentStep: number }> = ({ currentStep }) => (
  <div className="flex justify-between items-center mb-8">
    {STEPS.map((step, index) => (
      <React.Fragment key={step.id}>
        <div className="flex flex-col items-center text-center w-20">
          <div
            className={`w-8 h-8 rounded-full flex items-center justify-center transition-colors duration-300 ${
              currentStep >= step.id ? 'bg-primary text-white' : 'bg-gray-200 text-gray-500'
            }`}
          >
            {currentStep > step.id ? '✓' : step.id}
          </div>
          <p className={`text-xs mt-2 ${currentStep >= step.id ? 'text-primary font-semibold' : 'text-gray-500'}`}>
            {step.name}
          </p>
        </div>
        {index < STEPS.length - 1 && (
          <div
            className={`flex-1 h-1 mx-2 transition-colors duration-300 ${
              currentStep > step.id ? 'bg-primary' : 'bg-gray-200'
            }`}
          />
        )}
      </React.Fragment>
    ))}
  </div>
);


interface OnboardingProps {
    onFinish: (data: any) => void;
    onSwitchToLogin: () => void;
    onSkipSetup: () => void;
}
const Onboarding: React.FC<OnboardingProps> = ({ onFinish, onSwitchToLogin, onSkipSetup }) => {
    const [step, setStep] = useState(1);
    const [owner, setOwner] = useState({
        fullName: '',
        countryCode: '+1',
        localPhone: '',
        email: '',
        password: '',
    });
    const [business, setBusiness] = useState<BusinessProfile>({
        businessName: '',
        dateEstablished: '',
        employeeCount: '',
        businessType: 'Retail',
        website: '',
        businessEmail: '',
        businessPhone: '', // This will be composed later
        logo: null
    });
    const [businessPhone, setBusinessPhone] = useState({ countryCode: '+1', localPhone: ''});

    const fileInputRef = useRef<HTMLInputElement>(null);

    const nextStep = () => setStep(s => s + 1);
    const prevStep = () => setStep(s => s - 1);

    const handleOwnerChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
        setOwner({ ...owner, [e.target.name]: e.target.value });
    };

    const handleBusinessChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
        setBusiness({ ...business, [e.target.name]: e.target.value });
    };

    const handleBusinessPhoneChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
        setBusinessPhone({ ...businessPhone, [e.target.name]: e.target.value });
    };

    const handleLogoUpload = (e: React.ChangeEvent<HTMLInputElement>) => {
        const file = e.target.files?.[0];
        if (file) {
            const reader = new FileReader();
            reader.onloadend = () => {
                setBusiness({ ...business, logo: reader.result as string });
            };
            reader.readAsDataURL(file);
        }
    };
    
    const handleFinish = () => {
        const finalBusinessData = {
            ...business,
            businessPhone: `${businessPhone.countryCode}${businessPhone.localPhone.replace(/\D/g, '')}`
        };
        const finalOwnerData = {
            ...owner,
            phone: `${owner.countryCode}${owner.localPhone.replace(/\D/g, '')}`
        };
        onFinish({ owner: finalOwnerData, business: finalBusinessData });
    };

    const renderStep = () => {
        switch (step) {
            case 1:
                return <WelcomeScreen onNext={nextStep} onSwitchToLogin={onSwitchToLogin} onSkipSetup={onSkipSetup} />;
            case 2:
                return (
                    <BusinessRegistration
                        owner={owner}
                        business={business}
                        businessPhone={businessPhone}
                        onOwnerChange={handleOwnerChange}
                        onBusinessChange={handleBusinessChange}
                        onBusinessPhoneChange={handleBusinessPhoneChange}
                        onLogoUpload={handleLogoUpload}
                        fileInputRef={fileInputRef}
                        onNext={nextStep}
                    />
                );
            case 3:
                return <VerifyEmailScreen onNext={nextStep} onPrev={prevStep} ownerEmail={owner.email} />;
            case 4:
                 return <FinalStep onFinish={handleFinish} ownerName={owner.fullName} />;
            default:
                return <div>Unknown step</div>;
        }
    };

    return (
        <div className="min-h-screen bg-gray-50 dark:bg-gray-900 flex items-center justify-center p-4">
            <div className="w-full max-w-5xl bg-white dark:bg-gray-800 rounded-2xl shadow-lg p-8 md:p-12">
                {step > 1 && step < STEPS.length && <ProgressIndicator currentStep={step} />}
                {renderStep()}
            </div>
        </div>
    );
};

// --- Step Components ---

const FinTabLogo = ({ className }: { className?: string }) => (
    <svg viewBox="0 0 200 50" className={className} xmlns="http://www.w3.org/2000/svg">
        <text x="0" y="40" fontFamily="Arial, sans-serif" fontSize="45" fontWeight="bold" fill="currentColor" className="text-primary dark:text-accent-sky">
            Fin
            <tspan fill="currentColor" className="text-neutral-dark dark:text-gray-200">Tab</tspan>
        </text>
    </svg>
);

const Illustration = () => (
    <div className="hidden lg:flex flex-col justify-center items-center text-center bg-blue-50 dark:bg-gray-800/50 rounded-2xl p-8">
        <div className="relative w-48 h-48">
            <div className="absolute inset-0 bg-primary/10 dark:bg-blue-900/20 rounded-full animate-pulse"></div>
            <div className="absolute inset-4 bg-primary/20 dark:bg-blue-900/30 rounded-full animate-pulse [animation-delay:0.2s]"></div>
            <svg viewBox="0 0 100 100" className="relative z-10 text-primary dark:text-accent-sky">
                <path d="M20,85 h60 v-10 h-60 z" fill="currentColor" fillOpacity="0.1" />
                <path d="M25,75 h50 v-40 h-50 z M 40,75 v-15 h20 v15" stroke="currentColor" strokeWidth="3" fill="none" strokeLinejoin="round" strokeLinecap="round"/>
                <path d="M30,35 h40 l-5,-15 h-30 z" fill="currentColor"/>
                <path d="M70,50 l5,-5 l-15,-15 l-10,10 l-15,-15 l-10,10" stroke="#22C55E" strokeWidth="3" fill="none" strokeLinecap="round" strokeLinejoin="round" />
                <path d="M25,50 l5,-5" stroke="#22C55E" strokeWidth="3" fill="none" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
        </div>
        <h2 className="mt-8 text-2xl font-bold text-neutral-dark dark:text-gray-100">Unlock Your Business Potential</h2>
        <p className="mt-2 text-neutral-medium dark:text-gray-400">Manage sales, inventory, customers, and staff with a single, powerful tool.</p>
    </div>
);

const WelcomeScreen: React.FC<{ onNext: () => void; onSwitchToLogin: () => void; onSkipSetup: () => void; }> = ({ onNext, onSwitchToLogin, onSkipSetup }) => {
    return (
        <div className="grid lg:grid-cols-2 gap-12 items-center">
            <Illustration />
            <div className="flex flex-col items-center lg:items-start text-center lg:text-left">
                <FinTabLogo className="h-12 w-auto mb-4" />
                <h1 className="text-3xl lg:text-4xl font-bold text-neutral-dark dark:text-gray-100">
                    Smart, Simple, and Professional POS for Your Business.
                </h1>
                <p className="mt-2 text-lg text-gray-600 dark:text-gray-400">
                    Get started for free today.
                </p>
                <div className="mt-10 space-y-4 w-full max-w-sm">
                    <button
                        onClick={onNext}
                        className="w-full text-lg bg-primary text-white py-3 px-6 rounded-lg font-semibold hover:bg-blue-700 transition-colors shadow-md transform active:scale-95"
                    >
                        Create Your Free Account
                    </button>
                     <div className="relative flex items-center py-2">
                        <div className="flex-grow border-t border-gray-300 dark:border-gray-600"></div>
                        <span className="flex-shrink mx-4 text-gray-500 dark:text-gray-400 text-sm">OR</span>
                        <div className="flex-grow border-t border-gray-300 dark:border-gray-600"></div>
                    </div>
                     <button
                        onClick={onSkipSetup}
                        className="w-full text-lg bg-white dark:bg-gray-700 text-primary dark:text-accent-sky border-2 border-primary dark:border-accent-sky py-2.5 px-6 rounded-lg font-semibold hover:bg-primary/5 dark:hover:bg-gray-600 transition-colors transform active:scale-95"
                    >
                        Explore a Demo Account
                    </button>
                </div>
                <div className="mt-6 text-center text-sm">
                    <p className="text-gray-600 dark:text-gray-400">
                        Already have an account?{' '}
                        <button onClick={onSwitchToLogin} className="font-semibold text-primary hover:underline focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-primary rounded">
                            Sign In
                        </button>
                    </p>
                </div>
            </div>
        </div>
    );
};

const BusinessRegistration: React.FC<any> = ({ owner, business, businessPhone, onOwnerChange, onBusinessChange, onBusinessPhoneChange, onLogoUpload, fileInputRef, onNext }) => {
    const handleSubmit = (e: React.FormEvent) => {
        e.preventDefault();
        onNext();
    };
    
    return (
        <form onSubmit={handleSubmit} className="space-y-8">
            <Section title="Personal Information">
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <Input name="fullName" label="Full Name" value={owner.fullName} onChange={onOwnerChange} required />
                    <PhoneInput
                        label="Phone Number"
                        countryCode={owner.countryCode}
                        localPhone={owner.localPhone}
                        onCountryCodeChange={onOwnerChange}
                        onLocalPhoneChange={onOwnerChange}
                    />
                    <Input name="email" label="Email Address" value={owner.email} onChange={onOwnerChange} required type="email" />
                </div>
            </Section>
            
            <Section title="Business Information">
                 <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <Input name="businessName" label="Business Name" value={business.businessName} onChange={onBusinessChange} required />
                    <Input name="dateEstablished" label="Date Established" value={business.dateEstablished} onChange={onBusinessChange} required type="date" />
                     <Input name="employeeCount" label="Number of Employees" value={business.employeeCount} onChange={onBusinessChange} required />
                     <Select name="businessType" label="Type of Business" value={business.businessType} onChange={onBusinessChange} options={['Retail', 'Restaurant', 'Service', 'Other']} />
                     <Input name="website" label="Business Website (Optional)" value={business.website} onChange={onBusinessChange} />
                     <Input name="businessEmail" label="Business Email" value={business.businessEmail} onChange={onBusinessChange} required type="email" />
                    <PhoneInput
                        label="Business Phone"
                        countryCode={businessPhone.countryCode}
                        localPhone={businessPhone.localPhone}
                        onCountryCodeChange={onBusinessPhoneChange}
                        onLocalPhoneChange={onBusinessPhoneChange}
                    />
                </div>
                 <div>
                    <label className="block text-sm font-medium text-gray-700">Business Logo</label>
                    <div className="mt-1 flex items-center">
                        <span className="inline-block h-12 w-12 rounded-full overflow-hidden bg-gray-100">
                             {business.logo ? <img src={business.logo} alt="Logo" className="h-full w-full object-cover" /> : <svg className="h-full w-full text-gray-300" fill="currentColor" viewBox="0 0 24 24"><path d="M24 20.993V24H0v-2.993A1 1 0 001 18h22a1 1 0 001 2.993zM2.5 13.5l3-3 3 3-3 3-3-3zM18 10.5l-3 3 3 3 3-3-3-3zM21.5 6l-3 3 3 3 3-3-3-3zM8.5 6l-3 3 3 3 3-3-3-3z"/></svg>}
                        </span>
                        <input type="file" accept="image/*" ref={fileInputRef} onChange={onLogoUpload} className="hidden" />
                        <button type="button" onClick={() => fileInputRef.current?.click()} className="ml-5 bg-white py-2 px-3 border border-gray-300 rounded-md shadow-sm text-sm leading-4 font-medium text-gray-700 hover:bg-gray-50">
                            Upload Logo
                        </button>
                    </div>
                </div>
            </Section>

             <Section title="Security">
                <Input name="password" label="Create Password" value={owner.password} onChange={onOwnerChange} required type="password" />
                <PasswordStrengthIndicator password={owner.password} />
            </Section>
            
            <div className="flex justify-end pt-4">
                <button type="submit" className="btn-responsive bg-primary text-white hover:bg-blue-700">
                    Next
                </button>
            </div>
        </form>
    );
};

const VerifyEmailScreen: React.FC<{ onNext: () => void; onPrev: () => void; ownerEmail: string }> = ({ onNext, onPrev, ownerEmail }) => (
    <div className="text-center p-8">
        <svg xmlns="http://www.w3.org/2000/svg" className="mx-auto h-16 w-16 text-primary" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z" />
        </svg>
        <h2 className="mt-4 text-2xl font-semibold text-gray-800">Check Your Email</h2>
        <p className="mt-2 text-gray-600">
            We've sent a verification link to <strong className="text-gray-900">{ownerEmail}</strong>.
        </p>
        <p className="mt-1 text-sm text-gray-500">
            Please check your inbox (and spam folder!) and click the link to confirm your account.
        </p>
        <div className="mt-8 max-w-xs mx-auto">
            <button
                onClick={onNext}
                className="btn-responsive bg-primary text-white hover:bg-blue-700 transition-colors"
            >
                I've Verified My Email (Click to simulate)
            </button>
        </div>
        <button onClick={onPrev} className="mt-4 text-sm text-gray-500 hover:underline">Go Back</button>
    </div>
);

const FinalStep: React.FC<{ onFinish: () => void; ownerName: string }> = ({ onFinish, ownerName }) => {
    useEffect(() => {
        const timer = setTimeout(() => {
            onFinish();
        }, 2500); // 2.5 seconds to show the message
        return () => clearTimeout(timer);
    }, [onFinish]);

    return (
        <div className="text-center p-12">
            <svg xmlns="http://www.w3.org/2000/svg" className="mx-auto h-16 w-16 text-success" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
            <h2 className="mt-4 text-2xl font-semibold text-gray-800">Welcome Aboard, {ownerName.split(' ')[0]}!</h2>
            <p className="mt-2 text-gray-600">Your account is ready.</p>
            <div className="animate-spin rounded-full h-8 w-8 border-t-2 border-b-2 border-primary mx-auto mt-6"></div>
            <p className="mt-4 text-sm text-gray-500 animate-pulse">Finalizing your account setup...</p>
        </div>
    );
};


// --- Helper Components ---

const Section: React.FC<{ title: string; children: React.ReactNode }> = ({ title, children }) => (
    <div className="border-t pt-6">
        <h3 className="text-xl font-semibold text-gray-800 mb-4">{title}</h3>
        <div className="space-y-4">{children}</div>
    </div>
);

const Input: React.FC<any> = ({ name, label, ...props }) => (
  <div>
    <label htmlFor={name} className="block text-sm font-medium text-gray-700">{label}</label>
    <input
      id={name}
      name={name}
      className="mt-1"
      {...props}
    />
  </div>
);

const Select: React.FC<any> = ({ name, label, options, ...props }) => (
    <div>
        <label htmlFor={name} className="block text-sm font-medium text-gray-700">{label}</label>
        <select
            id={name}
            name={name}
            className="mt-1"
            {...props}
        >
            {options.map((opt: string) => <option key={opt} value={opt}>{opt}</option>)}
        </select>
    </div>
);

const PhoneInput: React.FC<{ label: string; countryCode: string; localPhone: string; onCountryCodeChange: (e: React.ChangeEvent<HTMLSelectElement>) => void; onLocalPhoneChange: (e: React.ChangeEvent<HTMLInputElement>) => void; }> = ({ label, countryCode, localPhone, onCountryCodeChange, onLocalPhoneChange }) => (
    <div>
        <label htmlFor="localPhone" className="block text-sm font-medium text-gray-700">{label}</label>
        <div className="mt-1 flex rounded-md shadow-sm input-group">
            <select
                name="countryCode"
                value={countryCode}
                onChange={onCountryCodeChange}
                className="w-40"
                aria-label="Country code"
            >
                {COUNTRIES.map(country => (
                    <option key={country.code} value={country.dial_code}>
                        {country.flag} {country.name} ({country.dial_code})
                    </option>
                ))}
            </select>
            <input
                type="tel"
                name="localPhone"
                id="localPhone"
                value={localPhone}
                onChange={onLocalPhoneChange}
                required
                className="flex-1 min-w-0"
                placeholder="5551234567"
            />
        </div>
    </div>
);


export default Onboarding;