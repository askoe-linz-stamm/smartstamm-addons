#!/usr/bin/env bash
# Calendar schedules with a fresh, symmetric random offset per measurement.
# Persist the pending slot before running it so restarts cannot repeat it.
declare -A SCHEDULE
SCHEDULE_DIR=${SCHEDULE_DIR:-/data/schedules}

schedule_offset() { # $1 maximum deviation in seconds
  echo "$(( ((RANDOM << 15) | RANDOM) % (2 * $1 + 1) - $1 ))"
}

schedule_local_time() {
  local text="$1" nominal actual wanted observed
  nominal=$(date -d "${text}" +%s) || return 1
  actual=$(date -d "@${nominal}" '+%Y-%m-%d %H:%M:%S') || return 1
  if [[ "${actual}" < "${text}" ]]; then
    # BusyBox maps a missing spring-forward time backwards. Move it forwards
    # by the size of the clock jump instead, e.g. 02:30 becomes 03:30.
    wanted=$(date -u -d "${text}" +%s) || return 1
    observed=$(date -u -d "${actual}" +%s) || return 1
    nominal=$((nominal + wanted - observed))
  fi
  echo "${nominal}"
}

schedule_save() {
  local name="$1" file="${SCHEDULE_DIR}/$1.json"
  mkdir -p "${SCHEDULE_DIR}" &&
    jq -cn --arg signature "${SCHEDULE[$name.signature]}" \
      --argjson nominal "${SCHEDULE[$name.nominal]}" --argjson due "${SCHEDULE[$name.due]}" \
      '{signature:$signature, nominal:$nominal, due:$due}' > "${file}.tmp" &&
    mv "${file}.tmp" "${file}"
}

schedule_next() {
  local name="$1" nominal="${SCHEDULE[$1.nominal]}" day text
  if [ "${SCHEDULE[$name.unit]}" = hours ]; then
    nominal=$((nominal + SCHEDULE[$name.interval] * 3600))
  else
    # Add calendar days in UTC, then reconstruct the local wall-clock time.
    # A day can contain 23 or 25 hours when daylight saving time changes.
    day=$(date -d "@${nominal}" +%Y-%m-%d) || return 1
    day=$(date -u -d "${day} 00:00:00" +%s) || return 1
    day=$(date -u -d "@$((day + SCHEDULE[$name.interval] * 86400))" +%Y-%m-%d) || return 1
    printf -v text '%s %02d:%02d:00' "${day}" "${SCHEDULE[$name.hour]}" "${SCHEDULE[$name.minute]}"
    nominal=$(schedule_local_time "${text}") || return 1
  fi
  SCHEDULE[$name.nominal]="${nominal}"
  SCHEDULE[$name.due]=$((nominal + $(schedule_offset "${SCHEDULE[$name.jitter]}")))
}

schedule_skip_past() { # Skip missed slots without catching up in a burst.
  local name="$1" now="$2" steps period
  if [ "${SCHEDULE[$name.unit]}" = hours ]; then
    period=$((SCHEDULE[$name.interval] * 3600))
    steps=$(((now - SCHEDULE[$name.nominal] - SCHEDULE[$name.jitter]) / period))
    if [ "${steps}" -gt 0 ]; then
      SCHEDULE[$name.nominal]=$((SCHEDULE[$name.nominal] + steps * period))
      SCHEDULE[$name.due]=$((SCHEDULE[$name.nominal] + $(schedule_offset "${SCHEDULE[$name.jitter]}")))
    fi
  fi
  while [ "${SCHEDULE[$name.due]}" -le "${now}" ]; do
    schedule_next "${name}" || return 1
  done
}

# $1 name, $2 interval, $3 unit (hours/days), $4 hour (daily), $5 minute,
# $6 deviation in minutes, $7 current epoch seconds. Empty minute disables it.
schedule_init() {
  local name="$1" interval="$2" unit="$3" hour="$4" minute="$5" jitter="$6" now="$7"
  local file="${SCHEDULE_DIR}/${name}.json" stored signature nominal="" due="" text timezone="${TZ:-}"
  SCHEDULE[$name.due]=""
  [ -n "${minute}" ] || return 0
  if [ -z "${timezone}" ] && [ -f /etc/localtime ]; then
    timezone=$(cksum < /etc/localtime) || return 1
    timezone=${timezone%% *}
  fi
  signature="${interval}:${unit}:${hour}:${minute}:${jitter}:${timezone:-UTC}"
  SCHEDULE[$name.signature]="${signature}"
  SCHEDULE[$name.interval]="${interval}"
  SCHEDULE[$name.unit]="${unit}"
  SCHEDULE[$name.hour]="${hour}"
  SCHEDULE[$name.minute]="${minute}"
  SCHEDULE[$name.jitter]=$((jitter * 60))
  if [ -f "${file}" ]; then
    stored=$(jq -er '[.signature, .nominal, .due] | @tsv' "${file}") || return 1
    read -r signature nominal due <<< "${stored}"
    if ! [[ "${nominal}" =~ ^[0-9]+$ && "${due}" =~ ^[0-9]+$ ]]; then
      bashio::log.error "Invalid schedule state in ${file}"
      return 1
    fi
  fi
  if [ "${signature}" = "${SCHEDULE[$name.signature]}" ] && [ -n "${nominal}" ]; then
    SCHEDULE[$name.nominal]="${nominal}"
    SCHEDULE[$name.due]="${due}"
  else
    if [ "${unit}" = hours ]; then
      # Anchor a new hourly schedule to the current hour's selected minute.
      text=$(date -d "@${now}" '+%M %S') || return 1
      read -r due nominal <<< "${text}"
      nominal=$((now - 10#$due * 60 - 10#$nominal + minute * 60))
    else
      text=$(date -d "@${now}" +%Y-%m-%d) || return 1
      printf -v text '%s %02d:%02d:00' "${text}" "${hour}" "${minute}"
      nominal=$(schedule_local_time "${text}") || return 1
    fi
    SCHEDULE[$name.nominal]="${nominal}"
    SCHEDULE[$name.due]=$((nominal + $(schedule_offset "${SCHEDULE[$name.jitter]}")))
  fi
  schedule_skip_past "${name}" "${now}" && schedule_save "${name}"
}

schedule_due() {
  [ -n "${SCHEDULE[$1.due]}" ] && [ "$2" -ge "${SCHEDULE[$1.due]}" ]
}

schedule_advance() { # Consume the pending slot before invoking its measurement.
  schedule_next "$1" && schedule_skip_past "$1" "$2" && schedule_save "$1"
}
