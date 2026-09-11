import assert from "node:assert/strict";
import http from "node:http";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const gatewayEntry = path.join(root, "fpk/app/bin/sag-gateway.mjs");
const { createGatewayServer } = await import(gatewayEntry);

let receivedRequest;
const web = http.createServer((req, res) => {
  receivedRequest = { url: req.url, host: req.headers.host };
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify({ phase: "ready", choices: [] }));
});

await new Promise((resolve, reject) => {
  web.once("error", reject);
  web.listen(0, "127.0.0.1", resolve);
});
const address = web.address();
assert(address && typeof address === "object");

const gateway = createGatewayServer({
  targetHost: "127.0.0.1",
  targetPort: address.port,
});
await new Promise((resolve, reject) => {
  gateway.once("error", reject);
  gateway.listen(0, "127.0.0.1", resolve);
});
const gatewayAddress = gateway.address();
assert(gatewayAddress && typeof gatewayAddress === "object");

try {
  const requestPath = "/app/SAG/api/v1/system/storage-bootstrap?source=fnos";
  const response = await new Promise((resolve, reject) => {
    const request = http.request({
      host: "127.0.0.1",
      port: gatewayAddress.port,
      method: "GET",
      path: requestPath,
      headers: { host: "192.168.100.125:1088" },
    }, (incoming) => {
      let body = "";
      incoming.setEncoding("utf8");
      incoming.on("data", (chunk) => { body += chunk; });
      incoming.on("end", () => resolve({ status: incoming.statusCode, body }));
    });
    request.once("error", reject);
    request.end();
  });

  assert.equal(response.status, 200);
  assert.deepEqual(JSON.parse(response.body), { phase: "ready", choices: [] });
  assert.deepEqual(receivedRequest, {
    url: requestPath,
    host: "192.168.100.125:1088",
  });
  console.log("transparent fnOS gateway test passed");
} finally {
  gateway.close();
  web.close();
}
