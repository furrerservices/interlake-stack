# interlake-stack

Festgelegte Versionen der Programme, die eine Interlake-Installation unter Windows braucht
(PHP, Apache Lounge + mod_fcgid, MariaDB, NSSM, MinGit, Composer, CA-Bündel, mkcert).

- **`manifest.json`** — pro Paket: Version, Dateiname, Download-Adressen (der Reihe nach versucht) und SHA-256.
  `install_production.ps1` aus dem Interlake-Repo liest diese Datei, lädt jedes Paket selbst und bricht ab,
  wenn die Prüfsumme nicht stimmt.
- **Releases** (`pakete-JJJJ-MM-TT`) — unveränderte Kopien von Paketen, deren Anbieter alte Versionen
  nicht dauerhaft anbieten (Apache Lounge, mod_fcgid) oder zeitweise nicht erreichbar sind (NSSM).
  PHP, MariaDB, MinGit, Composer, CA-Bündel und mkcert werden direkt beim Anbieter geladen (dauerhafte Archiv-Links).

## Automatisch geprüft: GitHub-Lauf „Stack pruefen“

Täglich um 04:17 UTC (`.github/workflows/stack-pruefen.yml`): zuerst PHP, danach Apache Lounge.
Gemeinsame Teile (Download, Probeinstallation, JSON) in `werkzeuge/gemeinsam.ps1`.

### PHP (`werkzeuge/php_pruefen.ps1`)


1. Neueste Version je festgelegter Reihe aus `releases.json` von downloads.php.net (NTS x64, nur gleiche Reihe;
   auch Windows-Neubauten wie `8.3.36-1`).
2. Download, SHA-256 gegen die Angabe von downloads.php.net.
3. Probeinstallation auf einem frischen Windows: `php.ini` wie `install_production.ps1` (gleiche Erweiterungen,
   OPcache), `php -m`, dann Apache + mod_fcgid aus diesem Manifest starten und eine Testseite über `php-cgi` abrufen.
4. Bestanden → `manifest.json` anpassen. `version` = Basisversion (so meldet sich PHP), `build` = Windows-Build,
   `sicherheit` = Sicherheits-Release laut php.net.

### Apache + mod_fcgid (`werkzeuge/apache_pruefen.ps1`)

1. Download-Seite von Apache Lounge auslesen (keine Versionsliste vorhanden). Erkannt wird eine neue Datei und
   ein **stiller Neubau unter gleichem Namen** (Prüfsumme anders — kam am 24.10.2026 bei `httpd-2.4.69-261002` vor).
2. **httpd:** GPG-Signatur (`.asc`) mit dem fest abgelegten Schlüssel `schluessel/apachelounge.asc`
   (Steffen Land, Fingerprint `3D49 885E ADE8 BC39 9F46 D5DD BEE8 8A78 29C1 7558`, abgeglichen mit keys.openpgp.org)
   + SHA-256 aus der `.txt`. Geprüft mit `gpgv` (Git for Windows).
3. **mod_fcgid:** Apache Lounge veröffentlicht für Module **weder Signatur noch Prüfsumme** → wird erkannt und
   geprüft, aber **immer als Pull Request** (auch mit `AUTO_UEBERNEHMEN=ja`). Ebenso ein Compiler-Wechsel (VS18 → VS19),
   weil dann `vc_redist.mindestversion` angepasst werden muss.
4. Probe: neues httpd/mod_fcgid mit **jeder** festgelegten PHP-Reihe, `httpd -v`, Testseite über php-cgi.
5. Bestanden → Datei ins Release `pakete-<Datum>` (Spiegel, erste Download-Adresse), `manifest.json` anpassen.

### Ergebnis

`stand` oben in `manifest.json` ändert der Lauf nicht (sonst kämen sich PHP- und Apache-Pull-Requests in die Quere).

Was danach passiert, steuert die Repo-Variable **`AUTO_UEBERNEHMEN`** (Settings › Secrets and variables › Actions › Variables):

| Wert | Ergebnis |
|---|---|
| `ja` | direkt auf `main`, Info-Issue (geschlossen, nur für die Mail) |
| leer/anders | Pull Request zum Mergen von Hand (Übergang, bis Interlake die Version selbst einspielt) |

Fällt eine Probe durch: Issue „… : Probe fehlgeschlagen“ (einmal je Version; ohne Versionsnummer, z.B. Seite umgebaut,
höchstens einmal im Monat), `manifest.json` bleibt dafür unverändert.
Von Hand starten: Actions › Stack pruefen › Run workflow (Häkchen „Nur Probeinstallation“ prüft die festgelegten Versionen, ändert nichts).
Lokal: `powershell -ExecutionPolicy Bypass -File werkzeuge\php_pruefen.ps1 -NurProbe` bzw. `apache_pruefen.ps1 -NurProbe`.

## Übrige Pakete (MariaDB, NSSM, MinGit, Composer, CA-Bündel, mkcert): von Hand festlegen

1. Datei beim Anbieter laden, SHA-256 mit der Angabe des Anbieters vergleichen (wo vorhanden).
2. Falls gespiegelt: als Asset in ein neues Release `pakete-<Datum>` laden.
3. Eintrag in `manifest.json` anpassen (`version`, `datei`, `urls`, `sha256`, `festgelegt_am`, `grund`), `stand` nachführen.
4. Zuerst auf dem Testrechner installieren, erst dann bei der Kundin.

## Lizenzen

Die gespiegelten Dateien sind unverändert. Apache HTTP Server und mod_fcgid stehen unter der
Apache License 2.0 (LICENSE/NOTICE liegen in den Archiven), NSSM ist Public Domain.
Builds: Apache Lounge (https://www.apachelounge.com), NSSM (https://nssm.cc).
