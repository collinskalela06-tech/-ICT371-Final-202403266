-- =====================================================================
-- ICT371 Advanced Database | Question 5: Hostel Room Allocation
-- Student: Collins Kalela (202403266)
-- DBMS: PostgreSQL 14+ (pg_cron extension for part g)
-- Run the whole file top to bottom; it can be re-run safely.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- pg_cron uses GMT by default (Zambia is GMT+2). Set cron.timezone = 'Africa/Lusaka'
-- in postgresql.conf if you want the times below to be local.

DROP SCHEMA IF EXISTS q5_hostel CASCADE;
CREATE SCHEMA q5_hostel;
SET search_path = q5_hostel, public;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE students (
    student_id      SERIAL       PRIMARY KEY,
    student_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name       VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id      SERIAL      PRIMARY KEY,
    room_number  VARCHAR(10) NOT NULL UNIQUE,
    capacity     INTEGER     NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id  SERIAL      PRIMARY KEY,
    student_id     INTEGER     NOT NULL REFERENCES students(student_id),
    room_id        INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on   DATE        NOT NULL,
    released_on    DATE        NULL,
    status         VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
    CONSTRAINT ck_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT ck_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date  DATE    NOT NULL,
    room_id        INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds  INTEGER NOT NULL CHECK (occupied_beds >= 0),
    free_beds      INTEGER NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
    ('202301001', 'Chanda Mwila'),
    ('202301002', 'Mutale Banda'),
    ('202301003', 'Natasha Phiri'),
    ('202301004', 'Joseph Zulu'),
    ('202301005', 'Mercy Tembo');

INSERT INTO rooms (room_number, capacity) VALUES
    ('R101', 2),     -- will be full
    ('R102', 3),     -- will be partly occupied
    ('R103', 2);     -- will be empty (only ended history)

-- ---------------------------------------------------------------------
-- (b) Function: fn_free_beds
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active           -- ENDED rows are ignored
    FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: BEFORE INSERT OR UPDATE row trigger
--     Enforces capacity and one ACTIVE allocation per student even for
--     direct SQL. "allocation_id IS DISTINCT FROM NEW.allocation_id"
--     excludes the row being updated from the counts.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_others   INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        -- Lock the room row so two sessions cannot both take the last bed
        SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;

        IF EXISTS (SELECT 1 FROM allocations a
                   WHERE a.student_id = NEW.student_id
                     AND a.status = 'ACTIVE'
                     AND a.allocation_id IS DISTINCT FROM NEW.allocation_id) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        SELECT COUNT(*) INTO v_others
        FROM allocations a
        WHERE a.room_id = NEW.room_id
          AND a.status = 'ACTIVE'
          AND a.allocation_id IS DISTINCT FROM NEW.allocation_id;

        IF v_others + 1 > v_capacity THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocation_rules();

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_allocate_room
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id   INTEGER,
                                             p_room_id      INTEGER,
                                             p_allocated_on DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_student_id IS NULL OR p_room_id IS NULL OR p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'All parameters are required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;
    -- lock the room first so the availability check below is reliable
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id %', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- ---------------------------------------------------------------------
-- (a) continued: allocations (full, partly occupied and empty rooms)
-- ---------------------------------------------------------------------
CALL pr_allocate_room(1, 1, CURRENT_DATE - 60);   -- R101 gets 2 of 2 -> full
CALL pr_allocate_room(2, 1, CURRENT_DATE - 55);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 30);   -- R102 gets 1 of 3 -> partly occupied

-- History row: Joseph lived in R103 and left; it must not occupy a bed
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, CURRENT_DATE - 120, CURRENT_DATE - 40, 'ENDED');

SELECT * FROM allocations ORDER BY allocation_id;

-- Tests for (b) and (c)
SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY room_id;   -- 0, 2, 2

DO $$ BEGIN PERFORM fn_free_beds(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_allocate_room(5, 1, CURRENT_DATE);        -- R101 is full
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_allocate_room(3, 3, CURRENT_DATE);        -- student 3 already ACTIVE
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_allocate_room(99, 3, CURRENT_DATE);       -- unknown student
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

CALL pr_allocate_room(4, 2, CURRENT_DATE);   -- ended history does not block a new allocation (R103 stays empty)

-- Tests for (d): direct SQL is also protected by the trigger
DO $$ BEGIN
    INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (5, 1, CURRENT_DATE, 'ACTIVE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Direct INSERT rejected (capacity): %', SQLERRM; END $$;

DO $$ BEGIN
    INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (1, 2, CURRENT_DATE, 'ACTIVE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Direct INSERT rejected (one active): %', SQLERRM; END $$;

-- UPDATE excluding itself: changing a date on an existing ACTIVE row is allowed even in a full room
UPDATE allocations SET allocated_on = allocated_on + 1 WHERE allocation_id = 1;

-- ---------------------------------------------------------------------
-- (e) View: v_room_occupancy (LEFT JOIN keeps rooms with no allocations)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)               AS occupied_beds,
       r.capacity - COUNT(a.allocation_id)  AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_id;

-- ---------------------------------------------------------------------
-- (f) Index for ACTIVE allocations by room
--     Justification: capacity checks and occupancy reports only count
--     ACTIVE rows for one room. A partial index stores just those rows,
--     so it stays small as ENDED history grows and the lookup by room_id
--     is fast.
-- ---------------------------------------------------------------------
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;

SET enable_seqscan = off;    -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT allocation_id, student_id
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_occupancy at 23:55 daily
--     Primary key (snapshot_date, room_id) + ON CONFLICT = one row per
--     date and room, values replaced on rerun.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
        SET occupied_beds = EXCLUDED.occupied_beds,
            free_beds     = EXCLUDED.free_beds;
END;
$$;

SELECT cron.schedule(
    'q5_refresh_occupancy',
    '55 23 * * *',                                     -- every day at 23:55
    $job$CALL q5_hostel.pr_refresh_occupancy()$job$
);

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();                           -- rerun: still one row per room
SELECT * FROM occupancy_snapshot ORDER BY room_id;

SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q5_refresh_occupancy';
SELECT jobid, status, return_message, start_time FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;
