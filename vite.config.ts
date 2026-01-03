
import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig(({ mode }) => {
  // Use the global process object available in Node.js environment
  // Fix: Cast process to any to access cwd() when Node types are not fully recognized in the current execution context
  const env = loadEnv(mode, (process as any).cwd(), '');
  
  return {
    plugins: [react()],
    define: {
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
      chunkSizeWarningLimit: 10000,
      rollupOptions: {
        output: {
          format: 'es',
        },
      },
    },
  };
});
