#!/usr/bin/env bash
# one-click-installer/lib/native/07-monitoring-exporters.sh <envcode>
# Stand up Prometheus exporters for the NATIVE (host-installed) services that k3s can't see:
# PostgreSQL and Kafka. ClickHouse needs no exporter (its native install already serves Prometheus
# metrics — see one-click-installer/lib/native/02-install-clickhouse.sh / the prometheus-config overlay patch).
#
#   - postgres_exporter (prometheus-community): read-only `postgres_exporter` role (pg_monitor,
#     no superuser) against native ccedb on :5432, exposes :9187/metrics.
#   - kafka_exporter (danielqsj): consumer-group lag / topic-partition metrics against the native,
#     unauthenticated Kafka broker on localhost:9092, exposes :9308/metrics.
#
# Both run as `docker run --network host` (not k3s pods — they need to reach native localhost
# services, matching how ClickHouse/Postgres/Kafka themselves are host-resident). --restart
# unless-stopped survives reboots. --log-opt max-size=10m/max-file=3 (30MB cap) — there's no
# /etc/docker/daemon.json default, so an unbounded json-file driver is the alternative. Idempotent:
# re-running reuses the existing Infisical-stored password rather than rotating it, and replaces
# the containers in place (docker log-opts can only be set at container creation, not changed live).
#
# RUN:  sudo -A bash one-click-installer/lib/infisical-run.sh <envcode> bash one-click-installer/lib/native/07-monitoring-exporters.sh <envcode>
set -euo pipefail

ENVCODE="${1:?usage: 07-monitoring-exporters.sh <envcode>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../infisical-secret-helpers.sh
. "$REPO/one-click-installer/lib/infisical-secret-helpers.sh"

PSQL="sudo -u postgres psql -p 5432 -d ${POSTGRES_DB:-ccedb} -v ON_ERROR_STOP=1"

log(){ echo "[monitoring-exporters $ENVCODE $(date -u +%H:%M:%S)] $*"; }
# Poll a metrics endpoint for a pattern instead of a fixed sleep (container replace can take a
# few seconds longer than expected, e.g. the old container's port not yet released).
wait_for_metric(){ # url pattern max_tries
  local url="$1" pattern="$2" tries="${3:-10}"
  for _ in $(seq 1 "$tries"); do
    curl -sf -m 5 "$url" 2>/dev/null | grep -q "$pattern" && return 0
    sleep 2
  done
  return 1
}

# ============================================================ postgres_exporter
log "postgres_exporter: resolve credential"
infisical_resolve_project "$ENVCODE"
infisical_login

PGEXP_PW=$(infisical_get_or_generate /postgres POSTGRES_EXPORTER_PASSWORD "$PROJECT_ID" "$INFISICAL_ENV_SLUG")
log "  password ready (reused existing, or generated + stored in Infisical /postgres)"

log "postgres_exporter: create/update monitoring role (pg_monitor, no superuser)"
$PSQL <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgres_exporter') THEN
    CREATE ROLE postgres_exporter WITH LOGIN PASSWORD '${PGEXP_PW}';
  ELSE
    ALTER ROLE postgres_exporter WITH LOGIN PASSWORD '${PGEXP_PW}';
  END IF;
END
\$\$;
GRANT pg_monitor TO postgres_exporter;
SQL

log "postgres_exporter: (re)deploy container"
docker rm -f postgres-exporter >/dev/null 2>&1 || true
docker run -d --name postgres-exporter --restart unless-stopped --network host \
  --log-opt max-size=10m --log-opt max-file=3 \
  -e DATA_SOURCE_NAME="postgresql://postgres_exporter:${PGEXP_PW}@localhost:5432/${POSTGRES_DB:-ccedb}?sslmode=disable" \
  quay.io/prometheuscommunity/postgres-exporter:latest >/dev/null
wait_for_metric http://localhost:9187/metrics '^pg_up 1$' \
  && log "  OK: pg_up=1" || { log "  !! postgres_exporter not reporting pg_up=1"; exit 1; }

# ============================================================ kafka_exporter
log "kafka_exporter: (re)deploy container (native broker, unauthenticated, localhost:9092)"
docker rm -f kafka-exporter >/dev/null 2>&1 || true
docker run -d --name kafka-exporter --restart unless-stopped --network host \
  --log-opt max-size=10m --log-opt max-file=3 \
  danielqsj/kafka-exporter --kafka.server=localhost:9092 >/dev/null
# kafka_exporter's initial broker-metadata handshake has been observed taking ~40s on the reference VM and well over 90s on a fresh cloud VM
# (each collection round also trips over the Kafka Connect consumer group it cannot decode, which slows the first scrape) —
# so give it a generous budget, and do NOT let a MONITORING sidecar abort provisioning an entire environment: warn and carry on.
# (A 90s budget made the one-click installer die here on a fresh AWS VM although the exporter went healthy moments later.)
wait_for_metric http://localhost:9308/metrics '^kafka_brokers ' 90 \
  && log "  OK: kafka_brokers metric present" \
  || log "  WARNING: kafka_exporter not yet reporting kafka_brokers — continuing (monitoring only). Check: docker logs kafka-exporter; curl -s localhost:9308/metrics | grep ^kafka_brokers"

log "DONE. Next: apply the prometheus-config ConfigMap (one-click-installer/lib/native/05-k8s-deploy.sh, or extract+apply"
log "      just that ConfigMap) and run one-click-installer/lib/grafana-redeploy.sh $ENVCODE to wire scrape targets + dashboards."
