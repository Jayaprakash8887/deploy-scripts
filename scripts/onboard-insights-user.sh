#!/usr/bin/env bash
#
# Onboard one or more users into the cce-insights-ui Keycloak client.
# Creates the user (if missing) in Keycloak and triggers Keycloak's
# "execute actions email" — the user receives an email with a link to
# set their password; that link is effectively their first sign-in.
#
# Requires: curl, jq
#
# Auth: reads KEYCLOAK_ADMIN_USERNAME / KEYCLOAK_ADMIN_PASSWORD (and
# optionally KEYCLOAK_ADMIN_CLIENT_ID) from the environment, or from an
# env file (--env-file, default /opt/deployment/.env) — the same variable
# names cce-gateway-service already uses, so no new secrets are needed.
#
# Usage:
#   onboard-insights-user.sh --email a@b.com --first-name Ada --last-name Lovelace
#   onboard-insights-user.sh --csv users.csv          # header: email,first_name,last_name[,username]
#
# Common flags:
#   --env-file <path>       file to source admin creds from (default: /opt/deployment/.env)
#   --keycloak-url <url>    default: https://cceuat.moh.gov.rw/auth
#   --admin-realm <realm>   realm the admin user authenticates against (default: master)
#   --target-realm <realm>  realm users are created in (default: cce)
#   --client-id <id>        client used for the redirect after set-password (default: cce-insights-ui)
#   --redirect-uri <url>    default: https://cceuat.moh.gov.rw/insights/
#   --lifespan <seconds>    how long the email link stays valid (default: 259200 = 72h)
#   --role-client-id <id>   client that owns the authorization role to grant (default: gateway-service)
#   --role-name <name>      client role to grant, required by gateway-service's api_permissions
#                           table for /v1/insights/** GETs (default: INSIGHTS_READ) — without this,
#                           the user authenticates fine but gets 403 from the gateway on every call.
#                           Pass an empty string (--role-name "") to skip role assignment.
#   --dry-run               print what would happen, make no changes
#   -y, --yes               skip the confirmation prompt
#
set -euo pipefail

KEYCLOAK_URL_DEFAULT="https://cceuat.moh.gov.rw/auth"
ADMIN_REALM_DEFAULT="master"
TARGET_REALM_DEFAULT="cce"
CLIENT_ID_DEFAULT="cce-insights-ui"
REDIRECT_URI_DEFAULT="https://cceuat.moh.gov.rw/insights/"
LIFESPAN_DEFAULT=259200
ENV_FILE_DEFAULT="/opt/deployment/.env"
ADMIN_CLIENT_ID_DEFAULT="admin-cli"
ROLE_CLIENT_ID_DEFAULT="gateway-service"
ROLE_NAME_DEFAULT="INSIGHTS_READ"

env_file="$ENV_FILE_DEFAULT"
keycloak_url="$KEYCLOAK_URL_DEFAULT"
admin_realm="$ADMIN_REALM_DEFAULT"
target_realm="$TARGET_REALM_DEFAULT"
client_id="$CLIENT_ID_DEFAULT"
redirect_uri="$REDIRECT_URI_DEFAULT"
lifespan="$LIFESPAN_DEFAULT"
role_client_id="$ROLE_CLIENT_ID_DEFAULT"
role_name="$ROLE_NAME_DEFAULT"
dry_run=false
assume_yes=false
csv_file=""
email=""
first_name=""
last_name=""
username=""

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) env_file="$2"; shift 2 ;;
    --keycloak-url) keycloak_url="$2"; shift 2 ;;
    --admin-realm) admin_realm="$2"; shift 2 ;;
    --target-realm) target_realm="$2"; shift 2 ;;
    --client-id) client_id="$2"; shift 2 ;;
    --redirect-uri) redirect_uri="$2"; shift 2 ;;
    --lifespan) lifespan="$2"; shift 2 ;;
    --role-client-id) role_client_id="$2"; shift 2 ;;
    --role-name) role_name="$2"; shift 2 ;;
    --csv) csv_file="$2"; shift 2 ;;
    --email) email="$2"; shift 2 ;;
    --first-name) first_name="$2"; shift 2 ;;
    --last-name) last_name="$2"; shift 2 ;;
    --username) username="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -y|--yes) assume_yes=true; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

if [[ -z "$csv_file" && ( -z "$email" || -z "$first_name" || -z "$last_name" ) ]]; then
  echo "Provide either --csv <file> or --email/--first-name/--last-name" >&2
  usage 1
fi

if [[ -f "$env_file" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$env_file"; set +a
fi

: "${KEYCLOAK_ADMIN_USERNAME:?KEYCLOAK_ADMIN_USERNAME not set (export it or provide via --env-file)}"
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD not set (export it or provide via --env-file)}"
admin_client_id="${KEYCLOAK_ADMIN_CLIENT_ID:-$ADMIN_CLIENT_ID_DEFAULT}"

get_admin_token() {
  curl -sf -X POST "${keycloak_url}/realms/${admin_realm}/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=password" \
    -d "client_id=${admin_client_id}" \
    -d "username=${KEYCLOAK_ADMIN_USERNAME}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
  | jq -r '.access_token'
}

echo "Authenticating to Keycloak (${keycloak_url}, realm=${admin_realm})..."
token="$(get_admin_token)" || { echo "Failed to obtain admin token — check KEYCLOAK_ADMIN_USERNAME/PASSWORD/CLIENT_ID" >&2; exit 1; }
[[ -n "$token" && "$token" != "null" ]] || { echo "Failed to obtain admin token — check KEYCLOAK_ADMIN_USERNAME/PASSWORD/CLIENT_ID" >&2; exit 1; }

echo "Checking SMTP is configured on realm '${target_realm}'..."
smtp_host="$(curl -sf -H "Authorization: Bearer ${token}" \
  "${keycloak_url}/admin/realms/${target_realm}" | jq -r '.smtpServer.host // empty')"
if [[ -z "$smtp_host" ]]; then
  echo "ERROR: realm '${target_realm}' has no SMTP server configured — Keycloak cannot send sign-in emails." >&2
  echo "Configure Email settings under Realm Settings > Email in the Keycloak admin console first." >&2
  exit 1
fi
echo "SMTP OK (host=${smtp_host})"

# Resolve the authorization role to grant, once, up front — gateway-service denies with 403
# (even with a valid, correctly-audienced token) unless the user holds this client role, per its
# api_permissions table (role name == permission_name, matched via resource_access.<client>.roles).
role_client_uuid=""
role_repr=""
if [[ -n "$role_name" ]]; then
  echo "Resolving role '${role_name}' on client '${role_client_id}'..."
  role_client_uuid="$(curl -sf -H "Authorization: Bearer ${token}" \
    -G "${keycloak_url}/admin/realms/${target_realm}/clients" --data-urlencode "clientId=${role_client_id}" \
    | jq -r '.[0].id // empty')"
  [[ -n "$role_client_uuid" ]] || { echo "ERROR: client '${role_client_id}' not found in realm '${target_realm}'" >&2; exit 1; }
  role_repr="$(curl -sf -H "Authorization: Bearer ${token}" \
    "${keycloak_url}/admin/realms/${target_realm}/clients/${role_client_uuid}/roles/${role_name}")"
  [[ -n "$role_repr" && "$role_repr" != "null" ]] || { echo "ERROR: role '${role_name}' not found on client '${role_client_id}'" >&2; exit 1; }
  echo "Role OK (${role_client_id}/${role_name})"
fi

onboard_one() {
  local u_email="$1" u_first="$2" u_last="$3" u_username="${4:-$1}"

  echo
  echo "== ${u_email} =="

  local existing_id
  existing_id="$(curl -sf -H "Authorization: Bearer ${token}" \
    -G "${keycloak_url}/admin/realms/${target_realm}/users" \
    --data-urlencode "email=${u_email}" --data-urlencode "exact=true" \
    | jq -r '.[0].id // empty')"

  local role_note=""
  [[ -n "$role_name" ]] && role_note=", grant role ${role_client_id}/${role_name}"

  if $dry_run; then
    if [[ -n "$existing_id" ]]; then
      echo "[dry-run] user already exists (id=${existing_id})${role_note} — would send sign-in email"
    else
      echo "[dry-run] would create user username=${u_username} firstName=${u_first} lastName=${u_last}${role_note}, then send sign-in email"
    fi
    return
  fi

  local user_id="$existing_id"
  if [[ -z "$user_id" ]]; then
    local body location
    body="$(jq -n --arg u "$u_username" --arg e "$u_email" --arg f "$u_first" --arg l "$u_last" \
      '{username:$u, email:$e, firstName:$f, lastName:$l, enabled:true, emailVerified:false, requiredActions:["UPDATE_PASSWORD"]}')"
    location="$(curl -sf -D - -o /dev/null -X POST "${keycloak_url}/admin/realms/${target_realm}/users" \
      -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' \
      -d "$body" | grep -i '^location:' | tr -d '\r' | awk '{print $2}')"
    [[ -n "$location" ]] || { echo "Failed to create user ${u_email}" >&2; return 1; }
    user_id="${location##*/}"
    echo "Created user id=${user_id}"
  else
    echo "User already exists, id=${user_id} — reusing"
  fi

  if [[ -n "$role_name" ]]; then
    curl -sf -X POST \
      "${keycloak_url}/admin/realms/${target_realm}/users/${user_id}/role-mappings/clients/${role_client_uuid}" \
      -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' \
      -d "[${role_repr}]" \
      && echo "Granted role ${role_client_id}/${role_name}"
  fi

  curl -sf -X PUT \
    "${keycloak_url}/admin/realms/${target_realm}/users/${user_id}/execute-actions-email" \
    --url-query "client_id=${client_id}" \
    --url-query "redirect_uri=${redirect_uri}" \
    --url-query "lifespan=${lifespan}" \
    -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' \
    -d '["UPDATE_PASSWORD"]' \
    && echo "Sign-in email sent to ${u_email}"
}

# Build the list of users up front so we can show one confirmation prompt.
users=()
if [[ -n "$csv_file" ]]; then
  [[ -f "$csv_file" ]] || { echo "CSV file not found: $csv_file" >&2; exit 1; }
  while IFS=',' read -r c_email c_first c_last c_username; do
    [[ "$c_email" == "email" ]] && continue   # skip header
    [[ -z "$c_email" ]] && continue           # skip blank lines
    users+=("${c_email// /}|${c_first}|${c_last}|${c_username:-$c_email}")
  done < "$csv_file"
else
  users+=("${email}|${first_name}|${last_name}|${username:-$email}")
fi

echo
echo "About to onboard ${#users[@]} user(s) into realm '${target_realm}' and send them a sign-in email:"
for u in "${users[@]}"; do IFS='|' read -r e f l un <<<"$u"; echo "  - $e ($f $l)"; done

if ! $dry_run && ! $assume_yes; then
  read -r -p "Proceed and send real emails? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

for u in "${users[@]}"; do
  IFS='|' read -r e f l un <<<"$u"
  onboard_one "$e" "$f" "$l" "$un"
done
