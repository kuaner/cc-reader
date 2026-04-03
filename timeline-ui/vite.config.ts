import { svelte } from '@sveltejs/vite-plugin-svelte';
import tailwindcss from '@tailwindcss/vite';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig, mergeConfig } from 'vite';
import { sharedCcreaderBuild } from './vite.build.shared';

const __dirname = fileURLToPath(new URL('.', import.meta.url));

/** Timeline WKWebView shell (Svelte 5 + Tailwind + marked + highlight.js). */
export default mergeConfig(
  defineConfig({
    build: sharedCcreaderBuild,
  }),
  defineConfig({
    plugins: [tailwindcss(), svelte()],
    build: {
      lib: {
        entry: resolve(__dirname, 'src/timeline/main.ts'),
        name: 'ccreaderTimeline',
        formats: ['iife'],
        fileName: () => 'timeline-shell.js',
      },
      rollupOptions: {
        output: {
          assetFileNames: 'timeline-shell[extname]',
        },
      },
    },
  }),
);
