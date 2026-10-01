#!/usr/bin/env bash
# Verify grouped options and the one-time migration without Supervisor access.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=netzmessung/options.sh
source netzmessung/options.sh
TEST_TMP=$(mktemp -d)
trap 'rm -rf "${TEST_TMP}"' EXIT
OPTIONS="${TEST_TMP}/options.json"

assert_equal() {
  if [ "$1" != "$2" ]; then
    printf 'FAIL: %s, expected %s, got %s\n' "$3" "$2" "$1" >&2
    exit 1
  fi
}

printf '{}\n' > "${OPTIONS}"
load_options "${OPTIONS}"
assert_equal "${OPTIONS_LEGACY}" false 'new install has no legacy options'
assert_equal "${SPEEDTEST_MINUTE}" 0 'default Speedtest minute'
assert_equal "${SPEEDTEST_INTERVAL}" 1 'default Speedtest interval'
assert_equal "${SPEEDTEST_INTERVAL_UNIT}" hours 'default Speedtest interval unit'
assert_equal "${SPEEDTEST_HOUR}" 0 'default Speedtest hour'
assert_equal "${SPEEDTEST_SERVER}" 818 'default Speedtest server'
assert_equal "${SPEEDTEST_FALLBACK}" 73500 'default Speedtest fallback'
assert_equal "${RTR_MINUTE}" 30 'default RTR minute'
assert_equal "${RTR_INTERVAL}" 1 'default RTR interval'
assert_equal "${RTR_INTERVAL_UNIT}" hours 'default RTR interval unit'
assert_equal "${RTR_HOUR}" 0 'default RTR hour'
assert_equal "${RTR_CONTROL}" https://c01.netztest.at 'default RTR control server'
assert_equal "${RTR_MODEL}" 'Home Assistant Green' 'default RTR model'
assert_equal "${RTR_SERVER_UUID}" '' 'automatic RTR server'
assert_equal "${RUN_ON_START}" true 'default startup measurement'
assert_equal "${JITTER_MINUTES}" 3 'default deviation'
assert_equal "${PROTECTION_ENABLED}" false 'protection requires configuring access'
assert_equal "${PROTECTION_THRESHOLD_MBPS}" 2 'default traffic threshold'
assert_equal "${PROTECTION_ROUTER_URL}" http://192.168.3.1 'default router address'
assert_equal "${PROTECTION_ROUTER_PASSWORD}" '' 'no default router credential'

# Existing settings beat grouped defaults added by Supervisor during update.
cat > "${OPTIONS}" <<'EOF'
{
  "speedtest_minute":17,"speedtest_interval":2,"speedtest_interval_unit":"days",
  "speedtest_hour":18,"speedtest_server_id":12345,"speedtest_fallback_server_id":null,
  "rtr_minute":null,"rtr_interval":6,"rtr_interval_unit":"hours","rtr_hour":2,
  "rtr_control_server":"https://control.example.com","rtr_model":"Existing device",
  "run_on_start":false,"jitter_minutes":0,
  "speedtest":{"enabled":true,"interval":1,"interval_unit":"Stunden","hour":0,"minute":0,
    "server":"LIWEST, Linz, Österreich, ID 818","fallback_server":"Energie AG, Linz, Österreich, ID 73500"},
  "rtr":{"enabled":true,"minute":30},
  "general":{"run_on_start":true,"jitter_minutes":3}
}
EOF
load_options "${OPTIONS}"
assert_equal "${OPTIONS_LEGACY}" true 'legacy migration detected'
assert_equal "${SPEEDTEST_MINUTE}" 17 'legacy minute overrides new default'
assert_equal "${SPEEDTEST_INTERVAL}" 2 'legacy interval retained'
assert_equal "${SPEEDTEST_INTERVAL_UNIT}" days 'legacy daily unit retained'
assert_equal "${SPEEDTEST_HOUR}" 18 'legacy daily hour retained'
assert_equal "${SPEEDTEST_SERVER}" 12345 'unlisted legacy server retained'
assert_equal "${SPEEDTEST_FALLBACK}" '' 'legacy null fallback stays disabled'
assert_equal "${RTR_MINUTE}" '' 'legacy null minute stays disabled'
assert_equal "${RTR_INTERVAL}" 6 'legacy RTR interval retained'
assert_equal "${RTR_INTERVAL_UNIT}" hours 'legacy RTR unit retained'
assert_equal "${RTR_HOUR}" 2 'legacy RTR hour retained'
assert_equal "${RTR_CONTROL}" https://control.example.com 'legacy control server retained'
assert_equal "${RTR_MODEL}" 'Existing device' 'legacy model retained'
assert_equal "${RUN_ON_START}" false 'false startup setting retained'
assert_equal "${JITTER_MINUTES}" 0 'zero deviation retained'

before=$(cksum < "${OPTIONS}")
options_migrate "${OPTIONS}" > "${TEST_TMP}/migrated.json"
assert_equal "$(cksum < "${OPTIONS}")" "${before}" 'migration does not mutate input'
jq -e 'keys == ["general","protection","rtr","speedtest"] and
  .speedtest.custom_server_id == 12345 and .rtr.enabled == false and
  .speedtest.fallback_server == "Kein Ersatzserver"' "${TEST_TMP}/migrated.json" > /dev/null
options_migrate "${TEST_TMP}/migrated.json" > "${TEST_TMP}/again.json"
assert_equal "$(jq -Sc . "${TEST_TMP}/migrated.json")" "$(jq -Sc . "${TEST_TMP}/again.json")" 'migration is idempotent'
load_options "${TEST_TMP}/migrated.json"
assert_equal "${OPTIONS_LEGACY}" false 'migration removes legacy overrides'
assert_equal "${SPEEDTEST_SERVER}" 12345 'custom server works after migration'
assert_equal "${RTR_MINUTE}" '' 'disabled schedule works after migration'

# Omitted optional legacy minutes and fallback must not become enabled defaults.
printf '{"speedtest_minute":0,"speedtest_server_id":818}\n' > "${OPTIONS}"
load_options "${OPTIONS}"
assert_equal "${SPEEDTEST_MINUTE}" 0 'zero remains an active minute'
assert_equal "${RTR_MINUTE}" '' 'missing legacy minute stays disabled'
assert_equal "${SPEEDTEST_FALLBACK}" '' 'missing legacy fallback stays disabled'

printf '{"speedtest_minute":0,"speedtest_server_id":818,"speedtest_fallback_server_id":54321}\n' > "${OPTIONS}"
load_options "${OPTIONS}"
assert_equal "${SPEEDTEST_FALLBACK}" 54321 'unlisted legacy fallback retained'

cat > "${OPTIONS}" <<'EOF'
{
  "speedtest":{"enabled":false,"minute":42,"server":"Automatisch auswählen","fallback_server":"Kein Ersatzserver"},
  "rtr":{"enabled":true,"interval":3,"interval_unit":"Tage","hour":20,"minute":15,
    "server":"RTR https 100G AT #1"},
  "protection":{"enabled":true,"threshold_mbps":1.5,"router_url":"http://router.example.com","password":"test-only \"quoted\" password\nnext line"},
  "general":{"run_on_start":false,"jitter_minutes":0}
}
EOF
load_options "${OPTIONS}"
assert_equal "${SPEEDTEST_MINUTE}" '' 'new enabled switch disables schedule'
assert_equal "${SPEEDTEST_SERVER}" '' 'automatic server omits explicit ID'
assert_equal "${SPEEDTEST_FALLBACK}" '' 'no fallback omits explicit ID'
assert_equal "${RTR_MINUTE}" 15 'grouped RTR minute'
assert_equal "${RTR_INTERVAL}" 3 'grouped RTR interval'
assert_equal "${RTR_INTERVAL_UNIT}" days 'German units map to scheduler units'
assert_equal "${RTR_HOUR}" 20 'grouped RTR hour'
assert_equal "${RTR_SERVER_UUID}" 59557829-5a22-42ff-9dce-b0c450aa79fb 'named RTR choice resolves UUID'
assert_equal "${PROTECTION_ENABLED}" true 'protection enabled'
assert_equal "${PROTECTION_THRESHOLD_MBPS}" 1.5 'fractional traffic threshold'
assert_equal "${PROTECTION_ROUTER_URL}" http://router.example.com 'custom router address'
if [ "${PROTECTION_ROUTER_PASSWORD}" != $'test-only "quoted" password\nnext line' ]; then
  echo 'FAIL: password was not preserved exactly' >&2
  exit 1
fi
assert_equal "${RUN_ON_START}" false 'grouped false startup setting'
assert_equal "${JITTER_MINUTES}" 0 'grouped zero deviation'

# A failed Supervisor write must preserve the old configuration for a retry.
jq '. + {run_on_start:true}' "${OPTIONS}" > "${TEST_TMP}/upgrade.json"
export SUPERVISOR_TOKEN=test-only-token
UPGRADE_RESULT=fail
curl() {
  [ "${*: -1}" = http://supervisor/addons/self/options ] || return 1
  cat > "${TEST_TMP}/request.json"
  [ "${UPGRADE_RESULT}" = ok ] || return 1
  echo '{"result":"ok"}'
}
before=$(cksum < "${TEST_TMP}/upgrade.json")
if options_upgrade "${TEST_TMP}/upgrade.json"; then
  echo 'FAIL: unsuccessful persistence must fail the upgrade' >&2
  exit 1
fi
assert_equal "$(cksum < "${TEST_TMP}/upgrade.json")" "${before}" 'failed upgrade leaves options untouched'
UPGRADE_RESULT=ok
options_upgrade "${TEST_TMP}/upgrade.json"
jq -e '.options | keys == ["general","protection","rtr","speedtest"]' "${TEST_TMP}/request.json" > /dev/null
assert_equal "$(jq -r '.general.run_on_start' "${TEST_TMP}/upgrade.json")" true 'saved legacy startup value retained'
assert_equal "$(jq -r '.protection.password' "${TEST_TMP}/upgrade.json")" "${PROTECTION_ROUTER_PASSWORD}" 'upgrade preserves password'
UPGRADE_RESULT=fail
options_upgrade "${TEST_TMP}/upgrade.json"

echo 'Options migration tests passed'
