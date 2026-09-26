#!/usr/bin/env bash
# gpu-temp-log.sh [logdir] [interval_s] — append one row per card per sample, keyed by
# serial (short canonical key), into one CSV per day: logdir/gpu-temps-v4-YYYYMMDD.csv.
# The date is re-evaluated every sample, so midnight rollover starts a fresh file with
# its own header row — no service restart needed. Retention: gpu-temp-prune.timer
# deletes gpu-temps-*.csv* older than 180 days. (logrotate removed 2026-09-26: its
# daily rename fought the per-day names — a long-lived instance's date-named file got
# renamed into .1/.2.gz chains holding other days' data, and first-seen files were
# state-stamped without being renamed at all.)
#
# Schema history (each break starts a fresh file — never append across schemas):
#   2026-09-13 morning: ts,serial,uuid,bdf,slot,hbm_c,core_c,power_w,util_gpu,util_mem,throttle
#   2026-09-13 midday:  + fan_rpm,fan_duty (it87 hwmon, CHA_FAN1 via ARCTIC hub)
#   2026-09-13 v3:      ts=MM-DD-YYYY HH:MM:SS, dropped uuid (dup of serial), bdf
#                       (per-boot renumbering — belongs to gpu-id.sh, not the log),
#                       util_mem (always 0 on these cards); slot shortened to O1..O4
#                       (ports live in gpu-slots.tsv); throttle as bare bitmask number
#                       (0=none, 0x01 idle, 0x04 SW power cap, 0x10 SW thermal,
#                       0x20 HW thermal — NVML clocks_event_reasons; see runbook §1).
#   2026-09-26 v4:      fan_duty (raw pwm 0-255) normalized to fan_pct (0-100,
#                       round(pwm/255*100)); filename gains the v4 prefix so
#                       pre/post-normalization rows never share a file.
# Column meanings: hbm_c/core_c °C, power_w board watts, fan_rpm/fan_pct from the
# it8665 hwmon (empty when the module is not loaded — e.g. blacklisted at boot — so
# BIOS-curve rows self-mark).
# Note: a stop mid-sample (SIGTERM during the nvidia-smi pipeline) can leave one timestamp
# with fewer than 4 rows — consumers must not assume exactly 4 rows per ts.
#
# Prometheus output (2026-09-26): when /var/lib/prometheus/node-exporter exists
# (node_exporter textfile collector, installed for the obs stack), each sample also
# atomically writes two .prom files there:
#   170hx-gpu.prom   — per-card hbm/core temp, power (slot+serial labels), hub fan
#                      rpm/duty, and gpu_exporter_last_sample_timestamp_seconds
#                      (frozen gauge = exporter stopped, never assume liveness)
#   vllm-bridge.prom — raw vllm:* lines passed through from the serving pod's
#                      /metrics (cross-VLAN Prometheus cannot reach the NodePort;
#                      file removed when vLLM is down so metrics gap, not freeze)
# Unwritable/missing dir → CSV-only, exactly as before.
LOGDIR=${1:-/var/tmp/170hx_logs}
INT=${2:-5}
PROMDIR=/var/lib/prometheus/node-exporter
VLLM_METRICS_URL=http://localhost:31566/metrics   # microk8s NodePort, vllm-glm53-flash-awq
# Real serial→slot map lives in /etc/gpu-slots.tsv (never committed — the repo copy
# is a sanitized template). Fall back to the repo copy for local testing.
SLOTMAP=/etc/gpu-slots.tsv
[ -r "$SLOTMAP" ] || SLOTMAP="$(dirname "$0")/gpu-slots.tsv"
LOG=""; day=""

while :; do
  today=$(date +%Y%m%d)
  if [ "$today" != "$day" ]; then
    day=$today
    LOG="$LOGDIR/gpu-temps-v4-$today.csv"
    mkdir -p "$LOGDIR" || { echo "cannot create logdir $LOGDIR" >&2; exit 1; }
    [ -e "$LOG" ] || echo "ts,serial,slot,hbm_c,core_c,power_w,util_gpu,throttle,fan_rpm,fan_pct" > "$LOG"
  fi
  ts=$(date +"%m-%d-%Y %H:%M:%S")
  # it87 hwmon device: resolved by name each sample (hwmon indices renumber per boot),
  # so fan_rpm/fan_duty reflect the live duty, not the value at service start.
  FANDEV=""
  for d in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$d/name" 2>/dev/null)" = "it8665" ] && FANDEV="$d" && break
  done
  FAN_RPM=""; FAN_PCT=""
  [ -n "$FANDEV" ] && { FAN_RPM=$(cat "$FANDEV/fan2_input" 2>/dev/null); FAN_PCT=$(( ( $(cat "$FANDEV/pwm2" 2>/dev/null || echo 0) * 100 + 127 ) / 255 )); }
  SMI=$(nvidia-smi --query-gpu=serial,temperature.memory,temperature.gpu,power.draw,\
utilization.gpu,clocks_event_reasons.active --format=csv,noheader,nounits 2>/dev/null) \
  && [ -n "$SMI" ] && {
    PROM=""
    while IFS=, read -r serial hbm core pw ug thr; do
      serial=$(echo "$serial" | xargs)
      slot=$([ -f "$SLOTMAP" ] && awk -F'\t' -v s="$serial" '$1==s{print $2}' "$SLOTMAP")
      hbm=$(echo $hbm|xargs); core=$(echo $core|xargs); pw=$(echo $pw|xargs); ug=$(echo $ug|xargs)
      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" "$ts" "$serial" "${slot:-unknown}" \
        "$hbm" "$core" "$pw" "$ug" "$(( $(echo $thr|xargs) ))" "$FAN_RPM" "$FAN_PCT" >> "$LOG"
      for kv in "hbm_temp_celsius|$hbm" "core_temp_celsius|$core" "power_watts|$pw"; do
        name=${kv%%|*}; val=${kv#*|}
        case "$val" in *[!0-9.]*) ;; *) [ -n "$val" ] && \
          PROM="${PROM}gpu_$name{slot=\"${slot:-unknown}\",serial=\"$serial\"} $val\n";; esac
      done
    done <<< "$SMI"
    [ -n "$FAN_RPM" ] && PROM="${PROM}gpu_fan_rpm{fan=\"cha_fan1\"} $FAN_RPM\n"
    [ -n "$FAN_PCT" ] && PROM="${PROM}gpu_fan_duty_percent{fan=\"cha_fan1\"} $FAN_PCT\n"
    PROM="${PROM}gpu_exporter_last_sample_timestamp_seconds $(date +%s)\n"
    printf "$PROM" > "$PROMDIR/.170hx-gpu.prom.tmp" 2>/dev/null && \
      mv "$PROMDIR/.170hx-gpu.prom.tmp" "$PROMDIR/170hx-gpu.prom" 2>/dev/null
  }
  # vLLM /metrics bridge (see header). File removed on any failure → gaps, not staleness.
  VLM=$(curl -sf --max-time 4 "$VLLM_METRICS_URL" | grep '^vllm') && \
    printf '%s\n' "$VLM" > "$PROMDIR/.vllm-bridge.prom.tmp" 2>/dev/null && \
    mv "$PROMDIR/.vllm-bridge.prom.tmp" "$PROMDIR/vllm-bridge.prom" 2>/dev/null || \
    rm -f "$PROMDIR/vllm-bridge.prom"
  sleep "$INT"
done
