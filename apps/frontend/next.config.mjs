/** @type {import('next').NextConfig} */
const nextConfig = {
  output: "standalone",
  poweredByHeader: false,
  reactStrictMode: true,
  async rewrites() {
    return [
      { source: "/api/auth/:path*", destination: `${process.env.AUTH_API_URL || "http://auth-svc.app.svc.cluster.local:8080"}/api/v1/:path*` },
      { source: "/api/tasks/:path*", destination: `${process.env.TASKS_API_URL || "http://tasks-svc.app.svc.cluster.local:8080"}/api/v1/:path*` },
      { source: "/api/notifier/:path*", destination: `${process.env.NOTIFIER_API_URL || "http://notifier-svc.app.svc.cluster.local:8080"}/api/v1/:path*` },
    ];
  },
};
export default nextConfig;
