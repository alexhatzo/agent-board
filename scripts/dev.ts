import { createServer } from "node:http";
import app from "../api/index.js";

const port = Number(process.env.PORT ?? 3939);
createServer(async (req, res) => {
  const body = req.method === "GET" || req.method === "HEAD" ? undefined : Buffer.concat(await req.toArray());
  const headers = new Headers(Object.entries(req.headers).flatMap(([k, v]) => (v === undefined ? [] : [[k, String(v)]])));
  const response = await app.fetch(new Request(`http://${req.headers.host}${req.url}`, { method: req.method, headers, body }));
  res.writeHead(response.status, Object.fromEntries(response.headers));
  res.end(Buffer.from(await response.arrayBuffer()));
}).listen(port, () => console.log(`agent-board on http://localhost:${port}`));
