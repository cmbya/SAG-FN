import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

function writeError(res, error) {
  if (res.headersSent) {
    res.destroy(error);
    return;
  }
  res.writeHead(502, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" });
  res.end("SAG WebUI upstream unavailable\n");
}

export function createGatewayServer({ targetHost, targetPort }) {
  if (!Number.isInteger(targetPort) || targetPort < 1 || targetPort > 65535) {
    throw new Error(`Invalid SAG_WEB_PORT: ${targetPort}`);
  }

  const server = http.createServer((req, res) => {
    const requestUrl = req.url || "/";
    const pathname = new URL(requestUrl, "http://sag.local").pathname;
    const isRuntimeRequest =
      pathname === "/api" ||
      pathname.startsWith("/api/") ||
      pathname === "/mcp" ||
      pathname.startsWith("/mcp/") ||
      pathname === "/app/SAG/api" ||
      pathname.startsWith("/app/SAG/api/") ||
      pathname === "/app/SAG/mcp" ||
      pathname.startsWith("/app/SAG/mcp/");
    const originalHost = req.headers.host || `${targetHost}:${targetPort}`;
    const headers = { ...req.headers };
    // Preserve the browser-visible host so SAG's port-scoped auth cookie has
    // the same name in the browser, Next middleware, and the root page.
    headers.host = originalHost;
    headers["x-forwarded-proto"] = headers["x-forwarded-proto"] || "http";
    headers["x-forwarded-host"] = headers["x-forwarded-host"] || originalHost;

    const upstream = http.request({
      host: targetHost,
      port: targetPort,
      method: req.method,
      // Keep the fnOS-visible path byte-for-byte. The verified Next.js
      // standalone server owns basePath handling and API/MCP rewrites.
      path: requestUrl,
      headers,
    }, (upstreamResponse) => {
      if (isRuntimeRequest) {
        console.log(`[SAG gateway] ${req.method} ${pathname} -> web ${upstreamResponse.statusCode || 502}`);
      }
      res.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
      upstreamResponse.pipe(res);
    });

    upstream.on("error", (error) => {
      console.error(`[SAG gateway] ${req.method} ${pathname} -> web error=${error.code || error.message}`);
      writeError(res, error);
    });
    req.on("aborted", () => upstream.destroy());
    req.pipe(upstream);
  });

  server.on("clientError", (_error, socket) => socket.destroy());
  return server;
}

async function main() {
  const socketPath = process.env.SAG_GATEWAY_SOCKET;
  const targetHost = process.env.SAG_WEB_HOST || "127.0.0.1";
  const targetPort = Number(process.env.SAG_WEB_PORT || 18199);
  if (!socketPath) throw new Error("SAG_GATEWAY_SOCKET is required");

  const server = createGatewayServer({ targetHost, targetPort });
  await fs.mkdir(path.dirname(socketPath), { recursive: true });
  await fs.rm(socketPath, { force: true });
  server.listen(socketPath, () => {
    console.log(`[SAG gateway] listening on ${socketPath}; upstream=${targetHost}:${targetPort}`);
  });

  async function shutdown() {
    server.close(async () => {
      await fs.rm(socketPath, { force: true }).catch(() => {});
      process.exit(0);
    });
    setTimeout(() => process.exit(1), 10_000).unref();
  }

  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

if (fileURLToPath(import.meta.url) === path.resolve(process.argv[1] || "")) {
  await main();
}
