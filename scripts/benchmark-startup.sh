#!/usr/bin/env bash
#
# Measure agentc startup latency.
#
# Two numbers are reported per run and they mean different things:
#
#   launch_to_token  host time from exec'ing agentc until the workload prints its
#                    readiness token. This is what a user waits for.
#   total            wall-clock time for the whole command, which additionally
#                    includes container teardown and rootfs deletion.
#
# The harness uses a dedicated temporary profile and a fixture configuration whose
# prepare.sh is a no-op, so nothing here depends on an external agent service or on
# whatever the user's real profile happens to contain.
#
# Run with --verbose to also capture agentc's own per-phase `timing` records, which
# break the launch down into image unpacking, guest startup, ownership traversal and
# preparation costs. Host and guest spans come from different monotonic clocks: read
# them individually, never subtract or sum them.
#
# Usage:
#   scripts/benchmark-startup.sh [options]
#
# Options:
#   --agentc PATH        agentc binary to measure (default: ./.build/release/agentc,
#                        falling back to ./.build/debug/agentc, then $PATH).
#   --image REF          Image to launch. Repeat to benchmark several images.
#   --runs N             Measured runs per case (default: 20).
#   --warmup N           Unmeasured runs before measuring (default: 1).
#   --profile-files N    Files to plant in the throwaway profile home. Repeat to
#                        benchmark several profile sizes (default: 0).
#   --extra-arg ARG      Extra argument passed through to agentc. Repeat as needed.
#   --out DIR            Where to write results (default: a fresh mktemp -d).
#   --keep               Keep the temporary profile/configuration directories.
#   --verbose            Pass --verbose to agentc and keep its timing records.
#   -h, --help           Show this help.
#
set -euo pipefail

AGENTC=""
IMAGES=()
RUNS=20
WARMUP=1
PROFILE_FILE_COUNTS=()
EXTRA_ARGS=()
OUT_DIR=""
KEEP=0
VERBOSE=0

READY_TOKEN="agentc-benchmark-ready"

usage() {
  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agentc) AGENTC="$2"; shift 2 ;;
    --image) IMAGES+=("$2"); shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --profile-files) PROFILE_FILE_COUNTS+=("$2"); shift 2 ;;
    --extra-arg) EXTRA_ARGS+=("$2"); shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ${#IMAGES[@]} -eq 0 ]]; then
  # A small image and a larger development image, so unpack cost is visible.
  IMAGES=("docker.io/library/alpine:latest" "ghcr.io/laosb/claudec:latest")
fi
if [[ ${#PROFILE_FILE_COUNTS[@]} -eq 0 ]]; then
  PROFILE_FILE_COUNTS=(0)
fi

resolve_agentc() {
  if [[ -n "$AGENTC" ]]; then
    command -v "$AGENTC" >/dev/null 2>&1 || [[ -x "$AGENTC" ]] || {
      echo "agentc not executable: $AGENTC" >&2; exit 1; }
    printf '%s\n' "$AGENTC"
    return
  fi
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  for candidate in "$repo_root/.build/release/agentc" "$repo_root/.build/debug/agentc"; do
    if [[ -x "$candidate" ]]; then printf '%s\n' "$candidate"; return; fi
  done
  command -v agentc || { echo "no agentc binary found; pass --agentc" >&2; exit 1; }
}

AGENTC="$(resolve_agentc)"

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentc-bench.XXXXXX")"
fi
mkdir -p "$OUT_DIR"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentc-bench-work.XXXXXX")"
cleanup() {
  if [[ "$KEEP" -eq 1 ]]; then
    echo "keeping work directory: $WORK_DIR" >&2
  else
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixture configuration: a no-op prepare.sh, so preparation cost is measured as
# near-zero rather than as whatever a real agent's setup happens to do today.
# ---------------------------------------------------------------------------
CONFIG_DIR="$WORK_DIR/configurations"
mkdir -p "$CONFIG_DIR/benchmark"
cat > "$CONFIG_DIR/benchmark/settings.json" <<JSON
{
  "entrypoint": ["/bin/sh", "-c", "echo $READY_TOKEN"]
}
JSON
cat > "$CONFIG_DIR/benchmark/prepare.sh" <<'SH'
#!/bin/sh
# Intentionally does nothing: the benchmark measures agentc, not agent setup.
exit 0
SH
chmod +x "$CONFIG_DIR/benchmark/prepare.sh"

# ---------------------------------------------------------------------------
# Timing helpers
# ---------------------------------------------------------------------------

now_ms() {
  # `date +%s%3N` is a GNU extension; on macOS fall back to python3, then to
  # whole seconds, so the harness still runs on a stock system.
  if [[ -n "${AGENTC_BENCH_DATE_MS:-}" ]]; then
    eval "$AGENTC_BENCH_DATE_MS"
    return
  fi
  local value
  value="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ && "$value" != *N* ]]; then
    printf '%s\n' "$value"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.monotonic()*1000))'
    return
  fi
  printf '%s000\n' "$(date +%s)"
}

percentile() {
  # percentile <p> <sorted values on stdin>
  local p="$1"
  awk -v p="$p" '
    { values[NR] = $1 }
    END {
      if (NR == 0) { print "n/a"; exit }
      idx = int((p / 100) * (NR - 1)) + 1
      if (idx < 1) idx = 1
      if (idx > NR) idx = NR
      print values[idx]
    }'
}

summarize() {
  # summarize <label> <file of values>
  local label="$1" file="$2"
  if [[ ! -s "$file" ]]; then
    printf '  %-16s no successful runs\n' "$label"
    return
  fi
  local sorted median p95 count
  sorted="$(sort -n "$file")"
  count="$(wc -l < "$file" | tr -d ' ')"
  median="$(printf '%s\n' "$sorted" | percentile 50)"
  p95="$(printf '%s\n' "$sorted" | percentile 95)"
  printf '  %-16s n=%-4s median=%sms p95=%sms\n' "$label" "$count" "$median" "$p95"
}

# ---------------------------------------------------------------------------
# Profile fixture
# ---------------------------------------------------------------------------

make_profile() {
  # make_profile <dir> <file count>
  local dir="$1" count="$2"
  rm -rf "$dir"
  mkdir -p "$dir/home"
  if [[ "$count" -gt 0 ]]; then
    # Spread across subdirectories so the tree has realistic depth rather than
    # one enormous flat directory.
    local per_dir=500
    local made=0 bucket=0
    while [[ "$made" -lt "$count" ]]; do
      local sub="$dir/home/.cache/bucket-$bucket"
      mkdir -p "$sub"
      local i=0
      while [[ "$i" -lt "$per_dir" && "$made" -lt "$count" ]]; do
        printf 'x' > "$sub/file-$i"
        i=$((i + 1))
        made=$((made + 1))
      done
      bucket=$((bucket + 1))
    done
  fi
}

# ---------------------------------------------------------------------------
# One measured launch
# ---------------------------------------------------------------------------

run_once() {
  # run_once <profile dir> <image> <stdout file> <stderr file>
  # Prints "<launch_to_token_ms> <total_ms> <exit code>".
  local profile_dir="$1" image="$2" out_file="$3" err_file="$4"
  local args=(
    run
    --profile-dir "$profile_dir"
    --image "$image"
    --configurations benchmark
    --configurations-dir "$CONFIG_DIR"
    --workspace "$WORK_DIR/workspace"
    --suppress-migration-from-claudec
  )
  [[ "$VERBOSE" -eq 1 ]] && args+=(--verbose)
  args+=("${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}")

  mkdir -p "$WORK_DIR/workspace"

  local token_file="$WORK_DIR/token-at"
  : > "$token_file"
  : > "$out_file"

  # stdout is streamed rather than redirected so the token can be timestamped the
  # moment it arrives. Everything after that point is teardown, not startup.
  local start end status
  start="$(now_ms)"
  set +e
  "$AGENTC" "${args[@]}" 2> "$err_file" | while IFS= read -r line; do
    printf '%s\n' "$line" >> "$out_file"
    if [[ ! -s "$token_file" && "$line" == *"$READY_TOKEN"* ]]; then
      now_ms > "$token_file"
    fi
  done
  status=${PIPESTATUS[0]}
  set -e
  end="$(now_ms)"

  if [[ -s "$token_file" ]]; then
    printf '%s %s %s\n' "$(($(cat "$token_file") - start))" "$((end - start))" "$status"
  else
    printf '%s %s %s\n' "-1" "$((end - start))" "$status"
  fi
}

# ---------------------------------------------------------------------------
# Environment report
# ---------------------------------------------------------------------------

REPORT="$OUT_DIR/report.txt"
{
  echo "agentc startup benchmark"
  echo "date:            $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "agentc:          $AGENTC"
  echo "agentc version:  $("$AGENTC" version 2>/dev/null | head -1 || echo unknown)"
  echo "uname:           $(uname -a)"
  if command -v sw_vers >/dev/null 2>&1; then
    echo "macOS:           $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  fi
  if command -v sysctl >/dev/null 2>&1; then
    echo "hardware:        $(sysctl -n hw.model 2>/dev/null || echo unknown)"
    echo "cpus:            $(sysctl -n hw.ncpu 2>/dev/null || echo unknown)"
    echo "memory:          $(sysctl -n hw.memsize 2>/dev/null || echo unknown)"
  fi
  echo "filesystem:      $(df -T "$WORK_DIR" 2>/dev/null | tail -1 || df "$WORK_DIR" | tail -1)"
  echo "runs:            $RUNS (warmup $WARMUP)"
  echo
} | tee "$REPORT"

# ---------------------------------------------------------------------------
# Measure
# ---------------------------------------------------------------------------

for image in "${IMAGES[@]}"; do
  for file_count in "${PROFILE_FILE_COUNTS[@]}"; do
    case_id="$(printf '%s' "$image" | tr -c 'A-Za-z0-9._-' '_')-profile$file_count"
    profile_dir="$WORK_DIR/profile"
    make_profile "$profile_dir" "$file_count"

    launch_file="$OUT_DIR/$case_id.launch_to_token.txt"
    total_file="$OUT_DIR/$case_id.total.txt"
    : > "$launch_file"
    : > "$total_file"

    # First use is reported separately: it may pull the image, download a kernel,
    # or populate a cold rootfs cache, none of which repeat.
    first_out="$OUT_DIR/$case_id.firstuse.stdout"
    first_err="$OUT_DIR/$case_id.firstuse.stderr"
    read -r first_launch first_total first_status \
      < <(run_once "$profile_dir" "$image" "$first_out" "$first_err")

    for ((i = 0; i < WARMUP; i++)); do
      run_once "$profile_dir" "$image" "$OUT_DIR/$case_id.warmup.stdout" \
        "$OUT_DIR/$case_id.warmup.stderr" > /dev/null
    done

    failures=0
    for ((i = 0; i < RUNS; i++)); do
      out_file="$OUT_DIR/$case_id.run$i.stdout"
      err_file="$OUT_DIR/$case_id.run$i.stderr"
      read -r launch total status \
        < <(run_once "$profile_dir" "$image" "$out_file" "$err_file")
      if [[ "$status" -ne 0 || "$launch" -lt 0 ]]; then
        failures=$((failures + 1))
        continue
      fi
      echo "$launch" >> "$launch_file"
      echo "$total" >> "$total_file"

      # Diagnostics must never reach the workload's stdout. A stray record here
      # is a bug in the instrumentation, not a benchmark artifact.
      if grep -q 'agentc: timing ' "$out_file"; then
        echo "FAIL: timing diagnostics contaminated stdout in $out_file" >&2
        exit 1
      fi

      if [[ "$VERBOSE" -eq 1 ]]; then
        grep 'agentc: timing ' "$err_file" >> "$OUT_DIR/$case_id.timings.txt" || true
      else
        rm -f "$err_file"
      fi
      rm -f "$out_file"
    done

    {
      echo "case: $case_id"
      echo "  image:          $image"
      echo "  profile files:  $file_count"
      echo "  first use:      launch_to_token=${first_launch}ms total=${first_total}ms exit=$first_status"
      summarize "launch_to_token" "$launch_file"
      summarize "total" "$total_file"
      echo "  failed runs:    $failures"
      if [[ "$VERBOSE" -eq 1 && -s "$OUT_DIR/$case_id.timings.txt" ]]; then
        echo "  phase medians:"
        awk '
          match($0, /phase=[^ ]+/) {
            phase = substr($0, RSTART + 6, RLENGTH - 6)
          }
          match($0, /duration_ms=[0-9.]+/) {
            ms = substr($0, RSTART + 12, RLENGTH - 12) + 0
            values[phase] = values[phase] " " ms
          }
          END {
            for (p in values) {
              n = split(values[p], a, " ")
              # a[1] is the empty leading field from the join above.
              for (i = 2; i <= n; i++) nums[i - 1] = a[i]
              count = n - 1
              for (i = 1; i < count; i++)
                for (j = i + 1; j <= count; j++)
                  if (nums[j] + 0 < nums[i] + 0) { t = nums[i]; nums[i] = nums[j]; nums[j] = t }
              printf "    %-32s n=%-4d median=%.1fms\n", p, count, nums[int((count + 1) / 2)]
              delete nums
            }
          }' "$OUT_DIR/$case_id.timings.txt"
      fi
      echo
    } | tee -a "$REPORT"
  done
done

echo "results written to $OUT_DIR" | tee -a "$REPORT"
