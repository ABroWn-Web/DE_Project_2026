# 04 · Optimization report (Phase 4)

**Result: the 30 queries went from 4,608.326 ms to 222.258 ms in total (95.2% faster, 21×)**, with 9 indexes and 11 rewritten queries. The wrong-result query (R13) is fixed, and every other result is proven unchanged.

| What | Where |
|---|---|
| Indexes (each with the queries it serves and why) | [`sql/05_indexes.sql`](../sql/05_indexes.sql) |
| Rewritten queries (a copy of the workload; changed queries carry a comment) | [`sql/06_optimized_queries.sql`](../sql/06_optimized_queries.sql) |
| Proof that results are unchanged + index sizes | [`sql/07_result_checks.sql`](../sql/07_result_checks.sql) → [`result_checks.txt`](../benchmarks/results/optimized/result_checks.txt) |
| Raw plans: before (3 runs each) / after (5 runs each) | [`baseline/`](../benchmarks/results/baseline/) / [`optimized/`](../benchmarks/results/optimized/) |

**Method:** same machine as the baseline (**MacBook Pro, Apple M4, 16 GB RAM, macOS**, PostgreSQL **18.7**, default server settings). `psql -d practo -f sql/05_indexes.sql` (ends with `VACUUM ANALYZE`), then `./benchmarks/run_benchmark.sh practo optimized 5 sql/06_optimized_queries.sql`, the command in README §4.2. *Before* = average of the baseline runs, *After* = average of the optimized runs, each read from the `Execution Time` lines of the raw plan files. No server settings were changed and no data was modified. Averages include every run, including the first (sometimes cold-cache) run; `summary.csv` also lists the median, used in §10 where it matters.

## 1. Optimization table

| Query | Before (ms) | Problem found in the plan | Optimization applied | After (ms) | Improvement | Same result? |
|-------|------------:|---------------------------|----------------------|-----------:|------------:|:------------:|
| R01 | 4.633 | Small tables only; schedules found through `doctor_schedules_pkey` | — (already fast; tables are tiny) | 4.474 | 3.4% | ✅ (same SQL) |
| R02 | 1.029 | None: `doctor_id` is the first PK column | — (already indexed) | 0.472 | 54.1% (2×) | ✅ (same SQL) |
| R03 | 20.791 | Seq Scan of all 150k appointments for the `NOT EXISTS` check | I1 `(doctor_id, slot_start)` → Index Only Scan | 0.231 | 98.9% (90×) | ✅ (same SQL) |
| R04 | 12.897 | Seq Scan: no index on `patient_id` | I2 `(patient_id, doctor_id, slot_start)` | 0.221 | 98.3% (58×) | ✅ (same SQL) |
| R05 | 10.270 | Seq Scan; `DATE(slot_start)` is not sargable | Range on `slot_start` + I1 | 0.141 | 98.6% (73×) | ✅ |
| R06 | 0.077 | None: UNIQUE index on `phone` | — (already indexed) | 0.067 | 13.0% | ✅ (same SQL) |
| R07 | 0.221 | None: UNIQUE/PK indexes | — (already indexed) | 0.134 | 39.4% | ✅ (same SQL) |
| R08 | 31.527 | Seq Scan; `EXTRACT(YEAR …)` is not sargable | Range on `slot_start` + I3 covering → Index Only Scan | 12.563 | 60.2% (3×) | ✅ |
| R09 | 10.614 | Seq Scan to keep ~5,600 June rows | I3 `(slot_start, …)` range scan | 5.336 | 49.7% (2×) | ✅ (same SQL) |
| R10 | 19.743 | Seq Scans: array filter on patients, no index on `patient_id` | I9 GIN on `allergies`; I2 exists but the planner keeps the hash join | 23.488 | -19.0% | ✅ (same SQL) |
| R11 | 17.993 | Seq Scans of prescriptions and of all appointments (anti-join) | I7 partial on `follow_up_date` + I2 for the anti-join | 2.240 | 87.6% (8×) | ✅ (same SQL) |
| R12 | 21.728 | Seq Scan; `EXTRACT(YEAR …)` is not sargable | Range on `slot_start` + I3 covering → Index Only Scan | 16.693 | 23.2% | ✅ |
| R13 | 2.541 | **Wrong answer** (0 rows): `NOT IN` + NULL | `NOT EXISTS` (correct: 292 rows) + I6 | 2.235 | 12.0% | ❌→✅ fixed |
| R14 | 22.714 | Must read every review + hash join with all appointments | — (tie-breaker added for a unique answer) | 29.288 | -28.9% | ✅ up to ties* |
| R15 | 19.909 | Seq Scan of 243k `prescription_items` + hash joins | I8 on `issued_at`; items still scanned | 17.228 | 13.5% | ✅ (same SQL) |
| R16 | 9.811 | Seq Scan to keep ~6,400 June rows | I3 range scan + tie-breaker | 2.929 | 70.1% (3×) | ✅ up to ties* |
| R17 | 34.450 | Seq Scan + `age()` computed for ~40,700 rows | I3 covering → Index Only Scan; `age()` cost remains | 34.685 | -0.7% | ✅ (same SQL) |
| R18 | 4.736 | Seq Scan of 30k schedules (small tables) | I6 `(clinic_id) INCLUDE (doctor_id)` | 3.336 | 29.6% | ✅ (same SQL) |
| R19 | 4,216.663 | **960 full scans**: 2 correlated subqueries × 480 doctors | One `LATERAL` pass per doctor + I1 → Index Only Scan | 8.274 | 99.8% (510×) | ✅ |
| R20 | 10.208 | Seq Scan; `slot_start::date` cast is not sargable | Range on `slot_start` + I3 covering | 2.714 | 73.4% (4×) | ✅ |
| R21 | 11.561 | Seq Scan + top-N sort of ~24,700 unpaid rows | I4 partial index read backwards, stops at 100 + tie-breaker | 0.189 | 98.4% (61×) | ✅ |
| R22 | 35.271 | `OFFSET 100000`: sorts all 150k rows (spills to disk) | Keyset pagination + I3 → reads 25 index entries | 0.120 | 99.7% (294×) | ✅ |
| R23 | 0.028 | None: UNIQUE index on `registration_no` | — (already indexed) | 0.088 | -214.3% | ✅ (same SQL) |
| R24 | 24.271 | Self hash join of ~135k × ~135k rows | — (rewrites tested were slower; kept original) | 29.747 | -22.6% | ✅ (same SQL) |
| R25 | 19.238 | Seq Scan + sort for `count(DISTINCT …)` | I3 covering → Index Only Scan; sort remains | 14.006 | 27.2% | ✅ (same SQL) |
| W01 | 0.675 | None: PK lookups (insert) | — (now also maintains the new indexes) | 0.671 | 0.6% | ✅ (same SQL) |
| W02 | 11.225 | Seq Scan to find the earliest booked appointment | I5 partial (open appointments) + tie-breaker | 0.679 | 94.0% (17×) | ✅ |
| W03 | 0.263 | None: UNIQUE index | — (slower: the update now also writes index entries, see §7) | 0.558 | -112.2% | ✅ (same SQL) |
| W04 | 20.036 | Seq Scan to find open appointments | I5 partial (open appointments) | 8.585 | 57.2% (2×) | ✅ (same SQL) |
| W05 | 13.203 | Seq Scan: no index on `doctor_id` | I5 partial (open appointments on 3 July), filtered by doctor | 0.866 | 93.4% (15×) | ✅ (same SQL) |
| **Total** | **4,608.326** | | | **222.258** | **95.2% (21×)** | |

Improvement % = (before − after) / before × 100. I1–I9 are the indexes in §2. \* *up to ties*: see §5. A negative improvement means the query got slower.

## 2. Indexes created (`sql/05_indexes.sql`)

Rule for column order: columns compared with `=` first, then the range / `ORDER BY` column. `INCLUDE` adds columns a query reads, so it can be answered by an **Index Only Scan** without visiting the table.

| # | Index | Serves | Why this type and column order |
|---|---|---|---|
| I1 | `appointments (doctor_id, slot_start) INCLUDE (status, appointment_id, consult_ended_at)` | R03, R05, R19 | All filter `doctor_id =`, then a time range/match. The INCLUDEd columns let R03 and R19 read only the index. |
| I2 | `appointments (patient_id, doctor_id, slot_start)` | R04, R11, (R10) | `patient_id =` in all; R11's anti-join also needs `doctor_id =` and `slot_start >`, so the range column goes last. |
| I3 | `appointments (slot_start, appointment_id) INCLUDE (status, consult_type, doctor_id, patient_id)` | R08, R09, R12, R16, R17, R20, R22, R25 | Every report filters a date range; INCLUDE covers the columns they read. `appointment_id` in the key gives R22 a unique order for keyset paging. |
| I4 | `appointments (slot_start, appointment_id) WHERE status='COMPLETED' AND payment_status='PENDING'` | R21 | **Partial**: only ~24,700 rows that R21 can ever want; read backwards it stops after 100. |
| I5 | `appointments (slot_start, appointment_id) WHERE status IN ('BOOKED','CHECKED_IN')` | W02, W04, W05 | **Partial**: open appointments are a small, moving set (~1,800). An index on `status` alone would be useless: 4 values. |
| I6 | `doctor_schedules (clinic_id) INCLUDE (doctor_id)` | R13, R18, R19 | The PK starts with `doctor_id`, so nothing could look schedules up **by clinic**. |
| I7 | `prescriptions (follow_up_date) WHERE follow_up_date IS NOT NULL` | R11 | **Partial**: NULL dates can never match `BETWEEN`, so 70% of rows stay out of the index. |
| I8 | `prescriptions (issued_at)` | R15 | June 2026 is ~5,500 of 97,234 prescriptions. |
| I9 | `patients USING gin (allergies)` | R10 | **GIN**: a B-tree can't search *inside* an array; GIN indexes each element, so `@> ARRAY['Penicillin']` is an index lookup. |

Not created, on purpose: an index on `status` alone (too few distinct values), `pg_trgm` for R10's `ILIKE '%amoxicillin%'` (the filter runs on only ~4,300 already-joined rows), GIN on `doctors.languages` (3,000 rows; a scan takes well under 1 ms).

## 3. Query rewrites (`sql/06_optimized_queries.sql`)

| Query | Rewrite | Why |
|---|---|---|
| R05, R08, R12, R20 | `DATE(x) = d`, `EXTRACT(YEAR FROM x) = y`, `x::date BETWEEN …` → `x >= start AND x < end` | A function or cast around the column hides it from the index (*not sargable*). `DATE(timestamptz)` depends on the session time zone, so it can't even be put in an expression index. The ranges are the same IST days/years, because the database time zone is Asia/Kolkata. |
| R13 | `NOT IN (subquery)` → `NOT EXISTS` | Fixes the wrong answer (§4) and becomes an anti-join on I6. |
| R19 | 2 correlated subqueries → 1 `LATERAL` subquery | Each doctor's appointments are read once (from I1) instead of two full table scans per doctor. |
| R22 | `OFFSET 100000` → keyset: `WHERE (slot_start, appointment_id) < (last row of page 4,000)` | OFFSET produces and discards 100,000 rows for every page; keyset jumps straight there in the index. The app keeps the last row it showed; for the benchmark it is row 100,000, found once with `ORDER BY slot_start DESC, appointment_id DESC OFFSET 99999 LIMIT 1` → (2025-07-08 12:15+05:30, 50125). |
| R14, R16, R21, R22, W02 | Tie-breaker column added at the end of `ORDER BY` | Rows tie across the LIMIT/OFFSET boundary, so the original answer wasn't unique (§5). |

## 4. The wrong-result query: R13 and `NOT IN` with NULL

`clinic_id NOT IN (SELECT sc.clinic_id FROM doctor_schedules sc)` returned **0 rows**, so the partnerships list (problem P5) was always empty.

- `x NOT IN (a, b, NULL)` means `x <> a AND x <> b AND x <> NULL`.
- `x <> NULL` is **UNKNOWN**, never TRUE. So for a clinic with no schedule the whole condition is `TRUE AND … AND UNKNOWN` = UNKNOWN, and `WHERE` drops the row.
- The subquery contains NULLs because every **video** schedule (5,899 rows) has `clinic_id = NULL`. One NULL is enough to empty the result.
- `NOT EXISTS (SELECT 1 … WHERE sc.clinic_id = c.clinic_id)` only asks whether a matching row exists. NULLs never match, so they can't break it. **Correct answer: 292 clinics.**

Independent check (section 2 of `result_checks.txt`): `LEFT JOIN … IS NULL` also finds 292, and `NOT IN` returns the right 292 once the NULLs are filtered out of the subquery:

```
 clinics_without_schedule | schedules_with_null_clinic | original_not_in_result | not_in_without_nulls 
--------------------------+----------------------------+------------------------+----------------------
                      292 |                       5899 |                      0 |                  292
```

## 5. Proof that the results are unchanged

`sql/07_result_checks.sql` runs the **original** and the **optimized** text of every changed query on the same data. It compares the row counts, the rows themselves (`EXCEPT ALL` both ways, so duplicates count) and the sequence of `ORDER BY` values. The other 19 queries are the unchanged original SQL, sped up only by indexes.

```
 query | rows_original | rows_optimized | only_in_original | only_in_optimized | same_order_of_keys |                     verdict                     
-------+---------------+----------------+------------------+-------------------+--------------------+-------------------------------------------------
 R05   |             3 |              3 |                0 |                 0 | t                  | SAME
 R08   |            15 |             15 |                0 |                 0 | t                  | SAME
 R12   |            14 |             14 |                0 |                 0 | t                  | SAME
 R13   |             0 |            292 |                0 |               292 | f                  | FIXED (original returned 0 rows: NOT IN + NULL)
 R14   |            20 |             20 |                1 |                 1 | t                  | SAME up to ties
 R16   |            20 |             20 |                1 |                 1 | t                  | SAME up to ties
 R19   |           480 |            480 |                0 |                 0 | t                  | SAME
 R20   |            26 |             26 |                0 |                 0 | t                  | SAME
 R21   |           100 |            100 |                0 |                 0 | t                  | SAME
 R22   |            25 |             25 |                0 |                 0 | t                  | SAME
 W02   |             1 |              1 |                0 |                 0 | t                  | SAME
```

**Ties ("SAME up to ties").** `ORDER BY … LIMIT n` is only well-defined when no rows tie across the cut. In this data they do:

```
                   query                   |                      tied_values                      
-------------------------------------------+-------------------------------------------------------
 R14 rows 19-21 of top 20                  | (4.42,12) / (4.42,12) / (4.42,12)
 R16 rows 19-21 of top 20                  | 10600.00 / 10600.00 / 10600.00
 R21 rows 100-101 of top 100               | 2026-06-29 10:30:00+05:30 / 2026-06-29 10:30:00+05:30
 R22 rows 100000-100001 (page edge)        | 2025-07-08 12:15:00+05:30 / 2025-07-08 12:15:00+05:30
 W02 booked in-clinic at the earliest slot | 11 appointments at 2026-07-01 10:00:00+05:30
```

When rows tie on the `ORDER BY` key, SQL may return them in any order, so *which* tied row lands on the page depends on the plan. Adding indexes changes plans, so the original could silently change its answer. We added the primary key as a last tie-breaker (e.g. `ORDER BY avg_rating DESC, reviews DESC, a.doctor_id`), which makes the answer unique and repeatable. The proof shows the `ORDER BY` values are identical in the same order (`same_order_of_keys = t`). Any row that differs is a row tied with the one it replaced, which was already a valid answer of the original query.

## 6. Before / after plans: the 5 biggest improvements

Ranked by speed-up factor. Plans are the last run of each benchmark (cost estimates and buffer lines removed for readability; full plans in the result files).

### R19: 4,216.663 ms → 8.274 ms (510× faster)

**Before** ([`baseline/R19.txt`](../benchmarks/results/baseline/R19.txt))
```
Sort  (actual time=4243.410..4243.422 rows=480.00 loops=1)
  Sort Key: ((SubPlan 1)) DESC
  Sort Method: quicksort  Memory: 51kB
  ->  Hash Right Semi Join  (actual time=12.682..4243.284 rows=480.00 loops=1)
        Hash Cond: (sc.doctor_id = d.doctor_id)
        ->  Hash Join  (actual time=0.086..2.309 rows=3900.00 loops=1)
              Hash Cond: (sc.clinic_id = c.clinic_id)
              ->  Seq Scan on doctor_schedules sc  (actual time=0.003..0.964 rows=30499.00 loops=1)
              ->  Hash  (actual time=0.075..0.076 rows=240.00 loops=1)
                    Buckets: 1024  Batches: 1  Memory Usage: 17kB
                    ->  Seq Scan on clinics c  (actual time=0.004..0.064 rows=240.00 loops=1)
                          Filter: (city_id = 1)
                          Rows Removed by Filter: 1260
        ->  Hash  (actual time=0.337..0.337 rows=3000.00 loops=1)
              Buckets: 4096  Batches: 1  Memory Usage: 186kB
              ->  Seq Scan on doctors d  (actual time=0.002..0.171 rows=3000.00 loops=1)
        SubPlan 1
          ->  Aggregate  (actual time=5.010..5.010 rows=1.00 loops=480)
                ->  Seq Scan on appointments a  (actual time=4.751..5.009 rows=2.26 loops=480)
                      Filter: ((slot_start >= '2026-06-01 00:00:00+05:30'::timestamp with time zone) AND (slot_start < '2026-07-01 00:00:00+05:30'::timestamp with time zone) AND (doctor_id = d.doctor_id) AND ((status)::text = 'COMPLETED'::text))
                      Rows Removed by Filter: 149998
        SubPlan 2
          ->  Aggregate  (actual time=3.823..3.823 rows=1.00 loops=480)
                ->  Seq Scan on appointments a_1  (actual time=0.080..3.819 rows=49.60 loops=480)
                      Filter: (doctor_id = d.doctor_id)
                      Rows Removed by Filter: 149950
Planning Time: 0.746 ms
Execution Time: 4243.487 ms
```
**After** ([`optimized/R19.txt`](../benchmarks/results/optimized/R19.txt))
```
Sort  (actual time=7.720..7.740 rows=480.00 loops=1)
  Sort Key: (count(*) FILTER (WHERE (((a.status)::text = 'COMPLETED'::text) AND (a.slot_start >= '2026-06-01 00:00:00+05:30'::timestamp with time zone) AND (a.slot_start < '2026-07-01 00:00:00+05:30'::timestamp with time zone)))) DESC
  Sort Method: quicksort  Memory: 51kB
  ->  Nested Loop  (actual time=0.642..7.640 rows=480.00 loops=1)
        ->  Hash Right Semi Join  (actual time=0.559..2.087 rows=480.00 loops=1)
              Hash Cond: (sc.doctor_id = d.doctor_id)
              ->  Nested Loop  (actual time=0.005..1.094 rows=3900.00 loops=1)
                    ->  Seq Scan on clinics c  (actual time=0.003..0.134 rows=240.00 loops=1)
                          Filter: (city_id = 1)
                          Rows Removed by Filter: 1260
                    ->  Index Only Scan using idx_sched_clinic on doctor_schedules sc  (actual time=0.002..0.002 rows=16.25 loops=240)
                          Index Cond: (clinic_id = c.clinic_id)
                          Heap Fetches: 0
                          Index Searches: 240
              ->  Hash  (actual time=0.547..0.547 rows=3000.00 loops=1)
                    Buckets: 4096  Batches: 1  Memory Usage: 186kB
                    ->  Seq Scan on doctors d  (actual time=0.002..0.254 rows=3000.00 loops=1)
        ->  Aggregate  (actual time=0.011..0.011 rows=1.00 loops=480)
              ->  Index Only Scan using idx_appt_doctor_slot on appointments a  (actual time=0.003..0.007 rows=49.60 loops=480)
                    Index Cond: (doctor_id = d.doctor_id)
                    Heap Fetches: 26
                    Index Searches: 480
Planning Time: 0.662 ms
Execution Time: 7.795 ms
```

### R22: 35.271 ms → 0.120 ms (294× faster)

**Before** ([`baseline/R22.txt`](../benchmarks/results/baseline/R22.txt))
```
Limit  (actual time=29.553..29.554 rows=25.00 loops=1)
  ->  Sort  (actual time=24.904..27.872 rows=100025.00 loops=1)
        Sort Key: slot_start DESC
        Sort Method: external merge  Disk: 6176kB
        ->  Seq Scan on appointments  (actual time=0.005..8.445 rows=150000.00 loops=1)
Planning Time: 0.170 ms
Execution Time: 30.872 ms
```
**After** ([`optimized/R22.txt`](../benchmarks/results/optimized/R22.txt))
```
Limit  (actual time=0.042..0.052 rows=25.00 loops=1)
  ->  Index Only Scan Backward using idx_appt_slot_covering on appointments  (actual time=0.041..0.049 rows=25.00 loops=1)
        Index Cond: (ROW(slot_start, appointment_id) < ROW('2025-07-08 12:15:00+05:30'::timestamp with time zone, 50125))
        Heap Fetches: 0
        Index Searches: 1
Planning Time: 1.111 ms
Execution Time: 0.079 ms
```

### R03: 20.791 ms → 0.231 ms (90× faster)

**Before** ([`baseline/R03.txt`](../benchmarks/results/baseline/R03.txt))
```
Merge Anti Join  (actual time=17.114..17.116 rows=12.00 loops=1)
  Merge Cond: (slot.slot = a.slot_start)
  ->  Sort  (actual time=0.108..0.109 rows=12.00 loops=1)
        Sort Key: slot.slot
        Sort Method: quicksort  Memory: 25kB
        ->  Nested Loop  (actual time=0.091..0.095 rows=12.00 loops=1)
              ->  Index Scan using doctor_schedules_pkey on doctor_schedules sc  (actual time=0.015..0.016 rows=1.00 loops=1)
                    Index Cond: ((doctor_id = 217) AND (weekday = 5))
                    Filter: (clinic_id IS NOT NULL)
                    Rows Removed by Filter: 1
                    Index Searches: 1
              ->  Function Scan on generate_series slot  (actual time=0.075..0.076 rows=12.00 loops=1)
  ->  Sort  (actual time=16.998..17.001 rows=72.00 loops=1)
        Sort Key: a.slot_start
        Sort Method: quicksort  Memory: 25kB
        ->  Seq Scan on appointments a  (actual time=0.436..16.988 rows=72.00 loops=1)
              Filter: (((status)::text <> 'CANCELLED'::text) AND (doctor_id = 217))
              Rows Removed by Filter: 149928
Planning Time: 0.710 ms
Execution Time: 17.195 ms
```
**After** ([`optimized/R03.txt`](../benchmarks/results/optimized/R03.txt))
```
Merge Anti Join  (actual time=0.177..0.180 rows=12.00 loops=1)
  Merge Cond: (slot.slot = a.slot_start)
  ->  Sort  (actual time=0.077..0.078 rows=12.00 loops=1)
        Sort Key: slot.slot
        Sort Method: quicksort  Memory: 25kB
        ->  Nested Loop  (actual time=0.055..0.058 rows=12.00 loops=1)
              ->  Index Scan using doctor_schedules_pkey on doctor_schedules sc  (actual time=0.028..0.028 rows=1.00 loops=1)
                    Index Cond: ((doctor_id = 217) AND (weekday = 5))
                    Filter: (clinic_id IS NOT NULL)
                    Rows Removed by Filter: 1
                    Index Searches: 1
              ->  Function Scan on generate_series slot  (actual time=0.026..0.027 rows=12.00 loops=1)
  ->  Index Only Scan using idx_appt_doctor_slot on appointments a  (actual time=0.086..0.095 rows=72.00 loops=1)
        Index Cond: (doctor_id = 217)
        Filter: ((status)::text <> 'CANCELLED'::text)
        Rows Removed by Filter: 14
        Heap Fetches: 0
        Index Searches: 1
Planning Time: 1.551 ms
Execution Time: 0.252 ms
```

### R05: 10.270 ms → 0.141 ms (73× faster)

**Before** ([`baseline/R05.txt`](../benchmarks/results/baseline/R05.txt))
```
Sort  (actual time=8.930..10.150 rows=3.00 loops=1)
  Sort Key: a.slot_start
  Sort Method: quicksort  Memory: 25kB
  ->  Nested Loop  (actual time=8.780..10.131 rows=3.00 loops=1)
        ->  Gather  (actual time=8.768..10.107 rows=3.00 loops=1)
              Workers Planned: 1
              Workers Launched: 1
              ->  Parallel Seq Scan on appointments a  (actual time=7.274..7.372 rows=1.50 loops=2)
                    Filter: ((doctor_id = 16) AND (date(slot_start) = '2026-06-30'::date))
                    Rows Removed by Filter: 74998
        ->  Index Scan using patients_pkey on patients p  (actual time=0.006..0.006 rows=1.00 loops=3)
              Index Cond: (patient_id = a.patient_id)
              Index Searches: 3
Planning Time: 0.422 ms
Execution Time: 10.225 ms
```
**After** ([`optimized/R05.txt`](../benchmarks/results/optimized/R05.txt))
```
Nested Loop  (actual time=0.075..0.137 rows=3.00 loops=1)
  ->  Index Scan using idx_appt_doctor_slot on appointments a  (actual time=0.035..0.051 rows=3.00 loops=1)
        Index Cond: ((doctor_id = 16) AND (slot_start >= '2026-06-30 00:00:00+05:30'::timestamp with time zone) AND (slot_start < '2026-07-01 00:00:00+05:30'::timestamp with time zone))
        Index Searches: 1
  ->  Index Scan using patients_pkey on patients p  (actual time=0.025..0.025 rows=1.00 loops=3)
        Index Cond: (patient_id = a.patient_id)
        Index Searches: 3
Planning Time: 1.848 ms
Execution Time: 0.240 ms
```

### R21: 11.561 ms → 0.189 ms (61× faster)

**Before** ([`baseline/R21.txt`](../benchmarks/results/baseline/R21.txt))
```
Limit  (actual time=11.185..12.087 rows=100.00 loops=1)
  ->  Gather Merge  (actual time=11.185..12.076 rows=100.00 loops=1)
        Workers Planned: 1
        Workers Launched: 1
        ->  Sort  (actual time=10.198..10.200 rows=73.00 loops=2)
              Sort Key: slot_start DESC
              Sort Method: top-N heapsort  Memory: 38kB
              Worker 0:  Sort Method: top-N heapsort  Memory: 38kB
              ->  Parallel Seq Scan on appointments  (actual time=0.006..8.552 rows=12341.50 loops=2)
                    Filter: (((status)::text = 'COMPLETED'::text) AND ((payment_status)::text = 'PENDING'::text))
                    Rows Removed by Filter: 62658
Planning Time: 0.197 ms
Execution Time: 12.114 ms
```
**After** ([`optimized/R21.txt`](../benchmarks/results/optimized/R21.txt))
```
Limit  (actual time=0.017..0.172 rows=100.00 loops=1)
  ->  Index Scan Backward using idx_appt_unpaid_completed on appointments  (actual time=0.016..0.166 rows=100.00 loops=1)
        Index Searches: 1
Planning Time: 1.009 ms
Execution Time: 0.204 ms
```

## 7. Write overhead

Every new index on `appointments` must be updated when a row is inserted or when an indexed column changes. `status` appears in I1/I3's INCLUDE and in the partial-index conditions, so status updates also rewrite index entries (no HOT updates). The write queries run inside `BEGIN … ROLLBACK` in both benchmarks.

| Write | Before (ms) | After (ms) | Change | What it touches now |
|---|---:|---:|---:|---|
| W01 | 0.675 | 0.671 | -0.6% | Inserts 1 BOOKED row → PK + I1, I2, I3, I5 (not I4: wrong status) |
| W02 | 11.225 | 0.679 | -94.0% | Finds the row via I5 instead of a full scan; updates 1 row's indexes |
| W03 | 0.263 | 0.558 | +112.2% | `follow_up_date` is now indexed (I7), so the update can't be HOT: a new entry is written into **all 4** indexes of `prescriptions` (PK, `appointment_id`, I7, I8) |
| W04 | 20.036 | 8.585 | -57.2% | Finds 329 open rows via I5; each status change updates I1, I3, I5 |
| W05 | 13.203 | 0.866 | -93.4% | Finds 3 rows via I5 instead of a full scan; updates their indexes |

**Slower: W03.** W03 went from 0.263 to 0.558 ms (0.295 ms more). The extra work is maintaining the new index entries on every write. This is acceptable: it is a fraction of a millisecond per write, every write is still far under its 5 ms / 1,000 ms target, and in exchange 20+ reads stopped scanning the whole table.

## 8. Index storage

```
    table_name    |          index_name          | index_size | table_size | pct_of_table 
------------------+------------------------------+------------+------------+--------------
 appointments     | idx_appt_slot_covering       | 8720 kB    | 21 MB      |         40.1
 appointments     | idx_appt_doctor_slot         | 8640 kB    | 21 MB      |         39.7
 appointments     | idx_appt_patient_doctor_slot | 4640 kB    | 21 MB      |         21.3
 appointments     | idx_appt_unpaid_completed    | 776 kB     | 21 MB      |          3.6
 appointments     | idx_appt_open                | 72 kB      | 21 MB      |          0.3
 doctor_schedules | idx_sched_clinic             | 736 kB     | 1800 kB    |         40.9
 patients         | idx_patients_allergies_gin   | 80 kB      | 4264 kB    |          1.9
 prescriptions    | idx_presc_issued_at          | 2000 kB    | 7296 kB    |         27.4
 prescriptions    | idx_presc_follow_up          | 224 kB     | 7296 kB    |          3.1
```

```
 new_indexes_total | all_tables_total | all_indexes_total | database_size 
-------------------+------------------+-------------------+---------------
 25 MB             | 54 MB            | 45 MB             | 107 MB
```

The two big covering indexes (I1, I3) are each ~40% of the `appointments` table, the price of Index Only Scans. The partial indexes are tiny (I5 < 1%) because they only hold the rows their queries can match.

## 9. Queries we could not speed up much, and why

- **R10** (19.743 → 23.488 ms, -19%): It must join every appointment of the 1,737 penicillin-allergic patients with their prescriptions and items. The GIN index finds the patients instantly, but the planner still prefers one hash join over all appointments to 1,737 separate index probes, and a forced index plan was no faster in our tests. The real cost is the join, not a missing index.
- **R14** (22.714 → 29.288 ms, -29%): It must read **every** review (30,339 rows) and look up each review's doctor, so the whole join has to happen. No index can skip that work. If it had to be instant, the answer would be a summary table refreshed nightly.
- **R15** (19.909 → 17.228 ms, 13%): It must count medicines for all ~5,500 June prescriptions (~13,700 item rows). I8 finds the prescriptions fast, but the planner still scans the 243,085 items for the join, because one scan is cheaper than thousands of lookups at this size. A forced nested-loop plan was no faster.
- **R17** (34.450 → 34.685 ms, -1%): It must read every completed 2026 appointment (~40,700) with its patient and compute `age()` for each. I3 makes the read an Index Only Scan, but `age()` and the sort of 40,700 rows remain. Rewriting `age()` as date arithmetic gives different answers on edge cases (e.g. 29 Feb birthdays), so we kept it.
- **R24** (24.271 → 29.747 ms, -23%): To find double bookings it must compare the **whole** table with itself. We tried two rewrites (window function; GROUP BY … HAVING then join back); both were slower than PostgreSQL's single hash join, so R24 is unchanged.
- **R25** (19.238 → 14.006 ms, 27%): It reads all ~40,700 completed 2026 appointments and sorts them for `count(DISTINCT doctor_id)`; the index makes the read cheaper but the grouping work stays.
- **R01, R02, R06, R07, R23, W01, W03** were already fast (< 5 ms): they touch small tables or find their rows through a PRIMARY KEY / UNIQUE index created in Phase 2.

These are all **reports** (target < 5,000 ms on the 20× dataset) whose answer depends on a large share of the data, so they must read it. If any misses its target at scale, the next step is a summary table / materialized view refreshed nightly (Phase 5).

## 10. Reads whose average went up

| Query | Before runs (ms) | After runs (ms) | Median before → after | Same plan? |
|---|---|---|---|:-:|
| R10 | 21.190 / 20.150 / 17.888 | 34.848 / 25.246 / 21.429 / 18.569 / 17.346 | 20.150 → 21.429 | changed |
| R14 | 25.426 / 22.848 / 19.868 | 49.215 / 30.224 / 24.162 / 22.015 / 20.825 | 22.848 → 24.162 | yes |
| R17 | 36.117 / 33.727 / 33.505 | 48.953 / 35.554 / 29.684 / 29.777 / 29.459 | 33.727 → 29.777 | changed |
| R23 | 0.033 / 0.026 / 0.026 | 0.106 / 0.085 / 0.121 / 0.040 / 0.090 | 0.026 → 0.090 | yes |
| R24 | 27.567 / 23.905 / 21.340 | 48.138 / 30.119 / 25.768 / 23.702 / 21.009 | 23.905 → 25.768 | yes |

- **First run was cold** for R10, R14, R17, R24: run 1 is clearly the slowest of the five, and the later runs are back at the baseline level. Run 1 pays for reading data into memory and CPU warm-up; it is still counted in the average, so the average looks worse than the typical run.
- **Same plan as before** for R14, R23, R24: no index or rewrite changes how they run (identical scan nodes in both `summary.csv` files), so the difference is measurement noise, not a regression. The sub-millisecond ones (if listed) differ by hundredths of a millisecond.
- **R10:** The plan changed only in how the **patients** are found: the GIN index (I9) replaced the scan of all 40,000 patients, and that step dropped from ~2.3 ms to ~0.6 ms in the plans. The query's time is dominated by the hash join over **all** appointments (see §9), which is unchanged.
- **R17:** The plan changed: the 2026 completed appointments now come from I3 by an Index Only Scan instead of a table scan. The `age()` computation and the sort of ~40,700 rows still dominate (see §9).

