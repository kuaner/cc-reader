import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig, mergeConfig } from 'vite';
import { sharedCcreaderBuild } from './vite.build.shared';

const __dirname = fileURLToPath(new URL('.', import.meta.url));

/** MarkdownRenderView: `marked` + hljs + `markdown-preview.css` (no Svelte). */
export default mergeConfig(
  defineConfig({
    build: sharedCcreaderBuild,
  }),
  defineConfig({
    plugins: [],
    build: {
      lib: {
        entry: resolve(__dirname, 'src/markdown/previewEntry.ts'),
        name: 'ccreaderMarkdownPreview',
        formats: ['iife'],
        fileName: () => 'markdown-preview.js',
      },
      rollupOptions: {
        output: {
          assetFileNames: 'markdown-preview[extname]',
        },
      },
    },
  }),
);
