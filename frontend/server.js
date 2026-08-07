const fs = require("node:fs/promises");
const crypto = require("node:crypto");
const http = require("node:http");
const path = require("node:path");

const PORT = Number(process.env.PORT || "80");
const PUBLIC_DIR = process.env.PUBLIC_DIR || path.join(process.cwd(), "public");
const CLIENT_UPDATES_DIR =
  process.env.CLIENT_UPDATES_DIR ||
  path.join(process.cwd(), "data", "client-updates");
const FALLBACK_CLIENT_UPDATES_DIR = path.join(PUBLIC_DIR, "client-updates");
const PRIVATE_EXPORTS_DIR = path.join(CLIENT_UPDATES_DIR, ".private-exports");
const PRIVATE_EXPORT_TOKEN = process.env.PRIVATE_EXPORT_TOKEN || "";
const MAX_PRIVATE_EXPORT_BODY_BYTES = 8 * 1024 * 1024;
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
  res.setHeader(
    "Access-Control-Allow-Headers",
    "Content-Type, Authorization, X-Content-Sha256",
  );
  res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, PUT, OPTIONS");
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

async function readLatestClientManifest(roots) {
  const manifests = [];
  for (const rootDir of roots) {
    const candidatePath = resolveSafePath(rootDir, "latest.json");
    if (!candidatePath) continue;
    try {
      const payload = JSON.parse(await fs.readFile(candidatePath, "utf8"));
      if (payload && typeof payload === "object") {
        manifests.push(payload);
      }
    } catch {
      // Ignore an unavailable or malformed manifest and try the other source.
    }
  }
  manifests.sort((left, right) => {
    const versionOrder = compareClientVersions(left.version, right.version);
    if (versionOrder !== 0) {
      return versionOrder;
    }
    return String(left.releaseDate || "").localeCompare(
      String(right.releaseDate || ""),
    );
  });
  return manifests.length > 0 ? manifests[manifests.length - 1] : null;
}

function clientDownloadLocation(manifest) {
  const zipUrl = String(manifest?.zipUrl || "").trim();
  if (
    /^https:\/\/sync\.velvet-leaf\.com\/client\/[A-Za-z0-9._-]+\.zip$/.test(
      zipUrl,
    ) ||
    /^\/client\/[A-Za-z0-9._-]+\.zip$/.test(zipUrl)
  ) {
    return zipUrl;
  }
  return "/client/sync_windows_agent_latest.zip";
}

async function tryServeClientUpdate(pathname, res) {
  if (pathname !== "/client" && !pathname.startsWith("/client/")) {
    return false;
  }

  const requestedPath =
    pathname === "/client"
      ? "latest.json"
      : decodeURIComponent(pathname.substring("/client/".length));
  if (
    requestedPath === ".private-exports" ||
    requestedPath.startsWith(".private-exports/")
  ) {
    sendJson(res, 404, { error: "client update artifact not found" });
    return true;
  }
  const roots = [CLIENT_UPDATES_DIR, FALLBACK_CLIENT_UPDATES_DIR];
  if (requestedPath === "download") {
    const manifest = await readLatestClientManifest(roots);
    const location = clientDownloadLocation(manifest);
    res.writeHead(302, {
      Location: location,
      "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
      Pragma: "no-cache",
    });
    res.end();
    return true;
  }
  if (requestedPath === "latest.json") {
    const manifest = await readLatestClientManifest(roots);
    if (manifest) {
      const body = Buffer.from(JSON.stringify(manifest));
      res.writeHead(200, {
        "Content-Type": "application/json; charset=utf-8",
        "Content-Length": body.length,
        "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
        Pragma: "no-cache",
      });
      res.end(body);
      return true;
    }
  }
  for (const rootDir of roots) {
    const candidatePath = resolveSafePath(rootDir, requestedPath);
    if (!candidatePath) {
      continue;
    }
    try {
      const stat = await fs.stat(candidatePath);
      if (!stat.isFile()) {
        continue;
      }
      const buffer = await fs.readFile(candidatePath);
      const contentType =
        MIME_TYPES[path.extname(candidatePath).toLowerCase()] ||
        "application/octet-stream";
      const headers = {
        "Content-Type": contentType,
        "Content-Length": buffer.length,
      };
      if (
        requestedPath === "update.ps1" ||
        requestedPath === "latest-files.json" ||
        requestedPath === "sync_windows_agent_latest.zip" ||
        requestedPath.startsWith("packages/latest-package/")
      ) {
        headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0";
        headers.Pragma = "no-cache";
      }
      res.writeHead(200, headers);
      res.end(buffer);
      return true;
    } catch {
      // Try the image-bundled fallback when the persistent volume has no file.
    }
  }
  sendJson(res, 404, { error: "client update artifact not found" });
  return true;
}

function compareClientVersions(left, right) {
  const parse = (value) => String(value || "0").split(/[.+-]/).slice(0, 3).map((part) => Number(part) || 0);
  const a = parse(left);
  const b = parse(right);
  return (a[0] - b[0]) || (a[1] - b[1]) || (a[2] - b[2]);
}

function privateExportName(value) {
  const decoded = decodeURIComponent(value || "");
  return /^[A-Za-z0-9._-]{1,128}$/.test(decoded) ? decoded : null;
}

function authorizedPrivateExport(req) {
  if (PRIVATE_EXPORT_TOKEN.length < 32) return false;
  const actual = Buffer.from(String(req.headers.authorization || ""));
  const expected = Buffer.from(`Bearer ${PRIVATE_EXPORT_TOKEN}`);
  return (
    actual.length === expected.length && crypto.timingSafeEqual(actual, expected)
  );
}

async function readBoundedBody(req, maxBytes) {
  const chunks = [];
  let length = 0;
  for await (const chunk of req) {
    length += chunk.length;
    if (length > maxBytes) {
      const error = new Error("private export chunk is too large");
      error.statusCode = 413;
      throw error;
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, length);
}

async function tryStorePrivateExport(pathname, req, res) {
  if (!pathname.startsWith("/private-export/")) return false;
  if (req.method !== "PUT") {
    sendJson(res, 405, { error: "method not allowed" });
    return true;
  }
  if (!authorizedPrivateExport(req)) {
    sendJson(res, 401, { error: "private export authorization failed" });
    return true;
  }
  const segments = pathname.substring("/private-export/".length).split("/");
  if (segments.length !== 3) {
    sendJson(res, 400, { error: "invalid private export path" });
    return true;
  }
  const requestId = privateExportName(segments[0]);
  const clientName = privateExportName(segments[1]);
  const artifactName = privateExportName(segments[2]);
  if (!requestId || !clientName || !artifactName) {
    sendJson(res, 400, { error: "invalid private export name" });
    return true;
  }
  if (artifactName !== "manifest.json" && !/^\d{8}\.part$/.test(artifactName)) {
    sendJson(res, 400, { error: "invalid private export artifact" });
    return true;
  }
  try {
    const body = await readBoundedBody(req, MAX_PRIVATE_EXPORT_BODY_BYTES);
    const actualSha256 = crypto.createHash("sha256").update(body).digest("hex");
    const expectedSha256 = String(req.headers["x-content-sha256"] || "")
      .trim()
      .toLowerCase();
    if (expectedSha256 && expectedSha256 !== actualSha256) {
      sendJson(res, 422, { error: "private export chunk checksum mismatch" });
      return true;
    }
    if (artifactName === "manifest.json") {
      const manifest = JSON.parse(body.toString("utf8"));
      if (
        manifest.requestId !== requestId ||
        manifest.clientName !== clientName ||
        !Number.isSafeInteger(manifest.bytes) ||
        !Number.isSafeInteger(manifest.chunkCount) ||
        !/^[a-f0-9]{64}$/.test(String(manifest.sha256 || ""))
      ) {
        sendJson(res, 400, { error: "invalid private export manifest" });
        return true;
      }
    }
    const directory = path.join(PRIVATE_EXPORTS_DIR, requestId, clientName);
    await fs.mkdir(directory, { recursive: true });
    const targetPath = path.join(directory, artifactName);
    const tempPath = `${targetPath}.${process.pid}.${Date.now()}.tmp`;
    await fs.writeFile(tempPath, body, { flag: "wx", mode: 0o600 });
    await fs.rename(tempPath, targetPath);
    sendJson(res, 201, {
      ok: true,
      requestId,
      clientName,
      artifactName,
      bytes: body.length,
      sha256: actualSha256,
    });
  } catch (error) {
    sendJson(res, error.statusCode || 500, {
      error: error.statusCode ? error.message : "private export storage failed",
    });
  }
  return true;
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

  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  const pathname = url.pathname;

  if (await tryStorePrivateExport(pathname, req, res)) {
    return;
  }

  if (req.method !== "GET" && req.method !== "HEAD") {
    sendJson(res, 404, { error: "not found" });
    return;
  }

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
