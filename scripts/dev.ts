import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { extname } from "node:path";
import app from "../api/index.js";

const port = Number(process.env.PORT ?? 3939);
const types: Record<string, string> = { ".html": "text/html; charset=utf-8", ".md": "text/markdown; charset=utf-8" };

createServer(async (req, res) => {
  // Mirror Vercel: files in public/ win, everything else goes to the function.
  const path = req.url!.split("?")[0].replace(/\/$/, "/index.html");
  if (req.method === "GET" && !path.includes("..")) {
    const file = await readFile(new URL(`../public${path}`, import.meta.url)).catch(() => null);
    if (file) return res.writeHead(200, { "content-type": types[extname(path)] ?? "application/octet-stream" }).end(file);
  }
  const body = req.method === "GET" || req.method === "HEAD" ? undefined : Buffer.concat(await req.toArray());
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) if (v !== undefined) headers.set(k, String(v));
  const response = await app.fetch(new Request(`http://${req.headers.host}${req.url}`, { method: req.method, headers, body }));
  res.writeHead(response.status, Object.fromEntries(response.headers));
  res.end(Buffer.from(await response.arrayBuffer()));
}).listen(port, () => console.log(`agent-board on http://localhost:${port}`));
