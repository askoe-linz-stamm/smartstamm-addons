#!/usr/bin/env bash
# Normalize existing flat options and the native grouped configuration.
# Supervisor merges new defaults with saved options. Upgrade those saved options
# once through the self API before presenting the grouped controls to the user.
# These globals are consumed by run.sh after load_options returns.
# shellcheck disable=SC2034

options_migrate() { # $1 options.json; prints grouped JSON, including secrets.
  jq '
    def legacy($key; $fallback):
      if has($key) then .[$key] else $fallback end;
    def unit_label:
      if . == "days" then "Tage" elif . == "hours" then "Stunden" else . end;
    def server_label:
      if . == 818 then "LIWEST, Linz, Österreich, ID 818"
      elif . == 73500 then "Energie AG, Linz, Österreich, ID 73500"
      else "Automatisch auswählen" end;
    . as $old |
    any(keys[]; test("^(speedtest_|rtr_|run_on_start$|jitter_minutes$)")) as $legacy |
    ({enabled:true, interval:1, interval_unit:"Stunden", hour:0, minute:0,
      server:"LIWEST, Linz, Österreich, ID 818",
      fallback_server:"Energie AG, Linz, Österreich, ID 73500"} + (.speedtest // {})) as $speedtest |
    ({enabled:true, interval:1, interval_unit:"Stunden", hour:0, minute:30,
      server:"Automatisch auswählen", control_server:"https://c01.netztest.at",
      model:"Home Assistant Green"} + (.rtr // {})) as $rtr |
    ({enabled:false, threshold_mbps:2, router_url:"http://192.168.3.1"} + (.protection // {})) as $protection |
    ({run_on_start:true, jitter_minutes:3} + (.general // {})) as $general |
    {
      speedtest: ($speedtest + {
        enabled: (if $legacy then $old.speedtest_minute != null else $speedtest.enabled end),
        minute: ($old | legacy("speedtest_minute"; $speedtest.minute) // $speedtest.minute),
        interval: ($old | legacy("speedtest_interval"; $speedtest.interval) // $speedtest.interval),
        interval_unit: ($old | legacy("speedtest_interval_unit"; $speedtest.interval_unit) // $speedtest.interval_unit | unit_label),
        hour: ($old | legacy("speedtest_hour"; $speedtest.hour) // $speedtest.hour)
      } |
        if $old | has("speedtest_server_id") then
          .server = ($old.speedtest_server_id | server_label) |
          del(.custom_server_id) |
          if $old.speedtest_server_id != null and $old.speedtest_server_id != 818 and $old.speedtest_server_id != 73500
          then .custom_server_id = $old.speedtest_server_id else . end
        else . end |
        if $legacy then
          .fallback_server = (if $old.speedtest_fallback_server_id == null then "Kein Ersatzserver"
            elif $old.speedtest_fallback_server_id == 818 or $old.speedtest_fallback_server_id == 73500
            then $old.speedtest_fallback_server_id | server_label else "Kein Ersatzserver" end) |
          del(.custom_fallback_server_id) |
          if $old.speedtest_fallback_server_id != null and $old.speedtest_fallback_server_id != 818 and $old.speedtest_fallback_server_id != 73500
          then .custom_fallback_server_id = $old.speedtest_fallback_server_id else . end
        else . end),
      rtr: ($rtr + {
        enabled: (if $legacy then $old.rtr_minute != null else $rtr.enabled end),
        minute: ($old | legacy("rtr_minute"; $rtr.minute) // $rtr.minute),
        interval: ($old | legacy("rtr_interval"; $rtr.interval) // $rtr.interval),
        interval_unit: ($old | legacy("rtr_interval_unit"; $rtr.interval_unit) // $rtr.interval_unit | unit_label),
        hour: ($old | legacy("rtr_hour"; $rtr.hour) // $rtr.hour),
        control_server: ($old | legacy("rtr_control_server"; $rtr.control_server) // $rtr.control_server),
        model: ($old | legacy("rtr_model"; $rtr.model) // $rtr.model)
      }),
      protection: $protection,
      general: ($general + {
        run_on_start: ($old | legacy("run_on_start"; $general.run_on_start)),
        jitter_minutes: ($old | legacy("jitter_minutes"; $general.jitter_minutes))
      })
    }
  ' "$1"
}

options_server_id() { # Known choice labels carry their numeric ID at the end.
  if [[ "$1" =~ ,\ ID\ ([0-9]+)$ ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; fi
}

options_upgrade() { # $1 options.json; persist the one-time upgrade without logging secrets.
  local normalized response
  [ "$(jq -r 'any(keys[]; test("^(speedtest_|rtr_|run_on_start$|jitter_minutes$)"))' "$1")" = true ] || return 0
  normalized=$(options_migrate "$1") || return 1
  # Bashio's API helper logs request bodies at debug level, so use curl here.
  response=$(printf '%s' "${normalized}" | jq '{options:.}' | \
    curl -sf --max-time 15 -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
      -H 'Content-Type: application/json' --data-binary @- 'http://supervisor/addons/self/options') || return 1
  jq -e '.result == "ok"' <<< "${response}" > /dev/null || return 1
  # Supervisor rewrites this file on the next start. Use the saved values now too.
  (umask 077; printf '%s\n' "${normalized}" > "$1.tmp") && mv "$1.tmp" "$1"
}

load_options() { # $1 options.json; sets run.sh settings, never prints secrets.
  local normalized rtr_server loader_directory
  OPTIONS_LEGACY=$(jq -r 'any(keys[]; test("^(speedtest_|rtr_|run_on_start$|jitter_minutes$)"))' "$1") || return 1
  normalized=$(options_migrate "$1") || return 1
  SPEEDTEST_MINUTE=$(jq -r 'if .speedtest.enabled then .speedtest.minute else "" end' <<< "${normalized}")
  SPEEDTEST_INTERVAL=$(jq -r '.speedtest.interval' <<< "${normalized}")
  SPEEDTEST_INTERVAL_UNIT=$(jq -r 'if .speedtest.interval_unit == "Tage" then "days" else "hours" end' <<< "${normalized}")
  SPEEDTEST_HOUR=$(jq -r '.speedtest.hour' <<< "${normalized}")
  SPEEDTEST_SERVER=$(jq -r '.speedtest.custom_server_id // empty' <<< "${normalized}")
  [ -n "${SPEEDTEST_SERVER}" ] || SPEEDTEST_SERVER=$(options_server_id "$(jq -r '.speedtest.server' <<< "${normalized}")")
  SPEEDTEST_FALLBACK=$(jq -r '.speedtest.custom_fallback_server_id // empty' <<< "${normalized}")
  [ -n "${SPEEDTEST_FALLBACK}" ] || SPEEDTEST_FALLBACK=$(options_server_id "$(jq -r '.speedtest.fallback_server' <<< "${normalized}")")
  RTR_MINUTE=$(jq -r 'if .rtr.enabled then .rtr.minute else "" end' <<< "${normalized}")
  RTR_INTERVAL=$(jq -r '.rtr.interval' <<< "${normalized}")
  RTR_INTERVAL_UNIT=$(jq -r 'if .rtr.interval_unit == "Tage" then "days" else "hours" end' <<< "${normalized}")
  RTR_HOUR=$(jq -r '.rtr.hour' <<< "${normalized}")
  RTR_CONTROL=$(jq -r '.rtr.control_server' <<< "${normalized}")
  RTR_MODEL=$(jq -r '.rtr.model' <<< "${normalized}")
  rtr_server=$(jq -r '.rtr.server' <<< "${normalized}")
  RTR_SERVER_UUID=""
  if [ "${rtr_server}" != 'Automatisch auswählen' ]; then
    loader_directory=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
    RTR_SERVER_UUID=$(jq -er --arg name "${rtr_server}" '.[$name]' "${loader_directory}/rtr_servers.json") || return 1
  fi
  RUN_ON_START=$(jq -r '.general.run_on_start' <<< "${normalized}")
  JITTER_MINUTES=$(jq -r '.general.jitter_minutes' <<< "${normalized}")
  PROTECTION_ENABLED=$(jq -r '.protection.enabled' <<< "${normalized}")
  PROTECTION_THRESHOLD_MBPS=$(jq -r '.protection.threshold_mbps' <<< "${normalized}")
  PROTECTION_ROUTER_URL=$(jq -r '.protection.router_url' <<< "${normalized}")
  PROTECTION_ROUTER_PASSWORD=$(jq -r '.protection.password // empty' <<< "${normalized}")
}
