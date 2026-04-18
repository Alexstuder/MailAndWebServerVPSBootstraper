#!/bin/bash
set -e

# ==============================================================================
# VPS STACK - BACKUP MASTER SCRIPT
# ==============================================================================

STACK_DIR="/home/alex/vps-stack"
STAGING="/tmp/vps-backup-staging"
LOG="$STACK_DIR/backup/backup.log"
DATE=$(date '+%Y-%m-%d_%H-%M-%S')
DAY_OF_WEEK=$(date '+%u')  # 7 = Sonntag

mkdir -p "$STACK_DIR/backup"
touch "$LOG"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] $1" | tee -a "$LOG"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [!!] $1" | tee -a "$LOG"; }
info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [--] $1" | tee -a "$LOG"; }

echo "" >> "$LOG"
info "======== Backup Start: $DATE ========"

source "$STACK_DIR/.env"

# 1. Sicherung der .env Datei (immer synchronisieren, falls Änderungen stattfanden)
info ".env absichern und prüfen..."
if [ -f "$STACK_DIR/.env" ]; then
  gpg --batch --yes \
    --passphrase "$BACKUP_MAIL_GPG_PASSWORD" \
    --symmetric --cipher-algo AES256 \
    -o "$STACK_DIR/.env.gpg" "$STACK_DIR/.env"
  
  if cd "$STACK_DIR" && git diff --quiet ".env.gpg"; then
    info ".env.gpg hat sich im Git nicht verändert"
  else
    git add .env.gpg
    # Git Push als User 'alex' (cron läuft als alex)
    git commit -m "update: .env.gpg auto-sync $(date '+%Y-%m-%d')" >/dev/null || true
    git push origin main >/dev/null || true
    log ".env.gpg nach GitHub gepusht"
  fi
fi

# 2. Volumes vorbereiten
info "Sammle Volume-Daten für das Backup..."
rm -rf "$STAGING"
mkdir -p "$STAGING"

# Da poste-data und db-data teils root-Rechte haben (Docker Volumes),
# kopieren wir die reinen Daten via sudo-tar Trick in den Staging-Ordner.
# Das sudoers-File erlaubt dem User alex exakt diesen Befehl ohne PW.

# Poste.io Data (ohne var/clamav + var/rspamd — werden vom Image neu geladen)
mkdir -p "$STAGING/poste-data"
sudo -n /bin/tar -czpf - -C "$STACK_DIR/poste-data" \
  --exclude="./var/clamav" --exclude="./var/rspamd" \
  --exclude="./log" \
  . 2>/dev/null | tar -xzf - -C "$STAGING/poste-data" || fail "Fehler bei poste-data"

# Supabase DB Data
if [ -d "$STACK_DIR/db-data" ]; then
  mkdir -p "$STAGING/db-data"
  sudo -n /bin/tar -czpf - -C "$STACK_DIR/db-data" \
    --exclude="./pg_wal" --exclude="./pg_log" --exclude="./pg_stat_tmp" \
    . 2>/dev/null | tar -xzf - -C "$STAGING/db-data" || fail "Fehler bei db-data"
fi

# Flutter Web (www)
if [ -d "$STACK_DIR/www" ]; then
  mkdir -p "$STAGING/www"
  cp -rp "$STACK_DIR/www/." "$STAGING/www/" 2>/dev/null || true
fi

# 3. Verschlüsselung & Tar
IS_SUNDAY=false
[ "$DAY_OF_WEEK" = "7" ] && IS_SUNDAY=true

if $IS_SUNDAY; then
  FILENAME="backup-WEEKLY-${DATE}.tar.gz.gpg"
else
  FILENAME="backup-${DATE}.tar.gz.gpg"
fi

info "Erstelle verschlüsseltes Archiv: $FILENAME"
# Wir packen alle Ordner (poste-data, db-data, www) in ein Archiv und verschlüsseln es direkt
tar -czf - -C "$STAGING" . | \
  gpg --batch --yes --symmetric \
      --cipher-algo AES256 \
      --passphrase "$BACKUP_MAIL_GPG_PASSWORD" \
      -o "/tmp/$FILENAME"

BACKUP_SIZE=$(du -sh "/tmp/$FILENAME" | cut -f1)
log "Archiv fertiggestellt ($BACKUP_SIZE)"

# 4. Upload nach Cloudflare R2
info "Lade Backup in Cloudflare R2 hoch..."
rclone copy "/tmp/$FILENAME" "r2:${CF_R2_BUCKET}/backups/" \
  --config "$STACK_DIR/rclone/rclone.conf"
log "Upload erfolgreich!"

# Aufräumen lokal
rm -f "/tmp/$FILENAME"
rm -rf "$STAGING"

# 5. Rotation (alte Backups löschen)
info "Bereinige alte Backups (Rotation 7 Dailies / 4 Weeklies)..."

# Dailies rotieren (7 behalten)
NORMAL_BACKUPS=$(rclone ls "r2:${CF_R2_BUCKET}/backups/" \
  --config "$STACK_DIR/rclone/rclone.conf" \
  | sort | awk '{print $2}' | grep -v 'WEEKLY' || true)
COUNT=$(echo "$NORMAL_BACKUPS" | grep -v '^[[:space:]]*$' | wc -l || echo 0)
if [ "$COUNT" -gt 7 ]; then
  TO_DELETE=$(echo "$NORMAL_BACKUPS" | head -n $((COUNT - 7)))
  for F in $TO_DELETE; do
    rclone delete "r2:${CF_R2_BUCKET}/backups/$F" --config "$STACK_DIR/rclone/rclone.conf"
    info "Gelöscht (Daily rot.): $F"
  done
fi

# Weeklies rotieren (4 behalten)
WEEKLY_BACKUPS=$(rclone ls "r2:${CF_R2_BUCKET}/backups/" \
  --config "$STACK_DIR/rclone/rclone.conf" \
  | sort | awk '{print $2}' | grep 'WEEKLY' || true)
COUNT=$(echo "$WEEKLY_BACKUPS" | grep -v '^[[:space:]]*$' | wc -l || echo 0)
if [ "$COUNT" -gt 4 ]; then
  TO_DELETE=$(echo "$WEEKLY_BACKUPS" | head -n $((COUNT - 4)))
  for F in $TO_DELETE; do
    rclone delete "r2:${CF_R2_BUCKET}/backups/$F" --config "$STACK_DIR/rclone/rclone.conf"
    info "Gelöscht (Weekly rot.): $F"
  done
fi

log "Rotation abgeschlossen."

# 6. Status E-Mail Senden
if [ -n "$BREVO_KEY" ] && [ -n "$MAIL_DOMAIN" ]; then
  SUBJECT="VPS Backup ($MAIL_DOMAIN) - $DATE - OK"
  BODY="Das tägliche Backup ($BACKUP_SIZE) wurde erfolgreich verschlüsselt und nach Cloudflare R2 hochgeladen."
  
  PAYLOAD=$(jq -n \
    --arg from_name "VPS Backup" \
    --arg from_email "bot@${MAIL_DOMAIN}" \
    --arg to_email "admin@${MAIL_DOMAIN}" \
    --arg subject "$SUBJECT" \
    --arg body "$BODY" \
    '{
      sender: {name: $from_name, email: $from_email},
      to: [{email: $to_email}],
      subject: $subject,
      textContent: $body
    }')
    
  curl -s -X POST "https://api.brevo.com/v3/smtp/email" \
    -H "api-key: ${BREVO_KEY}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" >/dev/null || true
  log "Status Mail gesendet."
fi

info "======== Backup Erfolgreich beendet ========"
exit 0
