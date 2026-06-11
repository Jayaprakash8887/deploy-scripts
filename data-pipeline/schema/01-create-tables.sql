-- CCE Analytics ClickHouse Schema — Base Tables
-- ReplacingMergeTree(_version, _is_deleted), ClickHouse 23.2+.
--
-- These tables are populated by the ClickHouse Kafka-engine consumer MVs (schema/02), which
-- parse the Debezium JSON change events from Kafka. CDC-metadata columns:
--   - _version     Debezium source.lsn (monotonic) — ReplacingMergeTree dedup version
--   - _is_deleted  1 when op='d' (PostgreSQL DELETE) — set by the consumer MV
--   - clean_deleted_rows = 'Always' physically removes deleted rows during background merges
--
-- Execution order:
--   1. Run this script:                     schema/01-create-tables.sql
--   2. Kafka-engine queues + consumer MVs:  schema/02-kafka-ingestion.sql
--   3. Register the Debezium connector:     ./scripts/register-connectors.sh (initial snapshot)
--   4. Aggregation MVs:                      schema/03-create-materialized-views.sql
--   5. Indexes:                              schema/04-create-indexes.sql
--   6. Dictionaries:                         schema/05-create-dictionary.sql
--   7. Current-state rollups:                schema/06-current-state-rollups.sql

CREATE DATABASE IF NOT EXISTS cce_analytics;

USE cce_analytics;

-- ============================================================
-- COLLECTOR SERVICE: Event Ingestion
-- ============================================================

-- Immutable audit trail of all inbound CloudEvents received by the collector.
-- Status: RECEIVED → ACCEPTED | REJECTED | DUPLICATE
CREATE TABLE IF NOT EXISTS inbound_event_logs
(
    id                   UUID,
    cloudevents_id       String,
    source               String,
    correlation_id       String,
    raw_payload          String,              -- JSONB: original CloudEvent body, unchanged
    status               String,              -- RECEIVED | ACCEPTED | REJECTED | DUPLICATE
    rejection_reason     String,
    error_details        String,
    received_at          DateTime64(6),
    updated_at           DateTime64(6),

    -- Debezium CDC metadata (set by the schema/02 consumer MV)
    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0,

    -- MATERIALIZED: zero-cost extraction from raw_payload JSONB at insert time
    subject              String    MATERIALIZED JSONExtractString(raw_payload, 'subject'),
    event_type           String    MATERIALIZED JSONExtractString(raw_payload, 'type'),
    facility_id          String    MATERIALIZED JSONExtractString(raw_payload, 'facilityid'),
    event_time           Nullable(DateTime64(3))
                                   MATERIALIZED toDateTime64OrNull(
                                       JSONExtractString(raw_payload, 'time'), 3),
    resource_type        String    MATERIALIZED JSONExtractString(
                                       JSONExtractRaw(raw_payload, 'data'), 'resourceType'),
    practitioner_ref     String    MATERIALIZED JSONExtractString(
                                       JSONExtractRaw(raw_payload, 'data'), 'practitionerRef'),
    practitioner_display String    MATERIALIZED JSONExtractString(
                                       JSONExtractRaw(raw_payload, 'data'), 'practitionerDisplay'),

    -- ALIAS: patient_id resolves to subject without extra storage
    patient_id           String    ALIAS subject
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
PARTITION BY toYYYYMM(received_at)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always';


-- ============================================================
-- COMPLIANCE SERVICE: Protocol & Step Management
-- ============================================================

-- FHIR PlanDefinition templates defining protocol structure and triggers.
-- Status: ACTIVE | RETIRED
CREATE TABLE IF NOT EXISTS protocol_definitions
(
    id           UUID,
    name         String,
    url          String,
    version      String,
    status       String,    -- ACTIVE | RETIRED
    definition   String,    -- JSONB: full FHIR PlanDefinition resource

    created_at   DateTime64(6),
    updated_at   DateTime64(6),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always';


-- Patient enrollments in a protocol. One row per patient × protocol.
-- Status: ACTIVE | COMPLETED | WITHDRAWN | EXPIRED
CREATE TABLE IF NOT EXISTS protocol_instances
(
    id                     UUID,
    patient_id             String,
    protocol_definition_id UUID,
    protocol_canonical     String,    -- denormalized: url|version for join-free queries
    status                 String,    -- ACTIVE | COMPLETED | WITHDRAWN | EXPIRED
    enrolled_at            DateTime64(6),
    updated_at             DateTime64(6),
    expires_at             Nullable(DateTime64(6)),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
PARTITION BY toYYYYMM(enrolled_at)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always';


-- Individual action step occurrences within a protocol enrollment.
-- State machine: PENDING → DUE → OVERDUE → MISSED | COMPLETED | SKIPPED
CREATE TABLE IF NOT EXISTS step_instances
(
    id                   UUID,
    protocol_instance_id UUID,
    action_id            UUID,        -- FK → action_definitions.id
    state                String,      -- PENDING | DUE | OVERDUE | MISSED | COMPLETED | SKIPPED
    completion_status    String,      -- EARLY | ON_TIME | LATE  (set when state = COMPLETED)
    repeat_index         Int32,       -- for recurring actions; 0 = first occurrence
    required_behavior    String,      -- FHIR timing: MUST | SHOULD | MAY
    due_date             Nullable(DateTime64(6)),
    overdue_date         Nullable(DateTime64(6)),
    missed_date          Nullable(DateTime64(6)),
    created_at           DateTime64(6),
    updated_at           DateTime64(6),
    completed_at         Nullable(DateTime64(6)),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
PARTITION BY toYYYYMM(created_at)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always';


-- Compliance gaps recorded when steps become overdue or missed.
-- Types: OVERDUE | MISSED | ORDER_VIOLATION
CREATE TABLE IF NOT EXISTS deviations
(
    id                   UUID,
    protocol_instance_id UUID,
    step_instance_id     UUID,
    deviation_type       String,    -- OVERDUE | MISSED | ORDER_VIOLATION
    detected_at          DateTime64(6),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
PARTITION BY toYYYYMM(detected_at)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always';


-- Idempotency log for inbound CloudEvents processed by the compliance service.
-- Processing status: MATCHED | ZERO_MATCH | DUPLICATE
CREATE TABLE IF NOT EXISTS compliance_event_logs
(
    id                UUID,
    cloudevents_id    String,
    source            String,
    processing_status String,    -- MATCHED | ZERO_MATCH | DUPLICATE
    received_at       DateTime64(6),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
PARTITION BY toYYYYMM(received_at)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always';


-- FHIR ActivityDefinition resources defining intelligence actions.
-- Kind: CommunicationRequest | Task | ServiceRequest
CREATE TABLE IF NOT EXISTS action_definitions
(
    id          UUID,
    name        String,
    url         String,
    version     String,
    kind        String,    -- CommunicationRequest | Task | ServiceRequest
    status      String,    -- ACTIVE | RETIRED
    definition  String,    -- JSONB: full FHIR ActivityDefinition resource

    created_at  DateTime64(6),
    updated_at  DateTime64(6),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always';


-- Self-contained intelligence action execution records. No FK constraints by design
-- (fat-event: all routing context is embedded). Populated when compliance service fires actions.
CREATE TABLE IF NOT EXISTS intelligence_event_logs
(
    id                       UUID,
    subject                  String,    -- patient UPID (denormalized)
    protocol_instance_id     UUID,
    protocol_canonical       String,
    action_type              String,    -- CommunicationRequest | Task | ServiceRequest
    intelligence_destination String,
    step_state               String,
    step_instance_id         UUID,
    action_definition_id     UUID,
    trigger_reason           String,
    severity                 String,    -- LOW | MEDIUM | HIGH | CRITICAL
    -- event_payload (JSONB routing blob) excluded from the mirror — unused by analytics.
    created_at               DateTime64(6),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
PARTITION BY toYYYYMM(created_at)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always';


-- ============================================================
-- INTELLIGENCE SERVICE: Delivery Tracking
-- ============================================================

-- Webhook delivery lifecycle per intelligence_event × destination_adaptor_mapping pair.
-- Status: PENDING | EXECUTING | DELIVERED | FAILED | CANCELLED
CREATE TABLE IF NOT EXISTS intelligence_deliveries
(
    id                             UUID,
    intelligence_event_id          UUID,
    action_definition_id           UUID,
    destination_adaptor_mapping_id Nullable(UUID),
    action_type                    String,     -- CommunicationRequest | Task | ServiceRequest
    status                         String,     -- PENDING | EXECUTING | DELIVERED | FAILED | CANCELLED
    subject                        String,     -- patient UPID (denormalized)
    protocol_canonical             String,
    action_id                      String,     -- PlanDefinition action ID (e.g., anc-visit-2)
    severity                       String,     -- LOW | MEDIUM | HIGH | CRITICAL
    destination                    String,
    adaptor_name                   String,     -- denormalized from receiver_adaptor at dispatch
    endpoint_url                   String,     -- denormalized from receiver_adaptor at dispatch
    -- fhir_payload (JSONB resource sent) excluded from the mirror — unused by analytics.
    delivery_result                String,     -- JSONB: {httpStatus, responseBody, attempts[]} (kept: feeds MATERIALIZED cols)
    latency_ms                     Int64,
    attempt_count                  Int32,
    created_at                     DateTime64(6),
    updated_at                     DateTime64(6),
    delivered_at                   Nullable(DateTime64(6)),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0,

    -- MATERIALIZED: extracted from delivery_result JSONB at insert time
    http_status_code     Nullable(Int32) MATERIALIZED
                             nullIf(JSONExtractInt(delivery_result, 'httpStatus'), 0),
    error_message        String MATERIALIZED
                             JSONExtractString(delivery_result, 'responseBody')
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
PARTITION BY toYYYYMM(created_at)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always';



