-- =====================================================================
-- ICT371 Advanced Database | Question 3: Library Returns and Overdue Fines
-- Student: Collins Kalela(202403266)
-- DBMS: PostgreSQL 14+ (pg_cron extension for part g)
-- Run the whole file top to bottom; it can be re-run safely.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- pg_cron uses GMT by default (Zambia is GMT+2). Set cron.timezone = 'Africa/Lusaka'
-- in postgresql.conf if you want the times below to be local.

DROP SCHEMA IF EXISTS q3_library CASCADE;
CREATE SCHEMA q3_library;
SET search_path = q3_library, public;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE books (
    book_id  SERIAL       PRIMARY KEY,
    title    VARCHAR(200) NOT NULL
);

CREATE TABLE loans (
    loan_id        SERIAL        PRIMARY KEY,
    book_id        INTEGER       NOT NULL REFERENCES books(book_id),
    borrower_name  VARCHAR(100)  NOT NULL,
    borrowed_on    DATE          NOT NULL,
    due_on         DATE          NOT NULL,
    returned_on    DATE          NULL,
    fine_amount    NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id          SERIAL     PRIMARY KEY,
    loan_id           INTEGER    NOT NULL REFERENCES loans(loan_id),
    old_returned_on   DATE       NULL,
    new_returned_on   DATE       NULL,
    changed_at        TIMESTAMP  NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date  DATE          PRIMARY KEY,
    overdue_count  INTEGER       NOT NULL CHECK (overdue_count >= 0),
    total_fine     NUMERIC(12,2) NOT NULL CHECK (total_fine >= 0)
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Computer Networks');

-- Six loans, all inserted open (returned_on NULL). The returned ones are
-- closed later through pr_return_loan so the fine and audit are produced
-- by the real logic.
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Chanda Mwila',   CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1 open, overdue
    (2, 'Mutale Banda',   CURRENT_DATE -  5, CURRENT_DATE +  9),  -- 2 open, on time
    (3, 'Natasha Phiri',  CURRENT_DATE - 20, CURRENT_DATE -  6),  -- 3 will be returned on time
    (1, 'Joseph Zulu',    CURRENT_DATE - 40, CURRENT_DATE - 26),  -- 4 will be returned late
    (2, 'Mercy Tembo',    CURRENT_DATE - 10, CURRENT_DATE -  3),  -- 5 open, overdue
    (3, 'Peter Lungu',    CURRENT_DATE -  3, CURRENT_DATE);       -- 6 open, due today (no fine)

-- ---------------------------------------------------------------------
-- (b) Function: fn_loan_fine  (K2 per day late, minimum 0)
--     LEAST(p_as_of, returned_on): when returned_on is NULL, LEAST simply
--     returns p_as_of; when a return date exists the earlier date wins,
--     so a returned loan stops accumulating fines.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id %', p_loan_id;
    END IF;

    v_end := LEAST(p_as_of, v_returned);
    RETURN 2 * GREATEST(v_end - v_due, 0);
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_return_loan
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC;
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date must not be NULL';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before the borrow date %', p_returned_on, v_borrowed;
    END IF;

    -- returned_on is still NULL here, so the function measures up to p_returned_on
    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine          -- return date and final fine stored together
    WHERE loan_id = p_loan_id;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: AFTER UPDATE row trigger logging returned_on changes
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)   -- NULL-safe "date really changed"
EXECUTE FUNCTION trg_fn_loan_audit();

-- Close the two returned loans (one on time, one late)
CALL pr_return_loan(3, CURRENT_DATE - 8);    -- returned before due date -> fine 0
CALL pr_return_loan(4, CURRENT_DATE - 20);   -- 6 days late -> fine 12

SELECT * FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;

-- Tests for (b), (c), (d)
SELECT loan_id, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today FROM loans ORDER BY loan_id;
-- loan 1: 32, loan 2: 0, loan 3: 0, loan 4: 12 (frozen at return), loan 5: 6, loan 6: 0

DO $$ BEGIN PERFORM fn_loan_fine(999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_return_loan(999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_return_loan(3, CURRENT_DATE);               -- already returned
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_return_loan(2, CURRENT_DATE - 100);          -- before borrowed_on
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- An UPDATE that leaves returned_on unchanged must not create an audit row
SELECT COUNT(*) AS audit_rows_before FROM loan_audit;
UPDATE loans SET borrower_name = borrower_name WHERE loan_id = 3;
SELECT COUNT(*) AS audit_rows_after FROM loan_audit;            -- same number

-- ---------------------------------------------------------------------
-- (e) View: v_overdue_loans
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;        -- loans 1 and 5 only

-- ---------------------------------------------------------------------
-- (f) Index for a given book's unreturned loans
--     A partial index holds only the rows with returned_on IS NULL, so it
--     stays small (most loans end up returned) and serves exactly this search.
-- ---------------------------------------------------------------------
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;

SET enable_seqscan = off;    -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_overdue at 00:10 daily
--     Assumption: the snapshot counts loans that are overdue and still
--     unreturned on p_as_of (borrowed on/before it, due before it, and
--     either never returned or returned after it), and sums their fines
--     as of that date.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND due_on < p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine    = EXCLUDED.total_fine;       -- same date is replaced
END;
$$;

SELECT cron.schedule(
    'q3_refresh_overdue',
    '10 0 * * *',                                       -- every day at 00:10
    $job$CALL q3_library.pr_refresh_overdue(CURRENT_DATE)$job$
);

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);                  -- rerun: still one row
SELECT * FROM overdue_summary;                          -- 2 loans (loans 1 and 5), K38

SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q3_refresh_overdue';
SELECT jobid, status, return_message, start_time FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;
