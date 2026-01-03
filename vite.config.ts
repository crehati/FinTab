
import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig(({ mode }) => {
  // Load environment variables from process.env and .env files
  const env = loadEnv(mode, (process as any).cwd(), '');
  
  return {
    plugins: [react()],
    define: {
      // Prioritize API_KEY, fallback to empty string if not found
      'process.env.API_KEY': JSON.stringify(env.API_KEY || env.VITE_API_KEY || ''),
      'process.env.NODE_ENV': JSON.stringify(mode),
    },
    server: {
      port: 3000,
    },
    build: {
      outDir: 'dist',
      sourcemap: false,
      // Suppress chunk size warnings in the build logs
      chunkSizeWarningLimit: 10000,
      rollupOptions: {
        output: {
          // Allow Vite to manage the format automatically
        },
      },
    },
  };
});
