# interlake-stack

Festgelegte Versionen der Programme, die eine Interlake-Installation unter Windows braucht
(PHP, Apache Lounge + mod_fcgid, MariaDB, NSSM, MinGit, Composer, CA-Bündel, mkcert).

- **`manifest.json`** — pro Paket: Version, Dateiname, Download-Adressen (der Reihe nach versucht) und SHA-256.
  `install_production.ps1` aus dem Interlake-Repo liest diese Datei, lädt jedes Paket selbst und bricht ab,
  wenn die Prüfsumme nicht stimmt.
- **Releases** (`pakete-JJJJ-MM-TT`) — unveränderte Kopien von Paketen, deren Anbieter alte Versionen
  nicht dauerhaft anbieten (Apache Lounge, mod_fcgid) oder zeitweise nicht erreichbar sind (NSSM).
  PHP, MariaDB, MinGit, Composer, CA-Bündel und mkcert werden direkt beim Anbieter geladen (dauerhafte Archiv-Links).

## Neue Version festlegen

1. Datei beim Anbieter laden, SHA-256 mit der Angabe des Anbieters vergleichen (wo vorhanden).
2. Falls gespiegelt: als Asset in ein neues Release `pakete-<Datum>` laden.
3. Eintrag in `manifest.json` anpassen (`version`, `datei`, `urls`, `sha256`, `festgelegt_am`, `grund`), `stand` nachführen.
4. Zuerst auf dem Testrechner installieren, erst dann bei der Kundin.

Keine automatischen Updates: Interlake meldet höchstens, dass eine neue festgelegte Version vorliegt.

## Lizenzen

Die gespiegelten Dateien sind unverändert. Apache HTTP Server und mod_fcgid stehen unter der
Apache License 2.0 (LICENSE/NOTICE liegen in den Archiven), NSSM ist Public Domain.
Builds: Apache Lounge (https://www.apachelounge.com), NSSM (https://nssm.cc).
