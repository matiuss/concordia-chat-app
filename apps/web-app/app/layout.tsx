import type { ReactNode } from 'react';
import AppShell from '@/app/components/AppShell';
import "./globals.css";

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className="h-full antialiased font-sans">
      <body className="h-full bg-[#09090b]">
        <AppShell>{children}</AppShell>
      </body>
    </html>
  );
}
