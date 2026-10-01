## 2026.10.1.2

- Connection protection observes traffic before the scheduled test instead of delaying it by the observation. All three consecutive one-minute averages must stay below the threshold.
- A shared background sampler keeps manual triggers available and skips automatic tests when the full three-minute history is missing or stale. Startup tests observe three minutes each.

## 2026.10.1.1

- Native Home Assistant configuration with German labels, explanations and separate sections for each measurement, connection protection and general options.
- Named Ookla and RTR server selections, including automatic selection. Existing configurations and custom Ookla IDs can be migrated without changing their schedules.
- Optional TCL HH515L connection protection checks combined download and upload over 60 seconds before automatic tests. Busy or unavailable connections skip the test; manual requests bypass protection.
- Updated the pinned RTR client to 336e0a8 for explicit measurement server selection.

## 2026.10.1

- Each measurement can run every N hours or N calendar days, with a configurable local hour for daily measurements.
- Measurements run up to three minutes before or after their target by default. `jitter_minutes` adjusts this deviation or disables it with `0`.
- Pending schedule targets survive restarts. Daily schedules preserve local wall-clock time across daylight saving changes.

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
