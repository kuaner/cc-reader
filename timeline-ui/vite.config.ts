import preact from '@preact/preset-vite';
import { resolve } from 'node:path';
import { defineConfig } from 'vite';

/** Timeline WKWebView shell (Preact + Tailwind + marked + highlight.js). */
export default defineConfig({
  plugins: [preact()],
  build: {
    // Never wipe ../CCReader/Resources — it also holds Assets.xcassets and *.lproj.
    emptyOutDir: false,
    outDir: resolve(__dirname, '../CCReader/Resources'),
    cssCodeSplit: false,
    lib: {
      entry: resolve(__dirname, 'src/main.tsx'),
      name: 'ccreaderTimeline',
      formats: ['iife'],
      fileName: () => 'timeline-shell.js',
    },
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
        assetFileNames: 'timeline-shell[extname]',
      },
    },
  },
});
