-- =====================================================================
-- ICT371 Advanced Database | Question 2: University Fee Payments
-- Student: Blessings Kyembe (202301658)
-- DBMS: PostgreSQL 14+ (pg_cron extension for part g)
-- Run the whole file top to bottom; it can be re-run safely.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- pg_cron uses GMT by default (Zambia is GMT+2). Set cron.timezone = 'Africa/Lusaka'
-- in postgresql.conf if you want the times below to be local.

DROP SCHEMA IF EXISTS q2_fees CASCADE;
CREATE SCHEMA q2_fees;
SET search_path = q2_fees, public;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE students (
    student_id      SERIAL        PRIMARY KEY,
    student_number  VARCHAR(20)   NOT NULL UNIQUE,
    full_name       VARCHAR(100)  NOT NULL,
    fee_due         NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id  SERIAL        PRIMARY KEY,
    student_id  INTEGER       NOT NULL REFERENCES students(student_id),
    amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on     DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id    SERIAL        PRIMARY KEY,
    payment_id  INTEGER       NOT NULL REFERENCES payments(payment_id),
    student_id  INTEGER       NOT NULL REFERENCES students(student_id),
    amount      NUMERIC(12,2) NOT NULL,
    logged_at   TIMESTAMP     NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date  DATE          PRIMARY KEY,
    payment_count    INTEGER       NOT NULL CHECK (payment_count >= 0),
    total_amount     NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0)
);

-- Three students with different fee balances (payments are loaded later
-- through the procedure; student 3 will have no payments at all)
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('202301001', 'Chanda Mwila',     5000.00),
    ('202301002', 'Mutale Banda',     3000.00),
    ('202301003', 'Natasha Phiri',    4500.00);

-- ---------------------------------------------------------------------
-- (b) Function: fn_fee_balance
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_fee  NUMERIC;
    v_paid NUMERIC;
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;

    -- COALESCE returns 0 when there are no payments, so the full fee comes back
    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_receive_payment
--     It only inserts into payments. It does NOT touch fee_due and does
--     NOT write the audit row (the trigger in part d does that).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INTEGER,
                                               p_amount     NUMERIC,
                                               p_paid_on    DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be greater than zero (got %)', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date must not be NULL';
    END IF;

    -- Lock the student row so two simultaneous payments cannot both pass the check
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % (credit balances are not allowed)',
                        p_amount, v_balance;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: AFTER INSERT row trigger on payments -> payment_audit
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_payment_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

-- ---------------------------------------------------------------------
-- (a) continued: six payments loaded through the procedure
--     Student 1 pays 3 times (balance 2000), student 2 pays 3 times
--     (fully settled), student 3 has no payments.
-- ---------------------------------------------------------------------
CALL pr_receive_payment(1, 1000.00, CURRENT_DATE - 2);
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(1,  500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 3);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE);

SELECT * FROM payments ORDER BY payment_id;
SELECT * FROM payment_audit ORDER BY audit_id;    -- six rows written by the trigger only

-- Tests for (b) and (c)
SELECT student_id, fn_fee_balance(student_id) AS balance FROM students ORDER BY student_id;
-- expected: 2000.00, 0.00, 4500.00 (student 3 has no payments -> full fee)

DO $$
BEGIN
    PERFORM fn_fee_balance(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'fn_fee_balance rejected: %', SQLERRM;
END $$;

DO $$ BEGIN CALL pr_receive_payment(1, NULL, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_payment(1, 0, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_payment(1, -50, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_payment(1, 2500, CURRENT_DATE);    -- balance is only 2000
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

SELECT student_id, fee_due FROM students ORDER BY student_id;   -- fee_due never changes

-- ---------------------------------------------------------------------
-- (e) View: v_fee_balances (only students who still owe)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

SELECT * FROM v_fee_balances;      -- Mutale Banda (settled) is excluded

-- ---------------------------------------------------------------------
-- (f) Composite index
--     Justification: the query uses equality on student_id and a range on
--     paid_on. With student_id first, PostgreSQL goes straight to that
--     student's entries and, because paid_on is second, reads the date
--     range as one contiguous slice of the index.
-- ---------------------------------------------------------------------
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;

SET enable_seqscan = off;    -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_collections at 01:00 daily
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
        SET payment_count = EXCLUDED.payment_count,
            total_amount  = EXCLUDED.total_amount;    -- replaces, never adds
END;
$$;

SELECT cron.schedule(
    'q2_refresh_collections',
    '0 1 * * *',                                       -- every day at 01:00
    $job$CALL q2_fees.pr_refresh_collections(CURRENT_DATE - 1)$job$
);

-- Prove reruns replace the row
CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);
SELECT * FROM daily_collections;     -- yesterday: 3 payments, 3000.00

SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q2_refresh_collections';
SELECT jobid, status, return_message, start_time FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;
