import { createMDX } from 'fumadocs-mdx/next';

const withMDX = createMDX();

// `/argus` for a GitHub Pages project site, empty for local dev / root hosting.
// Set via the deploy workflow; `NEXT_PUBLIC_` so it's also readable client-side
// (the static search client needs it to fetch the prerendered index).
// Strip trailing slash so a `/` (root / custom-domain) value normalizes to ''.
const basePath = (process.env.NEXT_PUBLIC_BASE_PATH || '').replace(/\/+$/, '');

/** @type {import('next').NextConfig} */
const config = {
  output: 'export',
  // Pin the workspace root to this folder (a stray lockfile in $HOME otherwise
  // confuses Next's root inference).
  turbopack: { root: import.meta.dirname },
  basePath,
  // Folder-per-route (out/docs/index.html) so GitHub Pages serves clean URLs
  // without 404-on-refresh.
  trailingSlash: true,
  // next/image can't run on a static host.
  images: { unoptimized: true },
  reactStrictMode: true,
};

export default withMDX(config);
