#!/usr/bin/env bash
# Kill running instances, package, relaunch, verify.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME=${APP_NAME:-}
RUN_TESTS=0
RELEASE_ARCHES="${ARCHES:-arm64 x86_64}"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "${arg}" in
    --test|-t) RUN_TESTS=1 ;;
    --release-universal) RELEASE_ARCHES="arm64 x86_64" ;;
    --release-arches=*) RELEASE_ARCHES="${arg#*=}" ;;
    --app-name=*) APP_NAME="${arg#*=}" ;;
    --help|-h)
      log "Usage: $(basename "$0") [APP_NAME] [--app-name=APP_NAME] [--test] [--release-universal] [--release-arches=\"arm64 x86_64\"]"
      exit 0
      ;;
    *)
      if [[ -z "$APP_NAME" ]]; then
        APP_NAME="$arg"
      else
        fail "Unknown argument: $arg"
      fi
      ;;
  esac
done

APP_NAME=${APP_NAME:-$(basename "$ROOT_DIR")}
APP_BUNDLE="${ROOT_DIR}/${APP_NAME}.app"
APP_PROCESS_PATTERN="${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
DEBUG_PROCESS_PATTERN="${ROOT_DIR}/.build/debug/${APP_NAME}"
RELEASE_PROCESS_PATTERN="${ROOT_DIR}/.build/release/${APP_NAME}"

log "==> compile_and_run.sh settings"
log "    root          : ${ROOT_DIR}"
log "    app name      : ${APP_NAME}"
log "    run tests     : ${RUN_TESTS}"
log "    architectures : ${RELEASE_ARCHES}"

log "==> Killing existing ${APP_NAME} instances"
pkill -f "${APP_PROCESS_PATTERN}" 2>/dev/null || true
pkill -f "${DEBUG_PROCESS_PATTERN}" 2>/dev/null || true
pkill -f "${RELEASE_PROCESS_PATTERN}" 2>/dev/null || true
pkill -x "${APP_NAME}" 2>/dev/null || true

if [[ "${RUN_TESTS}" == "1" ]]; then
  log "==> swift test"
  swift test -q
fi

log "==> package app"
SIGNING_MODE=adhoc ARCHES="${RELEASE_ARCHES}" "${ROOT_DIR}/Scripts/package_app.sh" release "$APP_NAME"

log "==> launch app"
if ! open "${APP_BUNDLE}"; then
  log "WARN: open failed; launching binary directly."
  "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1 &
  disown
fi

for _ in {1..10}; do
  if pgrep -f "${APP_PROCESS_PATTERN}" >/dev/null 2>&1; then
    log "OK: ${APP_NAME} is running."
    exit 0
  fi
  sleep 0.4
done
fail "App exited immediately. Check crash logs in Console.app (User Reports)."
