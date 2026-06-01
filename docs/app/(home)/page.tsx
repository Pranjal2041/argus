import Link from 'next/link';

export default function HomePage() {
  return (
    <main className="flex flex-1 flex-col items-center justify-center px-4 py-20 text-center">
      <p className="mb-3 text-sm font-medium tracking-wide text-fd-muted-foreground">
        macOS · Android · Windows — over Tailscale, peer-to-peer
      </p>
      <h1 className="mb-4 text-4xl font-bold sm:text-5xl">Argus</h1>
      <p className="mb-8 max-w-2xl text-balance text-lg text-fd-muted-foreground">
        One watchful eye over every coding agent, on every machine. Reach every{' '}
        <code className="rounded bg-fd-muted px-1.5 py-0.5 text-base">claude</code> session across
        your Mac, clusters, Windows boxes, and phone — terminals, files, and ports — with no central
        server.
      </p>
      <div className="flex flex-wrap items-center justify-center gap-3">
        <Link
          href="/docs"
          className="rounded-lg bg-fd-primary px-5 py-2.5 font-medium text-fd-primary-foreground transition-opacity hover:opacity-90"
        >
          Read the docs
        </Link>
        <a
          href="https://github.com/Pranjal2041/argus"
          className="rounded-lg border border-fd-border px-5 py-2.5 font-medium transition-colors hover:bg-fd-muted"
        >
          GitHub
        </a>
      </div>
    </main>
  );
}
