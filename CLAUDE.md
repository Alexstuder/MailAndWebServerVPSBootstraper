# Projekt: VPS Bootstrapper (Mailserver & Web/Supabase)
Das Ziel dieses Repositories ist die vollautomatisierte, hoster-unabhängige Bereitstellung eines privaten Stacks auf einem Ubuntu 24.04 Server.

## 1. Zero-Trust & Netzwerk-Architektur
* **KEINE offenen Ports für Web-Traffic!** Der Server hängt nicht direkt per HTTP/HTTPS im Internet.
* Der *einzige* Zugang für Web/APIs ist der `cloudflared` (Cloudflare Tunnel).
* **Ausnahme:** Poste.io (Mailserver). Die Ports 25, 465, 587, 143 und 993 werden direkt durchgereicht, da nativer E-Mail-Verkehr nicht durch kostenlose Cloudflare-Tunnels fließen kann.
* Alle Container kommunizieren intern über das Docker Bridge-Netzwerk `vps-net`.

## 2. Secrets & Security
* Es dürfen sich NIEMALS Passwörter oder Klartext-Tokens im Code befinden.
* Alles wird als Umgebungsvariable aus einer Datei geladen, die im Repository als verschlüsselte Datei `.env.gpg` vorliegt.
* Die De- und Verschlüsselung geschieht mit einem GPG-Zertifikat.
* Das Master-GPG-Passwort liegt beim User verschlüsselt in Bitwarden. Das `bootstrap.sh` holt es sich via Bitwarden-CLI beim ersten Server-Start.

## 3. Storage & Backups (State)
* Das Repository ist "Stateless" (enthält nur Konfiguration und Code). 
* Wirkliche Anwendungs-Daten ("State") sind strikt getrennt und werden in Docker-Volumes gespeichert (z.B. `poste-data`, `db-data`).
* Backups laufen automatisiert täglich um 02:00 Uhr. Ein Cronjob packt die Volumes in Tar-Archive, verschlüsselt diese mit GPG und lädt sie via Rclone auf Cloudflare R2 hoch.

## 4. Technologie-Stack-Regeln
* **Web-App:** Die Flutter-Web-Applikation wird als reines statisches HTML/JS-Bundle über einen leichtgewichtigen NGINX (`nginx:alpine`) ausgespielt. Es dürfen keine Node.js Server für die Website eingeführt werden.
* **Backend:** Genutzt wird der offizielle Supabase-Stack.
* **Mail:** Supabase wird so konfiguriert, dass Auth-Mails komplett lokal über den internen Poste.io-Container via Port 25 ausgeliefert werden.

## 5. Domain-Lebenszyklus & Migration
* **Testphase:** Das gesamte Setup wird initial *ausschließlich* auf der Testdomain **`alexstuder.cloud`** aufgebaut, konfiguriert und auf Herz und Nieren geprüft.
* **Produktionsphase:** Erst wenn das System lupenrein und fehlerfrei läuft, erfolgt der Wechsel auf die finale Produktionsdomain **`alexstuder.ch`**.
* **Design-Konsequenz:** Bei JEDER Lösungsfindung, Architektur-Entscheidung und jedem Skript muss zwingend berücksichtigt werden, dass die Domain in Zukunft gewechselt wird. Domains (z.B. `MAIL_DOMAIN`, `API_DOMAIN`, `WEB_DOMAIN`) müssen voll variabel gestaltet sein (z.B. primär über `.env` Variablen) und werden vom zentralen NGINX Reverse-Proxy über `envsubst` Templates dynamisch geroutet. Keine Domain wird jemals hartverdrahtet.

## Anweisung an KIs (Claude/Cursor/Copilot/Antigravity)
1. Bevorhalte stets das Prinzip der **Idempotenz**. Wenn das `bootstrap.sh` mehrmals ausgeführt wird, darf das System nicht kaputt gehen.
2. Schlage niemals Änderungen vor, die externe Web-Ports auf dem VPS öffnen. Neue Web-Dashboards müssen dem Cloudflare Tunnel hinzugefügt werden.
3. Füllst du die `docker-compose.yml` mit einem neuen Service, der dauerhafte Daten (State) generiert, MUSST du im gleichen Atemzug prüfen, ob dieser State in das Backup-Script nach Cloudflare R2 integriert werden muss.
4. **Qualitätssicherung (QS) & Recherche:** Bevor du dem User eine Lösung vorschlägst, MUSS im Internet nach der aktuellsten und stabilsten Best Practice gesucht werden. Der eigene, erste Lösungsansatz muss hart hinterfragt und validiert werden. Erst wenn zweifelsfrei bestätigt ist, dass die vorliegende Lösung robust und state-of-the-art ist, darf sie präsentiert werden.
5. **Git-Workflow:** Führe NIEMALS eigenmächtig einen Push in das GitHub-Repository durch. Nachdem Änderungen am Code vorgenommen wurden, musst du stets den User um die explizite Erlaubnis für einen Push bitten.
