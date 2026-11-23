-- CP4 scalability design: RANGE partition appointments by slot_start.
-- PostgreSQL 15+. Run in a dedicated scratch database after 01_schema.sql.
-- This is a schema proof, not an in-place migration: see docs/05_scalability_report.md
-- for the required child-table FK changes and backfill/swap sequence.
--
-- Range partitioning matches the dominant time filters and allows old
-- appointment history to be detached/archived by month. The default
-- partition prevents inserts from failing at a month boundary; create new
-- monthly partitions ahead of time and keep it empty in normal operation.

CREATE TABLE practo.appointments_partitioned (
    LIKE practo.appointments INCLUDING DEFAULTS INCLUDING CONSTRAINTS
) PARTITION BY RANGE (slot_start);

-- PostgreSQL requires every unique/primary key on a partitioned table to
-- include the partition key. appointment_id alone can no longer be the PK.
ALTER TABLE practo.appointments_partitioned
    ADD CONSTRAINT appointments_partitioned_pkey
    PRIMARY KEY (appointment_id, slot_start);

ALTER TABLE practo.appointments_partitioned
    ADD CONSTRAINT appointments_partitioned_patient_fk
    FOREIGN KEY (patient_id) REFERENCES practo.patients(patient_id) ON DELETE RESTRICT,
    ADD CONSTRAINT appointments_partitioned_doctor_fk
    FOREIGN KEY (doctor_id) REFERENCES practo.doctors(doctor_id) ON DELETE RESTRICT,
    ADD CONSTRAINT appointments_partitioned_clinic_fk
    FOREIGN KEY (clinic_id) REFERENCES practo.clinics(clinic_id) ON DELETE RESTRICT;

CREATE TABLE practo.appointments_2025_01 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2025-01-01 00:00:00+05:30') TO ('2025-02-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2025_02 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2025-02-01 00:00:00+05:30') TO ('2025-03-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2025_03 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2025-03-01 00:00:00+05:30') TO ('2025-04-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2025_04 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2025-04-01 00:00:00+05:30') TO ('2025-05-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2025_05 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2025-05-01 00:00:00+05:30') TO ('2025-06-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2025_06 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2025-06-01 00:00:00+05:30') TO ('2025-07-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2025_07 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2025-07-01 00:00:00+05:30') TO ('2025-08-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2025_08 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2025-08-01 00:00:00+05:30') TO ('2025-09-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2025_09 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2025-09-01 00:00:00+05:30') TO ('2025-10-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2025_10 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2025-10-01 00:00:00+05:30') TO ('2025-11-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2025_11 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2025-11-01 00:00:00+05:30') TO ('2025-12-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2025_12 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2025-12-01 00:00:00+05:30') TO ('2026-01-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2026_01 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2026-01-01 00:00:00+05:30') TO ('2026-02-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2026_02 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2026-02-01 00:00:00+05:30') TO ('2026-03-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2026_03 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2026-03-01 00:00:00+05:30') TO ('2026-04-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2026_04 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2026-04-01 00:00:00+05:30') TO ('2026-05-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2026_05 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2026-05-01 00:00:00+05:30') TO ('2026-06-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2026_06 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2026-06-01 00:00:00+05:30') TO ('2026-07-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2026_07 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2026-07-01 00:00:00+05:30') TO ('2026-08-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2026_08 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2026-08-01 00:00:00+05:30') TO ('2026-09-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2026_09 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2026-09-01 00:00:00+05:30') TO ('2026-10-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2026_10 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2026-10-01 00:00:00+05:30') TO ('2026-11-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2026_11 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2026-11-01 00:00:00+05:30') TO ('2026-12-01 00:00:00+05:30');
CREATE TABLE practo.appointments_2026_12 PARTITION OF practo.appointments_partitioned
    FOR VALUES FROM ('2026-12-01 00:00:00+05:30') TO ('2027-01-01 00:00:00+05:30');
CREATE TABLE practo.appointments_future PARTITION OF practo.appointments_partitioned DEFAULT;

-- Indexes are propagated to each partition. Keep the same access paths as
-- sql/05_indexes.sql; the time key is included in each partitioned unique key.
CREATE INDEX appointments_partitioned_doctor_slot_idx
    ON practo.appointments_partitioned (doctor_id, slot_start)
    INCLUDE (status, appointment_id, consult_ended_at);
CREATE INDEX appointments_partitioned_patient_doctor_slot_idx
    ON practo.appointments_partitioned (patient_id, doctor_id, slot_start);
CREATE INDEX appointments_partitioned_slot_cover_idx
    ON practo.appointments_partitioned (slot_start, appointment_id)
    INCLUDE (status, consult_type, doctor_id, patient_id);
CREATE INDEX appointments_partitioned_unpaid_idx
    ON practo.appointments_partitioned (slot_start, appointment_id)
    WHERE status = 'COMPLETED' AND payment_status = 'PENDING';
CREATE INDEX appointments_partitioned_open_idx
    ON practo.appointments_partitioned (slot_start, appointment_id)
    WHERE status IN ('BOOKED', 'CHECKED_IN');

ANALYZE practo.appointments_partitioned;

-- Plan proof (run after loading rows into the partitioned parent):
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT count(*) FROM practo.appointments_partitioned
-- WHERE slot_start >= TIMESTAMPTZ '2026-06-01 00:00:00+05:30'
--   AND slot_start <  TIMESTAMPTZ '2026-07-01 00:00:00+05:30';
-- The plan should mention only appointments_2026_06. On the empty proof
-- structure above, PostgreSQL will prune all other partitions at planning time.
