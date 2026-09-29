## 2026.9.29

- Status sensors carry `error_code` (`measurement-failed`, `client-exit`, `result-format`) and `failed_runs` on errors, so SmartStamm can report lasting failures as GitHub issues.
- Speedtest.net results with an unexpected format are reported as errors instead of publishing empty values.

## 2026.9.28

- Scheduled rebuild: Alpine packages of the base image refreshed (`apk upgrade`), no upstream changes.

## 2026.9.25

- Scheduled rebuild: Alpine packages of the base image refreshed (`apk upgrade`), no upstream changes.

## 2026.9.22

- RMBT client 8d85b82 → cb87ff8 (rebuilt, smoke test passed)
- Image rebuilt with current Alpine packages.

## 2026.9.19

- Scheduled rebuild: Alpine packages of the base image refreshed (`apk upgrade`), no upstream changes.

## 2026.9.16

- Scheduled rebuild: Alpine packages of the base image refreshed (`apk upgrade`), no upstream changes.

## 1.0.0

- First release. Merges the former add-ons RTR-Netztest (0.1.1) and Speedtest.net (Ookla CLI) (0.1.0) into one add-on with one schedule loop.
- Both clients are downloaded at first start (Ookla CLI 1.2.0 from Ookla, RMBT client from this repository's releases, SHA-256 verified).
- A failed measurement sets the status sensor to `error` instead of ending the add-on (bashio's `errexit` is disabled).
- Sensors and entity ids are unchanged: `sensor.speedtest_*` and `sensor.rtr_netztest_*`.
