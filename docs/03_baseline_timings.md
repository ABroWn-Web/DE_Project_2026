# 03 · Baseline timings (Phase 3)

All 30 queries of `queries/workload_30.sql`, **unchanged**, on the schema of Phase 2 (only the automatic PK / UNIQUE indexes exist; no tuning).

**How we measured** (the method in README §3.1, done by `benchmarks/run_benchmark.sh`):

- every query run with `EXPLAIN (ANALYZE, BUFFERS)`, **3 times**; the time is the `Execution Time` line of each run
- **Average** = mean of the 3 runs; write queries (W01–W05) run inside `BEGIN … ROLLBACK`, so the data never changed
- raw plans of all 3 runs: [`benchmarks/results/baseline/`](../benchmarks/results/baseline/) (`R01.txt` … `W05.txt`); summary: [`summary.csv`](../benchmarks/results/baseline/summary.csv)
- machine: **MacBook Pro, Apple M4, 16 GB RAM, macOS** · PostgreSQL **18.7** · default server settings · other heavy apps closed
- command: `./benchmarks/run_benchmark.sh practo baseline`

## Timing table

| SQL Query | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
|---|---|---:|---:|---:|---:|
| R01: Find a doctor: verified dermatologists practising in Bengaluru, most experienced first | READ | 4.883 | 4.430 | 4.587 | 4.633 |
| R02: Doctor profile: doctor 217's weekly timetable with clinic names | READ | 1.009 | 1.033 | 1.044 | 1.029 |
| R03: Slot picker: doctor 217's free in-clinic slots on Friday 3 July 2026 | READ | 26.046 | 19.131 | 17.195 | 20.791 |
| R04: "My appointments": patient 90's upcoming appointments | READ | 12.550 | 13.729 | 12.412 | 12.897 |
| R05: Doctor's queue: doctor 16's appointments on 30 June 2026 | READ | 8.777 | 11.807 | 10.225 | 10.270 |
| R06: Sign-in with mobile number | READ | 0.062 | 0.079 | 0.090 | 0.077 |
| R07: Prescription view: the prescription and medicines of appointment 18872 | READ | 0.254 | 0.256 | 0.152 | 0.221 |
| R08: Quality: no-show rate per specialization in 2026 | READ | 42.515 | 28.347 | 23.719 | 31.527 |
| R09: Clinic experience: average minutes patients waited after their slot time, per clinic (June 2026) | READ | 9.932 | 10.861 | 11.050 | 10.614 |
| R10: Patient safety: patients allergic to penicillin who were prescribed amoxicillin | READ | 21.190 | 20.150 | 17.888 | 19.743 |
| R11: Care team: follow-ups due in the first week of July 2026 that the patient has not booked yet | READ | 19.770 | 17.494 | 16.715 | 17.993 |
| R12: Product analytics: video vs in-clinic appointments per month in 2026 | READ | 22.760 | 21.247 | 21.176 | 21.728 |
| R13: Clinic partnerships: clinics where no doctor has any schedule | READ | 2.486 | 2.805 | 2.333 | 2.541 |
| R14: Doctor ranking: average rating and recommendation rate (at least 10 reviews) | READ | 25.426 | 22.848 | 19.868 | 22.714 |
| R15: Pharmacy partners: most prescribed medicines per primary specialization in June 2026 | READ | 20.623 | 19.958 | 19.146 | 19.909 |
| R16: Finance: fees collected per clinic in June 2026 | READ | 9.766 | 9.998 | 9.668 | 9.811 |
| R17: Population health: completed appointments by patient age group and blood group (2026) | READ | 36.117 | 33.727 | 33.505 | 34.450 |
| R18: Search filter: Tamil-speaking doctors with Chennai clinics | READ | 4.120 | 4.768 | 5.319 | 4.736 |
| R19: City report: June 2026 completed consultations and latest consultation of every doctor with a Bengaluru clinic | READ | 4,133.082 | 4,273.420 | 4,243.487 | 4,216.663 |
| R20: Platform analytics: completed appointments per day and running total, June 2026 | READ | 9.888 | 10.362 | 10.374 | 10.208 |
| R21: Finance: completed in-clinic consultations whose fee is still unpaid | READ | 11.093 | 11.475 | 12.114 | 11.561 |
| R22: Support console: all appointments, newest first, page 4,001 (25 per page) | READ | 41.824 | 33.118 | 30.872 | 35.271 |
| R23: Verification team: look up a doctor by medical council registration number | READ | 0.033 | 0.026 | 0.026 | 0.028 |
| R24: Data quality: two active appointments of the same doctor in the same slot (double bookings) | READ | 27.567 | 23.905 | 21.340 | 24.271 |
| R25: Care quality: patients who saw 3 or more different doctors of the same specialization in 2026 | READ | 19.643 | 19.435 | 18.637 | 19.238 |
| W01: Book: patient 90 books doctor 217's 10:30 slot on Friday 3 July 2026 | WRITE | 0.617 | 0.537 | 0.871 | 0.675 |
| W02: Reception: check in the earliest BOOKED in-clinic appointment of 1 July 2026 | WRITE | 10.399 | 11.641 | 11.636 | 11.225 |
| W03: Doctor: add notes and a follow-up date to the prescription of appointment 18872 | WRITE | 0.177 | 0.151 | 0.461 | 0.263 |
| W04: Nightly job (run at 00:00 on 2 July 2026): BOOKED appointments whose slot has ended become NO_SHOW | WRITE | 23.585 | 19.166 | 17.358 | 20.036 |
| W05: Doctor on leave: cancel and refund all of doctor 504's appointments on 3 July 2026 | WRITE | 11.822 | 13.598 | 14.190 | 13.203 |
| **Total (sum of all 30)** | | **4,558.016** | **4,659.502** | **4,607.458** | **4,608.326** |

## What the numbers say

- **R19 is by far the slowest** (4,216.663 ms on average, **92% of the total**). It is the "noticeably longer" query the brief warns about (see below).
- **21 of the 30 queries do a `Seq Scan on appointments`** (R03, R04, R05, R08, R09, R10, R11, R12, R14, R15, R16, R17, R19, R20, R21, R22, R24, R25, W02, W04, W05). `appointments` (150,000 rows) has only its primary-key index, so any filter on doctor, patient, date or status reads the whole table.
- **5 queries use only index scans** (R06, R07, R23, W01, W03). Each looks rows up by a PRIMARY KEY or UNIQUE column, whose index PostgreSQL created automatically. 5 queries finish in under 1 ms (R06, R07, R23, W01, W03).
- **R13 is fast but returns a wrong answer** (0 rows instead of 292); that is a NULL problem, not a speed problem.

## Scan type and reason, per query

Scan nodes are taken from the plan of run 3 (`scan_nodes` column of `summary.csv`).

| Query | Scan type(s) in the plan | Why it is slow / fast |
|---|---|---|
| R01 | Seq Scan on doctor_specializations<br>Seq Scan on specializations<br>Index Scan using doctors_pkey on doctors<br>Index Scan using doctor_schedules_pkey on doctor_schedules<br>Seq Scan on clinics | Fast. Only small tables are touched: the specialization filter leaves ~250 dermatologists, and each one's doctor row and schedule rows are found through the primary-key indexes (`doctors_pkey`, `doctor_schedules_pkey`, whose first column is `doctor_id`). `clinics` (1,500 rows) is small enough to scan. |
| R02 | Index Scan using doctor_schedules_pkey on doctor_schedules<br>Seq Scan on clinics | Fast. `doctor_id = 217` is the first column of `doctor_schedules_pkey`, so the 9 schedule rows come straight from the index. `clinics` is scanned once for the hash join, but it has only 1,500 rows. |
| R03 | Index Scan using doctor_schedules_pkey on doctor_schedules<br>Seq Scan on appointments | The schedule part is an index lookup, but the `NOT EXISTS` check has **no index on `appointments(doctor_id, slot_start)`**, so it scans all 150,000 appointments to keep the ~70 rows of doctor 217. |
| R04 | Seq Scan on appointments<br>Index Scan using doctors_pkey on doctors<br>Seq Scan on clinics | **No index on `appointments.patient_id`**: PostgreSQL reads all 150,000 appointments to find patient 90's 2 booked ones. |
| R05 | Seq Scan on appointments<br>Index Scan using patients_pkey on patients | No index on `appointments.doctor_id`, and `DATE(slot_start)` wraps the column in a function, so even an index on `slot_start` couldn't be used (not *sargable*). It scans the whole table to return 3 rows. |
| R06 | Index Scan using patients_phone_key on patients | Fast. `phone` is UNIQUE, so the automatic index `patients_phone_key` finds the one row directly. |
| R07 | Index Scan using prescriptions_appointment_id_key on prescriptions<br>Index Scan using prescription_items_pkey on prescription_items | Fast. `prescriptions.appointment_id` is UNIQUE (index `prescriptions_appointment_id_key`), and the items are found through `prescription_items_pkey`, whose first column is `prescription_id`. |
| R08 | Seq Scan on appointments<br>Seq Scan on doctor_specializations<br>Seq Scan on specializations | `EXTRACT(YEAR FROM slot_start) = 2026` is a function on the column, so no index could help. It reads every appointment, joins the primary specializations by hash, then sorts and groups ~45,000 rows. |
| R09 | Seq Scan on appointments | **No index on `slot_start`**: it scans all 150,000 rows to keep the ~5,600 completed in-clinic appointments of June 2026, then aggregates per clinic. |
| R10 | Seq Scan on appointments<br>Seq Scan on patients<br>Index Scan using prescriptions_appointment_id_key on prescriptions<br>Index Scan using prescription_items_pkey on prescription_items | `allergies @> ARRAY['Penicillin']` has no GIN index (scan of all 40,000 patients), and there is **no index on `appointments.patient_id`**, so all appointments are scanned and hash-joined. Prescriptions and items are then found through their unique/PK indexes. `ILIKE '%amoxicillin%'` can't use a B-tree. |
| R11 | Seq Scan on appointments<br>Seq Scan on prescriptions<br>Index Scan using appointments_pkey on appointments | No index on `prescriptions.follow_up_date` (full scan to find 430 rows), and the `NOT EXISTS` anti-join reads all ~135,000 non-cancelled appointments because there is no index on `appointments(patient_id, doctor_id, slot_start)`. |
| R12 | Seq Scan on appointments | `EXTRACT(YEAR …)` on the column can't use an index. It reads the whole table and sorts ~51,000 rows of 2026 to group by month. As a report it must read a year of data anyway. |
| R13 | Seq Scan on clinics<br>Seq Scan on doctor_schedules | Fast, but **the answer is wrong**: it returns 0 rows although 292 clinics have no schedule. `NOT IN` against a subquery that contains NULLs (video schedules have `clinic_id = NULL`) is never TRUE. Fixed in Phase 4. |
| R14 | Seq Scan on appointments<br>Seq Scan on doctor_reviews | Must read every review (30,339), and it scans all 150,000 appointments to get each review's `doctor_id` for the hash join, then aggregates per doctor. |
| R15 | Seq Scan on prescription_items<br>Seq Scan on appointments<br>Seq Scan on prescriptions<br>Seq Scan on doctor_specializations<br>Seq Scan on specializations | Joins the largest table, `prescription_items` (243,085 rows), fully scanned, with prescriptions filtered on `issued_at` (no index) and all appointments, all through hash joins. |
| R16 | Seq Scan on appointments<br>Seq Scan on clinics | **No index on `slot_start`**: the full scan keeps only ~6,400 paid June appointments, then hash-joins the clinics and aggregates. |
| R17 | Seq Scan on appointments<br>Seq Scan on patients | Reads all 2026 completed appointments (~40,700) and all 40,000 patients (hash join), computes `age()` for every row, then sorts and groups. As a report it must read most of the year anyway. |
| R18 | Seq Scan on doctor_schedules<br>Seq Scan on doctors<br>Seq Scan on clinics | `'Tamil' = ANY(languages)` has no GIN index, so all three tables are scanned. They are small (3,000 doctors, 1,500 clinics, 30,499 schedules), so it's still quick. |
| R19 | Seq Scan on doctor_schedules<br>Seq Scan on clinics<br>Seq Scan on doctors<br>Seq Scan on appointments | **Slowest query.** The two correlated subqueries run **once per Bengaluru doctor (480 times)**, and each run is a full scan of 150,000 appointments because there is no index on `appointments.doctor_id`. That's ~960 full scans (~144 million rows read) to return 480 rows. |
| R20 | Seq Scan on appointments | `slot_start::date BETWEEN …` casts the column, so it isn't sargable: full scan to keep ~6,900 completed June rows. The window function for the running total (26 days) is cheap. |
| R21 | Seq Scan on appointments | No index on `(status, payment_status, slot_start)`: it scans all appointments, keeps ~24,700 unpaid completed ones and top-N sorts them for the newest 100. |
| R22 | Seq Scan on appointments | `OFFSET 100000` means PostgreSQL must read and **sort all 150,000 rows** and throw away the first 100,000 just to return 25. In our plan the sort did not fit in memory and spilled to disk (`Sort Method: external merge`). |
| R23 | Index Scan using doctors_registration_no_key on doctors | Fast. `registration_no` is UNIQUE, so `doctors_registration_no_key` returns the row directly. |
| R24 | Seq Scan on appointments | A self-join of `appointments`: the table is scanned **twice** (~135,000 non-cancelled rows each) and hash-joined on `(doctor_id, slot_start)`. The join is the right strategy, but it must compare the whole table. |
| R25 | Seq Scan on appointments<br>Seq Scan on doctor_specializations | Scans all appointments to keep ~40,700 completed 2026 rows, joins primary specializations, then sorts for `count(DISTINCT doctor_id)` per patient and specialization. |
| W01 | Index Scan using doctor_schedules_pkey on doctor_schedules<br>Index Scan using doctors_pkey on doctors | Fast. The schedule and doctor rows come from their primary-key indexes; the insert maintains only the PK index of `appointments` (there are no other indexes yet). |
| W02 | Seq Scan on appointments<br>Index Scan using appointments_pkey on appointments | The subquery has no index on `(status, consult_type, slot_start)`: full scan to find the 227 booked in-clinic appointments of 1 July and top-N sort for the earliest. The update itself uses `appointments_pkey`. |
| W03 | Index Scan using prescriptions_appointment_id_key on prescriptions | Fast. The row is found through the UNIQUE index on `prescriptions.appointment_id`. |
| W04 | Seq Scan on appointments | No index on `status` / `slot_end`: full scan of 150,000 rows to update the 329 booked appointments whose slot has ended. |
| W05 | Seq Scan on appointments | No index on `doctor_id`: full scan of 150,000 rows to cancel doctor 504's 3 appointments on 3 July. |
