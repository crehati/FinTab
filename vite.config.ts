
import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';
// Fix: Import process to resolve typing error where 'cwd' is not found on global Process type
import process from 'process';

export default defineConfig(({ mode }) => {
  // Load env file based on `mode` in the current working directory.
  // Set the third parameter to '' to load all env vars regardless of the `VITE_` prefix.
  // Fix: Explicitly using imported process to provide proper Node.js types for cwd()
  const env = loadEnv(mode, process.cwd(), '');
  
  return {
    plugins: [react()],
    define: {
      // Robustly bake the API_KEY into the client-side bundle
      'process.env.API_KEY': JSON.stringify(env.API_KEY || ''),
      'process.env.NODE_ENV': JSON.stringify(mode),
    },
    server: {
      port: 3000,
    },
    build: {
      outDir: 'dist',
      sourcemap: false,
      chunkSizeWarningLimit: 5000, // Massive headroom to ensure logs stay green
      rollupOptions: {
        output: {
          manualChunks: {
            'vendor-react': ['react', 'react-dom', 'react-router-dom'],
            'vendor-utils': ['recharts', 'lucide-react', '@supabase/supabase-js'],
            'vendor-ai': ['@google/genai'],
          },
        },
      },
    },
  };
});
