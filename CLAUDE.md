# VPS Bootstrapper — Mailserver & Web/Supabase (Ubuntu 24.04)

## 1. Netzwerk-Architektur (Zero-Trust)
* Keine offenen Web-Ports. Einziger Web-Zugang: `cloudflared` (Cloudflare Tunnel).
* Ausnahme Mailserver: Ports 25, 465, 587, 143, 993 direkt durchgereicht.
* Alle Container kommunizieren intern über Docker Bridge `vps-net`.
* Neues Web-Dashboard → Cloudflare Tunnel + nginx-Template, NIE direkten Port öffnen.

## 2. Multi-VPS & Cloudflare Tunnel
* Jeder VPS/Domain braucht einen **eigenen** Tunnel (Zero Trust Dashboard → Networks → Tunnels).
* `CLOUDFLARE_TUNNEL_TOKEN` ist tunnel-spezifisch — niemals zwischen VPS teilen.
* Alle Subdomains laufen durch nginx als Reverse Proxy. Neuer Service = Eintrag im CF-Tunnel + nginx-Template.
* `CF_ZONE_ID` ist domain-spezifisch (eine Zone pro Domain in Cloudflare).

## 3. Domain-Variablen
* `MAIL_DOMAIN` = Root-Mail-Domain (z.B. `alexstuder.cloud`) — für SMTP-Hostname & MX-Record.
* nginx-Template nutzt `mail.${MAIL_DOMAIN}` für das Webmail-Interface (nicht `${MAIL_DOMAIN}` direkt).
* Alle Domains sind variabel über `.env` — nie hartverdrahtet.
* **Testdomain:** `alexstuder.cloud` → **Produktionsdomain:** `alexstuder.ch` (Migration noch ausstehend).

## 4. Secrets & Security
* Keine Klartextgeheimnisse im Code. Alles in `.env`, verschlüsselt als `.env.gpg` (GPG symmetrisch AES256).
* GPG-Passphrase (`BACKUP_MAIL_GPG_PASSWORD`) liegt in Bitwarden; `bootstrap.sh` holt sie via Bitwarden-CLI.
* GitHub-Push erfordert Token (`GITHUB_MAIL_TOKEN`) aus Bitwarden — immer beim User anfragen.

## 5. Storage, State & Backups
* Repo ist stateless (nur Config/Code). State in Docker Volumes (`poste-data`, `db-data`, etc.).
* Neuer Service mit State → Backup-Script prüfen (`backup/backup-master.sh` → Cloudflare R2, täglich 02:00).

## 6. Supabase DB-Initialisierung (kritisch)
* `volumes/db/init/00-data.sql` — erstellt ALLE Rollen, Schemas und Grants.
* `volumes/db/init/01-passwords.sh` — setzt Passwörter für alle Service-Accounts.
* Das `supabase/postgres`-Image erstellt nur `supabase_admin`. Alle anderen Rollen (auth, storage, realtime, etc.) kommen ausschliesslich aus diesen Init-Skripten.
* `db-data/` löschen = kompletter Datenverlust + Init-Skripte laufen beim nächsten Start neu durch.
* Bei Supabase-Problemen zuerst `volumes/db/init/` prüfen.

## 7. Technologie-Stack
* **Web:** Flutter-Web als statisches Bundle via `nginx:alpine` (`www/index.html` als Platzhalter). Kein Node.js.
* **Backend:** Offizieller Supabase-Stack (Kong, Auth, REST, Studio, Realtime, Storage, Meta).
* **Kong:** Env-Substitution via `supabase_config/kong-entrypoint.sh` mit `sed` (`envsubst` nicht im Kong-Image).
* **nginx:** Env-Substitution via `envsubst`-Templates in `nginx/templates/`.
* **poste.io:** Config-Overrides in `poste-config/` (z.B. `worker-controller.inc` für rspamd Unix-Socket).
* **Mail:** Supabase Auth sendet Mails lokal über poste.io (intern Port 25).

## Anweisungen an KIs
1. **Idempotenz:** `bootstrap.sh` muss mehrfach ausführbar sein ohne Schaden.
2. **Keine Web-Ports öffnen.** Neues Dashboard → Cloudflare Tunnel + nginx.
3. **State + Backup:** Neuer Service mit persistenten Daten → Backup-Script anpassen.
4. **Vor Push:** Explizit beim User nach GitHub-Token (`GITHUB_MAIL_TOKEN`) fragen.
5. **Supabase-DB-Probleme:** Immer zuerst `volumes/db/init/` und DB-Logs prüfen.
6. **QS:** Lösungen vor Präsentation auf aktuelle Best Practices validieren.
