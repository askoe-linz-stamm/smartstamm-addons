#!/command/with-contenv bashio
# SmartStamm Netzmessung: runs Speedtest.net (official Ookla CLI, fixed server)
# and RTR-Netztest (RMBT client) on an hourly schedule and publishes the results
# as Home Assistant sensors through the Supervisor core API proxy.
# bashio enables errexit; a failed measurement must not end the add-on.
set +o errexit +o errtrace
set -o pipefail

OPTIONS=/data/options.json   # add-on options as written by the Supervisor
opt() { jq -r "$1 // empty" "${OPTIONS}"; }
SPEEDTEST_MINUTE=$(opt .speedtest_minute)
SPEEDTEST_SERVER=$(opt .speedtest_server_id)
SPEEDTEST_FALLBACK=$(opt .speedtest_fallback_server_id)
RTR_MINUTE=$(opt .rtr_minute)
RTR_CONTROL=$(opt .rtr_control_server); RTR_CONTROL=${RTR_CONTROL:-https://c01.netztest.at}
RTR_MODEL=$(opt .rtr_model); RTR_MODEL=${RTR_MODEL:-Home Assistant Green}
RUN_ON_START=$(jq -r 'if .run_on_start == null then true else .run_on_start end' "${OPTIONS}")
export HOME=/data            # keeps Ookla licence acceptance and the RMBT client UUID across restarts
BIN=/data/bin
API="http://supervisor/core/api"

# Measurement clients, downloaded once into /data/bin (see install_clients).
OOKLA_VERSION=1.2.0
RMBT_RELEASE=rmbt-client-cb87ff8   # tag in askoe-linz-stamm/smartstamm-addons, built from open-rmbt-client-cli commit cb87ff88235a2b075d61c9a57e36a2fa332aaf11
RMBT_SHA256=1dadffcec7c2b7546f5b54f46e30d04fcae33a5b64c397b0f63833bda76f2ba4

# Publish one sensor state. $1 entity id, $2 state, $3 attributes JSON object.
publish() {
  local entity="$1" state="$2" attrs="$3" body
  body=$(jq -cn --arg s "$state" --argjson a "$attrs" '{state:$s, attributes:$a}')
  if [ -f /data/dry_run ]; then echo "DRY ${entity} ${body}"; return 0; fi
  curl -sf -o /dev/null -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    -H "Content-Type: application/json" -d "${body}" "${API}/states/${entity}" \
    || bashio::log.warning "Publishing ${entity} failed"
}

set_status() {   # $1 entity, $2 friendly name, $3 state, $4 message
  publish "$1" "$3" "$(jq -cn --arg n "$2" --arg m "$4" --arg t "$(date -Iseconds)" \
    '{friendly_name:$n, icon:"mdi:speedometer", message:$m, updated:$t}')"
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
  timeout 180 "${BIN}/speedtest" --accept-license --accept-gdpr -f json -p no -s "$1" 2>/dev/null | grep '"type":"result"' | tail -1
}

run_speedtest() {
  bashio::log.info "Speedtest.net: starting against server ${SPEEDTEST_SERVER}"
  set_status sensor.speedtest_status "Speedtest.net Status" running "Messung läuft"
  local json used="${SPEEDTEST_SERVER}"
  json=$(speedtest_json "${SPEEDTEST_SERVER}")
  if [ -z "${json}" ] && [ -n "${SPEEDTEST_FALLBACK}" ]; then
    bashio::log.warning "Speedtest.net: server ${SPEEDTEST_SERVER} failed, trying fallback ${SPEEDTEST_FALLBACK}"
    used="${SPEEDTEST_FALLBACK}"; json=$(speedtest_json "${SPEEDTEST_FALLBACK}")
  fi
  if [ -z "${json}" ]; then
    bashio::log.error "Speedtest.net: measurement failed on server ${used}"
    set_status sensor.speedtest_status "Speedtest.net Status" error "Messung gegen Server ${used} fehlgeschlagen"
    return 1
  fi
  # bandwidth is bytes/s in the CLI output; sensors report Mbit/s
  local down up ping
  down=$(echo "${json}" | jq -r '(.download.bandwidth * 8 / 1000000 * 100 | round) / 100')
  up=$(echo "${json}" | jq -r '(.upload.bandwidth * 8 / 1000000 * 100 | round) / 100')
  ping=$(echo "${json}" | jq -r '(.ping.latency * 10 | round) / 10')
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
  local out rc
  out=$(timeout 300 "${BIN}/rmbt-client" --host "${RTR_CONTROL}" --type CLI --platform Linux --model "${RTR_MODEL}" --nettype 98 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    bashio::log.error "RTR-Netztest: client exited with ${rc}: $(echo "${out}" | tail -3 | tr '\n' ' ')"
    set_status sensor.rtr_netztest_status "RTR-Netztest Status" error "Client-Fehler ${rc}: $(echo "${out}" | grep -iE 'error|failed' | tail -1)"
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
    set_status sensor.rtr_netztest_status "RTR-Netztest Status" error "Ergebnis nicht lesbar"
    return 1
  fi
  local common; common=$(jq -cn --arg srv "${server}" --arg url "${share}" --arg t "$(date -Iseconds)" --arg th "${threads:-}" \
    '{server:$srv, share_url:$url, measured_at:$t, threads:$th, attribution:"RTR-Netztest (RMBT), RTR-GmbH"}')
  publish sensor.rtr_netztest_download "${down}" "$(echo "${common}" | jq -c '. + {friendly_name:"RTR-Netztest Download", unit_of_measurement:"Mbit/s", device_class:"data_rate", state_class:"measurement", icon:"mdi:download-network"}')"
  publish sensor.rtr_netztest_upload "${up}" "$(echo "${common}" | jq -c '. + {friendly_name:"RTR-Netztest Upload", unit_of_measurement:"Mbit/s", device_class:"data_rate", state_class:"measurement", icon:"mdi:upload-network"}')"
  publish sensor.rtr_netztest_ping "${ping_med}" "$(echo "${common}" | jq -c --arg mn "${ping_min}" --arg n "${pings}" '. + {friendly_name:"RTR-Netztest Ping", unit_of_measurement:"ms", device_class:"duration", state_class:"measurement", icon:"mdi:timer-outline", ping_min:($mn|tonumber), pings:($n|tonumber? // $n)}')"
  set_status sensor.rtr_netztest_status "RTR-Netztest Status" ok "Download ${down} Mbit/s, Upload ${up} Mbit/s, Ping ${ping_med} ms"
  bashio::log.info "RTR-Netztest: down ${down} Mbit/s, up ${up} Mbit/s, ping ${ping_med} ms, ${share}"
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

bashio::log.info "Netzmessung started; Speedtest.net at minute ${SPEEDTEST_MINUTE:-off} (server ${SPEEDTEST_SERVER}, fallback ${SPEEDTEST_FALLBACK:-none}), RTR-Netztest at minute ${RTR_MINUTE:-off}"
until install_clients; do bashio::log.warning "Retrying client download in 60 s"; sleep 60; done
if [ "${RUN_ON_START}" = "true" ]; then
  [ -n "${SPEEDTEST_MINUTE}" ] && run_speedtest
  [ -n "${RTR_MINUTE}" ] && run_rtr
fi
# Each schedule fires once per hour when the current minute reaches its target.
# Slots already passed in the current hour count as done so a restart does not
# repeat them (or run them at all when run_on_start is false).
hour=$(date +%Y%m%d%H); minute=$(date +%M | sed 's/^0*//'); minute=${minute:-0}
done_speedtest=""; done_rtr=""
[ -n "${SPEEDTEST_MINUTE}" ] && [ "${minute}" -ge "${SPEEDTEST_MINUTE}" ] && done_speedtest="${hour}"
[ -n "${RTR_MINUTE}" ] && [ "${minute}" -ge "${RTR_MINUTE}" ] && done_rtr="${hour}"
while true; do
  if [ -f /tmp/trigger_speedtest ]; then rm -f /tmp/trigger_speedtest; bashio::log.info "Manual trigger: Speedtest.net"; run_speedtest; fi
  if [ -f /tmp/trigger_rtr ]; then rm -f /tmp/trigger_rtr; bashio::log.info "Manual trigger: RTR-Netztest"; run_rtr; fi
  hour=$(date +%Y%m%d%H); minute=$(date +%M | sed 's/^0*//'); minute=${minute:-0}
  if [ -n "${SPEEDTEST_MINUTE}" ] && [ "${minute}" -ge "${SPEEDTEST_MINUTE}" ] && [ "${done_speedtest}" != "${hour}" ]; then done_speedtest="${hour}"; run_speedtest; fi
  if [ -n "${RTR_MINUTE}" ] && [ "${minute}" -ge "${RTR_MINUTE}" ] && [ "${done_rtr}" != "${hour}" ]; then done_rtr="${hour}"; run_rtr; fi
  sleep 10
done
