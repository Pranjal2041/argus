export const appName = 'Argus';
export const docsRoute = '/docs';
export const docsImageRoute = '/og/docs';
export const docsContentRoute = '/llms.mdx/docs';

// Base path the site is served under (e.g. `/argus` for a GitHub Pages project
// site). Empty for local dev / root hosting. Threaded into next.config and the
// static search client so raw fetches resolve under the same prefix.
export const basePath = (process.env.NEXT_PUBLIC_BASE_PATH ?? '').replace(/\/+$/, '');

export const gitConfig = {
  user: 'Pranjal2041',
  repo: 'argus',
  branch: 'main',
};
