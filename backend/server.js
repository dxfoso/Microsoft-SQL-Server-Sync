const crypto = require("node:crypto");
const fs = require("node:fs/promises");
const http = require("node:http");
const path = require("node:path");

const PORT = Number(process.env.PORT || "9001");
const STATE_FILE =
  process.env.STATE_FILE ||
  path.join(process.cwd(), "data", "state.json");
const MAX_BODY_SIZE = 100 * 1024 * 1024;
const AGENT_ONLINE_WINDOW_MS = 60 * 1000;

let state = createDefaultState();
let saveQueue = Promise.resolve();

function createDefaultState() {
  return {
    agents: {},
    jobs: [],
    snapshots: {},
  };
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
    state = {
      agents: parsed.agents || {},
      jobs: Array.isArray(parsed.jobs) ? parsed.jobs : [],
      snapshots: parsed.snapshots || {},
    };
  } catch {
    state = createDefaultState();
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
    message: String(tableState.message || ""),
  };
}

function ensureAgent(clientName) {
  if (!state.agents[clientName]) {
    state.agents[clientName] = {
      clientName,
      machineName: clientName,
      server: "",
      database: "",
      isOnline: false,
      serverConnected: false,
      sqlConnected: false,
      lastHeartbeat: "",
      selectedTable: null,
      tables: {},
    };
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

function buildLiveState() {
  const generatedAt = nowIso();
  const agents = Object.values(state.agents)
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
        serverConnected: Boolean(agent.serverConnected),
        sqlConnected: Boolean(agent.sqlConnected),
        lastHeartbeat: agent.lastHeartbeat,
        selectedTable: agent.selectedTable,
        tables: Object.values(agent.tables || {})
          .map(normalizeTableState)
          .sort((left, right) => left.table.localeCompare(right.table)),
      };
    })
    .sort((left, right) => left.clientName.localeCompare(right.clientName));

  const jobs = sortJobsDescending([...state.jobs]).slice(0, 100);
  const snapshots = Object.values(state.snapshots)
    .map((snapshot) => ({
      id: snapshot.id,
      clientName: snapshot.clientName,
      table: snapshot.table,
      rowCount: snapshot.rowCount,
      checksum: snapshot.checksum,
      createdAt: snapshot.createdAt,
      columns: snapshot.columns,
      previewRows: buildSnapshotPreviewRows(snapshot),
      sourceJobId: snapshot.sourceJobId || null,
    }))
    .sort((left, right) => right.createdAt.localeCompare(left.createdAt));

  return { generatedAt, agents, jobs, snapshots };
}

function createJob(payload) {
  const job = {
    id: crypto.randomUUID(),
    clientName: String(payload.clientName || ""),
    sourceClientName: String(
      payload.sourceClientName || payload.clientName || "",
    ),
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
    message: patch.message !== undefined ? String(patch.message) : job.message,
  });
}

function latestSnapshot(clientName, table) {
  return state.snapshots[snapshotKey(clientName, table)] || null;
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

function serializeSnapshot(snapshot) {
  return {
    ...snapshot,
    rows: Array.isArray(snapshot.rows)
      ? snapshot.rows.map((row) => normalizeSnapshotRow(row, snapshot.columns))
      : [],
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

  if (req.method === "GET" && pathname === "/api/live-state") {
    sendJson(res, 200, buildLiveState());
    return;
  }

  if (req.method === "POST" && pathname === "/api/agents/heartbeat") {
    const body = await parseJsonBody(req);
    const clientName = String(body.clientName || "").trim();
    if (!clientName) {
      sendJson(res, 400, { error: "clientName is required" });
      return;
    }

    const agent = ensureAgent(clientName);
    agent.clientName = clientName;
    agent.machineName = String(body.machineName || clientName);
    agent.server = String(body.server || "");
    agent.database = String(body.database || "");
    agent.serverConnected = Boolean(body.serverConnected);
    agent.sqlConnected = Boolean(body.sqlConnected);
    agent.lastHeartbeat = nowIso();
    agent.selectedTable = body.selectedTable ? String(body.selectedTable) : null;
    if (Array.isArray(body.tables)) {
      agent.tables = Object.fromEntries(
        body.tables
          .map(normalizeTableState)
          .filter((item) => item.table)
          .map((item) => [item.table, item]),
      );
    }

    await queueSave();
    sendJson(res, 200, {
      ok: true,
      jobs: activeJobsForClient(clientName),
    });
    return;
  }

  if (req.method === "GET" && pathname.startsWith("/api/agents/") && pathname.endsWith("/jobs")) {
    const clientName = decodeURIComponent(
      pathname.replace("/api/agents/", "").replace("/jobs", ""),
    );
    sendJson(res, 200, { jobs: activeJobsForClient(clientName) });
    return;
  }

  if (req.method === "POST" && pathname === "/api/jobs") {
    const body = await parseJsonBody(req);
    const clientName = String(body.clientName || "").trim();
    const direction = String(body.direction || "upload").trim().toLowerCase();
    const sourceClientName = String(
      body.sourceClientName || body.clientName || "",
    ).trim();
    const tables = Array.isArray(body.tables)
      ? body.tables.map(String).map((item) => item.trim()).filter(Boolean)
      : [];

    if (!clientName || tables.length == 0) {
      sendJson(res, 400, { error: "clientName and tables are required." });
      return;
    }

    const jobs = tables.map((table) => {
      const existingJob = state.jobs.find(
        (job) =>
          job.clientName === clientName &&
          job.table === table &&
          job.direction === direction &&
          isJobActive(job),
      );
      if (existingJob) {
        return existingJob;
      }

      return createJob({
        clientName,
        sourceClientName,
        table,
        direction,
        message:
          direction === "download"
            ? `Queued snapshot download for ${table}.`
            : `Queued snapshot upload for ${table}.`,
      });
    });
    await queueSave();
    sendJson(res, 201, { jobs });
    return;
  }

  if (req.method === "GET" && pathname === "/api/snapshots/latest") {
    const clientName = String(url.searchParams.get("clientName") || "").trim();
    const table = String(url.searchParams.get("table") || "").trim();
    const snapshot = latestSnapshot(clientName, table);
    if (!snapshot) {
      sendJson(res, 404, { error: "snapshot not found" });
      return;
    }
    sendJson(res, 200, serializeSnapshot(snapshot));
    return;
  }

  if (pathname.startsWith("/api/jobs/")) {
    const parts = pathname.split("/").filter(Boolean);
    const jobId = parts[2];
    const action = parts[3];
    const job = findJob(jobId);

    if (!job) {
      sendJson(res, 404, { error: "job not found" });
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
      const snapshot = {
        id: crypto.randomUUID(),
        clientName: String(body.clientName || job.clientName),
        table: String(body.table || job.table),
        createdAt,
        rowCount: Number(body.rowCount || rows.length),
        checksum:
          body.checksum ||
          crypto
            .createHash("sha256")
            .update(JSON.stringify(rows))
            .digest("hex"),
        columns,
        rows,
        sourceJobId: job.id,
      };
      state.snapshots[snapshotKey(snapshot.clientName, snapshot.table)] = snapshot;
      updateJob(job, {
        status: "completed",
        progress: 100,
        completedAt: nowIso(),
        snapshotId: snapshot.id,
        snapshotCreatedAt: snapshot.createdAt,
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
