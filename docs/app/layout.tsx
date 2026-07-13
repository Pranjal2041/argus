import { Inter } from 'next/font/google';
import type { Metadata } from 'next';
import { Provider } from '@/components/provider';
import './global.css';

const siteOrigin = process.env.NEXT_PUBLIC_SITE_ORIGIN || 'https://pranjal2041.github.io';

export const metadata: Metadata = {
  metadataBase: new URL(siteOrigin),
  title: {
    default: 'Argus — one watchful eye over every coding agent',
    template: '%s · Argus',
  },
  description: 'Supervise coding agents across every machine, review their work, and keep a trustworthy record — peer-to-peer over your tailnet.',
};

const inter = Inter({
  subsets: ['latin'],
});

export default function Layout({ children }: LayoutProps<'/'>) {
  return (
    <html lang="en" className={inter.className} suppressHydrationWarning>
      <body className="flex flex-col min-h-screen">
        <Provider>{children}</Provider>
      </body>
    </html>
  );
}
