import typography from '@tailwindcss/typography';

/** @type {import('tailwindcss').Config} */
export default {
  content: ['./src/**/*.{ts,tsx}'],
  darkMode: 'media',
  theme: {
    extend: {
      maxWidth: {
        timeline: 'min(100%, clamp(560px, 82vw, 1080px))',
      },
    },
  },
  plugins: [typography],
};
