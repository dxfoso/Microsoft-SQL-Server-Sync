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
        "-d", database, "-b", "-r", "1",
        *(["-f", "65001"] if SQLCMD_SUPPORTS_INPUT_CODEPAGE else []),
        "-h", "-1", "-W", "-Q", sql,
    ]
    return run(command, check=check)

def sqlcmd_script(sql, *, database="master", check=True):
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
            SQLCMD, "-C", "-S", "localhost,14333", "-U", "sa", "-P", PASSWORD,
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
    delete_missing=False,
    unique_index_column_sets=None,
    table="SyncItems",
    columns=None,
    primary_key_columns=None,
    logical_identity_columns=None,
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
        "logicalIdentityColumns": logical_identity_columns or [],
        "uniqueIndexColumnSets": unique_index_column_sets or [],
        "rows": rows or [],
        "deletes": deletes or [],
        "deleteMissing": delete_missing,
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


def apply(
    database,
    *,
    rows=None,
    deletes=None,
    delete_missing=False,
    unique_index_column_sets=None,
    table="SyncItems",
    columns=None,
    primary_key_columns=None,
    logical_identity_columns=None,
):
    generated = generate_sql(
        database,
        rows=rows,
        deletes=deletes,
        delete_missing=delete_missing,
        unique_index_column_sets=unique_index_column_sets,
        table=table,
        columns=columns,
        primary_key_columns=primary_key_columns,
        logical_identity_columns=logical_identity_columns,
    )
    with tempfile.NamedTemporaryFile("w", suffix=".sql", encoding="utf-8", delete=False) as handle:
        handle.write(generated)
        sql_path = Path(handle.name)
    try:
        result = run([
            SQLCMD, "-C", "-S", "localhost,14333", "-U", "sa", "-P", PASSWORD,
            "-d", "master", "-b", "-r", "1",
            *(["-f", "65001"] if SQLCMD_SUPPORTS_INPUT_CODEPAGE else []),
            "-i", str(sql_path),
        ])
        return result.stdout
    finally:
        sql_path.unlink(missing_ok=True)


def coalesce(rows, *, primary_key_columns=None, logical_identity_columns=None):
    request = {
        "operation": "coalesce",
        "rows": rows,
        "primaryKeyColumns": primary_key_columns or ["Id"],
        "logicalIdentityColumns": logical_identity_columns or [],
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


def run_scenarios():
    reset_databases()
    assert_hex_row_transport(DATABASES[0])
    for database in DATABASES:
        assert_business_trigger_enabled(database)

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

    # Ameen edits an invoice line by deleting its GUID and inserting the same
    # ParentGUID + Number under a new GUID. Concurrent clients therefore need
    # logical replacement reconciliation, not a union of both generated GUIDs.
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
        logical_identity_columns=["ParentGUID", "Number"],
    )
    deletes = [
        row_value for row_value in merged_invoice_delta
        if row_value.get("__sync_op") == "D"
    ]
    upserts = [
        row_value for row_value in merged_invoice_delta
        if row_value.get("__sync_op") != "D"
    ]
    if len(deletes) != 2 or len(upserts) != 2:
        raise AssertionError(
            f"Invoice logical reconciliation selected invalid winners: {merged_invoice_delta}"
        )
    for database in DATABASES:
        apply(
            database,
            rows=upserts,
            deletes=deletes,
            table="InvoiceLines",
            columns=INVOICE_LINE_COLUMNS,
            primary_key_columns=["GUID"],
            logical_identity_columns=["ParentGUID", "Number"],
        )
    invoice_snapshots = {
        database: invoice_line_rows(database) for database in DATABASES
    }
    if any(len(rows_for_client) != 2 for rows_for_client in invoice_snapshots.values()):
        raise AssertionError(
            f"Invoice line replacement produced duplicates: {invoice_snapshots}"
        )
    if len({tuple(rows_for_client) for rows_for_client in invoice_snapshots.values()}) != 1:
        raise AssertionError(
            f"Invoice line replacement did not converge: {invoice_snapshots}"
        )
    expected_arabic_hex = "تعديل العميل الثاني".encode("utf-16-le").hex().upper()
    if any(
        "|234.00|" not in row_value or not row_value.endswith(expected_arabic_hex)
        for row_value in invoice_snapshots[DATABASES[0]]
    ):
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
            logical_identity_columns=["ParentGUID", "Number"],
        )
    if invoice_line_rows(DATABASES[0]) != invoice_snapshots[DATABASES[0]]:
        raise AssertionError("Invoice logical replacement retry was not idempotent.")

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

    multi_writer_rows = coalesce([
        {**row(32, "WRITER-C1", "Written by c1"), "__sync_modified_at_utc": "2026-07-16T10:00:00Z"},
        {**row(33, "WRITER-C2", "Written by c2"), "__sync_modified_at_utc": "2026-07-16T10:00:00Z"},
    ])
    if len(multi_writer_rows) != 2:
        raise AssertionError(f"Independent writer rows were lost: {multi_writer_rows}")
    for database in DATABASES:
        apply(database, rows=multi_writer_rows)
    assert_equal(*DATABASES)

    # Different permanent IDs are independent even when a business unique key
    # collides. The target constraint must reject the complete incoming table
    # delta atomically; sync must never coalesce it or partially apply siblings.
    identity_collision = coalesce([
        {**row(34, "SAME-BUSINESS-KEY", "Created by c1"), "__sync_modified_at_utc": "2026-07-16T10:00:00Z"},
        {**row(35, "SAME-BUSINESS-KEY", "Created by c2"), "__sync_modified_at_utc": "2026-07-16T10:00:01Z"},
    ])
    if len(identity_collision) != 2:
        raise AssertionError(f"Different permanent identities were silently collapsed: {identity_collision}")
    for database in DATABASES:
        apply(database, rows=[identity_collision[0]])
        before_collision = table_rows(database)
        expect_apply_failure(
            database,
            rows=[
                identity_collision[1],
                row(39, "VALID-SIBLING", "Must roll back with collision"),
            ],
        )
        current = table_rows(database)
        if current != before_collision:
            raise AssertionError(
                f"Identity collision partially applied its table delta in {database}: "
                f"before={before_collision}, after={current}"
            )
        if not any("34|SAME-BUSINESS-KEY|Created by c1" in value for value in current):
            raise AssertionError(f"Unique collision replaced the established identity in {database}: {current}")
        if any("35|SAME-BUSINESS-KEY" in value for value in current):
            raise AssertionError(f"Unique collision inserted a second invalid identity in {database}: {current}")
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

    # An authoritative reconciliation atomically replaces stale target-only
    # rows and remains idempotent when the same complete snapshot is retried.
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
    apply(DATABASES[0], rows=authoritative_rows, delete_missing=True)
    apply(DATABASES[2], rows=authoritative_rows, delete_missing=True)
    apply(
        DATABASES[1],
        rows=[
            row(7998, "AUTHORITATIVE-AR", "Old identity with winning business key"),
            row(7999, "STALE-TARGET", "Must be removed"),
        ],
    )
    apply(
        DATABASES[1],
        rows=authoritative_rows,
        delete_missing=True,
        unique_index_column_sets=[["Code"]],
    )
    if table_rows(DATABASES[1]) != [
        line for line in table_rows(DATABASES[1])
        if "STALE-TARGET" not in line
    ]:
        raise AssertionError("Authoritative replacement retained a stale target-only row.")
    assert_text_value(DATABASES[1], 7001, authoritative_rows[0]["ArabicText"])
    authoritative_once = table_rows(DATABASES[1])
    apply(
        DATABASES[1],
        rows=authoritative_rows,
        delete_missing=True,
        unique_index_column_sets=[["Code"]],
    )
    if table_rows(DATABASES[1]) != authoritative_once:
        raise AssertionError("Authoritative replacement retry was not idempotent.")
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

    assert_context_filtered(DATABASES[0])
    print(json.dumps({
        "ok": True,
        "clients": len(DATABASES),
        "scenarios": [
            "insert", "update", "primary-key-change", "delete",
            "missing-delete", "empty-delta", "newest-commit-conflict",
            "exact-unicode-arabic-emoji-cjk", "null-binary-decimal-datetime",
            "framed-hex-control-character-row-transport",
            "lossless-float-real-9999999-capture-roundtrip",
            "independent-multi-writer", "offline-catch-up",
            "guid-only-identity-unique-collision-atomic-failure",
            "invoice-line-logical-update-no-duplicate-arabic-atomic-retry",
            "large-1200-row-batch", "idempotent-retry",
            "authoritative-replace-unique-conflict-delete-missing-unicode-retry",
            "rejected-row-rollback-and-recovery", "change-context",
            "business-trigger-bypass-and-restore",
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
