import "./globals.css";
import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "USF DevOps — Task Tracker",
  description: "Production-grade DevOps demo",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className="min-h-screen bg-gradient-to-br from-slate-950 via-slate-900 to-purple-950 text-slate-100 antialiased">
        <div className="mx-auto max-w-3xl px-6 py-10">
          <header className="mb-10 flex items-center justify-between">
            <a href="/" className="text-xl font-semibold tracking-tight">
              <span className="text-accent">◆</span> Task Tracker
            </a>
            <nav className="text-sm text-slate-400">
              <span>USF DevOps Orchestration</span>
            </nav>
          </header>
          <main>{children}</main>
          <footer className="mt-16 border-t border-slate-800 pt-6 text-center text-xs text-slate-500">
            Built with EKS · Argo Rollouts · Loki · Grafana — zero downtime promotions
          </footer>
        </div>
      </body>
    </html>
  );
}
