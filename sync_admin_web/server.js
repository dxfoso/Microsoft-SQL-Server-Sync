const crypto = require("node:crypto");
const fs = require("node:fs/promises");
const http = require("node:http");
const path = require("node:path");
const { promisify } = require("node:util");
const zlib = require("node:zlib");

const PORT = Number(process.env.PORT || "9001");
const STATE_FILE =
  process.env.STATE_FILE ||
  path.join(process.cwd(), "data", "state.json");
const UPLOADS_DIR =
  process.env.UPLOADS_DIR ||
  path.join(path.dirname(STATE_FILE), "upload-chunks");
const PUBLIC_DIR = process.env.PUBLIC_DIR || path.join(process.cwd(), "public");
const MAX_BODY_SIZE = 100 * 1024 * 1024;
const SNAPSHOT_TRANSFER_CHUNK_SIZE = 100 * 1024;
const SNAPSHOT_TRANSFER_ENCODING = "gzip";
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
const MIME_TYPES = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".ico": "image/x-icon",
  ".js": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".map": "application/json; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".txt": "text/plain; charset=utf-8",
  ".wasm": "application/wasm",
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
    snapshots: {},
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

function normalizeSyncMode(value, fallbackIsMaster = true) {
  const normalized = String(value || "").trim();
  if (normalized === "master" || normalized === "upload") {
    return "master";
  }
  if (normalized === "client" || normalized === "download") {
    return "client";
  }
  if (normalized === "masterMix" || normalized === "mix") {
    return "masterMix";
  }
  return fallbackIsMaster ? "master" : "client";
}

function directionForSyncMode(syncMode) {
  return normalizeSyncMode(syncMode) === "client" ? "download" : "upload";
}

function normalizeAgentSyncSettings(raw, fallbackIsMaster = true) {
  const source = raw && typeof raw === "object" ? raw : {};
  return {
    isMaster:
      source.isMaster === undefined
        ? fallbackIsMaster !== false
        : Boolean(source.isMaster),
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
    snapshots: {},
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
            isMaster: agent?.isMaster,
            historyLimit: agent?.historyLimit,
            autoSyncIntervalMinutes: agent?.autoSyncIntervalMinutes,
          };
    const syncSettings = normalizeAgentSyncSettings(
      rawSyncSettings,
      agent?.isMaster !== false,
    );
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
      isMaster: syncSettings.isMaster,
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

  for (const [legacyKey, snapshot] of Object.entries(parsed?.snapshots || {})) {
    const legacySnapshotKeyParts = String(legacyKey).split("::");
    const legacyClientName = legacySnapshotKeyParts.shift() || "";
    const legacyTable = legacySnapshotKeyParts.join("::");
    const rawClientIdentity = String(snapshot?.clientName || legacyClientName || "");
    const clientUser = findNormalizedClientUser(
      rawClientIdentity,
      snapshot?.clientUserId,
    );
    const normalizedSnapshot = normalizeSnapshot({
      ...snapshot,
      clientName: normalizeClientIdentity(
        rawClientIdentity,
        snapshot?.clientUserId,
      ),
      clientUserId:
        clientUser?.id ||
        (snapshot?.clientUserId ? String(snapshot.clientUserId) : null),
      ownerUserId:
        clientUser?.ownerUserId ||
        (snapshot?.ownerUserId ? String(snapshot.ownerUserId) : null),
      table: normalizeTableKey(snapshot?.table || legacyTable),
    });
    if (!normalizedSnapshot.clientName || !normalizedSnapshot.table) {
      continue;
    }
    normalized.snapshots[
      snapshotKey(normalizedSnapshot.clientName, normalizedSnapshot.table)
    ] = normalizedSnapshot;
  }

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

function snapshotKey(clientName, table) {
  return `${clientName}::${table}`;
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

function safePathToken(value) {
  return String(value || "")
    .trim()
    .replace(/[^a-zA-Z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "") || "item";
}

function chunkStorageDir(job, session) {
  const jobToken = safePathToken(job?.id || "job");
  const uploadToken = safePathToken(session?.id || "upload");
  return path.join(UPLOADS_DIR, jobToken, uploadToken);
}

function chunkStoragePath(job, session, chunkIndex) {
  return path.join(
    chunkStorageDir(job, session),
    `${String(Number(chunkIndex)).padStart(8, "0")}.bin`,
  );
}

async function ensureChunkStorageDir(job, session) {
  await fs.mkdir(chunkStorageDir(job, session), { recursive: true });
}

async function clearUploadSessionFiles(job, session) {
  if (!session) {
    return;
  }
  try {
    await fs.rm(chunkStorageDir(job, session), { recursive: true, force: true });
  } catch {
    // Best-effort cleanup only.
  }
}

function sortJobsDescending(items) {
  return items.sort((left, right) =>
    String(right.updatedAt || right.createdAt || "").localeCompare(
      String(left.updatedAt || left.createdAt || ""),
    ),
  );
}

function publicJobPayload(job) {
  const { uploadSession, downloadSession, ...payload } = job;
  return payload;
}

function normalizeTableState(tableState) {
  const direction = String(tableState.direction || "upload");
  const syncMode = normalizeSyncMode(
    tableState.syncMode,
    direction !== "download",
  );
  return {
    table: normalizeTableKey(tableState.table),
    enabled: Boolean(tableState.enabled),
    status: String(tableState.status || "Idle"),
    lastSync: String(tableState.lastSync || ""),
    progress: Number(tableState.progress || 0),
    direction,
    syncMode,
    rowCount: Number(tableState.rowCount || 0),
    snapshotId: tableState.snapshotId ? String(tableState.snapshotId) : null,
    snapshotCreatedAt: tableState.snapshotCreatedAt
      ? String(tableState.snapshotCreatedAt)
      : null,
    snapshotBytes: Number(tableState.snapshotBytes || 0),
    message: String(tableState.message || ""),
    mergedSnapshotSources:
      tableState.mergedSnapshotSources &&
      typeof tableState.mergedSnapshotSources === "object"
        ? Object.fromEntries(
            Object.entries(tableState.mergedSnapshotSources).map(([key, value]) => [
              String(key),
              String(value || ""),
            ]),
          )
        : {},
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
    const syncSettings = normalizeAgentSyncSettings(
      metadata.syncSettings,
      metadata.isMaster !== false,
    );
    state.agents[clientName] = {
      clientName,
      clientUserId: metadata.clientUserId || null,
      ownerUserId: metadata.ownerUserId || null,
      machineName: clientName,
      server: "",
      database: "",
      isOnline: false,
      isMaster: syncSettings.isMaster,
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
      state.agents[clientName].isMaster !== false,
    );
    state.agents[clientName].syncSettingsUpdatedAt = null;
  }
  state.agents[clientName].isMaster =
    state.agents[clientName].syncSettings.isMaster;
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
  const mergedSnapshotSources = {
    ...(currentTable.mergedSnapshotSources || {}),
  };
  const snapshotCreatedAt =
    patch.snapshotCreatedAt !== undefined
      ? String(patch.snapshotCreatedAt || "")
      : String(job.snapshotCreatedAt || "");
  if (
    job.direction === "download" &&
    job.sourceClientName &&
    snapshotCreatedAt
  ) {
    mergedSnapshotSources[String(job.sourceClientName)] = snapshotCreatedAt;
  }
  agent.tables[job.table] = {
    ...currentTable,
    ...patch,
    table: job.table,
    mergedSnapshotSources,
  };
}

function buildLiveState(viewer) {
  const generatedAt = nowIso();
  const agents = Object.values(state.agents)
    .filter((agent) =>
      viewerCanAccessRecord(viewer, agent.ownerUserId || null, agent.clientUserId || null),
    )
    .map((agent) => {
      const syncSettings = normalizeAgentSyncSettings(
        agent.syncSettings,
        agent.isMaster !== false,
      );
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
        isMaster: syncSettings.isMaster,
        historyLimit: syncSettings.historyLimit,
        autoSyncIntervalMinutes: syncSettings.autoSyncIntervalMinutes,
        serverConnected: Boolean(agent.serverConnected),
        sqlConnected: Boolean(agent.sqlConnected),
        lastHeartbeat: agent.lastHeartbeat,
        selectedTable: agent.selectedTable,
        tables: Object.values(agent.tables || {})
          .map((tableState) => {
            const normalizedTableState = normalizeTableState(tableState);
            const snapshot = latestSnapshot(
              agent.clientName,
              normalizedTableState.table,
            );
            if (!snapshot) {
              return normalizedTableState;
            }
            return {
              ...normalizedTableState,
              snapshotBytes: finalizeSnapshot(snapshot).snapshotBytes,
            };
          })
          .sort((left, right) => left.table.localeCompare(right.table)),
      };
    })
    .sort((left, right) => left.clientName.localeCompare(right.clientName));

  const visibleJobs = sortJobsDescending(
    state.jobs.filter((job) =>
      viewerCanAccessRecord(viewer, job.ownerUserId || null, job.clientUserId || null),
    ),
  ).slice(0, 100).map(publicJobPayload);
  const snapshots = Object.values(state.snapshots)
    .filter((snapshot) =>
      viewerCanAccessRecord(
        viewer,
        snapshot.ownerUserId || null,
        snapshot.clientUserId || null,
      ),
    )
    .map((snapshot) => {
      const normalized = finalizeSnapshot(snapshot);
      return {
        id: normalized.id,
        clientName: normalized.clientName,
        table: normalized.table,
        rowCount: normalized.rowCount,
        checksum: normalized.checksum,
        createdAt: normalized.createdAt,
        snapshotBytes: normalized.snapshotBytes,
        columns: normalized.columns,
        previewRows: buildSnapshotPreviewRows(normalized),
        sourceJobId: normalized.sourceJobId || null,
      };
    })
    .sort((left, right) => right.createdAt.localeCompare(left.createdAt));

  return { generatedAt, agents, jobs: visibleJobs, snapshots };
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
    direction: String(payload.direction || "upload"),
    syncMode: normalizeSyncMode(payload.syncMode, payload.direction !== "download"),
    status: "queued",
    progress: 0,
    rowCount: 0,
    createdAt: nowIso(),
    updatedAt: nowIso(),
    startedAt: null,
    completedAt: null,
    snapshotId: null,
    snapshotCreatedAt: null,
    snapshotBytes: 0,
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
    snapshotId:
      patch.snapshotId !== undefined ? patch.snapshotId : job.snapshotId,
    snapshotCreatedAt:
      patch.snapshotCreatedAt !== undefined
        ? patch.snapshotCreatedAt
        : job.snapshotCreatedAt,
    snapshotBytes:
      patch.snapshotBytes !== undefined
        ? Number(patch.snapshotBytes || 0)
        : Number(job.snapshotBytes || 0),
    message: patch.message !== undefined ? String(patch.message) : job.message,
  });
}

function latestSnapshot(clientName, table) {
  return state.snapshots[snapshotKey(clientName, table)] || null;
}

function agentTableState(clientName, table) {
  const agent = state.agents[clientName];
  if (!agent || !agent.tables) {
    return null;
  }
  return agent.tables[table] ? normalizeTableState(agent.tables[table]) : null;
}

function latestMasterSnapshotForTable(ownerUserId, table) {
  return masterSnapshotsForTable(ownerUserId, table)[0] || null;
}

function masterSnapshotsForTable(ownerUserId, table) {
  return Object.values(state.snapshots)
    .map((snapshot) => finalizeSnapshot(snapshot))
    .filter((snapshot) => {
      if (snapshot.table !== table) {
        return false;
      }
      if ((snapshot.ownerUserId || null) !== (ownerUserId || null)) {
        return false;
      }
      const tableState = agentTableState(snapshot.clientName, table);
      return tableState
        ? normalizeSyncMode(tableState.syncMode, true) !== "client"
        : false;
    })
    .sort((left, right) => right.createdAt.localeCompare(left.createdAt));
}

function resolveDownloadSource(
  clientName,
  requestedSourceClientName,
  table,
  ownerUserId,
) {
  const explicitSource = String(requestedSourceClientName || "").trim();
  if (explicitSource) {
    const explicitSourceUser = findClientUserByName(explicitSource);
    const explicitSourceClientName = explicitSourceUser
      ? explicitSourceUser.username
      : explicitSource;
    const snapshot = latestSnapshot(explicitSourceClientName, table);
    if (!snapshot || (snapshot.ownerUserId || null) !== (ownerUserId || null)) {
      return null;
    }
    return finalizeSnapshot(snapshot);
  }

  const masterSnapshot = latestMasterSnapshotForTable(ownerUserId, table);
  if (!masterSnapshot) {
    return null;
  }

  if (masterSnapshot.clientName === clientName) {
    return masterSnapshot;
  }

  return masterSnapshot;
}

function shouldQueueDownloadJob(clientName, table, sourceSnapshot) {
  if (!sourceSnapshot) {
    return false;
  }

  const targetTableState = agentTableState(clientName, table);
  const sourceClientName = String(sourceSnapshot.clientName || "").trim();
  const mergedSources = targetTableState?.mergedSnapshotSources || {};
  if (sourceClientName && mergedSources[sourceClientName]) {
    const mergedTimestamp = Date.parse(mergedSources[sourceClientName]);
    const sourceTimestamp = Date.parse(sourceSnapshot.createdAt);
    if (
      Number.isFinite(mergedTimestamp) &&
      Number.isFinite(sourceTimestamp)
    ) {
      return sourceTimestamp > mergedTimestamp;
    }
    return String(mergedSources[sourceClientName]) !== sourceSnapshot.createdAt;
  }
  const targetCreatedAt = String(targetTableState?.snapshotCreatedAt || "").trim();
  if (!targetCreatedAt) {
    return true;
  }

  const targetTimestamp = Date.parse(targetCreatedAt);
  const sourceTimestamp = Date.parse(sourceSnapshot.createdAt);
  if (!Number.isFinite(targetTimestamp) || !Number.isFinite(sourceTimestamp)) {
    return targetCreatedAt !== sourceSnapshot.createdAt;
  }

  return sourceTimestamp > targetTimestamp;
}

function normalizeSnapshotRow(row, columns) {
  if (Array.isArray(row)) {
    return Object.fromEntries(
      columns.map((column, index) => [column, row[index] ?? null]),
    );
  }

  if (row && typeof row === "object") {
    return Object.fromEntries(
      columns.map((column) => [
        column,
        Object.prototype.hasOwnProperty.call(row, column) ? row[column] : null,
      ]),
    );
  }

  return Object.fromEntries(columns.map((column) => [column, null]));
}

function normalizeSnapshot(snapshot) {
  const columns = Array.isArray(snapshot.columns)
    ? snapshot.columns.map((column) => String(column))
    : [];
  const rows = Array.isArray(snapshot.rows)
    ? snapshot.rows.map((row) => normalizeSnapshotRow(row, columns))
    : [];
  const rowCount =
    snapshot.rowCount !== undefined ? Number(snapshot.rowCount) : rows.length;

  return {
    id: snapshot.id ? String(snapshot.id) : crypto.randomUUID(),
    clientName: String(snapshot.clientName || "").trim(),
    clientUserId: snapshot.clientUserId ? String(snapshot.clientUserId) : null,
    ownerUserId: snapshot.ownerUserId ? String(snapshot.ownerUserId) : null,
    table: normalizeTableKey(snapshot.table),
    createdAt: String(snapshot.createdAt || nowIso()),
    rowCount,
    checksum:
      snapshot.checksum ||
      crypto.createHash("sha256").update(JSON.stringify(rows)).digest("hex"),
    columns,
    rows,
    sourceJobId: snapshot.sourceJobId ? String(snapshot.sourceJobId) : null,
    snapshotBytes: Number(snapshot.snapshotBytes || 0),
  };
}

function createSnapshotFilePayload(snapshot) {
  return {
    formatVersion: 1,
    id: snapshot.id,
    clientName: snapshot.clientName,
    clientUserId: snapshot.clientUserId || null,
    ownerUserId: snapshot.ownerUserId || null,
    table: snapshot.table,
    createdAt: snapshot.createdAt,
    rowCount: snapshot.rowCount,
    checksum: snapshot.checksum,
    snapshotBytes: Number(snapshot.snapshotBytes || 0),
    columns: snapshot.columns,
    rows: snapshot.rows,
    sourceJobId: snapshot.sourceJobId || null,
  };
}

function serializeSnapshotFile(snapshot) {
  let snapshotBytes = Number(snapshot.snapshotBytes || 0);
  let payload = createSnapshotFilePayload(snapshot);

  for (let index = 0; index < 3; index += 1) {
    payload = {
      ...payload,
      snapshotBytes,
    };
    const nextBytes = Buffer.byteLength(JSON.stringify(payload));
    if (nextBytes === snapshotBytes) {
      break;
    }
    snapshotBytes = nextBytes;
  }

  payload = {
    ...payload,
    snapshotBytes,
  };

  return {
    payload,
    buffer: Buffer.from(JSON.stringify(payload)),
    snapshotBytes,
  };
}

function finalizeSnapshot(snapshot) {
  const normalized = normalizeSnapshot(snapshot);
  const serialized = serializeSnapshotFile(normalized);
  return {
    ...normalized,
    snapshotBytes: serialized.snapshotBytes,
  };
}

function serializeSnapshot(snapshot) {
  const normalized = finalizeSnapshot(snapshot);
  return {
    ...normalized,
    rows: normalized.rows,
  };
}

function serializeSnapshotSummary(snapshot) {
  const normalized = finalizeSnapshot(snapshot);
  const { rows, ...summary } = normalized;
  return summary;
}

function transferChunkCount(byteLength) {
  return Math.max(1, Math.ceil(byteLength / SNAPSHOT_TRANSFER_CHUNK_SIZE));
}

function receivedUploadIndexes(session) {
  return Object.keys(session?.chunks || {})
    .map((item) => Number(item))
    .filter((item) => Number.isInteger(item) && item >= 0)
    .sort((left, right) => left - right);
}

function receivedUploadBytes(session) {
  return Object.values(session?.chunks || {}).reduce(
    (total, chunk) => total + Number(chunk?.bytes || 0),
    0,
  );
}

function uploadSessionStatus(session) {
  return {
    uploadId: session.id,
    chunkSizeBytes: session.chunkSizeBytes,
    chunkCount: session.chunkCount,
    compressedBytes: session.compressedBytes,
    receivedBytes: receivedUploadBytes(session),
    receivedIndexes: receivedUploadIndexes(session),
  };
}

function createSnapshotTransfer(snapshot) {
  const normalized = finalizeSnapshot(snapshot);
  const serialized = serializeSnapshotFile(normalized);
  const compressedBuffer = zlib.gzipSync(serialized.buffer);
  return {
    snapshot: {
      ...normalized,
      snapshotBytes: serialized.snapshotBytes,
    },
    payloadBytes: serialized.buffer.length,
    compressedBuffer,
    compressedBytes: compressedBuffer.length,
    chunkSizeBytes: SNAPSHOT_TRANSFER_CHUNK_SIZE,
    chunkCount: transferChunkCount(compressedBuffer.length),
    encoding: SNAPSHOT_TRANSFER_ENCODING,
  };
}

async function snapshotFromUploadSession(job) {
  const session = job.uploadSession;
  if (!session) {
    throw new Error("upload session not found");
  }

  const buffers = [];
  for (let index = 0; index < session.chunkCount; index += 1) {
    const chunk = session.chunks?.[String(index)] || null;
    const chunkPath = chunkStoragePath(job, session, index);
    let buffer = null;
    try {
      buffer = await fs.readFile(chunkPath);
    } catch {
      buffer = null;
    }

    if (!buffer && chunk?.data) {
      buffer = Buffer.from(chunk.data, "base64");
    }
    if (!buffer) {
      throw new Error(`missing upload chunk ${index}`);
    }
    buffers.push(buffer);
  }

  const compressedBuffer = Buffer.concat(buffers);
  if (
    Number(session.compressedBytes || 0) > 0 &&
    compressedBuffer.length !== Number(session.compressedBytes)
  ) {
    throw new Error("uploaded snapshot byte count does not match manifest");
  }

  const payloadBuffer = zlib.gunzipSync(compressedBuffer);
  const payload = JSON.parse(payloadBuffer.toString("utf8"));
  const columns = Array.isArray(payload.columns)
    ? payload.columns.map((column) => String(column))
    : [];
  const rows = Array.isArray(payload.rows)
    ? payload.rows.map((row) => normalizeSnapshotRow(row, columns))
    : [];

  return finalizeSnapshot({
    id: payload.id || crypto.randomUUID(),
    clientName: job.clientName,
    clientUserId: job.clientUserId || null,
    ownerUserId: job.ownerUserId || null,
    table: normalizeTableKey(payload.table || session.table || job.table),
    createdAt: String(
      payload.createdAt || payload.snapshotCreatedAt || session.snapshotCreatedAt || nowIso(),
    ),
    rowCount: Number(payload.rowCount || rows.length),
    checksum: payload.checksum,
    columns,
    rows,
    sourceJobId: job.id,
  });
}

function downloadSessionForJob(job, snapshot) {
  const transfer = createSnapshotTransfer(snapshot);
  if (
    job.downloadSession?.snapshotId === transfer.snapshot.id &&
    job.downloadSession?.snapshotDataBase64
  ) {
    return job.downloadSession;
  }

  const session = {
    id: crypto.randomUUID(),
    snapshotId: transfer.snapshot.id,
    snapshot: serializeSnapshotSummary(transfer.snapshot),
    encoding: transfer.encoding,
    chunkSizeBytes: transfer.chunkSizeBytes,
    chunkCount: transfer.chunkCount,
    compressedBytes: transfer.compressedBytes,
    payloadBytes: transfer.payloadBytes,
    snapshotDataBase64: transfer.compressedBuffer.toString("base64"),
    createdAt: nowIso(),
    updatedAt: nowIso(),
  };
  job.downloadSession = session;
  return session;
}

function downloadSessionManifest(session) {
  const { snapshotDataBase64, ...manifest } = session;
  return manifest;
}

function downloadSessionChunk(session, chunkIndex) {
  const index = Number(chunkIndex);
  if (!Number.isInteger(index) || index < 0 || index >= session.chunkCount) {
    throw new Error("chunk index is out of range");
  }

  const compressedBuffer = Buffer.from(session.snapshotDataBase64, "base64");
  const start = index * session.chunkSizeBytes;
  const end = Math.min(start + session.chunkSizeBytes, compressedBuffer.length);
  return compressedBuffer.subarray(start, end);
}

function buildSnapshotPreviewRows(snapshot) {
  if (!Array.isArray(snapshot.rows)) {
    return [];
  }

  return snapshot.rows.slice(0, 5).map((row) => {
    const normalized = normalizeSnapshotRow(row, snapshot.columns);
    return snapshot.columns.map((column) => {
      const value = normalized[column];
      return value === null || value === undefined ? "NULL" : String(value);
    });
  });
}

function snapshotFilename(snapshot) {
  const sanitize = (value) =>
    String(value || "snapshot")
      .replace(/[^a-z0-9._-]+/gi, "-")
      .replace(/^-+|-+$/g, "") || "snapshot";
  const createdAt = sanitize(String(snapshot.createdAt || nowIso()));
  return `${sanitize(snapshot.clientName)}-${sanitize(snapshot.table)}-${createdAt}.json`;
}

function isJobActive(job) {
  return (
    job.status === "queued" ||
    job.status === "snapshotting" ||
    job.status === "uploading" ||
    job.status === "downloading" ||
    job.status === "applying"
  );
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
    sendJson(res, 200, { ok: true, generatedAt: nowIso() });
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

    if (app === APP_WEB && user.role === ROLE_CLIENT) {
      sendJson(res, 403, {
        error: "client accounts can sign in only in the Windows app",
      });
      return;
    }

    if (app === APP_WINDOWS && user.role !== ROLE_CLIENT) {
      sendJson(res, 403, {
        error: "only client accounts can sign in in the Windows app",
      });
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
        isMaster: body.isMaster,
        historyLimit: body.historyLimit,
        autoSyncIntervalMinutes: body.autoSyncIntervalMinutes,
      },
      body.isMaster !== false,
    );

    const agent = ensureAgent(clientName, {
      clientUserId: context.user.id,
      ownerUserId: context.user.ownerUserId,
      syncSettings: incomingSyncSettings,
    });
    if (!agent.syncSettingsUpdatedAt) {
      agent.syncSettings = incomingSyncSettings;
    }
    agent.isMaster = agent.syncSettings.isMaster;
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
          agent.syncSettings.isMaster,
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
        syncSettings: normalizeAgentSyncSettings(
          agent.syncSettings,
          agent.isMaster !== false,
        ),
      });
      return;
    }

    const body = await parseJsonBody(req);
    const syncSettings = normalizeAgentSyncSettings(
      body,
      agent.syncSettings?.isMaster ?? agent.isMaster !== false,
    );
    agent.syncSettings = syncSettings;
    agent.syncSettingsUpdatedAt = nowIso();
    agent.isMaster = syncSettings.isMaster;

    const direction = syncSettings.isMaster ? "upload" : "download";
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
            direction,
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
    const direction = String(body.direction || "upload").trim().toLowerCase();
    const syncMode = normalizeSyncMode(
      body.syncMode,
      direction !== "download",
    );
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
      const downloadSources =
        direction === "download" && syncMode === "masterMix" && !sourceClientName
          ? masterSnapshotsForTable(clientUser.ownerUserId || null, table).filter(
              (snapshot) => snapshot.clientName !== clientName,
            )
          : [];
      if (downloadSources.length > 0) {
        return downloadSources.flatMap((sourceSnapshot) => {
          const existingJob = state.jobs.find(
            (job) =>
              job.clientName === clientName &&
              job.table === table &&
              job.direction === direction &&
              job.sourceClientName === sourceSnapshot.clientName &&
              isJobActive(job),
          );
          if (existingJob) {
            return [existingJob];
          }
          if (!shouldQueueDownloadJob(clientName, table, sourceSnapshot)) {
            return [];
          }
          return [
            createJob({
              clientName,
              clientUserId: clientUser.id,
              ownerUserId: clientUser.ownerUserId || null,
              sourceClientName: sourceSnapshot.clientName,
              sourceClientUserId: sourceSnapshot.clientUserId || null,
              table,
              direction,
              syncMode,
              message: `Queued master (merge) sync for ${table} from ${sourceSnapshot.clientName}.`,
            }),
          ];
        });
      }

      const existingJob = state.jobs.find(
        (job) =>
          job.clientName === clientName &&
          job.table === table &&
          job.direction === direction &&
          (!sourceClientName || job.sourceClientName === sourceClientName) &&
          isJobActive(job),
      );
      if (existingJob) {
        return [existingJob];
      }

      if (direction === "download") {
        const sourceSnapshot = resolveDownloadSource(
          clientName,
          sourceClientName,
          table,
          clientUser.ownerUserId || null,
        );
        if (!shouldQueueDownloadJob(clientName, table, sourceSnapshot)) {
          return [];
        }

        return [
          createJob({
            clientName,
            clientUserId: clientUser.id,
            ownerUserId: clientUser.ownerUserId || null,
            sourceClientName: sourceSnapshot.clientName,
            sourceClientUserId: sourceSnapshot.clientUserId || null,
            table,
            direction,
            syncMode,
            message: `Queued snapshot download for ${table} from ${sourceSnapshot.clientName}.`,
          }),
        ];
      }

      return [createJob({
        clientName,
        clientUserId: clientUser.id,
        ownerUserId: clientUser.ownerUserId || null,
        sourceClientName: sourceClientName || clientName,
        table,
        direction,
        syncMode,
        message:
          direction === "download"
            ? `Queued snapshot download for ${table}.`
            : `Queued snapshot upload for ${table}.`,
      })];
    });
    await queueSave();
    sendJson(res, 201, { jobs: jobs.map(publicJobPayload) });
    return;
  }

  if (req.method === "GET" && pathname === "/api/snapshots/latest") {
    const context = requireAuth(req, res);
    if (!context) {
      return;
    }
    const clientIdentity = String(url.searchParams.get("clientName") || "").trim();
    const table = String(url.searchParams.get("table") || "").trim();
    const clientUser = findClientUserByName(clientIdentity);
    if (!clientUser || !canAccessClientUser(context.user, clientUser)) {
      sendJson(res, 403, { error: "permission denied" });
      return;
    }
    const snapshot = latestSnapshot(clientUser.username, table);
    if (!snapshot) {
      sendJson(res, 404, { error: "snapshot not found" });
      return;
    }
    sendJson(res, 200, serializeSnapshot(snapshot));
    return;
  }

  if (req.method === "GET" && pathname === "/api/snapshots/latest/file") {
    const context = requireAuth(req, res);
    if (!context) {
      return;
    }
    const clientIdentity = String(url.searchParams.get("clientName") || "").trim();
    const table = String(url.searchParams.get("table") || "").trim();
    const clientUser = findClientUserByName(clientIdentity);
    if (!clientUser || !canAccessClientUser(context.user, clientUser)) {
      sendJson(res, 403, { error: "permission denied" });
      return;
    }
    const snapshot = latestSnapshot(clientUser.username, table);
    if (!snapshot) {
      sendJson(res, 404, { error: "snapshot not found" });
      return;
    }
    const normalized = finalizeSnapshot(snapshot);
    const serialized = serializeSnapshotFile(normalized);
    sendBuffer(
      res,
      200,
      serialized.buffer,
      "application/json; charset=utf-8",
      {
        "Content-Disposition": `attachment; filename="${snapshotFilename(
          normalized,
        )}"`,
      },
    );
    return;
  }

  if (req.method === "GET" && pathname.startsWith("/api/snapshots/")) {
    const context = requireAuth(req, res);
    if (!context) {
      return;
    }
    const snapshotId = decodeURIComponent(pathname.replace("/api/snapshots/", ""));
    const snapshot = Object.values(state.snapshots)
      .map((entry) => finalizeSnapshot(entry))
      .find((entry) => entry.id === snapshotId);
    if (!snapshot) {
      sendJson(res, 404, { error: "snapshot not found" });
      return;
    }
    if (
      !viewerCanAccessRecord(
        context.user,
        snapshot.ownerUserId || null,
        snapshot.clientUserId || null,
      )
    ) {
      sendJson(res, 403, { error: "permission denied" });
      return;
    }
    sendJson(res, 200, serializeSnapshot(snapshot));
    return;
  }

  if (req.method === "POST" && pathname === "/api/snapshots/import") {
    const context = requireAuth(req, res, {
      allowedRoles: [ROLE_ADMIN, ROLE_OWNER],
      app: APP_WEB,
    });
    if (!context) {
      return;
    }
    const body = await parseJsonBody(req);
    const clientUser = findClientUserByName(body.clientName);
    if (!clientUser || !canAccessClientUser(context.user, clientUser)) {
      sendJson(res, 403, { error: "permission denied for that client account" });
      return;
    }
    const rawSnapshot =
      body.snapshot && typeof body.snapshot === "object" ? body.snapshot : body;
    const importDatabase =
      body.database ||
      databaseFromTableKey(rawSnapshot.table) ||
      databaseFromTableKey(body.table) ||
      state.agents[clientUser.username]?.database ||
      "";
    const snapshot = finalizeSnapshot({
      ...rawSnapshot,
      clientName: clientUser.username,
      clientUserId: clientUser.id,
      ownerUserId: clientUser.ownerUserId || null,
      table: qualifyTableWithDatabase(
        body.table || rawSnapshot.table,
        importDatabase,
      ),
      createdAt:
        body.createdAt ||
        rawSnapshot.createdAt ||
        rawSnapshot.snapshotCreatedAt ||
        nowIso(),
    });

    if (!snapshot.clientName || !snapshot.table) {
      sendJson(res, 400, { error: "clientName and table are required." });
      return;
    }

    state.snapshots[snapshotKey(snapshot.clientName, snapshot.table)] = snapshot;

    const agent = state.agents[snapshot.clientName];
    if (agent) {
      const currentTable = normalizeTableState(
        agent.tables[snapshot.table] || { table: snapshot.table, enabled: true },
      );
      agent.tables[snapshot.table] = {
        ...currentTable,
        table: snapshot.table,
        status: currentTable.enabled ? "Completed" : currentTable.status,
        progress: currentTable.enabled ? 100 : currentTable.progress,
        lastSync: snapshot.createdAt,
        rowCount: snapshot.rowCount,
        snapshotId: snapshot.id,
        snapshotCreatedAt: snapshot.createdAt,
        snapshotBytes: snapshot.snapshotBytes,
        message: `Backup file imported with ${snapshot.rowCount} rows.`,
      };
    }

    await queueSave();
    sendJson(res, 200, { snapshot: serializeSnapshot(snapshot) });
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
        "upload",
        "upload-chunk-start",
        "upload-chunk",
        "upload-chunk-complete",
        "download-snapshot",
        "download-snapshot-manifest",
        "download-snapshot-chunk",
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
        status: String(body.status || "snapshotting"),
        startedAt: job.startedAt || nowIso(),
        progress: Number(body.progress || 5),
        message: String(body.message || "Started."),
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
        direction:
          body.direction !== undefined ? String(body.direction) : job.direction,
      });
      await queueSave();
      sendJson(res, 200, { job: publicJobPayload(job) });
      return;
    }

    if (req.method === "POST" && action === "upload-chunk-start") {
      const body = await parseJsonBody(req);
      const chunkCount = Number(body.chunkCount || 0);
      const chunkSizeBytes = Number(
        body.chunkSizeBytes || SNAPSHOT_TRANSFER_CHUNK_SIZE,
      );
      const compressedBytes = Number(body.compressedBytes || 0);

      if (
        !Number.isInteger(chunkCount) ||
        chunkCount < 1 ||
        !Number.isInteger(chunkSizeBytes) ||
        chunkSizeBytes < 1 ||
        chunkSizeBytes > SNAPSHOT_TRANSFER_CHUNK_SIZE ||
        !Number.isFinite(compressedBytes) ||
        compressedBytes < 1
      ) {
        sendJson(res, 400, { error: "invalid chunked upload manifest" });
        return;
      }

      const requestedUploadId = String(body.uploadId || "").trim();
    if (
        !job.uploadSession ||
        (requestedUploadId && job.uploadSession.id !== requestedUploadId) ||
        job.uploadSession.chunkCount !== chunkCount ||
        job.uploadSession.compressedBytes !== compressedBytes
      ) {
        await clearUploadSessionFiles(job, job.uploadSession || null);
        job.uploadSession = {
          id: requestedUploadId || crypto.randomUUID(),
          table: qualifyTableWithDatabase(
            body.table || job.table,
            databaseFromTableKey(job.table),
          ),
          snapshotCreatedAt: String(body.snapshotCreatedAt || body.createdAt || nowIso()),
          rowCount: Number(body.rowCount || 0),
          snapshotBytes: Number(body.snapshotBytes || 0),
          compressedBytes,
          chunkSizeBytes,
          chunkCount,
          encoding: SNAPSHOT_TRANSFER_ENCODING,
          chunks: {},
          createdAt: nowIso(),
          updatedAt: nowIso(),
        };
      }
      await ensureChunkStorageDir(job, job.uploadSession);

      updateJob(job, {
        status: "uploading",
        progress: 70,
        rowCount: Number(body.rowCount || job.rowCount || 0),
        message: `Ready to receive ${chunkCount} compressed snapshot chunks.`,
      });
      await queueSave();
      sendJson(res, 200, {
        job: publicJobPayload(job),
        ...uploadSessionStatus(job.uploadSession),
      });
      return;
    }

    if (req.method === "POST" && action === "upload-chunk") {
      const body = await parseJsonBody(req);
      const session = job.uploadSession;
      const uploadId = String(body.uploadId || "").trim();
      const chunkIndex = Number(body.chunkIndex);
      const chunkData = String(body.chunkData || "");

      if (!session || session.id !== uploadId) {
        sendJson(res, 404, { error: "upload session not found" });
        return;
      }
      if (
        !Number.isInteger(chunkIndex) ||
        chunkIndex < 0 ||
        chunkIndex >= session.chunkCount
      ) {
        sendJson(res, 400, { error: "chunk index is out of range" });
        return;
      }
      if (!chunkData) {
        sendJson(res, 400, { error: "chunkData is required" });
        return;
      }

      const buffer = Buffer.from(chunkData, "base64");
      if (buffer.length > session.chunkSizeBytes) {
        sendJson(res, 400, { error: "chunk is larger than the configured size" });
        return;
      }

      await ensureChunkStorageDir(job, session);
      await fs.writeFile(chunkStoragePath(job, session, chunkIndex), buffer);

      session.chunks[String(chunkIndex)] = {
        bytes: buffer.length,
        receivedAt: nowIso(),
      };
      session.updatedAt = nowIso();
      const receivedCount = receivedUploadIndexes(session).length;
      const progress = Math.min(
        95,
        Math.max(70, Math.round(70 + (receivedCount / session.chunkCount) * 25)),
      );
      updateJob(job, {
        status: "uploading",
        progress,
        rowCount: Number(session.rowCount || job.rowCount || 0),
        message: `Received snapshot chunk ${receivedCount}/${session.chunkCount}.`,
      });
      sendJson(res, 200, {
        job: publicJobPayload(job),
        ...uploadSessionStatus(session),
      });
      return;
    }

    if (req.method === "POST" && action === "upload-chunk-complete") {
      const body = await parseJsonBody(req);
      const session = job.uploadSession;
      const uploadId = String(body.uploadId || "").trim();

      if (!session || session.id !== uploadId) {
        sendJson(res, 404, { error: "upload session not found" });
        return;
      }
      if (receivedUploadIndexes(session).length !== session.chunkCount) {
        sendJson(res, 409, {
          error: "upload is missing chunks",
          ...uploadSessionStatus(session),
        });
        return;
      }

      const snapshot = await snapshotFromUploadSession(job);
      state.snapshots[snapshotKey(snapshot.clientName, snapshot.table)] = snapshot;
      await clearUploadSessionFiles(job, session);
      job.uploadSession = null;
      updateJob(job, {
        status: "completed",
        progress: 100,
        completedAt: nowIso(),
        snapshotId: snapshot.id,
        snapshotCreatedAt: snapshot.createdAt,
        snapshotBytes: snapshot.snapshotBytes,
        rowCount: snapshot.rowCount,
        message: `Snapshot uploaded with ${snapshot.rowCount} rows in compressed chunks.`,
      });
      await queueSave();
      sendJson(res, 200, {
        job: publicJobPayload(job),
        snapshot: serializeSnapshotSummary(snapshot),
      });
      return;
    }

    if (req.method === "POST" && action === "upload") {
      const body = await parseJsonBody(req);
      const columns = Array.isArray(body.columns)
        ? body.columns.map((column) => String(column))
        : [];
      const rows = Array.isArray(body.rows)
        ? body.rows.map((row) => normalizeSnapshotRow(row, columns))
        : [];
      const createdAt = String(body.snapshotCreatedAt || nowIso());
      const snapshot = finalizeSnapshot({
        id: crypto.randomUUID(),
        clientName: job.clientName,
        clientUserId: job.clientUserId || null,
        ownerUserId: job.ownerUserId || null,
        table: qualifyTableWithDatabase(
          body.table || job.table,
          databaseFromTableKey(job.table),
        ),
        createdAt,
        rowCount: Number(body.rowCount || rows.length),
        checksum: body.checksum,
        columns,
        rows,
        sourceJobId: job.id,
      });
      state.snapshots[snapshotKey(snapshot.clientName, snapshot.table)] = snapshot;
      updateJob(job, {
        status: "completed",
        progress: 100,
        completedAt: nowIso(),
        snapshotId: snapshot.id,
        snapshotCreatedAt: snapshot.createdAt,
        snapshotBytes: snapshot.snapshotBytes,
        rowCount: snapshot.rowCount,
        message: `Snapshot uploaded with ${snapshot.rowCount} rows.`,
      });
      await queueSave();
      sendJson(res, 200, {
        job: publicJobPayload(job),
        snapshot: serializeSnapshot(snapshot),
      });
      return;
    }

    if (req.method === "GET" && action === "download-snapshot") {
      const snapshot = latestSnapshot(job.sourceClientName || job.clientName, job.table);
      if (!snapshot) {
        sendJson(res, 404, { error: "snapshot not found for job" });
        return;
      }
      sendJson(res, 200, {
        job: publicJobPayload(job),
        snapshot: serializeSnapshot(snapshot),
      });
      return;
    }

    if (req.method === "GET" && action === "download-snapshot-manifest") {
      const snapshot = latestSnapshot(job.sourceClientName || job.clientName, job.table);
      if (!snapshot) {
        sendJson(res, 404, { error: "snapshot not found for job" });
        return;
      }
      const session = downloadSessionForJob(job, snapshot);
      updateJob(job, {
        status: "downloading",
        progress: Math.max(Number(job.progress || 0), 40),
        rowCount: Number(session.snapshot?.rowCount || job.rowCount || 0),
        message: `Prepared ${session.chunkCount} compressed snapshot chunks for download.`,
      });
      await queueSave();
      sendJson(res, 200, {
        job: publicJobPayload(job),
        manifest: downloadSessionManifest(session),
      });
      return;
    }

    if (req.method === "GET" && action === "download-snapshot-chunk") {
      const session = job.downloadSession;
      if (!session?.snapshotDataBase64) {
        sendJson(res, 404, { error: "download session not found" });
        return;
      }

      try {
        const chunkIndex = Number(url.searchParams.get("index"));
        const chunk = downloadSessionChunk(session, chunkIndex);
        const progress = Math.min(
          74,
          Math.max(
            40,
            Math.round(40 + ((chunkIndex + 1) / session.chunkCount) * 34),
          ),
        );
        updateJob(job, {
          status: "downloading",
          progress,
          rowCount: Number(session.snapshot?.rowCount || job.rowCount || 0),
          message: `Served snapshot chunk ${chunkIndex + 1}/${session.chunkCount}.`,
        });
        await queueSave();
        sendJson(res, 200, {
          transferId: session.id,
          chunkIndex,
          chunkCount: session.chunkCount,
          chunkData: chunk.toString("base64"),
        });
      } catch (error) {
        sendJson(res, 400, {
          error: error instanceof Error ? error.message : "invalid chunk request",
        });
      }
      return;
    }

    if (req.method === "POST" && action === "complete") {
      const body = await parseJsonBody(req);
      job.downloadSession = null;
      updateJob(job, {
        status: String(body.status || "completed"),
        progress: Number(body.progress || 100),
        completedAt: nowIso(),
        message: String(body.message || "Completed."),
        rowCount:
          body.rowCount !== undefined ? Number(body.rowCount) : Number(job.rowCount),
        snapshotId:
          body.snapshotId !== undefined ? String(body.snapshotId) : job.snapshotId,
        snapshotCreatedAt:
          body.snapshotCreatedAt !== undefined
            ? String(body.snapshotCreatedAt)
            : job.snapshotCreatedAt,
        snapshotBytes:
          body.snapshotBytes !== undefined
            ? Number(body.snapshotBytes || 0)
            : Number(job.snapshotBytes || 0),
      });
      await queueSave();
      sendJson(res, 200, { job: publicJobPayload(job) });
      return;
    }

    if (req.method === "POST" && action === "fail") {
      const body = await parseJsonBody(req);
      await clearUploadSessionFiles(job, job.uploadSession || null);
      job.uploadSession = null;
      job.downloadSession = null;
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
