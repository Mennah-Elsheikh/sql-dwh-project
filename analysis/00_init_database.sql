/*
=============================================================
Create Analytics Database and Load Gold Layer Data
=============================================================
Script Purpose:
    This script creates a new database named 'DataWarehouseAnalytics' after checking
    if it already exists. If the database exists, it is dropped and recreated.
    It then creates physical tables in the 'gold' schema and populates them by
    querying the Gold layer VIEWS from the 'DataWarehouse' database.

    PREREQUISITE:
    The 'DataWarehouse' database must already exist and the following scripts
    must have been executed in order:
      1. scripts/init_database.sql               -- Create DataWarehouse + schemas
      2. scripts/bronze/ddl_bronze.sql           -- Bronze layer tables
      3. scripts/bronze/proc_load_bronze.sql     -- Load bronze data
      4. scripts/silver/ddl_silver.sql           -- Silver layer tables
      5. scripts/silver/proc_load_silver.sql     -- Load silver data
      6. scripts/gold/ddl_gold.sql               -- Gold layer views

WARNING:
    Running this script will drop the entire 'DataWarehouseAnalytics' database if it exists.
    All data in the database will be permanently deleted. Proceed with caution
    and ensure you have proper backups before running this script.
*/

USE master;
GO

-- Drop and recreate the 'DataWarehouseAnalytics' database
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'DataWarehouseAnalytics')
BEGIN
    ALTER DATABASE DataWarehouseAnalytics SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DataWarehouseAnalytics;
END;
GO

-- Create the 'DataWarehouseAnalytics' database
CREATE DATABASE DataWarehouseAnalytics;
GO

USE DataWarehouseAnalytics;
GO

-- Create Schema
CREATE SCHEMA gold;
GO

-- =============================================================================
-- Create Table: gold.dim_customers
-- =============================================================================
CREATE TABLE gold.dim_customers (
    customer_key    INT,
    customer_id     INT,
    customer_number NVARCHAR(50),
    first_name      NVARCHAR(50),
    last_name       NVARCHAR(50),
    country         NVARCHAR(50),
    marital_status  NVARCHAR(50),
    gender          NVARCHAR(50),
    birthdate       DATE,
    create_date     DATE
);
GO

-- =============================================================================
-- Create Table: gold.dim_products
-- =============================================================================
CREATE TABLE gold.dim_products (
    product_key     INT,
    product_id      INT,
    product_number  NVARCHAR(50),
    product_name    NVARCHAR(50),
    category_id     NVARCHAR(50),
    category        NVARCHAR(50),
    subcategory     NVARCHAR(50),
    maintenance     NVARCHAR(50),
    cost            INT,
    product_line    NVARCHAR(50),
    start_date      DATE
);
GO

-- =============================================================================
-- Create Table: gold.fact_sales
-- =============================================================================
CREATE TABLE gold.fact_sales (
    order_number    NVARCHAR(50),
    product_key     INT,
    customer_key    INT,
    order_date      DATE,
    shipping_date   DATE,
    due_date        DATE,
    sales_amount    INT,
    quantity        TINYINT,
    price           INT
);
GO

-- =============================================================================
-- Load Data from DataWarehouse Gold Layer Views
-- =============================================================================

-- Load gold.dim_customers
INSERT INTO gold.dim_customers (
    customer_key, customer_id, customer_number, first_name, last_name,
    country, marital_status, gender, birthdate, create_date
)
SELECT
    customer_key, customer_id, customer_number, first_name, last_name,
    country, marital_status, gender, birthdate, create_date
FROM DataWarehouse.gold.dim_customers;
GO

-- Load gold.dim_products
INSERT INTO gold.dim_products (
    product_key, product_id, product_number, product_name, category_id,
    category, subcategory, maintenance, cost, product_line, start_date
)
SELECT
    product_key, product_id, product_number, product_name, category_id,
    category, subcategory, maintenance, cost, product_line, start_date
FROM DataWarehouse.gold.dim_products;
GO

-- Load gold.fact_sales
INSERT INTO gold.fact_sales (
    order_number, product_key, customer_key, order_date,
    shipping_date, due_date, sales_amount, quantity, price
)
SELECT
    order_number, product_key, customer_key, order_date,
    shipping_date, due_date, sales_amount, quantity, price
FROM DataWarehouse.gold.fact_sales;
GO

-- =============================================================================
-- Create Report View: gold.report_customers
-- =============================================================================
IF OBJECT_ID('gold.report_customers', 'V') IS NOT NULL
    DROP VIEW gold.report_customers;
GO

CREATE VIEW gold.report_customers AS

WITH base_query AS (
    SELECT
        f.order_number,
        f.product_key,
        f.order_date,
        f.sales_amount,
        f.quantity,
        c.customer_key,
        c.customer_number,
        CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
        DATEDIFF(year, c.birthdate, GETDATE())  AS age
    FROM gold.fact_sales f
    LEFT JOIN gold.dim_customers c
        ON c.customer_key = f.customer_key
    WHERE order_date IS NOT NULL
),

customer_aggregation AS (
    SELECT
        customer_key,
        customer_number,
        customer_name,
        age,
        COUNT(DISTINCT order_number)            AS total_orders,
        SUM(sales_amount)                       AS total_sales,
        SUM(quantity)                           AS total_quantity,
        COUNT(DISTINCT product_key)             AS total_products,
        MAX(order_date)                         AS last_order_date,
        DATEDIFF(month, MIN(order_date), MAX(order_date)) AS lifespan
    FROM base_query
    GROUP BY
        customer_key,
        customer_number,
        customer_name,
        age
)

SELECT
    customer_key,
    customer_number,
    customer_name,
    age,
    CASE
        WHEN age < 20                  THEN 'Under 20'
        WHEN age BETWEEN 20 AND 29     THEN '20-29'
        WHEN age BETWEEN 30 AND 39     THEN '30-39'
        WHEN age BETWEEN 40 AND 49     THEN '40-49'
        ELSE '50 and above'
    END AS age_group,
    CASE
        WHEN lifespan >= 12 AND total_sales > 5000  THEN 'VIP'
        WHEN lifespan >= 12 AND total_sales <= 5000 THEN 'Regular'
        ELSE 'New'
    END AS customer_segment,
    last_order_date,
    DATEDIFF(month, last_order_date, GETDATE()) AS recency,
    total_orders,
    total_sales,
    total_quantity,
    total_products,
    lifespan,
    -- Average order value (AOV)
    CASE WHEN total_orders = 0 THEN 0
         ELSE total_sales / total_orders
    END AS avg_order_value,
    -- Average monthly spend
    CASE WHEN lifespan = 0 THEN total_sales
         ELSE total_sales / lifespan
    END AS avg_monthly_spend
FROM customer_aggregation;
GO

-- =============================================================================
-- Create Report View: gold.report_products
-- =============================================================================
IF OBJECT_ID('gold.report_products', 'V') IS NOT NULL
    DROP VIEW gold.report_products;
GO

CREATE VIEW gold.report_products AS

WITH base_query AS (
    SELECT
        f.order_number,
        f.order_date,
        f.customer_key,
        f.sales_amount,
        f.quantity,
        p.product_key,
        p.product_name,
        p.category,
        p.subcategory,
        p.cost
    FROM gold.fact_sales f
    LEFT JOIN gold.dim_products p
        ON f.product_key = p.product_key
    WHERE order_date IS NOT NULL
),

product_aggregations AS (
    SELECT
        product_key,
        product_name,
        category,
        subcategory,
        cost,
        DATEDIFF(MONTH, MIN(order_date), MAX(order_date))              AS lifespan,
        MAX(order_date)                                                 AS last_sale_date,
        COUNT(DISTINCT order_number)                                    AS total_orders,
        COUNT(DISTINCT customer_key)                                    AS total_customers,
        SUM(sales_amount)                                               AS total_sales,
        SUM(quantity)                                                   AS total_quantity,
        ROUND(AVG(CAST(sales_amount AS FLOAT) / NULLIF(quantity, 0)), 1) AS avg_selling_price
    FROM base_query
    GROUP BY
        product_key,
        product_name,
        category,
        subcategory,
        cost
)

SELECT
    product_key,
    product_name,
    category,
    subcategory,
    cost,
    last_sale_date,
    DATEDIFF(MONTH, last_sale_date, GETDATE()) AS recency_in_months,
    CASE
        WHEN total_sales > 50000  THEN 'High-Performer'
        WHEN total_sales >= 10000 THEN 'Mid-Range'
        ELSE 'Low-Performer'
    END AS product_segment,
    lifespan,
    total_orders,
    total_sales,
    total_quantity,
    total_customers,
    avg_selling_price,
    -- Average Order Revenue (AOR)
    CASE
        WHEN total_orders = 0 THEN 0
        ELSE total_sales / total_orders
    END AS avg_order_revenue,
    -- Average Monthly Revenue
    CASE
        WHEN lifespan = 0 THEN total_sales
        ELSE total_sales / lifespan
    END AS avg_monthly_revenue
FROM product_aggregations;
GO

