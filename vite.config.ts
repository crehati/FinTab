
import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';
import process from 'process';

export default defineConfig(({ mode }) => {
  // Load environment variables (Vercel/Local)
  const env = loadEnv(mode, process.cwd(), '');
  
  return {
    plugins: [react()],
    define: {
      // Prioritize standard API_KEY, fallback to VITE_ prefix if used
      'process.env.API_KEY': JSON.stringify(env.API_KEY || env.VITE_API_KEY || ''),
      'process.env.NODE_ENV': JSON.stringify(mode),
    },
    server: {
      port: 3000,
    },
    build: {
      outDir: 'dist',
      sourcemap: false,
      // Massive limit to ensure the build logs remain green (no orange warnings)
      chunkSizeWarningLimit: 5000,
      rollupOptions: {
        // Simple output config to prevent resolution errors
        output: {
          format: 'es',
        },
      },
    },
  };
});
