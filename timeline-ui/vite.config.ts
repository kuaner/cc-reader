import { svelte } from '@sveltejs/vite-plugin-svelte';
import tailwindcss from '@tailwindcss/vite';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig, mergeConfig } from 'vite';
import type { UserConfig } from 'vite';
const __dirname = fileURLToPath(new URL('.', import.meta.url));

/** Built artifacts land next to app resources (never wipe whole folder — see emptyOutDir). */
const resourcesOutDir = resolve(__dirname, '../CCReader/Resources');

/** Shared between timeline-shell and markdown-preview Vite configs. */
const sharedCcreaderBuild: UserConfig['build'] = {
  emptyOutDir: false,
  outDir: resourcesOutDir,
  cssCodeSplit: false,
};

export default defineConfig(({ mode }) => {


  if (!['timeline-shell', 'markdown-preview'].includes(mode)) {
    throw new Error(`Unsupported vite mode: ${mode}`);
  }

  return mergeConfig(
    defineConfig({
      build: sharedCcreaderBuild,
    }),
    defineConfig({
      plugins:[tailwindcss(), svelte()],
      build: {
        lib: {
          entry: resolve(__dirname, `src/${mode}/main.ts`),
          name: `${mode.replace(/-/g, '')}Lib`,
          formats: ['iife'],
          fileName: () => `${mode}.js`,
        },
        rollupOptions: {
          output: {
            assetFileNames: `${mode}[extname]`,
          },
        },
      },
    }),
  );
});
