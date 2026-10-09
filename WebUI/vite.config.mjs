import { defineConfig } from "vite";
import { proxyok } from "./proxypolicy.mjs";

const nativeActions = ["1", "fixture"].includes(
  process.env.PANEL_NATIVE_ACTIONS,
);
const packageEnabled = process.env.PANEL_NATIVE_ACTIONS === "1";
const target = process.env.PANEL_API_URL || "http://127.0.0.1:18761";

// 保持默认只读，原生授权操作需要独立启用。
export default defineConfig({
  plugins: [
    {
      name: "read-only-api",
      // 在代理之前拒绝变更请求。
      configureServer(server) {
        server.middlewares.use((request, response, next) => {
          if (!packageEnabled && request.method === "GET" && ["/api/v1/environments/capabilities", "/api/v1/environments/containers/capabilities", "/api/v1/files/capabilities", "/api/v1/databases/capabilities"].includes(request.url)) {
            response.writeHead(200, { "Content-Type": "application/json" });
            response.end(JSON.stringify({ enabled: false, actions: [], reason: "当前预览未启用原生操作" }));
            return;
          }
          if (
            !nativeActions &&
            request.method === "GET" &&
            request.url === "/api/v1/services/capabilities"
          ) {
            response.writeHead(200, { "Content-Type": "application/json" });
            response.end(
              JSON.stringify({
                enabled: false,
                reason: "当前预览未启用本机授权操作",
              }),
            );
            return;
          }
          if (
            request.url?.startsWith("/api") &&
            request.method !== "GET" &&
            request.method !== "HEAD" &&
            !proxyok({
              enabled: nativeActions,
              packageEnabled,
              method: request.method,
              path: request.url,
              host: request.headers.host,
              origin: request.headers.origin,
            })
          ) {
            response.writeHead(405);
            response.end("Read-only preview");
            return;
          }
          next();
        });
      },
    },
  ],
  server: {
    host: "127.0.0.1",
    strictPort: true,
    proxy: {
      "/api": {
        target,
        changeOrigin: true,
        // 只在同源校验通过后映射到后台代理边界。
        configure(proxy) {
          proxy.on("proxyReq", (outgoing, request) => {
            if (
              proxyok({
                enabled: nativeActions,
                packageEnabled,
                method: request.method,
                path: request.url,
                host: request.headers.host,
                origin: request.headers.origin,
              })
            ) {
              outgoing.setHeader("Origin", new URL(target).origin);
            }
          });
        },
      },
    },
  },
});
