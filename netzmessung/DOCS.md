# SmartStamm Netzmessung add-on

Runs two internet speed measurements at configurable intervals in hours or calendar days and publishes the results as Home Assistant sensors. By default, both run hourly with a random deviation of up to three minutes before or after the selected minute:

- **Speedtest.net** with the official [Speedtest CLI by Ookla](https://www.speedtest.net/apps/cli) against a fixed server. The built-in Speedtest.net integration can only use the ten servers Ookla picks from the client's geo-IP location, which is often wrong on mobile uplinks; the CLI accepts any server id.
- **RTR-Netztest** with the [RMBT client](https://github.com/rtr-nettest/open-rmbt-client-cli) of the Austrian regulator RTR-GmbH (Rust variant, built from a pinned commit).

Both measurements run sequentially in one loop, so they never overlap.

## Sensors

| Entity | Unit | Content |
| --- | --- | --- |
| `sensor.speedtest_download` | Mbit/s | Download (attributes `bytes_received`, `latency_loaded_ms`) |
| `sensor.speedtest_upload` | Mbit/s | Upload (attributes `bytes_sent`, `latency_loaded_ms`) |
| `sensor.speedtest_ping` | ms | Idle latency (attributes `jitter_ms`, `packet_loss`) |
| `sensor.speedtest_status` | text | `ok`, `running` or `error`, with message |
| `sensor.rtr_netztest_download` | Mbit/s | Download |
| `sensor.rtr_netztest_upload` | Mbit/s | Upload |
| `sensor.rtr_netztest_ping` | ms | Median ping (attribute `ping_min`) |
| `sensor.rtr_netztest_status` | text | `ok`, `running` or `error`, with message |

Speedtest sensors carry `server_name`, `server_location`, `server_country`, `server_id`, `server_host`, `isp`, `share_url` and `measured_at`; RTR sensors carry `server`, `share_url`, `measured_at` and `threads`. The entity ids match the former Speedtest.net integration and the former separate add-ons, so history and dashboards keep working.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `speedtest_minute` | `0` | Target minute for Speedtest.net; leave empty to disable scheduled and startup measurements |
| `speedtest_interval` | `1` | Number of hours or days between Speedtest.net measurements, from 1 to 365 |
| `speedtest_interval_unit` | `hours` | `hours` for elapsed hours, `days` for calendar days |
| `speedtest_hour` | `0` | Target local hour for daily Speedtest.net measurements, from 0 to 23; ignored with `hours` |
| `speedtest_server_id` | `818` | Speedtest.net server id (818 = LIWEST Linz). Find ids at `https://www.speedtest.net/api/js/servers?engine=js&search=<city>` |
| `speedtest_fallback_server_id` | `73500` | Server tried when the first one fails (73500 = Energie AG Linz); empty disables the fallback |
| `rtr_minute` | `30` | Target minute for RTR-Netztest; leave empty to disable scheduled and startup measurements |
| `rtr_interval` | `1` | Number of hours or days between RTR-Netztest measurements, from 1 to 365 |
| `rtr_interval_unit` | `hours` | `hours` for elapsed hours, `days` for calendar days |
| `rtr_hour` | `0` | Target local hour for daily RTR-Netztest measurements, from 0 to 23; ignored with `hours` |
| `rtr_control_server` | `https://c01.netztest.at` | RTR control server |
| `rtr_model` | `Home Assistant Green` | Device model reported to RTR |
| `run_on_start` | `true` | Run both enabled measurements when the add-on starts |
| `jitter_minutes` | `3` | Maximum random deviation before or after each target, from 0 to 15 minutes; `0` disables it |

Change these options on the add-on's **Configuration** tab, save, and restart the add-on.

For Speedtest.net every six hours around minute 15, set `speedtest_interval: 6`, `speedtest_interval_unit: hours`, and `speedtest_minute: 15`. The first target is in the current hour if its randomized time is still ahead; otherwise it is six hours later. Following targets stay six hours apart, independently of measurement duration or random deviation.

For RTR-Netztest every day around 18:30, set `rtr_interval: 1`, `rtr_interval_unit: days`, `rtr_hour: 18`, and `rtr_minute: 30`. Use `rtr_interval: 2` for every other day. A new daily schedule starts with today's target if its randomized time is still ahead, otherwise with the target N days later.

With `jitter_minutes: 3`, the 18:30 target can run between 18:27 and 18:33. Each target gets its own random offset, which can cross an hour or midnight. The pending target and offset are saved in the add-on data directory and survive restarts. Changing schedule options or the timezone creates a new schedule. Missed targets are skipped rather than replayed. Startup and manual measurements run immediately and do not move the schedule. When both measurements are due, they run sequentially; a busy measurement can delay the other beyond its random window.

Daily schedules use the add-on's local timezone and retain the selected wall-clock time across daylight saving changes. A time missing during the spring clock change moves forward by the clock jump, for example 02:30 to 03:30. A repeated autumn time runs once. Hourly schedules count elapsed hours, so they can run in both occurrences of a repeated hour.

The distinction between elapsed and calendar intervals follows the scheduling model described by [APScheduler](https://apscheduler.readthedocs.io/en/stable/modules/triggers/calendarinterval.html). Randomizing each target without moving the underlying cadence is also used by [systemd timers](https://github.com/systemd/systemd/blob/main/man/systemd.timer.xml). This add-on uses symmetric offsets so measurements can run both before and after their target.

## Manual measurement

Call the action `hassio.addon_stdin` with `addon: <this add-on's slug>` and `input: speedtest` or `input: rtr`; any other input starts both. The status sensors switch to `running` while a test is in progress.

## Notes

- Both clients are downloaded on first start into the add-on data directory: the Ookla CLI from Ookla (its EULA does not allow redistribution; starting it records acceptance of EULA and privacy policy, use is limited to personal, non-commercial purposes), the RMBT client from this repository's releases with SHA-256 verification. The add-on needs internet access at first start.
- Each measurement transfers roughly 100 to 300 MB. Two measurements per hour add up to several GB per day.
- Speedtest results are submitted to Ookla, RTR results to RTR (anonymised open data); both `share_url`s are public.
- The sensors are created through the REST API and are not available until the first measurement after a Home Assistant restart.
