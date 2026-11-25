-- =====================================================================
-- ICT371 Advanced Database | Question 8: Transport Fleet Maintenance
-- Student: Collins Kalela (202403266)
-- DBMS: PostgreSQL 14+ (pg_cron extension for part g)
-- Run the whole file top to bottom; it can be re-run safely.
-- Service rule: a vehicle is due when current_odometer - last_service_odometer >= 5000 km.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- pg_cron uses GMT by default (Zambia is GMT+2). Set cron.timezone = 'Africa/Lusaka'
-- in postgresql.conf if you want the times below to be local.

DROP SCHEMA IF EXISTS q8_fleet CASCADE;
CREATE SCHEMA q8_fleet;
SET search_path = q8_fleet, public;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id             SERIAL      PRIMARY KEY,
    registration           VARCHAR(15) NOT NULL UNIQUE,
    current_odometer       INTEGER     NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer  INTEGER     NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id         SERIAL  PRIMARY KEY,
    vehicle_id      INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on         DATE    NOT NULL,
    start_odometer  INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer    INTEGER NOT NULL CHECK (end_odometer   >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id        INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service  INTEGER NOT NULL,
    flagged_on        DATE    NOT NULL DEFAULT CURRENT_DATE
);

-- Three vehicles in different service positions (km since service: 2000, 6000, 5000)
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABC 1234', 20000, 18000),
    ('BAF 5678', 30000, 24000),
    ('ALZ 9012', 15000, 10000);

-- ---------------------------------------------------------------------
-- (b) Function: fn_service_due
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_km INTEGER;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id %', p_vehicle_id;
    END IF;

    RETURN v_km >= 5000;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: BEFORE INSERT row trigger on trips
--     Checks the start odometer, rejects invalid mileage and moves the
--     vehicle's current_odometer to the trip end. This is the ONLY place
--     the odometer is updated, so it happens exactly once per trip.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
BEGIN
    -- lock the vehicle row so two trips cannot start from the same reading
    SELECT current_odometer INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id %', NEW.vehicle_id;
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)',
                        NEW.end_odometer, NEW.start_odometer;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at the current odometer % (got %)',
                        v_current, NEW.start_odometer;
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_record_trip (inserts the trip only; the trigger moves the odometer)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INTEGER,
                                           p_trip_on    DATE,
                                           p_start      INTEGER,
                                           p_end        INTEGER)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start and end odometer are all required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id %', p_vehicle_id;
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end odometer (%) must be greater than start odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);     -- no UPDATE of vehicles here
END;
$$;

-- ---------------------------------------------------------------------
-- (a) continued: six trips added through the procedure, after the trigger
-- ---------------------------------------------------------------------
CALL pr_record_trip(1, CURRENT_DATE - 10, 20000, 20300);
CALL pr_record_trip(1, CURRENT_DATE -  8, 20300, 20500);
CALL pr_record_trip(2, CURRENT_DATE -  9, 30000, 30400);
CALL pr_record_trip(2, CURRENT_DATE -  6, 30400, 30900);
CALL pr_record_trip(3, CURRENT_DATE -  7, 15000, 15250);
CALL pr_record_trip(3, CURRENT_DATE -  3, 15250, 15700);

SELECT * FROM trips ORDER BY trip_id;
SELECT * FROM vehicles ORDER BY vehicle_id;      -- odometers: 20500, 30900, 15700

-- Tests for (b)
SELECT vehicle_id, fn_service_due(vehicle_id) AS due FROM vehicles ORDER BY vehicle_id;  -- f, t, t
DO $$ BEGIN PERFORM fn_service_due(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Tests for (c) and (d)
DO $$ BEGIN CALL pr_record_trip(999, CURRENT_DATE, 1, 2);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown vehicle): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 20500, 20500);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (end not greater): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 20400, 20600);        -- wrong start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (wrong start): %', SQLERRM; END $$;
DO $$ BEGIN
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (1, CURRENT_DATE, 20500, 20100);                             -- direct SQL, bad mileage
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct SQL): %', SQLERRM; END $$;
SELECT vehicle_id, current_odometer FROM vehicles ORDER BY vehicle_id;  -- unchanged

-- ---------------------------------------------------------------------
-- (e) View: v_service_due
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due ORDER BY registration;     -- BAF 5678 (6900) and ALZ 9012 (5700)

-- ---------------------------------------------------------------------
-- (f) Index for one vehicle's trips in a date range
--     Justification: the query is "vehicle = X and trip_on between two
--     dates": equality on vehicle_id then a range on trip_on. The
--     composite index (vehicle_id, trip_on) reads that vehicle's entries
--     in date order and stops at the end of the range.
-- ---------------------------------------------------------------------
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;

SET enable_seqscan = off;    -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_service_alerts every Monday at 06:00
--     Upsert one alert per due vehicle (keeps the original flagged_on),
--     then delete alerts for vehicles that are no longer due.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service;

    DELETE FROM service_alerts a
    WHERE NOT EXISTS (
        SELECT 1 FROM vehicles v
        WHERE v.vehicle_id = a.vehicle_id
          AND v.current_odometer - v.last_service_odometer >= 5000
    );
END;
$$;

SELECT cron.schedule(
    'q8_refresh_service_alerts',
    '0 6 * * 1',                                         -- Mondays (1) at 06:00
    $job$CALL q8_fleet.pr_refresh_service_alerts()$job$
);

CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();                        -- rerun: still one alert per due vehicle
SELECT * FROM service_alerts ORDER BY vehicle_id;        -- vehicles 2 and 3

-- Service vehicle 2: alert must disappear on the next refresh
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;        -- only vehicle 3 remains

SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q8_refresh_service_alerts';
SELECT jobid, status, return_message, start_time FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;
