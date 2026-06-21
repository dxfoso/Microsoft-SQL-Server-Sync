param(
    [string] $SqlInstance = "localhost",
    [string] $Database = "velvet",
    [int] $Customers = 2,
    [int] $Products = 2,
    [int] $Orders = 4,
    [int] $OrderLines = 10,
    [int] $Payments = 3,
    [switch] $UseSqlLogin,
    [string] $SqlUser = "",
    [string] $SqlPassword = "",
    [int] $CommandTimeoutSeconds = 180
)

if ($UseSqlLogin -and ([string]::IsNullOrWhiteSpace($SqlUser) -or [string]::IsNullOrWhiteSpace($SqlPassword))) {
    throw "UseSqlLogin is set, but SqlUser and SqlPassword must be provided."
}

function Get-ConnectionString {
    param(
        [string] $SqlInstanceValue,
        [bool] $UseSqlLoginValue,
        [string] $SqlUserValue,
        [string] $SqlPasswordValue,
        [string] $DatabaseValue
    )

    if ($UseSqlLoginValue) {
        return "Server=$SqlInstanceValue;Database=$DatabaseValue;User Id=$SqlUserValue;Password=$SqlPasswordValue;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
    }

    return "Server=$SqlInstanceValue;Database=$DatabaseValue;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
}

function New-CountMap {
    param($Connection)

    $command = $Connection.CreateCommand()
    $command.CommandTimeout = $CommandTimeoutSeconds
    $command.CommandText = @"
SET NOCOUNT ON;
SELECT 'Customers' AS TableName, COUNT_BIG(1) AS [RowCount] FROM dbo.Customers
UNION ALL
SELECT 'Products', COUNT_BIG(1) FROM dbo.Products
UNION ALL
SELECT 'Orders', COUNT_BIG(1) FROM dbo.Orders
UNION ALL
SELECT 'OrderLines', COUNT_BIG(1) FROM dbo.OrderLines
UNION ALL
SELECT 'Payments', COUNT_BIG(1) FROM dbo.Payments;
"@

    $counts = @{}
    $reader = $command.ExecuteReader()
    try {
        while ($reader.Read()) {
            $counts[$reader.GetString(0)] = [int64] $reader.GetValue(1)
        }
    }
    finally {
        $reader.Close()
    }

    return $counts
}

Add-Type -AssemblyName System.Data

$connectionString = Get-ConnectionString -SqlInstanceValue $SqlInstance -UseSqlLoginValue $UseSqlLogin -SqlUserValue $SqlUser -SqlPasswordValue $SqlPassword -DatabaseValue $Database
$connection = New-Object System.Data.SqlClient.SqlConnection $connectionString

$injectScript = @"
SET NOCOUNT ON;

DECLARE @Customers int = $Customers;
DECLARE @Products int = $Products;
DECLARE @Orders int = $Orders;
DECLARE @OrderLines int = $OrderLines;
DECLARE @Payments int = $Payments;
DECLARE @RunId nvarchar(32) = REPLACE(CONVERT(nvarchar(36), NEWID()), '-', '');

IF @Customers > 0
BEGIN
    ;WITH numbers AS (
        SELECT TOP (@Customers) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
        FROM sys.all_objects a
        CROSS JOIN sys.all_objects b
    )
    INSERT INTO dbo.Customers (FullName, Email, City)
    SELECT
        CONCAT(N'Test Customer ', RIGHT(@RunId, 6), N'-', n),
        CONCAT(N'test-', @RunId, N'-c', n, N'@example.local'),
        CASE ((CHECKSUM(NEWID()) & 2147483647) % 8)
            WHEN 0 THEN N'Dubai'
            WHEN 1 THEN N'Riyadh'
            WHEN 2 THEN N'Berlin'
            WHEN 3 THEN N'Paris'
            WHEN 4 THEN N'Doha'
            WHEN 5 THEN N'Amman'
            WHEN 6 THEN N'Cairo'
            ELSE N'Abu Dhabi'
        END
    FROM numbers;
END;

IF @Products > 0
BEGIN
    ;WITH numbers AS (
        SELECT TOP (@Products) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
        FROM sys.all_objects a
        CROSS JOIN sys.all_objects b
    )
    INSERT INTO dbo.Products (ProductName, Category, UnitPrice, InStock)
    SELECT
        CONCAT(N'Test Product ', RIGHT(@RunId, 6), N'-', n),
        CASE ((CHECKSUM(NEWID()) & 2147483647) % 6)
            WHEN 0 THEN N'Electronics'
            WHEN 1 THEN N'Hardware'
            WHEN 2 THEN N'Furniture'
            WHEN 3 THEN N'Office'
            WHEN 4 THEN N'Sports'
            ELSE N'Kitchen'
        END,
        CAST(((ABS(CHECKSUM(NEWID())) % 90000) / 100.0) + 10 AS DECIMAL(10,2)),
        (ABS(CHECKSUM(NEWID())) % 200) + 5
    FROM numbers;
END;

IF @Orders > 0
BEGIN
    INSERT INTO dbo.Orders (CustomerId, OrderDate, Status, TotalAmount)
    SELECT TOP (@Orders)
        c.CustomerId,
        DATEADD(minute, -1 * ((ABS(CHECKSUM(NEWID())) % 4320) + ROW_NUMBER() OVER (ORDER BY NEWID())), SYSUTCDATETIME()),
        CASE ((CHECKSUM(NEWID()) & 2147483647) % 5)
            WHEN 0 THEN N'جديد'
            WHEN 1 THEN N'قيد التجهيز'
            WHEN 2 THEN N'تم الشحن'
            WHEN 3 THEN N'تم التسليم'
            ELSE N'مرتجع'
        END,
        0
    FROM dbo.Customers c
    ORDER BY NEWID();
END;

IF @OrderLines > 0
BEGIN
    ;WITH line_numbers AS (
        SELECT TOP (@OrderLines) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
        FROM sys.all_objects a
        CROSS JOIN sys.all_objects b
    )
    INSERT INTO dbo.OrderLines (OrderId, ProductId, Quantity, UnitPrice)
    SELECT
        chosen.OrderId,
        chosen.ProductId,
        (ABS(CHECKSUM(NEWID())) % 5) + 1,
        chosen.UnitPrice
    FROM line_numbers src
    CROSS APPLY (
        SELECT TOP (1)
            recentOrders.OrderId,
            p.ProductId,
            p.UnitPrice
        FROM (
            SELECT TOP (CASE WHEN @Orders > 0 THEN @Orders ELSE 20 END)
                o.OrderId
            FROM dbo.Orders o
            ORDER BY o.OrderId DESC
        ) recentOrders
        CROSS JOIN dbo.Products p
        ORDER BY NEWID()
    ) chosen;
END;

UPDATE o
SET TotalAmount = sums.SumAmount
FROM dbo.Orders o
INNER JOIN (
    SELECT
        ol.OrderId,
        SUM(ol.LineTotal) AS SumAmount
    FROM dbo.OrderLines ol
    GROUP BY ol.OrderId
) sums ON sums.OrderId = o.OrderId
WHERE o.TotalAmount <> sums.SumAmount;

IF @Payments > 0
BEGIN
    ;WITH unpaid_orders AS (
        SELECT TOP (@Payments)
            o.OrderId,
            o.OrderDate,
            o.TotalAmount
        FROM dbo.Orders o
        WHERE o.TotalAmount > 0
          AND NOT EXISTS (
              SELECT 1
              FROM dbo.Payments p
              WHERE p.OrderId = o.OrderId
          )
        ORDER BY NEWID()
    )
    INSERT INTO dbo.Payments (OrderId, PaidAt, Amount, Method)
    SELECT
        uo.OrderId,
        DATEADD(minute, (ABS(CHECKSUM(NEWID())) % 240), uo.OrderDate),
        uo.TotalAmount,
        CASE ((CHECKSUM(NEWID()) & 2147483647) % 4)
            WHEN 0 THEN N'Card'
            WHEN 1 THEN N'Bank Transfer'
            WHEN 2 THEN N'Cash'
            ELSE N'Wallet'
        END
    FROM unpaid_orders uo;
END;
"@

try {
    $connection.Open()
    $beforeCounts = New-CountMap -Connection $connection

    $command = $connection.CreateCommand()
    $command.CommandTimeout = $CommandTimeoutSeconds
    $command.CommandText = $injectScript
    $null = $command.ExecuteNonQuery()

    $afterCounts = New-CountMap -Connection $connection

    $tableNames = @("Customers", "Products", "Orders", "OrderLines", "Payments")
    $summary = foreach ($tableName in $tableNames) {
        $before = if ($beforeCounts.ContainsKey($tableName)) { [int64] $beforeCounts[$tableName] } else { 0 }
        $after = if ($afterCounts.ContainsKey($tableName)) { [int64] $afterCounts[$tableName] } else { 0 }
        [pscustomobject]@{
            Table = $tableName
            Before = $before
            After = $after
            Added = $after - $before
            CounterColorAfterReset = if ($before -eq $after) { "green" } else { "blue" }
        }
    }

    Write-Host "Injected random test data into '$Database' on '$SqlInstance'."
    Write-Host ($summary | Format-Table -AutoSize | Out-String)
    Write-Host "Counter behavior after you already saved/reset row counts:"
    Write-Host "- green = row count stayed the same"
    Write-Host "- blue = row count changed"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\inject_velvet_random_data.ps1"
    Write-Host "  .\inject_velvet_random_data.ps1 -Customers 0 -Products 0 -Orders 5 -OrderLines 12 -Payments 3"
}
catch {
    throw "Velvet test data injection failed: $($_.Exception.Message)"
}
finally {
    if ($connection.State -eq "Open") {
        $connection.Close()
    }
}
