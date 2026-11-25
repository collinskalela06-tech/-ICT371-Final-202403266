-- =====================================================================
-- ICT371 Advanced Database | Question 7: Water Meter Readings and Billing
-- Student: Blessings Kyembe (202301658)
-- DBMS: PostgreSQL 14+ (pg_cron extension for part g)
-- Run the whole file top to bottom; it can be re-run safely.
-- Tariff: first 10 units K5 each, units above 10 K8 each.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- pg_cron uses GMT by default (Zambia is GMT+2). Set cron.timezone = 'Africa/Lusaka'
-- in postgresql.conf if you want the times below to be local.

DROP SCHEMA IF EXISTS q7_water CASCADE;
CREATE SCHEMA q7_water;
SET search_path = q7_water, public;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id  SERIAL       PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id        SERIAL        PRIMARY KEY,
    customer_id       INTEGER       NOT NULL REFERENCES customers(customer_id),
    reading_month     DATE          NOT NULL,
    previous_reading  NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading   NUMERIC(12,2) NOT NULL CHECK (current_reading  >= 0),
    CONSTRAINT ck_reading_month_first_day CHECK (EXTRACT(DAY FROM reading_month) = 1),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id      SERIAL        PRIMARY KEY,
    reading_id   INTEGER       NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge       NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid  NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on       DATE          NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date  DATE          PRIMARY KEY,
    total_due      NUMERIC(14,2) NOT NULL CHECK (total_due >= 0)
);

INSERT INTO customers (full_name) VALUES
    ('Chanda Mwila'), ('Mutale Banda'), ('Natasha Phiri');

-- ---------------------------------------------------------------------
-- (b) Function: fn_water_charge
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION 'Consumption must not be NULL';
    END IF;
    IF p_units < 0 THEN
        RAISE EXCEPTION 'Consumption must not be negative (got %)', p_units;
    END IF;

    -- first 10 units at K5, the rest at K8; ROUND gives an exact 2-decimal value
    RETURN ROUND(LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2);
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: BEFORE INSERT OR UPDATE on readings
--     Raising an exception in a BEFORE trigger cancels the row, so a bad
--     reading is never stored (also for direct SQL imports).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_reading_check()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_reading_check();

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_generate_bill
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev   NUMERIC;
    v_curr   NUMERIC;
    v_units  NUMERIC;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date must not be NULL';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_units := v_curr - v_prev;                       -- consumption derived from the reading

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_units), 0, p_due_on);
END;
$$;

-- ---------------------------------------------------------------------
-- (a) continued: six readings (0, exactly 10 and above 10 units)
--     inserted after the trigger exists, so the trigger validates them
-- ---------------------------------------------------------------------
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date, 100, 100),  -- 0 units
    (1, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,  100, 110),  -- 10 units
    (2, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date,  50,  75),  -- 25 units
    (2, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,   75,  80),  -- 5 units
    (3, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date,   0,  10),  -- exactly 10
    (3, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,   10,  28);  -- 18 units

SELECT * FROM readings ORDER BY reading_id;

-- Tests for (b)
SELECT fn_water_charge(0)   AS units_0,    -- 0.00
       fn_water_charge(5)   AS units_5,    -- 25.00
       fn_water_charge(10)  AS units_10,   -- 50.00
       fn_water_charge(18)  AS units_18,   -- 50 + 8*8 = 114.00
       fn_water_charge(25.5) AS units_25_5;-- 50 + 15.5*8 = 174.00

DO $$ BEGIN PERFORM fn_water_charge(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(-3);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Tests for (d): rejected insert and rejected update, nothing stored
DO $$ BEGIN
    INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
    VALUES (1, (date_trunc('month', CURRENT_DATE))::date, 200, 150);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Insert rejected: %', SQLERRM; END $$;
DO $$ BEGIN
    UPDATE readings SET current_reading = 1 WHERE reading_id = 6;   -- previous is 10
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Update rejected: %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_still_6 FROM readings;
SELECT current_reading AS reading6_unchanged FROM readings WHERE reading_id = 6;   -- 28

-- Generate the six bills (older months already past due, recent ones not yet due)
CALL pr_generate_bill(1, CURRENT_DATE - 30);
CALL pr_generate_bill(2, CURRENT_DATE +  7);
CALL pr_generate_bill(3, CURRENT_DATE - 30);
CALL pr_generate_bill(4, CURRENT_DATE +  7);
CALL pr_generate_bill(5, CURRENT_DATE - 30);
CALL pr_generate_bill(6, CURRENT_DATE +  7);

-- Some payments: bill 2 fully paid, bill 3 partly paid
UPDATE bills SET amount_paid = 50 WHERE bill_id = 2;
UPDATE bills SET amount_paid = 70 WHERE bill_id = 3;

SELECT * FROM bills ORDER BY bill_id;

-- Tests for (c)
DO $$ BEGIN CALL pr_generate_bill(999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(1, CURRENT_DATE);                -- already billed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- ---------------------------------------------------------------------
-- (e) View: v_overdue_bills
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills ORDER BY due_on, full_name;   -- zero-charge bill 1, paid bill 2 and not-yet-due bills excluded

-- ---------------------------------------------------------------------
-- (f) Index for overdue-bill searches
--     Justification: overdue means "due_on in the past AND not fully paid".
--     A partial index on due_on that holds only unpaid bills is small
--     (paid bills drop out of it) and lets the date range be read in order.
-- ---------------------------------------------------------------------
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;

SET enable_seqscan = off;    -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_receivables at 00:30 daily
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
        SET total_due = EXCLUDED.total_due;           -- same date replaced, never added
END;
$$;

SELECT cron.schedule(
    'q7_refresh_receivables',
    '30 0 * * *',                                      -- every day at 00:30
    $job$CALL q7_water.pr_refresh_receivables()$job$
);

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();                         -- rerun: still one row for today
SELECT * FROM receivable_snapshot;                     -- 100 + 25 + 50 + 114 = 289.00

SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q7_refresh_receivables';
SELECT jobid, status, return_message, start_time FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;
