# SmartStamm Add-ons

Home Assistant add-on repository of ASKÖ Linz-Stamm.

- **SmartStamm Netzmessung**: hourly Speedtest.net (official Ookla CLI against a fixed server, default LIWEST Linz) and hourly RTR-Netztest (RMBT client of the Austrian regulator), each reported as Home Assistant sensors. See `netzmessung/DOCS.md`.

Add this repository in Home Assistant under Settings → Add-ons → Add-on store → ⋮ → Repositories:
`https://github.com/askoe-linz-stamm/smartstamm-addons`

The existing SmartStamm installation keeps its original `https://github.com/flowsworld/smartstamm-addons` store entry. GitHub redirects that address after the transfer. Removing and adding the repository under the new address would change the repository ID and the installed add-on slug used by Home Assistant scripts.

## Error reports

On errors the status sensors (`sensor.speedtest_status`, `sensor.rtr_netztest_status`) carry `error_code` (`measurement-failed`, `client-exit`, `result-format`) and `failed_runs`. SmartStamm turns lasting failures into issues labelled `automatisch` here. A failed run of the update workflow opens such an issue itself (or comments on the open one) using the workflow's `GITHUB_TOKEN`.

## Building

There is no prebuilt image: the Supervisor builds the add-on on the device (the Dockerfile only runs `apk upgrade` and adds the run script). Both measurement clients are downloaded at first start. Test locally with

```
docker build --build-arg BUILD_FROM=ghcr.io/home-assistant/aarch64-base:3.22 -t netzmessung netzmessung
docker run --rm -e SUPERVISOR_TOKEN=x -v <dir>:/data netzmessung
```

with an `options.json` and an empty file `dry_run` in `<dir>`; sensor payloads are then printed instead of sent.

## Automatic updates

The workflow **Update netzmessung** (`.github/workflows/update.yaml`, script `.github/scripts/update.sh`) runs every three days on a native arm64 runner with a 15-minute limit and commits directly to `main`:

- moves `build.yaml` to the newest `3.x` tag of `ghcr.io/home-assistant/aarch64-base`,
- adopts a newer Ookla CLI version from speedtest.net/apps/cli after a smoke test of its JSON output,
- rebuilds the RMBT client when `open-rmbt-client-cli` master moved, runs one real measurement as smoke test, attaches the binary with checksum to a release and updates the pinned values in `run.sh`,
- bumps the add-on version (CalVer `YYYY.M.D`) on every run and prepends the changes to `CHANGELOG.md`.

The version bump makes the Supervisor (auto-update is enabled for the add-on) rebuild the image on the device, where `apk upgrade` pulls current Alpine packages. Nothing changed: about one minute of runtime; RMBT rebuild: a few minutes. Test the script locally with `DRY_RUN=1 GH_TOKEN=$(gh auth token) .github/scripts/update.sh` (add `FORCE_RMBT_BUILD=1` to exercise the build path); it prints the diff and reverts all uncommitted changes, so commit your own edits first.

## RMBT client binary

The RTR client is compiled from `rtr-nettest/open-rmbt-client-cli` (`clientRust`, Apache-2.0) at a pinned commit and attached to a release of this repository (`rmbt-client-<commit>`, asset `rmbt-client-aarch64` plus `.sha256`). The update workflow does this automatically; by hand, build it on an arm64 machine with Docker:

```
docker build --platform linux/arm64 -o type=local,dest=out -f - . <<'EOF2'
FROM rust:1-alpine AS build
RUN apk add --no-cache musl-dev git
ARG RMBT_COMMIT=8d85b82786abacb361c75a496df118d9ac6e3c87
RUN git clone https://github.com/rtr-nettest/open-rmbt-client-cli /src \
 && cd /src && git checkout -q "${RMBT_COMMIT}" \
 && cd clientRust && cargo build --release && strip target/release/rmbt-client
FROM scratch
COPY --from=build /src/clientRust/target/release/rmbt-client /rmbt-client
EOF2
```

Then `gh release create rmbt-client-<short commit> out/rmbt-client#rmbt-client-aarch64` and update `RMBT_RELEASE` (with the full commit in its comment) and `RMBT_SHA256` in `netzmessung/run.sh`.

Former add-ons `rtr-netztest` and `speedtest-ookla` (up to 2026-09-16) were merged into this one; their images on ghcr.io are no longer used.
