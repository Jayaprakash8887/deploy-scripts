-- CCE Analytics ClickHouse Schema — Static Reference Tables
-- Run: clickhouse-client --database cce_analytics < schema/08-reference-tables.sql
--
-- WHY THIS EXISTS
-- Analytics indicators that compare actual activity against a known baseline require a
-- reference list that cannot be derived from event data alone:
--
--   1. Active Facility Rate  — numerator: facilities that transmitted HIE data in period
--                              denominator: total facilities IN SCOPE (agreed facility list)
--                              Without a reference list the denominator is only "facilities
--                              seen in event data", which excludes silent/inactive ones.
--
--   2. e-Buzima Adoption     — actual patients / expected patients per facility per day
--                              "Expected" is a validated figure set by the programme, not
--                              derivable from HIE events. It must be stored explicitly.
--
-- MANAGEMENT
--   Manually managed — no CDC or Kafka ingestion. Programme staff execute SQL directly.
--
-- NOTE ON DUPLICATES
--   ClickHouse has NO unique constraint enforcement — ORDER BY is a sort key only.
--   ReplacingMergeTree(updated_at) handles this: if the same facility_id is inserted
--   twice, ClickHouse deduplicates during background merges (keeping the row with the
--   highest updated_at). Until the merge runs, both rows exist — queries use FINAL to
--   see the deduplicated view. For a tiny reference table this is immediate in practice.
--
-- SEEDED FACILITIES (real facility IDs from production event data):
--   Outpatient Clinic  — facility_id: '44c3efb0-2583-4c80-a79e-1f756a03c0a1'  (source: openmrs / e-Buzima)
--   NCD Upazila        — facility_id: '1302'                                   (source: spice)
--
-- ADD a facility:
--   INSERT INTO cce_analytics.facility_reference (facility_id, facility_name, expected_patients_per_day)
--   VALUES ('44c3efb0-2583-4c80-a79e-1f756a03c0a1', 'Outpatient Clinic', 20);
--
-- UPDATE expected volume (insert a new row — ReplacingMergeTree keeps the latest):
--   INSERT INTO cce_analytics.facility_reference (facility_id, facility_name, expected_patients_per_day, updated_at)
--   VALUES ('44c3efb0-2583-4c80-a79e-1f756a03c0a1', 'Outpatient Clinic', 25, now64(3));
--
-- REMOVE a facility (drops from all MV calculations on next refresh):
--   DELETE FROM cce_analytics.facility_reference WHERE facility_id = '1302';
--
-- VERIFY current state (FINAL forces dedup of any unmerged parts):
--   SELECT * FROM cce_analytics.facility_reference FINAL ORDER BY facility_name;
--
-- Prerequisites: schema/01 (cce_analytics database must exist). No other dependencies.
-- Apply BEFORE schema/07 so that the refreshable MVs can reference this table on first run.

USE cce_analytics;

-- ============================================================
-- Facility Reference  (agreed facility list + adoption baseline)
-- ============================================================
-- One row per facility. Managed manually by programme staff.
--
-- Columns:
--   facility_id               — matches the facility_id used in inbound_event_logs and
--                               compliance_event_logs (HIE-assigned identifier)
--   facility_name             — human-readable name for display
--   expected_patients_per_day — validated baseline for e-Buzima adoption calculation
--                               Set to 0 for admin facilities not expected to submit patients

CREATE TABLE IF NOT EXISTS facility_reference
(
    facility_id               String,
    facility_name             String,
    expected_patients_per_day UInt32        DEFAULT 0,
    updated_at                DateTime64(3) DEFAULT now64(3)
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (facility_id);
-- ReplacingMergeTree(updated_at): if the same facility_id is inserted more than once,
-- background merges keep only the row with the highest updated_at. Prevents duplicate
-- data from accumulating if staff re-insert an existing facility. Always query with FINAL.

-- ============================================================
-- Example: seed known facilities
-- ============================================================
-- Run manually via kubectl exec or clickhouse-client on each environment.
-- Do NOT execute as part of this schema file — facility data is environment-specific.
--
-- kubectl exec -it <clickhouse-pod> -n <namespace> -- \
--   clickhouse-client --user cce_pipeline --password <password> --database cce_analytics
--
-- INSERT INTO facility_reference (facility_id, facility_name, expected_patients_per_day) VALUES
--     ('44c3efb0-2583-4c80-a79e-1f756a03c0a1', 'Outpatient Clinic', 20),  -- source: openmrs / e-Buzima
--     ('1302',                                  'NCD Upazila',        10); -- source: spice
