-- =====================================================================
-- ICT371 Advanced Database | Question 10: Scholarship Application Assessment
-- Student: Blessings Kyembe (202301658)
-- DBMS: PostgreSQL 14+ (pg_cron extension for part g)
-- Run the whole file top to bottom; it can be re-run safely.
-- Eligibility: age 18-25 inclusive, monthly income <= K3,000, average mark >= 70.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- pg_cron uses GMT by default (Zambia is GMT+2). Set cron.timezone = 'Africa/Lusaka'
-- in postgresql.conf if you want the times below to be local.

DROP SCHEMA IF EXISTS q10_scholarship CASCADE;
CREATE SCHEMA q10_scholarship;
SET search_path = q10_scholarship, public;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE students (
    student_id      SERIAL       PRIMARY KEY,
    student_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name       VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id      SERIAL        PRIMARY KEY,
    student_id          INTEGER       NOT NULL REFERENCES students(student_id),
    age_at_application  INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income      NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark        NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on        DATE          NOT NULL DEFAULT CURRENT_DATE,
    status              VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id        SERIAL      PRIMARY KEY,
    application_id  INTEGER     NOT NULL REFERENCES applications(application_id),
    old_status      VARCHAR(10) NOT NULL,
    new_status      VARCHAR(10) NOT NULL,
    changed_at      TIMESTAMP   NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('202301001', 'Chanda Mwila'),
    ('202301002', 'Mutale Banda'),
    ('202301003', 'Natasha Phiri');

-- Six PENDING applications: normal pass, boundary passes, and fails on
-- each rule (age, income, mark just below 70)
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 20, 2500.00, 75.00, CURRENT_DATE - 10),   -- 1 qualifies
    (1, 18, 3000.00, 70.00, CURRENT_DATE -  9),   -- 2 boundary: all minimums -> qualifies
    (2, 25, 3000.00, 70.00, CURRENT_DATE -  8),   -- 3 boundary: age 25 inclusive -> qualifies
    (2, 17, 1000.00, 90.00, CURRENT_DATE -  7),   -- 4 too young -> rejected
    (3, 22, 3000.01, 80.00, CURRENT_DATE -  6),   -- 5 income K0.01 too high -> rejected
    (3, 24, 2000.00, 69.99, CURRENT_DATE -  5);   -- 6 mark just below 70 -> rejected

-- ---------------------------------------------------------------------
-- (b) Function: fn_scholarship_eligible
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative (got %)', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25      -- inclusive
       AND p_income <= 3000
       AND p_mark   >= 70;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: AFTER UPDATE row trigger logging real status changes
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)     -- unchanged status -> no audit row
EXECUTE FUNCTION trg_fn_decision_audit();

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_assess_application
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_status   VARCHAR(10);
    v_age      INTEGER;
    v_income   NUMERIC;
    v_mark     NUMERIC;
    v_eligible BOOLEAN;
BEGIN
    -- lock the row so two assessors cannot decide the same application twice
    SELECT status, age_at_application, monthly_income, average_mark
      INTO v_status, v_age, v_income, v_mark
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id %', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % was already assessed (status %)', p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);

    UPDATE applications
    SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- Tests for (b)
SELECT fn_scholarship_eligible(18, 3000, 70)     AS all_minimums,    -- true
       fn_scholarship_eligible(25, 3000, 70)     AS age_25,          -- true
       fn_scholarship_eligible(26, 1000, 90)     AS age_26,          -- false
       fn_scholarship_eligible(20, 3000.01, 90)  AS income_over,     -- false
       fn_scholarship_eligible(20, 1000, 69.99)  AS mark_under;      -- false

DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 100, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 100, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 100, 101);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Tests for (c) and (d): assess one application, then try again
CALL pr_assess_application(1);
SELECT application_id, status FROM applications ORDER BY application_id;
SELECT * FROM decision_audit ORDER BY audit_id;                    -- 1 row: PENDING -> APPROVED

DO $$ BEGIN CALL pr_assess_application(1);                          -- already assessed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(999);                        -- unknown
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- An UPDATE that keeps the same status creates no audit row
UPDATE applications SET status = status WHERE application_id = 1;
UPDATE applications SET monthly_income = monthly_income WHERE application_id = 2;
SELECT COUNT(*) AS audit_rows_still_1 FROM decision_audit;

-- ---------------------------------------------------------------------
-- (e) View: v_approved_applicants (no household income exposed)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- ---------------------------------------------------------------------
-- (f) Index for status within a submitted_on range
--     Justification: the search is equality on status plus a range on
--     submitted_on. Equality column first, range column second means the
--     matching rows form one contiguous slice of the index, already in
--     date order (this also serves the weekly job that looks for PENDING).
-- ---------------------------------------------------------------------
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;

SET enable_seqscan = off;    -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT application_id, student_id, submitted_on
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_assess_pending every Monday at 08:00
--     Only PENDING rows are selected, and pr_assess_application refuses
--     anything already decided, so reruns never reassess or duplicate audit rows.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

SELECT cron.schedule(
    'q10_assess_pending',
    '0 8 * * 1',                                        -- Mondays (1) at 08:00
    $job$CALL q10_scholarship.pr_assess_pending()$job$
);

CALL pr_assess_pending();                               -- assesses applications 2 to 6
SELECT application_id, age_at_application, monthly_income, average_mark, status
FROM applications ORDER BY application_id;              -- 1,2,3 APPROVED; 4,5,6 REJECTED
SELECT * FROM decision_audit ORDER BY audit_id;         -- 6 rows, one per decision

CALL pr_assess_pending();                               -- rerun: nothing pending, nothing changes
SELECT COUNT(*) AS audit_rows_still_6 FROM decision_audit;

SELECT * FROM v_approved_applicants ORDER BY student_number;   -- approved only, no income column

SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q10_assess_pending';
SELECT jobid, status, return_message, start_time FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;
