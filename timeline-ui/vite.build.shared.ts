import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { UserConfig } from 'vite';

const __dirname = fileURLToPath(new URL('.', import.meta.url));

/** Built artifacts land next to app resources (never wipe whole folder — see emptyOutDir). */
export const resourcesOutDir = resolve(__dirname, '../CCReader/Resources');

/** Shared between timeline-shell and markdown-preview Vite configs. */
export const sharedCcreaderBuild: UserConfig['build'] = {
  emptyOutDir: false,
  outDir: resourcesOutDir,
  cssCodeSplit: false,
  rollupOptions: {
    output: {
      inlineDynamicImports: true,
    },
  },
};
