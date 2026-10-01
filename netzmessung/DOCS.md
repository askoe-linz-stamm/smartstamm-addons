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
| `sensor.speedtest_status` | text | `ok`, `checking`, `running`, `skipped` or `error`, with message |
| `sensor.rtr_netztest_download` | Mbit/s | Download |
| `sensor.rtr_netztest_upload` | Mbit/s | Upload |
| `sensor.rtr_netztest_ping` | ms | Median ping (attribute `ping_min`) |
| `sensor.rtr_netztest_status` | text | `ok`, `checking`, `running`, `skipped` or `error`, with message |

Speedtest sensors carry `server_name`, `server_location`, `server_country`, `server_id`, `server_host`, `isp`, `share_url` and `measured_at`; RTR sensors carry `server`, `share_url`, `measured_at` and `threads`. The entity ids match the former Speedtest.net integration and the former separate add-ons, so history and dashboards keep working.

## Konfiguration

Auf der Registerkarte **Konfiguration** gibt es vier Abschnitte mit deutschen Feldnamen und Beschreibungen. Nach Änderungen speichern und das Add-on neu starten.

### Speedtest.net und RTR-Netztest

Jedes Messverfahren hat einen eigenen Schalter und Zeitplan. Für eine Messung alle sechs Stunden um Minute 15 den Abstand auf `6`, die Einheit auf `Stunden` und die Minute auf `15` setzen. Das Stundenfeld gilt nur bei täglichen Messungen.

Für eine tägliche RTR-Messung um 18:30 den Abstand auf `1`, die Einheit auf `Tage`, die Stunde auf `18` und die Minute auf `30` setzen. Mit Abstand `2` läuft die Messung jeden zweiten Tag. Tagesintervalle halten die lokale Uhrzeit auch bei der Zeitumstellung ein. Eine im Frühjahr fehlende Uhrzeit verschiebt sich um den Zeitsprung. Eine im Herbst doppelte Uhrzeit wird einmal verwendet.

Bei Speedtest.net stehen automatische Auswahl, LIWEST Linz und Energie AG Linz zur Verfügung. Die Servernamen enthalten Standort und Servernummer. Ein Ersatzserver kann bei einem Fehler übernehmen. Bereits gespeicherte andere Servernummern bleiben in optionalen Feldern erhalten und haben Vorrang vor der Auswahl. Diese Felder leeren, um wieder die benannten Server zu verwenden.

RTR bietet automatische Auswahl und zwölf benannte Server aus dem offiziellen Katalog. Die Zuordnung zu deren UUID erfolgt intern. Die Servernamen stammen von RTR, das keine gesonderten Angaben zu Standort oder Betreiber liefert. Der Steuerungsserver organisiert den Test und ist kein Messserver. Bei einem eigenen Steuerungsserver die automatische Messserverauswahl verwenden.

Home Assistants native Konfiguration stellt kurze Auswahllisten als Optionsfelder und längere als Dropdown dar. Sie bietet hier keine Suche und keinen Schieberegler. Die Nutzungsschwelle ist deshalb ein Zahlenfeld. Die Serverliste ist mit dieser Add-on-Version festgelegt und wird nicht während der Eingabe vom Anbieter geladen.

### Streaming und andere Internetnutzung schützen

Der Schutz ist zunächst ausgeschaltet. Zum Aktivieren die Adresse des TCL HH515L und sein Verwaltungspasswort hinterlegen, anschließend **Bei beanspruchter Verbindung überspringen** einschalten. Das optionale Passwortfeld über **Nicht verwendete optionale Konfigurationsoptionen anzeigen** einblenden. Das Passwort ist kein WLAN-Passwort. Home Assistant speichert es in den Add-on-Optionen und damit gegebenenfalls auch in Backups. Die Konfigurationsoberfläche maskiert es; das Add-on schreibt es nicht in seine Logs.

Vor geplanten Messungen beginnt eine gemeinsame Routerbeobachtung mit ausreichend Vorlauf für drei vollständige Minuten. Etwa alle fünf Sekunden liest sie Download und Upload über die API der Routeroberfläche und addiert beide Raten. Am geplanten Termin müssen die zeitgewichteten Mittelwerte aller drei aufeinanderfolgenden 60-Sekunden-Fenster unter der eingestellten Schwelle liegen. Ein einzelnes beanspruchtes Minutenfenster genügt zum Überspringen, auch wenn der Mittelwert über alle drei Minuten niedrig ist. Die eigentliche Messung wird durch die Beobachtung nicht um drei Minuten verschoben. Die installierte HH515L-Firmware liefert `Speed_Dl` und `Speed_Ul` in Bit/s, für Mbit/s teilt das Add-on durch 1.000.000.

Vorgabe sind `2 Mbit/s`. Eine kleinere Zahl schützt schon bei geringerer Nutzung. Auch ohne erreichbaren Router, bei fehlendem Passwort oder ungültigen beziehungsweise veralteten Daten wird übersprungen. Nach einem Neustart kann ein naher Termin entfallen, weil noch keine vollständigen drei Minuten vorliegen. Datenlücken über zehn Sekunden erlauben keinen Test. Ein ausgelassener Test wird beim nächsten regulären Termin erneut versucht, nicht sofort nachgeholt. Die letzten Messergebnisse bleiben erhalten. Das Add-on zeigt während des Vorlaufs `checking`, anschließend gegebenenfalls `skipped` mit dem Grund. Überspringen zählt nicht als Messfehler.

Die Beobachtung läuft im Hintergrund und wird für beide Zeitpläne gemeinsam verwendet. Manuelle Anfragen bleiben erreichbar. Auch der Datenverkehr anderer Geschwindigkeitstests gehört zur gesamten Routerauslastung und kann eine nahe automatische Messung verhindern. Beim Add-on-Start wird vor jeder aktivierten Startmessung drei Minuten lang beobachtet; dafür gibt es keinen vorab geplanten Termin.

Das Add-on beobachtet die gesamte Internetverbindung des Routers, einschließlich anderer Geräte. Es erkennt keine einzelnen Anwendungen. Ein Stream, der erst nach der Beobachtung startet, kann daher weiterhin mit einer Messung zusammentreffen. Der Routerzugriff wurde an HH515L TI v4.0 geprüft; andere Modelle oder Firmwarestände können abweichen. Die Anmeldung verwendet denselben Administratorzugang wie die Weboberfläche und kann eine dort bestehende Sitzung beeinflussen.

### Allgemeine Einstellungen

**Nach dem Start des Add-ons messen** startet jedes aktivierte Messverfahren einmal. Der Verbindungsschutz gilt dabei ebenfalls.

**Zufällige Zeitabweichung in Minuten** gilt für beide Zeitpläne. Bei `3` liegt der Beginn eines Termins bis zu drei Minuten vor oder nach der gewählten Uhrzeit. Ist der Schutz aktiv, beginnt die Beobachtung vorher; zum zufällig gewählten Termin wird entschieden, ob die Messung starten darf. `0` deaktiviert die Abweichung. Jeder Termin bekommt einen neuen Zufallswert. Ausstehende Termine überleben Neustarts; Änderungen an Zeitplan oder Zeitzone erzeugen einen neuen Zeitplan. Verpasste Termine werden ausgelassen.

Die Messverfahren laufen nacheinander. Ist das erste noch beschäftigt, kann das zweite später als seine geplante Uhrzeit beginnen. Manuelle Messungen verändern den Zeitplan nicht.

### Bestehende Installationen umstellen

Der Supervisor verbindet neue Vorgaben mit bisher gespeicherten Optionen. Beim ersten Start stellt das Add-on diese automatisch auf die neuen Abschnitte um. Zeitpläne, deaktivierte Verfahren, unbekannte Servernummern und die Einstellung für Startmessungen bleiben erhalten. Danach die bereits geöffnete Konfigurationsseite neu laden. Schlägt das Speichern der Umstellung fehl, startet das Add-on keine Messungen und bittet im Log um einen erneuten Start. Es braucht dafür nur Zugriff auf seine eigenen Optionen, keine zusätzliche Supervisor-Rolle.

## Manual measurement

Call the action `hassio.addon_stdin` with `addon: <this add-on's slug>` and `input: speedtest` or `input: rtr`; any other input starts both. Manual requests bypass the connection protection and start the requested measurement even when automatic measurements are disabled. The status sensors switch to `running` while a test is in progress.

## Notes

- Both clients are downloaded on first start into the add-on data directory: the Ookla CLI from Ookla (its EULA does not allow redistribution; starting it records acceptance of EULA and privacy policy, use is limited to personal, non-commercial purposes), the RMBT client from this repository's releases with SHA-256 verification. The add-on needs internet access at first start.
- Each measurement transfers roughly 100 to 300 MB. Two measurements per hour add up to several GB per day.
- Speedtest results are submitted to Ookla, RTR results to RTR (anonymised open data); both `share_url`s are public.
- The sensors are created through the REST API and are not available until the first measurement after a Home Assistant restart.
