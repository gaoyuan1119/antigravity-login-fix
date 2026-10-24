#!/usr/bin/env bash
#
# Antigravity Login Doctor (macOS)
#
# Read-only diagnostic for the common "Google login succeeds but Antigravity
# stays on the login/onboarding screen" problem.
#
# This script does NOT:
#   - modify Clash / network / Antigravity settings
#   - kill processes
#   - read or print OAuth tokens
#   - require sudo
#
# Usage:
#   chmod +x antigravity-login-doctor.sh
#   ./antigravity-login-doctor.sh
#
# Optional:
#   MIXED_PORT=7897 ./antigravity-login-doctor.sh
#
# Exit code:
#   0 = no critical issue detected
#   1 = at least one critical issue detected
#
set -uo pipefail

APP="/Applications/Antigravity.app"
LS_BIN="$APP/Contents/Resources/bin/language_server"
LOG="$HOME/Library/Logs/Antigravity/language_server.log"
MIXED_PORT="${MIXED_PORT:-7897}"
FAILED=0

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'
  C_YEL=$'\033[33m'
  C_GRN=$'\033[32m'
  C_DIM=$'\033[2m'
else
  C_RESET=""
  C_BOLD=""
  C_RED=""
  C_YEL=""
  C_GRN=""
  C_DIM=""
fi

section() {
  printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_RESET"
}

ok() {
  printf '%s[OK]%s %s\n' "$C_GRN" "$C_RESET" "$1"
}

warn() {
  printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RESET" "$1"
}

fail() {
  printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$1"
  FAILED=1
}

info() {
  printf '     %s\n' "$1"
}

dim() {
  printf '%s%s%s\n' "$C_DIM" "$1" "$C_RESET"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

# Remove secrets that may appear in process args.
sanitize_args() {
  sed -E 's/(--csrf_token|--host_bridge_token)([= ])[^ ]+/\1\2<redacted>/g' |
    cut -c1-600
}

# Remove OAuth codes/tokens from log lines before printing.
sanitize_log() {
  sed -E 's/(code|state|access_token|refresh_token|id_token)=[^&[:space:]]+/\1=<redacted>/g' |
    cut -c1-260
}

# Last matching line from the recent log, sanitized.
last_match() {
  local pattern="$1"
  tail -n 5000 "$LOG" 2>/dev/null |
    grep -a "$pattern" 2>/dev/null |
    tail -n 1 |
    sanitize_log
}

# Count matching lines in the recent log.
count_match() {
  local pattern="$1"
  tail -n 5000 "$LOG" 2>/dev/null |
    grep -ac "$pattern" 2>/dev/null || true
}

# HTTP status, never fail the script.
http_code() {
  local url="$1"
  shift
  curl -sS -o /dev/null -m 10 -w '%{http_code}' "$@" "$url" 2>/dev/null || true
}

printf '%s\n' "Antigravity Login Doctor"
printf '%s\n' "read-only diagnostic; no configuration will be changed"
printf '%s\n' "time: $(date '+%Y-%m-%d %H:%M:%S %Z')"

# ---------------------------------------------------------------------------
section "System"
# ---------------------------------------------------------------------------
printf 'macOS: %s (%s)\n' "$(sw_vers -productVersion 2>/dev/null || echo unknown)" "$(uname -m 2>/dev/null || echo unknown)"
printf 'user:  %s\n' "${USER:-unknown}"

if [[ -d "$APP" ]]; then
  APP_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -n "$APP_VER" ]]; then
    ok "Antigravity $APP_VER at $APP"
    if [[ "$APP_VER" == "2.24.0" || "$APP_VER" == 2.24* ]]; then
      warn "2.24.0 has known login/connection issues in some environments; consider updating before deeper debugging."
    fi
  else
    warn "Antigravity exists but version could not be read."
  fi
else
  fail "Antigravity not found at $APP"
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  warn "This script is written for macOS; some checks will not work here."
fi

# ---------------------------------------------------------------------------
section "Processes"
# ---------------------------------------------------------------------------
APP_PIDS="$(pgrep -f "$APP/Contents/MacOS/Antigravity" 2>/dev/null || true)"
LS_PIDS="$(pgrep -f "$LS_BIN" 2>/dev/null || true)"

if [[ -z "$APP_PIDS" ]]; then
  warn "Antigravity main process is not running."
else
  ok "Antigravity main process: $(echo "$APP_PIDS" | tr '\n' ' ')"
  for pid in $APP_PIDS; do
    ARGS="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
    printf '     args: %s\n' "$(printf '%s' "$ARGS" | sanitize_args)"
    if printf '%s' "$ARGS" | grep -q -- '<-loopback>'; then
      warn "Found '<-loopback>' in launch args. It can force loopback through the proxy and break OAuth callbacks."
    else
      ok "No '<-loopback>' in this process's launch args."
    fi
  done
fi

if [[ -z "$LS_PIDS" ]]; then
  warn "language_server is not running."
else
  ok "language_server process: $(echo "$LS_PIDS" | tr '\n' ' ')"
  for pid in $LS_PIDS; do
    ARGS="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
    printf '     args: %s\n' "$(printf '%s' "$ARGS" | sanitize_args)"
    if ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -qx 'ELECTRON_RUN_AS_NODE=1'; then
      warn "ELECTRON_RUN_AS_NODE=1 is present in the language_server environment."
    fi
  done
fi

if [[ "${ELECTRON_RUN_AS_NODE:-}" == "1" ]]; then
  warn "Your current shell has ELECTRON_RUN_AS_NODE=1; launching Antigravity from this shell may exit immediately."
  info "Use: env -u ELECTRON_RUN_AS_NODE open -a $APP"
fi

# ---------------------------------------------------------------------------
section "Proxy / TUN"
# ---------------------------------------------------------------------------
PROXY_OUT="$(scutil --proxy 2>/dev/null || true)"
SYSTEM_PROXY=0
TUN_ROUTE=0
TUN_IFACE=0

if printf '%s\n' "$PROXY_OUT" | grep -q 'HTTPEnable : 1'; then
  SYSTEM_PROXY=1
  ok "macOS system proxy is enabled."
  info "$(printf '%s\n' "$PROXY_OUT" | grep -E 'HTTPProxy|HTTPPort|HTTPSProxy|HTTPSPort' | tr '\n' ' ')"
else
  warn "macOS system proxy is not enabled."
fi

if netstat -rn -f inet 2>/dev/null | grep -q '198\.18\.0\.1'; then
  TUN_ROUTE=1
fi
if ifconfig 2>/dev/null | grep -q 'inet 198\.18\.0\.1'; then
  TUN_IFACE=1
fi

if [[ "$TUN_ROUTE" -eq 1 && "$TUN_IFACE" -eq 1 ]]; then
  ok "Clash-style TUN looks active (utun with 198.18.0.1 and route present)."
elif [[ "$TUN_ROUTE" -eq 1 || "$TUN_IFACE" -eq 1 ]]; then
  warn "TUN is partially present (route or interface, not both). Check Clash Verge's TUN status."
else
  warn "No 198.18.0.1 TUN route/interface found."
fi

if nc -z 127.0.0.1 "$MIXED_PORT" >/dev/null 2>&1; then
  ok "Something is accepting connections on 127.0.0.1:$MIXED_PORT (expected Clash mixed port)."
elif curl -sS -o /dev/null -m 3 -x "http://127.0.0.1:$MIXED_PORT" https://www.google.com 2>/dev/null; then
  ok "The mixed port responds to a proxy request (127.0.0.1:$MIXED_PORT)."
else
  fail "Nothing is accepting connections on 127.0.0.1:$MIXED_PORT. Set MIXED_PORT if your Clash port is different."
fi

if [[ "$SYSTEM_PROXY" -eq 0 && "$TUN_ROUTE" -eq 0 ]]; then
  fail "Neither system proxy nor TUN is active. Apps that do not have an explicit proxy setting will go direct and fail."
fi

# ---------------------------------------------------------------------------
section "Connectivity"
# ---------------------------------------------------------------------------
GOOGLE_DIRECT="$(http_code 'https://www.google.com' --noproxy '*')"
OAUTH_DIRECT="$(http_code 'https://oauth2.googleapis.com/token' --noproxy '*')"
OAUTH_PROXY="$(http_code "https://oauth2.googleapis.com/token" -x "http://127.0.0.1:$MIXED_PORT")"
OAUTH_POST="$(http_code "https://oauth2.googleapis.com/token" \
  -x "http://127.0.0.1:$MIXED_PORT" \
  -X POST \
  -d 'grant_type=refresh_token&refresh_token=x&client_id=x')"

printf 'direct  google: %s\n' "${GOOGLE_DIRECT:-000}"
printf 'direct  oauth : %s\n' "${OAUTH_DIRECT:-000}"
printf 'proxy   oauth : %s\n' "${OAUTH_PROXY:-000}"
printf 'proxy   POST  : %s\n' "${OAUTH_POST:-000}"

if [[ "$GOOGLE_DIRECT" == "000" ]]; then
  if [[ "$TUN_ROUTE" -eq 1 ]]; then
    fail "TUN route exists but direct HTTPS to Google still fails. Check the selected node and Clash logs."
  elif [[ "$SYSTEM_PROXY" -eq 1 ]]; then
    warn "Direct curl ignores the macOS system proxy; this does not necessarily mean the App is broken."
  else
    fail "Direct HTTPS to Google fails and no global proxy is active."
  fi
else
  ok "Direct HTTPS to Google works (HTTP $GOOGLE_DIRECT)."
fi

if [[ "$OAUTH_PROXY" == "000" ]]; then
  fail "OAuth token endpoint is unreachable through the Clash mixed port."
elif [[ "$OAUTH_PROXY" == "404" || "$OAUTH_PROXY" == "400" || "$OAUTH_PROXY" == "401" ]]; then
  ok "OAuth token endpoint is reachable through the mixed port (HTTP $OAUTH_PROXY; 404 is normal for GET)."
else
  warn "OAuth token endpoint returned an unexpected status through the proxy: $OAUTH_PROXY"
fi

if [[ "$OAUTH_POST" == "000" ]]; then
  fail "POST to oauth2.googleapis.com/token failed through the proxy. This can block the code-to-token exchange."
elif [[ "$OAUTH_POST" == "400" || "$OAUTH_POST" == "401" ]]; then
  ok "POST to the token endpoint works through the proxy (HTTP $OAUTH_POST; dummy credentials are expected to fail)."
else
  warn "Unexpected POST status from the token endpoint: $OAUTH_POST"
fi

# ---------------------------------------------------------------------------
section "Language server log"
# ---------------------------------------------------------------------------
if [[ ! -f "$LOG" ]]; then
  warn "Log not found: $LOG"
else
  AUTH_OK="$(count_match 'Auth succeeded')"
  TOKEN_FAIL="$(count_match 'Failed to get OAuth token')"
  TOKEN_ERR="$(count_match 'oauth2.googleapis.com/token')"
  FLOW_FAIL="$(count_match 'OAuth2 flow failed')"
  STATE_FAIL="$(count_match 'state mismatch')"
  NO_CODE="$(count_match 'no authorization code received')"
  INELIGIBLE="$(count_match 'not eligible\|ineligible')"
  KEYCHAIN="$(count_match 'Failed to save token to keyring')"

  printf 'Auth succeeded              : %s\n' "${AUTH_OK:-0}"
  printf 'oauth2 token errors         : %s\n' "${TOKEN_ERR:-0}"
  printf 'Failed to get OAuth token   : %s\n' "${TOKEN_FAIL:-0}"
  printf 'OAuth2 flow failed          : %s\n' "${FLOW_FAIL:-0}"
  printf 'state mismatch              : %s\n' "${STATE_FAIL:-0}"
  printf 'no authorization code       : %s\n' "${NO_CODE:-0}"
  printf 'ineligible / not eligible   : %s\n' "${INELIGIBLE:-0}"
  printf 'keyring save failure        : %s\n' "${KEYCHAIN:-0}"

  if [[ "${AUTH_OK:-0}" -gt 0 ]]; then
    ok "Auth success has been logged at least once."
    info "last: $(last_match 'Auth succeeded')"
  fi

  if [[ "${TOKEN_ERR:-0}" -gt 0 || "${TOKEN_FAIL:-0}" -gt 0 ]]; then
    warn "OAuth token exchange has failed in the recent log."
    info "last: $(last_match 'oauth2.googleapis.com/token')"
    info "A full quit/relaunch of Antigravity often clears stale keep-alive connections."
  fi

  if [[ "${STATE_FAIL:-0}" -gt 0 ]]; then
    warn "state mismatch found. Start a fresh login from the App; do not reuse an old browser tab."
  fi

  if [[ "${NO_CODE:-0}" -gt 0 ]]; then
    warn "No authorization code was received by the callback listener."
  fi

  if [[ "${INELIGIBLE:-0}" -gt 0 ]]; then
    warn "The log contains historical ineligible/not eligible messages."
    info "If the App is currently in the main UI, these are from earlier attempts and can be ignored."
    info "If it is still on onboarding, this is an account eligibility problem, not a proxy problem."
  fi

  if [[ "${KEYCHAIN:-0}" -gt 0 ]]; then
    warn "Token could not be saved to the keychain; it may have fallen back to a file."
    info "Check: security show-keychain-info ~/Library/Keychains/login.keychain-db"
  fi
fi

# ---------------------------------------------------------------------------
section "OAuth callback listener"
# ---------------------------------------------------------------------------
if [[ -z "$LS_PIDS" ]]; then
  warn "language_server is not running, so no callback listener is expected."
else
  LISTEN_PORTS=""
  for pid in $LS_PIDS; do
    P="$(lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}' || true)"
    [[ -n "$P" ]] && LISTEN_PORTS="$LISTEN_PORTS$P"$'\n'
  done
  if [[ -n "$LISTEN_PORTS" ]]; then
    printf 'listening:\n%s' "$LISTEN_PORTS" | sed '/^$/d' | sed 's/^/     /'
    COUNT="$(printf '%s' "$LISTEN_PORTS" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$COUNT" -ge 3 ]]; then
      ok "A third listening port is present; this is likely the temporary OAuth callback listener."
    else
      info "Only the base ports are listening. Start a login and rerun while the browser is on the callback page to see the temporary port."
    fi
  else
    warn "No listening ports found for language_server."
  fi
fi

# ---------------------------------------------------------------------------
section "Other VPN / network clients"
# ---------------------------------------------------------------------------
CONFLICTS="$(pgrep -fl 'iKuuuVPN|aTrust|ClashX|Surge|Shadowrocket|sing-box|v2ray|Xray' 2>/dev/null |
  grep -v 'clash-verge' || true)"
if [[ -n "$CONFLICTS" ]]; then
  warn "Other network clients are running. They may compete with Clash for TUN/routes/DNS:"
  printf '%s\n' "$CONFLICTS" | sed -E 's/ --.*$//' | cut -c1-160 | sort -u | sed -n '1,8p' | sed 's/^/     /'
  CONFLICT_COUNT="$(printf '%s\n' "$CONFLICTS" | sed -E 's/ --.*$//' | sort -u | wc -l | tr -d ' ')"
  if [[ "$CONFLICT_COUNT" -gt 8 ]]; then
    info "... and $((CONFLICT_COUNT - 8)) more."
  fi
  info "For a clean test, keep only one proxy/VPN stack."
else
  ok "No other common VPN clients detected."
fi

# ---------------------------------------------------------------------------
section "Keychain"
# ---------------------------------------------------------------------------
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if [[ -f "$KEYCHAIN" ]]; then
  KEYCHAIN_INFO="$(security show-keychain-info "$KEYCHAIN" 2>&1 | head -1 || true)"
  printf 'login.keychain: %s\n' "${KEYCHAIN_INFO:-unknown}"
  if printf '%s' "$KEYCHAIN_INFO" | grep -qi 'locked'; then
    warn "login keychain is locked; the language server may fail to persist tokens."
  else
    ok "login keychain does not report locked."
  fi
else
  warn "login.keychain-db not found."
fi

# ---------------------------------------------------------------------------
section "Summary"
# ---------------------------------------------------------------------------
if [[ "$FAILED" -eq 0 ]]; then
  ok "No critical issue was detected by this script."
else
  printf '%sAt least one critical issue was detected.%s\n' "$C_RED" "$C_RESET"
fi

cat <<'EOF'

Suggested order:

1. If TUN/system proxy is not actually active, fix that first.
2. If direct Google works but the App still fails, full-quit Antigravity
   (including language_server) and reopen it.
3. If the browser reaches localhost/auth/callback but the App does not move on,
   check the token exchange and the account eligibility message.
4. If the App says "not eligible" or GetAuthStatus returns "ineligible",
   complete Google's verification, then fully quit and reopen the App.
   Proxy IP does not change account eligibility.
5. If the App exits immediately when launched from a script, use:
   env -u ELECTRON_RUN_AS_NODE open -a /Applications/Antigravity.app

This script is read-only. No settings were changed.
EOF

exit "$FAILED"
