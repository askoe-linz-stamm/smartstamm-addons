#!/command/with-contenv bashio
# SmartStamm Netzmessung: runs Speedtest.net (official Ookla CLI)
# and RTR-Netztest (RMBT client) on configurable schedules and publishes the results
# as Home Assistant sensors through the Supervisor core API proxy.
# bashio enables errexit; a failed measurement must not end the add-on.
set +o errexit +o errtrace
set -o pipefail

OPTIONS=/data/options.json   # add-on options as written by the Supervisor
# shellcheck source=options.sh
source "$(dirname "${BASH_SOURCE[0]}")/options.sh"
options_upgrade "${OPTIONS}" || { bashio::log.error 'Die bisherigen Einstellungen konnten nicht umgestellt werden. Bitte das Add-on erneut starten.'; exit 1; }
load_options "${OPTIONS}" || { bashio::log.error "Cannot read Netzmessung options"; exit 1; }
# shellcheck source=schedule.sh
source "$(dirname "${BASH_SOURCE[0]}")/schedule.sh"
export HOME=/data            # keeps Ookla licence acceptance and the RMBT client UUID across restarts
BIN=/data/bin
API="http://supervisor/core/api"

# Measurement clients, downloaded once into /data/bin (see install_clients).
OOKLA_VERSION=1.2.0
RMBT_RELEASE=rmbt-client-cf5d85d   # tag in askoe-linz-stamm/smartstamm-addons, built from open-rmbt-client-cli commit cf5d85d5a48d5b70922749b38b799fe185601e11
RMBT_SHA256=c9b55ca9c956f56dd909ca3f15e1d9322a2d7a793ac59599af6ff8a03e038dbb

# Publish one sensor state. $1 entity id, $2 state, $3 attributes JSON object.
publish() {
  local entity="$1" state="$2" attrs="$3" body
  body=$(jq -cn --arg s "$state" --argjson a "$attrs" '{state:$s, attributes:$a}')
  if [ -f /data/dry_run ]; then echo "DRY ${entity} ${body}"; return 0; fi
  curl -sf -o /dev/null -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    -H "Content-Type: application/json" -d "${body}" "${API}/states/${entity}" \
    || bashio::log.warning "Publishing ${entity} failed"
}

# Consecutive failed runs per measurement. Together with a stable error code on
# the status sensor, SmartStamm turns lasting failures into GitHub issues.
SPEEDTEST_FAILS=0
RTR_FAILS=0

set_status() {   # $1 entity, $2 friendly name, $3 state, $4 message, on errors $5 code and $6 failed runs
  publish "$1" "$3" "$(jq -cn --arg n "$2" --arg m "$4" --arg t "$(date -Iseconds)" --arg c "${5:-}" --arg f "${6:-0}" \
    '{friendly_name:$n, icon:"mdi:speedometer", message:$m, updated:$t}
     + (if $c == "" then {} else {error_code:$c, failed_runs:($f | tonumber)} end)')"
}

# Download a file and check its SHA-256. $1 url, $2 target, $3 expected sha256
fetch_verified() {
  curl -sfL "$1" -o "$2.tmp" || return 1
  local sum; sum=$(sha256sum "$2.tmp" | cut -d' ' -f1)
  if [ "${sum}" != "$3" ]; then bashio::log.error "Checksum mismatch for $1: ${sum}"; rm -f "$2.tmp"; return 1; fi
  chmod +x "$2.tmp" && mv "$2.tmp" "$2"
}

install_clients() {
  mkdir -p "${BIN}"
  local arch; arch=$(uname -m)   # aarch64
  if [ ! -x "${BIN}/speedtest" ] || [ "$(cat "${BIN}/speedtest.version" 2>/dev/null)" != "${OOKLA_VERSION}" ]; then
    bashio::log.info "Downloading Ookla CLI ${OOKLA_VERSION} for ${arch}"
    curl -sfL "https://install.speedtest.net/app/cli/ookla-speedtest-${OOKLA_VERSION}-linux-${arch}.tgz" | tar xz -C "${BIN}" speedtest \
      && echo "${OOKLA_VERSION}" > "${BIN}/speedtest.version" || { bashio::log.error "Ookla CLI download failed"; return 1; }
  fi
  if [ ! -x "${BIN}/rmbt-client" ] || [ "$(cat "${BIN}/rmbt-client.version" 2>/dev/null)" != "${RMBT_RELEASE}" ]; then
    bashio::log.info "Downloading RMBT client ${RMBT_RELEASE} for ${arch}"
    fetch_verified "https://github.com/askoe-linz-stamm/smartstamm-addons/releases/download/${RMBT_RELEASE}/rmbt-client-${arch}" "${BIN}/rmbt-client" "${RMBT_SHA256}" \
      && echo "${RMBT_RELEASE}" > "${BIN}/rmbt-client.version" || { bashio::log.error "RMBT client download failed"; return 1; }
  fi
}

# ---------------------------------------------------------------- Speedtest.net
speedtest_json() {   # $1 server id; prints the JSON result line on success
  local server_options=()
  [ -n "$1" ] && server_options=(-s "$1")
  timeout 180 "${BIN}/speedtest" --accept-license --accept-gdpr -f json -p no "${server_options[@]}" 2>/dev/null | grep '"type":"result"' | tail -1
}

run_speedtest() {
  bashio::log.info "Speedtest.net: starting against server ${SPEEDTEST_SERVER:-automatic}"
  set_status sensor.speedtest_status "Speedtest.net Status" running "Messung läuft"
  local json used="${SPEEDTEST_SERVER:-automatic}"
  json=$(speedtest_json "${SPEEDTEST_SERVER}")
  if [ -z "${json}" ] && [ -n "${SPEEDTEST_FALLBACK}" ]; then
    bashio::log.warning "Speedtest.net: server ${SPEEDTEST_SERVER} failed, trying fallback ${SPEEDTEST_FALLBACK}"
    used="${SPEEDTEST_FALLBACK}"; json=$(speedtest_json "${SPEEDTEST_FALLBACK}")
  fi
  if [ -z "${json}" ]; then
    bashio::log.error "Speedtest.net: measurement failed on server ${used}"
    SPEEDTEST_FAILS=$((SPEEDTEST_FAILS + 1))
    set_status sensor.speedtest_status "Speedtest.net Status" error "Messung gegen Server ${used} fehlgeschlagen" measurement-failed "${SPEEDTEST_FAILS}"
    return 1
  fi
  # bandwidth is bytes/s in the CLI output; sensors report Mbit/s
  local down up ping
  down=$(echo "${json}" | jq -r '(.download.bandwidth * 8 / 1000000 * 100 | round) / 100')
  up=$(echo "${json}" | jq -r '(.upload.bandwidth * 8 / 1000000 * 100 | round) / 100')
  ping=$(echo "${json}" | jq -r '(.ping.latency * 10 | round) / 10')
  if ! [[ "${down}" =~ ^[0-9.]+$ && "${up}" =~ ^[0-9.]+$ && "${ping}" =~ ^[0-9.]+$ ]]; then
    bashio::log.error "Speedtest.net: unexpected result format"
    SPEEDTEST_FAILS=$((SPEEDTEST_FAILS + 1))
    set_status sensor.speedtest_status "Speedtest.net Status" error "Ergebnis nicht lesbar" result-format "${SPEEDTEST_FAILS}"
    return 1
  fi
  SPEEDTEST_FAILS=0
  local common; common=$(echo "${json}" | jq -c --arg t "$(date -Iseconds)" '{
    server_name: .server.name, server_location: .server.location, server_country: .server.country,
    server_id: (.server.id | tostring), server_host: .server.host, isp: .isp,
    share_url: .result.url, measured_at: $t, attribution: "Data retrieved from Speedtest.net by Ookla"}')
  publish sensor.speedtest_download "${down}" "$(echo "${common}" | jq -c --argjson j "${json}" '. + {friendly_name:"SpeedTest Download", unit_of_measurement:"Mbit/s", device_class:"data_rate", state_class:"measurement", icon:"mdi:download-network", bytes_received:$j.download.bytes, latency_loaded_ms:$j.download.latency.iqm}')"
  publish sensor.speedtest_upload "${up}" "$(echo "${common}" | jq -c --argjson j "${json}" '. + {friendly_name:"SpeedTest Upload", unit_of_measurement:"Mbit/s", device_class:"data_rate", state_class:"measurement", icon:"mdi:upload-network", bytes_sent:$j.upload.bytes, latency_loaded_ms:$j.upload.latency.iqm}')"
  publish sensor.speedtest_ping "${ping}" "$(echo "${common}" | jq -c --argjson j "${json}" '. + {friendly_name:"SpeedTest Ping", unit_of_measurement:"ms", device_class:"duration", state_class:"measurement", icon:"mdi:timer-outline", jitter_ms:$j.ping.jitter, packet_loss:$j.packetLoss}')"
  set_status sensor.speedtest_status "Speedtest.net Status" ok "Download ${down} Mbit/s, Upload ${up} Mbit/s, Ping ${ping} ms"
  bashio::log.info "Speedtest.net: down ${down} Mbit/s, up ${up} Mbit/s, ping ${ping} ms, server ${used}, $(echo "${json}" | jq -r .result.url)"
}

# ---------------------------------------------------------------- RTR-Netztest
run_rtr() {
  bashio::log.info "RTR-Netztest: starting against ${RTR_CONTROL}"
  set_status sensor.rtr_netztest_status "RTR-Netztest Status" running "Messung läuft"
  local out rc server_options=()
  [ -n "${RTR_SERVER_UUID}" ] && server_options=(--server_uuid "${RTR_SERVER_UUID}")
  out=$(timeout 300 "${BIN}/rmbt-client" --host "${RTR_CONTROL}" --type CLI --platform Linux --model "${RTR_MODEL}" --nettype 98 "${server_options[@]}" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    bashio::log.error "RTR-Netztest: client exited with ${rc}: $(echo "${out}" | tail -3 | tr '\n' ' ')"
    RTR_FAILS=$((RTR_FAILS + 1))
    set_status sensor.rtr_netztest_status "RTR-Netztest Status" error "Client-Fehler ${rc}: $(echo "${out}" | grep -iE 'error|failed' | tail -1)" client-exit "${RTR_FAILS}"
    return 1
  fi
  # parse the "=== Results ===" block of the client output
  local down up ping_med ping_min pings share server threads
  down=$(echo "${out}" | awk '/^Download:/{print $2}')
  up=$(echo "${out}" | awk '/^Upload:/{print $2}')
  ping_med=$(echo "${out}" | awk '/^Ping \(median\):/{print $3}')
  ping_min=$(echo "${out}" | awk '/^Ping \(min\):/{print $3}')
  pings=$(echo "${out}" | awk '/^Ping \(min\):/{gsub(/[()]/,"",$5); print $5}')
  share=$(echo "${out}" | awk '/^Result:/{print $2}')
  server=$(echo "${out}" | awk '/^Server:/{print $2}')
  threads=$(echo "${out}" | awk '/^Download:/{for(i=1;i<=NF;i++) if($i ~ /^thread/) print $(i-1)}' | head -1)
  if [ -z "${down}" ] || [ -z "${up}" ] || [ -z "${ping_med}" ]; then
    bashio::log.error "RTR-Netztest: could not parse results: $(echo "${out}" | tail -8 | tr '\n' ' ')"
    RTR_FAILS=$((RTR_FAILS + 1))
    set_status sensor.rtr_netztest_status "RTR-Netztest Status" error "Ergebnis nicht lesbar" result-format "${RTR_FAILS}"
    return 1
  fi
  RTR_FAILS=0
  local common; common=$(jq -cn --arg srv "${server}" --arg url "${share}" --arg t "$(date -Iseconds)" --arg th "${threads:-}" \
    '{server:$srv, share_url:$url, measured_at:$t, threads:$th, attribution:"RTR-Netztest (RMBT), RTR-GmbH"}')
  publish sensor.rtr_netztest_download "${down}" "$(echo "${common}" | jq -c '. + {friendly_name:"RTR-Netztest Download", unit_of_measurement:"Mbit/s", device_class:"data_rate", state_class:"measurement", icon:"mdi:download-network"}')"
  publish sensor.rtr_netztest_upload "${up}" "$(echo "${common}" | jq -c '. + {friendly_name:"RTR-Netztest Upload", unit_of_measurement:"Mbit/s", device_class:"data_rate", state_class:"measurement", icon:"mdi:upload-network"}')"
  publish sensor.rtr_netztest_ping "${ping_med}" "$(echo "${common}" | jq -c --arg mn "${ping_min}" --arg n "${pings}" '. + {friendly_name:"RTR-Netztest Ping", unit_of_measurement:"ms", device_class:"duration", state_class:"measurement", icon:"mdi:timer-outline", ping_min:($mn|tonumber), pings:($n|tonumber? // $n)}')"
  set_status sensor.rtr_netztest_status "RTR-Netztest Status" ok "Download ${down} Mbit/s, Upload ${up} Mbit/s, Ping ${ping_med} ms"
  bashio::log.info "RTR-Netztest: down ${down} Mbit/s, up ${up} Mbit/s, ping ${ping_med} ms, ${share}"
}

# One background sampler serves both schedules, avoiding competing router logins.
PROTECTION_SNAPSHOT=/tmp/netzmessung-traffic.json
PROTECTION_PID=""
protection_stop() {
  if [ -n "${PROTECTION_PID}" ]; then
    kill "${PROTECTION_PID}" 2>/dev/null
    wait "${PROTECTION_PID}" 2>/dev/null
    PROTECTION_PID=""
  fi
  rm -f "${PROTECTION_SNAPSHOT}"
}
trap protection_stop EXIT

protection_prepare() { # Start before the three-minute window, allowing login time.
  [ "${PROTECTION_ENABLED}" = true ] || return 0
  local now="$1" measurement due needed=false entity name
  for measurement in speedtest rtr; do
    due="${SCHEDULE[$measurement.due]}"
    if [ -n "${due}" ] && [ "$((due - now))" -le 210 ]; then
      needed=true
      if [ -z "${SCHEDULE[$measurement.checking]:-}" ]; then
        if [ "${measurement}" = speedtest ]; then
          entity=sensor.speedtest_status; name='Speedtest.net Status'
        else
          entity=sensor.rtr_netztest_status; name='RTR-Netztest Status'
        fi
        set_status "${entity}" "${name}" checking 'Internetnutzung wird vor dem Termin über drei Minuten geprüft'
        SCHEDULE[$measurement.checking]=true
      fi
    fi
  done
  if [ "${needed}" = true ]; then
    if [ -z "${PROTECTION_PID}" ]; then
      protection_stop
      python3 "$(dirname "${BASH_SOURCE[0]}")/router.py" monitor "${OPTIONS}" "${PROTECTION_SNAPSHOT}" >/dev/null 2>&1 &
      PROTECTION_PID=$!
    fi
  else
    protection_stop
  fi
}

# Guard only automatic measurements. Manual requests explicitly bypass it.
# Unknown, missing or incomplete router data must never permit a protected test.
run_automatic() {
  local measurement="$1" mode="${2:-startup}" entity name result rc state average reason message
  if [ "${PROTECTION_ENABLED}" = true ]; then
    if [ "${measurement}" = speedtest ]; then
      entity=sensor.speedtest_status; name='Speedtest.net Status'
    else
      entity=sensor.rtr_netztest_status; name='RTR-Netztest Status'
    fi
    if [ "${mode}" = scheduled ]; then
      result=$(python3 "$(dirname "${BASH_SOURCE[0]}")/router.py" check "${PROTECTION_SNAPSHOT}" "${PROTECTION_THRESHOLD_MBPS}" 2>/dev/null); rc=$?
    else
      set_status "${entity}" "${name}" checking 'Internetnutzung wird drei Minuten lang geprüft'
      result=$(python3 "$(dirname "${BASH_SOURCE[0]}")/router.py" "${OPTIONS}" 2>/dev/null); rc=$?
    fi
    state=$(jq -r '.state // empty' <<< "${result}" 2>/dev/null)
    average=$(jq -er '(.window_averages_mbps | max) // .average_mbps | select(type == "number" and . >= 0)' <<< "${result}" 2>/dev/null)
    if [ "${rc}" -ne 0 ] || [ "${state}" != idle ] || [ -z "${average}" ]; then
      if [ "${rc}" = 2 ] && [ "${state}" = busy ] && [ -n "${average}" ]; then
        message="Messung übersprungen. Internetnutzung ${average} Mbit/s im höchsten Minutenmittel, Schwelle ${PROTECTION_THRESHOLD_MBPS} Mbit/s."
      else
        reason=$(jq -r '.reason // empty' <<< "${result}" 2>/dev/null)
        case "${reason}" in
          router-password-missing) message='Messung übersprungen. Das Routerpasswort fehlt.' ;;
          router-unauthorized) message='Messung übersprungen. Anmeldung am Router fehlgeschlagen.' ;;
          router-unreachable) message='Messung übersprungen. Der Router ist nicht erreichbar.' ;;
          router-traffic-invalid|router-traffic-stale|router-traffic-incomplete|router-clock-changed) message='Messung übersprungen. Keine aktuellen Internetnutzungsdaten vom Router.' ;;
          *) message='Messung übersprungen. Die Internetnutzung konnte nicht zuverlässig geprüft werden.' ;;
        esac
      fi
      set_status "${entity}" "${name}" skipped "${message}"
      bashio::log.info "${measurement}: ${message}"
      return 0
    fi
  fi
  "run_${measurement}"
}

# ---------------------------------------------------------------- scheduling
# Manual trigger via `hassio.addon_stdin`: input "speedtest" or "rtr" starts that
# measurement, anything else starts both.
( while read -r line; do
    case "${line}" in
      speedtest) touch /tmp/trigger_speedtest ;;
      rtr)       touch /tmp/trigger_rtr ;;
      *)         touch /tmp/trigger_speedtest /tmp/trigger_rtr ;;
    esac
  done ) <&0 &

bashio::log.info "Netzmessung started; Speedtest.net at minute ${SPEEDTEST_MINUTE:-off} (server ${SPEEDTEST_SERVER:-automatic}, fallback ${SPEEDTEST_FALLBACK:-none}), RTR-Netztest at minute ${RTR_MINUTE:-off}; deviation ±${JITTER_MINUTES} minutes"
until install_clients; do bashio::log.warning "Retrying client download in 60 s"; sleep 60; done
if [ "${RUN_ON_START}" = "true" ]; then
  [ -n "${SPEEDTEST_MINUTE}" ] && run_automatic speedtest
  [ -n "${RTR_MINUTE}" ] && run_automatic rtr
fi
# Missing new options retain hourly schedules on existing installations.
now=$(date +%s)
for measurement in speedtest rtr; do
  prefix="${measurement^^}"
  interval_key="${prefix}_INTERVAL"; unit_key="${prefix}_INTERVAL_UNIT"
  hour_key="${prefix}_HOUR"; minute_key="${prefix}_MINUTE"
  interval="${!interval_key}"; unit="${!unit_key}"
  target_hour="${!hour_key}"; target_minute="${!minute_key}"
  schedule_init "${measurement}" "${interval}" "${unit}" "${target_hour}" "${target_minute}" "${JITTER_MINUTES}" "${now}" \
    || { bashio::log.error "Cannot initialize ${measurement} schedule"; exit 1; }
  [ -n "${SCHEDULE[$measurement.due]}" ] && bashio::log.info "${measurement}: every ${interval} ${unit}; next measurement $(date -d "@${SCHEDULE[$measurement.due]}" -Iseconds)"
done
while true; do
  protection_prepare "$(date +%s)"
  if [ -f /tmp/trigger_speedtest ]; then rm -f /tmp/trigger_speedtest; bashio::log.info "Manual trigger: Speedtest.net"; run_speedtest; fi
  if [ -f /tmp/trigger_rtr ]; then rm -f /tmp/trigger_rtr; bashio::log.info "Manual trigger: RTR-Netztest"; run_rtr; fi
  for measurement in speedtest rtr; do
    now=$(date +%s)
    if schedule_due "${measurement}" "${now}"; then
      schedule_advance "${measurement}" "${now}" \
        || { bashio::log.error "Cannot advance ${measurement} schedule"; exit 1; }
      run_automatic "${measurement}" scheduled
      SCHEDULE[$measurement.checking]=""
      bashio::log.info "${measurement}: next measurement $(date -d "@${SCHEDULE[$measurement.due]}" -Iseconds)"
    fi
  done
  sleep 10
done
