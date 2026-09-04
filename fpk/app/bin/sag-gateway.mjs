import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";

const socketPath = process.env.SAG_GATEWAY_SOCKET;
const targetHost = process.env.SAG_WEB_HOST || "127.0.0.1";
const targetPort = Number(process.env.SAG_WEB_PORT || 18199);

if (!socketPath) throw new Error("SAG_GATEWAY_SOCKET is required");
if (!Number.isInteger(targetPort) || targetPort < 1 || targetPort > 65535) {
  throw new Error(`Invalid SAG_WEB_PORT: ${process.env.SAG_WEB_PORT || ""}`);
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
  const headers = { ...req.headers };
  headers.host = `${targetHost}:${targetPort}`;
  headers["x-forwarded-proto"] = headers["x-forwarded-proto"] || "http";
  headers["x-forwarded-host"] = headers["x-forwarded-host"] || req.headers.host || "";

  const upstream = http.request({
    host: targetHost,
    port: targetPort,
    method: req.method,
    path: req.url || "/",
    headers,
  }, (upstreamResponse) => {
    res.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
    upstreamResponse.pipe(res);
  });

  upstream.on("error", (error) => writeError(res, error));
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
