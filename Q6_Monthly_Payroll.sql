-- =====================================================================
-- ICT371 Advanced Database | Question 6: Monthly Payroll Processing
-- Student: Blessings Kyembe (202301658)
-- DBMS: PostgreSQL 14+ (pg_cron extension for part g)
-- Run the whole file top to bottom; it can be re-run safely.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- pg_cron uses GMT by default (Zambia is GMT+2). Set cron.timezone = 'Africa/Lusaka'
-- in postgresql.conf if you want the times below to be local.

DROP SCHEMA IF EXISTS q6_payroll CASCADE;
CREATE SCHEMA q6_payroll;
SET search_path = q6_payroll, public;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE employees (
    employee_id   SERIAL        PRIMARY KEY,
    full_name     VARCHAR(100)  NOT NULL,
    basic_salary  NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance     NUMERIC(12,2) NOT NULL CHECK (allowance    >= 0),
    deduction     NUMERIC(12,2) NOT NULL CHECK (deduction    >= 0),
    active        BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id   SERIAL        PRIMARY KEY,
    employee_id  INTEGER       NOT NULL REFERENCES employees(employee_id),
    pay_month    DATE          NOT NULL,
    gross_pay    NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay      NUMERIC(12,2) NOT NULL CHECK (net_pay   >= 0),
    CONSTRAINT ck_pay_month_first_day CHECK (EXTRACT(DAY FROM pay_month) = 1),
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id     SERIAL        PRIMARY KEY,
    employee_id  INTEGER       NOT NULL REFERENCES employees(employee_id),
    old_salary   NUMERIC(12,2) NOT NULL,
    new_salary   NUMERIC(12,2) NOT NULL,
    changed_at   TIMESTAMP     NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Dr. Samuel Mumba',  12000.00, 2000.00, 1500.00, TRUE),
    ('Grace Kunda',        8000.00, 1000.00,  900.00, TRUE),
    ('Peter Sakala',       6000.00,  500.00,  700.00, TRUE),
    ('Esther Lungu',       7000.00,  800.00,  800.00, TRUE);   -- becomes inactive later

-- ---------------------------------------------------------------------
-- (b) Function: fn_net_pay
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_net NUMERIC;
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Net pay for employee % would be negative (%)', p_employee_id, v_net;
    END IF;

    RETURN v_net;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_process_payroll (query FOR loop over active employees)
--     ON CONFLICT DO NOTHING leaves an existing month row untouched.
--     fn_net_pay raises for a bad employee, which aborts the whole CALL,
--     so no partial month is ever stored.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    r       RECORD;
    v_net   NUMERIC;
BEGIN
    IF p_month IS NULL THEN
        RAISE EXCEPTION 'p_month must not be NULL';
    END IF;
    IF EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month (got %)', p_month;
    END IF;

    FOR r IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active
        ORDER BY employee_id
    LOOP
        v_net := fn_net_pay(r.employee_id);          -- raises on invalid data

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing row unchanged
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: AFTER UPDATE logging real basic_salary changes
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE OF basic_salary ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- ---------------------------------------------------------------------
-- (a) continued: two payroll months. Esther is active for the first month
--     and then made inactive, so history for an inactive employee exists.
-- ---------------------------------------------------------------------
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date);
UPDATE employees SET active = FALSE WHERE employee_id = 4;
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date);

SELECT * FROM payroll ORDER BY pay_month, employee_id;     -- 4 rows + 3 rows

-- Tests for (b)
SELECT employee_id, fn_net_pay(employee_id) AS net_pay FROM employees ORDER BY employee_id;
DO $$ BEGIN PERFORM fn_net_pay(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Tests for (c): not a month start, and rerun leaves rows unchanged
DO $$ BEGIN CALL pr_process_payroll(DATE '2026-02-15');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

SELECT COUNT(*) AS rows_before FROM payroll;
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date);   -- rerun
SELECT COUNT(*) AS rows_after FROM payroll;                                                -- same

-- Negative net pay must fail the WHOLE call and store nothing for that month
UPDATE employees SET deduction = 99999 WHERE employee_id = 3;     -- Peter now has negative net
DO $$ BEGIN CALL pr_process_payroll((date_trunc('month', CURRENT_DATE))::date);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Whole call failed: %', SQLERRM; END $$;
SELECT COUNT(*) AS rows_for_current_month_still_0
FROM payroll WHERE pay_month = date_trunc('month', CURRENT_DATE)::date;
UPDATE employees SET deduction = 700 WHERE employee_id = 3;       -- restore

-- Tests for (d): a salary change is logged, an unchanged salary is not
UPDATE employees SET basic_salary = 12500 WHERE employee_id = 1;  -- logged
UPDATE employees SET basic_salary = basic_salary WHERE employee_id = 2;   -- not logged
UPDATE employees SET allowance = allowance + 100 WHERE employee_id = 2;   -- not logged
SELECT * FROM salary_audit ORDER BY audit_id;                     -- exactly one row
UPDATE employees SET basic_salary = 12000 WHERE employee_id = 1;  -- put it back (logged too)

-- ---------------------------------------------------------------------
-- (e) View: v_payroll_report (no filter on active, so history stays visible)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;     -- Esther's first month still shown

-- ---------------------------------------------------------------------
-- (f) Index for "all employees in one pay_month"
--     Justification: the unique index uq_employee_month is on
--     (employee_id, pay_month). Because employee_id is its leading column,
--     it cannot efficiently find rows by pay_month alone. A single-column
--     index on pay_month fixes that without repeating the (employee_id,
--     pay_month) pair already indexed.
-- ---------------------------------------------------------------------
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;

SET enable_seqscan = off;    -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: 02:00 on the 1st of every month, for the previous month
-- ---------------------------------------------------------------------
SELECT cron.schedule(
    'q6_process_payroll',
    '0 2 1 * *',                       -- minute 0, hour 2, day-of-month 1, every month
    $job$CALL q6_payroll.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$job$
);

-- Inspect the job definition
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'q6_process_payroll';

-- Inspect the run history (one row per execution; empty until the job first runs)
SELECT jobid, runid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'q6_process_payroll')
ORDER BY start_time DESC;
