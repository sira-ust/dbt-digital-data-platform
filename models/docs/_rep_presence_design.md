# Adding store presence (GPS) to rep activity — design

Status: **proposed, not built.** Written 2026-08-14 after prototyping the whole
thing against real data. Every number quoted below is measured, not estimated.

## What this adds

The activity marts today measure **app usage** — which customers a rep worked,
for how long, on which device. They cannot say whether the rep was physically
at the customer. Adding GPS closes that, and splits a rep's day into five
distinguishable patterns:

| Scenario | On-site? | App activity? |
|---|---|---|
| remote | No | Yes |
| on-site | Yes | Yes, during the visit |
| visited, keyed elsewhere | Yes | Yes, outside the visit |
| customer ordered online | Either | Order arrives already placed |
| visit only, no app | Yes | None |

The last one is the reason presence must be derived **independently** rather
than joined onto activity: a visit that produced no typing has no activity row
to attach to, so building it the other way round leaves it invisible. On rep
025's 2026-08-10 it was a 58-minute stop — his longest of the day.

---

## 1. New seed — customer coordinates

`seeds/seed_customer_locations.csv`, from `1.address.xlsx` (2,810 rows, all
geocoded).

| Column | Note |
|---|---|
| `customer_key` | matches `customer_key` in the activity models |
| `latitude`, `longitude` | already present in the file |
| `address`, `city`, `county`, `post_code` | for drill-down |

**Blocked on a clean export.** 25 of the 2,810 customer codes have been
corrupted into dates by Excel (`2026-03-08 00:00:00` etc). One of them is where
rep 025 spent 109 minutes across three stops on 2026-08-10 — address survives
(4148 MONTEREY RD, SAN JOSE) but the code does not. Re-export with `No_` as
text before seeding.

Coverage: 1,584 of the 1,808 customers in the activity mart match (**87.6%**).
The remaining 224 can never be confirmed on-site, so they must read as
`unknown`, never as `false`.

---

## 2. New model — `int_rep_customer_presence`

Grain: one row per rep × customer × visit.

Pipeline, in order — each step exists because of a measured failure mode:

1. **Split GPS fixes per device.** Reps carry a median of 3 devices (max 5).
   Sorting all their fixes into one timeline makes the rep teleport: 10.7% of
   consecutive hops imply >80mph, and **97% of those are a device change**.
   Track each device separately and the problem disappears.
2. **Drop impossible hops** within a device track (>80 mph implied).
3. **Exclude the office.** The company address (37.6449309, -122.1362259,
   marked OFF001 in Annie's process) is in the address file and will otherwise
   be every rep's most-visited "customer". Rep 025 spent 236 minutes there on
   2026-08-11.
4. **Match each fix to the nearest customer within 100m.**
5. **Group consecutive fixes into visits**, ending a visit on a 20-minute gap.
   Do NOT use first-to-last across the day: min→max lumped two separate stops
   plus lunch into one 187-minute "visit" during prototyping.
6. **Drop visits under ~3 minutes** — driving past is not a visit.
7. **Merge overlapping visits across devices.** Step 1 stops the teleporting
   but then logs the same visit once per device; DAI003 appeared twice on
   2026-08-10.

Columns: `sales_code`, `customer_key`, `activity_date`, `visit_seq`,
`arrived_at`, `departed_at`, `on_site_minutes`, `closest_metres`, `fix_count`,
`is_ambiguous`.

### Ambiguity is real and must be published, not hidden

**21.2% of customers have another customer within 100m** (596 of 2,810); 10.3%
have one within 25m, which is inside GPS error — "nearest" there is a coin
flip, not a measurement. Tie-break in the order Annie's process uses:

1. which customer the rep had open in the app around that time
2. nearest, but only when it is a clear win
3. otherwise `is_ambiguous = true`

Scenario "visit only" has no app signal to tie-break with, so those fall
through to nearest-or-ambiguous. Worth knowing before treating that count as
exact.

---

## 3. Changed model — `mart_rep_customer_activity`

**Grain changes** to rep × customer × day × **scenario**. A customer worked
both on-site and remotely gets two rows instead of one misleading label.

This matters: on 2026-08-10 rep 025 built three baskets in-store (BIG008,
DAI003, LEE042 — 71/47/79 events) and submitted all three at 22:42 that
evening. The collapsed version read "on-site, order M000182028" and implied he
sent it there. He did not. Split, it reads as three `on-site` rows with no
order and three `visited, keyed elsewhere` rows carrying the orders.

**Becomes a full outer join** of activity and presence, so `visit only, no app`
gets a row.

New columns: `scenario`, `on_site_minutes`, `sessions`, `is_ambiguous`.
Existing columns keep their meaning; `keying_minutes` and the device splits are
now per scenario rather than per day.

---

## 4. Changed model — `mart_rep_customer_activity_events`

Add `was_on_site` per event, so a replay shows exactly when the rep walked in
and out.

---

## 5. New vars

```yaml
presence_geofence_metres: 100      # matches Annie's process
presence_visit_gap_minutes: 20     # gap that ends a visit
presence_min_dwell_minutes: 3      # below this it is driving past
presence_max_mph: 80               # above this the hop is bad data
office_latitude: 37.6449309
office_longitude: -122.1362259
office_radius_metres: 150
```

---

## Cost — measured, not guessed

415,853 GPS fixes × 2,810 stores = 1.16bn pairs.

| Approach | Time |
|---|---|
| Naive cross join + haversine | 27s |
| Bounding-box prefilter first | **7.8s** |

Counting the fixes alone takes 15s, so the join costs less than reading the
data. The stores broadcast at ~100KB, so there is no shuffle. Cost is not a
reason to hesitate.

---

## One bug to fix regardless

**Date windows must both be local.** During prototyping, filtering GPS on the
UTC date while activity used the local date put the two halves of a rep's day
in different 24-hour windows — they could never overlap, so `on-site` was
unreachable and every visit appeared on the wrong day. For a GMT-8 rep the
windows are 8 hours apart.

---

## Open questions before building

1. **Does Annie's process already output a visit table we can join to?** If so,
   join it rather than re-implementing the geofence — two implementations of
   the same rule will drift and produce two different visit counts.
2. **Are the thresholds above hers?** 100m is; the gap, dwell and speed limits
   are mine and should be reconciled.
3. **Which side owns the scenario label** when a customer is both on-site and
   remote in one day — currently split into two rows, which loses nothing but
   changes the grain.
4. **The 224 customers with no address** — can they be geocoded, or do they
   stay permanently `unknown`?
