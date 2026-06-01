# Argus docs

The [Argus](../README.md) documentation site — a [Fumadocs](https://fumadocs.dev)
(Next.js) app exported as a static site and published to GitHub Pages by
[`.github/workflows/deploy-docs.yml`](../.github/workflows/deploy-docs.yml).

## Develop

```sh
npm install
npm run dev      # http://localhost:3000
```

Content lives in [`content/docs/`](content/docs) as MDX, ordered by
[`content/docs/meta.json`](content/docs/meta.json).

## Build (static export)

```sh
npm run build    # emits ./out
```

For a GitHub Pages **project site** the build needs a base path; CI sets it from
the Pages config automatically. To mirror that locally:

```sh
NEXT_PUBLIC_BASE_PATH=/argus npm run build
```

| path | role |
|---|---|
| `content/docs/`           | the MDX documentation pages + `meta.json` ordering |
| `lib/shared.ts`           | app name, GitHub repo, and the base-path helper |
| `lib/source.ts`           | Fumadocs content source adapter |
| `components/search.tsx`   | static (Orama) search, base-path aware |
| `next.config.mjs`         | static export + base path + trailing slash |
