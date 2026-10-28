# CCE one-click installer

Stands up a complete **Care Coordination Engine (CCE)** environment on **one dedicated Ubuntu machine**, reproducing the
reference production topology. It is generic: nothing in here is specific to one country or implementation — everything
deployment-specific comes from a config file and the Infisical secrets store.

```bash
cp one-click-installer/config/example.env one-click-installer/config/<envcode>.env   # edit it
sudo bash one-click-installer/install.sh --config one-click-installer/config/<envcode>.env
```

`--yes` skips the two confirmation prompts (for automation).

## What you get

| Layer | What | Notes |
|---|---|---|
| Data (native, systemd) | PostgreSQL 16 · Kafka 3.7 (KRaft) · ClickHouse 26.5 · Kafka Connect + Debezium | versions pinned in the config |
| Platform | k3s (+ Traefik ingress) | version pinned in the config |
| CCE services | namespace `cce-<envcode>`: gateway, collector, protocol, matcher, step-sla, intelligence, insights service + UI, OpenHIM emitter, Keycloak, Grafana, Prometheus, kafka-ui | sizing / HPAs / rate limits cloned from the reference production overlay |
| Pipeline | Postgres → Debezium → Kafka → ClickHouse analytics schema | CDC connector points at `localhost` (survives IP changes) |
| Seed | Keycloak realm `cce`, gateway `api_permissions`, optional clinical protocol | |
| Secrets | Infisical project `cce-<envcode>` | generated unless supplied; the host IP is **detected**, never stored |
| Hardening | docker-published ports blocked from the public NIC; UFW default-deny when `IS_CLOUD_DEPLOYMENT=false`; `pg_stat_statements` | |

## Requirements

* Fresh **Ubuntu 26.04** (systemd, apt), root/sudo. 8 vCPU / 24 GiB RAM / 40 GB free disk recommended — the production-sized
  overlay requests ≈7.6 vCPU and the data services share the node.
* Outbound HTTPS to: get.k3s.io, github.com, ghcr.io, quay.io, Docker Hub, registry.k8s.io, archive.apache.org,
  packages.clickhouse.com, artifacts-cli.infisical.com, the Ubuntu mirror. `lib/prereqs.sh` checks all of them first.
* An Infisical instance — or let the installer run its own (`USE_LOCAL_INFISICAL=true`, the default).

Everything else (k3s, Infisical CLI, docker, ClickHouse, Kafka, …) is installed for you.

## Getting the code onto the machine

Copy the **whole `deploy-scripts` repository** (git clone or archive) — the installer uses `k8s/`, `data-pipeline/` and
`keycloak-themes/` from it. Do **not** copy local secret files along with it: any `*.env` other than `config/example.env`,
`data-pipeline/.env`, Infisical exports or `*.creds`. The repository location does not matter (it is not tied to a user or path).

## Configuration

Every key is documented in [`config/example.env`](config/example.env). The essentials:

| Key | Meaning |
|---|---|
| `ENVCODE` | short code → namespace `cce-<ENVCODE>` and Infisical project `cce-<ENVCODE>` |
| `IS_CLOUD_DEPLOYMENT` | `true` = behind a cloud security group (no host firewall); `false` = on-prem/direct → UFW is configured |
| `INGRESS_HOST` / `ACME_EMAIL` | DNS name + Let's Encrypt contact for TLS; empty = plain HTTP |
| `USE_LOCAL_INFISICAL` | run a self-contained Infisical on the machine, or use an existing one |
| `IMAGE_<SERVICE>` | per-service image **tag** or **`sha256:` digest**; `IMAGE_TAG_DEFAULT`, `IMAGE_REGISTRY` for all |
| `*_VERSION` | k3s, Infisical CLI, ClickHouse, Postgres, Kafka, Debezium |

The config holds **no secrets**. `config/*.env` is gitignored (only `example.env` is tracked). Credentials needed at runtime
(`INFISICAL_ADMIN_EMAIL/PASSWORD` for a remote Infisical, `PROTOCOL_AUTH`) are passed as environment variables.
Environment variables also override any config key: `sudo env IS_CLOUD_DEPLOYMENT=true bash install.sh --config …`.

## Phases

| # | Phase | Script |
|---|---|---|
| 1 | prerequisites: machine + outbound checks, k3s, Infisical CLI, docker | `lib/prereqs.sh` |
| 2 | Infisical project + machine identity (local instance if configured) | `lib/infisical-local.sh`, `lib/infisical-bootstrap.sh` |
| 3 | seed configuration into Infisical | `lib/infisical-seed.sh` |
| 4 | generate `k8s/overlays/<OVERLAY_NAME>` from the template, apply image versions | `lib/generate-overlay.sh`, `lib/apply-image-pins.sh` |
| 5 | pre-flight: every overlay variable has a value; dry render (nothing applied) | `lib/overlay-vars-check.sh`, `lib/dry-render.sh` |
| 6 | Postgres+Kafka → ClickHouse → Connect → exporters → k3s deploy → CDC pipeline → seed | `lib/native/install-all.sh` (01–07) |
| 7 | docker-port block always; UFW if not cloud | `lib/install-docker-fw.sh`, `lib/ufw-baseline.sh` |

**Re-running is safe and resumes.** An existing Infisical project, overlay, native install or connector is reused; a failure
in phase 6 can be fixed and the same command re-run.

## After installing

* Commit `k8s/overlays/<OVERLAY_NAME>/` — it is tracked, and records exactly which image versions are deployed.
* Fill in external-system settings left blank (OpenHIM host/credentials, facility filter) in Infisical, then
  `sudo bash one-click-installer/lib/redeploy.sh cce-<envcode>`.
* From **outside** the network: `nmap -Pn <public-ip>` — only 22/80/443 should be open.

### Day-2 operations

| Task | Command |
|---|---|
| New image or Infisical value → roll | `sudo bash lib/redeploy.sh cce-<env> [service…]` (`IMAGE_DIGEST=sha256:…` / `IMAGE_TAG=…` for one service) |
| Change pinned versions | edit `IMAGE_*` in the config, re-run `install.sh` (or `lib/apply-image-pins.sh <env>` + `lib/native/05-k8s-deploy.sh <env>`) |
| ClickHouse schema change | `sudo bash lib/redeploy-clickhouse.sh <env>` |
| Grafana dashboards | `sudo bash lib/grafana-redeploy.sh <env>` |
| Machine IP changed | `sudo bash tools/host-ip-check.sh <env>` lists anything still holding the old address |
| CDC connector re-registered | `bash tools/connector-repoint.sh <env>` (keeps it IP-free) |
| Compare with another environment | `sudo bash tools/env-fingerprint.sh <env> > a.fp` on each host, then `python3 tools/env-parity.py ref.fp a.fp` |

## Troubleshooting — problems this installer already handles

These were all hit on real fresh installs; the fixes are in the scripts. Listed so you recognise them if they reappear.

| Symptom | Cause | Handled by |
|---|---|---|
| a pinned version is silently ignored | Ubuntu 26.04's `sudo-rs` ignores `sudo -E` | `lib/sudo-compat.sh` — never `sudo -E` |
| `wget` exit 8 downloading Kafka | old releases leave downloads.apache.org | archive.apache.org first, SHA-512 verified |
| ClickHouse schema: *"Column(s) … of the AggregatingMergeTree table are neither part of the sorting key nor aggregate measures"* | ClickHouse ≥ 26.10 is stricter than the schema | pinned to the 26.5 series + `apt-mark hold` |
| deploy aborts: *"ipBlock.cidr: Invalid value: ${VM_HOST_CIDR}"* | base NetworkPolicy placeholder | substituted at render |
| keycloak stuck `ContainerCreating` (*hostPath type check failed*) | base manifest's theme path is one machine's checkout | path mapped to this repo at render |
| insights / emitter crash-loop: *"Failed to convert '' to long/int"* | overlay variable empty in Infisical | `overlay-vars-check.sh` fails at pre-flight, naming it |
| `psql: … Permission denied` on a repo file | Postgres can't read inside a 750 home dir | SQL streamed on stdin |
| `gpg: cannot open '/dev/tty'` on a re-run | keyring already exists | `--dearmor --yes` |
| exporter "not reporting" aborts install | slow first scrape on a fresh VM | longer wait; warning, not fatal |

## Notes

* **Known product-level item:** `k8s/base/services/openhim-emitter-adaptor.yaml` sets `EBUZIMA_CLIENT_ID=ebuzima` — the source
  system of the first implementation. Other implementations configure their own source systems in the emitter.
* This folder is a generic copy of the tooling first built for the Rwanda deployment (`rw/`, not in git). That deployment
  still runs from `rw/`; changes here do not affect it.
