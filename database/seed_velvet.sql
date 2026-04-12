IF DB_ID('velvet') IS NOT NULL
BEGIN
    ALTER DATABASE velvet SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE velvet;
END;
GO

CREATE DATABASE velvet;
GO

USE velvet;
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
    SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a
    CROSS JOIN sys.all_objects b
) AS src;

INSERT INTO dbo.Products (ProductName, Category, UnitPrice, InStock)
SELECT
    CONCAT('Product ', n),
    CHOOSE((n % 8) + 1, 'Electronics', 'Hardware', 'Tools', 'Furniture', 'Books', 'Sports', 'Food', 'Stationery'),
    CAST((ABS(CHECKSUM(NEWID())) % 50000) / 100.0 + 1 AS DECIMAL(10,2)),
    (ABS(CHECKSUM(NEWID())) % 300) + 10
FROM (
    SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a
    CROSS JOIN sys.all_objects b
) AS src;

INSERT INTO dbo.Orders (CustomerId, OrderDate, Status)
SELECT
    (ABS(CHECKSUM(NEWID())) % 1000) + 1,
    DATEADD(day, - (ABS(CHECKSUM(NEWID())) % 365), SYSUTCDATETIME()),
    CHOOSE((ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) % 5) + 1, 'New', 'Packed', 'Shipped', 'Delivered', 'Returned')
FROM (
    SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a
    CROSS JOIN sys.all_objects b
) AS src;

INSERT INTO dbo.OrderLines (OrderId, ProductId, Quantity, UnitPrice)
SELECT TOP (2000)
    (ABS(CHECKSUM(NEWID())) % 1000) + 1,
    (ABS(CHECKSUM(NEWID())) % 1000) + 1,
    (ABS(CHECKSUM(NEWID())) % 5) + 1,
    p.UnitPrice
FROM (
    SELECT TOP (2000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a
    CROSS JOIN sys.all_objects b
) src
CROSS APPLY (
    SELECT TOP (1) UnitPrice
    FROM dbo.Products p
    WHERE p.ProductId = (ABS(CHECKSUM(NEWID())) % 1000) + 1
) p;

UPDATE o
SET TotalAmount = x.SumAmount
FROM dbo.Orders o
CROSS APPLY (
    SELECT ISNULL(SUM(LineTotal), 0) AS SumAmount
    FROM dbo.OrderLines ol
    WHERE ol.OrderId = o.OrderId
) x;

INSERT INTO dbo.Payments (OrderId, PaidAt, Amount, Method)
SELECT
    o.OrderId,
    DATEADD(minute, (ABS(CHECKSUM(NEWID())) % 14400), o.OrderDate),
    o.TotalAmount,
    CHOOSE((ROW_NUMBER() OVER (ORDER BY o.OrderId) % 4) + 1, 'Card', 'Bank Transfer', 'Cash', 'Wallet')
FROM dbo.Orders o
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
