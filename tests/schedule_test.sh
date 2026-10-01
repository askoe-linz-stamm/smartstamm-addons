#!/usr/bin/env bash
# Run in Alpine with bash, jq and tzdata. No network measurements are performed.
set -euo pipefail
cd "$(dirname "$0")/.."
export TZ=Europe/Vienna
SCHEDULE_DIR=$(mktemp -d)
trap 'rm -rf "${SCHEDULE_DIR}"' EXIT
bashio::log.error() { echo "$*" >&2; }
# shellcheck source=../netzmessung/schedule.sh
source netzmessung/schedule.sh

assert_eq() {
  if [ "$1" != "$2" ]; then
    echo "FAIL $3: expected $2, got $1" >&2
    exit 1
  fi
}
epoch() { date -d "$1" +%s; }
assert_time() { assert_eq "${SCHEDULE[$1.due]}" "$(epoch "$2")" "$3"; }

# Exercise the real random generator, then fix offsets to test both boundaries.
negative=0; positive=0
for ((i=0; i<100; i++)); do
  offset=$(schedule_offset 180)
  [ "${offset}" -ge -180 ] && [ "${offset}" -le 180 ]
  if [ "${offset}" -lt 0 ]; then negative=1; fi
  if [ "${offset}" -gt 0 ]; then positive=1; fi
done
assert_eq "${negative}:${positive}" 1:1 'random offsets have both signs'
assert_eq "$(schedule_offset 0)" 0 'zero deviation'
offset=0
schedule_offset() { echo "${offset}"; }

schedule_init disabled 1 hours 0 '' 3 "$(epoch '2026-10-01 09:00:00')"
if schedule_due disabled "$(epoch '2026-10-02 09:00:00')"; then exit 1; fi

schedule_init hourly 1 hours 0 30 0 "$(epoch '2026-10-01 09:15:00')"
assert_time hourly '2026-10-01 09:30:00' 'hourly target'
if schedule_due hourly "$(epoch '2026-10-01 09:29:59')"; then exit 1; fi
schedule_due hourly "$(epoch '2026-10-01 09:30:00')"
schedule_advance hourly "$(epoch '2026-10-01 09:30:00')"
assert_time hourly '2026-10-01 10:30:00' 'once per slot'

offset=-180
schedule_init early 1 hours 0 0 3 "$(epoch '2026-10-01 09:55:00')"
assert_time early '2026-10-01 09:57:00' 'early run across the hour boundary'
schedule_advance early "$(epoch '2026-10-01 09:57:00')"
offset=180
schedule_init early 1 hours 0 0 3 "$(epoch '2026-10-01 09:58:00')"
assert_time early '2026-10-01 10:57:00' 'restart retains offset and consumed slot'
schedule_init late 1 hours 0 59 3 "$(epoch '2026-10-01 09:58:00')"
assert_time late '2026-10-01 10:02:00' 'late run across the hour boundary'

offset=0
schedule_init six_hourly 6 hours 0 30 0 "$(epoch '2026-10-01 09:15:00')"
schedule_advance six_hourly "$(epoch '2026-10-01 09:30:00')"
assert_time six_hourly '2026-10-01 15:30:00' 'six-hour interval'
schedule_init six_hourly 6 hours 0 30 0 "$(epoch '2026-10-04 16:00:00')"
assert_time six_hourly '2026-10-04 21:30:00' 'downtime retains hourly phase'

schedule_init daily 1 days 18 30 0 "$(epoch '2026-10-01 09:15:00')"
assert_time daily '2026-10-01 18:30:00' 'daily hour and minute'
schedule_advance daily "$(epoch '2026-10-01 18:30:00')"
assert_time daily '2026-10-02 18:30:00' 'daily advancement'
schedule_init daily 2 days 18 30 0 "$(epoch '2026-12-31 09:15:00')"
schedule_advance daily "$(epoch '2026-12-31 18:30:00')"
assert_time daily '2027-01-02 18:30:00' 'two-day interval across year boundary'
schedule_init daily 2 days 18 30 0 "$(epoch '2027-01-09 19:00:00')"
assert_time daily '2027-01-10 18:30:00' 'missed daily slots are skipped'

offset=-180
schedule_init midnight 1 days 0 0 3 "$(epoch '2026-10-01 20:00:00')"
assert_time midnight '2026-10-01 23:57:00' 'daily jitter across midnight'
offset=0
schedule_init spring 1 days 8 30 0 "$(epoch '2026-03-28 08:00:00')"
before=${SCHEDULE[spring.nominal]}
schedule_advance spring "$(epoch '2026-03-28 08:30:00')"
assert_time spring '2026-03-29 08:30:00' 'spring keeps wall-clock time'
assert_eq "$((${SCHEDULE[spring.nominal]} - before))" 82800 '23-hour calendar day'
schedule_init autumn 1 days 8 30 0 "$(epoch '2026-10-24 08:00:00')"
before=${SCHEDULE[autumn.nominal]}
schedule_advance autumn "$(epoch '2026-10-24 08:30:00')"
assert_time autumn '2026-10-25 08:30:00' 'autumn keeps wall-clock time'
assert_eq "$((${SCHEDULE[autumn.nominal]} - before))" 90000 '25-hour calendar day'
schedule_init missing_hour 1 days 2 30 0 "$(epoch '2026-03-28 01:00:00')"
schedule_advance missing_hour "$(epoch '2026-03-28 02:30:00')"
assert_time missing_hour '2026-03-29 03:30:00' 'missing hour shifts forwards'
schedule_advance missing_hour "$(epoch '2026-03-29 03:30:00')"
assert_time missing_hour '2026-03-30 02:30:00' 'returns to configured hour'

schedule_init timezone_change 1 days 18 30 0 "$(epoch '2026-10-01 09:00:00')"
export TZ=UTC
schedule_init timezone_change 1 days 18 30 0 "$(epoch '2026-10-01 09:00:00')"
assert_time timezone_change '2026-10-01 18:30:00' 'timezone change resets local target'

echo 'Schedule tests passed'
