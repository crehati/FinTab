
import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig(({ mode }) => {
  // Load env vars from the current working directory
  // Fix: Property 'cwd' does not exist on type 'Process'. Casting to any to allow access to Node.js process.cwd().
  const env = loadEnv(mode, (process as any).cwd(), '');
  
  return {
    plugins: [react()],
    define: {
      // Bake the API key into the client-side bundle
      'process.env.API_KEY': JSON.stringify(env.API_KEY || env.VITE_API_KEY || ''),
      'process.env.NODE_ENV': JSON.stringify(mode),
    },
    build: {
      outDir: 'dist',
      sourcemap: false,
      // Massive limit to ensure no orange chunk size warnings ever appear
      chunkSizeWarningLimit: 20000,
      rollupOptions: {
        output: {
          // Standard ES module output
          format: 'es',
        },
      },
    },
  };
});
