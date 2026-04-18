#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
ask()  { echo -e "${YELLOW}[?]${NC} $1"; }

BOOTSTRAP_VERSION="V.2026.1"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║ VPS Stack — Bootstrap                    ║"
echo "║ Poste.io / Supabase / Flutter Web        ║"
echo "║ ${BOOTSTRAP_VERSION}                              ║"
echo "╚══════════════════════════════════════════╝"
echo ""

[ "$EUID" -ne 0 ] && fail "Bitte als root ausführen"

STACK_DIR="/home/alex/vps-stack"
REPO_URL="https://github.com/Alexstuder/MailAndWebServerVPSBootstraper.git"

# ─────────────────────────────────────────────────────────────
info "Schritt 1/8 — Bitwarden Login..."
echo ""

info "Warten auf Cloud-Init Boot-Prozesse (falls vorhanden)..."
if command -v cloud-init &>/dev/null; then
  cloud-init status --wait >/dev/null 2>&1 || true
fi

export DEBIAN_FRONTEND=noninteractive
info "Lade Updates... (Wartet automatisch, falls Ubuntu im Hintergrund noch Updates fährt)"
apt-get -o DPkg::Lock::Timeout=600 update -y
apt-get -o DPkg::Lock::Timeout=600 install -y curl unzip jq gpg git

if ! command -v bw &>/dev/null; then
  info "Bitwarden CLI installieren..."
  curl -fsSL "https://vault.bitwarden.com/download/?app=cli&platform=linux" \
    -o /tmp/bw.zip
  unzip -q /tmp/bw.zip -d /tmp/bw
  mv /tmp/bw/bw /usr/local/bin/bw
  chmod +x /usr/local/bin/bw
  rm -rf /tmp/bw /tmp/bw.zip
  log "Bitwarden CLI installiert"
fi

ask "Bitwarden E-Mail:"
read -p "  > " BW_EMAIL

ask "Bitwarden Master-Passwort:"
read -s -p "  > " BW_PASSWORD; echo ""

export BW_PASSWORD

ask "Welche Haupt-Domain soll verwendet werden? [Standard: alexstuder.cloud]"
read -p "  > " MAIN_DOMAIN
MAIN_DOMAIN=${MAIN_DOMAIN:-alexstuder.cloud}

info "Verbinde mit Bitwarden..."
bw logout &>/dev/null || true

BW_SESSION=$(bw login "$BW_EMAIL" --passwordenv BW_PASSWORD --raw) \
  || fail "Bitwarden Login fehlgeschlagen — E-Mail, Passwort oder OTP-Code prüfen"

unset BW_PASSWORD

[ -z "$BW_SESSION" ] || [ ${#BW_SESSION} -lt 20 ] \
  && fail "Bitwarden Session ungültig — Login fehlgeschlagen"

log "Bitwarden Login erfolgreich"

info "Secrets aus Bitwarden holen..."

BACKUP_MAIL_GPG_PASSWORD=$(bw get item "BACKUP_MAIL_GPG_PASSWORD" \
  --session "$BW_SESSION" | jq -r '.login.password') \
  || fail "Fehler beim Holen von BACKUP_MAIL_GPG_PASSWORD"

GITHUB_MAIL_TOKEN=$(bw get item "GITHUB_MAIL_TOKEN" \
  --session "$BW_SESSION" | jq -r '.login.password') \
  || fail "Fehler beim Holen von GITHUB_MAIL_TOKEN"

ALEX_USER_PASSWORD=$(bw get item "ALEX_USER_PASSWORD" \
  --session "$BW_SESSION" | jq -r '.login.password') \
  || fail "Fehler beim Holen von ALEX_USER_PASSWORD"

[ -z "$BACKUP_MAIL_GPG_PASSWORD" ] || [ "$BACKUP_MAIL_GPG_PASSWORD" = "null" ] \
  && fail "BACKUP_MAIL_GPG_PASSWORD nicht in Bitwarden gefunden"
[ -z "$GITHUB_MAIL_TOKEN" ] || [ "$GITHUB_MAIL_TOKEN" = "null" ] \
  && fail "GITHUB_MAIL_TOKEN nicht in Bitwarden gefunden"
[ -z "$ALEX_USER_PASSWORD" ] || [ "$ALEX_USER_PASSWORD" = "null" ] \
  && fail "ALEX_USER_PASSWORD nicht in Bitwarden gefunden"

bw lock --session "$BW_SESSION" &>/dev/null || true
unset BW_SESSION BW_EMAIL

log "GPG Passwort + GitHub Token + User-Passwort aus Bitwarden geholt — Bitwarden gesperrt"

# ─────────────────────────────────────────────────────────────
info "Schritt 2/8 — User 'alex' anlegen..."

if id "alex" &>/dev/null; then
  warn "User 'alex' existiert bereits"
else
  useradd -m -s /bin/bash alex
  log "User 'alex' angelegt"
fi

usermod -aG sudo alex

echo "alex:${ALEX_USER_PASSWORD}" | chpasswd
unset ALEX_USER_PASSWORD
log "User 'alex' bereit (sudo)"

# SSH Passwort-Login aktivieren (cloud-init setzt es oft auf 'no')
cat > /etc/ssh/sshd_config.d/99-vps-stack.conf << 'EOF'
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin yes
EOF
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
log "SSH: Passwort-Login aktiviert"

# ─────────────────────────────────────────────────────────────
info "Schritt 3/8 — System + Docker + Auto-Updates installieren..."

export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update -y
apt-get -o DPkg::Lock::Timeout=600 upgrade -y
apt-get -o DPkg::Lock::Timeout=600 install -y \
  curl git unzip jq gpg dnsutils \
  ca-certificates gnupg \
  lsb-release apt-transport-https \
  software-properties-common rclone \
  unattended-upgrades update-notifier-common

if command -v docker &>/dev/null; then
  warn "Docker bereits installiert"
else
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker && systemctl start docker
  log "Docker installiert"
fi

usermod -aG docker alex
log "User 'alex' zur docker-Gruppe hinzugefügt"

cat > /etc/apt/apt.conf.d/51vps-upgrades << 'UPGRADES'
// VPS Stack — Auto-Update Konfiguration
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
    "${distro_id}:${distro_codename}-updates";
    "Docker:${distro_codename}";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:30";
UPGRADES

mkdir -p /etc/systemd/system/apt-daily.timer.d
cat > /etc/systemd/system/apt-daily.timer.d/override.conf << 'TIMER'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:00
RandomizedDelaySec=0
TIMER

mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf << 'TIMER'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:00
RandomizedDelaySec=0
TIMER

systemctl daemon-reload
systemctl enable unattended-upgrades
systemctl restart unattended-upgrades
log "unattended-upgrades konfiguriert (täglich 03:00, Reboot 03:30)"
log "System bereit"

# ─────────────────────────────────────────────────────────────
info "Schritt 4/8 — Repository clonen..."

if [ -d "$STACK_DIR" ]; then
  warn "$STACK_DIR existiert — wird gesichert"
  mv "$STACK_DIR" "${STACK_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
fi

git clone "$REPO_URL" "$STACK_DIR"
cd "$STACK_DIR"

[ ! -f ".env.gpg" ] && warn ".env.gpg existiert (noch) nicht im Repo! Backup & Decrypt wird übersprungen."

if [ -f ".env.gpg" ]; then
  gpg --batch --yes \
    --passphrase "$BACKUP_MAIL_GPG_PASSWORD" \
    --decrypt .env.gpg > .env

  if ! grep -q "^BACKUP_MAIL_GPG_PASSWORD=" "$STACK_DIR/.env"; then
    echo "BACKUP_MAIL_GPG_PASSWORD=${BACKUP_MAIL_GPG_PASSWORD}" >> "$STACK_DIR/.env"
  else
    sed -i "s|^BACKUP_MAIL_GPG_PASSWORD=.*|BACKUP_MAIL_GPG_PASSWORD=${BACKUP_MAIL_GPG_PASSWORD}|" "$STACK_DIR/.env"
  fi
  log ".env entschlüsselt"
else
  info "Erstelle frische .env aus .env.template (Erstinstallation)..."
  cp "$STACK_DIR/.env.template" "$STACK_DIR/.env"
  if ! grep -q "^BACKUP_MAIL_GPG_PASSWORD=" "$STACK_DIR/.env"; then
    echo "BACKUP_MAIL_GPG_PASSWORD=${BACKUP_MAIL_GPG_PASSWORD}" >> "$STACK_DIR/.env"
  else
    sed -i "s|^BACKUP_MAIL_GPG_PASSWORD=.*|BACKUP_MAIL_GPG_PASSWORD=${BACKUP_MAIL_GPG_PASSWORD}|" "$STACK_DIR/.env"
  fi
fi

if [ "$MAIN_DOMAIN" != "alexstuder.cloud" ]; then
  info "Passe Domain in .env an: alexstuder.cloud -> $MAIN_DOMAIN"
  sed -i "s/alexstuder.cloud/${MAIN_DOMAIN}/g" "$STACK_DIR/.env"
fi

if [ -f "$STACK_DIR/bootstrap.sh" ]; then
  chmod +x "$STACK_DIR/bootstrap.sh"
  [ -d "$STACK_DIR/backup" ] && chmod +x "$STACK_DIR/backup/"*.sh 2>/dev/null || true
  log "Scripts ausführbar gemacht"
fi

mkdir -p "$STACK_DIR"/{poste-data,db-data,www}

cat > /etc/sudoers.d/alex-vps-stack << SUDOERS
# sudo Passwort-Timeout: 60 Minuten
Defaults:alex timestamp_timeout=60
# Lesezugriff für Backup-Skripte ohne PW-Prompt
alex ALL=(root) NOPASSWD: /bin/tar
SUDOERS
chmod 440 /etc/sudoers.d/alex-vps-stack
log "sudoers konfiguriert (Lesezugriff für Backups)"

# Rclone Konfiguration für Cloudflare R2
source "$STACK_DIR/.env" 2>/dev/null || true
if [ -n "$CF_R2_ACCESS_KEY" ]; then
  mkdir -p "$STACK_DIR/rclone"
  cat > "$STACK_DIR/rclone/rclone.conf" << RCLONE
[r2]
type = s3
provider = Cloudflare
access_key_id = ${CF_R2_ACCESS_KEY}
secret_access_key = ${CF_R2_SECRET_KEY}
endpoint = ${CF_R2_ENDPOINT}
acl = private
RCLONE
  log "Rclone Config generiert"
fi

chown -R alex:alex "$STACK_DIR" || true

sudo -u alex git -C "$STACK_DIR" remote set-url origin \
  "https://github.com/Alexstuder/MailAndWebServerVPSBootstraper.git"
sudo -u alex git -C "$STACK_DIR" config user.name "alex"
sudo -u alex git -C "$STACK_DIR" config user.email "alex@alexstuder.ch"

# GitHub Token in ~/.netrc hinterlegen → git push ohne manuelle Token-Eingabe
NETRC_FILE="/home/alex/.netrc"
# Bestehenden github.com-Eintrag entfernen (Idempotenz)
grep -v "machine github.com" "$NETRC_FILE" 2>/dev/null > "${NETRC_FILE}.tmp" || true
echo "machine github.com login Alexstuder password ${GITHUB_MAIL_TOKEN}" >> "${NETRC_FILE}.tmp"
mv "${NETRC_FILE}.tmp" "$NETRC_FILE"
chown alex:alex "$NETRC_FILE"
chmod 600 "$NETRC_FILE"
log "GitHub Token in ~/.netrc hinterlegt"

unset GITHUB_MAIL_TOKEN

log "Repository geclont und konfiguriert"

# ─────────────────────────────────────────────────────────────
info "Schritt 5/8 — Backup von R2 wiederherstellen..."

BACKUP_RESTORED=false

if [ -f "$STACK_DIR/rclone/rclone.conf" ]; then
  LATEST=$(rclone ls "r2:${CF_R2_BUCKET}/backups/" \
    --config "$STACK_DIR/rclone/rclone.conf" 2>/dev/null \
    | sort | tail -1 | awk '{print $2}')

  if [ -n "$LATEST" ]; then
    info "Backup gefunden: $LATEST"
    rclone copy "r2:${CF_R2_BUCKET}/backups/$LATEST" /tmp/ \
      --config "$STACK_DIR/rclone/rclone.conf"

    STAGING="/tmp/vps-restore-staging"
    rm -rf "$STAGING" && mkdir -p "$STAGING"

    gpg --batch --yes \
      --passphrase "$BACKUP_MAIL_GPG_PASSWORD" \
      --decrypt "/tmp/$LATEST" \
      | tar -xzp -C "$STAGING/"

    rm -f "/tmp/$LATEST"

    if [ -d "$STAGING/poste-data/" ]; then
      mkdir -p "$STACK_DIR/poste-data"
      cp -rp "$STAGING/poste-data/." "$STACK_DIR/poste-data/"
      BACKUP_RESTORED=true
      log "Poste.io Backup wiederhergestellt"
    fi

    if [ -f "$STAGING/db-data/supabase_dump.sql" ]; then
      mkdir -p "$STACK_DIR/restore"
      cp "$STAGING/db-data/supabase_dump.sql" "$STACK_DIR/restore/supabase_dump.sql"
      log "Supabase SQL-Dump bereitgestellt — wird nach Stack-Start eingespielt"
    elif [ -d "$STAGING/db-data/" ]; then
      # Fallback: altes raw-backup Format
      mkdir -p "$STACK_DIR/db-data"
      cp -rp "$STAGING/db-data/." "$STACK_DIR/db-data/"
      log "Supabase (PostgreSQL) raw-Backup wiederhergestellt"
    fi

    if [ -d "$STAGING/www/" ]; then
      mkdir -p "$STACK_DIR/www"
      cp -rp "$STAGING/www/." "$STACK_DIR/www/"
      log "WWW / Flutter App Backup wiederhergestellt"
    fi

    rm -rf "$STAGING"
    log "Backup vollständig wiederhergestellt aus: $LATEST"
  else
    warn "Kein Backup gefunden — frischer Start"
  fi
else
  warn "Keine Rclone Config vorhanden — verpasse Cloudflare Vars in .env?"
fi

# ─────────────────────────────────────────────────────────────
info "Schritt 6/8 — DNS Validierung & Stack Start..."

source "$STACK_DIR/.env" 2>/dev/null || true

info "Prüfe DNS-Einträge für ${MAIN_DOMAIN}..."
VPS_IP=$(curl -s https://api.ipify.org || echo "Unbekannt")
log "Aktuelle VPS-IP: $VPS_IP"

# Hilfsfunktion für Cloudflare API
update_cf_dns() {
  local type=$1
  local name=$2
  local content=$3
  local proxied=${4:-false}
  local priority=$5

  if [ -z "$CF_API_TOKEN" ] || [ -z "$CF_ZONE_ID" ]; then
    warn "Konnte DNS-Eintrag für $name nicht updaten: CF_API_TOKEN oder CF_ZONE_ID in .env fehlen."
    return
  fi

  local full_name="${name}.$MAIN_DOMAIN"
  [ "$name" = "@" ] && full_name="$MAIN_DOMAIN"

  local data="{\"type\":\"$type\",\"name\":\"$full_name\",\"content\":\"$content\",\"proxied\":$proxied}"
  [ -n "$priority" ] && data="{\"type\":\"$type\",\"name\":\"$full_name\",\"content\":\"$content\",\"proxied\":$proxied,\"priority\":$priority}"

  # Suche ohne Typ-Filter: findet auch CNAMEs die in A-Records umgewandelt werden müssen
  local response
  response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${full_name}" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json")

  local record_id existing_type
  record_id=$(echo "$response" | jq -r '.result[0].id // empty')
  existing_type=$(echo "$response" | jq -r '.result[0].type // empty')

  local result
  if [ -n "$record_id" ] && [ "$existing_type" = "$type" ]; then
    info "Aktualisiere $type-Record für $full_name auf $content (Proxied: $proxied)..."
    result=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/$record_id" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$data")
    if echo "$result" | jq -e '.success' >/dev/null 2>&1; then
      log "Cloudflare $type-Record (ID: $record_id) erfolgreich aktualisiert!"
    else
      warn "CF API Fehler beim Aktualisieren von $full_name: $(echo "$result" | jq -r '.errors[0].message // "unbekannt"')"
    fi
  elif [ -n "$record_id" ] && [ "$existing_type" != "$type" ]; then
    # Falscher Typ (z.B. CNAME statt A) → erst löschen, dann neu erstellen
    info "Lösche $existing_type-Record für $full_name (wird durch $type ersetzt)..."
    curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/$record_id" \
      -H "Authorization: Bearer $CF_API_TOKEN" >/dev/null
    info "Erstelle $type-Record für $full_name auf $content (Proxied: $proxied)..."
    result=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$data")
    if echo "$result" | jq -e '.success' >/dev/null 2>&1; then
      log "Cloudflare $type-Record erfolgreich erstellt (ersetzt $existing_type)!"
    else
      warn "CF API Fehler beim Erstellen von $full_name: $(echo "$result" | jq -r '.errors[0].message // "unbekannt"')"
    fi
  else
    info "Erstelle neuen $type-Record für $full_name auf $content (Proxied: $proxied)..."
    result=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$data")
    if echo "$result" | jq -e '.success' >/dev/null 2>&1; then
      log "Cloudflare $type-Record erfolgreich erstellt!"
    else
      warn "CF API Fehler beim Erstellen von $full_name: $(echo "$result" | jq -r '.errors[0].message // "unbekannt"')"
    fi
  fi
}

if [ -n "$CF_API_TOKEN" ] && [ -n "$CF_ZONE_ID" ]; then
  # mail.DOMAIN — muss unproxied A-Record sein (SMTP/IMAP direkt)
  MAIL_CF=$(curl -s "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=mail.${MAIN_DOMAIN}&type=A" \
    -H "Authorization: Bearer $CF_API_TOKEN" | jq -r '.result[0].content // empty')
  if [ "$MAIL_CF" != "$VPS_IP" ]; then
    warn "🚨 DNS: 'mail.$MAIN_DOMAIN' zeigt nicht auf $VPS_IP (CF: ${MAIL_CF:-fehlt})"
    update_cf_dns "A" "mail" "$VPS_IP" false
  else
    log "[OK] DNS: 'mail.$MAIN_DOMAIN' → $VPS_IP (unproxied)"
  fi

  # webmail.DOMAIN — wird automatisch vom CF Tunnel (Zero Trust Dashboard) als CNAME angelegt
  WEBMAIL_CF=$(curl -s "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=webmail.${MAIN_DOMAIN}&type=CNAME" \
    -H "Authorization: Bearer $CF_API_TOKEN" | jq -r '.result[0].content // empty')
  if [ -z "$WEBMAIL_CF" ]; then
    warn "🚨 DNS: 'webmail.$MAIN_DOMAIN' fehlt!"
    warn "   → Im CF Zero-Trust-Dashboard: Tunnel → Public Hostnames → 'webmail.$MAIN_DOMAIN' → http://nginx:80"
  else
    log "[OK] DNS: 'webmail.$MAIN_DOMAIN' → CNAME (Tunnel)"
  fi

  # ssh.DOMAIN
  SSH_CF=$(curl -s "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=ssh.${MAIN_DOMAIN}&type=A" \
    -H "Authorization: Bearer $CF_API_TOKEN" | jq -r '.result[0].content // empty')
  if [ "$SSH_CF" != "$VPS_IP" ]; then
    warn "🚨 DNS: 'ssh.$MAIN_DOMAIN' zeigt nicht auf $VPS_IP"
    update_cf_dns "A" "ssh" "$VPS_IP" false
  else
    log "[OK] DNS: 'ssh.$MAIN_DOMAIN' → $VPS_IP"
  fi

  # MX-Record
  MX_CF=$(curl -s "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${MAIN_DOMAIN}&type=MX" \
    -H "Authorization: Bearer $CF_API_TOKEN" | jq -r '.result[0].content // empty')
  if [ "$MX_CF" != "mail.$MAIN_DOMAIN" ]; then
    warn "🚨 DNS: MX-Record fehlt oder falsch (ist: ${MX_CF:-leer})"
    update_cf_dns "MX" "@" "mail.$MAIN_DOMAIN" false 10
  else
    log "[OK] DNS: MX → mail.$MAIN_DOMAIN"
  fi
  echo ""
elif command -v dig &>/dev/null; then
  # Fallback ohne CF-Credentials: nur SSH und MX via dig
  SSH_IP=$(dig +short "ssh.$MAIN_DOMAIN" | tail -n1)
  [ "$SSH_IP" != "$VPS_IP" ] && warn "🚨 DNS: ssh.$MAIN_DOMAIN zeigt nicht auf $VPS_IP" || log "[OK] ssh.$MAIN_DOMAIN"
  echo ""
fi

cd "$STACK_DIR"
if [ -f "docker-compose.yml" ]; then
  source "$STACK_DIR/.env" 2>/dev/null || true
  if [ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
    warn ""
    warn "WICHTIG: Das ist die Erstinstallation. Die Umgebungsvariablen (.env) fehlen noch!"
    warn "Ein Start von 'docker-compose' würde jetzt crashen."
    warn ""
    warn "  ➔ 1. Logge dich nach dem Abschluss dieses Skripts als 'alex' ein."
    warn "  ➔ 2. Wechsle ins Verzeichnis: cd $STACK_DIR"
    warn "  ➔ 3. Führe aus: ./set-secret.sh (und hinterlege deine Keys/Passwörter)"
    warn "  ➔ 4. Führe danach aus: docker compose up -d"
    warn ""
  else
    docker compose pull
    docker compose up -d
    sleep 10
    docker compose ps
    log "Docker Stack erfolgreich gestartet"

    # Supabase SQL-Dump einspielen falls vorhanden (aus Backup-Restore)
    if [ -f "$STACK_DIR/restore/supabase_dump.sql" ]; then
      info "Supabase DB-Dump wird eingespielt..."
      for i in $(seq 1 12); do
        if docker exec supabase-db pg_isready -U supabase_admin >/dev/null 2>&1; then
          break
        fi
        sleep 5
      done
      docker exec -i supabase-db psql -U supabase_admin -d postgres \
        < "$STACK_DIR/restore/supabase_dump.sql" >/dev/null 2>&1 \
        && log "Supabase DB-Dump erfolgreich eingespielt" \
        || fail "Fehler beim Einspielen des Supabase DB-Dumps"
      rm -f "$STACK_DIR/restore/supabase_dump.sql"
      rmdir "$STACK_DIR/restore" 2>/dev/null || true
    fi
  fi
else
  warn "Keine docker-compose.yml vorhanden, überspringe Stack-Start."
fi

# ── Portainer Admin via API einrichten ───────────────────────
if [ -n "$PORTAINER_ADMIN_PASSWORD" ]; then
  info "Portainer Admin-Passwort setzen..."
  PORTAINER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' portainer 2>/dev/null || echo "")

  if [ -n "$PORTAINER_IP" ]; then
    for i in $(seq 1 12); do
      HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://${PORTAINER_IP}:9000/api/system/status" 2>/dev/null || echo "000")
      if [ "$HTTP_CODE" = "200" ]; then
        break
      fi
      sleep 5
    done
    INIT_RESPONSE=$(curl -s -X POST "http://${PORTAINER_IP}:9000/api/users/admin/init" \
      -H "Content-Type: application/json" \
      -d "{\"Username\":\"admin\",\"Password\":\"${PORTAINER_ADMIN_PASSWORD}\"}") 
    if echo "$INIT_RESPONSE" | grep -q "jwt"; then
      log "Portainer Admin-User 'admin' eingerichtet"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────
info "Schritt 7/8 — Cron + Firewall + LetsEncrypt..."

(crontab -u alex -l 2>/dev/null; \
  echo "0 2 * * * bash /home/alex/vps-stack/backup/backup-master.sh >> /home/alex/vps-stack/backup/backup.log 2>&1") \
  | crontab -u alex -
log "Backup-Cron eingerichtet (täglich 02:00)"

# LetsEncrypt-Zertifikat für mail.MAIL_DOMAIN
source "$STACK_DIR/.env" 2>/dev/null || true
if [ -n "$CF_API_TOKEN" ] && [ -n "$MAIL_DOMAIN" ]; then
  # certbot + Cloudflare-Plugin installieren
  apt-get install -y -qq certbot python3-certbot-dns-cloudflare

  # Cloudflare-Credentials
  CF_INI="/root/.cloudflare-certbot.ini"
  echo "dns_cloudflare_api_token = ${CF_API_TOKEN}" > "$CF_INI"
  chmod 600 "$CF_INI"

  # Zertifikat holen (idempotent — certbot überspringt wenn noch gültig)
  certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$CF_INI" \
    --dns-cloudflare-propagation-seconds 30 \
    -d "mail.${MAIL_DOMAIN}" \
    --email "admin@${MAIL_DOMAIN}" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring \
    2>&1 | grep -E 'Certificate|error|Saving|Success' || true

  # Deploy-Hook: Cert nach Renewal in poste.io einspielen
  ln -sf "$STACK_DIR/backup/renew-mail-cert.sh" \
    /etc/letsencrypt/renewal-hooks/deploy/mail-posteio.sh

  # Cert sofort in poste.io installieren (falls neu ausgestellt)
  if [ -f "/etc/letsencrypt/live/mail.${MAIL_DOMAIN}/fullchain.pem" ]; then
    cp "/etc/letsencrypt/live/mail.${MAIL_DOMAIN}/fullchain.pem" /tmp/mail-fullchain.pem
    cp "/etc/letsencrypt/live/mail.${MAIL_DOMAIN}/privkey.pem" /tmp/mail-privkey.pem
    chmod 644 /tmp/mail-fullchain.pem /tmp/mail-privkey.pem
    docker cp /tmp/mail-fullchain.pem posteio:/etc/ssl/server-combined.crt
    docker cp /tmp/mail-privkey.pem posteio:/etc/ssl/server.key
    docker restart posteio >/dev/null 2>&1 || true
    log "LetsEncrypt-Cert in posteio installiert"
  fi

  # Cron: Renewal alle 30 Tage (root)
  RENEW_CRON="0 3 1 * * certbot renew --force-renewal --quiet 2>&1 | logger -t certbot-renew"
  ( crontab -l 2>/dev/null | grep -v 'certbot renew'; echo "$RENEW_CRON" ) | crontab -
  log "LetsEncrypt-Renewal-Cron eingerichtet (monatlich 03:00)"
else
  warn "CF_API_TOKEN oder MAIL_DOMAIN fehlt — LetsEncrypt übersprungen"
fi

ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 25/tcp    # SMTP (eingehende Mails)
ufw allow 465/tcp   # SMTPS
ufw allow 587/tcp   # Submission (Brevo Relay / Clients)
ufw allow 143/tcp   # IMAP
ufw allow 993/tcp   # IMAPs
ufw --force enable
log "Firewall (UFW) konfiguriert (SSH + Mail-Ports)"

# ─────────────────────────────────────────────────────────────
info "Schritt 8/8 — Claude Code installieren..."

# Node.js 20 LTS installieren (falls nicht vorhanden oder zu alt)
NODE_OK=false
if command -v node &>/dev/null; then
  NODE_VER=$(node -e "process.exit(process.version.slice(1).split('.')[0] < 18 ? 1 : 0)" 2>/dev/null && echo ok || echo old)
  [ "$NODE_VER" = "ok" ] && NODE_OK=true
fi

if [ "$NODE_OK" = "false" ]; then
  info "Node.js 20 LTS installieren..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
  log "Node.js $(node -v) installiert"
else
  log "Node.js $(node -v) bereits vorhanden — OK"
fi

# npm selbst aktualisieren (vermeidet "new major version" Notice)
npm install -g npm@latest --quiet

# Claude Code global installieren / aktualisieren
if command -v claude &>/dev/null; then
  info "Claude Code bereits installiert — aktualisiere..."
  npm update -g @anthropic-ai/claude-code
else
  info "Claude Code installieren..."
  npm install -g @anthropic-ai/claude-code
fi
log "Claude Code $(claude --version 2>/dev/null || echo 'installiert')"

# ANTHROPIC_API_KEY aus .env in User-Umgebung eintragen
source "$STACK_DIR/.env" 2>/dev/null || true
if [ -n "$ANTHROPIC_API_KEY" ]; then
  BASHRC="/home/alex/.bashrc"
  # Alte Einträge entfernen (Idempotenz)
  sed -i '/^export ANTHROPIC_API_KEY=/d' "$BASHRC" 2>/dev/null || true
  echo "export ANTHROPIC_API_KEY=\"${ANTHROPIC_API_KEY}\"" >> "$BASHRC"
  log "ANTHROPIC_API_KEY in ~/.bashrc von user 'alex' gesetzt"

  # ANTHROPIC_API_KEY in Claude Code Config hinterlegen
  CLAUDE_CONFIG="/home/alex/.claude.json"
  if [ -f "$CLAUDE_CONFIG" ]; then
    tmp=$(mktemp)
    jq --arg key "$ANTHROPIC_API_KEY" '.apiKey = $key' "$CLAUDE_CONFIG" > "$tmp" && mv "$tmp" "$CLAUDE_CONFIG"
  else
    echo "{\"apiKey\":\"${ANTHROPIC_API_KEY}\"}" > "$CLAUDE_CONFIG"
  fi
  chown alex:alex "$CLAUDE_CONFIG"
  chmod 600 "$CLAUDE_CONFIG"
  log "ANTHROPIC_API_KEY in ~/.claude.json von user 'alex' gesetzt"
else
  warn "ANTHROPIC_API_KEY nicht in .env gefunden"
  warn "  ➔ Nachholen mit: ./set-secret.sh ANTHROPIC_API_KEY"
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║ Installation abgeschlossen!              ║"
echo "║ ${BOOTSTRAP_VERSION}                              ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Stack: $STACK_DIR"
echo "  User:  alex (sudo, docker)"
echo ""
echo "  Zeitplan (UTC):"
echo "    02:00 — Backup → R2 + Status-Mail"
echo "    02:30 — Watchtower → Container-Updates"
echo "    03:00 — unattended-upgrades → System + Docker Engine"
echo "    03:30 — Automatischer Neustart (falls Kernel-Update)"
echo ""
echo "  Claude Code: 'claude' im Terminal (als User alex)"
echo ""
echo "  iPhone Mail-Setup (Profil öffnen im Safari):"
source "$STACK_DIR/.env" 2>/dev/null || true
echo "  https://${WEB_DOMAIN:-www.${MAIL_DOMAIN}}/mail-setup.mobileconfig"
echo ""
echo "  HINWEIS: Bitte per SSH als User 'alex' neu anmelden,"
echo "           damit die Docker-Rechte (usermod) aktiv werden:"
echo "           su - alex"
echo ""
