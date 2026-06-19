#!/usr/bin/env bash
set -Eeuo pipefail

MIN_SAFE_DASHBOARD="2.0.13"
CHECK_POC=1
UPGRADE_DASHBOARD=0
UPGRADE_AGENT=0
CN="${CN:-}"
REPORT="/tmp/nezha_audit_$(date +%Y%m%d_%H%M%S).log"
NZ_BASE_PATH="${NZ_BASE_PATH:-/opt/nezha}"
NZ_DASHBOARD_PATH="${NZ_DASHBOARD_PATH:-$NZ_BASE_PATH/dashboard}"
NZ_AGENT_PATH="${NZ_AGENT_PATH:-$NZ_BASE_PATH/agent}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

usage() {
  cat <<'USAGE'
Usage: sudo bash nezha_audit_fix.sh [options]

Options:
  --check-only           Only audit, default
  --upgrade-dashboard    Upgrade Nezha Dashboard after audit
  --upgrade-agent        Upgrade Nezha Agent after audit
  --upgrade-all          Upgrade both Dashboard and Agent after audit
  --cn                   Prefer official China mirror/source
  --no-poc               Skip localhost path-traversal PoC checks
  --help                 Show this help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-only) UPGRADE_DASHBOARD=0; UPGRADE_AGENT=0 ;;
    --upgrade-dashboard) UPGRADE_DASHBOARD=1 ;;
    --upgrade-agent) UPGRADE_AGENT=1 ;;
    --upgrade-all) UPGRADE_DASHBOARD=1; UPGRADE_AGENT=1 ;;
    --cn) CN=true ;;
    --no-poc) CHECK_POC=0 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

log() { printf "%b\n" "$*" | tee -a "$REPORT"; }
info() { log "${BLUE}[INFO]${PLAIN} $*"; }
ok() { log "${GREEN}[OK]${PLAIN} $*"; }
warn() { log "${YELLOW}[WARN]${PLAIN} $*"; }
bad() { log "${RED}[HIGH]${PLAIN} $*"; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    bad "Please run as root, for example: sudo bash nezha_audit_fix.sh"
    exit 1
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

version_ge() {
  local a="${1#v}" b="${2#v}"
  [ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | head -n1)" = "$b" ]
}

extract_yaml_value() {
  local key="$1" file="$2"
  [ -f "$file" ] || return 1
  sed -n "s/^[[:space:]]*$key:[[:space:]]*['\"]*\\([^'\"#[:space:]]*\\).*/\\1/p" "$file" | head -n1
}

get_latest_release() {
  local repo="$1" api
  if [ -n "$CN" ]; then
    api="https://gitee.com/api/v5/repos/naibahq/${repo##*/}/releases/latest"
  else
    api="https://api.github.com/repos/$repo/releases/latest"
  fi
  curl -fsSL --max-time 12 "$api" 2>/dev/null |
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n1
}

find_dashboard_config() {
  for f in \
    "$NZ_DASHBOARD_PATH/data/config.yaml" \
    "$NZ_DASHBOARD_PATH/data/config.yml" \
    "/opt/nezha/dashboard/data/config.yaml" \
    "/etc/nezha/dashboard/config.yaml"; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  find /opt /etc -maxdepth 5 -type f \( -name config.yaml -o -name config.yml \) 2>/dev/null |
    grep -E '/nezha/.*/data/config\.ya?ml$|/nezha.*/config\.ya?ml$' |
    head -n1 || true
}

find_agent_configs() {
  find "$NZ_AGENT_PATH" /opt/nezha /etc/nezha -maxdepth 4 -type f \( -name '*config*.yml' -o -name '*config*.yaml' \) 2>/dev/null |
    awk '!seen[$0]++'
}

detect_dashboard_version() {
  local ver=""
  if [ -x "$NZ_DASHBOARD_PATH/app" ]; then
    ver="$("$NZ_DASHBOARD_PATH/app" --version 2>/dev/null | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  fi
  if [ -z "$ver" ] && have docker; then
    ver="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null |
      grep -E '(^|/)nezha(:|$)|nezha-dashboard' |
      grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' |
      head -n1 || true)"
  fi
  echo "$ver"
}

detect_agent_version() {
  local bin="$NZ_AGENT_PATH/nezha-agent" ver=""
  [ -x "$bin" ] && ver="$("$bin" --version 2>/dev/null | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  echo "$ver"
}

audit_versions() {
  info "Checking versions..."
  local dash_ver latest_dash agent_ver latest_agent
  dash_ver="$(detect_dashboard_version)"
  latest_dash="$(get_latest_release nezhahq/nezha || true)"
  agent_ver="$(detect_agent_version)"
  latest_agent="$(get_latest_release nezhahq/agent || true)"

  if [ -n "$dash_ver" ]; then
    if version_ge "$dash_ver" "$MIN_SAFE_DASHBOARD"; then
      ok "Dashboard version $dash_ver is not below fixed version $MIN_SAFE_DASHBOARD."
    else
      bad "Dashboard version $dash_ver is below fixed version $MIN_SAFE_DASHBOARD. Public vulnerabilities may apply."
    fi
  else
    warn "Could not detect Dashboard version. This is common with Docker latest tags or custom installs."
  fi

  [ -n "$latest_dash" ] && info "Latest Dashboard release: $latest_dash"
  [ -n "$agent_ver" ] && info "Agent version: $agent_ver" || warn "Could not detect Agent version."
  [ -n "$latest_agent" ] && info "Latest Agent release: $latest_agent"
}

audit_poc() {
  [ "$CHECK_POC" -eq 1 ] || { warn "PoC check skipped."; return; }
  local cfg port body code tmp
  cfg="$(find_dashboard_config || true)"
  [ -n "$cfg" ] || { warn "Dashboard config.yaml was not found. Local PoC check skipped."; return; }
  port="$(extract_yaml_value listen_port "$cfg" || true)"
  [ -n "$port" ] || port=8008
  tmp="$(mktemp)"
  info "Checking localhost path traversal on 127.0.0.1:$port..."

  for path in "/dashboard../data/config.yaml" "/dashboard%2e%2e/data/config.yaml" "/dashboard..%2fdata/config.yaml"; do
    code="$(curl -sS --path-as-is --max-time 8 -o "$tmp" -w '%{http_code}' "http://127.0.0.1:${port}${path}" 2>/dev/null || true)"
    body="$(head -c 4096 "$tmp" 2>/dev/null || true)"
    if [ "$code" = "200" ] && printf '%s' "$body" | grep -Eq 'jwt_secret_key|agent_secret_key|oauth2|listen_port'; then
      bad "VULNERABLE: GET $path returned content that looks like config.yaml."
      rm -f "$tmp"
      return
    fi
  done

  code="$(curl -sS --path-as-is --max-time 8 -o "$tmp" -w '%{http_code}' "http://127.0.0.1:${port}/dashboard../data/sqlite.db" 2>/dev/null || true)"
  if [ "$code" = "200" ] && head -c 16 "$tmp" 2>/dev/null | grep -q 'SQLite format'; then
    bad "VULNERABLE: /dashboard../data/sqlite.db returned a SQLite database."
  else
    ok "Local PoC did not read config.yaml or sqlite.db."
  fi
  rm -f "$tmp"
}

audit_logs() {
  info "Scanning common web logs for exploit traces..."
  local files hits
  files="$(find /var/log /opt/nezha -maxdepth 4 -type f 2>/dev/null |
    grep -Ei 'access|nginx|caddy|apache|http|nezha|dashboard' || true)"
  [ -n "$files" ] || { warn "No common web log files found."; return; }
  hits="$(printf '%s\n' "$files" | xargs -r grep -IEn 'dashboard(\.\.|%2e%2e|%252e|\.%2e|%2f)|data/(config\.ya?ml|sqlite\.db)' 2>/dev/null | head -n 30 || true)"
  if [ -n "$hits" ]; then
    bad "Possible exploit scans or hits found in logs:"
    printf '%s\n' "$hits" | tee -a "$REPORT"
  else
    ok "No known PoC patterns found in common logs."
  fi
}

audit_processes() {
  info "Checking suspicious processes..."
  local hits
  hits="$(ps axww -o pid,user,etime,command 2>/dev/null |
    grep -Eiv 'grep|nezha_audit_fix' |
    grep -Ei 'xmrig|kinsing|kdevtmpfsi|crypto|miner|/tmp/|/dev/shm/|base64|curl .*\|.*sh|wget .*\|.*sh|nc -e|bash -i' |
    head -n 30 || true)"
  if [ -n "$hits" ]; then
    warn "Suspicious processes found. Review manually:"
    printf '%s\n' "$hits" | tee -a "$REPORT"
  else
    ok "No common miner, reverse shell, or temporary-directory process patterns found."
  fi
}

audit_persistence() {
  info "Checking cron and systemd persistence..."
  local tmp hits
  tmp="$(mktemp)"
  {
    crontab -l 2>/dev/null || true
    find /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/systemd/system -maxdepth 2 -type f -print -exec sed -n '1,120p' {} \; 2>/dev/null || true
  } > "$tmp"
  hits="$(grep -Ein 'curl|wget|/tmp/|/dev/shm|base64|bash -c|sh -c|nc |socat|python -c|perl -e|xmrig|miner' "$tmp" | head -n 40 || true)"
  if [ -n "$hits" ]; then
    warn "Suspicious cron or service snippets found. Review manually:"
    printf '%s\n' "$hits" | tee -a "$REPORT"
  else
    ok "No common suspicious persistence patterns found."
  fi
  rm -f "$tmp"
}

audit_nezha_data() {
  info "Checking Nezha config and database risk indicators..."
  local cfg db dump agent_cfgs
  cfg="$(find_dashboard_config || true)"
  if [ -n "$cfg" ]; then
    ok "Dashboard config file: $cfg"
    stat "$cfg" 2>/dev/null | tee -a "$REPORT" >/dev/null || true
    db="$(dirname "$cfg")/sqlite.db"
    if [ -f "$db" ]; then
      info "Dashboard database: $db"
      if have sqlite3; then
        dump="$(sqlite3 "$db" .dump 2>/dev/null | grep -Ei 'curl|wget|bash|sh -c|powershell|base64|/tmp/|/dev/shm|nc |socat|xmrig|miner' | head -n 40 || true)"
        [ -n "$dump" ] && { warn "Possible command/download payloads found in database:"; printf '%s\n' "$dump" | tee -a "$REPORT"; } || ok "No common malicious command patterns found in database dump."
      else
        warn "sqlite3 is not installed. Dashboard database content scan skipped."
      fi
    fi
  else
    warn "Dashboard config file was not found."
  fi

  agent_cfgs="$(find_agent_configs || true)"
  if [ -n "$agent_cfgs" ]; then
    printf '%s\n' "$agent_cfgs" | while read -r f; do
      [ -f "$f" ] || continue
      if grep -Eq '^[[:space:]]*disable_command_execute:[[:space:]]*false' "$f"; then
        warn "Agent remote command execution is enabled: $f. If Dashboard was compromised, review Dashboard tasks and consider disabling it temporarily."
      else
        ok "Agent remote command execution is not explicitly enabled or is disabled: $f"
      fi
    done
  fi
}

download_official_script() {
  local url="$1" out="$2"
  curl -fsSL --max-time 60 "$url" -o "$out"
  chmod +x "$out"
}

upgrade_dashboard() {
  info "Calling official script to upgrade Dashboard..."
  local script="/tmp/nezha.sh"
  if [ -n "$CN" ]; then
    download_official_script "https://gitee.com/naibahq/scripts/raw/main/install.sh" "$script"
    CN=true bash "$script" restart_and_update
  else
    download_official_script "https://raw.githubusercontent.com/nezhahq/scripts/main/install.sh" "$script"
    bash "$script" restart_and_update
  fi
}

upgrade_agent() {
  info "Calling official script to upgrade Agent..."
  local script="/tmp/nezha-agent.sh"
  if [ -n "$CN" ]; then
    download_official_script "https://gitee.com/naibahq/scripts/raw/main/agent/install.sh" "$script"
    CN=true bash "$script"
  else
    download_official_script "https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh" "$script"
    bash "$script"
  fi
}

main() {
  need_root
  touch "$REPORT"
  info "Report file: $REPORT"
  info "Starting Nezha Dashboard/Agent audit."
  audit_versions
  audit_poc
  audit_logs
  audit_processes
  audit_persistence
  audit_nezha_data

  if [ "$UPGRADE_DASHBOARD" -eq 1 ]; then
    upgrade_dashboard
  fi
  if [ "$UPGRADE_AGENT" -eq 1 ]; then
    upgrade_agent
  fi

  info "Audit completed. Report saved to $REPORT"
  warn "If config.yaml/sqlite.db was exposed or logs show exploit hits, rotate passwords, JWT secret, API tokens, OAuth/notification/DDNS secrets, and Agent connection secrets after upgrading."
}

main "$@"
