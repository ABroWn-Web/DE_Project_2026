# 01 · Problem understanding (Phase 1)

Practo connects **patients** with **doctors**. Patients search for a doctor, book an in-clinic or video slot built from the doctor's weekly schedule, check in at the clinic, consult, get a prescription and may leave a review. The old database has no documented schema, and seven teams report problems. All of them are about *speed* except P5, which is about a *wrong answer*.

| # | What the business needs (our words) | Stakeholders affected | Queries | Class |
|---|---|---|---|---|
| **P1** | A patient must find a doctor (by specialization, city, language), open the profile and see free slots **while they wait on the screen**. Free slots are computed from the schedule minus booked appointments on every request, so this must be fast. | Patient; doctors (lost bookings if search is slow) | R01, R02, R03, R18 | **Customer-facing / real-time** (R01, R18 are interactive search) |
| **P2** | Signing in with a mobile number, opening *My appointments* and a prescription, and booking a slot must feel instant. Booking is a write on the busiest table. | Patient | R04, R06, R07, W01 | **Customer-facing / real-time** |
| **P3** | The front desk needs the doctor's queue for today and must check a patient in **while the patient stands at the counter**. | Clinic reception; doctor | R05, W02 | **Customer-facing / real-time** |
| **P4** | Find penicillin-allergic patients prescribed amoxicillin, follow-ups that are due but not booked, and patients "doctor shopping" in one specialization. Doctors also update prescriptions (notes, follow-up). | Patient-safety team; care team; doctor; patient | R10, R11, R25, W03 | **Reporting / analytics** (R10, R25), **interactive tool** (R11), **real-time write** (W03) |
| **P5** | Partnerships want the list of clinics where no doctor works, to re-engage them, but the list is **always empty**. This is a correctness bug, not slowness: `NOT IN (subquery)` returns nothing when the subquery contains a `NULL`, and video schedules have `clinic_id = NULL`. The data actually has **292** such clinics. | Clinic partnerships; partner clinics | R13 | **Reporting / internal tool** |
| **P6** | Quality reports (no-show rate, waiting time, doctor ratings, double bookings) time out. The nightly no-show job must finish inside its batch window. | Quality team; clinics; doctors; patients (indirectly) | R08, R09, R14, R24, W04 | **Reporting / analytics**; W04 = **batch job** |
| **P7** | Finance (fees per clinic, unpaid consults), pharmacy partners (top medicines), population health (age/blood group, daily totals), support (paging all appointments), verification (lookup by registration no.) and doctor-leave cancellations are slow **now**. Appointments will grow **20×**, so they must also scale. | Finance; pharmacy partners; insights team; support; verification team; doctors & patients (W05) | R12, R15, R16, R17, R19, R20, R21, R22, R23, W05 | Mostly **reporting / analytics**; R21, R22, W05 interactive tools; R23 real-time lookup |

**Performance targets that follow from the classes** (README §5.2): real-time screens and their writes < 5 ms; interactive search and tools < 250 ms; reports < 5 s; nightly batch < 1 s.

## Assumptions
1. **All times are IST (Asia/Kolkata).** Every timestamp in the export has `+05:30`, and "a day" (R05, R20, W02) means an IST calendar day. We set the database time zone to IST so that date conversions in the queries are correct (see `docs/02_schema_design.md`).
2. **"Now" is about 1 July 2026.** The history runs from 1 Jan 2025 to 30 Jun 2026. The only `BOOKED` appointments are future ones (1–15 Jul 2026), which matches W02, W04 and W05.
3. **`weekday` uses ISO numbering, 1 = Monday … 7 = Sunday.** The data has 1–6 (no Sunday clinics), and R03 uses 5 for Friday 3 Jul 2026.
4. **`clinic_id IS NULL` means a video consultation**, both in schedules and in appointments.
5. The 30 queries as written define the expected result, **except** where an SQL NULL rule makes them wrong (R13). That one we will fix and explain in Phase 4.
6. The CSV export is the source of truth. If a row breaks a business rule (e.g. a double booking), we **report it as a data problem** and do not change the data.
7. One laptop with default PostgreSQL server settings (version recorded in `team.json`) is used for both the baseline (Phase 3) and the optimized run (Phase 4).
