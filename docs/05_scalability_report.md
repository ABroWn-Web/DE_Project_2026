# 05 · Scalability report (CP4)

## 1. Method and dataset

We loaded `large_data/` into a separate database, `practo_large`. We ran our own `sql/01_schema.sql`, then `sql/02_load_data.sql` with only the CSV folder changed to `large_data/`, then `sql/05_indexes.sql` (which ends with `VACUUM ANALYZE`). All 11 files loaded with no errors. Then we ran only the **optimized** queries, 3 runs each:

```bash
./benchmarks/run_benchmark.sh practo_large large 3 sql/06_optimized_queries.sql
```

Raw plans for all 30 queries are in [`benchmarks/results/large/`](../benchmarks/results/large/). The seed column is our Phase 4 average from [`benchmarks/results/optimized/summary.csv`](../benchmarks/results/optimized/summary.csv). No server settings were changed and no data was modified (writes run inside `BEGIN … ROLLBACK`).

**Machines.** The large run used PostgreSQL 18.4 (Postgres.app) on a team member's Mac. The Phase 3/4 seed runs used PostgreSQL 18.7 on a MacBook Pro M4 (16 GB). This only matters for the sub-millisecond queries, where machine and cache noise is larger than the query's real work. The rows that matter for scaling (milliseconds to seconds) are dominated by how much data the plan reads.

| Table | Seed rows | Large rows | × |
|---|---:|---:|---:|
| doctors | 3,000 | 60,000 | 20 |
| doctor_specializations | 3,700 | 74,000 | 20 |
| clinics | 1,500 | 30,000 | 20 |
| doctor_schedules | 30,499 | 609,747 | 20 |
| patients | 40,000 | 800,000 | 20 |
| appointments | 150,000 | 3,000,000 | 20 |
| prescriptions | 97,234 | 1,944,432 | 20 |
| prescription_items | 243,085 | 4,861,080 | 20 |
| doctor_reviews | 30,339 | 608,179 | 20 |
| cities / specializations | 10 / 15 | 10 / 15 | 1 |

## 2. Results table

Large = average of 3 `EXPLAIN (ANALYZE, BUFFERS)` runs. Targets are from README §5.2.

| Query | Target | Optimized on seed (ms) | Optimized on large (ms) | Growth (large ÷ seed) | Meets target? | If not, what you changed |
|---|---:|---:|---:|---:|:---:|---|
| R01 | < 250 ms | 4.474 | 17.617 | 3.9× | ✅ | — |
| R02 | < 5 ms | 0.472 | 0.120 | 0.25× | ✅ | — |
| R03 | < 5 ms | 0.231 | 0.112 | 0.48× | ✅ | — |
| R04 | < 5 ms | 0.221 | 0.038 | 0.17× | ✅ | — |
| R05 | < 5 ms | 0.141 | 0.087 | 0.62× | ✅ | — |
| R06 | < 5 ms | 0.067 | 0.144 | 2.1× | ✅ | — |
| R07 | < 5 ms | 0.134 | 0.144 | 1.1× | ✅ | — |
| R08 | < 5,000 ms | 12.563 | 104.589 | 8.3× | ✅ | — |
| R09 | < 5,000 ms | 5.336 | 60.464 | 11.3× | ✅ | — |
| R10 | < 5,000 ms | 23.488 | 294.931 | 12.6× | ✅ | — |
| R11 | < 250 ms | 2.240 | 18.705 | 8.4× | ✅ | — |
| R12 | < 5,000 ms | 16.693 | 70.748 | 4.2× | ✅ | — |
| R13 | < 250 ms | 2.235 | 20.468 | 9.2× | ✅ | — |
| R14 | < 5,000 ms | 29.288 | 350.035 | 12.0× | ✅ | — |
| R15 | < 5,000 ms | 17.228 | 245.876 | 14.3× | ✅ | — |
| R16 | < 5,000 ms | 2.929 | 53.516 | 18.3× | ✅ | — |
| R17 | < 5,000 ms | 34.685 | 447.300 | 12.9× | ✅ | — |
| R18 | < 250 ms | 3.336 | 50.540 | 15.2× | ✅ | — |
| R19 | < 5,000 ms | 8.274 | 107.439 | 13.0× | ✅ | — |
| R20 | < 5,000 ms | 2.714 | 19.671 | 7.2× | ✅ | — |
| R21 | < 250 ms | 0.189 | 0.167 | 0.88× | ✅ | — |
| R22 | < 250 ms | 0.120 | 0.047 | 0.39× | ✅ | — (cursor explained in §5) |
| R23 | < 5 ms | 0.088 | 0.150 | 1.7× | ✅ | — |
| R24 | < 5,000 ms | 29.747 | 1,763.766 | **59.3×** | ✅ | — (explained in §4.1) |
| R25 | < 5,000 ms | 14.006 | 328.722 | 23.5× | ✅ | — |
| W01 | < 5 ms | 0.671 | 1.008 | 1.5× | ✅ | — |
| W02 | < 5 ms | 0.679 | 0.415 | 0.61× | ✅ | — |
| W03 | < 5 ms | 0.558 | 0.055 | 0.10× | ✅ | — |
| W04 | < 1,000 ms | 8.585 | 496.095 | **57.8×** | ✅ | — (explained in §4.2) |
| W05 | < 250 ms | 0.866 | 0.054 | 0.06× | ✅ | — |

**All 30 queries meet their targets on the large data**, so no query had to be rewritten for this round. Two queries grew much faster than the data (R24, W04). We explain why in §4, because they are the first to break at 100×.

## 3. Growth analysis

### 3.1 Stayed about the same (< 2.5×): R02–R07, R21, R22, R23, W01, W02, W03, W05
These are single-key lookups through a B-tree: doctor 217's timetable, one patient's appointments, one phone number, one appointment's prescription, a 25-row keyset page. They return **the same number of rows** whatever the table size, and a B-tree's depth grows with log n. 20× more rows adds at most one level (one extra page read). Several are even *faster* on large. At 0.03–0.5 ms the time is mostly first-run cache misses and machine differences, not data. R06's average (0.144 ms) is pulled up by one slow run (0.380 ms); its median is 0.026 ms, lower than seed. All of them stay far under 5 ms.

### 3.2 Grew less than or about 20× (4–18×): R01, R08–R20, R11, R13
These read a **fixed share** of a table: "all of 2026", "June 2026", "every clinic". That share is 20× bigger, so the work is 20× bigger. Most grew *less* than 20× for three reasons:
- Seed times include fixed costs (planning, executor start-up, launching workers) that don't grow with data.
- PostgreSQL gives bigger tables more parallel workers. R24, for example, used 1 worker on seed and 2 on large.
- Some plans switched to a better access path once the tables were big enough (§4.3). R01 grew only 3.9× because its seq scans on `doctor_specializations` and `clinics` became index scans.

R16 (18.3×) is the closest to linear: a bitmap scan that reads 20× more June rows.

### 3.3 Grew more than 20×: R24 (59.3×), W04 (57.8×), R25 (23.5×)
- **R25** is slightly above linear. It groups and counts distinct doctors per patient over all 2026 appointments, and grouping/sorting costs a bit more than linear (n log n).
- **R24 and W04** are the real "breaks at scale". See §4.

## 4. What broke at scale

### 4.1 R24 (double bookings): the plan changed from a hash join to 2.7 million index probes
R24 self-joins `appointments` on `(doctor_id, slot_start)`. Same query, two different plans:

| | Seed (`optimized/R24.txt`) | Large (`large/R24.txt`) |
|---|---|---|
| Join | **Parallel Hash Join**, 1 worker | **Nested Loop**, 2 workers |
| Inner side | one seq scan into a hash table (8.4 MB, 1 batch) | `Index Only Scan using idx_appt_doctor_slot`, **2,703,682 index searches** (one per non-cancelled row) |
| Buffers | 5,448 shared hits, **0 reads** (≈ 43 MB) | 7.46 M hits + **702,087 reads** (≈ 5.4 GiB of page traffic) |
| Rows returned | 559 pairs | 11,308 pairs |
| Execution time | 21–28 ms | 1,717–1,808 ms |

On the seed data, both sides of the join (135,100 non-cancelled rows) fit in one in-memory hash table. On the large data, the hash table would be 20× bigger (2.7 M rows), far beyond the default `work_mem`, so it would have to spill to disk in batches. The planner instead chose a nested loop that probes our index once per row. Each probe is cheap (0.002 ms), but there are 2.7 million of them. Our appointment indexes are about 870 MB in total (§7), much more than PostgreSQL's default 128 MB `shared_buffers`, so the same index pages are read again and again (702,087 reads). That is why R24 grew 59× instead of 20×.

R24 still meets its 5 s target, so we left it unchanged (our CP3 rewrites of R24 were slower on seed). At 100× it would not meet the target (§8), so the real fix belongs in the design: **prevent double bookings instead of searching for them.** After the existing 11,308 pairs are cleaned up, a partial unique index
`CREATE UNIQUE INDEX ON appointments (doctor_id, slot_start) WHERE status <> 'CANCELLED';`
makes a second active booking of the same slot impossible. Then R24 always returns 0 rows and can be dropped from the nightly checks.

### 4.2 W04 (nightly NO_SHOW job): 20× more rows, each written to every index
W04 updates every open appointment whose slot has ended. On large data there are 20× more such rows. Each updated row also has to update every index on `appointments`, because `status` is part of `idx_appt_slot_covering` and of our two partial indexes, which rules out PostgreSQL's cheap "HOT" update path. The three runs show a second effect:

| Run | 1 | 2 | 3 |
|---|---:|---:|---:|
| W04 (ms) | 91.1 | 604.3 | 793.0 |

The benchmark runs every write inside `BEGIN … ROLLBACK`. Each rolled-back run leaves its new row versions and index entries behind as **dead tuples**, and the next run has to skip over them. So W04 slows down run after run until VACUUM cleans up. In production the same thing happens to any big UPDATE. This is why §8 sets more aggressive autovacuum for `appointments` and splits W04 into batches.

### 4.3 Other plan changes we saw (all still within target)
| Query | Seed plan | Large plan | Why |
|---|---|---|---|
| R01 | Seq Scan on `doctor_specializations`, `clinics` | Index scans on their primary keys | Lookups become cheaper than full scans on bigger tables |
| R04 | Bitmap Heap Scan | plain Index Scan | Patient 90 still has a few rows, now a tiny share of the table |
| R11 | Index Scan on `idx_presc_follow_up` | Bitmap scan on the same index | More matching rows, so it batches the heap reads |
| R18, R19 | Index Only Scan on `idx_sched_clinic` | Seq Scan on `doctor_schedules` (609,747 rows) | The query needs a large share of all schedules, so one sequential pass is cheaper |
| W05 | `idx_appt_open` | `idx_appt_doctor_slot` | With 20× more open appointments, "doctor 504 on 3 July" is the more selective path |

## 5. R22: how the keyset "last seen" value is chosen on the large data
R22 asks for page 4,001 (25 per page, newest first). Our optimized version uses keyset pagination: it starts right after the last row of page 4,000 instead of reading and discarding 100,000 rows with `OFFSET`. In the app, the "last seen" value is simply the `(slot_start, appointment_id)` of the last row on the page the user is looking at. The browser sends it back when "Next" is clicked, so it is always taken from the current data.

The constant in `sql/06_optimized_queries.sql` is the seed data's row 100,000. On the large data, page 4,000 ends at a different row, which we find once with:
```sql
SELECT slot_start, appointment_id FROM practo.appointments
ORDER BY slot_start DESC, appointment_id DESC OFFSET 99999 LIMIT 1;
```
The cost of the keyset query does **not** depend on which page it starts from: it is one index seek plus 25 index entries (Index Only Scan on `idx_appt_slot_covering`). That's why it takes 0.047 ms on 3 M rows. An `OFFSET` version would have to read 100,000 rows for this page and 2,999,975 rows for the last page.

## 6. Data checks on the large export
All 11 tables loaded with the expected row counts, and every constraint in `01_schema.sql` held. Cross-table checks found zero violations for schedule fit, clinic assignment, fee consistency, video eligibility, primary specializations, prescription and review timing, and review wait buckets. The export also contains these anomalies. We report them and do not "fix" them, because the export is the source of truth:

| Check | Seed | Large |
|---|---:|---:|
| Penicillin-allergic patients prescribed amoxicillin (R10) | 726 | 13,919 |
| Active double-booking pairs (R24) | 559 | 11,308 |
| Appointment booked before the patient's account was created | 1,072 | 20,704 |
| Check-in after the consultation started | 16,183 | 323,445 |
| Clinics with no scheduled doctor (R13, informational) | 292 | 10,668 |

## 7. Storage

| Dataset | Database size | Tables | Indexes |
|---|---:|---:|---:|
| Seed (150 k appointments) | 106.97 MiB | 53.76 MiB | 44.71 MiB |
| Large (3 M appointments) | 1.90 GiB | 1.04 GiB | 870.63 MiB |

Measured with `pg_database_size`, `pg_relation_size` and `pg_indexes_size` after `VACUUM ANALYZE`, before the partitioning test table was created. Storage grew 18.2× for 20× the rows. Indexes are **about 45% of the total size** on both datasets: that's the price of the covering indexes that give us Index Only Scans.

## 8. Architecture for 100×

100× the seed data is **15 M appointments**, 5× our large run. Scaling our measured numbers by 5 (linearly; the true numbers will be a bit higher):
- database ≈ **9.5 GiB**, of which indexes ≈ **4.3 GiB**
- **R24 ≈ 8.8 s or more** → misses the 5 s target
- **W04 ≈ 2.5 s** → misses the 1 s target
- all real-time lookups stay well under 1 ms (log n)

So R24 and W04 are what the design has to handle.

### 8.1 Partitioning: `appointments`, RANGE by `slot_start`, one partition per month
See [`sql/08_partitioning.sql`](../sql/08_partitioning.sql).
- **Why this table and column:** `appointments` is the biggest table that queries filter by time. 12 of the 30 queries filter on a `slot_start` range: one day, June 2026, or all of 2026 (R05, R08, R09, R11, R12, R16, R17, R19, R20, R25, W02, W05). With monthly partitions a June report reads 1 partition instead of the whole table, and closed months can be detached and archived.
- **Why RANGE, monthly:** the large data has ~162,000 appointments per month (3 M over Jan 2025 – mid-Jul 2026; June 2026 = 167,952). At 100× that is ~840,000 rows per month, a good partition size. HASH would spread a month over every partition and kill pruning. LIST has no natural values for time.
- **DDL and pruning proof:** we created `appointments_partitioned` with 24 monthly partitions (Jan 2025 – Dec 2026) plus a `DEFAULT` partition, and the same 5 appointment indexes as `05_indexes.sql`. We copied June 2026 (167,952 rows) into it. `EXPLAIN ANALYZE` of a June count scanned **only `appointments_2026_06`** (20.094 ms). The plan is in [`partition_pruning.txt`](../benchmarks/results/large/partition_pruning.txt).
- **Primary-key rule:** a unique key on a partitioned table must include the partition key, so the primary key becomes `(appointment_id, slot_start)`. `prescriptions` and `doctor_reviews` reference `appointment_id` alone, so in a real migration they need a `slot_start` column, a backfill, and composite foreign keys to `(appointment_id, slot_start)`. Then the data is copied, counts are checked, and the tables are swapped in one release.
- **Trade-off:** lookups by `appointment_id` alone (R07, W03) can't be pruned and probe every partition's index. With ~30 partitions that is still well under a millisecond, but we would archive old months to keep the count small.
- **Operations:** create next month's partition ahead of time and alert if any row lands in `DEFAULT`.

### 8.2 Sharding: by `doctor_id`
- **Why doctor:** booking is the critical write. W01 must check that a doctor's slot is free and insert the booking **atomically**. If all of a doctor's appointments live on one shard, that check is a normal local transaction, and the partial unique index from §4.1 can enforce "no double booking" on each shard. Sharding by patient would spread a doctor's slot across shards and make double bookings impossible to prevent locally. We already found 11,308 of them in the data.
- **Co-located on the doctor's shard:** `doctors`, `doctor_specializations`, `doctor_schedules`, `appointments`, and the `prescriptions`, `prescription_items` and `doctor_reviews` of those appointments.
- **Single-shard queries:** R02, R03, R05, W01, W05 (doctor-keyed), plus R07/W03 once the appointment id encodes its shard.
- **Cross-shard queries and how we handle them:**
  - R04 (a patient's appointments): keep a small `patient_appointments(patient_id → appointment_id, doctor_id)` lookup table, sharded by `patient_id` and updated on every booking. A patient has few rows, so this is a short fan-out.
  - R06 (sign-in) uses `patients` only. `patients` is sharded separately by `patient_id`.
  - R01, R18 (doctor search): `doctors`, `clinics` and `specializations` are small (60 k / 30 k / 15 rows at 20×), so they are copied to every shard as reference tables.
  - All other reports and tools (R08–R17, R19–R22, R24, R25): scatter-gather, i.e. run on every shard in parallel and merge, on replicas where allowed (§8.3). For R22 each shard returns its next 25 rows after the cursor, and we merge them and keep the newest 25.
  - W02 and W04 run on every shard in parallel.
- **Why not city:** Bengaluru and Mumbai would be hot shards, video consultations don't belong to a city, and a doctor can have clinics in more than one city.

### 8.3 Read replicas and caching
- **Replica (a few seconds' lag is fine):** reports R08–R10, R12–R17, R19, R20, R24, R25. These are also our slowest queries (up to 1.76 s), so moving them off the primary protects the booking path.
- **Cache for a few minutes:** R01, R02, R18, R23 (search, profiles, registration lookups that change rarely). R06 only if the cache is invalidated when a phone number changes.
- **Must hit the primary:** R03 (free slots must be live, or patients would see slots that are already booked), R04, R05, R07, R11, R21, R22 (patients, reception, care and support staff act on these rows right away), and all writes W01–W05.

### 8.4 Maintenance
- **Autovacuum for `appointments`:** the default `autovacuum_vacuum_scale_factor = 0.2` waits for 20% of rows to be dead: 600 k dead rows at 3 M, 3 M at 15 M. §4.2 shows how much dead rows slow W04, so we set it per table:
  ```sql
  ALTER TABLE appointments SET (autovacuum_vacuum_scale_factor = 0.02,
                                autovacuum_analyze_scale_factor = 0.01,
                                autovacuum_vacuum_insert_scale_factor = 0.05);
  ```
  With partitions this applies per month: closed months stop changing, stay all-visible, and keep our Index Only Scans at `Heap Fetches: 0` (as in large `R24.txt`).
- **W04 in batches:** update at most 10,000 rows per transaction (for example, one day at a time), so each batch is short and autovacuum can keep up. W04 filters on `slot_end`, not the partition key, so we would add a lower bound on `slot_start` (for example, the last 2 days). That lets it prune to the current partition.
- **Archiving:** detach partitions older than 24 months into an archive schema or cold storage, which keeps the live table and its indexes small.
- **Summary tables:** reports such as R08, R12 and R17 can read from materialized views refreshed nightly with `REFRESH MATERIALIZED VIEW CONCURRENTLY`, with the refresh time shown on the report.
- **Memory:** in production, `shared_buffers` would be sized so the hot appointment indexes fit in memory (870 MB at 20×). We did not change it for the benchmark, as the README requires.

## 9. Conclusion
**Yes, the database is ready for next year's 20× volume.** All 30 optimized queries meet their targets on 3 M appointments. The real-time screens average about 1 ms or less (slowest: W01, 1.008 ms), because our indexes turn them into log n lookups that barely notice the data growth.

**Remaining risks:**
1. **R24** grows faster than the data (59× for 20×) because its plan flips to 2.7 M index probes. It will miss 5 s at about 100×. Fix: the partial unique index that prevents double bookings.
2. **W04** grows with the number of open rows times the number of indexes, and slows down as dead tuples pile up. Fix: batching and tighter autovacuum.
3. **Partitioning** needs a careful migration (composite keys on `prescriptions` and `doctor_reviews`) and a monthly job to create partitions.
4. **Data quality:** the export already contains 11,308 double bookings and 13,919 penicillin/amoxicillin cases. These are business problems that indexes cannot fix.
