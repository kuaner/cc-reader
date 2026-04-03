import preact from '@preact/preset-vite';
import tailwindcss from '@tailwindcss/vite';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig, mergeConfig } from 'vite';
import { sharedCcreaderBuild } from './vite.build.shared';

const __dirname = fileURLToPath(new URL('.', import.meta.url));

/** Timeline WKWebView shell (Preact + Tailwind + marked + highlight.js). */
export default mergeConfig(
  defineConfig({
    build: sharedCcreaderBuild,
  }),
  defineConfig({
    plugins: [tailwindcss(), preact()],
    build: {
      lib: {
        entry: resolve(__dirname, 'src/timeline/main.tsx'),
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
