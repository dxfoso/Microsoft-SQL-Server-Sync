[CmdletBinding()]
param(
    [string] $ServerInstance = '.\SQL8',
    [string] $Database = 'AmnDb048',
    [switch] $UseSqlAuthentication,
    [Management.Automation.PSCredential] $SqlCredential,
    [ValidateRange(5, 180)][int] $TimeoutMinutes = 90
)

$ErrorActionPreference = 'Stop'
$posGuid = '1123818D-A5AE-46D9-8A23-0220534CB2D5'
$purchaseGuid = '840E3295-ECBF-426B-828A-F4780D88C6F8'
$temporaryNumber = -2147482307
$sqlSyncContext = '0x53514C53594E43'
$credential = $SqlCredential

if ($null -ne $credential) {
    $UseSqlAuthentication = $true
} elseif ($UseSqlAuthentication) {
    $credential = Get-Credential -Message "SQL login for $ServerInstance"
}

function Invoke-RepairSql {
    param([Parameter(Mandatory = $true)][string] $Sql)

    $sqlcmd = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
    if ($null -eq $sqlcmd) { $sqlcmd = Get-Command sqlcmd -ErrorAction SilentlyContinue }
    if ($null -eq $sqlcmd) { throw 'sqlcmd is not installed or is not available on PATH.' }

    $tempPath = Join-Path ([IO.Path]::GetTempPath()) ("sql-sync-voucher-2307-{0}.sql" -f ([Guid]::NewGuid().ToString('N')))
    try {
        [IO.File]::WriteAllText($tempPath, $Sql, [Text.UTF8Encoding]::new($true))
        $arguments = @('-S', $ServerInstance, '-d', $Database, '-C', '-b', '-V', '16', '-W', '-h', '-1', '-u', '-i', $tempPath)
        if ($UseSqlAuthentication) {
            $plainPassword = $credential.GetNetworkCredential().Password
            $arguments = @('-U', $credential.UserName, '-P', $plainPassword) + $arguments
        } else {
            $arguments = @('-E') + $arguments
        }
        $result = @(& $sqlcmd.Source @arguments 2>&1 | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0) {
            throw "SQL repair command failed:`n$($result -join [Environment]::NewLine)"
        }
        return @($result | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
        $plainPassword = $null
    }
}

$stageSql = @"
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @pos uniqueidentifier = '$posGuid';
DECLARE @purchase uniqueidentifier = '$purchaseGuid';
DECLARE @temporary int = $temporaryNumber;
DECLARE @zero uniqueidentifier = '00000000-0000-0000-0000-000000000000';
DECLARE @priorErrorCount int;

IF EXISTS (
    SELECT 1 FROM dbo.ce000
    WHERE GUID=@pos AND Type=1 AND Number=2307 AND Debit=932000 AND Credit=932000
) AND EXISTS (
    SELECT 1 FROM dbo.ce000
    WHERE GUID=@purchase AND Type=1 AND Number>0 AND Number<>2307
      AND Debit=9531000 AND Credit=9531000
)
BEGIN
    SELECT 'SQLSYNC_V2307_COMPLETE|' + CONVERT(varchar(20),(SELECT Number FROM dbo.ce000 WHERE GUID=@purchase));
    RETURN;
END;

IF EXISTS (SELECT 1 FROM dbo.ce000 WHERE GUID=@pos AND Number=@temporary)
   AND EXISTS (SELECT 1 FROM dbo.ce000 WHERE GUID=@purchase AND Type=1 AND Number=2307 AND Debit=9531000 AND Credit=9531000)
BEGIN
    SELECT 'SQLSYNC_V2307_STAGED';
    RETURN;
END;

BEGIN TRY
    BEGIN TRAN;
    IF dbo.fnFlag_IsSet(1000)<>0 THROW 52301, 'Maintenance flag 1000 is already set.', 1;
    IF NOT EXISTS (
        SELECT 1 FROM dbo.ce000
        WHERE GUID=@pos AND Type=1 AND Number=2307 AND Debit=932000 AND Credit=932000
          AND ISNULL(Branch,@zero)=@zero
    ) THROW 52302, 'POS voucher 2307 does not match the verified source row.', 1;
    IF EXISTS (SELECT 1 FROM dbo.ce000 WHERE GUID=@purchase)
        THROW 52303, 'Purchase voucher is present in an unexpected state.', 1;
    IF EXISTS (
        SELECT 1 FROM dbo.ce000
        WHERE Type=1 AND Number=@temporary AND ISNULL(Branch,@zero)=@zero
    ) THROW 52304, 'The reserved temporary number is already occupied.', 1;
    IF (SELECT COUNT(*) FROM dbo.en000 WHERE ParentGUID=@pos)<>4
       OR (SELECT SUM(Debit) FROM dbo.en000 WHERE ParentGUID=@pos)<>932000
       OR (SELECT SUM(Credit) FROM dbo.en000 WHERE ParentGUID=@pos)<>932000
        THROW 52305, 'POS accounting lines do not match the verified voucher.', 1;
    IF (SELECT COUNT(*) FROM dbo.en000 WHERE ParentGUID=@purchase)<>37
       OR (SELECT SUM(Debit) FROM dbo.en000 WHERE ParentGUID=@purchase)<>9531000
       OR (SELECT SUM(Credit) FROM dbo.en000 WHERE ParentGUID=@purchase)<>9531000
        THROW 52306, 'Purchase accounting lines do not match the verified invoice.', 1;

    SELECT @priorErrorCount=COUNT(*) FROM dbo.ErrorLog
    WHERE level=1 AND type=0 AND c1=N'AmnE0001: Can''t insert posted entries' AND g1=@purchase;

    WITH CHANGE_TRACKING_CONTEXT ($sqlSyncContext)
    INSERT dbo.mc000(type,number,item) VALUES(24,1000,0);
    WITH CHANGE_TRACKING_CONTEXT ($sqlSyncContext)
    UPDATE dbo.ce000 SET Number=@temporary WHERE GUID=@pos AND Number=2307;
    IF @@ROWCOUNT<>1 THROW 52307, 'POS voucher was not moved atomically.', 1;

    INSERT dbo.ce000(Type,Number,Date,Debit,Credit,Notes,CurrencyVal,IsPosted,State,Security,Num1,Num2,Branch,GUID,CurrencyGUID,TypeGUID,IsPrinted,PostDate)
    VALUES(1,2307,'20260823',9531000,9531000,N'',1,1,0,1,0,0,@zero,@purchase,'BCBCD2F1-24DD-4F86-9746-2537D7351DFE','591AB4E6-E395-4CFF-8294-9034F68D1CBD',0,'20260824 00:56:56.803');

    IF (SELECT COUNT(*) FROM dbo.ErrorLog
        WHERE level=1 AND type=0 AND c1=N'AmnE0001: Can''t insert posted entries' AND g1=@purchase)<>@priorErrorCount+1
        THROW 52308, 'Unexpected Al-Ameen validation-log result.', 1;
    DELETE TOP (1) FROM dbo.ErrorLog
    WHERE level=1 AND type=0 AND c1=N'AmnE0001: Can''t insert posted entries' AND g1=@purchase;

    WITH CHANGE_TRACKING_CONTEXT ($sqlSyncContext)
    DELETE dbo.mc000 WHERE type=24 AND number=1000;
    IF dbo.fnFlag_IsSet(1000)<>0 THROW 52309, 'Maintenance flag cleanup failed.', 1;
    COMMIT;
    SELECT 'SQLSYNC_V2307_STAGED';
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    THROW;
END CATCH;
"@

$stageResult = Invoke-RepairSql -Sql $stageSql
$marker = $stageResult | Where-Object { $_ -like 'SQLSYNC_V2307_*' } | Select-Object -Last 1
if ($marker -like 'SQLSYNC_V2307_COMPLETE|*') {
    Write-Host "Voucher recovery is already complete. Purchase voucher number: $($marker.Split('|')[1])"
    exit 0
}
if ($marker -ne 'SQLSYNC_V2307_STAGED') {
    throw "The staging command did not return its completion marker: $($stageResult -join '; ')"
}

Write-Host 'Voucher 2307 is staged safely. Keep this window open while the targeted ce000 sync runs.'
$deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
$allocatedNumber = 0
while ([DateTime]::UtcNow -lt $deadline) {
    $pollSql = "SET NOCOUNT ON; SELECT ISNULL((SELECT Number FROM dbo.ce000 WHERE GUID='$purchaseGuid' AND Type=1 AND Debit=9531000 AND Credit=9531000),0);"
    $pollResult = Invoke-RepairSql -Sql $pollSql
    $numberText = $pollResult | Where-Object { $_ -match '^-?\d+$' } | Select-Object -Last 1
    if ($null -ne $numberText) { $allocatedNumber = [int]$numberText }
    if ($allocatedNumber -gt 0 -and $allocatedNumber -ne 2307) { break }
    Start-Sleep -Seconds 5
}
if ($allocatedNumber -le 0 -or $allocatedNumber -eq 2307) {
    throw 'Timed out waiting for the server to assign the purchase voucher a new number. No rows were deleted; rerun this script after the targeted sync continues.'
}

$finalizeSql = @"
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @pos uniqueidentifier='$posGuid', @purchase uniqueidentifier='$purchaseGuid', @temporary int=$temporaryNumber;
BEGIN TRY
    BEGIN TRAN;
    IF dbo.fnFlag_IsSet(1000)<>0 THROW 52310, 'Maintenance flag 1000 is already set.', 1;
    IF NOT EXISTS(SELECT 1 FROM dbo.ce000 WHERE GUID=@purchase AND Number=$allocatedNumber AND Debit=9531000 AND Credit=9531000)
        THROW 52311, 'Allocated purchase voucher does not match the verified row.', 1;
    IF NOT EXISTS(SELECT 1 FROM dbo.ce000 WHERE GUID=@pos AND Number=@temporary AND Debit=932000 AND Credit=932000)
        THROW 52312, 'POS voucher is not in the verified temporary state.', 1;
    WITH CHANGE_TRACKING_CONTEXT ($sqlSyncContext)
    INSERT dbo.mc000(type,number,item) VALUES(24,1000,0);
    WITH CHANGE_TRACKING_CONTEXT ($sqlSyncContext)
    UPDATE dbo.ce000 SET Number=2307 WHERE GUID=@pos AND Number=@temporary;
    IF @@ROWCOUNT<>1 THROW 52313, 'POS voucher could not be restored to 2307.', 1;
    WITH CHANGE_TRACKING_CONTEXT ($sqlSyncContext)
    DELETE dbo.mc000 WHERE type=24 AND number=1000;
    IF dbo.fnFlag_IsSet(1000)<>0 THROW 52314, 'Maintenance flag cleanup failed.', 1;
    COMMIT;
    SELECT 'SQLSYNC_V2307_COMPLETE|$allocatedNumber';
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    THROW;
END CATCH;
"@

$finalResult = Invoke-RepairSql -Sql $finalizeSql
if (-not ($finalResult | Where-Object { $_ -eq "SQLSYNC_V2307_COMPLETE|$allocatedNumber" })) {
    throw "Final verification marker is missing: $($finalResult -join '; ')"
}
Write-Host "Voucher recovery completed. POS remains 2307; purchase voucher is now $allocatedNumber."
