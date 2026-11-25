-- =====================================================================
-- ICT371 Advanced Database | Question 4: Clinic Appointment Scheduling
-- Student: Collins Kalela (202403266)
-- DBMS: PostgreSQL 14+ (pg_cron extension for part g)
-- Run the whole file top to bottom; it can be re-run safely.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- pg_cron uses GMT by default (Zambia is GMT+2). Set cron.timezone = 'Africa/Lusaka'
-- in postgresql.conf if you want the times below to be local.

DROP SCHEMA IF EXISTS q4_clinic CASCADE;
CREATE SCHEMA q4_clinic;
SET search_path = q4_clinic, public;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE patients (
    patient_id  SERIAL       PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id  SERIAL       PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id   SERIAL      PRIMARY KEY,
    patient_id       INTEGER     NOT NULL REFERENCES patients(patient_id),
    doctor_id        INTEGER     NOT NULL REFERENCES doctors(doctor_id),
    appointment_day  DATE        NOT NULL,
    slot_time        TIME        NOT NULL,
    status           VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT ck_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED')),
    CONSTRAINT ck_slot   CHECK (slot_time IN ('09:00'::time, '10:00'::time,
                                              '11:00'::time, '12:00'::time))
);

CREATE TABLE clinic_summary (
    summary_date    DATE    PRIMARY KEY,
    booked_count    INTEGER NOT NULL DEFAULT 0,
    attended_count  INTEGER NOT NULL DEFAULT 0,
    cancelled_count INTEGER NOT NULL DEFAULT 0
);

INSERT INTO patients (full_name) VALUES
    ('Chanda Mwila'), ('Mutale Banda'), ('Natasha Phiri');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Samuel Mumba'), ('Dr. Grace Kunda'), ('Dr. Peter Sakala');

-- Six appointments, none sharing a doctor/date/slot with another non-cancelled one.
-- Yesterday's rows are inserted directly because the procedure refuses past dates.
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
    (2, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
    (3, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
    (1, 2, CURRENT_DATE - 1, '11:00', 'ATTENDED'),
    (2, 3, CURRENT_DATE - 1, '12:00', 'CANCELLED'),
    (3, 3, CURRENT_DATE - 1, '09:00', 'ATTENDED');

-- ---------------------------------------------------------------------
-- (b) Function: fn_daily_load
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count          -- COUNT returns 0 when the day has no bookings
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger (created before the procedure so the procedure relies on it
--     for the clash rule): BEFORE INSERT OR UPDATE row trigger
--     "appointment_id IS DISTINCT FROM NEW.appointment_id" excludes the row
--     being changed on UPDATE (and is harmless on INSERT).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_appointment_clash()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1
            FROM appointments a
            WHERE a.doctor_id       = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time       = NEW.slot_time
              AND a.status         <> 'CANCELLED'
              AND a.appointment_id IS DISTINCT FROM NEW.appointment_id
        ) THEN
            RAISE EXCEPTION 'Clash: doctor % is already booked on % at %',
                            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_appointment_clash();

-- Safety net for two sessions booking at the same instant (a trigger alone
-- cannot see another session's uncommitted row). Cancelled rows are ignored.
CREATE UNIQUE INDEX uq_active_slot
    ON appointments (doctor_id, appointment_day, slot_time)
    WHERE status <> 'CANCELLED';

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_book_appointment
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INTEGER,
                                                p_doctor_id  INTEGER,
                                                p_day        DATE,
                                                p_slot       TIME)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_patient_id IS NULL OR p_doctor_id IS NULL OR p_day IS NULL OR p_slot IS NULL THEN
        RAISE EXCEPTION 'All parameters are required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient_id %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id %', p_doctor_id;
    END IF;
    IF p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book a past date (%)', p_day;
    END IF;
    IF p_slot NOT IN ('09:00'::time, '10:00'::time, '11:00'::time, '12:00'::time) THEN
        RAISE EXCEPTION 'Unsupported slot %. Use 09:00, 10:00, 11:00 or 12:00', p_slot;
    END IF;

    -- the clash trigger rejects a double booking here
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- Tests
CALL pr_book_appointment(3, 1, CURRENT_DATE + 1, '11:00');     -- valid
SELECT * FROM appointments ORDER BY appointment_id;

SELECT fn_daily_load(1, CURRENT_DATE)      AS dr1_today,          -- 2
       fn_daily_load(3, CURRENT_DATE - 1)  AS dr3_yesterday,      -- 1 (the other is cancelled)
       fn_daily_load(3, CURRENT_DATE + 30) AS dr3_empty_day;      -- 0

DO $$ BEGIN PERFORM fn_daily_load(999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_book_appointment(2, 1, CURRENT_DATE + 1, '11:00');   -- same doctor/day/slot
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_book_appointment(2, 1, CURRENT_DATE - 1, '09:00');   -- past date
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_book_appointment(2, 1, CURRENT_DATE + 1, '15:00');   -- unsupported slot
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_book_appointment(99, 1, CURRENT_DATE + 1, '12:00');  -- unknown patient
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- UPDATE: moving appointment 2 into doctor 1's 09:00 slot (taken by appointment 1) is rejected...
DO $$ BEGIN UPDATE appointments SET slot_time = '09:00' WHERE appointment_id = 2;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
-- ...but updating a row without changing its slot does not clash with itself
UPDATE appointments SET status = 'ATTENDED' WHERE appointment_id = 1;
UPDATE appointments SET status = 'BOOKED'   WHERE appointment_id = 1;

-- ---------------------------------------------------------------------
-- (e) View: v_today_appointments (no phone/ID/other patient data)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id,
       p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time, doctor_name;

-- ---------------------------------------------------------------------
-- (f) Non-unique index
--     Justification: the common search is "this doctor's appointments on
--     this day". Both columns are equality tests, so one composite index
--     (appointment_day, doctor_id) answers it without scanning the table;
--     day first also serves day-only reports such as the daily summary.
-- ---------------------------------------------------------------------
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

SET enable_seqscan = off;    -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT appointment_id, patient_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_clinic_summary at 01:00 daily
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count    = EXCLUDED.booked_count,
            attended_count  = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;     -- rerun replaces the row
END;
$$;

SELECT cron.schedule(
    'q4_refresh_clinic_summary',
    '0 1 * * *',                                             -- every day at 01:00
    $job$CALL q4_clinic.pr_refresh_clinic_summary(CURRENT_DATE - 1)$job$
);

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);            -- rerun: still one row
SELECT * FROM clinic_summary;                                -- 0 booked, 2 attended, 1 cancelled

SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q4_refresh_clinic_summary';
SELECT jobid, status, return_message, start_time FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;
