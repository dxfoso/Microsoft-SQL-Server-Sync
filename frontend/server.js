const crypto = require("node:crypto");
const fs = require("node:fs/promises");
const http = require("node:http");
const path = require("node:path");
const { promisify } = require("node:util");
const zlib = require("node:zlib");

const PORT = Number(process.env.PORT || "6006");
const STATE_FILE =
  process.env.STATE_FILE ||
  path.join(process.cwd(), "data", "state.json");
const CLIENT_UPDATES_DIR =
  process.env.CLIENT_UPDATES_DIR ||
  path.join(path.dirname(STATE_FILE), "client-updates");
const PUBLIC_DIR = process.env.PUBLIC_DIR || path.join(process.cwd(), "public");
const MAX_BODY_SIZE = 100 * 1024 * 1024;
const AGENT_ONLINE_WINDOW_MS = 60 * 1000;
const DEFAULT_HISTORY_LIMIT = 5;
const MAX_HISTORY_LIMIT = 100;
const HEARTBEAT_SAVE_MIN_INTERVAL_MS = 5000;
const DEFAULT_AUTO_SYNC_INTERVAL_MINUTES = 30;
const MIN_AUTO_SYNC_INTERVAL_MINUTES = 1;
const MAX_AUTO_SYNC_INTERVAL_MINUTES = 1440;
const LIVE_STATE_CACHE_TTL_MS = 3000;
const LIVE_STATE_CACHE_STALE_MS = 15000;
const ADMIN_USERNAME = "dxfoso@gmail.com";
const ADMIN_EMAIL = "dxfoso@gmail.com";
const ADMIN_PASSWORD = "Admin@123";
const ADMIN_NAME = "dxfoso@gmail.com";
const ROLE_ADMIN = "admin";
const ROLE_OWNER = "owner";
const ROLE_CLIENT = "client";
const APP_WEB = "web";
const APP_WINDOWS = "windows";
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
};

let state = createDefaultState();
let saveQueue = Promise.resolve();
let lastHeartbeatSaveAt = 0;
const gzipAsync = promisify(zlib.gzip);
const liveStateCache = new Map();

function createDefaultState() {
  return {
    users: {},
    sessions: {},
    agents: {},
    jobs: [],
  };
}

function normalizeEmail(value) {
  return String(value || "").trim().toLowerCase();
}

function normalizeUsername(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9._@-]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function clampInteger(value, fallback, min, max) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return Math.max(min, Math.min(max, Math.round(parsed)));
}

function normalizeSyncMode(_value) {
  return "sync";
}

function directionForSyncMode(_syncMode) {
  return "sync";
}

function normalizeAgentSyncSettings(raw) {
  const source = raw && typeof raw === "object" ? raw : {};
  return {
    historyLimit: clampInteger(
      source.historyLimit,
      DEFAULT_HISTORY_LIMIT,
      1,
      MAX_HISTORY_LIMIT,
    ),
    autoSyncIntervalMinutes: clampInteger(
      source.autoSyncIntervalMinutes,
      DEFAULT_AUTO_SYNC_INTERVAL_MINUTES,
      MIN_AUTO_SYNC_INTERVAL_MINUTES,
      MAX_AUTO_SYNC_INTERVAL_MINUTES,
    ),
  };
}

function usernameFromEmail(value) {
  const normalizedEmail = normalizeEmail(value);
  if (!normalizedEmail) {
    return "";
  }
  return normalizeUsername(normalizedEmail.split("@")[0]);
}

function allocateUsername(preferredUsername, usedUsernames, fallback = "user") {
  const base =
    normalizeUsername(preferredUsername) ||
    normalizeUsername(fallback) ||
    "user";
  let candidate = base;
  let counter = 2;
  while (usedUsernames.has(candidate)) {
    candidate = `${base}-${counter}`;
    counter += 1;
  }
  usedUsernames.add(candidate);
  return candidate;
}

function normalizeRole(value) {
  const normalized = String(value || "").trim().toLowerCase();
  if (
    normalized !== ROLE_ADMIN &&
    normalized !== ROLE_OWNER &&
    normalized !== ROLE_CLIENT
  ) {
    return "";
  }
  return normalized;
}

function passwordHash(password, salt) {
  return crypto
    .createHash("sha256")
    .update(`${salt}:${String(password || "")}`)
    .digest("hex");
}

function userDisplayName(user) {
  const preferred = String(user?.name || "").trim();
  if (preferred) {
    return preferred;
  }
  const username = normalizeUsername(user?.username);
  if (username) {
    return username;
  }
  const email = normalizeEmail(user?.email);
  if (email) {
    return email.split("@")[0];
  }
  return "user";
}

function createStoredUser({
  username,
  email,
  password,
  role,
  name,
  ownerUserId = null,
  createdByUserId = null,
}) {
  const salt = crypto.randomUUID();
  const createdAt = nowIso();
  const normalizedEmail = normalizeEmail(email);
  const normalizedUsername = normalizeUsername(
    name || username || usernameFromEmail(normalizedEmail),
  );
  return {
    id: crypto.randomUUID(),
    username: normalizedUsername,
    email: normalizedEmail,
    name: normalizedUsername || "user",
    role: normalizeRole(role),
    ownerUserId: ownerUserId ? String(ownerUserId) : null,
    createdByUserId: createdByUserId ? String(createdByUserId) : null,
    passwordSalt: salt,
    passwordHash: passwordHash(password, salt),
    createdAt,
    updatedAt: createdAt,
  };
}

function setStoredUserPassword(user, password) {
  const salt = crypto.randomUUID();
  user.passwordSalt = salt;
  user.passwordHash = passwordHash(password, salt);
  user.updatedAt = nowIso();
}

function normalizeStoredUser(raw, usedUsernames = null) {
  const normalizedEmail = normalizeEmail(raw?.email);
  const preferredUsername =
    normalizeUsername(raw?.username) ||
    normalizeUsername(raw?.name) ||
    usernameFromEmail(normalizedEmail);
  const normalizedUsername =
    usedUsernames instanceof Set
      ? allocateUsername(
          preferredUsername,
          usedUsernames,
          normalizedEmail || raw?.name || "user",
        )
      : preferredUsername;
  return {
    id: String(raw?.id || crypto.randomUUID()),
    username: normalizedUsername || "user",
    email: normalizedEmail,
    name: normalizedUsername || "user",
    role: normalizeRole(raw?.role),
    ownerUserId: raw?.ownerUserId ? String(raw.ownerUserId) : null,
    createdByUserId: raw?.createdByUserId ? String(raw.createdByUserId) : null,
    passwordSalt: String(raw?.passwordSalt || ""),
    passwordHash: String(raw?.passwordHash || ""),
    createdAt: String(raw?.createdAt || nowIso()),
    updatedAt: String(raw?.updatedAt || raw?.createdAt || nowIso()),
  };
}

function normalizePersistedState(parsed) {
  const defaults = createDefaultState();
  const normalized = {
    ...defaults,
    ...parsed,
    users: {},
    sessions: {},
    agents: {},
    jobs: [],
  };

  const rawUsers = Object.entries(parsed?.users || {}).map(([id, user]) => ({
    id,
    user,
  }));
  const usedUsernames = new Set();
  const adminLikeIndex = rawUsers.findIndex(
    ({ user }) =>
      normalizeUsername(user?.username) === ADMIN_USERNAME ||
      normalizeEmail(user?.email) === ADMIN_EMAIL,
  );

  if (adminLikeIndex >= 0) {
    const [adminEntry] = rawUsers.splice(adminLikeIndex, 1);
    const normalizedUser = normalizeStoredUser(
      { id: adminEntry.id, ...adminEntry.user, username: ADMIN_USERNAME },
      usedUsernames,
    );
    if (normalizedUser.username && normalizedUser.role) {
      normalized.users[normalizedUser.id] = normalizedUser;
    }
  } else {
    usedUsernames.add(ADMIN_USERNAME);
  }

  for (const { id, user } of rawUsers) {
    const normalizedUser = normalizeStoredUser({ id, ...user }, usedUsernames);
    if (!normalizedUser.username || !normalizedUser.role) {
      continue;
    }
    normalized.users[normalizedUser.id] = normalizedUser;
  }

  const clientUsers = Object.values(normalized.users).filter(
    (user) => user.role === ROLE_CLIENT,
  );
  const findNormalizedClientUser = (identity, clientUserId = null) => {
    if (clientUserId) {
      const byId = normalized.users[String(clientUserId)] || null;
      if (byId?.role === ROLE_CLIENT) {
        return byId;
      }
    }

    const normalizedIdentity = normalizeUsername(identity);
    if (normalizedIdentity) {
      const byUsername = clientUsers.find(
        (user) => user.username === normalizedIdentity,
      );
      if (byUsername) {
        return byUsername;
      }
    }

    const normalizedIdentityEmail = normalizeEmail(identity);
    if (!normalizedIdentityEmail) {
      return null;
    }

    const byEmail = clientUsers.filter(
      (user) => normalizeEmail(user.email) === normalizedIdentityEmail,
    );
    return byEmail.length === 1 ? byEmail[0] : null;
  };

  const normalizeClientIdentity = (identity, clientUserId = null) => {
    const user = findNormalizedClientUser(identity, clientUserId);
    if (user) {
      return user.username;
    }
    return (
      normalizeUsername(identity) ||
      String(identity || "").trim() ||
      `client-${crypto.randomUUID()}`
    );
  };

  for (const [legacyKey, agent] of Object.entries(parsed?.agents || {})) {
    const rawClientIdentity = String(agent?.clientName || legacyKey || "");
    const clientUser = findNormalizedClientUser(
      rawClientIdentity,
      agent?.clientUserId,
    );
    const clientName = normalizeClientIdentity(
      rawClientIdentity,
      agent?.clientUserId,
    );
    const rawSyncSettings =
      agent?.syncSettings && typeof agent.syncSettings === "object"
        ? agent.syncSettings
        : {
            historyLimit: agent?.historyLimit,
            autoSyncIntervalMinutes: agent?.autoSyncIntervalMinutes,
          };
    const syncSettings = normalizeAgentSyncSettings(rawSyncSettings);
    normalized.agents[clientName] = {
      clientName,
      clientUserId: clientUser?.id || (agent?.clientUserId ? String(agent.clientUserId) : null),
      ownerUserId:
        clientUser?.ownerUserId ||
        (agent?.ownerUserId ? String(agent.ownerUserId) : null),
      machineName: String(agent?.machineName || clientName),
      server: String(agent?.server || ""),
      database: String(agent?.database || ""),
      isOnline: Boolean(agent?.isOnline),
      syncSettings,
      syncSettingsUpdatedAt:
        agent?.syncSettingsUpdatedAt && agent?.syncSettings
          ? String(agent.syncSettingsUpdatedAt)
          : null,
      serverConnected: Boolean(agent?.serverConnected),
      sqlConnected: Boolean(agent?.sqlConnected),
      lastHeartbeat: String(agent?.lastHeartbeat || ""),
      selectedTable: agent?.selectedTable
        ? normalizeTableKey(agent.selectedTable)
        : null,
      tables: normalizedAgentTables(agent),
    };
  }

  normalized.jobs = (Array.isArray(parsed?.jobs) ? parsed.jobs : [])
    .map((job) => {
      const clientUser = findNormalizedClientUser(job?.clientName, job?.clientUserId);
      const sourceClientUser = findNormalizedClientUser(
        job?.sourceClientName,
        job?.sourceClientUserId,
      );
      const clientName = normalizeClientIdentity(
        job?.clientName,
        job?.clientUserId,
      );
      const sourceClientName = normalizeClientIdentity(
        job?.sourceClientName || job?.clientName,
        job?.sourceClientUserId,
      );
      return {
        ...job,
        clientName,
        clientUserId:
          clientUser?.id || (job?.clientUserId ? String(job.clientUserId) : null),
        ownerUserId:
          clientUser?.ownerUserId ||
          (job?.ownerUserId ? String(job.ownerUserId) : null),
        sourceClientName,
        sourceClientUserId:
          sourceClientUser?.id ||
          (job?.sourceClientUserId ? String(job.sourceClientUserId) : null),
        table: normalizeTableKey(job?.table),
      };
    })
    .filter((job) => String(job.clientName || "").trim() && String(job.table || "").trim());

  for (const [tokenHash, session] of Object.entries(parsed?.sessions || {})) {
    normalized.sessions[tokenHash] = {
      id: String(session?.id || crypto.randomUUID()),
      userId: String(session?.userId || ""),
      app: String(session?.app || ""),
      createdAt: String(session?.createdAt || nowIso()),
      lastUsedAt: String(session?.lastUsedAt || session?.createdAt || nowIso()),
    };
  }

  return normalized;
}

function findUserByUsername(username) {
  const normalized = normalizeUsername(username);
  for (const user of Object.values(state.users || {})) {
    if (normalizeUsername(user.username) === normalized) {
      return user;
    }
  }
  return null;
}

function findUsersByEmail(email) {
  const normalized = normalizeEmail(email);
  if (!normalized) {
    return [];
  }
  return Object.values(state.users || {}).filter(
    (user) => normalizeEmail(user.email) === normalized,
  );
}

function ownerForUser(user) {
  if (!user?.ownerUserId) {
    return null;
  }
  return state.users[user.ownerUserId] || null;
}

function publicUserPayload(user) {
  const owner = ownerForUser(user);
  return {
    id: user.id,
    username: user.name,
    email: user.email || "",
    name: user.name,
    role: user.role,
    ownerUserId: user.ownerUserId,
    ownerUsername: owner ? owner.name : null,
    ownerEmail: owner ? owner.email : null,
    ownerName: owner ? owner.name : null,
    createdByUserId: user.createdByUserId,
    createdAt: user.createdAt,
  };
}

function ensureSeedUsers() {
  let admin =
    findUserByUsername(ADMIN_USERNAME) || findUsersByEmail(ADMIN_EMAIL)[0] || null;
  if (!admin) {
    admin = createStoredUser({
      username: ADMIN_USERNAME,
      email: ADMIN_EMAIL,
      password: ADMIN_PASSWORD,
      role: ROLE_ADMIN,
      name: ADMIN_NAME,
    });
    state.users[admin.id] = admin;
    return true;
  }

  let changed = false;
  if (admin.username !== ADMIN_USERNAME) {
    admin.username = ADMIN_USERNAME;
    changed = true;
  }
  if (admin.name !== ADMIN_NAME) {
    admin.name = ADMIN_NAME;
    changed = true;
  }
  if (admin.role !== ROLE_ADMIN) {
    admin.role = ROLE_ADMIN;
    changed = true;
  }
  if (normalizeEmail(admin.email) !== ADMIN_EMAIL) {
    admin.email = ADMIN_EMAIL;
    changed = true;
  }
  if (!String(admin.name || "").trim()) {
    admin.name = ADMIN_NAME;
    changed = true;
  }
  return changed;
}

function createSession(userId, app) {
  const token = `${crypto.randomUUID()}-${crypto.randomBytes(16).toString("hex")}`;
  const tokenHash = crypto.createHash("sha256").update(token).digest("hex");
  const createdAt = nowIso();
  state.sessions[tokenHash] = {
    id: crypto.randomUUID(),
    userId: String(userId),
    app: String(app || ""),
    createdAt,
    lastUsedAt: createdAt,
  };
  return token;
}

function readAuthToken(req) {
  const authHeader = String(req.headers.authorization || "").trim();
  if (authHeader.toLowerCase().startsWith("bearer ")) {
    return authHeader.slice(7).trim();
  }
  return String(req.headers["x-auth-token"] || "").trim();
}

function authContext(req) {
  const token = readAuthToken(req);
  if (!token) {
    return null;
  }
  const tokenHash = crypto.createHash("sha256").update(token).digest("hex");
  const session = state.sessions[tokenHash];
  if (!session) {
    return null;
  }
  const user = state.users[session.userId];
  if (!user) {
    delete state.sessions[tokenHash];
    return null;
  }
  session.lastUsedAt = nowIso();
  return { tokenHash, session, user };
}

function requireAuth(req, res, { allowedRoles = null, app = null } = {}) {
  const context = authContext(req);
  if (!context) {
    sendJson(res, 401, { error: "authentication required" });
    return null;
  }
  if (app && context.session.app !== app) {
    sendJson(res, 403, { error: `${app} session required` });
    return null;
  }
  if (allowedRoles && !allowedRoles.includes(context.user.role)) {
    sendJson(res, 403, { error: "permission denied" });
    return null;
  }
  return context;
}

function canAccessClientUser(viewer, clientUser) {
  if (!viewer || !clientUser || clientUser.role !== ROLE_CLIENT) {
    return false;
  }
  if (viewer.role === ROLE_ADMIN) {
    return true;
  }
  return viewer.role === ROLE_OWNER && clientUser.ownerUserId === viewer.id;
}

function visibleUsersFor(viewer) {
  const users = Object.values(state.users || {});
  if (viewer.role === ROLE_ADMIN) {
    return users;
  }
  if (viewer.role === ROLE_OWNER) {
    return users.filter(
      (user) =>
        user.id === viewer.id ||
        (user.role === ROLE_CLIENT && user.ownerUserId === viewer.id),
    );
  }
  return users.filter((user) => user.id === viewer.id);
}

function viewerCanAccessRecord(viewer, ownerUserId, clientUserId) {
  if (!viewer) {
    return false;
  }
  if (viewer.role === ROLE_ADMIN) {
    return true;
  }
  if (viewer.role === ROLE_OWNER) {
    return ownerUserId === viewer.id;
  }
  return viewer.role === ROLE_CLIENT && clientUserId === viewer.id;
}

function findClientUserByName(clientName) {
  const normalizedUsername = normalizeUsername(clientName);
  if (normalizedUsername) {
    const byUsername = Object.values(state.users || {}).find(
      (user) => user.role === ROLE_CLIENT && user.username === normalizedUsername,
    );
    if (byUsername) {
      return byUsername;
    }
  }

  const normalizedEmail = normalizeEmail(clientName);
  if (!normalizedEmail) {
    return null;
  }
  const emailMatches = Object.values(state.users || {}).filter(
    (user) =>
      user.role === ROLE_CLIENT && normalizeEmail(user.email) === normalizedEmail,
  );
  return emailMatches.length === 1 ? emailMatches[0] : null;
}

function sortUsers(users) {
  const priority = {
    [ROLE_ADMIN]: 0,
    [ROLE_OWNER]: 1,
    [ROLE_CLIENT]: 2,
  };
  return [...users].sort((left, right) => {
    const byRole = (priority[left.role] ?? 99) - (priority[right.role] ?? 99);
    if (byRole !== 0) {
      return byRole;
    }
    return (left.name || "").localeCompare(right.name || "");
  });
}

function nowIso() {
  return new Date().toISOString();
}

function buildInfo() {
  return {
    git_commit: BUILD_GIT_COMMIT,
    commit_message: BUILD_COMMIT_MESSAGE,
    commit_date: BUILD_COMMIT_DATE,
    release_date: BUILD_RELEASE_DATE,
  };
}

function healthPayload() {
  const build = buildInfo();
  return {
    ok: true,
    ready: true,
    generatedAt: nowIso(),
    commit: build.git_commit,
    commit_hash: build.git_commit,
    build,
  };
}

function envJsPayload() {
  return [
    "window.__env = window.__env || {};",
    `window.__env.BACKEND_BASE_URL = ${JSON.stringify(
      process.env.BACKEND_BASE_URL || "",
    )};`,
    `window.__env.BUILD_COMMIT_HASH = ${JSON.stringify(BUILD_GIT_COMMIT)};`,
    `window.__env.BUILD_COMMIT_MESSAGE = ${JSON.stringify(
      BUILD_COMMIT_MESSAGE,
    )};`,
    `window.__env.BUILD_COMMIT_DATE = ${JSON.stringify(BUILD_COMMIT_DATE)};`,
    `window.__env.BUILD_RELEASE_DATE = ${JSON.stringify(BUILD_RELEASE_DATE)};`,
    "",
  ].join("\n");
}

const TABLE_DATABASE_SEPARATOR = "::";

function tableHasDatabase(table) {
  return String(table || "").includes(TABLE_DATABASE_SEPARATOR);
}

function databaseFromTableKey(table) {
  const value = String(table || "");
  const separatorIndex = value.indexOf(TABLE_DATABASE_SEPARATOR);
  return separatorIndex < 0 ? "" : value.slice(0, separatorIndex).trim();
}

function localTableFromTableKey(table) {
  const value = String(table || "").trim();
  const separatorIndex = value.indexOf(TABLE_DATABASE_SEPARATOR);
  return separatorIndex < 0
    ? value
    : value.slice(separatorIndex + TABLE_DATABASE_SEPARATOR.length).trim();
}

function normalizeLocalTableName(table) {
  return String(table || "")
    .trim()
    .replace(/^dbo\./i, "");
}

function normalizeTableKey(table) {
  const databaseName = databaseFromTableKey(table);
  const tableName = normalizeLocalTableName(localTableFromTableKey(table));
  if (!tableName) {
    return "";
  }
  return databaseName
    ? `${databaseName}${TABLE_DATABASE_SEPARATOR}${tableName}`
    : tableName;
}

function tableBelongsToDatabase(table, database) {
  const databaseName = String(database || "").trim();
  if (!databaseName) {
    return false;
  }
  const tableDatabase = databaseFromTableKey(table);
  return tableDatabase ? tableDatabase === databaseName : true;
}

function qualifyTableWithDatabase(table, database) {
  const tableName = normalizeTableKey(table);
  const databaseName = String(database || "").trim();
  if (!tableName || !databaseName || tableHasDatabase(tableName)) {
    return tableName;
  }
  return `${databaseName}${TABLE_DATABASE_SEPARATOR}${tableName}`;
}

function withCorsHeaders(res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
}

function sendJson(res, statusCode, payload) {
  withCorsHeaders(res);
  res.writeHead(statusCode, { "Content-Type": "application/json" });
  res.end(JSON.stringify(payload));
}

function sendBuffer(res, statusCode, buffer, contentType, extraHeaders = {}) {
  withCorsHeaders(res);
  res.writeHead(statusCode, {
    "Content-Type": contentType,
    ...extraHeaders,
  });
  res.end(buffer);
}

function sendText(res, statusCode, body, contentType, extraHeaders = {}) {
  sendBuffer(
    res,
    statusCode,
    Buffer.from(String(body ?? ""), "utf8"),
    contentType,
    extraHeaders,
  );
}

function acceptsGzip(req) {
  return String(req.headers["accept-encoding"] || "")
    .toLowerCase()
    .includes("gzip");
}

function liveStateCacheKey(viewer) {
  return `${viewer.role}:${viewer.id}`;
}

function clearLiveStateCache() {
  liveStateCache.clear();
}

function markLiveStateCacheStale() {
  const now = Date.now();
  for (const entry of liveStateCache.values()) {
    entry.freshUntil = 0;
    entry.staleUntil = Math.max(entry.staleUntil || 0, now + LIVE_STATE_CACHE_STALE_MS);
  }
}

async function buildLiveStateCacheEntry(viewer) {
  const plainBuffer = Buffer.from(JSON.stringify(buildLiveState(viewer)));
  const gzipBuffer = await gzipAsync(plainBuffer);
  const now = Date.now();
  return {
    plainBuffer,
    gzipBuffer,
    freshUntil: now + LIVE_STATE_CACHE_TTL_MS,
    staleUntil: now + LIVE_STATE_CACHE_STALE_MS,
    refreshPromise: null,
  };
}

function refreshLiveStateCacheEntry(key, viewer, existingEntry = null) {
  const refreshPromise = buildLiveStateCacheEntry(viewer)
    .then((nextEntry) => {
      liveStateCache.set(key, nextEntry);
      return nextEntry;
    })
    .catch((error) => {
      if (existingEntry) {
        existingEntry.refreshPromise = null;
        liveStateCache.set(key, existingEntry);
      } else {
        liveStateCache.delete(key);
      }
      throw error;
    });

  if (existingEntry) {
    existingEntry.refreshPromise = refreshPromise;
    liveStateCache.set(key, existingEntry);
  } else {
    liveStateCache.set(key, {
      plainBuffer: null,
      gzipBuffer: null,
      freshUntil: 0,
      staleUntil: 0,
      refreshPromise,
    });
  }

  return refreshPromise;
}

async function cachedLiveStateEntry(viewer) {
  const key = liveStateCacheKey(viewer);
  const cached = liveStateCache.get(key);
  const now = Date.now();

  if (cached?.plainBuffer && cached.freshUntil > now) {
    return cached;
  }

  if (cached?.plainBuffer && cached.staleUntil > now) {
    if (!cached.refreshPromise) {
      refreshLiveStateCacheEntry(key, viewer, cached).catch(() => {});
    }
    return cached;
  }

  if (cached?.refreshPromise) {
    return cached.refreshPromise;
  }

  return refreshLiveStateCacheEntry(key, viewer, cached || null);
}

async function sendLiveState(req, res, viewer) {
  const cached = await cachedLiveStateEntry(viewer);
  if (acceptsGzip(req) && cached.gzipBuffer) {
    sendBuffer(res, 200, cached.gzipBuffer, "application/json; charset=utf-8", {
      "Content-Encoding": "gzip",
      Vary: "Accept-Encoding",
    });
    return;
  }

  sendBuffer(
    res,
    200,
    cached.plainBuffer,
    "application/json; charset=utf-8",
    { Vary: "Accept-Encoding" },
  );
}

async function parseJsonBody(req) {
  const chunks = [];
  let totalBytes = 0;

  for await (const chunk of req) {
    totalBytes += chunk.length;
    if (totalBytes > MAX_BODY_SIZE) {
      throw new Error("Request body is too large.");
    }
    chunks.push(chunk);
  }

  if (chunks.length === 0) {
    return {};
  }

  const raw = Buffer.concat(chunks).toString("utf8").trim();
  return raw ? JSON.parse(raw) : {};
}

async function loadState() {
  try {
    const raw = await fs.readFile(STATE_FILE, "utf8");
    const parsed = JSON.parse(raw);
    state = normalizePersistedState(parsed);
  } catch {
    state = createDefaultState();
  }
  clearLiveStateCache();

  const seeded = ensureSeedUsers();
  if (seeded) {
    await queueSave();
  }
}

function queueSave() {
  markLiveStateCacheStale();
  saveQueue = saveQueue
    .then(async () => {
      await fs.mkdir(path.dirname(STATE_FILE), { recursive: true });
      const payload = JSON.stringify(state, null, 2);
      const tempFile = `${STATE_FILE}.tmp`;
      await fs.writeFile(tempFile, payload, "utf8");
      await fs.rename(tempFile, STATE_FILE);
    })
    .catch(() => {});
  return saveQueue;
}

function maybeQueueHeartbeatSave() {
  const now = Date.now();
  if (now - lastHeartbeatSaveAt < HEARTBEAT_SAVE_MIN_INTERVAL_MS) {
    return;
  }
  lastHeartbeatSaveAt = now;
  queueSave().catch(() => {});
}

function sortJobsDescending(items) {
  return items.sort((left, right) =>
    String(right.updatedAt || right.createdAt || "").localeCompare(
      String(left.updatedAt || left.createdAt || ""),
    ),
  );
}

function publicJobPayload(job) {
  return { ...job };
}

function normalizeTableState(tableState) {
  const direction = directionForSyncMode(tableState.syncMode);
  const syncMode = normalizeSyncMode(tableState.syncMode);
  return {
    table: normalizeTableKey(tableState.table),
    enabled: Boolean(tableState.enabled),
    status: String(tableState.status || "Idle"),
    lastSync: String(tableState.lastSync || ""),
    progress: Number(tableState.progress || 0),
    direction,
    syncMode,
    rowCount: Number(tableState.rowCount || 0),
    message: String(tableState.message || ""),
  };
}

function mergeHeartbeatTableState(existingTableState, incomingTableState) {
  const normalizedIncoming = normalizeTableState(incomingTableState);
  const existingHistory = Array.isArray(existingTableState?.history)
    ? existingTableState.history
    : [];
  return {
    ...existingTableState,
    ...normalizedIncoming,
    history: existingHistory,
  };
}

function normalizedAgentTables(agent) {
  const tables = {};
  for (const [key, value] of Object.entries(agent?.tables || {})) {
    const normalizedTableState = normalizeTableState({
      ...value,
      table: value?.table || key,
    });
    if (!normalizedTableState.table) {
      continue;
    }
    tables[normalizedTableState.table] = mergeHeartbeatTableState(
      tables[normalizedTableState.table],
      normalizedTableState,
    );
  }
  return tables;
}

function ensureAgent(clientName, metadata = {}) {
  if (!state.agents[clientName]) {
    const syncSettings = normalizeAgentSyncSettings(metadata.syncSettings);
    state.agents[clientName] = {
      clientName,
      clientUserId: metadata.clientUserId || null,
      ownerUserId: metadata.ownerUserId || null,
      machineName: clientName,
      server: "",
      database: "",
      isOnline: false,
      syncSettings,
      syncSettingsUpdatedAt: null,
      serverConnected: false,
      sqlConnected: false,
      lastHeartbeat: "",
      selectedTable: null,
      tables: {},
    };
  }
  if (!state.agents[clientName].syncSettings) {
    state.agents[clientName].syncSettings = normalizeAgentSyncSettings(
      metadata.syncSettings,
    );
    state.agents[clientName].syncSettingsUpdatedAt = null;
  }
  if (metadata.clientUserId) {
    state.agents[clientName].clientUserId = String(metadata.clientUserId);
  }
  if (metadata.ownerUserId) {
    state.agents[clientName].ownerUserId = String(metadata.ownerUserId);
  }
  return state.agents[clientName];
}

function updateAgentTableFromJob(job, patch) {
  const agent = ensureAgent(job.clientName);
  const currentTable = normalizeTableState(
    agent.tables[job.table] || { table: job.table, enabled: true },
  );
  agent.tables[job.table] = {
    ...currentTable,
    ...patch,
    table: job.table,
  };
}

function buildLiveState(viewer) {
  const generatedAt = nowIso();
  const agents = Object.values(state.agents)
    .filter((agent) =>
      viewerCanAccessRecord(viewer, agent.ownerUserId || null, agent.clientUserId || null),
    )
    .map((agent) => {
      const syncSettings = normalizeAgentSyncSettings(agent.syncSettings);
      const lastHeartbeat = agent.lastHeartbeat
        ? Date.parse(agent.lastHeartbeat)
        : 0;
      const isOnline =
        Number.isFinite(lastHeartbeat) &&
        Date.now() - lastHeartbeat < AGENT_ONLINE_WINDOW_MS;

      return {
        clientName: agent.clientName,
        machineName: agent.machineName,
        server: agent.server,
        database: agent.database,
        isOnline,
        historyLimit: syncSettings.historyLimit,
        autoSyncIntervalMinutes: syncSettings.autoSyncIntervalMinutes,
        serverConnected: Boolean(agent.serverConnected),
        sqlConnected: Boolean(agent.sqlConnected),
        lastHeartbeat: agent.lastHeartbeat,
        selectedTable: agent.selectedTable,
        tables: Object.values(agent.tables || {})
          .map((tableState) => normalizeTableState(tableState))
          .sort((left, right) => left.table.localeCompare(right.table)),
      };
    })
    .sort((left, right) => left.clientName.localeCompare(right.clientName));

  const visibleJobs = sortJobsDescending(
    state.jobs.filter((job) =>
      viewerCanAccessRecord(viewer, job.ownerUserId || null, job.clientUserId || null),
    ),
  ).slice(0, 100).map(publicJobPayload);

  return { generatedAt, agents, jobs: visibleJobs };
}

function createJob(payload) {
  const job = {
    id: crypto.randomUUID(),
    clientName: String(payload.clientName || ""),
    clientUserId: payload.clientUserId ? String(payload.clientUserId) : null,
    ownerUserId: payload.ownerUserId ? String(payload.ownerUserId) : null,
    sourceClientName: String(
      payload.sourceClientName || payload.clientName || "",
    ),
    sourceClientUserId: payload.sourceClientUserId
      ? String(payload.sourceClientUserId)
      : null,
    table: normalizeTableKey(payload.table),
    direction: "sync",
    syncMode: normalizeSyncMode(payload.syncMode),
    status: "queued",
    progress: 0,
    rowCount: 0,
    createdAt: nowIso(),
    updatedAt: nowIso(),
    startedAt: null,
    completedAt: null,
    message: String(payload.message || "Queued."),
    error: null,
  };
  state.jobs.unshift(job);
  updateAgentTableFromJob(job, {
    enabled: true,
    status: "Queued",
    progress: 0,
    direction: job.direction,
    syncMode: job.syncMode,
    message: job.message,
  });
  return job;
}

function findJob(jobId) {
  return state.jobs.find((item) => item.id === jobId) || null;
}

function updateJob(job, patch) {
  Object.assign(job, patch, { updatedAt: nowIso() });
  updateAgentTableFromJob(job, {
    status: patch.status ? String(patch.status) : job.status,
    progress:
      patch.progress !== undefined ? Number(patch.progress) : Number(job.progress),
    direction: patch.direction ? String(patch.direction) : job.direction,
    lastSync:
      patch.lastSync !== undefined
        ? String(patch.lastSync)
        : job.completedAt || job.updatedAt,
    rowCount:
      patch.rowCount !== undefined ? Number(patch.rowCount) : Number(job.rowCount),
    message: patch.message !== undefined ? String(patch.message) : job.message,
  });
}

function agentTableState(clientName, table) {
  const agent = state.agents[clientName];
  if (!agent || !agent.tables) {
    return null;
  }
  return agent.tables[table] ? normalizeTableState(agent.tables[table]) : null;
}


function isJobActive(job) {
  return job.status === "queued" || job.status === "running";
}

function activeJobsForClient(clientName) {
  return sortJobsDescending(
    state.jobs.filter(
      (job) => job.clientName === clientName && isJobActive(job),
    ),
  ).map(publicJobPayload);
}

async function tryServeStatic(pathname, res) {
  if (pathname.startsWith("/api")) {
    return false;
  }

  const requestedPath =
    pathname === "/" ? "/index.html" : decodeURIComponent(pathname);
  const safeRelativePath = requestedPath.replace(/^\/+/, "");
  let candidatePath = path.normalize(path.join(PUBLIC_DIR, safeRelativePath));

  if (!candidatePath.startsWith(path.normalize(PUBLIC_DIR))) {
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

async function tryServeClientUpdate(pathname, res) {
  if (pathname !== "/client" && !pathname.startsWith("/client/")) {
    return false;
  }

  const requestedPath =
    pathname === "/client" ? "latest.json" : decodeURIComponent(pathname.substring("/client/".length));
  const safeRelativePath = requestedPath.replace(/^\/+/, "");
  let candidatePath = path.normalize(path.join(CLIENT_UPDATES_DIR, safeRelativePath));
  const normalizedRoot = path.normalize(CLIENT_UPDATES_DIR);
  const rootPrefix = normalizedRoot.endsWith(path.sep)
    ? normalizedRoot
    : `${normalizedRoot}${path.sep}`;

  if (
    candidatePath !== normalizedRoot &&
    !candidatePath.startsWith(rootPrefix)
  ) {
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

async function handleRequest(req, res) {
  withCorsHeaders(res);
  if (req.method === "OPTIONS") {
    res.writeHead(204);
    res.end();
    return;
  }

  const url = new URL(req.url, `http://${req.headers.host}`);
  const pathname = url.pathname;

  if (
    req.method === "GET" &&
    (
      pathname === "/health" ||
      pathname === "/ready" ||
      pathname === "/api/health" ||
      pathname === "/api/ready"
    )
  ) {
    sendJson(res, 200, healthPayload());
    return;
  }

  if (req.method === "GET" && pathname === "/env.js") {
    sendText(res, 200, envJsPayload(), "application/javascript; charset=utf-8", {
      "Cache-Control": "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0",
      Pragma: "no-cache",
      Expires: "0",
    });
    return;
  }

  if (req.method === "GET" && pathname === "/api/env") {
    sendJson(res, 200, {
      generatedAt: nowIso(),
      commit: BUILD_GIT_COMMIT,
      commit_hash: BUILD_GIT_COMMIT,
      build: buildInfo(),
    });
    return;
  }

  if (req.method === "POST" && pathname === "/api/auth/login") {
    const body = await parseJsonBody(req);
    const username = normalizeUsername(body.name || body.username);
    const password = String(body.password || "");
    const app = String(body.app || APP_WEB).trim().toLowerCase();
    const user = findUserByUsername(username);

    if (!user || passwordHash(password, user.passwordSalt) !== user.passwordHash) {
      sendJson(res, 401, { error: "invalid name or password" });
      return;
    }

    if (user.role === ROLE_CLIENT && !user.ownerUserId) {
      sendJson(res, 400, {
        error: "client account is missing an owner assignment",
      });
      return;
    }

    const token = createSession(user.id, app);
    await queueSave();
    sendJson(res, 200, { token, user: publicUserPayload(user) });
    return;
  }

  if (req.method === "GET" && pathname === "/api/auth/me") {
    const context = requireAuth(req, res);
    if (!context) {
      return;
    }
    sendJson(res, 200, { user: publicUserPayload(context.user) });
    return;
  }

  if (req.method === "POST" && pathname === "/api/auth/logout") {
    const context = requireAuth(req, res);
    if (!context) {
      return;
    }
    delete state.sessions[context.tokenHash];
    await queueSave();
    sendJson(res, 200, { ok: true });
    return;
  }

  if (req.method === "GET" && pathname === "/api/users") {
    const context = requireAuth(req, res, {
      allowedRoles: [ROLE_ADMIN, ROLE_OWNER],
      app: APP_WEB,
    });
    if (!context) {
      return;
    }
    const users = sortUsers(visibleUsersFor(context.user)).map(publicUserPayload);
    sendJson(res, 200, { users });
    return;
  }

  if (req.method === "POST" && pathname === "/api/users") {
    const context = requireAuth(req, res, {
      allowedRoles: [ROLE_ADMIN, ROLE_OWNER],
      app: APP_WEB,
    });
    if (!context) {
      return;
    }

    const body = await parseJsonBody(req);
    const role = normalizeRole(body.role);
    const email = normalizeEmail(body.email);
    const password = String(body.password || "");
    const name = normalizeUsername(body.name || body.username);

    if (!name || !password || !role) {
      sendJson(res, 400, {
        error: "name, password, and role are required",
      });
      return;
    }

    if (findUserByUsername(name)) {
      sendJson(res, 409, { error: "an account with that name already exists" });
      return;
    }

    let ownerUserId = null;
    if (context.user.role === ROLE_OWNER) {
      if (role !== ROLE_CLIENT) {
        sendJson(res, 403, { error: "owners can create client accounts only" });
        return;
      }
      ownerUserId = context.user.id;
    } else {
      if (role !== ROLE_OWNER && role !== ROLE_CLIENT) {
        sendJson(res, 403, { error: "admins can create owner or client accounts only" });
        return;
      }
      if (role === ROLE_CLIENT) {
        ownerUserId = body.ownerUserId ? String(body.ownerUserId) : "";
        const owner = state.users[ownerUserId] || null;
        if (!owner || owner.role !== ROLE_OWNER) {
          sendJson(res, 400, { error: "client accounts must belong to a valid owner" });
          return;
        }
      }
    }

    const user = createStoredUser({
      username: name,
      email,
      password,
      role,
      name,
      ownerUserId,
      createdByUserId: context.user.id,
    });
    state.users[user.id] = user;
    await queueSave();
    sendJson(res, 201, { user: publicUserPayload(user) });
    return;
  }

  const resetPasswordMatch =
    req.method === "POST"
      ? pathname.match(/^\/api\/users\/([^/]+)\/reset-password$/)
      : null;
  if (resetPasswordMatch) {
    const context = requireAuth(req, res, {
      allowedRoles: [ROLE_ADMIN],
      app: APP_WEB,
    });
    if (!context) {
      return;
    }

    const userId = decodeURIComponent(resetPasswordMatch[1] || "");
    const user = state.users[userId] || null;
    if (!user) {
      sendJson(res, 404, { error: "user not found" });
      return;
    }

    const body = await parseJsonBody(req);
    const password = String(body.password || "");
    if (!password.trim()) {
      sendJson(res, 400, { error: "password is required" });
      return;
    }

    setStoredUserPassword(user, password);
    await queueSave();
    sendJson(res, 200, { ok: true });
    return;
  }

  if (req.method === "GET" && pathname === "/api/live-state") {
    const context = requireAuth(req, res, {
      allowedRoles: [ROLE_ADMIN, ROLE_OWNER],
      app: APP_WEB,
    });
    if (!context) {
      return;
    }
    await sendLiveState(req, res, context.user);
    return;
  }

  if (req.method === "POST" && pathname === "/api/agents/heartbeat") {
    const context = requireAuth(req, res, {
      allowedRoles: [ROLE_CLIENT],
      app: APP_WINDOWS,
    });
    if (!context) {
      return;
    }
    const body = await parseJsonBody(req);
    const clientName = context.user.username;
    const incomingSyncSettings = normalizeAgentSyncSettings(
      {
        historyLimit: body.historyLimit,
        autoSyncIntervalMinutes: body.autoSyncIntervalMinutes,
      },
    );

    const agent = ensureAgent(clientName, {
      clientUserId: context.user.id,
      ownerUserId: context.user.ownerUserId,
      syncSettings: incomingSyncSettings,
    });
    if (!agent.syncSettingsUpdatedAt) {
      agent.syncSettings = incomingSyncSettings;
    }
    agent.clientName = clientName;
    agent.machineName = String(body.machineName || userDisplayName(context.user));
    agent.server = String(body.server || "");
    agent.database = String(body.database || "");
    agent.serverConnected = Boolean(body.serverConnected);
    agent.sqlConnected = Boolean(body.sqlConnected);
    agent.lastHeartbeat = nowIso();
    agent.selectedTable = body.selectedTable
      ? qualifyTableWithDatabase(body.selectedTable, agent.database)
      : null;
    if (Array.isArray(body.tables)) {
      const existingTables = normalizedAgentTables(agent);
      const nextTables = Object.fromEntries(
        Object.entries(existingTables).filter(
          ([table]) => !tableBelongsToDatabase(table, agent.database),
        ),
      );
      for (const tableState of body.tables) {
        const normalizedTableState = normalizeTableState(tableState);
        normalizedTableState.table = qualifyTableWithDatabase(
          normalizedTableState.table,
          agent.database,
        );
        if (!normalizedTableState.table) {
          continue;
        }
        normalizedTableState.syncMode = normalizeSyncMode(
          normalizedTableState.syncMode,
        );
        normalizedTableState.direction = directionForSyncMode(
          normalizedTableState.syncMode,
        );
        nextTables[normalizedTableState.table] = mergeHeartbeatTableState(
          agent.tables[normalizedTableState.table],
          normalizedTableState,
        );
      }
      agent.tables = nextTables;
    }

    maybeQueueHeartbeatSave();
    sendJson(res, 200, {
      ok: true,
      syncSettings: agent.syncSettings,
      jobs: activeJobsForClient(clientName),
    });
    return;
  }

  const syncSettingsMatch = pathname.match(/^\/api\/agents\/([^/]+)\/sync-settings$/);
  if (
    (req.method === "GET" || req.method === "POST") &&
    syncSettingsMatch
  ) {
    const context = requireAuth(req, res, {
      allowedRoles: [ROLE_ADMIN, ROLE_OWNER],
      app: APP_WEB,
    });
    if (!context) {
      return;
    }
    const clientIdentity = decodeURIComponent(syncSettingsMatch[1] || "");
    const clientUser = findClientUserByName(clientIdentity);
    if (!clientUser || !canAccessClientUser(context.user, clientUser)) {
      sendJson(res, 403, { error: "permission denied for that client account" });
      return;
    }
    const agent = ensureAgent(clientUser.username, {
      clientUserId: clientUser.id,
      ownerUserId: clientUser.ownerUserId,
    });

    if (req.method === "GET") {
      sendJson(res, 200, {
        syncSettings: normalizeAgentSyncSettings(agent.syncSettings),
      });
      return;
    }

    const body = await parseJsonBody(req);
    const syncSettings = normalizeAgentSyncSettings(body);
    agent.syncSettings = syncSettings;
    agent.syncSettingsUpdatedAt = nowIso();

    agent.tables = Object.fromEntries(
      Object.entries(agent.tables || {}).map(([table, tableState]) => {
        const normalizedTableState = normalizeTableState({
          ...tableState,
          table,
        });
        return [
          table,
          {
            ...normalizedTableState,
            direction: "sync",
          },
        ];
      }),
    );

    await queueSave();
    sendJson(res, 200, { ok: true, syncSettings });
    return;
  }

  if (req.method === "GET" && pathname.startsWith("/api/agents/") && pathname.endsWith("/jobs")) {
    const context = requireAuth(req, res);
    if (!context) {
      return;
    }
    const clientIdentity = decodeURIComponent(
      pathname.replace("/api/agents/", "").replace("/jobs", ""),
    );
    const clientUser = findClientUserByName(clientIdentity);
    const clientName = clientUser?.username || normalizeUsername(clientIdentity);
    if (
      (context.user.role !== ROLE_CLIENT || context.user.id !== clientUser?.id) &&
      !canAccessClientUser(context.user, clientUser)
    ) {
      sendJson(res, 403, { error: "permission denied" });
      return;
    }
    sendJson(res, 200, { jobs: activeJobsForClient(clientName) });
    return;
  }

  if (req.method === "POST" && pathname === "/api/jobs") {
    const context = requireAuth(req, res);
    if (!context) {
      return;
    }
    const body = await parseJsonBody(req);
    const direction = "sync";
    const syncMode = normalizeSyncMode(body.syncMode);
    const sourceClientName = String(body.sourceClientName || "").trim();
    const database = String(body.database || "").trim();
    const tables = Array.isArray(body.tables)
      ? body.tables
        .map((item) => qualifyTableWithDatabase(item, database))
        .filter(Boolean)
      : [];

    if (tables.length == 0) {
      sendJson(res, 400, { error: "tables are required." });
      return;
    }

    let clientUser = null;
    let clientName = "";
    if (context.user.role === ROLE_CLIENT) {
      clientUser = context.user;
      clientName = context.user.username;
    } else {
      clientUser = findClientUserByName(body.clientName);
      if (!clientUser || !canAccessClientUser(context.user, clientUser)) {
        sendJson(res, 403, { error: "permission denied for that client account" });
        return;
      }
      clientName = clientUser.username;
    }

    const jobs = tables.flatMap((table) => {
      const resolvedSourceClientName =
        sourceClientName || clientName;

      const existingJob = state.jobs.find(
        (job) =>
          job.clientName === clientName &&
          job.table === table &&
          job.direction === direction &&
          job.sourceClientName === resolvedSourceClientName &&
          isJobActive(job),
      );
      if (existingJob) {
        return [existingJob];
      }

      return [createJob({
        clientName,
        clientUserId: clientUser.id,
        ownerUserId: clientUser.ownerUserId || null,
        sourceClientName: resolvedSourceClientName,
        table,
        direction,
        syncMode,
        message: `Queued SymmetricDS sync for ${table}.`,
      })];
    });
    await queueSave();
    sendJson(res, 201, { jobs: jobs.map(publicJobPayload) });
    return;
  }

  if (pathname.startsWith("/api/jobs/")) {
    const context = requireAuth(req, res);
    if (!context) {
      return;
    }
    const parts = pathname.split("/").filter(Boolean);
    const jobId = parts[2];
    const action = parts[3];
    const job = findJob(jobId);

    if (!job) {
      sendJson(res, 404, { error: "job not found" });
      return;
    }

    if (
      !viewerCanAccessRecord(
        context.user,
        job.ownerUserId || null,
        job.clientUserId || null,
      )
    ) {
      sendJson(res, 403, { error: "permission denied" });
      return;
    }

    if (
      context.user.role === ROLE_CLIENT &&
      (job.clientUserId || null) !== context.user.id
    ) {
      sendJson(res, 403, { error: "permission denied" });
      return;
    }

    if (
      [
        "start",
        "progress",
        "complete",
        "fail",
      ].includes(action) &&
      context.user.role !== ROLE_CLIENT
    ) {
      sendJson(res, 403, { error: "client session required" });
      return;
    }

    if (req.method === "POST" && action === "start") {
      const body = await parseJsonBody(req);
      updateJob(job, {
        status: String(body.status || "running"),
        startedAt: job.startedAt || nowIso(),
        progress: Number(body.progress || 5),
        message: String(body.message || "Started SymmetricDS sync."),
      });
      await queueSave();
      sendJson(res, 200, { job: publicJobPayload(job) });
      return;
    }

    if (req.method === "POST" && action === "progress") {
      const body = await parseJsonBody(req);
      updateJob(job, {
        status: String(body.status || job.status),
        progress:
          body.progress !== undefined ? Number(body.progress) : Number(job.progress),
        message: body.message !== undefined ? String(body.message) : job.message,
        rowCount:
          body.rowCount !== undefined ? Number(body.rowCount) : Number(job.rowCount),
        direction: "sync",
      });
      await queueSave();
      sendJson(res, 200, { job: publicJobPayload(job) });
      return;
    }

    if (req.method === "POST" && action === "complete") {
      const body = await parseJsonBody(req);
      updateJob(job, {
        status: String(body.status || "completed"),
        progress: Number(body.progress || 100),
        completedAt: nowIso(),
        message: String(body.message || "Completed SymmetricDS sync."),
        rowCount:
          body.rowCount !== undefined ? Number(body.rowCount) : Number(job.rowCount),
      });
      await queueSave();
      sendJson(res, 200, { job: publicJobPayload(job) });
      return;
    }

    if (req.method === "POST" && action === "fail") {
      const body = await parseJsonBody(req);
      updateJob(job, {
        status: "failed",
        progress: Number(body.progress || job.progress || 100),
        completedAt: nowIso(),
        error: String(body.message || "Sync failed."),
        message: String(body.message || "Sync failed."),
      });
      await queueSave();
      sendJson(res, 200, { job: publicJobPayload(job) });
      return;
    }
  }

  if (req.method === "GET") {
    const servedUpdate = await tryServeClientUpdate(pathname, res);
    if (servedUpdate) {
      return;
    }

    const served = await tryServeStatic(pathname, res);
    if (served) {
      return;
    }
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

async function main() {
  await loadState();
  server.listen(PORT, "0.0.0.0", () => {
    console.log(`sync backend listening on ${PORT}`);
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
