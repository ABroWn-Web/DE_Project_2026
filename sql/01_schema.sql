-- =====================================================================
-- Practo Doctor Appointments: schema (Phase 2)
-- PostgreSQL 15+
--
-- Run on an empty database:   psql -d practo -f sql/01_schema.sql
--
-- Rules followed (README §2.2):
--   * every table lives in schema "practo"
--   * only constraints are created here: PRIMARY KEY, FOREIGN KEY, UNIQUE,
--     NOT NULL, CHECK (plus one EXCLUDE constraint for "one primary
--     specialization per doctor"). No performance indexes; those belong
--     to Phase 4 (sql/05_indexes.sql).
--   * the only indexes that exist after this script are the ones PostgreSQL
--     builds automatically for PK / UNIQUE / EXCLUDE (listed at the bottom).
-- =====================================================================

-- Re-runnable: wipe the project schema if it already exists.
DROP SCHEMA IF EXISTS practo CASCADE;
CREATE SCHEMA practo;
SET search_path TO practo;

-- ---------------------------------------------------------------------
-- Time zone.
-- Every timestamp in the seed data carries +05:30 (IST), and several of
-- the 30 queries turn a timestamptz into a date or build one from a date +
-- time (R03, R05, R17, R20). Those conversions use the session TimeZone,
-- so the database must default to IST or "30 June" would be cut at UTC
-- midnight (05:30 IST) and R03 would generate slots 5.5 hours late.
-- run_benchmark.sh opens new psql sessions and does not set a time zone,
-- so we set it on the database itself.
-- ---------------------------------------------------------------------
SET timezone TO 'Asia/Kolkata';
DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET timezone TO %L', current_database(), 'Asia/Kolkata');
END
$$;

-- =====================================================================
-- 1. cities  (10 rows): lookup table
-- =====================================================================
CREATE TABLE cities (
    city_id     smallint     PRIMARY KEY,                -- 10 cities: smallint is plenty
    city_name   varchar(50)  NOT NULL UNIQUE,            -- natural key
    state       varchar(50)  NOT NULL                    -- Mumbai & Pune share a state, so not unique
);

-- =====================================================================
-- 2. specializations  (15 rows): lookup table
-- =====================================================================
CREATE TABLE specializations (
    spec_id     smallint     PRIMARY KEY,
    spec_name   varchar(50)  NOT NULL UNIQUE             -- R01 looks a specialization up by name
);

-- =====================================================================
-- 3. doctors  (3,000 rows)
-- =====================================================================
CREATE TABLE doctors (
    doctor_id         integer       PRIMARY KEY,
    full_name         varchar(100)  NOT NULL,
    registration_no   varchar(20)   NOT NULL UNIQUE,     -- medical council registration: one per doctor (R23)
    gender            char(1)       NOT NULL,
    experience_years  smallint      NOT NULL,
    consultation_fee  numeric(8,2)  NOT NULL,            -- money: exact decimal, never float
    video_fee         numeric(8,2),                      -- NULL = doctor does not offer video consults
    languages         text[]        NOT NULL,            -- seed data is a Postgres array literal {English,Hindi}; R18 uses = ANY()
    is_verified       boolean       NOT NULL DEFAULT false,
    joined_on         date          NOT NULL,

    -- <STATE>MC-<6 digits>, e.g. DLMC-010007 (Delhi Medical Council)
    CONSTRAINT chk_doctors_registration_format CHECK (registration_no ~ '^[A-Z]{2,4}MC-[0-9]{6}$'),
    CONSTRAINT chk_doctors_gender              CHECK (gender IN ('M', 'F', 'X')),
    CONSTRAINT chk_doctors_experience          CHECK (experience_years BETWEEN 0 AND 70),
    CONSTRAINT chk_doctors_consultation_fee    CHECK (consultation_fee > 0),
    CONSTRAINT chk_doctors_video_fee           CHECK (video_fee IS NULL OR video_fee > 0),
    -- a doctor speaks at least one language, and the array holds no NULL elements
    CONSTRAINT chk_doctors_languages           CHECK (cardinality(languages) >= 1
                                                      AND array_position(languages, NULL) IS NULL)
);

-- =====================================================================
-- 4. doctor_specializations  (3,700 rows): M:N doctors <-> specializations
-- =====================================================================
CREATE TABLE doctor_specializations (
    doctor_id   integer   NOT NULL REFERENCES doctors (doctor_id) ON DELETE CASCADE,
    spec_id     smallint  NOT NULL REFERENCES specializations (spec_id) ON DELETE RESTRICT,
    is_primary  boolean   NOT NULL DEFAULT false,

    -- a doctor holds a given specialization at most once
    PRIMARY KEY (doctor_id, spec_id),

    -- At most ONE primary specialization per doctor.
    -- Same effect as a partial unique index on (doctor_id) WHERE is_primary,
    -- written as a table constraint so it lives with the other constraints.
    CONSTRAINT one_primary_spec_per_doctor
        EXCLUDE USING btree (doctor_id WITH =) WHERE (is_primary)
);

-- =====================================================================
-- 5. clinics  (1,500 rows)
-- =====================================================================
CREATE TABLE clinics (
    clinic_id    integer       PRIMARY KEY,
    clinic_name  varchar(100)  NOT NULL,
    city_id      smallint      NOT NULL REFERENCES cities (city_id) ON DELETE RESTRICT,
    locality     varchar(50)   NOT NULL,
    latitude     numeric(8,6)  NOT NULL,                 -- 6 decimals ≈ 0.1 m, as in the export
    longitude    numeric(9,6)  NOT NULL,
    phone        varchar(20)   NOT NULL UNIQUE,          -- each clinic has its own landline

    -- all clinics are in India (bounding box of the country)
    CONSTRAINT chk_clinics_in_india     CHECK (latitude BETWEEN 6 AND 38 AND longitude BETWEEN 68 AND 98),
    CONSTRAINT chk_clinics_phone_format CHECK (phone ~ '^\+91-[0-9]{2}-[0-9]{7}$')
);

-- =====================================================================
-- 6. doctor_schedules  (30,499 rows): weekly timetable
--    clinic_id NULL  = a VIDEO consultation block (21:00-22:00 in the data)
-- =====================================================================
CREATE TABLE doctor_schedules (
    doctor_id     integer   NOT NULL REFERENCES doctors (doctor_id) ON DELETE CASCADE,
    weekday       smallint  NOT NULL,                    -- ISO: 1 = Monday ... 7 = Sunday (data uses 1-6; R03 uses 5 = Friday)
    start_time    time      NOT NULL,
    end_time      time      NOT NULL,
    -- CASCADE, not SET NULL: NULL means "video", so SET NULL would silently
    -- turn a closed clinic's hours into video hours.
    clinic_id     integer   REFERENCES clinics (clinic_id) ON DELETE CASCADE,
    slot_minutes  smallint  NOT NULL,

    -- a doctor cannot start two blocks at the same moment on the same weekday
    PRIMARY KEY (doctor_id, weekday, start_time),

    CONSTRAINT chk_schedules_weekday      CHECK (weekday BETWEEN 1 AND 7),
    CONSTRAINT chk_schedules_time_order   CHECK (end_time > start_time),
    CONSTRAINT chk_schedules_slot_minutes CHECK (slot_minutes IN (10, 15, 20)),
    -- the block must split into whole slots (no half slot at the end)
    CONSTRAINT chk_schedules_whole_slots  CHECK ((EXTRACT(EPOCH FROM (end_time - start_time))::integer / 60)
                                                 % slot_minutes = 0)
);

-- =====================================================================
-- 7. patients  (40,000 rows)
-- =====================================================================
CREATE TABLE patients (
    patient_id   integer       PRIMARY KEY,
    full_name    varchar(100)  NOT NULL,
    phone        varchar(10)   NOT NULL UNIQUE,          -- sign-in by mobile number (R06)
    email        varchar(254)  UNIQUE,                   -- optional (35% empty); UNIQUE allows many NULLs
    dob          date          NOT NULL,
    gender       char(1)       NOT NULL,
    blood_group  varchar(3),                             -- NULL = not known yet
    allergies    text[],                                 -- NULL = no known allergies; R10 uses @>
    city_id      smallint      NOT NULL REFERENCES cities (city_id) ON DELETE RESTRICT,
    created_at   timestamptz   NOT NULL,

    CONSTRAINT chk_patients_phone_format  CHECK (phone ~ '^[6-9][0-9]{9}$'),         -- Indian mobile
    CONSTRAINT chk_patients_email_format  CHECK (email ~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$'),
    CONSTRAINT chk_patients_gender        CHECK (gender IN ('M', 'F', 'X')),
    CONSTRAINT chk_patients_blood_group   CHECK (blood_group IN ('A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-')),
    CONSTRAINT chk_patients_dob           CHECK (dob >= DATE '1900-01-01'),
    -- "no allergies" has exactly one representation (NULL), never an empty array
    CONSTRAINT chk_patients_allergies     CHECK (allergies IS NULL
                                                 OR (cardinality(allergies) >= 1
                                                     AND array_position(allergies, NULL) IS NULL))
);

-- =====================================================================
-- 8. appointments  (150,000 rows)
-- =====================================================================
CREATE TABLE appointments (
    appointment_id      integer       PRIMARY KEY,
    -- RESTRICT: medical and payment history must survive; deactivate, don't delete
    patient_id          integer       NOT NULL REFERENCES patients (patient_id) ON DELETE RESTRICT,
    doctor_id           integer       NOT NULL REFERENCES doctors  (doctor_id)  ON DELETE RESTRICT,
    clinic_id           integer       REFERENCES clinics (clinic_id) ON DELETE RESTRICT,   -- NULL for VIDEO
    consult_type        varchar(10)   NOT NULL,
    booked_at           timestamptz   NOT NULL,
    slot_start          timestamptz   NOT NULL,
    slot_end            timestamptz   NOT NULL,
    reason              varchar(100)  NOT NULL,
    status              varchar(12)   NOT NULL DEFAULT 'BOOKED',
    checked_in_at       timestamptz,                     -- only for in-clinic visits that were checked in
    consult_started_at  timestamptz,                     -- only for consultations that happened
    consult_ended_at    timestamptz,
    fee                 numeric(8,2)  NOT NULL,          -- price charged at booking time (snapshot)
    payment_status      varchar(10)   NOT NULL DEFAULT 'PENDING',

    CONSTRAINT chk_appt_consult_type     CHECK (consult_type IN ('IN_CLINIC', 'VIDEO')),
    -- CHECKED_IN never appears in the export but W02 writes it, so it must be allowed
    CONSTRAINT chk_appt_status           CHECK (status IN ('BOOKED', 'CHECKED_IN', 'COMPLETED', 'CANCELLED', 'NO_SHOW')),
    CONSTRAINT chk_appt_payment_status   CHECK (payment_status IN ('PENDING', 'PAID', 'REFUNDED')),
    CONSTRAINT chk_appt_fee              CHECK (fee >= 0),
    -- in-clinic <=> has a clinic; video <=> no clinic
    CONSTRAINT chk_appt_clinic_iff_in_clinic CHECK ((consult_type = 'IN_CLINIC') = (clinic_id IS NOT NULL)),
    CONSTRAINT chk_appt_slot_order       CHECK (slot_end > slot_start),
    CONSTRAINT chk_appt_slot_length      CHECK (slot_end - slot_start IN (INTERVAL '10 minutes',
                                                                          INTERVAL '15 minutes',
                                                                          INTERVAL '20 minutes')),
    CONSTRAINT chk_appt_booked_before_slot CHECK (booked_at <= slot_start),
    -- only patients who physically come to a clinic are checked in
    CONSTRAINT chk_appt_checkin_only_in_clinic CHECK (checked_in_at IS NULL OR consult_type = 'IN_CLINIC'),
    -- a consultation can only end after it started
    CONSTRAINT chk_appt_consult_order    CHECK (consult_ended_at IS NULL
                                                OR (consult_started_at IS NOT NULL
                                                    AND consult_ended_at >= consult_started_at)),
    -- COMPLETED <=> the consultation has an end time
    CONSTRAINT chk_appt_completed_iff_ended CHECK ((status = 'COMPLETED') = (consult_ended_at IS NOT NULL)),
    -- money is only given back for a cancelled appointment
    CONSTRAINT chk_appt_refund_only_cancelled CHECK (payment_status <> 'REFUNDED' OR status = 'CANCELLED')
);

-- =====================================================================
-- 9. prescriptions  (97,234 rows): 1:1 with a completed appointment
-- =====================================================================
CREATE TABLE prescriptions (
    prescription_id  integer       PRIMARY KEY,
    -- UNIQUE: at most one prescription per appointment (1:1).
    -- RESTRICT: a prescription is a medical record; it must not vanish
    -- as a side effect of deleting an appointment.
    appointment_id   integer       NOT NULL UNIQUE REFERENCES appointments (appointment_id) ON DELETE RESTRICT,
    diagnosis        varchar(100)  NOT NULL,
    notes            text,                               -- optional free text
    follow_up_date   date,                               -- NULL = no follow-up needed
    issued_at        timestamptz   NOT NULL,

    -- a follow-up is always on a later day than the prescription (IST calendar day).
    -- AT TIME ZONE with a fixed zone keeps the expression immutable.
    CONSTRAINT chk_presc_follow_up_after_issue CHECK (follow_up_date IS NULL
                                                      OR follow_up_date > (issued_at AT TIME ZONE 'Asia/Kolkata')::date)
);

-- =====================================================================
-- 10. prescription_items  (243,085 rows): medicines on a prescription
-- =====================================================================
CREATE TABLE prescription_items (
    -- CASCADE: line items are part of the prescription and mean nothing alone
    prescription_id  integer       NOT NULL REFERENCES prescriptions (prescription_id) ON DELETE CASCADE,
    line_no          smallint      NOT NULL,
    medicine_name    varchar(100)  NOT NULL,
    dosage           varchar(5)    NOT NULL,             -- morning-afternoon-night, e.g. 1-0-1
    duration_days    smallint      NOT NULL,
    instructions     varchar(100),                       -- optional: "After food", "At bedtime", ...

    -- line numbers restart at 1 on every prescription
    PRIMARY KEY (prescription_id, line_no),

    CONSTRAINT chk_items_line_no   CHECK (line_no >= 1),
    CONSTRAINT chk_items_dosage    CHECK (dosage ~ '^[0-9]-[0-9]-[0-9]$' AND dosage <> '0-0-0'),
    CONSTRAINT chk_items_duration  CHECK (duration_days BETWEEN 1 AND 365)
);

-- =====================================================================
-- 11. doctor_reviews  (30,339 rows): at most one review per appointment
-- =====================================================================
CREATE TABLE doctor_reviews (
    review_id         integer      PRIMARY KEY,
    -- UNIQUE: one review per consultation (1:1).
    -- CASCADE: a review is about one appointment and has no meaning without it.
    appointment_id    integer      NOT NULL UNIQUE REFERENCES appointments (appointment_id) ON DELETE CASCADE,
    rating            smallint     NOT NULL,
    recommends        boolean      NOT NULL,
    wait_time_bucket  varchar(10)  NOT NULL,
    review_text       varchar(500),                      -- optional (40% of reviews are rating-only)
    created_at        timestamptz  NOT NULL,

    CONSTRAINT chk_reviews_rating      CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT chk_reviews_wait_bucket CHECK (wait_time_bucket IN ('<15 min', '15-30 min', '30-60 min', '>1 hr'))
);

-- =====================================================================
-- Indexes that exist after this script (all created automatically by
-- PRIMARY KEY / UNIQUE / EXCLUDE; no other index is created in Phase 2):
--
--   cities_pkey                         cities(city_id)
--   cities_city_name_key                cities(city_name)
--   specializations_pkey                specializations(spec_id)
--   specializations_spec_name_key       specializations(spec_name)
--   doctors_pkey                        doctors(doctor_id)
--   doctors_registration_no_key         doctors(registration_no)
--   doctor_specializations_pkey         doctor_specializations(doctor_id, spec_id)
--   one_primary_spec_per_doctor         doctor_specializations(doctor_id) WHERE is_primary
--   clinics_pkey                        clinics(clinic_id)
--   clinics_phone_key                   clinics(phone)
--   doctor_schedules_pkey               doctor_schedules(doctor_id, weekday, start_time)
--   patients_pkey                       patients(patient_id)
--   patients_phone_key                  patients(phone)
--   patients_email_key                  patients(email)
--   appointments_pkey                   appointments(appointment_id)
--   prescriptions_pkey                  prescriptions(prescription_id)
--   prescriptions_appointment_id_key    prescriptions(appointment_id)
--   prescription_items_pkey             prescription_items(prescription_id, line_no)
--   doctor_reviews_pkey                 doctor_reviews(review_id)
--   doctor_reviews_appointment_id_key   doctor_reviews(appointment_id)
--
-- Check with:  SELECT tablename, indexname, indexdef FROM pg_indexes
--              WHERE schemaname = 'practo' ORDER BY 1, 2;
-- =====================================================================
