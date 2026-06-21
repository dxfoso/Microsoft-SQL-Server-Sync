param(
    [string] $SqlInstance = "localhost",
    [string] $Database = "velvet",
    [int] $Customers = 1000,
    [int] $Products = 1000,
    [int] $Orders = 1000,
    [int] $OrderLines = 2500,
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

function Invoke-SqlBatch {
    param(
        [System.Data.SqlClient.SqlConnection] $Connection,
        [string] $BatchSql,
        [string] $Name
    )

    if ([string]::IsNullOrWhiteSpace($BatchSql)) {
        return
    }

    $command = $Connection.CreateCommand()
    $command.CommandText = $BatchSql
    $command.CommandTimeout = $CommandTimeoutSeconds
    Write-Host "Running batch: $Name"
    $null = $command.ExecuteNonQuery()
}

function Invoke-SqlScript {
    param(
        [System.Data.SqlClient.SqlConnection] $Connection,
        [string] $ScriptText
    )

    $batches = $ScriptText -split "(?m)^\s*GO\s*$"
    $index = 1
    foreach ($batch in $batches) {
        $trimmed = $batch.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }
        Invoke-SqlBatch -Connection $Connection -BatchSql $trimmed -Name "Batch $index"
        $index++
    }
}

Add-Type -AssemblyName System.Data

$masterConnectionString = Get-ConnectionString -SqlInstanceValue $SqlInstance -UseSqlLoginValue $UseSqlLogin -SqlUserValue $SqlUser -SqlPasswordValue $SqlPassword -DatabaseValue "master"
$connection = New-Object System.Data.SqlClient.SqlConnection $masterConnectionString

$seedScript = @"
IF DB_ID(N'$($Database)') IS NOT NULL
BEGIN
    ALTER DATABASE [$($Database)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$($Database)];
END;
GO

CREATE DATABASE [$($Database)];
GO

USE [$($Database)];
GO

CREATE TABLE dbo.Customers (
    CustomerId INT IDENTITY(1,1) PRIMARY KEY,
    FullName NVARCHAR(120) NOT NULL,
    Email NVARCHAR(180) NOT NULL UNIQUE,
    City NVARCHAR(100) NOT NULL,
    CreatedAt DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE dbo.Products (
    ProductId INT IDENTITY(1,1) PRIMARY KEY,
    ProductName NVARCHAR(140) NOT NULL,
    Category NVARCHAR(80) NOT NULL,
    UnitPrice DECIMAL(10,2) NOT NULL,
    InStock INT NOT NULL
);

CREATE TABLE dbo.Orders (
    OrderId INT IDENTITY(1,1) PRIMARY KEY,
    CustomerId INT NOT NULL,
    OrderDate DATETIME2(0) NOT NULL,
    Status NVARCHAR(30) NOT NULL,
    TotalAmount DECIMAL(12,2) NOT NULL DEFAULT 0,
    CONSTRAINT FK_Orders_Customers FOREIGN KEY (CustomerId) REFERENCES dbo.Customers(CustomerId)
);

CREATE TABLE dbo.OrderLines (
    OrderLineId INT IDENTITY(1,1) PRIMARY KEY,
    OrderId INT NOT NULL,
    ProductId INT NOT NULL,
    Quantity INT NOT NULL,
    UnitPrice DECIMAL(10,2) NOT NULL,
    LineTotal AS (Quantity * UnitPrice) PERSISTED,
    CONSTRAINT FK_OrderLines_Orders FOREIGN KEY (OrderId) REFERENCES dbo.Orders(OrderId),
    CONSTRAINT FK_OrderLines_Products FOREIGN KEY (ProductId) REFERENCES dbo.Products(ProductId)
);

CREATE TABLE dbo.Payments (
    PaymentId INT IDENTITY(1,1) PRIMARY KEY,
    OrderId INT NOT NULL,
    PaidAt DATETIME2(0) NOT NULL,
    Amount DECIMAL(12,2) NOT NULL,
    Method NVARCHAR(40) NOT NULL,
    CONSTRAINT FK_Payments_Orders FOREIGN KEY (OrderId) REFERENCES dbo.Orders(OrderId)
);

INSERT INTO dbo.Customers (FullName, Email, City)
SELECT
    CONCAT('Customer ', n),
    CONCAT('customer', n, '@example.local'),
    CHOOSE((n % 10) + 1, 'Berlin', 'London', 'Paris', 'Madrid', 'Toronto', 'Dubai', 'Tokyo', 'New York', 'Sydney', 'Sao Paulo')
FROM (
    SELECT TOP ($Customers) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a
    CROSS JOIN sys.all_objects b
) AS source;
GO

INSERT INTO dbo.Products (ProductName, Category, UnitPrice, InStock)
SELECT
    CONCAT('Product ', n),
    CHOOSE((n % 8) + 1, 'Electronics', 'Hardware', 'Tools', 'Furniture', 'Books', 'Sports', 'Food', 'Stationery'),
    CAST((ABS(CHECKSUM(NEWID())) % 50000) / 100.0 + 1 AS DECIMAL(10,2)),
    (ABS(CHECKSUM(NEWID())) % 300) + 10
FROM (
    SELECT TOP ($Products) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a
    CROSS JOIN sys.all_objects b
) AS source;
GO

INSERT INTO dbo.Orders (CustomerId, OrderDate, Status)
SELECT
    (ABS(CHECKSUM(NEWID())) % $Customers) + 1,
    DATEADD(day, - (ABS(CHECKSUM(NEWID())) % 365), SYSUTCDATETIME()),
    CHOOSE(
        (ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) % 5) + 1,
        N'جديد',
        N'قيد التجهيز',
        N'تم الشحن',
        N'تم التسليم',
        N'مرتجع'
    )
FROM (
    SELECT TOP ($Orders) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a
    CROSS JOIN sys.all_objects b
) AS source;
GO

WITH SeedLines AS (
    SELECT TOP ($OrderLines)
        ((ABS(CHECKSUM(NEWID())) % $Orders) + 1) AS OrderId,
        ((ABS(CHECKSUM(NEWID())) % $Products) + 1) AS ProductId,
        ((ABS(CHECKSUM(NEWID())) % 5) + 1) AS Quantity
    FROM sys.all_objects a
    CROSS JOIN sys.all_objects b
)
INSERT INTO dbo.OrderLines (OrderId, ProductId, Quantity, UnitPrice)
SELECT
    sl.OrderId,
    sl.ProductId,
    sl.Quantity,
    p.UnitPrice
FROM SeedLines AS sl
JOIN dbo.Products AS p ON p.ProductId = sl.ProductId;
GO

UPDATE o
SET TotalAmount = x.SumAmount
FROM dbo.Orders o
CROSS APPLY (
    SELECT ISNULL(SUM(LineTotal), 0) AS SumAmount
    FROM dbo.OrderLines ol
    WHERE ol.OrderId = o.OrderId
) x;
GO

INSERT INTO dbo.Payments (OrderId, PaidAt, Amount, Method)
SELECT
    o.OrderId,
    DATEADD(minute, (ABS(CHECKSUM(NEWID())) % 14400), o.OrderDate),
    o.TotalAmount,
    CHOOSE((ROW_NUMBER() OVER (ORDER BY o.OrderId) % 4) + 1, 'Card', 'Bank Transfer', 'Cash', 'Wallet')
FROM dbo.Orders o
WHERE o.TotalAmount > 0
ORDER BY o.OrderId;

SELECT 'Customers' AS TableName, COUNT(1) AS Rows FROM dbo.Customers
UNION ALL
SELECT 'Products', COUNT(1) FROM dbo.Products
UNION ALL
SELECT 'Orders', COUNT(1) FROM dbo.Orders
UNION ALL
SELECT 'OrderLines', COUNT(1) FROM dbo.OrderLines
UNION ALL
SELECT 'Payments', COUNT(1) FROM dbo.Payments;
"@

try {
    $connection.Open()
    Write-Host "Connected to SQL Server instance: $SqlInstance"
    Invoke-SqlScript -Connection $connection -ScriptText $seedScript
    Write-Host "Seed completed for database '$Database'."
}
catch {
    throw "Database seeding failed: $($_.Exception.Message)"
}
finally {
    if ($connection.State -eq "Open") {
        $connection.Close()
    }
}
