
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
