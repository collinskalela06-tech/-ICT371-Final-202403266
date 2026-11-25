-- =====================================================================
-- ICT371 Advanced Database | Question 9: Farmer Cooperative Maize Deliveries
-- Student: Blessings Kyembe (202301658)
-- DBMS: PostgreSQL 14+ (pg_cron extension for part g)
-- Run the whole file top to bottom; it can be re-run safely.
-- Rates: grade A K5/kg, grade B K4/kg, grade C K3/kg.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- pg_cron uses GMT by default (Zambia is GMT+2). Set cron.timezone = 'Africa/Lusaka'
-- in postgresql.conf if you want the times below to be local.

DROP SCHEMA IF EXISTS q9_maize CASCADE;
CREATE SCHEMA q9_maize;
SET search_path = q9_maize, public;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE farmers (
    farmer_id      SERIAL       PRIMARY KEY,
    farmer_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id   SERIAL        PRIMARY KEY,
    farmer_id     INTEGER       NOT NULL REFERENCES farmers(farmer_id),
    grade         CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg     NUMERIC(10,2) NOT NULL,
    unit_rate     NUMERIC(10,2) NOT NULL,     -- filled by the trigger
    total_value   NUMERIC(12,2) NOT NULL,     -- filled by the trigger
    delivered_on  DATE          NOT NULL,
    is_paid       BOOLEAN       NOT NULL DEFAULT FALSE
);
-- NOT NULL on unit_rate/total_value is safe: constraints are checked
-- after BEFORE triggers run, so the trigger has already supplied them.

CREATE TABLE daily_purchases (
    purchase_date  DATE          PRIMARY KEY,
    total_weight   NUMERIC(12,2) NOT NULL,
    total_value    NUMERIC(14,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Bwalya Chileshe'),
    ('F002', 'Namukolo Siame'),
    ('F003', 'Kelvin Mutale');      -- will end with no unpaid deliveries

-- ---------------------------------------------------------------------
-- (b) Function: fn_maize_rate
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    v_rate NUMERIC;
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade must not be NULL';
    END IF;

    v_rate := CASE p_grade WHEN 'A' THEN 5.00 WHEN 'B' THEN 4.00 WHEN 'C' THEN 3.00 END;

    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade "%". Use A, B or C', p_grade;
    END IF;
    RETURN v_rate;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: BEFORE INSERT OR UPDATE on deliveries
--     Pricing lives here, so direct SQL follows the same rule as the
--     procedure. Any rate/total a user supplies is overwritten.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_delivery_pricing()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be greater than zero (got %)', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_delivery_pricing();

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_receive_delivery
--     Inserts only the basic fields (is_paid false); unit_rate and
--     total_value are supplied by the trigger.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INTEGER,
                                                p_grade     TEXT,
                                                p_weight    NUMERIC,
                                                p_date      DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_farmer_id IS NULL OR p_grade IS NULL OR p_weight IS NULL OR p_date IS NULL THEN
        RAISE EXCEPTION 'Farmer, grade, weight and date are all required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id %', p_farmer_id;
    END IF;
    IF p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be greater than zero (got %)', p_weight;
    END IF;
    PERFORM fn_maize_rate(p_grade);                      -- rejects an unsupported grade early

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- ---------------------------------------------------------------------
-- (a) continued: six deliveries (all grades, both payment states),
--     loaded through the procedure after the trigger exists
-- ---------------------------------------------------------------------
CALL pr_receive_delivery(1, 'A', 100,   CURRENT_DATE - 1);
CALL pr_receive_delivery(1, 'B',  50.5, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 200,   CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'A',  80,   CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'B', 120,   CURRENT_DATE - 3);
CALL pr_receive_delivery(3, 'C',  60,   CURRENT_DATE);

-- Mark some as paid (the UPDATE also passes through the trigger)
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 3, 5, 6);

SELECT * FROM deliveries ORDER BY delivery_id;

-- Tests for (b)
SELECT fn_maize_rate('A') AS a, fn_maize_rate('B') AS b, fn_maize_rate('C') AS c;
DO $$ BEGIN PERFORM fn_maize_rate(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_maize_rate('D');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Tests for (c)
DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (farmer): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (weight): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'Z', 10, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (grade): %', SQLERRM; END $$;

-- Tests for (d): direct SQL with a wrong rate/total is corrected, bad weight is refused
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
VALUES (1, 'A', 10, 999, 9990, CURRENT_DATE, FALSE);
SELECT delivery_id, grade, weight_kg, unit_rate, total_value
FROM deliveries ORDER BY delivery_id DESC LIMIT 1;           -- 5.00 and 50.00, not 999

DO $$ BEGIN
    INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
    VALUES (1, 'B', 0, 4, 0, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Direct INSERT rejected: %', SQLERRM; END $$;

DELETE FROM deliveries WHERE delivery_id = 7;                -- remove the test row to keep totals tidy

-- ---------------------------------------------------------------------
-- (e) View: v_farmer_amount_due (LEFT JOIN so farmers with nothing unpaid show 0)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0) AS total_unpaid
FROM farmers f
LEFT JOIN deliveries d
       ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;    -- F003 shows 0

-- ---------------------------------------------------------------------
-- (f) Composite index for a farmer's deliveries between two dates
--     Justification: equality on farmer_id then a range on delivered_on.
--     (farmer_id, delivered_on) lets PostgreSQL go to one farmer's block
--     of the index and read only the requested date range, in order.
-- ---------------------------------------------------------------------
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;

SET enable_seqscan = off;    -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_purchases at 01:30 daily
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
        SET total_weight = EXCLUDED.total_weight,
            total_value  = EXCLUDED.total_value;        -- replaced, not added
END;
$$;

SELECT cron.schedule(
    'q9_refresh_purchases',
    '30 1 * * *',                                       -- every day at 01:30
    $job$CALL q9_maize.pr_refresh_purchases(CURRENT_DATE - 1)$job$
);

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);            -- rerun: totals identical
SELECT * FROM daily_purchases;                          -- 230.5 kg, 500 + 202 + 400 = 1102.00

SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q9_refresh_purchases';
SELECT jobid, status, return_message, start_time FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;
