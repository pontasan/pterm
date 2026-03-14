#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/.build/pterm.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/PtermApp"
PROFILES_DIR="$ROOT_DIR/.build/profiles"

duration=10
interval_ms=1
build_if_needed=1
launch_mode="launch"
output_dir=""
pid=""
launched_pid=""

usage() {
  cat <<'EOF'
Usage:
  Scripts/profile-cpu.sh [options]

Options:
  --duration <seconds>       Sampling duration for sample/xctrace (default: 10)
  --interval-ms <ms>         sample interval in milliseconds (default: 1)
  --no-build                 Reuse existing bundle without building
  --attach-pid <pid>         Attach to an already-running PtermApp process
  --attach-existing          Attach to the newest running PtermApp process
  --output-dir <path>        Directory where profiling artifacts are written
  -h, --help                 Show this help

Artifacts:
  sample.txt                 Stack-sampling report from /usr/bin/sample
  spindump.txt               Spindump report
  time-profiler.trace        Instruments Time Profiler trace
  summary.txt                Short summary with quick pointers
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

wait_for_pid() {
  local attempts=0
  local candidate=""
  while (( attempts < 200 )); do
    candidate="$(pgrep -xn PtermApp || true)"
    if [[ -n "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
    sleep 0.1
    attempts=$((attempts + 1))
  done
  return 1
}

make_output_dir() {
  if [[ -n "$output_dir" ]]; then
    mkdir -p "$output_dir"
    echo "$output_dir"
    return 0
  fi

  mkdir -p "$PROFILES_DIR"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  local target="$PROFILES_DIR/$stamp"
  mkdir -p "$target"
  echo "$target"
}

summarize_sample() {
  local sample_file="$1"
  local summary_file="$2"

  {
    echo "pterm CPU profiling summary"
    echo "generated: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo
    echo "sample top-of-stack section:"
    awk '
      /^Sort by top of stack/ { in_section=1; print; next }
      in_section && /^Binary Images:/ { exit }
      in_section { print }
    ' "$sample_file"
  } > "$summary_file"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)
      duration="$2"
      shift 2
      ;;
    --interval-ms)
      interval_ms="$2"
      shift 2
      ;;
    --no-build)
      build_if_needed=0
      shift
      ;;
    --attach-pid)
      launch_mode="attach"
      pid="$2"
      shift 2
      ;;
    --attach-existing)
      launch_mode="attach-existing"
      shift
      ;;
    --output-dir)
      output_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_command sample
require_command spindump
require_command xcrun
require_command pgrep

if (( build_if_needed )); then
  make -C "$ROOT_DIR" debug >/dev/null
fi

if [[ ! -x "$APP_BINARY" ]]; then
  echo "error: app binary not found at $APP_BINARY" >&2
  exit 1
fi

ARTIFACT_DIR="$(make_output_dir)"
SAMPLE_FILE="$ARTIFACT_DIR/sample.txt"
SPINDUMP_FILE="$ARTIFACT_DIR/spindump.txt"
TRACE_FILE="$ARTIFACT_DIR/time-profiler.trace"
SUMMARY_FILE="$ARTIFACT_DIR/summary.txt"
SAMPLE_LOG="$ARTIFACT_DIR/sample.log"
SPINDUMP_LOG="$ARTIFACT_DIR/spindump.log"
XCTRACE_LOG="$ARTIFACT_DIR/xctrace.log"

cleanup() {
  if [[ -n "$launched_pid" ]]; then
    kill "$launched_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

case "$launch_mode" in
  launch)
    "$APP_BINARY" >/dev/null 2>&1 &
    launched_pid="$!"
    pid="$(wait_for_pid)"
    ;;
  attach-existing)
    pid="$(pgrep -xn PtermApp || true)"
    if [[ -z "$pid" ]]; then
      echo "error: no running PtermApp process found" >&2
      exit 1
    fi
    ;;
  attach)
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      echo "error: pid $pid is not running" >&2
      exit 1
    fi
    ;;
esac

echo "Profiling pid $pid for ${duration}s"
echo "Artifacts: $ARTIFACT_DIR"

sample "$pid" "$duration" "$interval_ms" -mayDie -fullPaths -file "$SAMPLE_FILE" >"$SAMPLE_LOG" 2>&1 &
sample_pid="$!"

spindump "$pid" "$duration" 10 -onlyTarget -o "$SPINDUMP_FILE" >"$SPINDUMP_LOG" 2>&1 &
spindump_pid="$!"

xcrun xctrace record \
  --template 'Time Profiler' \
  --attach "$pid" \
  --time-limit "${duration}s" \
  --output "$TRACE_FILE" \
  --no-prompt \
  >"$XCTRACE_LOG" 2>&1 &
xctrace_pid="$!"

sample_status=0
spindump_status=0
xctrace_status=0

wait "$sample_pid" || sample_status=$?
wait "$spindump_pid" || spindump_status=$?
wait "$xctrace_pid" || xctrace_status=$?

if [[ ! -f "$SAMPLE_FILE" ]]; then
  echo "error: sample did not produce $SAMPLE_FILE" >&2
  exit 1
fi

if [[ -d "$TRACE_FILE" ]]; then
  xctrace_status=0
fi

summarize_sample "$SAMPLE_FILE" "$SUMMARY_FILE"

if (( spindump_status != 0 )); then
  {
    echo
    echo "spindump status: $spindump_status"
    echo "spindump failed; on macOS this often requires root."
    echo "sample and xctrace are the primary artifacts."
  } >> "$SUMMARY_FILE"
fi

if (( xctrace_status != 0 )); then
  {
    echo
    echo "xctrace status: $xctrace_status"
    echo "xctrace failed; inspect $XCTRACE_LOG"
  } >> "$SUMMARY_FILE"
fi

cat <<EOF
Done.
  sample:       $SAMPLE_FILE
  spindump:     $SPINDUMP_FILE
  time profile: $TRACE_FILE
  summary:      $SUMMARY_FILE
EOF
