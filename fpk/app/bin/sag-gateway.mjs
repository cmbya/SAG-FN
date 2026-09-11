import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";

const socketPath = process.env.SAG_GATEWAY_SOCKET;
const targetHost = process.env.SAG_WEB_HOST || "127.0.0.1";
const targetPort = Number(process.env.SAG_WEB_PORT || 18199);
const apiHost = process.env.SAG_API_HOST || "127.0.0.1";
const apiPort = Number(process.env.SAG_API_PORT || 18188);

if (!socketPath) throw new Error("SAG_GATEWAY_SOCKET is required");
if (!Number.isInteger(targetPort) || targetPort < 1 || targetPort > 65535) {
  throw new Error(`Invalid SAG_WEB_PORT: ${process.env.SAG_WEB_PORT || ""}`);
}
if (!Number.isInteger(apiPort) || apiPort < 1 || apiPort > 65535) {
  throw new Error(`Invalid SAG_API_PORT: ${process.env.SAG_API_PORT || ""}`);
}

function requestParts(rawUrl) {
  const parsed = new URL(rawUrl || "/", "http://sag.local");
  const pathname = parsed.pathname;
  const isBackend =
    pathname === "/api" ||
    pathname.startsWith("/api/") ||
    pathname === "/mcp" ||
    pathname.startsWith("/mcp/") ||
    pathname === "/app/SAG/api" ||
    pathname.startsWith("/app/SAG/api/") ||
    pathname === "/app/SAG/mcp" ||
    pathname.startsWith("/app/SAG/mcp/");
  const upstreamPath = pathname.startsWith("/app/SAG")
    ? pathname.slice("/app/SAG".length) || "/"
    : pathname;
  return {
    isBackend,
    pathname,
    path: `${isBackend ? upstreamPath : pathname}${parsed.search}`,
  };
}

function writeError(res, error) {
  if (res.headersSent) {
    res.destroy(error);
    return;
  }
  res.writeHead(502, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" });
  res.end("SAG WebUI upstream unavailable\n");
}

const server = http.createServer((req, res) => {
  const parts = requestParts(req.url);
  const upstreamHost = parts.isBackend ? apiHost : targetHost;
  const upstreamPort = parts.isBackend ? apiPort : targetPort;
  const originalHost = req.headers.host || `${upstreamHost}:${upstreamPort}`;
  const headers = { ...req.headers };
  // Preserve the browser-visible host so SAG's port-scoped auth cookie has
  // the same name in the browser, Next middleware, and the root page.
  headers.host = originalHost;
  headers["x-forwarded-proto"] = headers["x-forwarded-proto"] || "http";
  headers["x-forwarded-host"] = headers["x-forwarded-host"] || originalHost;

  const upstream = http.request({
    host: upstreamHost,
    port: upstreamPort,
    method: req.method,
    path: parts.path,
    headers,
  }, (upstreamResponse) => {
    if (parts.isBackend) {
      console.log(`[SAG gateway] ${req.method} ${parts.pathname} -> api ${upstreamResponse.statusCode || 502}`);
    }
    res.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
    upstreamResponse.pipe(res);
  });

  upstream.on("error", (error) => {
    console.error(`[SAG gateway] ${req.method} ${parts.pathname} -> ${parts.isBackend ? "api" : "web"} error=${error.code || error.message}`);
    writeError(res, error);
  });
  req.on("aborted", () => upstream.destroy());
  req.pipe(upstream);
});

server.on("clientError", (_error, socket) => socket.destroy());

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
