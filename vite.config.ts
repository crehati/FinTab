import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';
// Fix: Import process from node:process to ensure Node.js environment types are available for process.cwd()
import process from 'node:process';

export default defineConfig(({ mode }) => {
  // Load env vars from the current working directory
  // Third parameter '' allows loading all variables regardless of prefix
  const env = loadEnv(mode, process.cwd(), '');
  
  return {
    plugins: [react()],
    define: {
      // Robust injection of the API_KEY into the production client bundle
      'process.env.API_KEY': JSON.stringify(env.API_KEY || env.VITE_API_KEY || ''),
      'process.env.NODE_ENV': JSON.stringify(mode),
    },
    build: {
      outDir: 'dist',
      sourcemap: false,
      chunkSizeWarningLimit: 20000,
      rollupOptions: {
        output: {
          format: 'es',
        },
      },
    },
    server: {
      port: 3000,
    }
  };
});
