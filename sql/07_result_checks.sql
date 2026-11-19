-- =====================================================================
-- Practo: proof that the optimized queries return the same results (Phase 4)
--
-- Run AFTER 05_indexes.sql, from the repo root, saving the output:
--   psql -d practo -f sql/07_result_checks.sql > benchmarks/results/optimized/result_checks.txt
--
-- For every query changed in sql/06_optimized_queries.sql, the ORIGINAL text
-- (queries/workload_30.sql) and the OPTIMIZED text run on the same data:
--   rows_original / rows_optimized : row counts
--   only_in_original / _optimized  : rows found in one result but not the other
--                                    (EXCEPT ALL, so duplicates count too)
--   same_order_of_keys             : the ORDER BY values come out in the same sequence
-- verdict:
--   SAME               identical rows (and order)
--   SAME up to ties    order keys identical; only rows that TIE on the ORDER BY key
--                      were picked/ordered differently (SQL leaves that order undefined)
--   FIXED              R13: the original answer was wrong (NOT IN + NULL)
-- W02 is a write: we compare the row its subquery picks to check in.
-- The other 19 queries are unchanged SQL (sped up by indexes only).
-- =====================================================================
\pset footer off
SET client_min_messages = warning;
SET search_path TO practo;

CREATE FUNCTION pg_temp.compare_results(qid text, orig_sql text, new_sql text, order_keys text)
RETURNS TABLE (query text, rows_original bigint, rows_optimized bigint,
               only_in_original bigint, only_in_optimized bigint,
               same_order_of_keys boolean, verdict text)
LANGUAGE plpgsql AS $f$
BEGIN
    DROP TABLE IF EXISTS pg_temp.o, pg_temp.n;
    EXECUTE format('CREATE TEMP TABLE o AS SELECT row_number() OVER () AS pos, q::text AS r, ROW(%s)::text AS k FROM (%s) q', order_keys, orig_sql);
    EXECUTE format('CREATE TEMP TABLE n AS SELECT row_number() OVER () AS pos, q::text AS r, ROW(%s)::text AS k FROM (%s) q', order_keys, new_sql);
    query := qid;
    SELECT count(*) INTO rows_original FROM o;
    SELECT count(*) INTO rows_optimized FROM n;
    SELECT count(*) INTO only_in_original  FROM (SELECT r FROM o EXCEPT ALL SELECT r FROM n) x;
    SELECT count(*) INTO only_in_optimized FROM (SELECT r FROM n EXCEPT ALL SELECT r FROM o) x;
    SELECT coalesce((SELECT string_agg(k, '|' ORDER BY pos) FROM o), '')
         = coalesce((SELECT string_agg(k, '|' ORDER BY pos) FROM n), '') INTO same_order_of_keys;
    verdict := CASE
        WHEN qid = 'R13' THEN 'FIXED (original returned 0 rows: NOT IN + NULL)'
        WHEN rows_original = rows_optimized AND only_in_original = 0 AND only_in_optimized = 0
             AND same_order_of_keys THEN 'SAME'
        WHEN rows_original = rows_optimized AND same_order_of_keys THEN 'SAME up to ties'
        ELSE 'DIFFERENT' END;
    RETURN NEXT;
END;
$f$;

\echo '=== 1. Original vs optimized results ==='

SELECT * FROM pg_temp.compare_results('R05',
  $q$SELECT a.appointment_id, p.full_name, a.slot_start, a.status, a.checked_in_at
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
WHERE a.doctor_id = 16
  AND DATE(a.slot_start) = '2026-06-30'
ORDER BY a.slot_start$q$,
  $q$SELECT a.appointment_id, p.full_name, a.slot_start, a.status, a.checked_in_at
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
WHERE a.doctor_id = 16
  AND a.slot_start >= '2026-06-30' AND a.slot_start < '2026-07-01'
ORDER BY a.slot_start$q$,
  'slot_start')
UNION ALL SELECT * FROM pg_temp.compare_results('R08',
  $q$SELECT s.spec_name, count(*) AS appointments,
       round(100.0 * count(*) FILTER (WHERE a.status = 'NO_SHOW') / count(*), 2) AS no_show_pct
FROM appointments a
JOIN doctor_specializations ds ON ds.doctor_id = a.doctor_id AND ds.is_primary
JOIN specializations s         ON s.spec_id = ds.spec_id
WHERE EXTRACT(YEAR FROM a.slot_start) = 2026
  AND a.status IN ('COMPLETED', 'NO_SHOW')
GROUP BY s.spec_name
ORDER BY no_show_pct DESC$q$,
  $q$SELECT s.spec_name, count(*) AS appointments,
       round(100.0 * count(*) FILTER (WHERE a.status = 'NO_SHOW') / count(*), 2) AS no_show_pct
FROM appointments a
JOIN doctor_specializations ds ON ds.doctor_id = a.doctor_id AND ds.is_primary
JOIN specializations s         ON s.spec_id = ds.spec_id
WHERE a.slot_start >= '2026-01-01' AND a.slot_start < '2027-01-01'
  AND a.status IN ('COMPLETED', 'NO_SHOW')
GROUP BY s.spec_name
ORDER BY no_show_pct DESC$q$,
  'no_show_pct')
UNION ALL SELECT * FROM pg_temp.compare_results('R12',
  $q$SELECT date_trunc('month', slot_start) AS month, consult_type, count(*) AS appointments
FROM appointments
WHERE EXTRACT(YEAR FROM slot_start) = 2026
GROUP BY 1, 2
ORDER BY 1, 2$q$,
  $q$SELECT date_trunc('month', slot_start) AS month, consult_type, count(*) AS appointments
FROM appointments
WHERE slot_start >= '2026-01-01' AND slot_start < '2027-01-01'
GROUP BY 1, 2
ORDER BY 1, 2$q$,
  'month, consult_type')
UNION ALL SELECT * FROM pg_temp.compare_results('R13',
  $q$SELECT c.clinic_id, c.clinic_name, c.city_id
FROM clinics c
WHERE c.clinic_id NOT IN (SELECT sc.clinic_id FROM doctor_schedules sc)$q$,
  $q$SELECT c.clinic_id, c.clinic_name, c.city_id
FROM clinics c
WHERE NOT EXISTS (SELECT 1 FROM doctor_schedules sc WHERE sc.clinic_id = c.clinic_id)$q$,
  'clinic_id')
UNION ALL SELECT * FROM pg_temp.compare_results('R14',
  $q$SELECT a.doctor_id, round(avg(r.rating), 2) AS avg_rating,
       round(100.0 * count(*) FILTER (WHERE r.recommends) / count(*), 1) AS recommend_pct, count(*) AS reviews
FROM doctor_reviews r
JOIN appointments a ON a.appointment_id = r.appointment_id
GROUP BY a.doctor_id
HAVING count(*) >= 10
ORDER BY avg_rating DESC, reviews DESC
LIMIT 20$q$,
  $q$SELECT a.doctor_id, round(avg(r.rating), 2) AS avg_rating,
       round(100.0 * count(*) FILTER (WHERE r.recommends) / count(*), 1) AS recommend_pct, count(*) AS reviews
FROM doctor_reviews r
JOIN appointments a ON a.appointment_id = r.appointment_id
GROUP BY a.doctor_id
HAVING count(*) >= 10
ORDER BY avg_rating DESC, reviews DESC, a.doctor_id
LIMIT 20$q$,
  'avg_rating, reviews')
UNION ALL SELECT * FROM pg_temp.compare_results('R16',
  $q$SELECT c.clinic_id, c.clinic_name, count(*) AS paid_consults, sum(a.fee) AS collected
FROM appointments a
JOIN clinics c ON c.clinic_id = a.clinic_id
WHERE a.payment_status = 'PAID'
  AND a.slot_start >= '2026-06-01' AND a.slot_start < '2026-07-01'
GROUP BY c.clinic_id, c.clinic_name
ORDER BY collected DESC
LIMIT 20$q$,
  $q$SELECT c.clinic_id, c.clinic_name, count(*) AS paid_consults, sum(a.fee) AS collected
FROM appointments a
JOIN clinics c ON c.clinic_id = a.clinic_id
WHERE a.payment_status = 'PAID'
  AND a.slot_start >= '2026-06-01' AND a.slot_start < '2026-07-01'
GROUP BY c.clinic_id, c.clinic_name
ORDER BY collected DESC, c.clinic_id
LIMIT 20$q$,
  'collected')
UNION ALL SELECT * FROM pg_temp.compare_results('R19',
  $q$SELECT d.doctor_id, d.full_name,
       (SELECT count(*) FROM appointments a WHERE a.doctor_id = d.doctor_id AND a.status = 'COMPLETED'
          AND a.slot_start >= '2026-06-01' AND a.slot_start < '2026-07-01') AS june_consults,
       (SELECT max(a.consult_ended_at) FROM appointments a WHERE a.doctor_id = d.doctor_id) AS last_consult_at
FROM doctors d
WHERE EXISTS (SELECT 1 FROM doctor_schedules sc JOIN clinics c ON c.clinic_id = sc.clinic_id
              WHERE sc.doctor_id = d.doctor_id AND c.city_id = 1)
ORDER BY june_consults DESC$q$,
  $q$SELECT d.doctor_id, d.full_name, s.june_consults, s.last_consult_at
FROM doctors d
CROSS JOIN LATERAL (
    SELECT count(*) FILTER (WHERE a.status = 'COMPLETED'
                              AND a.slot_start >= '2026-06-01' AND a.slot_start < '2026-07-01') AS june_consults,
           max(a.consult_ended_at) AS last_consult_at
    FROM appointments a
    WHERE a.doctor_id = d.doctor_id
) s
WHERE EXISTS (SELECT 1 FROM doctor_schedules sc JOIN clinics c ON c.clinic_id = sc.clinic_id
              WHERE sc.doctor_id = d.doctor_id AND c.city_id = 1)
ORDER BY s.june_consults DESC$q$,
  'june_consults')
UNION ALL SELECT * FROM pg_temp.compare_results('R20',
  $q$SELECT day, consults, sum(consults) OVER (ORDER BY day) AS running_total
FROM (
    SELECT slot_start::date AS day, count(*) AS consults
    FROM appointments
    WHERE status = 'COMPLETED'
      AND slot_start::date BETWEEN '2026-06-01' AND '2026-06-30'
    GROUP BY 1
) d
ORDER BY day$q$,
  $q$SELECT day, consults, sum(consults) OVER (ORDER BY day) AS running_total
FROM (
    SELECT slot_start::date AS day, count(*) AS consults
    FROM appointments
    WHERE status = 'COMPLETED'
      AND slot_start >= '2026-06-01' AND slot_start < '2026-07-01'
    GROUP BY 1
) d
ORDER BY day$q$,
  'day')
UNION ALL SELECT * FROM pg_temp.compare_results('R21',
  $q$SELECT appointment_id, patient_id, clinic_id, fee, slot_start
FROM appointments
WHERE status = 'COMPLETED' AND payment_status = 'PENDING'
ORDER BY slot_start DESC
LIMIT 100$q$,
  $q$SELECT appointment_id, patient_id, clinic_id, fee, slot_start
FROM appointments
WHERE status = 'COMPLETED' AND payment_status = 'PENDING'
ORDER BY slot_start DESC, appointment_id DESC
LIMIT 100$q$,
  'slot_start')
UNION ALL SELECT * FROM pg_temp.compare_results('R22',
  $q$SELECT appointment_id, patient_id, doctor_id, status, slot_start
FROM appointments
ORDER BY slot_start DESC
OFFSET 100000
LIMIT 25$q$,
  $q$SELECT appointment_id, patient_id, doctor_id, status, slot_start
FROM appointments
WHERE (slot_start, appointment_id) < (TIMESTAMPTZ '2025-07-08 12:15:00+05:30', 50125)
ORDER BY slot_start DESC, appointment_id DESC
LIMIT 25$q$,
  'slot_start')
UNION ALL SELECT * FROM pg_temp.compare_results('W02',
  $q$SELECT appointment_id, slot_start FROM appointments
                        WHERE status = 'BOOKED' AND consult_type = 'IN_CLINIC'
                          AND slot_start >= '2026-07-01' AND slot_start < '2026-07-02'
                        ORDER BY slot_start LIMIT 1$q$,
  $q$SELECT appointment_id, slot_start FROM appointments
                        WHERE status = 'BOOKED' AND consult_type = 'IN_CLINIC'
                          AND slot_start >= '2026-07-01' AND slot_start < '2026-07-02'
                        ORDER BY slot_start, appointment_id LIMIT 1$q$,
  'slot_start')
;

\echo ''
\echo '=== 2. R13: independent check of the fixed answer (LEFT JOIN ... IS NULL) ==='
SELECT (SELECT count(*) FROM clinics c LEFT JOIN doctor_schedules sc ON sc.clinic_id = c.clinic_id
        WHERE sc.clinic_id IS NULL)                                   AS clinics_without_schedule,
       (SELECT count(*) FROM doctor_schedules WHERE clinic_id IS NULL) AS schedules_with_null_clinic,
       (SELECT count(*) FROM clinics c WHERE c.clinic_id NOT IN
          (SELECT sc.clinic_id FROM doctor_schedules sc))             AS original_not_in_result,
       (SELECT count(*) FROM clinics c WHERE c.clinic_id NOT IN
          (SELECT sc.clinic_id FROM doctor_schedules sc WHERE sc.clinic_id IS NOT NULL)) AS not_in_without_nulls;

\echo ''
\echo '=== 3. Why tie-breakers were added: rows tied ACROSS the LIMIT/OFFSET boundary ==='
SELECT 'R14 rows 19-21 of top 20' AS query, string_agg(k, ' / ') AS tied_values FROM (
  SELECT ROW(avg_rating, reviews)::text k FROM (
    SELECT round(avg(r.rating), 2) avg_rating, count(*) reviews,
           row_number() OVER (ORDER BY round(avg(r.rating), 2) DESC, count(*) DESC) rn
    FROM doctor_reviews r JOIN appointments a ON a.appointment_id = r.appointment_id
    GROUP BY a.doctor_id HAVING count(*) >= 10) x WHERE rn BETWEEN 19 AND 21) y
UNION ALL
SELECT 'R16 rows 19-21 of top 20', string_agg(k, ' / ') FROM (
  SELECT collected::text k FROM (
    SELECT sum(a.fee) collected, row_number() OVER (ORDER BY sum(a.fee) DESC) rn
    FROM appointments a JOIN clinics c ON c.clinic_id = a.clinic_id
    WHERE a.payment_status = 'PAID' AND a.slot_start >= '2026-06-01' AND a.slot_start < '2026-07-01'
    GROUP BY c.clinic_id) x WHERE rn BETWEEN 19 AND 21) y
UNION ALL
SELECT 'R21 rows 100-101 of top 100', string_agg(k, ' / ') FROM (
  SELECT slot_start::text k FROM (
    SELECT slot_start, row_number() OVER (ORDER BY slot_start DESC) rn FROM appointments
    WHERE status = 'COMPLETED' AND payment_status = 'PENDING') x WHERE rn BETWEEN 100 AND 101) y
UNION ALL
SELECT 'R22 rows 100000-100001 (page edge)', string_agg(k, ' / ') FROM (
  SELECT slot_start::text k FROM (
    SELECT slot_start, row_number() OVER (ORDER BY slot_start DESC) rn FROM appointments) x
  WHERE rn BETWEEN 100000 AND 100001) y
UNION ALL
SELECT 'W02 booked in-clinic at the earliest slot', count(*)::text || ' appointments at ' || min(slot_start)::text
FROM appointments WHERE status = 'BOOKED' AND consult_type = 'IN_CLINIC'
  AND slot_start = (SELECT min(slot_start) FROM appointments WHERE status = 'BOOKED'
                    AND consult_type = 'IN_CLINIC' AND slot_start >= '2026-07-01' AND slot_start < '2026-07-02');

\echo ''
\echo '=== 4. Index storage: each new index vs its table ==='
SELECT t.relname AS table_name, i.relname AS index_name,
       pg_size_pretty(pg_relation_size(i.oid)) AS index_size,
       pg_size_pretty(pg_relation_size(t.oid)) AS table_size,
       round(100.0 * pg_relation_size(i.oid) / pg_relation_size(t.oid), 1) AS pct_of_table
FROM pg_index x
JOIN pg_class i ON i.oid = x.indexrelid
JOIN pg_class t ON t.oid = x.indrelid
JOIN pg_namespace ns ON ns.oid = t.relnamespace
WHERE ns.nspname = 'practo' AND i.relname LIKE 'idx\_%'
ORDER BY t.relname, pg_relation_size(i.oid) DESC;

\echo ''
\echo '=== 5. Totals ==='
SELECT pg_size_pretty(sum(pg_relation_size(i.oid))) AS new_indexes_total,
       pg_size_pretty((SELECT sum(pg_relation_size(c.oid)) FROM pg_class c JOIN pg_namespace n2 ON n2.oid = c.relnamespace
                       WHERE n2.nspname = 'practo' AND c.relkind = 'r')) AS all_tables_total,
       pg_size_pretty((SELECT sum(pg_relation_size(c.oid)) FROM pg_class c JOIN pg_namespace n2 ON n2.oid = c.relnamespace
                       WHERE n2.nspname = 'practo' AND c.relkind = 'i')) AS all_indexes_total,
       pg_size_pretty(pg_database_size(current_database())) AS database_size
FROM pg_class i JOIN pg_namespace ns ON ns.oid = i.relnamespace
WHERE ns.nspname = 'practo' AND i.relkind = 'i' AND i.relname LIKE 'idx\_%';
