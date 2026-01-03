
import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';
import process from 'node:process';

export default defineConfig(({ mode }) => {
  // Load env vars from the current working directory. 
  // Empty prefix '' allows loading variables without the VITE_ requirement.
  const env = loadEnv(mode, process.cwd(), '');
  
  return {
    plugins: [react()],
    define: {
      // Prioritize system environment variables (Vercel) over local .env files
      'process.env.API_KEY': JSON.stringify(process.env.API_KEY || env.API_KEY || env.VITE_API_KEY || ''),
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
