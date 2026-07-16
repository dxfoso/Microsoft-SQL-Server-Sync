#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HARNESS_DIR = Path(__file__).resolve().parent
AGENT_DIR = ROOT / "sync_windows_agent"
PASSWORD = os.environ.get("SQL_SYNC_TEST_PASSWORD", "SqlSync_Test_2026!")
DATABASES = ("SyncClient1", "SyncClient2", "SyncClient3")
COLUMNS = [
    {"name": "Id", "sqlType": "int", "maxLength": 4, "precision": 10, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "Code", "sqlType": "nvarchar", "maxLength": 100, "precision": 0, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "Name", "sqlType": "nvarchar", "maxLength": 200, "precision": 0, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "ArabicText", "sqlType": "nvarchar", "maxLength": 400, "precision": 0, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "Quantity", "sqlType": "int", "maxLength": 4, "precision": 10, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "Amount", "sqlType": "decimal", "maxLength": 9, "precision": 18, "scale": 2, "isIdentity": False, "isComputed": False},
    {"name": "ChangedAt", "sqlType": "datetime2", "maxLength": 8, "precision": 0, "scale": 3, "isIdentity": False, "isComputed": False},
    {"name": "Payload", "sqlType": "varbinary", "maxLength": 32, "precision": 0, "scale": 0, "isIdentity": False, "isComputed": False},
]


def native_tool(name):
    resolved = shutil.which(f"{name}.exe") or shutil.which(name)
    if not resolved:
        return None
    path = Path(resolved)
    if name == "dart" and path.suffix.lower() != ".exe":
        candidate = path.parent / "cache" / "dart-sdk" / "bin" / "dart.exe"
        if candidate.is_file():
            return str(candidate)
    return str(path)


DOCKER = native_tool("docker")
SQLCMD = native_tool("sqlcmd")
DART = native_tool("dart")
COMPOSE = [DOCKER, "compose", "-f", str(HARNESS_DIR / "compose.yaml")]


def run(command, *, input_text=None, cwd=ROOT, check=True):
    result = subprocess.run(
        command,
        cwd=cwd,
        input=input_text,
        text=True,
        encoding="utf-8",
        capture_output=True,
    )
    if check and result.returncode:
        raise RuntimeError(
            f"Command failed ({result.returncode}): {' '.join(map(str, command))}\n"
            f"{result.stdout}\n{result.stderr}"
        )
    return result


def sqlcmd(sql, *, database="master", check=True):
    command = [
        SQLCMD, "-C", "-S", "localhost,14333", "-U", "sa", "-P", PASSWORD,
        "-d", database, "-b", "-r", "1", "-h", "-1", "-W", "-Q", sql,
    ]
    return run(command, check=check)


def wait_for_sql():
    deadline = time.time() + 180
    while time.time() < deadline:
        if sqlcmd("SET NOCOUNT ON; SELECT 1;", check=False).returncode == 0:
            return
        time.sleep(3)
    raise RuntimeError("SQL Server container did not become ready within 180 seconds.")


def reset_databases():
    for database in DATABASES:
        sqlcmd(
            f"""
IF DB_ID(N'{database}') IS NOT NULL
BEGIN
  ALTER DATABASE [{database}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
  DROP DATABASE [{database}];
END;
CREATE DATABASE [{database}];
ALTER DATABASE [{database}] SET CHANGE_TRACKING = ON
  (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);
"""
        )
        sqlcmd(
            """
CREATE TABLE dbo.SyncItems (
  Id int NOT NULL CONSTRAINT PK_SyncItems PRIMARY KEY,
  Code nvarchar(50) NOT NULL CONSTRAINT UQ_SyncItems_Code UNIQUE,
  Name nvarchar(100) NULL,
  ArabicText nvarchar(200) NULL,
  Quantity int NULL,
  Amount decimal(18,2) NULL,
  ChangedAt datetime2(3) NULL,
  Payload varbinary(32) NULL
);
ALTER TABLE dbo.SyncItems ENABLE CHANGE_TRACKING
  WITH (TRACK_COLUMNS_UPDATED = ON);
INSERT dbo.SyncItems
  (Id, Code, Name, ArabicText, Quantity, Amount, ChangedAt, Payload)
VALUES
  (1, N'BASE-1', N'Baseline', N'بداية', 1, 10.50, '2026-01-01T00:00:00.000', 0x0102);
""",
            database=database,
        )


def generate_sql(database, *, rows=None, deletes=None):
    request = {
        "operation": "apply",
        "database": database,
        "schema": "dbo",
        "table": "SyncItems",
        "stageTableName": f"sync_stage_{uuid.uuid4().hex}",
        "columns": COLUMNS,
        "primaryKeyColumns": ["Id"],
        "matchColumnSets": [["Id"], ["Code"]],
        "rows": rows or [],
        "deletes": deletes or [],
    }
    with tempfile.NamedTemporaryFile("w", suffix=".json", encoding="utf-8", delete=False) as handle:
        json.dump(request, handle, ensure_ascii=False)
        request_path = Path(handle.name)
    try:
        result = run(
            [DART, "run", "tool/sync_sql_harness.dart", str(request_path)],
            cwd=AGENT_DIR,
        )
        return result.stdout
    finally:
        request_path.unlink(missing_ok=True)


def apply(database, *, rows=None, deletes=None):
    generated = generate_sql(database, rows=rows, deletes=deletes)
    with tempfile.NamedTemporaryFile("w", suffix=".sql", encoding="utf-8-sig", delete=False) as handle:
        handle.write(generated)
        sql_path = Path(handle.name)
    try:
        result = run([
            SQLCMD, "-C", "-S", "localhost,14333", "-U", "sa", "-P", PASSWORD,
            "-d", "master", "-b", "-r", "1", "-i", str(sql_path),
        ])
        return result.stdout
    finally:
        sql_path.unlink(missing_ok=True)


def coalesce(rows):
    request = {
        "operation": "coalesce",
        "rows": rows,
        "primaryKeyColumns": ["Id"],
        "matchColumnSets": [["Id"], ["Code"]],
    }
    with tempfile.NamedTemporaryFile("w", suffix=".json", encoding="utf-8", delete=False) as handle:
        json.dump(request, handle, ensure_ascii=False)
        request_path = Path(handle.name)
    try:
        result = run(
            [DART, "run", "tool/sync_sql_harness.dart", str(request_path)],
            cwd=AGENT_DIR,
        )
        return json.loads(result.stdout)
    finally:
        request_path.unlink(missing_ok=True)


def row(id_, code, name, *, arabic="مرحبا بالعالم", quantity=1, amount="1.25",
        changed_at="2026-07-16T10:00:00.000", payload="0x010203"):
    return {
        "Id": id_, "Code": code, "Name": name, "ArabicText": arabic,
        "Quantity": quantity, "Amount": amount, "ChangedAt": changed_at,
        "Payload": payload,
    }


def table_rows(database):
    result = sqlcmd(
        """
SET NOCOUNT ON;
SELECT CONCAT(
  Id, N'|', Code, N'|', COALESCE(Name, N'<NULL>'), N'|',
  COALESCE(ArabicText, N'<NULL>'), N'|', COALESCE(CONVERT(nvarchar(20), Quantity), N'<NULL>'),
  N'|', COALESCE(CONVERT(nvarchar(30), Amount), N'<NULL>'), N'|',
  COALESCE(CONVERT(nvarchar(33), ChangedAt, 126), N'<NULL>'), N'|',
  COALESCE(CONVERT(varchar(66), Payload, 1), '<NULL>')
)
FROM dbo.SyncItems
ORDER BY Id;
""",
        database=database,
    )
    return [line.strip() for line in result.stdout.splitlines() if "|" in line]


def assert_equal(*databases):
    snapshots = {database: table_rows(database) for database in databases}
    first = snapshots[databases[0]]
    for database in databases[1:]:
        if snapshots[database] != first:
            raise AssertionError(f"Database mismatch: {json.dumps(snapshots, ensure_ascii=False, indent=2)}")


def assert_context_filtered(database):
    result = sqlcmd(
        """
SET NOCOUNT ON;
DECLARE @v bigint = 0;
SELECT COUNT(*)
FROM CHANGETABLE(CHANGES dbo.SyncItems, @v) AS ct
WHERE ct.SYS_CHANGE_CONTEXT = 0x53514C53594E43;
""",
        database=database,
    )
    values = [line.strip() for line in result.stdout.splitlines() if line.strip().isdigit()]
    if not values or int(values[-1]) == 0:
        raise AssertionError("Expected sync-applied rows to retain the Change Tracking context.")


def run_scenarios():
    reset_databases()

    inserted = row(2, "INSERT-2", "Inserted on client 1", arabic="إضافة جديدة")
    for database in DATABASES[1:]:
        apply(database, rows=[inserted])
    apply(DATABASES[0], rows=[inserted])
    assert_equal(*DATABASES)

    updated = row(2, "INSERT-2", "Updated on client 2", arabic="تحديث صحيح", quantity=9)
    for database in DATABASES:
        apply(database, rows=[updated])
    assert_equal(*DATABASES)

    # SQL Change Tracking represents a primary-key edit as delete-old plus insert-new.
    key_changed = row(20, "INSERT-2", "Primary key changed", arabic="تغيير المفتاح", quantity=10)
    for database in DATABASES:
        apply(database, deletes=[{"Id": 2}], rows=[key_changed])
    assert_equal(*DATABASES)

    for database in DATABASES:
        apply(database, deletes=[{"Id": 20}])
    assert_equal(*DATABASES)

    winners = coalesce([
        {**row(30, "CONFLICT", "Older c1"), "__sync_modified_at_utc": "2026-07-16T10:00:00Z"},
        {**row(30, "CONFLICT", "Newer c2"), "__sync_modified_at_utc": "2026-07-16T10:00:01Z"},
    ])
    if len(winners) != 1 or winners[0]["Name"] != "Newer c2":
        raise AssertionError(f"Conflict policy selected the wrong row: {winners}")
    for database in DATABASES:
        apply(database, rows=winners)
    assert_equal(*DATABASES)

    # Client 3 is offline for two rounds, then receives the accumulated delta once.
    offline_rows = [
        row(40, "OFFLINE-1", "Queued while client 3 offline"),
        row(41, "OFFLINE-2", "Second queued row", arabic="عميل غير متصل"),
    ]
    for database in DATABASES[:2]:
        apply(database, rows=offline_rows)
    if table_rows(DATABASES[2]) == table_rows(DATABASES[0]):
        raise AssertionError("Offline client unexpectedly changed before catch-up.")
    apply(DATABASES[2], rows=offline_rows)
    assert_equal(*DATABASES)

    large_rows = [
        row(1000 + index, f"BULK-{index:04d}", f"Bulk row {index}", quantity=index)
        for index in range(1200)
    ]
    for database in DATABASES:
        apply(database, rows=large_rows)
    assert_equal(*DATABASES)

    # Retrying the same delta is idempotent.
    for database in DATABASES:
        apply(database, rows=large_rows[:25])
    assert_equal(*DATABASES)

    assert_context_filtered(DATABASES[0])
    print(json.dumps({
        "ok": True,
        "clients": len(DATABASES),
        "scenarios": [
            "insert", "update", "primary-key-change", "delete",
            "newest-commit-conflict", "unicode-arabic", "offline-catch-up",
            "large-1200-row-batch", "idempotent-retry", "change-context",
        ],
        "finalRowCount": len(table_rows(DATABASES[0])),
    }, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true", help="Keep the SQL container running after tests.")
    args = parser.parse_args()
    if DOCKER is None or SQLCMD is None or DART is None:
        raise SystemExit("docker, sqlcmd, and dart must be available on PATH.")
    run(COMPOSE + ["up", "-d"])
    try:
        wait_for_sql()
        run_scenarios()
    finally:
        if not args.keep:
            run(COMPOSE + ["down", "-v"], check=False)


if __name__ == "__main__":
    main()
