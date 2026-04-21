const crypto = require("node:crypto");
const fs = require("node:fs/promises");
const http = require("node:http");
const path = require("node:path");

const PORT = Number(process.env.PORT || "9001");
const STATE_FILE =
  process.env.STATE_FILE ||
  path.join(process.cwd(), "data", "state.json");
const PUBLIC_DIR = process.env.PUBLIC_DIR || path.join(process.cwd(), "public");
const MAX_BODY_SIZE = 100 * 1024 * 1024;
const AGENT_ONLINE_WINDOW_MS = 60 * 1000;
const ADMIN_EMAIL = "dxfoso@gmail.com";
const ADMIN_PASSWORD = "Admin@123";
const ADMIN_NAME = "dxfoso";
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
  const email = normalizeEmail(user?.email);
  if (email) {
    return email.split("@")[0];
  }
  return "user";
}

function createStoredUser({
  email,
  password,
  role,
  name,
  ownerUserId = null,
  createdByUserId = null,
}) {
  const salt = crypto.randomUUID();
  const createdAt = nowIso();
  return {
    id: crypto.randomUUID(),
    email: normalizeEmail(email),
    name: String(name || "").trim() || normalizeEmail(email),
    role: normalizeRole(role),
    ownerUserId: ownerUserId ? String(ownerUserId) : null,
    createdByUserId: createdByUserId ? String(createdByUserId) : null,
    passwordSalt: salt,
    passwordHash: passwordHash(password, salt),
    createdAt,
    updatedAt: createdAt,
  };
}

function normalizeStoredUser(raw) {
  const normalizedEmail = normalizeEmail(raw?.email);
  return {
    id: String(raw?.id || crypto.randomUUID()),
    email: normalizedEmail,
    name: String(raw?.name || "").trim() || normalizedEmail,
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
    agents: parsed?.agents || {},
    jobs: Array.isArray(parsed?.jobs) ? parsed.jobs : [],
    snapshots: parsed?.snapshots || {},
  };

  for (const [id, user] of Object.entries(parsed?.users || {})) {
    const normalizedUser = normalizeStoredUser({ id, ...user });
    if (!normalizedUser.email || !normalizedUser.role) {
      continue;
    }
    normalized.users[normalizedUser.id] = normalizedUser;
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

function findUserByEmail(email) {
  const normalizedEmail = normalizeEmail(email);
  for (const user of Object.values(state.users || {})) {
    if (normalizeEmail(user.email) === normalizedEmail) {
      return user;
    }
  }
  return null;
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
    email: user.email,
    name: userDisplayName(user),
    role: user.role,
    ownerUserId: user.ownerUserId,
    ownerEmail: owner ? owner.email : null,
    ownerName: owner ? userDisplayName(owner) : null,
    createdByUserId: user.createdByUserId,
    createdAt: user.createdAt,
  };
}

function ensureSeedUsers() {
  let admin = findUserByEmail(ADMIN_EMAIL);
  if (!admin) {
    admin = createStoredUser({
      email: ADMIN_EMAIL,
      password: ADMIN_PASSWORD,
      role: ROLE_ADMIN,
      name: ADMIN_NAME,
    });
    state.users[admin.id] = admin;
    return true;
  }

  let changed = false;
  if (admin.role !== ROLE_ADMIN) {
    admin.role = ROLE_ADMIN;
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
  const normalized = normalizeEmail(clientName);
  for (const user of Object.values(state.users || {})) {
    if (user.role !== ROLE_CLIENT) {
      continue;
    }
    if (normalizeEmail(user.email) === normalized) {
      return user;
    }
  }
  return null;
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
    return userDisplayName(left).localeCompare(userDisplayName(right));
  });
}

function nowIso() {
  return new Date().toISOString();
}

function snapshotKey(clientName, table) {
  return `${clientName}::${table}`;
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

  const seeded = ensureSeedUsers();
  if (seeded) {
    await queueSave();
  }
}

function queueSave() {
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

function sortJobsDescending(items) {
  return items.sort((left, right) =>
    String(right.updatedAt || right.createdAt || "").localeCompare(
      String(left.updatedAt || left.createdAt || ""),
    ),
  );
}

function normalizeTableState(tableState) {
  return {
    table: String(tableState.table || ""),
    enabled: Boolean(tableState.enabled),
    status: String(tableState.status || "Idle"),
    lastSync: String(tableState.lastSync || ""),
    progress: Number(tableState.progress || 0),
    direction: String(tableState.direction || "upload"),
    rowCount: Number(tableState.rowCount || 0),
    snapshotId: tableState.snapshotId ? String(tableState.snapshotId) : null,
    snapshotCreatedAt: tableState.snapshotCreatedAt
      ? String(tableState.snapshotCreatedAt)
      : null,
    snapshotBytes: Number(tableState.snapshotBytes || 0),
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

function ensureAgent(clientName, metadata = {}) {
  if (!state.agents[clientName]) {
    state.agents[clientName] = {
      clientName,
      clientUserId: metadata.clientUserId || null,
      ownerUserId: metadata.ownerUserId || null,
      machineName: clientName,
      server: "",
      database: "",
      isOnline: false,
      isMaster: true,
      serverConnected: false,
      sqlConnected: false,
      lastHeartbeat: "",
      selectedTable: null,
      tables: {},
    };
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
        isMaster: agent.isMaster !== false,
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

  const jobs = sortJobsDescending([...state.jobs]).slice(0, 100);
  const visibleJobs = sortJobsDescending(
    state.jobs.filter((job) =>
      viewerCanAccessRecord(viewer, job.ownerUserId || null, job.clientUserId || null),
    ),
  ).slice(0, 100);
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
    table: String(payload.table || ""),
    direction: String(payload.direction || "upload"),
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
  return Object.values(state.snapshots)
    .map((snapshot) => finalizeSnapshot(snapshot))
    .filter((snapshot) => {
      if (snapshot.table !== table) {
        return false;
      }
      if ((snapshot.ownerUserId || null) !== (ownerUserId || null)) {
        return false;
      }
      const agent = state.agents[snapshot.clientName];
      return agent ? agent.isMaster !== false : false;
    })
    .sort((left, right) => right.createdAt.localeCompare(left.createdAt))[0] || null;
}

function resolveDownloadSource(
  clientName,
  requestedSourceClientName,
  table,
  ownerUserId,
) {
  const explicitSource = String(requestedSourceClientName || "").trim();
  if (explicitSource) {
    const snapshot = latestSnapshot(explicitSource, table);
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
    table: String(snapshot.table || "").trim(),
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
  );
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

  if (req.method === "GET" && (pathname === "/health" || pathname === "/api/health")) {
    sendJson(res, 200, { ok: true, generatedAt: nowIso() });
    return;
  }

  if (req.method === "POST" && pathname === "/api/auth/login") {
    const body = await parseJsonBody(req);
    const email = normalizeEmail(body.email);
    const password = String(body.password || "");
    const app = String(body.app || APP_WEB).trim().toLowerCase();
    const user = findUserByEmail(email);

    if (!user || passwordHash(password, user.passwordSalt) !== user.passwordHash) {
      sendJson(res, 401, { error: "invalid email or password" });
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
    const name = String(body.name || "").trim();

    if (!email || !password || !name || !role) {
      sendJson(res, 400, {
        error: "name, email, password, and role are required",
      });
      return;
    }

    if (findUserByEmail(email)) {
      sendJson(res, 409, { error: "an account with that email already exists" });
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

  if (req.method === "GET" && pathname === "/api/live-state") {
    const context = requireAuth(req, res, {
      allowedRoles: [ROLE_ADMIN, ROLE_OWNER],
      app: APP_WEB,
    });
    if (!context) {
      return;
    }
    sendJson(res, 200, buildLiveState(context.user));
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
    const clientName = context.user.email;

    const agent = ensureAgent(clientName, {
      clientUserId: context.user.id,
      ownerUserId: context.user.ownerUserId,
    });
    agent.clientName = clientName;
    agent.machineName = String(body.machineName || userDisplayName(context.user));
    agent.server = String(body.server || "");
    agent.database = String(body.database || "");
    agent.isMaster = body.isMaster !== undefined ? Boolean(body.isMaster) : true;
    agent.serverConnected = Boolean(body.serverConnected);
    agent.sqlConnected = Boolean(body.sqlConnected);
    agent.lastHeartbeat = nowIso();
    agent.selectedTable = body.selectedTable ? String(body.selectedTable) : null;
    if (Array.isArray(body.tables)) {
      const nextTables = {};
      for (const tableState of body.tables) {
        const normalizedTableState = normalizeTableState(tableState);
        if (!normalizedTableState.table) {
          continue;
        }
        nextTables[normalizedTableState.table] = mergeHeartbeatTableState(
          agent.tables[normalizedTableState.table],
          normalizedTableState,
        );
      }
      agent.tables = nextTables;
    }

    await queueSave();
    sendJson(res, 200, {
      ok: true,
      jobs: activeJobsForClient(clientName),
    });
    return;
  }

  if (req.method === "GET" && pathname.startsWith("/api/agents/") && pathname.endsWith("/jobs")) {
    const context = requireAuth(req, res);
    if (!context) {
      return;
    }
    const clientName = decodeURIComponent(
      pathname.replace("/api/agents/", "").replace("/jobs", ""),
    );
    if (
      context.user.role !== ROLE_ADMIN &&
      context.user.email !== clientName &&
      !canAccessClientUser(context.user, findClientUserByName(clientName))
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
    const sourceClientName = String(body.sourceClientName || "").trim();
    const tables = Array.isArray(body.tables)
      ? body.tables.map(String).map((item) => item.trim()).filter(Boolean)
      : [];

    if (tables.length == 0) {
      sendJson(res, 400, { error: "tables are required." });
      return;
    }

    let clientUser = null;
    let clientName = "";
    if (context.user.role === ROLE_CLIENT) {
      clientUser = context.user;
      clientName = context.user.email;
    } else {
      clientName = normalizeEmail(body.clientName);
      clientUser = findClientUserByName(clientName);
      if (!clientUser || !canAccessClientUser(context.user, clientUser)) {
        sendJson(res, 403, { error: "permission denied for that client account" });
        return;
      }
    }

    const jobs = tables.flatMap((table) => {
      const existingJob = state.jobs.find(
        (job) =>
          job.clientName === clientName &&
          job.table === table &&
          job.direction === direction &&
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
        message:
          direction === "download"
            ? `Queued snapshot download for ${table}.`
            : `Queued snapshot upload for ${table}.`,
      })];
    });
    await queueSave();
    sendJson(res, 201, { jobs });
    return;
  }

  if (req.method === "GET" && pathname === "/api/snapshots/latest") {
    const context = requireAuth(req, res);
    if (!context) {
      return;
    }
    const clientName = normalizeEmail(url.searchParams.get("clientName") || "");
    const table = String(url.searchParams.get("table") || "").trim();
    const clientUser = findClientUserByName(clientName);
    if (!clientUser || !canAccessClientUser(context.user, clientUser)) {
      sendJson(res, 403, { error: "permission denied" });
      return;
    }
    const snapshot = latestSnapshot(clientName, table);
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
    const clientName = normalizeEmail(url.searchParams.get("clientName") || "");
    const table = String(url.searchParams.get("table") || "").trim();
    const clientUser = findClientUserByName(clientName);
    if (!clientUser || !canAccessClientUser(context.user, clientUser)) {
      sendJson(res, 403, { error: "permission denied" });
      return;
    }
    const snapshot = latestSnapshot(clientName, table);
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
    const snapshot = finalizeSnapshot({
      ...rawSnapshot,
      clientName: clientUser.email,
      clientUserId: clientUser.id,
      ownerUserId: clientUser.ownerUserId || null,
      table: body.table || rawSnapshot.table,
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
      ["start", "progress", "upload", "download-snapshot", "complete", "fail"].includes(
        action,
      ) &&
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
      sendJson(res, 200, { job });
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
      sendJson(res, 200, { job });
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
        table: String(body.table || job.table),
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
      sendJson(res, 200, { job, snapshot: serializeSnapshot(snapshot) });
      return;
    }

    if (req.method === "GET" && action === "download-snapshot") {
      const snapshot = latestSnapshot(job.sourceClientName || job.clientName, job.table);
      if (!snapshot) {
        sendJson(res, 404, { error: "snapshot not found for job" });
        return;
      }
      sendJson(res, 200, { job, snapshot: serializeSnapshot(snapshot) });
      return;
    }

    if (req.method === "POST" && action === "complete") {
      const body = await parseJsonBody(req);
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
      sendJson(res, 200, { job });
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
      sendJson(res, 200, { job });
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
