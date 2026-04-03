import { resolve } from 'node:path';
import { defineConfig } from 'vite';

/** MarkdownRenderView: globals `marked` + `hljs` + hljs themes (no Preact). */
export default defineConfig({
  plugins: [],
  build: {
    emptyOutDir: false,
    outDir: resolve(__dirname, '../CCReader/Resources'),
    cssCodeSplit: false,
    lib: {
      entry: resolve(__dirname, 'src/markdownPreview.ts'),
      name: 'ccreaderMarkdownPreview',
      formats: ['iife'],
      fileName: () => 'markdown-preview.js',
    },
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
        assetFileNames: 'markdown-preview[extname]',
      },
    },
  },
});
