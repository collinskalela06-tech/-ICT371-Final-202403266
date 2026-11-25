-- =====================================================================
-- ICT371 Advanced Database | Question 1: Pharmacy Stock and Daily Sales
-- Student: collins kalela (202403266)
-- DBMS: PostgreSQL 14+ (pg_cron extension for part g)
-- Run the whole file top to bottom; it can be re-run safely.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;   -- needs shared_preload_libraries = 'pg_cron'
-- pg_cron uses GMT by default. Zambia is GMT+2; to schedule in local time set
-- cron.timezone = 'Africa/Lusaka' in postgresql.conf and restart.

DROP SCHEMA IF EXISTS q1_pharmacy CASCADE;
CREATE SCHEMA q1_pharmacy;
SET search_path = q1_pharmacy, public;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE medicines (
    medicine_id    SERIAL        PRIMARY KEY,
    medicine_name  VARCHAR(100)  NOT NULL UNIQUE,
    unit_price     NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty      INTEGER       NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id      SERIAL        PRIMARY KEY,
    medicine_id  INTEGER       NOT NULL REFERENCES medicines(medicine_id),
    quantity     INTEGER       NOT NULL CHECK (quantity > 0),
    unit_price   NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on      DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id     SERIAL      PRIMARY KEY,
    medicine_id  INTEGER     NOT NULL REFERENCES medicines(medicine_id),
    old_qty      INTEGER     NOT NULL,
    new_qty      INTEGER     NOT NULL,
    changed_at   TIMESTAMP   NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date    DATE          PRIMARY KEY,
    total_qty     INTEGER       NOT NULL CHECK (total_qty >= 0),
    total_amount  NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0)
);

-- Three medicines (sales are loaded later through pr_record_sale)
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.00,  50),
    ('Ibuprofen 400mg',   3.75,  20);

-- ---------------------------------------------------------------------
-- (b) Function: fn_sale_value
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_price NUMERIC;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be a positive number (got %)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_record_sale
--     The whole CALL is one transaction, so any RAISE EXCEPTION undoes
--     both the sales insert and the stock deduction.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INTEGER,
                                           p_quantity    INTEGER,
                                           p_sold_on     DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be a positive number (got %)', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date must not be NULL';
    END IF;

    -- FOR UPDATE locks the row so two sales cannot oversell at the same time
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: requested %, available %',
                        p_medicine_id, p_quantity, v_stock;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);   -- current price stored

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity                    -- deducted exactly once
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: AFTER UPDATE row trigger on medicines
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)   -- only when stock really changes
EXECUTE FUNCTION trg_fn_stock_audit();

-- ---------------------------------------------------------------------
-- (a) continued: load six valid sales THROUGH the procedure
--     (done after the trigger exists so each stock change is audited)
-- ---------------------------------------------------------------------
CALL pr_record_sale(1, 10, CURRENT_DATE - 1);
CALL pr_record_sale(1, 20, CURRENT_DATE - 1);
CALL pr_record_sale(2,  5, CURRENT_DATE - 1);
CALL pr_record_sale(2, 15, CURRENT_DATE);
CALL pr_record_sale(3,  6, CURRENT_DATE);
CALL pr_record_sale(3,  5, CURRENT_DATE);      -- Ibuprofen drops to 9

SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;

-- Tests for (b) and (c)
SELECT fn_sale_value(2, 3) AS value_of_3_amoxicillin;      -- 24.00

DO $$
BEGIN
    PERFORM fn_sale_value(999, 1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'fn_sale_value rejected: %', SQLERRM;
END $$;

DO $$
BEGIN
    PERFORM fn_sale_value(1, 0);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'fn_sale_value rejected: %', SQLERRM;
END $$;

-- Overselling must fail and leave sales and medicines unchanged
DO $$
BEGIN
    CALL pr_record_sale(3, 1000, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pr_record_sale rejected: %', SQLERRM;
END $$;

SELECT (SELECT COUNT(*) FROM sales) AS sales_rows_still_6,
       (SELECT stock_qty FROM medicines WHERE medicine_id = 3) AS ibuprofen_still_9;

-- ---------------------------------------------------------------------
-- (e) View: v_low_stock
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

SELECT * FROM v_low_stock;                 -- Ibuprofen (9) appears

CALL pr_record_sale(3, 1, CURRENT_DATE);   -- one more sale (Ibuprofen 9 -> 8), then query the view again
SELECT * FROM v_low_stock;

-- ---------------------------------------------------------------------
-- (f) Index: one medicine's sales in a sold_on date range
--     Justification: the query filters by equality on medicine_id and a
--     range on sold_on. A composite (medicine_id, sold_on) index lets
--     PostgreSQL jump to that medicine's entries and read only the dates
--     in range, in order, instead of scanning the whole sales table.
-- ---------------------------------------------------------------------
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;

SET enable_seqscan = off;   -- the demo table is tiny, so force the planner to show the index
EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_sales + pg_cron at 00:15 daily
--     INSERT ... ON CONFLICT replaces the day's row, so reruns never
--     duplicate or double-count.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty    = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

SELECT cron.schedule(
    'q1_refresh_sales',            -- job name (re-running this file just updates it)
    '15 0 * * *',                  -- every day at 00:15
    $job$CALL q1_pharmacy.pr_refresh_sales(CURRENT_DATE - 1)$job$   -- previous day
);

-- Prove reruns do not double count
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE);
SELECT * FROM daily_sales ORDER BY sales_date;     -- yesterday: 35 units, 115.00

-- Inspect the job and its history
SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q1_refresh_sales';
SELECT jobid, status, return_message, start_time FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;
