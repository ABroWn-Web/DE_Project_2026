-- =====================================================================
-- Practo Doctor Appointments: load the seed data (Phase 2)
--
-- Run from the repository root (\copy paths are relative to where psql runs),
-- after sql/01_schema.sql:
--     unzip seed_data.zip
--     psql -d practo -f sql/02_load_data.sql
--
-- For the large dataset (Phase 5) change only the folder name:
--     seed_data/  ->  large_data/
-- =====================================================================
\set ON_ERROR_STOP on
SET search_path TO practo;
SET timezone TO 'Asia/Kolkata';

-- ---------------------------------------------------------------------
-- 1. Load, parents before children, so every foreign key already has
--    its target row:
--    cities, specializations -> doctors -> doctor_specializations
--    cities -> clinics -> doctor_schedules
--    cities -> patients -> appointments -> prescriptions -> prescription_items
--                                       -> doctor_reviews
--    Empty CSV fields become NULL (default for FORMAT csv).
-- ---------------------------------------------------------------------
\echo 'Loading cities ...'
\copy cities                 FROM 'seed_data/cities.csv'                 WITH (FORMAT csv, HEADER true)
\echo 'Loading specializations ...'
\copy specializations        FROM 'seed_data/specializations.csv'        WITH (FORMAT csv, HEADER true)
\echo 'Loading doctors ...'
\copy doctors                FROM 'seed_data/doctors.csv'                WITH (FORMAT csv, HEADER true)
\echo 'Loading doctor_specializations ...'
\copy doctor_specializations FROM 'seed_data/doctor_specializations.csv' WITH (FORMAT csv, HEADER true)
\echo 'Loading clinics ...'
\copy clinics                FROM 'seed_data/clinics.csv'                WITH (FORMAT csv, HEADER true)
\echo 'Loading doctor_schedules ...'
\copy doctor_schedules       FROM 'seed_data/doctor_schedules.csv'       WITH (FORMAT csv, HEADER true)
\echo 'Loading patients ...'
\copy patients               FROM 'seed_data/patients.csv'               WITH (FORMAT csv, HEADER true)
\echo 'Loading appointments ...'
\copy appointments           FROM 'seed_data/appointments.csv'           WITH (FORMAT csv, HEADER true)
\echo 'Loading prescriptions ...'
\copy prescriptions          FROM 'seed_data/prescriptions.csv'          WITH (FORMAT csv, HEADER true)
\echo 'Loading prescription_items ...'
\copy prescription_items     FROM 'seed_data/prescription_items.csv'     WITH (FORMAT csv, HEADER true)
\echo 'Loading doctor_reviews ...'
\copy doctor_reviews         FROM 'seed_data/doctor_reviews.csv'         WITH (FORMAT csv, HEADER true)

-- fresh planner statistics for every table
ANALYZE;

-- ---------------------------------------------------------------------
-- 2. Row counts (expected = README Phase 2 table)
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Row counts ==='
SELECT t.table_name, t.loaded, t.expected,
       CASE WHEN t.loaded = t.expected THEN 'OK' ELSE 'MISMATCH' END AS result
FROM (
              SELECT 1 AS ord, 'cities' AS table_name, (SELECT count(*) FROM cities) AS loaded, 10 AS expected
    UNION ALL SELECT 2, 'specializations',        (SELECT count(*) FROM specializations),        15
    UNION ALL SELECT 3, 'doctors',                (SELECT count(*) FROM doctors),                3000
    UNION ALL SELECT 4, 'doctor_specializations', (SELECT count(*) FROM doctor_specializations), 3700
    UNION ALL SELECT 5, 'clinics',                (SELECT count(*) FROM clinics),                1500
    UNION ALL SELECT 6, 'doctor_schedules',       (SELECT count(*) FROM doctor_schedules),       30499
    UNION ALL SELECT 7, 'patients',               (SELECT count(*) FROM patients),               40000
    UNION ALL SELECT 8, 'appointments',           (SELECT count(*) FROM appointments),           150000
    UNION ALL SELECT 9, 'prescriptions',          (SELECT count(*) FROM prescriptions),          97234
    UNION ALL SELECT 10, 'prescription_items',    (SELECT count(*) FROM prescription_items),     243085
    UNION ALL SELECT 11, 'doctor_reviews',        (SELECT count(*) FROM doctor_reviews),         30339
) t
ORDER BY t.ord;
-- (on large_data/ the "expected" column no longer applies; just read "loaded")

-- ---------------------------------------------------------------------
-- 3. Integrity checks: rules a CHECK constraint cannot express because
--    they span several rows or tables. Each returns the number of rows
--    that break the rule; 0 = rule holds.
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Integrity checks (violations; 0 = rule holds) ==='
SELECT * FROM (
    -- IC1: every appointment lies inside one of the doctor's schedule blocks
    --      for that weekday, at the same place (same clinic, or video),
    --      starts on the slot grid and lasts exactly slot_minutes.
    SELECT 'IC1  appointment fits doctor''s schedule (weekday, place, slot grid, length)' AS rule,
           count(*) AS violations
    FROM appointments a
    WHERE NOT EXISTS (
        SELECT 1 FROM doctor_schedules sc
        WHERE sc.doctor_id = a.doctor_id
          AND sc.weekday   = EXTRACT(ISODOW FROM a.slot_start)
          AND sc.clinic_id IS NOT DISTINCT FROM a.clinic_id
          AND a.slot_start::time >= sc.start_time
          AND a.slot_end::time   <= sc.end_time
          AND (EXTRACT(EPOCH FROM (a.slot_start::time - sc.start_time))::integer / 60) % sc.slot_minutes = 0
          AND a.slot_end - a.slot_start = sc.slot_minutes * INTERVAL '1 minute')

    -- IC2: an in-clinic appointment is at a clinic where the doctor has a schedule
    UNION ALL
    SELECT 'IC2  in-clinic appointment at a clinic where the doctor works', count(*)
    FROM appointments a
    WHERE a.consult_type = 'IN_CLINIC'
      AND NOT EXISTS (SELECT 1 FROM doctor_schedules sc
                      WHERE sc.doctor_id = a.doctor_id AND sc.clinic_id = a.clinic_id)

    -- IC3: the fee charged equals the doctor's fee for that consult type
    UNION ALL
    SELECT 'IC3  appointment fee = doctor''s fee for that consult type', count(*)
    FROM appointments a JOIN doctors d ON d.doctor_id = a.doctor_id
    WHERE a.fee IS DISTINCT FROM CASE a.consult_type WHEN 'VIDEO' THEN d.video_fee ELSE d.consultation_fee END

    -- IC4: only doctors who offer video (video_fee set) have video schedules
    UNION ALL
    SELECT 'IC4  video schedule only for doctors with a video_fee', count(*)
    FROM doctor_schedules sc JOIN doctors d ON d.doctor_id = sc.doctor_id
    WHERE sc.clinic_id IS NULL AND d.video_fee IS NULL

    -- IC5: every doctor has exactly one primary specialization
    --      (the EXCLUDE constraint guarantees "at most one"; this checks "at least one")
    UNION ALL
    SELECT 'IC5  doctor without a primary specialization', count(*)
    FROM doctors d
    WHERE NOT EXISTS (SELECT 1 FROM doctor_specializations ds WHERE ds.doctor_id = d.doctor_id AND ds.is_primary)

    -- IC6: prescriptions and reviews exist only for COMPLETED appointments,
    --      and are written after the consultation ended
    UNION ALL
    SELECT 'IC6  prescription for a non-completed appt, or issued before consult ended', count(*)
    FROM prescriptions p JOIN appointments a ON a.appointment_id = p.appointment_id
    WHERE a.status <> 'COMPLETED' OR p.issued_at < a.consult_ended_at
    UNION ALL
    SELECT 'IC7  review for a non-completed appt, or written before consult ended', count(*)
    FROM doctor_reviews r JOIN appointments a ON a.appointment_id = r.appointment_id
    WHERE a.status <> 'COMPLETED' OR r.created_at < a.consult_ended_at

    -- IC8: the review's wait bucket matches the real wait (consult start - slot start)
    UNION ALL
    SELECT 'IC8  review wait_time_bucket = actual wait (consult_started_at - slot_start)', count(*)
    FROM doctor_reviews r JOIN appointments a ON a.appointment_id = r.appointment_id
    WHERE r.wait_time_bucket <>
          CASE WHEN a.consult_started_at - a.slot_start < INTERVAL '15 minutes' THEN '<15 min'
               WHEN a.consult_started_at - a.slot_start < INTERVAL '30 minutes' THEN '15-30 min'
               WHEN a.consult_started_at - a.slot_start < INTERVAL '60 minutes' THEN '30-60 min'
               ELSE '>1 hr' END

    -- ----- the checks below FIND DATA PROBLEMS (non-zero is expected) -----

    -- IC9: patient safety: penicillin-allergic patient prescribed amoxicillin (a penicillin)
    UNION ALL
    SELECT 'IC9  [data problem] penicillin-allergic patient prescribed amoxicillin (lines)', count(*)
    FROM patients pt
    JOIN appointments a       ON a.patient_id = pt.patient_id
    JOIN prescriptions p      ON p.appointment_id = a.appointment_id
    JOIN prescription_items i ON i.prescription_id = p.prescription_id
    WHERE pt.allergies @> ARRAY['Penicillin'] AND i.medicine_name ILIKE '%amoxicillin%'

    -- IC10: double bookings: two non-cancelled appointments, same doctor, same slot
    UNION ALL
    SELECT 'IC10 [data problem] double-booked slots (pairs of active appointments)', count(*)
    FROM appointments a
    JOIN appointments b ON b.doctor_id = a.doctor_id AND b.slot_start = a.slot_start
                       AND b.appointment_id > a.appointment_id
    WHERE a.status <> 'CANCELLED' AND b.status <> 'CANCELLED'

    -- IC11: an appointment booked before the patient's account existed
    UNION ALL
    SELECT 'IC11 [data problem] appointment booked before patient account was created', count(*)
    FROM appointments a JOIN patients p ON p.patient_id = a.patient_id
    WHERE a.booked_at < p.created_at

    -- IC12: patient checked in after the consultation had already started
    UNION ALL
    SELECT 'IC12 [data problem] checked in after consultation started', count(*)
    FROM appointments a
    WHERE a.checked_in_at > a.consult_started_at

    -- IC13: clinics with no schedule at all (what R13 should list)
    UNION ALL
    SELECT 'IC13 [info] clinics where no doctor has any schedule', count(*)
    FROM clinics c
    WHERE NOT EXISTS (SELECT 1 FROM doctor_schedules sc WHERE sc.clinic_id = c.clinic_id)
) checks;
