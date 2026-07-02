const fs = require("node:fs/promises");
const http = require("node:http");
const path = require("node:path");

const PORT = Number(process.env.PORT || "80");
const PUBLIC_DIR = process.env.PUBLIC_DIR || path.join(process.cwd(), "public");
const CLIENT_UPDATES_DIR =
  process.env.CLIENT_UPDATES_DIR ||
  path.join(process.cwd(), "data", "client-updates");
const BUILD_GIT_COMMIT =
  process.env.BUILD_COMMIT_HASH || process.env.TRU_BUILD_GIT_SHA || "unknown";
const BUILD_COMMIT_MESSAGE =
  process.env.BUILD_COMMIT_MESSAGE || process.env.TRU_BUILD_COMMIT_MESSAGE || "";
const BUILD_COMMIT_DATE =
  process.env.BUILD_COMMIT_DATE || process.env.TRU_BUILD_COMMIT_DATE || "unknown";
const BUILD_RELEASE_DATE =
  process.env.BUILD_RELEASE_DATE || process.env.TRU_BUILD_RELEASE_DATE || "unknown";

const MIME_TYPES = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".ico": "image/x-icon",
  ".js": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".map": "application/json; charset=utf-8",
  ".png": "image/png",
  ".ps1": "text/plain; charset=utf-8",
  ".svg": "image/svg+xml",
  ".txt": "text/plain; charset=utf-8",
  ".wasm": "application/wasm",
  ".zip": "application/zip",
  ".z01": "application/octet-stream",
  ".z02": "application/octet-stream",
  ".z03": "application/octet-stream",
  ".z04": "application/octet-stream",
  ".z05": "application/octet-stream",
  ".z06": "application/octet-stream",
  ".z07": "application/octet-stream",
  ".z08": "application/octet-stream",
  ".z09": "application/octet-stream",
};

function nowIso() {
  return new Date().toISOString();
}

function buildInfo() {
  return {
    commit: BUILD_GIT_COMMIT,
    commitHash: BUILD_GIT_COMMIT,
    commitMessage: BUILD_COMMIT_MESSAGE,
    commitDate: BUILD_COMMIT_DATE,
    releaseDate: BUILD_RELEASE_DATE,
  };
}

function withCorsHeaders(res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
  res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
}

function sendJson(res, statusCode, payload) {
  const body = Buffer.from(JSON.stringify(payload));
  res.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": body.length,
  });
  res.end(body);
}

function sendText(res, statusCode, body, contentType = "text/plain; charset=utf-8") {
  const buffer = Buffer.from(body, "utf8");
  res.writeHead(statusCode, {
    "Content-Type": contentType,
    "Content-Length": buffer.length,
  });
  res.end(buffer);
}

function sendBuffer(res, statusCode, buffer, contentType) {
  res.writeHead(statusCode, {
    "Content-Type": contentType,
    "Content-Length": buffer.length,
  });
  res.end(buffer);
}

function envJsPayload() {
  return `window.SQL_SYNC_BUILD = ${JSON.stringify(buildInfo())};\n`;
}

function healthPayload() {
  return {
    ok: true,
    ready: true,
    generatedAt: nowIso(),
    build: buildInfo(),
  };
}

function resolveSafePath(rootDir, requestedPath) {
  const normalizedRoot = path.normalize(rootDir);
  const relativePath = requestedPath.replace(/^\/+/, "");
  const candidatePath = path.normalize(path.join(normalizedRoot, relativePath));
  const rootPrefix = normalizedRoot.endsWith(path.sep)
    ? normalizedRoot
    : `${normalizedRoot}${path.sep}`;
  if (candidatePath !== normalizedRoot && !candidatePath.startsWith(rootPrefix)) {
    return null;
  }
  return candidatePath;
}

async function tryServeClientUpdate(pathname, res) {
  if (pathname !== "/client" && !pathname.startsWith("/client/")) {
    return false;
  }

  const requestedPath =
    pathname === "/client"
      ? "latest.json"
      : decodeURIComponent(pathname.substring("/client/".length));
  const candidatePath = resolveSafePath(CLIENT_UPDATES_DIR, requestedPath);
  if (!candidatePath) {
    sendJson(res, 403, { error: "forbidden" });
    return true;
  }

  try {
    const stat = await fs.stat(candidatePath);
    if (!stat.isFile()) {
      sendJson(res, 404, { error: "client update artifact not found" });
      return true;
    }
    const buffer = await fs.readFile(candidatePath);
    const contentType =
      MIME_TYPES[path.extname(candidatePath).toLowerCase()] ||
      "application/octet-stream";
    sendBuffer(res, 200, buffer, contentType);
    return true;
  } catch {
    sendJson(res, 404, { error: "client update artifact not found" });
    return true;
  }
}

async function tryServeStatic(pathname, res) {
  const requestedPath =
    pathname === "/" ? "/index.html" : decodeURIComponent(pathname);
  let candidatePath = resolveSafePath(PUBLIC_DIR, requestedPath);
  if (!candidatePath) {
    sendJson(res, 403, { error: "forbidden" });
    return true;
  }

  const indexPath = path.join(PUBLIC_DIR, "index.html");

  try {
    const stat = await fs.stat(candidatePath);
    if (stat.isDirectory()) {
      candidatePath = path.join(candidatePath, "index.html");
    }
    const buffer = await fs.readFile(candidatePath);
    const contentType =
      MIME_TYPES[path.extname(candidatePath).toLowerCase()] ||
      "application/octet-stream";
    sendBuffer(res, 200, buffer, contentType);
    return true;
  } catch {
    try {
      const buffer = await fs.readFile(indexPath);
      sendBuffer(res, 200, buffer, MIME_TYPES[".html"]);
      return true;
    } catch {
      return false;
    }
  }
}

async function handleRequest(req, res) {
  withCorsHeaders(res);
  if (req.method === "OPTIONS") {
    res.writeHead(204);
    res.end();
    return;
  }

  if (req.method !== "GET" && req.method !== "HEAD") {
    sendJson(res, 404, { error: "not found" });
    return;
  }

  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  const pathname = url.pathname;

  if (pathname === "/health" || pathname === "/ready") {
    sendJson(res, 200, healthPayload());
    return;
  }

  if (pathname === "/api/env") {
    sendJson(res, 200, {
      generatedAt: nowIso(),
      commit: BUILD_GIT_COMMIT,
      commit_hash: BUILD_GIT_COMMIT,
      build: buildInfo(),
    });
    return;
  }

  const servedUpdate = await tryServeClientUpdate(pathname, res);
  if (servedUpdate) {
    return;
  }

  const servedStatic = await tryServeStatic(pathname, res);
  if (servedStatic) {
    return;
  }

  sendJson(res, 404, { error: "not found" });
}

const server = http.createServer(async (req, res) => {
  try {
    await handleRequest(req, res);
  } catch (error) {
    sendJson(res, 500, {
      error: error instanceof Error ? error.message : "unknown server error",
    });
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`frontend server listening on ${PORT}`);
});
