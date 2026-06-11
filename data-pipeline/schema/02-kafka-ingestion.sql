-- CCE Analytics ClickHouse Schema — Kafka Ingestion (Debezium → ClickHouse)
-- Run: clickhouse-client --database cce_analytics < schema/02-kafka-ingestion.sql
--
-- For each source table there are TWO objects:
--   1. <table>_queue   — Kafka-engine table reading the Debezium topic (cce.public.<src>) as
--                        ONE raw JSON String per message (kafka_format = 'JSONAsString').
--   2. <table>_mv      — consumer MV that parses the Debezium envelope and inserts the flat
--                        row into the base table (schema/01).
--
-- Envelope parsing:
--   op       = JSONExtractString(raw,'op')        -- c=create, u=update, r=snapshot read, d=delete, t=truncate
--   payload  = after (normal) or before (delete)  -- the row image
--   _version = source.lsn                          -- monotonic WAL position → ReplacingMergeTree version
--   _is_deleted = (op = 'd')                       -- soft-delete flag
--   WHERE op IN ('c','u','r','d')                  -- skip truncate / non-row messages
--
-- TEMPORAL TYPES — VERIFY against ccedb:
--   This assumes timestamp columns are PostgreSQL `timestamptz` → Debezium emits ISO-8601
--   strings → parseDateTime64BestEffort*. If a column is plain `timestamp` (no tz), Debezium
--   (time.precision.mode=adaptive_time_microseconds) emits micros-since-epoch as an integer;
--   for those, replace the parse with: fromUnixTimestamp64Micro(JSONExtractInt(payload,'col')).
--
-- BROKER: the Kafka tables use ENGINE = Kafka(cce_kafka), a named collection defined ONCE in
-- infra/clickhouse/named-collections.xml whose broker is read from the KAFKA_BOOTSTRAP_SERVERS
-- env var (set on the ClickHouse container, sourced from .env — the same var the Debezium worker
-- uses). To change the broker, edit .env only; nothing here needs to change.
-- (Only the per-table topic / consumer group / format live in the DDL below.)

USE cce_analytics;

-- ============================================================
-- inbound_event_logs
-- ============================================================
CREATE TABLE IF NOT EXISTS inbound_event_logs_queue (raw String)
ENGINE = Kafka(cce_kafka) SETTINGS
    kafka_topic_list  = 'cce.public.inbound_event_log',
    kafka_group_name  = 'clickhouse_inbound_event_logs',
    kafka_format      = 'JSONAsString',
    kafka_num_consumers = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS inbound_event_logs_mv TO inbound_event_logs AS
WITH
    JSONExtractString(raw, 'op') AS op,
    if(op = 'd', JSONExtractRaw(raw, 'before'), JSONExtractRaw(raw, 'after')) AS payload
SELECT
    toUUID(JSONExtractString(payload, 'id'))                                       AS id,
    JSONExtractString(payload, 'cloudevents_id')                                  AS cloudevents_id,
    JSONExtractString(payload, 'source')                                          AS source,
    JSONExtractString(payload, 'correlation_id')                                  AS correlation_id,
    JSONExtractString(payload, 'raw_payload')                                     AS raw_payload,
    JSONExtractString(payload, 'status')                                          AS status,
    JSONExtractString(payload, 'rejection_reason')                                AS rejection_reason,
    JSONExtractString(payload, 'error_details')                                   AS error_details,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'received_at'), 6) AS received_at,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'updated_at'), 6)  AS updated_at,
    JSONExtractUInt(JSONExtractRaw(raw, 'source'), 'lsn')                         AS _version,
    if(op = 'd', 1, 0)                                                            AS _is_deleted
FROM inbound_event_logs_queue
WHERE op IN ('c', 'u', 'r', 'd');

-- ============================================================
-- protocol_definitions
-- ============================================================
CREATE TABLE IF NOT EXISTS protocol_definitions_queue (raw String)
ENGINE = Kafka(cce_kafka) SETTINGS
    kafka_topic_list  = 'cce.public.protocol_definition',
    kafka_group_name  = 'clickhouse_protocol_definitions',
    kafka_format      = 'JSONAsString',
    kafka_num_consumers = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS protocol_definitions_mv TO protocol_definitions AS
WITH
    JSONExtractString(raw, 'op') AS op,
    if(op = 'd', JSONExtractRaw(raw, 'before'), JSONExtractRaw(raw, 'after')) AS payload
SELECT
    toUUID(JSONExtractString(payload, 'id'))                                       AS id,
    JSONExtractString(payload, 'name')                                            AS name,
    JSONExtractString(payload, 'url')                                             AS url,
    JSONExtractString(payload, 'version')                                         AS version,
    JSONExtractString(payload, 'status')                                          AS status,
    JSONExtractString(payload, 'definition')                                      AS definition,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'created_at'), 6)  AS created_at,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'updated_at'), 6)  AS updated_at,
    JSONExtractUInt(JSONExtractRaw(raw, 'source'), 'lsn')                         AS _version,
    if(op = 'd', 1, 0)                                                            AS _is_deleted
FROM protocol_definitions_queue
WHERE op IN ('c', 'u', 'r', 'd');

-- ============================================================
-- protocol_instances
-- ============================================================
CREATE TABLE IF NOT EXISTS protocol_instances_queue (raw String)
ENGINE = Kafka(cce_kafka) SETTINGS
    kafka_topic_list  = 'cce.public.protocol_instance',
    kafka_group_name  = 'clickhouse_protocol_instances',
    kafka_format      = 'JSONAsString',
    kafka_num_consumers = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS protocol_instances_mv TO protocol_instances AS
WITH
    JSONExtractString(raw, 'op') AS op,
    if(op = 'd', JSONExtractRaw(raw, 'before'), JSONExtractRaw(raw, 'after')) AS payload
SELECT
    toUUID(JSONExtractString(payload, 'id'))                                       AS id,
    JSONExtractString(payload, 'patient_id')                                      AS patient_id,
    toUUID(JSONExtractString(payload, 'protocol_definition_id'))                  AS protocol_definition_id,
    JSONExtractString(payload, 'protocol_canonical')                              AS protocol_canonical,
    JSONExtractString(payload, 'status')                                          AS status,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'enrolled_at'), 6) AS enrolled_at,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'updated_at'), 6)  AS updated_at,
    parseDateTime64BestEffortOrNull(JSONExtractString(payload, 'expires_at'), 6)  AS expires_at,
    JSONExtractUInt(JSONExtractRaw(raw, 'source'), 'lsn')                         AS _version,
    if(op = 'd', 1, 0)                                                            AS _is_deleted
FROM protocol_instances_queue
WHERE op IN ('c', 'u', 'r', 'd');

-- ============================================================
-- step_instances
-- ============================================================
CREATE TABLE IF NOT EXISTS step_instances_queue (raw String)
ENGINE = Kafka(cce_kafka) SETTINGS
    kafka_topic_list  = 'cce.public.step_instance',
    kafka_group_name  = 'clickhouse_step_instances',
    kafka_format      = 'JSONAsString',
    kafka_num_consumers = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS step_instances_mv TO step_instances AS
WITH
    JSONExtractString(raw, 'op') AS op,
    if(op = 'd', JSONExtractRaw(raw, 'before'), JSONExtractRaw(raw, 'after')) AS payload
SELECT
    toUUID(JSONExtractString(payload, 'id'))                                       AS id,
    toUUID(JSONExtractString(payload, 'protocol_instance_id'))                    AS protocol_instance_id,
    toUUID(JSONExtractString(payload, 'action_id'))                              AS action_id,
    JSONExtractString(payload, 'state')                                           AS state,
    JSONExtractString(payload, 'completion_status')                              AS completion_status,
    JSONExtractInt(payload, 'repeat_index')                                       AS repeat_index,
    JSONExtractString(payload, 'required_behavior')                              AS required_behavior,
    parseDateTime64BestEffortOrNull(JSONExtractString(payload, 'due_date'), 6)    AS due_date,
    parseDateTime64BestEffortOrNull(JSONExtractString(payload, 'overdue_date'), 6) AS overdue_date,
    parseDateTime64BestEffortOrNull(JSONExtractString(payload, 'missed_date'), 6) AS missed_date,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'created_at'), 6)  AS created_at,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'updated_at'), 6)  AS updated_at,
    parseDateTime64BestEffortOrNull(JSONExtractString(payload, 'completed_at'), 6) AS completed_at,
    JSONExtractUInt(JSONExtractRaw(raw, 'source'), 'lsn')                         AS _version,
    if(op = 'd', 1, 0)                                                            AS _is_deleted
FROM step_instances_queue
WHERE op IN ('c', 'u', 'r', 'd');

-- ============================================================
-- deviations
-- ============================================================
CREATE TABLE IF NOT EXISTS deviations_queue (raw String)
ENGINE = Kafka(cce_kafka) SETTINGS
    kafka_topic_list  = 'cce.public.deviation',
    kafka_group_name  = 'clickhouse_deviations',
    kafka_format      = 'JSONAsString',
    kafka_num_consumers = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS deviations_mv TO deviations AS
WITH
    JSONExtractString(raw, 'op') AS op,
    if(op = 'd', JSONExtractRaw(raw, 'before'), JSONExtractRaw(raw, 'after')) AS payload
SELECT
    toUUID(JSONExtractString(payload, 'id'))                                       AS id,
    toUUID(JSONExtractString(payload, 'protocol_instance_id'))                    AS protocol_instance_id,
    toUUID(JSONExtractString(payload, 'step_instance_id'))                       AS step_instance_id,
    JSONExtractString(payload, 'deviation_type')                                 AS deviation_type,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'detected_at'), 6) AS detected_at,
    JSONExtractUInt(JSONExtractRaw(raw, 'source'), 'lsn')                         AS _version,
    if(op = 'd', 1, 0)                                                            AS _is_deleted
FROM deviations_queue
WHERE op IN ('c', 'u', 'r', 'd');

-- ============================================================
-- compliance_event_logs
-- ============================================================
CREATE TABLE IF NOT EXISTS compliance_event_logs_queue (raw String)
ENGINE = Kafka(cce_kafka) SETTINGS
    kafka_topic_list  = 'cce.public.compliance_event_log',
    kafka_group_name  = 'clickhouse_compliance_event_logs',
    kafka_format      = 'JSONAsString',
    kafka_num_consumers = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS compliance_event_logs_mv TO compliance_event_logs AS
WITH
    JSONExtractString(raw, 'op') AS op,
    if(op = 'd', JSONExtractRaw(raw, 'before'), JSONExtractRaw(raw, 'after')) AS payload
SELECT
    toUUID(JSONExtractString(payload, 'id'))                                       AS id,
    JSONExtractString(payload, 'cloudevents_id')                                  AS cloudevents_id,
    JSONExtractString(payload, 'source')                                          AS source,
    JSONExtractString(payload, 'processing_status')                              AS processing_status,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'received_at'), 6) AS received_at,
    JSONExtractUInt(JSONExtractRaw(raw, 'source'), 'lsn')                         AS _version,
    if(op = 'd', 1, 0)                                                            AS _is_deleted
FROM compliance_event_logs_queue
WHERE op IN ('c', 'u', 'r', 'd');

-- ============================================================
-- action_definitions
-- ============================================================
CREATE TABLE IF NOT EXISTS action_definitions_queue (raw String)
ENGINE = Kafka(cce_kafka) SETTINGS
    kafka_topic_list  = 'cce.public.action_definition',
    kafka_group_name  = 'clickhouse_action_definitions',
    kafka_format      = 'JSONAsString',
    kafka_num_consumers = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS action_definitions_mv TO action_definitions AS
WITH
    JSONExtractString(raw, 'op') AS op,
    if(op = 'd', JSONExtractRaw(raw, 'before'), JSONExtractRaw(raw, 'after')) AS payload
SELECT
    toUUID(JSONExtractString(payload, 'id'))                                       AS id,
    JSONExtractString(payload, 'name')                                            AS name,
    JSONExtractString(payload, 'url')                                             AS url,
    JSONExtractString(payload, 'version')                                         AS version,
    JSONExtractString(payload, 'kind')                                            AS kind,
    JSONExtractString(payload, 'status')                                          AS status,
    JSONExtractString(payload, 'definition')                                      AS definition,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'created_at'), 6)  AS created_at,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'updated_at'), 6)  AS updated_at,
    JSONExtractUInt(JSONExtractRaw(raw, 'source'), 'lsn')                         AS _version,
    if(op = 'd', 1, 0)                                                            AS _is_deleted
FROM action_definitions_queue
WHERE op IN ('c', 'u', 'r', 'd');

-- ============================================================
-- intelligence_event_logs  (event_payload excluded at the connector)
-- ============================================================
CREATE TABLE IF NOT EXISTS intelligence_event_logs_queue (raw String)
ENGINE = Kafka(cce_kafka) SETTINGS
    kafka_topic_list  = 'cce.public.intelligence_event_log',
    kafka_group_name  = 'clickhouse_intelligence_event_logs',
    kafka_format      = 'JSONAsString',
    kafka_num_consumers = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS intelligence_event_logs_mv TO intelligence_event_logs AS
WITH
    JSONExtractString(raw, 'op') AS op,
    if(op = 'd', JSONExtractRaw(raw, 'before'), JSONExtractRaw(raw, 'after')) AS payload
SELECT
    toUUID(JSONExtractString(payload, 'id'))                                       AS id,
    JSONExtractString(payload, 'subject')                                         AS subject,
    toUUID(JSONExtractString(payload, 'protocol_instance_id'))                    AS protocol_instance_id,
    JSONExtractString(payload, 'protocol_canonical')                              AS protocol_canonical,
    JSONExtractString(payload, 'action_type')                                     AS action_type,
    JSONExtractString(payload, 'intelligence_destination')                       AS intelligence_destination,
    JSONExtractString(payload, 'step_state')                                      AS step_state,
    toUUID(JSONExtractString(payload, 'step_instance_id'))                       AS step_instance_id,
    toUUID(JSONExtractString(payload, 'action_definition_id'))                   AS action_definition_id,
    JSONExtractString(payload, 'trigger_reason')                                 AS trigger_reason,
    JSONExtractString(payload, 'severity')                                        AS severity,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'created_at'), 6)  AS created_at,
    JSONExtractUInt(JSONExtractRaw(raw, 'source'), 'lsn')                         AS _version,
    if(op = 'd', 1, 0)                                                            AS _is_deleted
FROM intelligence_event_logs_queue
WHERE op IN ('c', 'u', 'r', 'd');

-- ============================================================
-- intelligence_deliveries  (fhir_payload excluded at the connector;
-- http_status_code/error_message are MATERIALIZED from delivery_result, not inserted here)
-- ============================================================
CREATE TABLE IF NOT EXISTS intelligence_deliveries_queue (raw String)
ENGINE = Kafka(cce_kafka) SETTINGS
    kafka_topic_list  = 'cce.public.intelligence_delivery',
    kafka_group_name  = 'clickhouse_intelligence_deliveries',
    kafka_format      = 'JSONAsString',
    kafka_num_consumers = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS intelligence_deliveries_mv TO intelligence_deliveries AS
WITH
    JSONExtractString(raw, 'op') AS op,
    if(op = 'd', JSONExtractRaw(raw, 'before'), JSONExtractRaw(raw, 'after')) AS payload
SELECT
    toUUID(JSONExtractString(payload, 'id'))                                       AS id,
    toUUID(JSONExtractString(payload, 'intelligence_event_id'))                  AS intelligence_event_id,
    toUUID(JSONExtractString(payload, 'action_definition_id'))                   AS action_definition_id,
    toUUIDOrNull(JSONExtractString(payload, 'destination_adaptor_mapping_id'))    AS destination_adaptor_mapping_id,
    JSONExtractString(payload, 'action_type')                                     AS action_type,
    JSONExtractString(payload, 'status')                                          AS status,
    JSONExtractString(payload, 'subject')                                         AS subject,
    JSONExtractString(payload, 'protocol_canonical')                              AS protocol_canonical,
    JSONExtractString(payload, 'action_id')                                       AS action_id,
    JSONExtractString(payload, 'severity')                                        AS severity,
    JSONExtractString(payload, 'destination')                                     AS destination,
    JSONExtractString(payload, 'adaptor_name')                                    AS adaptor_name,
    JSONExtractString(payload, 'endpoint_url')                                    AS endpoint_url,
    JSONExtractString(payload, 'delivery_result')                                 AS delivery_result,
    JSONExtractInt(payload, 'latency_ms')                                         AS latency_ms,
    JSONExtractInt(payload, 'attempt_count')                                      AS attempt_count,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'created_at'), 6)  AS created_at,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'updated_at'), 6)  AS updated_at,
    parseDateTime64BestEffortOrNull(JSONExtractString(payload, 'delivered_at'), 6) AS delivered_at,
    JSONExtractUInt(JSONExtractRaw(raw, 'source'), 'lsn')                         AS _version,
    if(op = 'd', 1, 0)                                                            AS _is_deleted
FROM intelligence_deliveries_queue
WHERE op IN ('c', 'u', 'r', 'd');
