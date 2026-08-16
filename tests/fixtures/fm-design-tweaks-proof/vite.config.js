import { defineConfig } from 'vite';

export default defineConfig({
  appType: 'spa',
  build: {
    manifest: true,
    minify: 'oxc',
    sourcemap: false,
    target: 'es2022',
  },
  server: {
    host: '127.0.0.1',
    strictPort: true,
  },
  preview: {
    host: '127.0.0.1',
    strictPort: true,
  },
});
