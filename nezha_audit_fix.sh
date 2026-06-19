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
用法: sudo bash nezha_audit_fix.sh [选项]

选项:
  --check-only           仅自查，默认行为
  --upgrade-dashboard    自查后升级哪吒面板
  --upgrade-agent        自查后升级哪吒探针
  --upgrade-all          自查后升级哪吒面板和探针
  --cn                   优先使用官方国内镜像/源
  --no-poc               跳过本机路径穿越 PoC 检查
  --help                 显示帮助
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
    *) echo "未知选项: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

log() { printf "%b\n" "$*" | tee -a "$REPORT"; }
info() { log "${BLUE}[信息]${PLAIN} $*"; }
ok() { log "${GREEN}[正常]${PLAIN} $*"; }
warn() { log "${YELLOW}[警告]${PLAIN} $*"; }
bad() { log "${RED}[高危]${PLAIN} $*"; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    bad "请使用 root 运行，例如: sudo bash nezha_audit_fix.sh"
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

find_agent_service_files() {
  find /etc/systemd/system /etc/init.d -maxdepth 2 -type f 2>/dev/null |
    grep -Ei 'nezha.*agent|agent.*nezha' |
    awk '!seen[$0]++'
}

has_v2_agent_config() {
  local cfgs f
  cfgs="$(find_agent_configs || true)"
  [ -n "$cfgs" ] || return 1
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if grep -Eq '^[[:space:]]*server:[[:space:]]*.+' "$f" &&
       grep -Eq '^[[:space:]]*client_secret:[[:space:]]*.+' "$f"; then
      return 0
    fi
  done <<EOF
$cfgs
EOF
  return 1
}

has_agent_env_inputs() {
  [ -n "${NZ_SERVER:-}" ] && [ -n "${NZ_CLIENT_SECRET:-}" ]
}

looks_like_v0_agent_service() {
  local services
  services="$(find_agent_service_files || true)"
  [ -n "$services" ] || return 1
  printf '%s\n' "$services" | xargs -r grep -E 'nezha-agent .*(-s|--server).*(-p|--password|--secret)' >/dev/null 2>&1
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
  info "正在检查版本..."
  local dash_ver latest_dash agent_ver latest_agent
  dash_ver="$(detect_dashboard_version)"
  latest_dash="$(get_latest_release nezhahq/nezha || true)"
  agent_ver="$(detect_agent_version)"
  latest_agent="$(get_latest_release nezhahq/agent || true)"

  if [ -n "$dash_ver" ]; then
    if version_ge "$dash_ver" "$MIN_SAFE_DASHBOARD"; then
      ok "面板当前版本 $dash_ver，不低于安全修复版本 $MIN_SAFE_DASHBOARD。"
    else
      bad "面板当前版本 $dash_ver 低于安全修复版本 $MIN_SAFE_DASHBOARD，可能受已公开漏洞影响。"
    fi
  else
    warn "未能识别面板版本；Docker latest 标签或非标准安装常见此情况。"
  fi

  [ -n "$latest_dash" ] && info "面板官方最新版本: $latest_dash"
  [ -n "$agent_ver" ] && info "探针当前版本: $agent_ver" || warn "未能识别探针版本。"
  [ -n "$latest_agent" ] && info "探针官方最新版本: $latest_agent"
}

audit_poc() {
  [ "$CHECK_POC" -eq 1 ] || { warn "已跳过 PoC 检查。"; return; }
  local cfg port body code tmp
  cfg="$(find_dashboard_config || true)"
  [ -n "$cfg" ] || { warn "未找到面板 config.yaml，已跳过本机 PoC 检查。"; return; }
  port="$(extract_yaml_value listen_port "$cfg" || true)"
  [ -n "$port" ] || port=8008
  tmp="$(mktemp)"
  info "正在通过 127.0.0.1:$port 检查本机路径穿越漏洞..."

  for path in "/dashboard../data/config.yaml" "/dashboard%2e%2e/data/config.yaml" "/dashboard..%2fdata/config.yaml"; do
    code="$(curl -sS --path-as-is --max-time 8 -o "$tmp" -w '%{http_code}' "http://127.0.0.1:${port}${path}" 2>/dev/null || true)"
    body="$(head -c 4096 "$tmp" 2>/dev/null || true)"
    if [ "$code" = "200" ] && printf '%s' "$body" | grep -Eq 'jwt_secret_key|agent_secret_key|oauth2|listen_port'; then
      bad "存在漏洞: GET $path 返回了疑似 config.yaml 内容。"
      rm -f "$tmp"
      return
    fi
  done

  code="$(curl -sS --path-as-is --max-time 8 -o "$tmp" -w '%{http_code}' "http://127.0.0.1:${port}/dashboard../data/sqlite.db" 2>/dev/null || true)"
  if [ "$code" = "200" ] && head -c 16 "$tmp" 2>/dev/null | grep -q 'SQLite format'; then
    bad "存在漏洞: /dashboard../data/sqlite.db 返回了 SQLite 数据库。"
  else
    ok "本机 PoC 未读到 config.yaml 或 sqlite.db。"
  fi
  rm -f "$tmp"
}

audit_logs() {
  info "正在扫描常见 Web 日志中的漏洞利用痕迹..."
  local files hits
  files="$(find /var/log /opt/nezha -maxdepth 4 -type f 2>/dev/null |
    grep -Ei 'access|nginx|caddy|apache|http|nezha|dashboard' || true)"
  [ -n "$files" ] || { warn "未发现常见 Web 日志文件。"; return; }
  hits="$(printf '%s\n' "$files" | xargs -r grep -IEn 'dashboard(\.\.|%2e%2e|%252e|\.%2e|%2f)|data/(config\.ya?ml|sqlite\.db)' 2>/dev/null | head -n 30 || true)"
  if [ -n "$hits" ]; then
    bad "日志中发现疑似漏洞扫描或利用痕迹:"
    printf '%s\n' "$hits" | tee -a "$REPORT"
  else
    ok "常见日志中未发现已知 PoC 特征。"
  fi
}

audit_processes() {
  info "正在检查可疑进程..."
  local hits
  hits="$(ps axww -o pid,user,etime,command 2>/dev/null |
    grep -Eiv 'grep|nezha_audit_fix' |
    grep -Ei 'xmrig|kinsing|kdevtmpfsi|crypto|miner|/tmp/|/dev/shm/|base64|curl .*\|.*sh|wget .*\|.*sh|nc -e|bash -i' |
    head -n 30 || true)"
  if [ -n "$hits" ]; then
    warn "发现可疑进程，请人工确认:"
    printf '%s\n' "$hits" | tee -a "$REPORT"
  else
    ok "未发现常见挖矿、反弹 shell 或临时目录运行进程特征。"
  fi
}

audit_persistence() {
  info "正在检查 cron 和 systemd 持久化项..."
  local tmp hits
  tmp="$(mktemp)"
  {
    crontab -l 2>/dev/null || true
    find /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/systemd/system -maxdepth 2 -type f -print -exec sed -n '1,120p' {} \; 2>/dev/null || true
  } > "$tmp"
  hits="$(grep -Ein 'curl|wget|/tmp/|/dev/shm|base64|bash -c|sh -c|nc |socat|python -c|perl -e|xmrig|miner' "$tmp" | head -n 40 || true)"
  if [ -n "$hits" ]; then
    warn "发现可疑定时任务或服务片段，请人工确认:"
    printf '%s\n' "$hits" | tee -a "$REPORT"
  else
    ok "未发现常见可疑持久化特征。"
  fi
  rm -f "$tmp"
}

audit_nezha_data() {
  info "正在检查哪吒配置和数据库风险项..."
  local cfg db dump agent_cfgs
  cfg="$(find_dashboard_config || true)"
  if [ -n "$cfg" ]; then
    ok "面板配置文件: $cfg"
    stat "$cfg" 2>/dev/null | tee -a "$REPORT" >/dev/null || true
    db="$(dirname "$cfg")/sqlite.db"
    if [ -f "$db" ]; then
      info "面板数据库: $db"
      if have sqlite3; then
        dump="$(sqlite3 "$db" .dump 2>/dev/null | grep -Ei 'curl|wget|bash|sh -c|powershell|base64|/tmp/|/dev/shm|nc |socat|xmrig|miner' | head -n 40 || true)"
        [ -n "$dump" ] && { warn "数据库中发现疑似命令执行/下载器片段:"; printf '%s\n' "$dump" | tee -a "$REPORT"; } || ok "数据库 dump 中未发现常见恶意命令特征。"
      else
        warn "未安装 sqlite3，已跳过面板数据库内容扫描。"
      fi
    fi
  else
    warn "未找到面板配置文件。"
  fi

  agent_cfgs="$(find_agent_configs || true)"
  if [ -n "$agent_cfgs" ]; then
    printf '%s\n' "$agent_cfgs" | while read -r f; do
      [ -f "$f" ] || continue
      if grep -Eq '^[[:space:]]*disable_command_execute:[[:space:]]*false' "$f"; then
        warn "探针已开启远程命令执行: $f。如果面板曾被接管，请检查面板任务记录，并考虑临时关闭。"
      else
        ok "探针未显式开启远程命令执行，或已禁用: $f"
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
  info "正在调用官方脚本升级面板..."
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
  info "正在准备升级探针..."
  local script="/tmp/nezha-agent.sh"
  if ! has_v2_agent_config && ! has_agent_env_inputs; then
    warn "未发现新版探针 config.yml，也未提供 NZ_SERVER/NZ_CLIENT_SECRET，已跳过探针升级。"
    if looks_like_v0_agent_service; then
      warn "当前机器看起来是旧版 0.x 探针参数式安装。0.x 到 2.x 不能在缺少新版连接密钥时无损自动迁移。"
    fi
    warn "请到新版面板的服务器页面复制探针安装命令，或按下面格式提供参数后重试:"
    warn "curl -fsSL https://raw.githubusercontent.com/njzhx/nezhafix/main/nezha_audit_fix.sh | sudo env NZ_SERVER=你的面板通信地址:端口 NZ_CLIENT_SECRET=连接密钥 NZ_TLS=false bash -s -- --upgrade-agent"
    return 0
  fi
  info "正在调用官方脚本升级探针..."
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
  info "报告文件: $REPORT"
  info "开始哪吒面板/探针自查。"
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

  info "自查完成。报告已保存到 $REPORT"
  warn "如果 config.yaml/sqlite.db 曾暴露，或日志中存在漏洞利用痕迹，请在升级后轮换密码、JWT 密钥、API Token、OAuth/通知/DDNS 密钥和探针连接密钥。"
}

main "$@"
