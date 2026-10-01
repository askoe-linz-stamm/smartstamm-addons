#!/usr/bin/env bash
# End-to-end scheduling with a simulated clock and local measurement clients.
# Run only in a disposable container: this fixture owns /data and /tmp/trigger_*.
set -euo pipefail
cd "$(dirname "$0")/.."
export TZ=Europe/Vienna
mkdir -p /data/bin /data/test-bin
touch /data/dry_run
sed -n 's/^OOKLA_VERSION=//p' netzmessung/run.sh > /data/bin/speedtest.version
sed -n 's/^RMBT_RELEASE=\([^ ]*\).*/\1/p' netzmessung/run.sh > /data/bin/rmbt-client.version
cat > /data/test-bin/date <<'EOF'
#!/usr/bin/env bash
if [ "$*" = +%s ]; then cat /data/test-clock
elif [ "$*" = -Iseconds ]; then /bin/date -d "@$(cat /data/test-clock)" -Iseconds
else /bin/date "$@"
fi
EOF
cat > /data/bin/speedtest <<'EOF'
#!/usr/bin/env bash
echo speedtest >> /data/runs
printf '%s\n' "$*" >> /data/speedtest-arguments
echo "$(($(cat /data/test-clock) + 20))" > /data/test-clock
# First run fails. Subsequent manual requests must still work.
if [ ! -f /data/failed-once ]; then touch /data/failed-once; exit 1; fi
echo '{"type":"result","download":{"bandwidth":12500000},"upload":{"bandwidth":6250000},"ping":{"latency":10},"server":{"id":818},"result":{"url":"https://example.invalid/result"}}'
EOF
cat > /data/bin/rmbt-client <<'EOF'
#!/usr/bin/env bash
echo rtr >> /data/runs
printf '%s\n' "$*" >> /data/rtr-arguments
echo "$(($(cat /data/test-clock) + 20))" > /data/test-clock
echo 'Download: 100'
echo 'Upload: 50'
echo 'Ping (median): 10'
echo 'Ping (min): 8 ms (3)'
echo 'Result: https://example.invalid/result'
EOF
cat > /data/test-bin/python3 <<'EOF'
#!/usr/bin/env bash
[ "${1##*/}" = router.py ] || exit 3
echo check >> /data/protection-checks
echo "$(($(cat /data/test-clock) + 60))" > /data/test-clock
case "${TEST_PROTECTION}" in
  idle) echo '{"state":"idle","average_mbps":0.5}'; exit 0 ;;
  busy) echo '{"state":"busy","average_mbps":8}'; exit 2 ;;
  unavailable) echo '{"state":"unavailable","reason":"router-unauthorized"}'; exit 3 ;;
  malformed) echo 'not-json'; exit 0 ;;
esac
EOF
chmod +x /data/test-bin/date /data/test-bin/python3 /data/bin/speedtest /data/bin/rmbt-client
export PATH="/data/test-bin:${PATH}"
bashio::log.info() { echo "INFO $*"; }
bashio::log.warning() { echo "WARNING $*"; }
bashio::log.error() { echo "ERROR $*"; }
sleep() {
  local now
  now=$(cat /data/test-clock)
  if [ "${now}" -ge "${TEST_END}" ]; then exit 0; fi
  if [ "${now}" -ge "${TEST_MANUAL}" ] && [ ! -f /data/manual-once ]; then
    touch /data/manual-once /tmp/trigger_speedtest
  fi
  echo "$((now + $1))" > /data/test-clock
}
export -f bashio::log.info bashio::log.warning bashio::log.error sleep
export TEST_MANUAL TEST_END TEST_PROTECTION
export SUPERVISOR_TOKEN=test-only-token
curl() {
  [ "${*: -1}" = http://supervisor/addons/self/options ] || return 1
  jq -e '.options | keys == ["general","protection","rtr","speedtest"]' > /dev/null || return 1
  echo '{"result":"ok"}'
}
export -f curl

for mode in legacy daily; do
  rm -rf /data/schedules
  rm -f /data/runs /data/failed-once /data/manual-once /data/speedtest-arguments /data/rtr-arguments /data/protection-checks /tmp/trigger_speedtest /tmp/trigger_rtr
  date -d '2026-10-01 09:26:00' +%s > /data/test-clock
  TEST_MANUAL=$(date -d '2026-10-01 09:34:00' +%s)
  TEST_END=$(date -d '2026-10-01 09:35:00' +%s)
  # Legacy options omit all new settings; their defaults must still work.
  cat > /data/options.json <<'EOF'
{"speedtest_minute":30,"speedtest_server_id":818,"rtr_minute":30,"run_on_start":false}
EOF
  if [ "${mode}" = daily ]; then
    jq '. + {speedtest_interval:6,rtr_interval:1,rtr_interval_unit:"days",rtr_hour:9,jitter_minutes:0}' \
      /data/options.json > /data/options.tmp
    mv /data/options.tmp /data/options.json
  fi
  bash "${RUN_SCRIPT:-netzmessung/run.sh}" < /dev/null > "/data/${mode}.log" 2>&1
  [ "$(grep -c '^speedtest$' /data/runs)" = 2 ]
  [ "$(grep -c '^rtr$' /data/runs)" = 1 ]
  grep -q 'measurement-failed' "/data/${mode}.log"
  grep -q 'sensor.speedtest_status.*"ok"' "/data/${mode}.log"
  if [ "${mode}" = daily ]; then
    expected_speedtest=$(date -d '2026-10-01 15:30:00' +%s)
    expected_rtr=$(date -d '2026-10-02 09:30:00' +%s)
  else
    expected_speedtest=$(date -d '2026-10-01 10:30:00' +%s)
    expected_rtr=${expected_speedtest}
  fi
  [ "$(jq -r .nominal /data/schedules/speedtest.json)" = "${expected_speedtest}" ]
  [ "$(jq -r .nominal /data/schedules/rtr.json)" = "${expected_rtr}" ]
  [ ! -f /data/protection-checks ]
done

for TEST_PROTECTION in idle busy unavailable malformed; do
  rm -rf /data/schedules
  rm -f /data/runs /data/failed-once /data/manual-once /data/speedtest-arguments /data/rtr-arguments /data/protection-checks /tmp/trigger_speedtest /tmp/trigger_rtr
  date -d '2026-10-01 09:26:00' +%s > /data/test-clock
  TEST_MANUAL=$(date -d '2026-10-01 09:34:00' +%s)
  TEST_END=$(date -d '2026-10-01 09:35:00' +%s)
  cat > /data/options.json <<'EOF'
{
  "speedtest":{"enabled":true,"minute":30,"server":"Automatisch auswählen","fallback_server":"Kein Ersatzserver"},
  "rtr":{"enabled":true,"minute":30,"server":"RTR https 100G AT #1"},
  "protection":{"enabled":true,"threshold_mbps":2,"password":"test-fixture-password"},
  "general":{"run_on_start":true,"jitter_minutes":0}
}
EOF
  bash "${RUN_SCRIPT:-netzmessung/run.sh}" < /dev/null > "/data/${TEST_PROTECTION}.log" 2>&1
  [ "$(grep -c '^check$' /data/protection-checks)" = 4 ]
  if [ "${TEST_PROTECTION}" = idle ]; then
    [ "$(grep -c '^speedtest$' /data/runs)" = 3 ]
    [ "$(grep -c '^rtr$' /data/runs)" = 2 ]
    if grep -q '"state":"skipped"' "/data/${TEST_PROTECTION}.log"; then exit 1; fi
    grep -q -- '--server_uuid 59557829-5a22-42ff-9dce-b0c450aa79fb' /data/rtr-arguments
  else
    # Both startup and scheduled tests skip. The manual request still executes.
    [ "$(grep -c '^speedtest$' /data/runs)" = 1 ]
    if grep -q '^rtr$' /data/runs; then exit 1; fi
    [ "$(grep -c '"state":"skipped"' "/data/${TEST_PROTECTION}.log")" = 4 ]
    if grep '"state":"skipped"' "/data/${TEST_PROTECTION}.log" | grep -q error_code; then exit 1; fi
    if [ "${TEST_PROTECTION}" = busy ]; then
      grep -q 'Internetnutzung 8 Mbit/s' "/data/${TEST_PROTECTION}.log"
    elif [ "${TEST_PROTECTION}" = unavailable ]; then
      grep -q 'Anmeldung am Router fehlgeschlagen' "/data/${TEST_PROTECTION}.log"
    fi
  fi
  if grep -q -- ' -s ' /data/speedtest-arguments; then exit 1; fi
  if grep -q 'test-fixture-password' "/data/${TEST_PROTECTION}.log"; then exit 1; fi
  expected=$(date -d '2026-10-01 10:30:00' +%s)
  [ "$(jq -r .nominal /data/schedules/speedtest.json)" = "${expected}" ]
  [ "$(jq -r .nominal /data/schedules/rtr.json)" = "${expected}" ]
done
echo 'Run-loop tests passed'
