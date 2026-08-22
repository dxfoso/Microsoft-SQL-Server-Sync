#!/usr/bin/env python3
import argparse
import concurrent.futures
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HARNESS_DIR = Path(__file__).resolve().parent
AGENT_DIR = ROOT / "sync_windows_agent"
PASSWORD = os.environ.get("SQL_SYNC_TEST_PASSWORD", "SqlSync_Test_2026!")
SQL_SERVER = os.environ.get("SQL_SYNC_TEST_SERVER", "localhost,14333")
SQL_USER = os.environ.get("SQL_SYNC_TEST_USER", "sa")
SQL_CONTAINER_ID = os.environ.get("SQL_SYNC_TEST_CONTAINER_ID", "").strip()
DATABASES = ("SyncClient1", "SyncClient2", "SyncClient3")
COLUMNS = [
    {"name": "Id", "sqlType": "int", "maxLength": 4, "precision": 10, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "Code", "sqlType": "nvarchar", "maxLength": 100, "precision": 0, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "Name", "sqlType": "nvarchar", "maxLength": 200, "precision": 0, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "ArabicText", "sqlType": "nvarchar", "maxLength": 400, "precision": 0, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "Quantity", "sqlType": "int", "maxLength": 4, "precision": 10, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "Amount", "sqlType": "decimal", "maxLength": 9, "precision": 18, "scale": 2, "isIdentity": False, "isComputed": False},
    {"name": "FloatValue", "sqlType": "float", "maxLength": 8, "precision": 53, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "RealValue", "sqlType": "real", "maxLength": 4, "precision": 24, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "ChangedAt", "sqlType": "datetime2", "maxLength": 8, "precision": 0, "scale": 3, "isIdentity": False, "isComputed": False},
    {"name": "Payload", "sqlType": "varbinary", "maxLength": 32, "precision": 0, "scale": 0, "isIdentity": False, "isComputed": False},
]
INVOICE_LINE_COLUMNS = [
    {"name": "GUID", "sqlType": "uniqueidentifier", "maxLength": 16, "precision": 0, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "ParentGUID", "sqlType": "uniqueidentifier", "maxLength": 16, "precision": 0, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "Number", "sqlType": "int", "maxLength": 4, "precision": 10, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "Quantity", "sqlType": "decimal", "maxLength": 9, "precision": 18, "scale": 2, "isIdentity": False, "isComputed": False},
    {"name": "ArabicText", "sqlType": "nvarchar", "maxLength": 400, "precision": 0, "scale": 0, "isIdentity": False, "isComputed": False},
]
PARENT_COLUMNS = [
    {"name": "ParentId", "sqlType": "int", "maxLength": 4, "precision": 10, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "ExternalCode", "sqlType": "nvarchar", "maxLength": 80, "precision": 0, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "Name", "sqlType": "nvarchar", "maxLength": 200, "precision": 0, "scale": 0, "isIdentity": False, "isComputed": False},
]
CHILD_COLUMNS = [
    {"name": "ParentId", "sqlType": "int", "maxLength": 4, "precision": 10, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "ChildNo", "sqlType": "int", "maxLength": 4, "precision": 10, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "ExternalCode", "sqlType": "nvarchar", "maxLength": 80, "precision": 0, "scale": 0, "isIdentity": False, "isComputed": False},
    {"name": "Value", "sqlType": "decimal", "maxLength": 9, "precision": 18, "scale": 4, "isIdentity": False, "isComputed": False},
    {"name": "ArabicText", "sqlType": "nvarchar", "maxLength": 400, "precision": 0, "scale": 0, "isIdentity": False, "isComputed": False},
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
POWERSHELL = native_tool("powershell")
COMPOSE = [DOCKER, "compose", "-f", str(HARNESS_DIR / "compose.yaml")]
CONTAINER_SQLCMD = SQLCMD is None and DOCKER is not None


def go_sqlcmd_version(executable):
    if not executable:
        return ""
    result = subprocess.run(
        [executable, "--version"],
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
    )
    return f"{result.stdout}\n{result.stderr}".strip() if result.returncode == 0 else ""


SQLCMD_GO_VERSION = go_sqlcmd_version(SQLCMD)
SQLCMD_TLS_ARGS = (
    ["-N", "disable"]
    if SQLCMD_GO_VERSION and ":2017-" in os.environ.get("SQL_SYNC_TEST_IMAGE", "")
    else []
)


def tool_supports_option(executable, option):
    if not executable:
        return False
    result = subprocess.run(
        [executable, "-?"],
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
    )
    help_text = f"{result.stdout}\n{result.stderr}"
    return any(
        line.strip().startswith(option)
        or f" {option} " in line
        or f" {option}," in line
        for line in help_text.splitlines()
    )


SQLCMD_SUPPORTS_INPUT_CODEPAGE = tool_supports_option(SQLCMD, "-f")


def run_windows_bulk_stage_performance_regression():
    if os.name != "nt" or POWERSHELL is None or SQLCMD is None:
        print("Skipping Windows SqlBulkCopy performance regression on this host.")
        return
    result = run(
        [
            POWERSHELL,
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-WindowStyle",
            "Hidden",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(ROOT / "tests" / "benchmark_sql_bulk_stage.ps1"),
            "-Server",
            SQL_SERVER,
            "-User",
            SQL_USER,
            "-Password",
            PASSWORD,
            "-Rows",
            "14030",
            "-MinimumSpeedup",
            "1.25",
        ]
    )
    print(result.stdout.strip())


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


def sqlcmd_command(arguments):
    if not CONTAINER_SQLCMD:
        return [SQLCMD, *arguments]
    launcher = (
        'if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then '
        'exec /opt/mssql-tools18/bin/sqlcmd "$@"; '
        'else shift; exec /opt/mssql-tools/bin/sqlcmd "$@"; fi'
    )
    return [*COMPOSE, "exec", "-T", "sql", "/bin/sh", "-c", launcher, "sqlcmd", *arguments]


def sqlcmd(sql, *, database="master", check=True):
    server = "localhost" if CONTAINER_SQLCMD else SQL_SERVER
    arguments = [
        "-C", "-S", server, "-U", SQL_USER, "-P", PASSWORD,
        *SQLCMD_TLS_ARGS,
        "-d", database, "-b", "-r", "1",
        *(["-f", "65001"] if SQLCMD_SUPPORTS_INPUT_CODEPAGE else []),
        "-h", "-1", "-W", "-Q", sql,
    ]
    return run(sqlcmd_command(arguments), check=check)

def sqlcmd_script(sql, *, database="master", check=True):
    if CONTAINER_SQLCMD:
        arguments = [
            "-C", "-S", "localhost", "-U", SQL_USER, "-P", PASSWORD,
            *SQLCMD_TLS_ARGS,
            "-d", database, "-b", "-r", "1",
            "-h", "-1", "-w", "32767", "-i", "/dev/stdin",
        ]
        return run(sqlcmd_command(arguments), input_text=sql, check=check)
    with tempfile.NamedTemporaryFile(
        "w",
        suffix=".sql",
        encoding="utf-8",
        delete=False,
    ) as handle:
        handle.write(sql)
        sql_path = Path(handle.name)
    try:
        command = [
            SQLCMD, "-C", "-S", SQL_SERVER, "-U", SQL_USER, "-P", PASSWORD,
            *SQLCMD_TLS_ARGS,
            "-d", database, "-b", "-r", "1",
            *(["-f", "65001"] if SQLCMD_SUPPORTS_INPUT_CODEPAGE else []),
            "-h", "-1",
            "-w", "32767", "-i", str(sql_path),
        ]
        return run(command, check=check)
    finally:
        sql_path.unlink(missing_ok=True)


def wait_for_sql():
    deadline = time.time() + 180
    while time.time() < deadline:
        if sqlcmd("SET NOCOUNT ON; SELECT 1;", check=False).returncode == 0:
            return
        time.sleep(3)
    raise RuntimeError("SQL Server container did not become ready within 180 seconds.")


def wait_for_test_databases():
    deadline = time.time() + 180
    database_names = ", ".join(f"N'{name}'" for name in DATABASES)
    while time.time() < deadline:
        result = sqlcmd(
            f"""
SET NOCOUNT ON;
SELECT COUNT(*)
FROM sys.databases
WHERE name IN ({database_names})
  AND state_desc = N'ONLINE'
  AND HAS_DBACCESS(name) = 1;
""",
            check=False,
        )
        values = [line.strip() for line in result.stdout.splitlines()]
        if result.returncode == 0 and str(len(DATABASES)) in values:
            return
        time.sleep(1)
    raise RuntimeError("Sync test databases did not recover within 180 seconds.")


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
  FloatValue float NULL,
  RealValue real NULL,
  ChangedAt datetime2(3) NULL,
  Payload varbinary(32) NULL
);
ALTER TABLE dbo.SyncItems ENABLE CHANGE_TRACKING
  WITH (TRACK_COLUMNS_UPDATED = ON);
INSERT dbo.SyncItems
  (Id, Code, Name, ArabicText, Quantity, Amount, FloatValue, RealValue, ChangedAt, Payload)
VALUES
  (1, N'BASE-1', N'Baseline', N'بداية', 1, 10.50, NULL, NULL, '2026-01-01T00:00:00.000', 0x0102);
""",
            database=database,
        )
        sqlcmd(
            """
CREATE TABLE dbo.InvoiceLines (
  GUID uniqueidentifier NOT NULL CONSTRAINT PK_InvoiceLines PRIMARY KEY,
  ParentGUID uniqueidentifier NOT NULL,
  Number int NOT NULL,
  Quantity decimal(18,2) NULL,
  ArabicText nvarchar(200) NULL
);
ALTER TABLE dbo.InvoiceLines ENABLE CHANGE_TRACKING
  WITH (TRACK_COLUMNS_UPDATED = ON);
""",
            database=database,
        )
        sqlcmd(
            """
CREATE TABLE dbo.ParentItems (
  ParentId int NOT NULL CONSTRAINT PK_ParentItems PRIMARY KEY,
  ExternalCode nvarchar(40) NOT NULL CONSTRAINT UQ_ParentItems_ExternalCode UNIQUE,
  Name nvarchar(100) NULL
);
ALTER TABLE dbo.ParentItems ENABLE CHANGE_TRACKING
  WITH (TRACK_COLUMNS_UPDATED = ON);

CREATE TABLE dbo.ChildItems (
  ParentId int NOT NULL,
  ChildNo int NOT NULL,
  ExternalCode nvarchar(40) NOT NULL CONSTRAINT UQ_ChildItems_ExternalCode UNIQUE,
  Value decimal(18,4) NULL,
  ArabicText nvarchar(200) NULL,
  CONSTRAINT PK_ChildItems PRIMARY KEY (ParentId, ChildNo),
  CONSTRAINT FK_ChildItems_ParentItems FOREIGN KEY (ParentId)
    REFERENCES dbo.ParentItems(ParentId) ON DELETE CASCADE
);
ALTER TABLE dbo.ChildItems ENABLE CHANGE_TRACKING
  WITH (TRACK_COLUMNS_UPDATED = ON);
""",
            database=database,
        )
        sqlcmd(
            """
CREATE TRIGGER dbo.TR_SyncItems_Protect
ON dbo.SyncItems
AFTER UPDATE, DELETE
AS
BEGIN
  SET NOCOUNT ON;
  IF EXISTS (SELECT 1 FROM inserted) OR EXISTS (SELECT 1 FROM deleted)
  BEGIN
    RAISERROR('Business trigger rejected direct modification.', 16, 1);
    ROLLBACK TRANSACTION;
  END;
END;
""",
            database=database,
        )


def generate_sql(
    database,
    *,
    rows=None,
    deletes=None,
    unique_index_column_sets=None,
    table="SyncItems",
    columns=None,
    primary_key_columns=None,
    protect_local_changes_after_version=None,
    resolve_unique_conflicts_latest_wins=False,
):
    columns = columns or COLUMNS
    primary_key_columns = primary_key_columns or ["Id"]
    request = {
        "operation": "apply",
        "database": database,
        "schema": "dbo",
        "table": table,
        "stageTableName": f"sync_stage_{uuid.uuid4().hex}",
        "columns": columns,
        "primaryKeyColumns": primary_key_columns,
        "uniqueIndexColumnSets": unique_index_column_sets or [],
        "rows": rows or [],
        "deletes": deletes or [],
        "resolveUniqueConflictsLatestWins": resolve_unique_conflicts_latest_wins,
    }
    if protect_local_changes_after_version is not None:
        request["protectLocalChangesAfterVersion"] = protect_local_changes_after_version
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


def apply(
    database,
    *,
    rows=None,
    deletes=None,
    unique_index_column_sets=None,
    table="SyncItems",
    columns=None,
    primary_key_columns=None,
    protect_local_changes_after_version=None,
    resolve_unique_conflicts_latest_wins=False,
):
    generated = generate_sql(
        database,
        rows=rows,
        deletes=deletes,
        unique_index_column_sets=unique_index_column_sets,
        table=table,
        columns=columns,
        primary_key_columns=primary_key_columns,
        protect_local_changes_after_version=protect_local_changes_after_version,
        resolve_unique_conflicts_latest_wins=resolve_unique_conflicts_latest_wins,
    )
    return execute_generated_sql(generated).stdout


def generated_sql_command(sql_path, *, host_name=None):
    input_path = str(sql_path)
    if CONTAINER_SQLCMD:
        input_path = f"/harness/{sql_path.name}"
    arguments = [
        "-C",
        "-S",
        "localhost" if CONTAINER_SQLCMD else SQL_SERVER,
        "-U",
        SQL_USER,
        "-P",
        PASSWORD,
        *SQLCMD_TLS_ARGS,
        "-d",
        "master",
        "-b",
        "-r",
        "1",
        *(["-f", "65001"] if SQLCMD_SUPPORTS_INPUT_CODEPAGE else []),
        "-i",
        input_path,
    ]
    if host_name:
        arguments.extend(["-H", host_name])
    return sqlcmd_command(arguments)


def execute_generated_sql(generated, *, check=True):
    with tempfile.NamedTemporaryFile(
        "w",
        suffix=".sql",
        encoding="utf-8",
        delete=False,
        dir=HARNESS_DIR if CONTAINER_SQLCMD else None,
    ) as handle:
        handle.write(generated)
        sql_path = Path(handle.name)
    try:
        return run(generated_sql_command(sql_path), check=check)
    finally:
        sql_path.unlink(missing_ok=True)


def coalesce(rows, *, primary_key_columns=None, unique_key_column_sets=None):
    request = {
        "operation": "coalesce",
        "rows": rows,
        "primaryKeyColumns": primary_key_columns or ["Id"],
        "uniqueKeyColumnSets": unique_key_column_sets or [],
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


def transport_expression(column):
    request = {
        "operation": "transport-expression",
        "column": column,
        "columnReference": f"[{column['name']}]",
    }
    with tempfile.NamedTemporaryFile("w", suffix=".json", encoding="utf-8", delete=False) as handle:
        json.dump(request, handle, ensure_ascii=False)
        request_path = Path(handle.name)
    try:
        result = run(
            [DART, "run", "tool/sync_sql_harness.dart", str(request_path)],
            cwd=AGENT_DIR,
        )
        return result.stdout.strip()
    finally:
        request_path.unlink(missing_ok=True)


def capture_float_transport_values(database, id_):
    float_column = next(column for column in COLUMNS if column["name"] == "FloatValue")
    real_column = next(column for column in COLUMNS if column["name"] == "RealValue")
    float_expression = transport_expression(float_column)
    real_expression = transport_expression(real_column)
    result = sqlcmd_script(
        f"""
SET NOCOUNT ON;
SELECT CONCAT({float_expression}, N'|', {real_expression})
FROM dbo.SyncItems
WHERE Id = {id_};
""",
        database=database,
    )
    values = [line.strip().split("|") for line in result.stdout.splitlines() if "|" in line]
    if len(values) != 1 or len(values[0]) != 2:
        raise AssertionError(f"Unexpected floating-point capture output: {values}")
    return values[0]


def row(id_, code, name, *, arabic="مرحبا بالعالم", quantity=1, amount="1.25",
        float_value=None, real_value=None, changed_at="2026-07-16T10:00:00.000", payload="0x010203"):
    return {
        "Id": id_, "Code": code, "Name": name, "ArabicText": arabic,
        "Quantity": quantity, "Amount": amount, "FloatValue": float_value,
        "RealValue": real_value, "ChangedAt": changed_at,
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
  COALESCE(CONVERT(nvarchar(100), FloatValue, 3), N'<NULL>'), N'|',
  COALESCE(CONVERT(nvarchar(100), RealValue, 3), N'<NULL>'), N'|',
  COALESCE(CONVERT(nvarchar(33), ChangedAt, 126), N'<NULL>'), N'|',
  COALESCE(CONVERT(varchar(66), Payload, 1), '<NULL>')
)
FROM dbo.SyncItems
ORDER BY Id;
""",
        database=database,
    )
    return [line.strip() for line in result.stdout.splitlines() if "|" in line]


def scalar_int(database, sql):
    result = sqlcmd(f"SET NOCOUNT ON; {sql}", database=database)
    values = [line.strip() for line in result.stdout.splitlines() if line.strip().isdigit()]
    if not values:
        raise AssertionError(f"Expected an integer result from SQL: {result.stdout}")
    return int(values[-1])


def assert_post_upload_overlap_protection(database):
    sqlcmd(
        """
DISABLE TRIGGER dbo.TR_SyncItems_Protect ON dbo.SyncItems;
INSERT dbo.SyncItems
  (Id, Code, Name, ArabicText, Quantity, Amount, ChangedAt, Payload)
VALUES
  (9000, N'GUARD-9000', N'Before upload', N'local', 1, 1.00, SYSUTCDATETIME(), 0x01),
  (9001, N'GUARD-9001', N'Before upload', N'baseline', 1, 1.00, SYSUTCDATETIME(), 0x01),
  (9002, N'GUARD-9002', N'Unrelated before upload', N'baseline', 1, 1.00, SYSUTCDATETIME(), 0x01);
ENABLE TRIGGER dbo.TR_SyncItems_Protect ON dbo.SyncItems;
""",
        database=database,
    )
    baseline = scalar_int(database, "SELECT CHANGE_TRACKING_CURRENT_VERSION();")
    sqlcmd(
        """
DISABLE TRIGGER dbo.TR_SyncItems_Protect ON dbo.SyncItems;
UPDATE dbo.SyncItems SET Name = N'Local after upload' WHERE Id = 9000;
UPDATE dbo.SyncItems SET Name = N'Unrelated local after upload' WHERE Id = 9002;
ENABLE TRIGGER dbo.TR_SyncItems_Protect ON dbo.SyncItems;
""",
        database=database,
    )
    output = apply(
        database,
        rows=[
            row(9000, "GUARD-9000", "Remote incoming must be deferred"),
            row(9001, "GUARD-9001", "Remote incoming applied"),
        ],
        protect_local_changes_after_version=baseline,
    )
    if "__SQL_SYNC_PROTECTED__=1" not in output:
        raise AssertionError(f"Expected one protected incoming key: {output}")
    result = sqlcmd(
        """
SET NOCOUNT ON;
SELECT CONCAT(Id, N'|', Name)
FROM dbo.SyncItems
WHERE Id IN (9000, 9001, 9002)
ORDER BY Id;
""",
        database=database,
    )
    values = [line.strip() for line in result.stdout.splitlines() if "|" in line]
    expected = [
        "9000|Local after upload",
        "9001|Remote incoming applied",
        "9002|Unrelated local after upload",
    ]
    if values != expected:
        raise AssertionError(f"Post-upload overlap protection failed: {values}")
    user_context_rows = scalar_int(
        database,
        f"""
SELECT COUNT(*)
FROM CHANGETABLE(CHANGES dbo.SyncItems, {baseline}) AS ct
WHERE ct.Id IN (9000, 9002)
  AND (ct.SYS_CHANGE_CONTEXT IS NULL OR ct.SYS_CHANGE_CONTEXT <> 0x53514C53594E43);
""",
    )
    if user_context_rows != 2:
        raise AssertionError(
            f"Expected protected and unrelated user changes to remain outbound; count={user_context_rows}"
        )
    sqlcmd(
        """
DISABLE TRIGGER dbo.TR_SyncItems_Protect ON dbo.SyncItems;
DELETE dbo.SyncItems WHERE Id IN (9000, 9001, 9002);
ENABLE TRIGGER dbo.TR_SyncItems_Protect ON dbo.SyncItems;
""",
        database=database,
    )


def invoice_line_rows(database):
    result = sqlcmd(
        """
SET NOCOUNT ON;
SELECT CONCAT(
  CONVERT(varchar(36), GUID), N'|',
  CONVERT(varchar(36), ParentGUID), N'|',
  Number, N'|', CONVERT(varchar(30), Quantity), N'|',
  CONVERT(varchar(max), CONVERT(varbinary(max), ArabicText), 2)
)
FROM dbo.InvoiceLines
ORDER BY ParentGUID, Number, GUID;
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


def assert_text_value(database, id_, expected):
    result = sqlcmd(
        f"""
SET NOCOUNT ON;
SELECT CONVERT(varchar(max), CONVERT(varbinary(max), ArabicText), 2)
FROM dbo.SyncItems
WHERE Id = {id_};
""",
        database=database,
    )
    values = [line.strip().upper() for line in result.stdout.splitlines() if line.strip()]
    expected_hex = expected.encode("utf-16-le").hex().upper()
    if values != [expected_hex]:
        raise AssertionError(
            f"Unicode value mismatch in {database} for Id={id_}: expected {expected_hex}, got {values}"
        )


def assert_unicode_hex_transport(database, id_, expected):
    result = sqlcmd(
        f"""
SET NOCOUNT ON;
SELECT N'\\U' + CONVERT(
  nvarchar(max),
  CONVERT(
    varchar(max),
    CONVERT(varbinary(max), CONVERT(nvarchar(max), ArabicText)),
    2
  )
)
FROM dbo.SyncItems
WHERE Id = {id_};
""",
        database=database,
    )
    values = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if len(values) != 1 or not values[0].startswith("\\U"):
        raise AssertionError(
            f"Unicode transport marker mismatch in {database} for Id={id_}: {values}"
        )
    decoded = bytes.fromhex(values[0][2:]).decode("utf-16-le")
    if decoded != expected:
        raise AssertionError(
            f"Unicode transport mismatch in {database} for Id={id_}: expected {expected!r}, got {decoded!r}"
        )


def assert_float_values(database, id_, expected):
    result = sqlcmd(
        f"""
SET NOCOUNT ON;
SELECT COUNT(*)
FROM dbo.SyncItems
WHERE Id = {id_}
  AND FloatValue = CAST({expected} AS float)
  AND RealValue = CAST({expected} AS real);
""",
        database=database,
    )
    values = [line.strip() for line in result.stdout.splitlines() if line.strip().isdigit()]
    if values != ["1"]:
        raise AssertionError(
            f"Floating-point value mismatch in {database} for Id={id_}: {values}"
        )


def expect_apply_failure(database, *, rows=None, deletes=None):
    try:
        apply(database, rows=rows, deletes=deletes)
    except RuntimeError:
        return
    raise AssertionError("Expected SQL delta application to fail.")


def assert_business_trigger_enabled(database):
    state = sqlcmd(
        """
SET NOCOUNT ON;
SELECT is_disabled
FROM sys.triggers
WHERE object_id = OBJECT_ID(N'dbo.TR_SyncItems_Protect');
""",
        database=database,
    )
    values = [line.strip() for line in state.stdout.splitlines() if line.strip() in ("0", "1")]
    if values != ["0"]:
        raise AssertionError(f"Business trigger is not enabled in {database}: {values}")
    direct_update = sqlcmd(
        "UPDATE dbo.SyncItems SET Name = Name WHERE Id = (SELECT MIN(Id) FROM dbo.SyncItems);",
        database=database,
        check=False,
    )
    if direct_update.returncode == 0:
        raise AssertionError(f"Business trigger did not reject ordinary DML in {database}.")

def assert_hex_row_transport(database):
    control_text = "Arabic \u0627\u0644\u0639\u0631\u0628\u064a\u0629" + chr(31) + "|\\n\r\n\u6f22\u5b57"
    sqlcmd_script(
        """
SET NOCOUNT ON;
DISABLE TRIGGER dbo.TR_SyncItems_Protect ON dbo.SyncItems;
UPDATE dbo.SyncItems
SET Name =
  N'Arabic ' +
  NCHAR(1575) + NCHAR(1604) + NCHAR(1593) + NCHAR(1585) +
  NCHAR(1576) + NCHAR(1610) + NCHAR(1577) +
  NCHAR(31) + N'|\\n' + NCHAR(13) + NCHAR(10) +
  NCHAR(28450) + NCHAR(23383)
WHERE Id = 1;
ENABLE TRIGGER dbo.TR_SyncItems_Protect ON dbo.SyncItems;
""",
        database=database,
    )
    result = sqlcmd_script(
        """
SET NOCOUNT ON;
;WITH encoded_rows AS (
SELECT
  CAST('H' AS varchar(max)) +
  CONVERT(varchar(max), CONVERT(varbinary(max), CONVERT(nvarchar(max), source_row.Id)), 2) +
  '|H' +
  CONVERT(varchar(max), CONVERT(varbinary(max), CONVERT(nvarchar(max), source_row.Name)), 2) +
  '|H' +
  CONVERT(varchar(max), CONVERT(varbinary(max), CONVERT(nvarchar(max), source_row.ArabicText)), 2) +
  '~SQLSYNC_ROW_END~' AS payload
FROM dbo.SyncItems AS source_row
WHERE source_row.Id = 1
),
payload_chunks AS (
  SELECT 1 AS payload_offset, payload
  FROM encoded_rows
  UNION ALL
  SELECT payload_offset + 200, payload
  FROM payload_chunks
  WHERE payload_offset + 200 <= LEN(payload)
)
SELECT CONVERT(varchar(200), SUBSTRING(payload, payload_offset, 200))
FROM payload_chunks
ORDER BY payload_offset
OPTION (MAXRECURSION 0);
""",
        database=database,
    )
    fragments = result.stdout.split("~SQLSYNC_ROW_END~")
    encoded = "".join(fragments[0].split())
    decoded = [
        None if token == "N" else bytes.fromhex(token[1:]).decode("utf-16-le")
        for token in encoded.split("|")
    ]
    if decoded != ["1", control_text, "\u0628\u062f\u0627\u064a\u0629"]:
        raise AssertionError(f"Framed hex SQL row transport was lossy: {decoded!r}")
    sqlcmd(
        """
SET NOCOUNT ON;
DISABLE TRIGGER dbo.TR_SyncItems_Protect ON dbo.SyncItems;
UPDATE dbo.SyncItems SET Name = N'Baseline' WHERE Id = 1;
ENABLE TRIGGER dbo.TR_SyncItems_Protect ON dbo.SyncItems;
""",
        database=database,
    )


def inject_sql_once(generated, marker, injected):
    if marker not in generated:
        raise AssertionError(f"Fault-injection marker was not found: {marker!r}")
    return generated.replace(marker, f"{injected}\n{marker}", 1)


def assert_stage_table_removed(generated):
    match = re.search(r"tempdb\.dbo\.\[([^\]]+)\]", generated)
    if match is None:
        raise AssertionError("Generated SQL did not expose its staging table.")
    stage = match.group(1).replace("'", "''")
    remaining = scalar_int(
        "master",
        f"SELECT CASE WHEN OBJECT_ID(N'tempdb.dbo.[{stage}]', N'U') IS NULL THEN 0 ELSE 1 END;",
    )
    if remaining != 0:
        raise AssertionError(f"Faulted apply leaked staging table {match.group(1)}.")


def assert_atomic_fault_rollback(database, marker, label):
    before = table_rows(database)
    generated = generate_sql(
        database,
        rows=[
            row(1, "BASE-1", f"{label} must roll back"),
            row(8101, f"ATOMIC-{label}", "Sibling must roll back"),
        ],
    )
    faulted = inject_sql_once(
        generated,
        marker,
        f"  RAISERROR('Injected atomic fault: {label}', 16, 1);",
    )
    result = execute_generated_sql(faulted, check=False)
    if result.returncode == 0:
        raise AssertionError(f"Injected {label} failure unexpectedly committed.")
    if table_rows(database) != before:
        raise AssertionError(f"Injected {label} failure partially changed {database}.")
    assert_business_trigger_enabled(database)
    assert_stage_table_removed(generated)


def wait_for_fault_session(host_name, process=None, timeout_seconds=20):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if process is not None and process.poll() is not None:
            raise AssertionError(
                "SQL fault process exited before reaching the injected wait "
                f"(exit {process.returncode})."
            )
        result = sqlcmd(
            f"""
SET NOCOUNT ON;
SELECT session_id
FROM sys.dm_exec_sessions AS sessions
WHERE sessions.host_name = N'{host_name.replace("'", "''")}'
  AND sessions.session_id <> @@SPID;
""",
            check=False,
        )
        values = [
            int(line.strip())
            for line in result.stdout.splitlines()
            if line.strip().isdigit()
        ]
        if values:
            return values[0]
        time.sleep(0.2)
    diagnostics = sqlcmd(
        """
SET NOCOUNT ON;
SELECT sessions.session_id,
       sessions.status,
       sessions.program_name,
       master.dbo.fn_varbintohexstr(sessions.context_info),
       requests.command,
       requests.wait_type
FROM sys.dm_exec_sessions AS sessions
LEFT JOIN sys.dm_exec_requests AS requests
  ON requests.session_id = sessions.session_id
WHERE sessions.is_user_process = 1;
""",
        check=False,
    )
    raise AssertionError(
        f"Timed out waiting for SQL fault session {host_name}.\n"
        f"Active SQL sessions:\n{diagnostics.stdout}\n{diagnostics.stderr}"
    )


def run_interrupted_apply(generated, context_hex, *, restart_sql=False):
    host_name = f"SQLSYNC_FAULT_{context_hex[2:]}"
    identified = inject_sql_once(
        generated,
        "  BEGIN TRANSACTION;",
        f"  SET CONTEXT_INFO {context_hex};",
    )
    injected = inject_sql_once(
        identified,
        "  COMMIT TRANSACTION;",
        "  WAITFOR DELAY '00:00:30';",
    )
    with tempfile.NamedTemporaryFile(
        "w",
        suffix=".sql",
        encoding="utf-8",
        delete=False,
        dir=HARNESS_DIR if CONTAINER_SQLCMD else None,
    ) as handle:
        handle.write(injected)
        sql_path = Path(handle.name)
    process = subprocess.Popen(
        generated_sql_command(sql_path, host_name=host_name),
        cwd=ROOT,
        text=True,
        encoding="utf-8",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        try:
            spid = wait_for_fault_session(host_name, process)
        except AssertionError as error:
            if process.poll() is None:
                process.kill()
            stdout, stderr = process.communicate()
            raise AssertionError(
                f"{error}\nInterrupted apply output:\n{stdout}\n{stderr}"
            ) from error
        if restart_sql:
            container_id = SQL_CONTAINER_ID
            if not container_id and DOCKER:
                container_id = run(COMPOSE + ["ps", "-q", "sql"]).stdout.strip()
            if not container_id:
                raise AssertionError(
                    "SQL restart testing requires SQL_SYNC_TEST_CONTAINER_ID "
                    "or a locally managed Compose service."
                )
            run([DOCKER, "restart", container_id])
            wait_for_sql()
            wait_for_test_databases()
            # Some sqlcmd/ODBC versions keep retrying a broken TCP session after
            # the server is back. The transaction was already interrupted by the
            # restart, so terminate the stranded client process deterministically.
            if process.poll() is None:
                process.kill()
        else:
            sqlcmd(f"KILL {spid};")
        stdout, stderr = process.communicate(timeout=45)
        if process.returncode == 0:
            raise AssertionError(
                f"Interrupted SQL apply unexpectedly succeeded: {stdout}\n{stderr}"
            )
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
        sql_path.unlink(missing_ok=True)


def assert_connection_loss_atomicity(database, *, restart_sql=False):
    before = table_rows(database)
    generated = generate_sql(
        database,
        rows=[
            row(1, "BASE-1", "Interrupted update must roll back"),
            row(8201, "INTERRUPTED-SIBLING", "Interrupted insert must roll back"),
        ],
    )
    context_hex = (
        "0x53514C53594E4352455354415254"
        if restart_sql
        else "0x53514C53594E434B494C4C"
    )
    run_interrupted_apply(generated, context_hex, restart_sql=restart_sql)
    if table_rows(database) != before:
        mode = "SQL restart" if restart_sql else "connection kill"
        raise AssertionError(f"{mode} left a partial target transaction.")
    assert_business_trigger_enabled(database)


def assert_commit_response_loss_is_idempotent(database):
    committed = row(8202, "COMMIT-RESPONSE-LOSS", "Commit survives response loss")
    generated = generate_sql(database, rows=[committed])
    context_hex = "0x53514C53594E43434F4D4D4954"
    host_name = f"SQLSYNC_FAULT_{context_hex[2:]}"
    marker = "  SELECT N'__SQL_SYNC_INSERTED__='"
    delayed = inject_sql_once(
        generated,
        marker,
        f"  SET CONTEXT_INFO {context_hex};\n  WAITFOR DELAY '00:00:30';",
    )
    with tempfile.NamedTemporaryFile(
        "w",
        suffix=".sql",
        encoding="utf-8",
        delete=False,
        dir=HARNESS_DIR if CONTAINER_SQLCMD else None,
    ) as handle:
        handle.write(delayed)
        sql_path = Path(handle.name)
    process = subprocess.Popen(
        generated_sql_command(sql_path, host_name=host_name),
        cwd=ROOT,
        text=True,
        encoding="utf-8",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        spid = wait_for_fault_session(host_name, process)
        sqlcmd(f"KILL {spid};")
        process.communicate(timeout=45)
        if process.returncode == 0:
            raise AssertionError("Response-loss connection unexpectedly succeeded.")
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
        sql_path.unlink(missing_ok=True)
    if scalar_int(database, "SELECT COUNT(*) FROM dbo.SyncItems WHERE Id = 8202;") != 1:
        raise AssertionError("Committed row was lost when its response connection died.")
    apply(database, rows=[committed])
    if scalar_int(database, "SELECT COUNT(*) FROM dbo.SyncItems WHERE Id = 8202;") != 1:
        raise AssertionError("Retry after commit-response loss was not idempotent.")


def relational_rows(database, table):
    order = "ParentId" if table == "ParentItems" else "ParentId, ChildNo"
    result = sqlcmd(
        f"SET NOCOUNT ON; SELECT * FROM dbo.[{table}] ORDER BY {order} FOR JSON PATH;",
        database=database,
    )
    payload = "".join(line.strip() for line in result.stdout.splitlines())
    return json.loads(payload or "[]")


def run_relational_scenarios():
    reset_databases()
    parents = [
        {"ParentId": 1, "ExternalCode": "P-1", "Name": "Parent one"},
        {"ParentId": 2, "ExternalCode": "P-2", "Name": "Parent two"},
    ]
    children = [
        {"ParentId": 1, "ChildNo": 1, "ExternalCode": "C-1-1", "Value": "1.2500", "ArabicText": "طفل"},
        {"ParentId": 1, "ChildNo": 2, "ExternalCode": "C-1-2", "Value": "2.5000", "ArabicText": "بيانات"},
    ]
    for database in DATABASES:
        apply(
            database,
            rows=parents,
            table="ParentItems",
            columns=PARENT_COLUMNS,
            primary_key_columns=["ParentId"],
        )
        apply(
            database,
            rows=children,
            table="ChildItems",
            columns=CHILD_COLUMNS,
            primary_key_columns=["ParentId", "ChildNo"],
        )
    before = relational_rows(DATABASES[0], "ChildItems")
    invalid_batch = [
        {"ParentId": 1, "ChildNo": 3, "ExternalCode": "C-VALID-SIBLING", "Value": "3.0000", "ArabicText": "صحيح"},
        {"ParentId": 999, "ChildNo": 1, "ExternalCode": "C-BAD-FK", "Value": "4.0000", "ArabicText": "مرفوض"},
    ]
    generated = generate_sql(
        DATABASES[0],
        rows=invalid_batch,
        table="ChildItems",
        columns=CHILD_COLUMNS,
        primary_key_columns=["ParentId", "ChildNo"],
    )
    if execute_generated_sql(generated, check=False).returncode == 0:
        raise AssertionError("Foreign-key violation unexpectedly committed.")
    if relational_rows(DATABASES[0], "ChildItems") != before:
        raise AssertionError("Foreign-key failure partially applied sibling children.")
    for database in DATABASES:
        apply(
            database,
            deletes=[{"ParentId": 1}],
            table="ParentItems",
            columns=PARENT_COLUMNS,
            primary_key_columns=["ParentId"],
        )
        if relational_rows(database, "ChildItems"):
            raise AssertionError(f"Cascade delete did not remove children in {database}.")


def run_concurrency_scenarios(workers=12):
    reset_databases()
    initial = [
        row(8300, "HOT-8300", "Initial hot row"),
        row(8301, "HOT-8301", "Initial hot row"),
    ]
    apply(DATABASES[0], rows=initial)
    generated_batches = []
    for index in range(workers):
        generated_batches.append(
            generate_sql(
                DATABASES[0],
                rows=[
                    row(8300, "HOT-8300", f"Writer {index} hot row"),
                    row(8301, "HOT-8301", f"Writer {index} second hot row"),
                    row(8400 + index, f"WORKER-{index:02d}", f"Writer {index} sibling"),
                ],
            )
        )
    start_gate = threading.Event()

    def execute_batch(generated):
        start_gate.wait()
        return execute_generated_sql(generated, check=False)

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(execute_batch, generated) for generated in generated_batches]
        start_gate.set()
        results = [future.result(timeout=120) for future in futures]
    failures = [
        (index, result)
        for index, result in enumerate(results)
        if result.returncode != 0
    ]
    for index, _ in failures:
        # A deadlock victim is retryable; retry the complete atomic batch.
        execute_generated_sql(generated_batches[index])
    sibling_count = scalar_int(
        DATABASES[0],
        f"SELECT COUNT(*) FROM dbo.SyncItems WHERE Id BETWEEN 8400 AND {8399 + workers};",
    )
    if sibling_count != workers:
        raise AssertionError(
            f"Concurrent transactions lost siblings: expected {workers}, got {sibling_count}."
        )
    canonical = [
        row(8300, "HOT-8300", "Deterministic final winner"),
        row(8301, "HOT-8301", "Deterministic final winner"),
    ]
    for database in DATABASES:
        apply(database, rows=[*canonical, *[
            row(8400 + index, f"WORKER-{index:02d}", f"Writer {index} sibling")
            for index in range(workers)
        ]])
    assert_equal(*DATABASES)


def fuzz_value(rng, identifier, revision):
    unicode_values = ["العربية", "漢字", "emoji 🌍", "line\u001fseparator", None]
    return row(
        identifier,
        f"FUZZ-{identifier}",
        None if rng.random() < 0.2 else f"revision-{revision}-{rng.randrange(100000)}",
        arabic=rng.choice(unicode_values),
        quantity=None if rng.random() < 0.2 else rng.randint(-100000, 100000),
        amount=f"{rng.randint(-99999999, 99999999) / 100:.2f}",
        changed_at=f"2026-07-{1 + revision % 28:02d}T12:34:56.{revision % 1000:03d}",
        payload=f"0x{rng.randbytes(12).hex()}",
    )


def run_fuzz_scenarios(*, seed=20260731, rounds=30):
    reset_databases()
    for database in DATABASES:
        apply(database, deletes=[{"Id": 1}])
    rng = random.Random(seed)
    model = {}
    for revision in range(rounds):
        identifiers = rng.sample(range(8500, 8580), rng.randint(4, 12))
        rows = []
        deletes = []
        for identifier in identifiers:
            if identifier in model and rng.random() < 0.3:
                deletes.append({"Id": identifier})
                model.pop(identifier, None)
            else:
                value = fuzz_value(rng, identifier, revision)
                rows.append(value)
                model[identifier] = value
        for database in DATABASES:
            apply(database, rows=rows, deletes=deletes)
        if revision % 5 == 0:
            assert_equal(*DATABASES)
    assert_equal(*DATABASES)
    expected = len(model)
    for database in DATABASES:
        actual = scalar_int(database, "SELECT COUNT(*) FROM dbo.SyncItems;")
        if actual != expected:
            raise AssertionError(
                f"Seeded fuzz model mismatch in {database}: expected {expected}, got {actual}."
            )

    operations = []
    expected_names = {}
    for identifier in range(8600, 8620):
        for revision in range(5):
            value = row(identifier, f"NETWORK-{identifier}", f"revision-{revision}")
            value["__sync_modified_at_utc"] = (
                f"2026-07-31T12:00:{revision:02d}.{identifier % 1000:03d}Z"
            )
            operations.extend([dict(value), dict(value)])
            expected_names[identifier] = f"revision-{revision}"
    rng.shuffle(operations)
    winners = coalesce(operations)
    if len(winners) != len(expected_names):
        raise AssertionError("Duplicate/reordered delivery changed winner cardinality.")
    for winner in winners:
        if winner["Name"] != expected_names[winner["Id"]]:
            raise AssertionError(f"Reordered delivery selected the wrong winner: {winner}")
    for database in DATABASES:
        apply(database, rows=winners)
        apply(database, rows=winners)
    assert_equal(*DATABASES)


def run_scale_scenario(row_count=5000):
    reset_databases()
    for offset in range(0, row_count, 500):
        batch = [
            row(
                100000 + index,
                f"SCALE-{index:07d}",
                f"Scale row {index}",
                quantity=index,
                arabic="بيانات كبيرة",
            )
            for index in range(offset, min(offset + 500, row_count))
        ]
        for database in DATABASES:
            apply(database, rows=batch)
    assert_equal(*DATABASES)
    expected = row_count + 1
    actual = scalar_int(DATABASES[0], "SELECT COUNT(*) FROM dbo.SyncItems;")
    if actual != expected:
        raise AssertionError(f"Scale row count mismatch: expected {expected}, got {actual}.")


def run_soak_scenario(*, seconds=60, seed=20260731):
    reset_databases()
    for database in DATABASES:
        apply(database, deletes=[{"Id": 1}])
    rng = random.Random(seed)
    model = {}
    deadline = time.time() + seconds
    iteration = 0
    while time.time() < deadline:
        identifiers = rng.sample(range(8700, 8800), 10)
        rows = []
        deletes = []
        for identifier in identifiers:
            if identifier in model and rng.random() < 0.25:
                deletes.append({"Id": identifier})
                model.pop(identifier, None)
            else:
                value = fuzz_value(rng, identifier, iteration)
                rows.append(value)
                model[identifier] = value
        apply(DATABASES[0], rows=rows, deletes=deletes)
        apply(DATABASES[1], rows=rows, deletes=deletes)
        if iteration % 3 != 0:
            apply(DATABASES[2], rows=rows, deletes=deletes)
        if iteration % 7 == 0:
            apply(
                DATABASES[2],
                rows=list(model.values()),
                deletes=[{"Id": identifier} for identifier in range(8700, 8800) if identifier not in model],
            )
        if iteration % 10 == 0:
            before = table_rows(DATABASES[0])
            expect_apply_failure(
                DATABASES[0],
                rows=[row(8999, "SOAK-REJECT", "X" * 101)],
            )
            if table_rows(DATABASES[0]) != before:
                raise AssertionError("Soak rejection left a partial transaction.")
        iteration += 1
    for database in DATABASES:
        apply(
            database,
            rows=list(model.values()),
            deletes=[{"Id": identifier} for identifier in range(8700, 8800) if identifier not in model],
        )
    assert_equal(*DATABASES)
    for database in DATABASES:
        assert_business_trigger_enabled(database)
    return iteration


def run_robustness_scenarios(*, include_restart=True, fuzz_rounds=30, scale_rows=5000):
    reset_databases()
    insert_marker = "  WITH CHANGE_TRACKING_CONTEXT (0x53514C53594E43)\nINSERT INTO"
    assert_atomic_fault_rollback(DATABASES[0], insert_marker, "between-update-insert")
    assert_atomic_fault_rollback(DATABASES[0], "  COMMIT TRANSACTION;", "before-commit")
    assert_connection_loss_atomicity(DATABASES[0])
    if include_restart:
        assert_connection_loss_atomicity(DATABASES[0], restart_sql=True)
    assert_commit_response_loss_is_idempotent(DATABASES[0])
    run_concurrency_scenarios()
    run_relational_scenarios()
    run_fuzz_scenarios(rounds=fuzz_rounds)
    run_scale_scenario(scale_rows)
    scenarios = [
        "fault-between-update-insert-rollback",
        "fault-before-commit-rollback",
        "connection-kill-rollback",
        "commit-response-loss-idempotent-retry",
        "concurrent-overlapping-writers",
        "foreign-key-composite-key-atomic-rollback",
        "cascade-delete",
        "seeded-property-fuzz",
        "duplicate-reordered-delivery",
        f"scale-{scale_rows}-rows",
    ]
    if include_restart:
        scenarios.append("sql-restart-mid-transaction-rollback")
    print(json.dumps({"ok": True, "suite": "robustness", "scenarios": scenarios}))


def run_scenarios():
    reset_databases()
    assert_hex_row_transport(DATABASES[0])
    for database in DATABASES:
        assert_business_trigger_enabled(database)

    # Initial convergence is a true multi-writer union: every non-empty
    # client contributes its pre-existing rows, duplicate primary keys use
    # the normal deterministic winner policy, and every client receives the
    # same merged set before Change Tracking deltas begin.
    initial_client_rows = [
        [
            row(910, "BOOTSTRAP-C1", "Pre-existing on client 1"),
            {
                **row(913, "BOOTSTRAP-CONFLICT", "Older client 1 value"),
                "__sync_modified_at_utc": "2026-07-16T09:00:00Z",
            },
        ],
        [
            row(911, "BOOTSTRAP-C2", "Pre-existing on client 2"),
            {
                **row(913, "BOOTSTRAP-CONFLICT", "Newest client 2 value"),
                "__sync_modified_at_utc": "2026-07-16T09:00:02Z",
            },
        ],
        [
            row(912, "BOOTSTRAP-C3", "Pre-existing on client 3"),
            {
                **row(913, "BOOTSTRAP-CONFLICT", "Middle client 3 value"),
                "__sync_modified_at_utc": "2026-07-16T09:00:01Z",
            },
        ],
    ]
    for database, client_rows in zip(DATABASES, initial_client_rows):
        apply(database, rows=client_rows)
    initial_union = coalesce([
        value
        for client_rows in initial_client_rows
        for value in client_rows
    ])
    if len(initial_union) != 4:
        raise AssertionError(
            f"Initial multi-client union selected the wrong cardinality: {initial_union}"
        )
    stale_bootstrap_vs_delete = coalesce([
        {
            **row(914, "DELETED-BEFORE-UNION", "Must not be resurrected"),
            "__sync_modified_at_utc": "1970-01-01T00:00:00.000Z",
        },
        {
            "Id": 914,
            "__sync_op": "D",
            "__sync_modified_at_utc": "2026-07-16T09:00:03Z",
        },
    ])
    if (
        len(stale_bootstrap_vs_delete) != 1
        or stale_bootstrap_vs_delete[0].get("__sync_op") != "D"
    ):
        raise AssertionError(
            "A stale full-union row outranked a durable delete: "
            f"{stale_bootstrap_vs_delete}"
        )
    apply(DATABASES[0], rows=[row(914, "ZOMBIE-AFTER-DELETE", "Must be re-deleted")])
    for database in DATABASES:
        apply(database, deletes=stale_bootstrap_vs_delete)
        if scalar_int(database, "SELECT COUNT(*) FROM dbo.SyncItems WHERE Id = 914;") != 0:
            raise AssertionError(
                f"Durable tombstone did not remove a zombie full row from {database}."
            )
    for database in DATABASES:
        apply(database, rows=initial_union)
    assert_equal(*DATABASES)
    for database in DATABASES:
        if scalar_int(
            database,
            "SELECT COUNT(*) FROM dbo.SyncItems WHERE Id BETWEEN 910 AND 913;",
        ) != 4:
            raise AssertionError(
                f"Initial union did not retain every client's unique rows in {database}."
            )
    reset_databases()

    # Selective anti-entropy reads a complete consistent inventory but relays
    # only primary-key buckets proven to differ. Exercise the deterministic key
    # framing across three isolated clients and prove that unioning one bucket
    # converges without treating snapshot absence as deletion.
    def selective_bucket(id_):
        framed = json.dumps([["id", str(id_)]], separators=(",", ":"))
        digest = hashlib.sha256(framed.encode("utf-8")).digest()
        return int.from_bytes(digest[:4], "big") % 16

    grouped_ids = {}
    for candidate in range(8100, 8500):
        bucket = selective_bucket(candidate)
        grouped_ids.setdefault(bucket, []).append(candidate)
    selected_bucket, selected_ids = next(
        (bucket, ids) for bucket, ids in grouped_ids.items() if len(ids) >= 4
    )
    common_rows = [
        row(8000 + offset, f"RANGE-{offset}", f"Common {offset}")
        for offset in range(64)
    ]
    for database in DATABASES:
        apply(database, rows=common_rows)
    range_client_rows = []
    for index, database in enumerate(DATABASES):
        changed = {
            **row(
                selected_ids[index],
                f"RANGE-C{index + 1}",
                f"Client {index + 1} range row",
            ),
            "__sync_modified_at_utc": f"2026-08-21T10:00:0{index}Z",
        }
        apply(database, rows=[changed])
        range_client_rows.append(changed)
    selective_union = coalesce(range_client_rows)
    if any(
        selective_bucket(value["Id"]) != selected_bucket
        for value in selective_union
    ):
        raise AssertionError(
            "Selective range union escaped its deterministic primary-key bucket."
        )
    for database in DATABASES:
        apply(database, rows=selective_union)
    assert_equal(*DATABASES)
    if any(
        scalar_int(database, "SELECT COUNT(*) FROM dbo.SyncItems;") != 68
        for database in DATABASES
    ):
        raise AssertionError(
            "Selective range convergence removed a snapshot-absent row."
        )

    # accepted-winner-chunk-pruning-three-client-safety: the server may omit a
    # stored full-union chunk only when its durable accepted-operation set is
    # empty. Prove that pruning no-effect inventory pages preserves unrelated
    # target-only rows, still relays an accepted upsert and an explicit exact-
    # key tombstone, and remains idempotent after an interrupted retry.
    protected_rows = [
        row(8600 + index, f"PROTECTED-{index}", f"Client {index} target-only")
        for index in range(len(DATABASES))
    ]
    for database, protected in zip(DATABASES, protected_rows):
        apply(database, rows=[protected])
    accepted_upsert = {
        **row(8700, "ACCEPTED-WINNER", "Only accepted winner is relayed"),
        "__sync_operation_id": "accepted-upsert",
    }
    accepted_delete = {
        "Id": 8000,
        "__sync_op": "D",
        "__sync_operation_id": "accepted-delete",
        "__sync_modified_at_utc": "2026-08-21T12:30:00Z",
    }
    relay_chunks = [
        {
            "rows": [
                {**value, "__sync_operation_id": f"stale-{value['Id']}"}
                for value in common_rows[:32]
            ],
            "accepted": set(),
        },
        {
            "rows": [accepted_upsert, *[
                {**value, "__sync_operation_id": f"stale-tail-{value['Id']}"}
                for value in common_rows[32:48]
            ]],
            "accepted": {"accepted-upsert"},
        },
        {
            "rows": [accepted_delete],
            "accepted": {"accepted-delete"},
        },
    ]
    pruned_chunks = [chunk for chunk in relay_chunks if chunk["accepted"]]
    if len(pruned_chunks) != 2:
        raise AssertionError("Zero-winner union chunks were not pruned.")
    relayed_rows = [
        value
        for chunk in pruned_chunks
        for value in chunk["rows"]
        if value.get("__sync_operation_id") in chunk["accepted"]
        and value.get("__sync_op") != "D"
    ]
    relayed_deletes = [
        value
        for chunk in pruned_chunks
        for value in chunk["rows"]
        if value.get("__sync_operation_id") in chunk["accepted"]
        and value.get("__sync_op") == "D"
    ]
    for database in DATABASES:
        apply(database, rows=relayed_rows, deletes=relayed_deletes)
        apply(database, rows=relayed_rows, deletes=relayed_deletes)
    for database, protected in zip(DATABASES, protected_rows):
        if scalar_int(
            database,
            f"SELECT COUNT(*) FROM dbo.SyncItems WHERE Id = {protected['Id']};",
        ) != 1:
            raise AssertionError(
                "Pruned canonical relay removed a target-only row."
            )
        if scalar_int(
            database,
            "SELECT COUNT(*) FROM dbo.SyncItems WHERE Id = 8000;",
        ) != 0:
            raise AssertionError(
                "Accepted explicit tombstone was lost during chunk pruning."
            )
        if scalar_int(
            database,
            "SELECT COUNT(*) FROM dbo.SyncItems WHERE Id = 8700;",
        ) != 1:
            raise AssertionError(
                "Accepted winner row was lost during chunk pruning."
            )
    reset_databases()

    inserted = row(2, "INSERT-2", "Inserted on client 1", arabic="إضافة جديدة")
    for database in DATABASES[1:]:
        apply(database, rows=[inserted])
    apply(DATABASES[0], rows=[inserted])
    assert_equal(*DATABASES)
    for database in DATABASES:
        assert_text_value(database, 2, inserted["ArabicText"])

    updated = row(2, "INSERT-2", "Updated on client 2", arabic="تحديث صحيح", quantity=9)
    for database in DATABASES:
        apply(database, rows=[updated])
    assert_equal(*DATABASES)
    for database in DATABASES:
        assert_text_value(database, 2, updated["ArabicText"])

    # SQL Change Tracking represents a primary-key edit as delete-old plus insert-new.
    key_changed = row(20, "INSERT-2", "Primary key changed", arabic="تغيير المفتاح", quantity=10)
    for database in DATABASES:
        apply(database, deletes=[{"Id": 2}], rows=[key_changed])
    assert_equal(*DATABASES)

    for database in DATABASES:
        apply(database, deletes=[{"Id": 20}])
        apply(database, deletes=[{"Id": 999999}])
        apply(database)
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

    # Ameen edits an invoice line by deleting its GUID and inserting a new GUID.
    # Standard SQL identity is the primary key, so concurrent new GUIDs remain
    # independent unless a later explicit tombstone names one of them.
    invoice_guid = "181B8328-0A14-410B-9CF9-79223B0F3015"
    old_guids = [
        "3F781CBB-66A5-461A-A92C-8F5EBF77968B",
        "29CD3432-CC0B-451F-A1E4-B2AFDD272143",
    ]
    c1_guids = [
        "746F387F-C9CC-4162-AC5C-911411664846",
        "2A1A97F2-7EE7-4B41-A1AD-99585BB55C28",
    ]
    c2_guids = [
        "133DDFF9-9AD6-40C6-A2B4-1DBEF0219F4D",
        "D6351269-D0CF-47DB-AC30-164DF64EEDAA",
    ]

    def invoice_rows(guids, quantity, arabic):
        return [
            {
                "GUID": guids[number],
                "ParentGUID": invoice_guid,
                "Number": number,
                "Quantity": str(quantity),
                "ArabicText": arabic,
            }
            for number in range(2)
        ]

    local_invoice_rows = [
        invoice_rows(c1_guids, 123, "تعديل العميل الأول"),
        invoice_rows(c2_guids, 234, "تعديل العميل الثاني"),
        invoice_rows(old_guids, 1, "القيمة الأصلية"),
    ]
    for database, rows_for_client in zip(DATABASES, local_invoice_rows):
        apply(
            database,
            rows=rows_for_client,
            table="InvoiceLines",
            columns=INVOICE_LINE_COLUMNS,
            primary_key_columns=["GUID"],
        )

    merged_invoice_delta = coalesce(
        [
            *[
                {
                    "GUID": guid,
                    "__sync_op": "D",
                    "__sync_modified_at_utc": "2026-07-24T18:31:00Z",
                }
                for guid in old_guids
            ],
            *[
                {
                    **row_value,
                    "__sync_modified_at_utc": "2026-07-24T18:31:06.543Z",
                    "__sync_origin_client": "c1",
                }
                for row_value in invoice_rows(c1_guids, 123, "تعديل العميل الأول")
            ],
            *[
                {
                    **row_value,
                    "__sync_modified_at_utc": "2026-07-24T18:31:27.920Z",
                    "__sync_origin_client": "c2",
                }
                for row_value in invoice_rows(c2_guids, 234, "تعديل العميل الثاني")
            ],
        ],
        primary_key_columns=["GUID"],
    )
    deletes = [
        row_value for row_value in merged_invoice_delta
        if row_value.get("__sync_op") == "D"
    ]
    upserts = [
        row_value for row_value in merged_invoice_delta
        if row_value.get("__sync_op") != "D"
    ]
    if len(deletes) != 2 or len(upserts) != 4:
        raise AssertionError(
            f"Invoice primary-key reconciliation selected invalid winners: {merged_invoice_delta}"
        )
    for database in DATABASES:
        apply(
            database,
            rows=upserts,
            deletes=deletes,
            table="InvoiceLines",
            columns=INVOICE_LINE_COLUMNS,
            primary_key_columns=["GUID"],
        )
    invoice_snapshots = {
        database: invoice_line_rows(database) for database in DATABASES
    }
    if any(len(rows_for_client) != 4 for rows_for_client in invoice_snapshots.values()):
        raise AssertionError(
            f"Invoice primary-key union produced the wrong cardinality: {invoice_snapshots}"
        )
    if len({tuple(rows_for_client) for rows_for_client in invoice_snapshots.values()}) != 1:
        raise AssertionError(
            f"Invoice line replacement did not converge: {invoice_snapshots}"
        )
    expected_arabic_hex = "تعديل العميل الثاني".encode("utf-16-le").hex().upper()
    if sum(
        "|234.00|" in row_value and row_value.endswith(expected_arabic_hex)
        for row_value in invoice_snapshots[DATABASES[0]]
    ) != 2:
        raise AssertionError(
            f"Invoice winner values or Arabic text changed: {invoice_snapshots}"
        )
    for database in DATABASES:
        apply(
            database,
            rows=upserts,
            deletes=deletes,
            table="InvoiceLines",
            columns=INVOICE_LINE_COLUMNS,
            primary_key_columns=["GUID"],
        )
    if invoice_line_rows(DATABASES[0]) != invoice_snapshots[DATABASES[0]]:
        raise AssertionError("Invoice explicit replacement retry was not idempotent.")

    exact_unicode = "العربية 🌍 漢字"
    typed_row = row(
        31,
        "TYPES",
        None,
        arabic=exact_unicode,
        quantity=None,
        amount="1234567890123.45",
        changed_at="2026-07-16T23:59:59.987",
        payload="0x00FF102030405060708090A0B0C0D0E0F0",
    )
    for database in DATABASES:
        apply(database, rows=[typed_row])
        assert_text_value(database, 31, exact_unicode)
        assert_unicode_hex_transport(database, 31, exact_unicode)
    assert_equal(*DATABASES)

    # Exercise the production SQL capture expression against a real float/real
    # boundary. Default SQL conversion rounds 9999999 to 1e+007; style 3 must
    # retain the original value through capture, JSON transport, and target apply.
    sqlcmd(
        """
INSERT dbo.SyncItems
  (Id, Code, Name, ArabicText, Quantity, Amount, FloatValue, RealValue, ChangedAt, Payload)
VALUES
  (36, N'FLOAT-ROUNDTRIP', N'Lossless float capture', N'دقة الأرقام',
   1, 1.25, CAST(9999999 AS float), CAST(9999999 AS real),
   '2026-07-16T23:59:59.987', 0x999999),
  (37, N'FLOAT-NEGATIVE', N'Lossless negative float', N'دقة سالبة',
   1, 1.25, CAST(-9999999 AS float), CAST(-9999999 AS real),
   '2026-07-16T23:59:59.987', 0x999998),
  (38, N'FLOAT-FRACTION', N'Lossless fractional float', N'دقة عشرية',
   1, 1.25, CAST(0.84551240822557006 AS float), CAST(0.84551240822557006 AS real),
   '2026-07-16T23:59:59.987', 0x999997);
""",
        database=DATABASES[0],
    )
    float_cases = [
        (36, "FLOAT-ROUNDTRIP", "Lossless float capture", "دقة الأرقام", "9999999", "0x999999"),
        (37, "FLOAT-NEGATIVE", "Lossless negative float", "دقة سالبة", "-9999999", "0x999998"),
        (38, "FLOAT-FRACTION", "Lossless fractional float", "دقة عشرية", "0.84551240822557006", "0x999997"),
    ]
    for id_, code, name, arabic, expected, payload in float_cases:
        captured_float, captured_real = capture_float_transport_values(DATABASES[0], id_)
        if (
            captured_float.lower() in ("1e+007", "1e+7", "-1e+007", "-1e+7")
            or captured_real.lower() in ("1e+007", "1e+7", "-1e+007", "-1e+7")
        ):
            raise AssertionError(
                f"Lossy floating-point transport detected for {expected}: "
                f"float={captured_float}, real={captured_real}"
            )
        float_row = row(
            id_,
            code,
            name,
            arabic=arabic,
            float_value=captured_float,
            real_value=captured_real,
            changed_at="2026-07-16T23:59:59.987",
            payload=payload,
        )
        for database in DATABASES:
            apply(database, rows=[float_row])
            assert_float_values(database, id_, expected)
    assert_equal(*DATABASES)

    # Historical same-key float drift can exist after every client has already
    # advanced its Change Tracking cursor, so the next delta is legitimately
    # empty. A fresh complete inventory must still detect it and a durable
    # latest winner must converge all three clients without inferring deletes.
    historical_id = 41
    for database in DATABASES:
        apply(
            database,
            rows=[
                row(
                    historical_id,
                    "HISTORICAL-FLOAT-DRIFT",
                    "Same PK, no later CT delta",
                    float_value="13934625",
                    real_value="13934625",
                )
            ],
        )
    apply(
        DATABASES[0],
        rows=[
            row(
                historical_id,
                "HISTORICAL-FLOAT-DRIFT",
                "Same PK, no later CT delta",
                float_value="13934600",
                real_value="13934600",
            )
        ],
    )
    settled_versions = {
        database: scalar_int(database, "SELECT CHANGE_TRACKING_CURRENT_VERSION();")
        for database in DATABASES
    }
    for database, settled_version in settled_versions.items():
        pending = scalar_int(
            database,
            f"SELECT COUNT(*) FROM CHANGETABLE(CHANGES dbo.SyncItems, {settled_version}) AS CT;",
        )
        if pending != 0:
            raise AssertionError(
                f"Historical-drift setup did not produce an empty delta on {database}."
            )
    physical_values = {
        database: capture_float_transport_values(database, historical_id)[0]
        for database in DATABASES
    }
    if len(set(physical_values.values())) != 2:
        raise AssertionError(
            f"Fresh lossless inventory did not expose historical float drift: {physical_values}"
        )
    historical_winner = {
        **row(
            historical_id,
            "HISTORICAL-FLOAT-DRIFT",
            "Same PK, no later CT delta",
            float_value="13934625",
            real_value="13934625",
        ),
        "__sync_modified_at_utc": "2026-08-22T22:54:36Z",
    }
    for database in DATABASES:
        apply(database, rows=[historical_winner])
        assert_float_values(database, historical_id, "13934625")
    assert_equal(*DATABASES)

    multi_writer_rows = coalesce([
        {**row(32, "WRITER-C1", "Written by c1"), "__sync_modified_at_utc": "2026-07-16T10:00:00Z"},
        {**row(33, "WRITER-C2", "Written by c2"), "__sync_modified_at_utc": "2026-07-16T10:00:00Z"},
    ])
    if len(multi_writer_rows) != 2:
        raise AssertionError(f"Independent writer rows were lost: {multi_writer_rows}")
    for database in DATABASES:
        apply(database, rows=multi_writer_rows)
    assert_equal(*DATABASES)

    # Different permanent IDs that collide on a SQL unique/business key use
    # the same deterministic latest-change winner as ordinary row conflicts.
    # Only the older conflicting identity is replaced; valid siblings commit
    # in the same atomic transaction.
    identity_collision = coalesce([
        {**row(34, "SAME-BUSINESS-KEY", "Created by c1"), "__sync_modified_at_utc": "2026-07-16T10:00:00Z"},
        {**row(35, "SAME-BUSINESS-KEY", "Created by c2"), "__sync_modified_at_utc": "2026-07-16T10:00:01Z"},
    ], unique_key_column_sets=[["Code"]])
    if len(identity_collision) != 1 or identity_collision[0]["Id"] != 35:
        raise AssertionError(f"Latest unique-key winner was not selected: {identity_collision}")
    for database in DATABASES:
        apply(database, rows=[row(34, "SAME-BUSINESS-KEY", "Created by c1")])
        apply(
            database,
            rows=[
                identity_collision[0],
                row(39, "VALID-SIBLING", "Commits with latest winner"),
            ],
            unique_index_column_sets=[["Code"]],
            resolve_unique_conflicts_latest_wins=True,
        )
        current = table_rows(database)
        if any("34|SAME-BUSINESS-KEY" in value for value in current):
            raise AssertionError(f"Older unique-key identity survived in {database}: {current}")
        if not any("35|SAME-BUSINESS-KEY|Created by c2" in value for value in current):
            raise AssertionError(f"Latest unique-key identity is missing in {database}: {current}")
        if not any("39|VALID-SIBLING|Commits with latest winner" in value for value in current):
            raise AssertionError(f"Atomic sibling row is missing in {database}: {current}")
    assert_equal(*DATABASES)

    # A user edit made after this client uploaded protects the older local
    # business-key identity for the current pass. The incoming replacement is
    # deferred and will compete normally after that local edit uploads.
    for database in DATABASES:
        apply(database, rows=[row(36, "PROTECTED-BUSINESS-KEY", "Before upload")])
        baseline = scalar_int(database, "SELECT CHANGE_TRACKING_CURRENT_VERSION();")
        sqlcmd(
            """
DISABLE TRIGGER dbo.TR_SyncItems_Protect ON dbo.SyncItems;
UPDATE dbo.SyncItems SET Name = N'Local after upload' WHERE Id = 36;
ENABLE TRIGGER dbo.TR_SyncItems_Protect ON dbo.SyncItems;
""",
            database=database,
        )
        output = apply(
            database,
            rows=[row(37, "PROTECTED-BUSINESS-KEY", "Remote replacement")],
            unique_index_column_sets=[["Code"]],
            protect_local_changes_after_version=baseline,
            resolve_unique_conflicts_latest_wins=True,
        )
        if "__SQL_SYNC_PROTECTED__=1" not in output:
            raise AssertionError(f"Expected protected business-key replacement in {database}: {output}")
        protected = table_rows(database)
        if not any("36|PROTECTED-BUSINESS-KEY|Local after upload" in value for value in protected):
            raise AssertionError(f"Post-upload business-key edit was not preserved in {database}: {protected}")
        if any("37|PROTECTED-BUSINESS-KEY" in value for value in protected):
            raise AssertionError(f"Deferred business-key replacement was inserted in {database}: {protected}")
        sqlcmd(
            """
DISABLE TRIGGER dbo.TR_SyncItems_Protect ON dbo.SyncItems;
DELETE dbo.SyncItems WHERE Id IN (36, 37);
ENABLE TRIGGER dbo.TR_SyncItems_Protect ON dbo.SyncItems;
""",
            database=database,
        )
    assert_equal(*DATABASES)

    # Client 3 remains offline while clients 1 and 2 exchange independent
    # writes normally. The complete missed range is then replayed once when
    # client 3 reconnects.
    client_1_offline_window_row = {
        **row(40, "OFFLINE-C1", "Written by client 1 while client 3 is offline"),
        "__sync_modified_at_utc": "2026-07-16T11:00:00Z",
    }
    client_2_offline_window_row = {
        **row(
            41,
            "OFFLINE-C2",
            "Written by client 2 while client 3 is offline",
            arabic="عميل غير متصل",
        ),
        "__sync_modified_at_utc": "2026-07-16T11:00:01Z",
    }
    apply(DATABASES[0], rows=[client_1_offline_window_row])
    apply(DATABASES[1], rows=[client_1_offline_window_row])
    if table_rows(DATABASES[0]) != table_rows(DATABASES[1]):
        raise AssertionError("An offline peer blocked client 1 changes from reaching client 2.")
    apply(DATABASES[1], rows=[client_2_offline_window_row])
    apply(DATABASES[0], rows=[client_2_offline_window_row])
    if table_rows(DATABASES[0]) != table_rows(DATABASES[1]):
        raise AssertionError("An offline peer blocked client 2 changes from reaching client 1.")
    if table_rows(DATABASES[2]) == table_rows(DATABASES[0]):
        raise AssertionError("Offline client unexpectedly changed before reconnecting.")
    accumulated_offline_delta = coalesce(
        [client_1_offline_window_row, client_2_offline_window_row]
    )
    apply(DATABASES[2], rows=accumulated_offline_delta)
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

    # A complete reconciliation inserts/updates its incoming rows while always
    # preserving target-only rows. Repeating it remains idempotent.
    authoritative_rows = [
        row(
            7001,
            "AUTHORITATIVE-AR",
            "Authoritative Arabic row",
            arabic="البيانات العربية الصحيحة",
            quantity=77,
        ),
        row(7002, "AUTHORITATIVE-2", "Second authoritative row"),
    ]
    apply(DATABASES[0], rows=authoritative_rows)
    apply(DATABASES[2], rows=authoritative_rows)
    target_only_row = row(7999, "TARGET-ONLY", "Must be preserved")
    apply(
        DATABASES[1],
        rows=[target_only_row],
    )
    apply(
        DATABASES[1],
        rows=authoritative_rows,
        unique_index_column_sets=[["Code"]],
    )
    if not any("TARGET-ONLY" in line for line in table_rows(DATABASES[1])):
        raise AssertionError("Complete reconciliation deleted a target-only row.")
    assert_text_value(DATABASES[1], 7001, authoritative_rows[0]["ArabicText"])
    authoritative_once = table_rows(DATABASES[1])
    apply(
        DATABASES[1],
        rows=authoritative_rows,
        unique_index_column_sets=[["Code"]],
    )
    if table_rows(DATABASES[1]) != authoritative_once:
        raise AssertionError("Complete reconciliation retry was not idempotent.")
    apply(DATABASES[0], rows=[target_only_row])
    apply(DATABASES[2], rows=[target_only_row])
    assert_equal(*DATABASES)

    before_failure = table_rows(DATABASES[0])
    expect_apply_failure(
        DATABASES[0],
        rows=[row(5000, "REJECTED", "X" * 101)],
    )
    assert_business_trigger_enabled(DATABASES[0])
    if table_rows(DATABASES[0]) != before_failure:
        raise AssertionError("Rejected delta partially modified the target database.")
    recovery_row = row(5001, "RECOVERY", "Valid row after rejected delta")
    apply(DATABASES[0], rows=[recovery_row])
    for database in DATABASES[1:]:
        apply(database, rows=[recovery_row])
    assert_equal(*DATABASES)

    assert_post_upload_overlap_protection(DATABASES[0])
    assert_equal(*DATABASES)

    assert_context_filtered(DATABASES[0])
    print(json.dumps({
        "ok": True,
        "clients": len(DATABASES),
        "scenarios": [
            "insert", "update", "primary-key-change", "delete",
            "explicit-delete-of-missing-key-is-idempotent", "empty-delta", "newest-commit-conflict",
            "exact-unicode-arabic-emoji-cjk", "null-binary-decimal-datetime",
            "framed-hex-control-character-row-transport",
            "lossless-float-real-9999999-capture-roundtrip",
            "empty-delta-fresh-inventory-repairs-historical-float-drift",
            "initial-three-client-primary-key-union-bootstrap",
            "selective-range-three-client-convergence",
            "accepted-winner-chunk-pruning-three-client-safety",
            "full-union-does-not-resurrect-durable-delete",
            "durable-delete-reasserts-against-zombie-full-row",
            "independent-multi-writer",
            "offline-peer-online-continuity-and-reconnect-catch-up",
            "latest-unique-business-key-winner-atomic-replacement",
            "invoice-line-primary-key-union-explicit-delete-arabic-atomic-retry",
            "large-1200-row-batch", "idempotent-retry",
            "complete-reconcile-preserves-target-only-unicode-retry",
            "rejected-row-rollback-and-recovery", "change-context",
            "post-upload-overlap-row-protection",
            "business-trigger-bypass-and-restore",
        ],
        "finalRowCount": len(table_rows(DATABASES[0])),
    }, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true", help="Keep the SQL container running after tests.")
    parser.add_argument(
        "--external",
        action="store_true",
        help="Use SQL_SYNC_TEST_SERVER instead of managing the Compose service.",
    )
    parser.add_argument(
        "--suite",
        choices=("standard", "robustness", "soak", "all"),
        default="standard",
    )
    parser.add_argument("--soak-seconds", type=int, default=60)
    parser.add_argument("--fuzz-rounds", type=int, default=30)
    parser.add_argument("--scale-rows", type=int, default=5000)
    parser.add_argument(
        "--skip-sql-restart",
        action="store_true",
        help="Skip the SQL service restart fault (for externally managed servers).",
    )
    args = parser.parse_args()
    if DOCKER is None or (SQLCMD is None and args.external) or DART is None:
        required = [
            name
            for name, executable in (("sqlcmd", SQLCMD), ("dart", DART))
            if executable is None and (name != "sqlcmd" or args.external)
        ]
        if not args.external and DOCKER is None:
            required.append("docker")
        if required:
            raise SystemExit(f"Required tools are unavailable: {', '.join(required)}.")
    if args.soak_seconds < 1 or args.fuzz_rounds < 1 or args.scale_rows < 1:
        raise SystemExit("soak-seconds, fuzz-rounds, and scale-rows must be positive.")
    if not args.external:
        # A prior interrupted run can leave the disposable SQL volume or
        # container behind. Reset only this harness-owned Compose project so
        # every invocation starts with fresh client databases and cannot fail
        # on stale tables from an earlier local run.
        run(COMPOSE + ["down", "-v"], check=False)
        run(COMPOSE + ["up", "-d"])
    try:
        wait_for_sql()
        if args.suite in ("standard", "all"):
            run_scenarios()
            run_windows_bulk_stage_performance_regression()
        if args.suite in ("robustness", "all"):
            run_robustness_scenarios(
                include_restart=not args.skip_sql_restart,
                fuzz_rounds=args.fuzz_rounds,
                scale_rows=args.scale_rows,
            )
        if args.suite in ("soak", "all"):
            iterations = run_soak_scenario(seconds=args.soak_seconds)
            print(
                json.dumps(
                    {
                        "ok": True,
                        "suite": "soak",
                        "seconds": args.soak_seconds,
                        "iterations": iterations,
                    }
                )
            )
    finally:
        if not args.external and not args.keep:
            run(COMPOSE + ["down", "-v"], check=False)


if __name__ == "__main__":
    main()
