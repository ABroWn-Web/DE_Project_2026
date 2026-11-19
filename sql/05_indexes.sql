-- =====================================================================
-- Practo Doctor Appointments: indexes (Phase 4)
--
-- Run once, after 01_schema.sql and 02_load_data.sql:
--     psql -d practo -f sql/05_indexes.sql
-- Re-runnable (IF NOT EXISTS). Ends with VACUUM ANALYZE so the planner has
-- fresh statistics and index-only scans can skip the table (visibility map).
--
-- Column-order rule used everywhere: columns compared with "=" first,
-- then the column used for a range (<, >, BETWEEN) or for ORDER BY.
-- =====================================================================
SET search_path TO practo;

-- ---------------------------------------------------------------------
-- appointments (150,000 rows) had ONLY its primary key, so 21 of the 30
-- queries read the whole table. Five indexes, each serving several queries.
-- ---------------------------------------------------------------------

-- I1. Doctor + time.
-- Serves R03 (doctor 217's booked slots), R05 (doctor 16's day, after the
-- sargable rewrite), R19 (each doctor's June consults and last consult),
-- R24 (double bookings = same doctor_id + slot_start), W05 (doctor 504's day).
-- Why this order: every one of them has doctor_id = <value>; slot_start is
-- then a range or a join column, so it goes second.
-- INCLUDE (status, appointment_id, consult_ended_at): R03, R19 and R24 also
-- test status, R24 compares appointment_id and R19 needs max(consult_ended_at),
-- so they answer from the index alone (Index Only Scan, no table visits).
CREATE INDEX IF NOT EXISTS idx_appt_doctor_slot
    ON appointments (doctor_id, slot_start) INCLUDE (status, appointment_id, consult_ended_at);

-- I2. Patient + doctor + time.
-- Serves R04 (patient 90's appointments), R10 (appointments of the
-- penicillin-allergic patients), R11 (the NOT EXISTS check: same patient,
-- same doctor, a later slot).
-- Why this order: all three filter patient_id = ...; R11 adds doctor_id = ...
-- and then slot_start > ... (range), so the range column is last.
CREATE INDEX IF NOT EXISTS idx_appt_patient_doctor_slot
    ON appointments (patient_id, doctor_id, slot_start);

-- I3. Time, covering the columns the reports read.
-- Serves R09, R16 (June 2026), R12, R08 (2026, after the sargable rewrite),
-- R17, R25 (2026 completed), R20 (June, after the rewrite) and R22 (newest
-- first: the index is already sorted, so it is read backwards).
-- Key (slot_start, appointment_id): appointment_id breaks ties between rows
-- with the same slot time, which R22's keyset paging needs.
-- INCLUDE: every other column those queries read, so most of them become
-- Index Only Scans that never touch the table.
CREATE INDEX IF NOT EXISTS idx_appt_slot_covering
    ON appointments (slot_start, appointment_id)
    INCLUDE (status, consult_type, doctor_id, patient_id);

-- I4. Partial: unpaid completed consultations only (~24,700 of 150,000 rows).
-- Serves R21 (newest 100 unpaid). Read backwards, PostgreSQL stops after
-- 100 rows instead of sorting 24,700.
-- Partial because R21 never asks for any other status/payment combination,
-- so indexing the other ~125,000 rows would only cost space and write time.
-- appointment_id is the tie-breaker of the rewritten ORDER BY.
CREATE INDEX IF NOT EXISTS idx_appt_unpaid_completed
    ON appointments (slot_start, appointment_id)
    WHERE status = 'COMPLETED' AND payment_status = 'PENDING';

-- I5. Partial: open appointments only (BOOKED / CHECKED_IN, ~1,800 rows).
-- Serves W02 (earliest BOOKED in-clinic appointment of 1 July) and W04
-- (nightly NO_SHOW job). Both only ever look at open appointments, and the
-- open set stays small because appointments move on to COMPLETED,
-- CANCELLED or NO_SHOW. A full index on status would be mostly useless
-- (the four values split the table into huge groups).
-- appointment_id is the tie-breaker of W02's rewritten ORDER BY.
CREATE INDEX IF NOT EXISTS idx_appt_open
    ON appointments (slot_start, appointment_id)
    WHERE status IN ('BOOKED', 'CHECKED_IN');

-- ---------------------------------------------------------------------
-- Other tables
-- ---------------------------------------------------------------------

-- I6. Schedules by clinic.
-- Serves R13 (rewritten with NOT EXISTS: "is there any schedule at this
-- clinic?"), R18 and R19 / R01 (which doctors have a clinic in a city).
-- The primary key starts with doctor_id, so it can't answer "by clinic".
-- INCLUDE (doctor_id) lets R18/R19 get the doctor from the index alone.
CREATE INDEX IF NOT EXISTS idx_sched_clinic
    ON doctor_schedules (clinic_id) INCLUDE (doctor_id);

-- I7. Partial: prescriptions that have a follow-up (29,050 of 97,234).
-- Serves R11 (follow-ups due 1-7 July). Rows with no follow-up date can
-- never match a BETWEEN, so they are left out of the index.
CREATE INDEX IF NOT EXISTS idx_presc_follow_up
    ON prescriptions (follow_up_date)
    WHERE follow_up_date IS NOT NULL;

-- I8. Prescriptions by issue time.
-- Serves R15 (prescriptions issued in June 2026: ~5,500 of 97,234).
CREATE INDEX IF NOT EXISTS idx_presc_issued_at
    ON prescriptions (issued_at);

-- I9. GIN on the allergies array.
-- Serves R10 (allergies @> ARRAY['Penicillin']). A B-tree can't look
-- inside an array; GIN indexes every element, so "contains Penicillin"
-- becomes an index lookup instead of reading all 40,000 patients.
CREATE INDEX IF NOT EXISTS idx_patients_allergies_gin
    ON patients USING gin (allergies);

-- Fresh statistics + visibility map (needed for Index Only Scans).
VACUUM ANALYZE;
