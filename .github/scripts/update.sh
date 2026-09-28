#!/usr/bin/env bash
# Upstream update for the netzmessung add-on. Runs from the repository root.
#   - base image: newest 3.x tag of ghcr.io/home-assistant/aarch64-base
#   - Ookla CLI: newest version offered on speedtest.net/apps/cli (aarch64 file must exist)
#   - RMBT client: head of rtr-nettest/open-rmbt-client-cli master; rebuilt, smoke-tested
#     and attached to a release when it changed
# The add-on version is bumped on every run (CalVer YYYY.M.D) so the Supervisor rebuilds
# the image on the device and `apk upgrade` in the Dockerfile pulls current Alpine packages.
# Environment: GH_TOKEN (releases), DRY_RUN=1 (no push, no release), FORCE_RMBT_BUILD=1 (test the build path).
set -euo pipefail
cd "$(dirname "$0")/../.."
ADDON=netzmessung
RUN_SH="${ADDON}/run.sh"; BUILD_YAML="${ADDON}/build.yaml"; CONFIG="${ADDON}/config.yaml"; CHANGELOG="${ADDON}/CHANGELOG.md"
REPO="${GITHUB_REPOSITORY:-askoe-linz-stamm/smartstamm-addons}"
RMBT_REPO=rtr-nettest/open-rmbt-client-cli
changes=()

# ---- current values -------------------------------------------------------------------
cur_base=$(sed -n 's/^  aarch64: ghcr.io\/home-assistant\/aarch64-base:\(.*\)$/\1/p' "${BUILD_YAML}")
cur_ookla=$(sed -n 's/^OOKLA_VERSION=\(.*\)$/\1/p' "${RUN_SH}")
cur_rmbt_release=$(sed -n 's/^RMBT_RELEASE=\([^ ]*\).*$/\1/p' "${RUN_SH}")
cur_rmbt_full=$(sed -n 's/^RMBT_RELEASE=.*commit \([0-9a-f]*\)$/\1/p' "${RUN_SH}")
cur_version=$(sed -n 's/^version: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${CONFIG}")
echo "current: base ${cur_base}, ookla ${cur_ookla}, rmbt ${cur_rmbt_release} (${cur_rmbt_full}), version ${cur_version}"

# ---- base image ------------------------------------------------------------------------
tok=$(curl -sf "https://ghcr.io/token?scope=repository:home-assistant/aarch64-base:pull" | jq -r .token)
new_base=$(curl -sf -H "Authorization: Bearer ${tok}" "https://ghcr.io/v2/home-assistant/aarch64-base/tags/list?n=1000" \
  | jq -r '.tags[] | select(test("^3\\.[0-9]+$"))' | sort -t. -k2,2n | tail -1)
[ -n "${new_base}" ] || { echo "no base image tags found"; exit 1; }
if [ "${new_base}" != "${cur_base}" ]; then
  sed -i.bak "s|aarch64-base:${cur_base}|aarch64-base:${new_base}|" "${BUILD_YAML}" && rm -f "${BUILD_YAML}.bak"
  changes+=("Base image ghcr.io/home-assistant/aarch64-base ${cur_base} → ${new_base}")
fi

# ---- Ookla CLI --------------------------------------------------------------------------
new_ookla=$(curl -sfL https://www.speedtest.net/apps/cli | grep -o 'ookla-speedtest-[0-9.]*-linux-aarch64\.tgz' | sed 's/ookla-speedtest-\(.*\)-linux-aarch64.tgz/\1/' | sort -V | tail -1)
if [ -n "${new_ookla}" ] && [ "${new_ookla}" != "${cur_ookla}" ]; then
  url="https://install.speedtest.net/app/cli/ookla-speedtest-${new_ookla}-linux-aarch64.tgz"
  tmp=$(mktemp -d); curl -sfL "${url}" | tar xz -C "${tmp}" speedtest
  # smoke test: the JSON result must still carry the fields run.sh parses
  out=$(docker run --rm --platform linux/arm64 -v "${tmp}:/o" alpine:3 sh -c '/o/speedtest --accept-license --accept-gdpr -f json -p no -s 818 2>/dev/null' | grep '"type":"result"' | tail -1 || true)
  if echo "${out}" | jq -e '.download.bandwidth and .upload.bandwidth and .ping.latency and .server.name and .result.url' >/dev/null 2>&1; then
    sed -i.bak "s|^OOKLA_VERSION=.*|OOKLA_VERSION=${new_ookla}|" "${RUN_SH}" && rm -f "${RUN_SH}.bak"
    changes+=("Ookla CLI ${cur_ookla} → ${new_ookla} (smoke test passed)")
  else
    echo "::warning::Ookla CLI ${new_ookla} available but smoke test failed; keeping ${cur_ookla}"
  fi
  rm -rf "${tmp}"
fi

# ---- RMBT client ------------------------------------------------------------------------
auth=(); [ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GH_TOKEN}")
new_rmbt_full=$(curl -sf "${auth[@]}" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${RMBT_REPO}/commits/master" | jq -r .sha || true)
[ -n "${new_rmbt_full}" ] && [ "${new_rmbt_full}" != "null" ] || { echo "::error::could not read ${RMBT_REPO} master"; exit 1; }
if [ "${new_rmbt_full}" != "${cur_rmbt_full}" ] || [ -n "${FORCE_RMBT_BUILD:-}" ]; then
  short=${new_rmbt_full:0:7}; tag="rmbt-client-${short}"
  echo "building RMBT client ${short}"
  out=$(mktemp -d)
  docker build --platform linux/arm64 -o "type=local,dest=${out}" -f - . <<DOCKER
FROM rust:1-alpine AS build
RUN apk add --no-cache musl-dev git
RUN git clone https://github.com/${RMBT_REPO} /src && cd /src && git checkout -q ${new_rmbt_full} \
 && cd clientRust && cargo build --release && strip target/release/rmbt-client
FROM scratch
COPY --from=build /src/clientRust/target/release/rmbt-client /rmbt-client
DOCKER
  # smoke test: one real measurement, the result block must still parse
  res=$(docker run --rm --platform linux/arm64 -v "${out}:/o" alpine:3 /o/rmbt-client --host https://c01.netztest.at --type CLI --platform Linux --model "GitHub Actions" --nettype 98 2>&1 || true)
  if ! echo "${res}" | grep -q '^Download:' || ! echo "${res}" | grep -q '^Upload:' || ! echo "${res}" | grep -q '^Ping (median):'; then
    echo "::error::RMBT client ${short} built but smoke test failed; keeping ${cur_rmbt_release}"; echo "${res}" | tail -5
    rm -rf "${out}"
  else
    cp "${out}/rmbt-client" "${out}/rmbt-client-aarch64"
    sha=$(shasum -a 256 "${out}/rmbt-client-aarch64" | cut -d' ' -f1); echo "${sha}  rmbt-client-aarch64" > "${out}/rmbt-client-aarch64.sha256"
    if [ -z "${DRY_RUN:-}" ]; then
      gh release create "${tag}" -R "${REPO}" --title "RMBT client ${short} (aarch64)" \
        --notes "RTR-Netztest RMBT client, Rust variant, built from ${RMBT_REPO} commit ${new_rmbt_full} (Apache-2.0) with rust:1-alpine for linux/arm64, statically linked and stripped. Built automatically by the update workflow." \
        "${out}/rmbt-client-aarch64" "${out}/rmbt-client-aarch64.sha256"
    else
      echo "DRY: would create release ${tag} with sha ${sha}"
    fi
    sed -i.bak -e "s|^RMBT_RELEASE=.*|RMBT_RELEASE=${tag}   # tag in ${REPO}, built from open-rmbt-client-cli commit ${new_rmbt_full}|" \
               -e "s|^RMBT_SHA256=.*|RMBT_SHA256=${sha}|" "${RUN_SH}" && rm -f "${RUN_SH}.bak"
    changes+=("RMBT client ${cur_rmbt_release#rmbt-client-} → ${short} (rebuilt, smoke test passed)")
    rm -rf "${out}"
  fi
fi

# ---- version bump, changelog, commit ------------------------------------------------------
today=$(date -u +%Y.%-m.%-d)
new_version="${today}"
case "${cur_version}" in "${today}"|"${today}".*) n=${cur_version#${today}}; n=${n#.}; new_version="${today}.$(( ${n:-0} + 1 ))";; esac
sed -i.bak "s|^version: .*|version: \"${new_version}\"|" "${CONFIG}" && rm -f "${CONFIG}.bak"
{ echo "## ${new_version}"; echo
  if [ ${#changes[@]} -eq 0 ]; then echo "- Scheduled rebuild: Alpine packages of the base image refreshed (\`apk upgrade\`), no upstream changes."
  else for c in "${changes[@]}"; do echo "- ${c}"; done; echo "- Image rebuilt with current Alpine packages."; fi
  echo; cat "${CHANGELOG}"; } > "${CHANGELOG}.new" && mv "${CHANGELOG}.new" "${CHANGELOG}"
echo "new version ${new_version}; changes: ${changes[*]:-none}"
git add -A
if [ -n "${DRY_RUN:-}" ]; then echo "DRY: diff follows"; git --no-pager diff --cached --stat; git --no-pager diff --cached -- "${RUN_SH}" "${BUILD_YAML}" "${CONFIG}"; git reset -q; git checkout -- .; exit 0; fi
git -c user.name="smartstamm-update" -c user.email="smartstamm-update@users.noreply.github.com" commit -q -m "chore(netzmessung): ${new_version} automatic upstream update

$(printf '%s\n' "${changes[@]:-no upstream changes, scheduled rebuild}")"
git push origin HEAD
