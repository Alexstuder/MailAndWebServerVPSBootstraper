#!/bin/bash
set -e

# ==============================================================================
# VPS STACK - SECRET MANAGER
# Erlaubt sicheres Ändern von .env Variablen, automatische GPG 
# Neu-Verschlüsselung und sauberen Push ins GitHub Repo.
# ==============================================================================

STACK_DIR="/home/alex/vps-stack"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
ask()  { echo -e "${YELLOW}[?]${NC} $1"; }

[ ! -f "$STACK_DIR/.env" ] && fail ".env nicht gefunden: $STACK_DIR/.env"

source "$STACK_DIR/.env"

[ -z "$BACKUP_MAIL_GPG_PASSWORD" ] && fail "BACKUP_MAIL_GPG_PASSWORD fehlt in .env. Führe erst bootstrap.sh aus!"

# ── 1. git pull ──────────────────────────────────────────────
info "git pull — aktuellen Stand holen..."
cd "$STACK_DIR"
git pull origin main || fail "git pull fehlgeschlagen"
log "git pull — OK"

# ── Secret Name + Wert bestimmen ────────────────────────────
if [ -n "$1" ] && [ -n "$2" ]; then
  SECRET_NAME="$1"
  SECRET_VALUE="$2"
elif [ -n "$1" ] && [ -z "$2" ]; then
  SECRET_NAME="$1"
  ask "Wert für $SECRET_NAME:"
  read -s -p "  > " SECRET_VALUE; echo ""
else
  echo ""
  echo "Verfügbare Setup-Secrets:"
  echo ""
  SECRETS=(
    MAIL_DOMAIN
    API_EXTERNAL_URL
    CLOUDFLARE_TUNNEL_TOKEN
    CF_API_TOKEN
    CF_ZONE_ID
    POSTGRES_PASSWORD
    JWT_SECRET
    CF_R2_ACCESS_KEY
    CF_R2_SECRET_KEY
    CF_R2_BUCKET
    CF_R2_ENDPOINT
    PORTAINER_ADMIN_PASSWORD
    BREVO_SMTP_USER
    BREVO_SMTP_API_KEY
    ANTHROPIC_API_KEY
    BACKUP_MAIL_GPG_PASSWORD
  )
  for i in "${!SECRETS[@]}"; do
    echo "  $((i+1)). ${SECRETS[$i]}"
  done
  echo ""
  ask "Welches Secret? (Nummer oder Name eingeben):"
  read -p "  > " CHOICE

  if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
    SECRET_NAME="${SECRETS[$((CHOICE-1))]}"
    [ -z "$SECRET_NAME" ] && fail "Ungültige Auswahl"
  else
    SECRET_NAME="$CHOICE"
  fi

  ask "Neuer Wert für $SECRET_NAME:"
  read -s -p "  > " SECRET_VALUE; echo ""
fi

[ -z "$SECRET_NAME" ]  && fail "Kein Secret-Name angegeben"
[ -z "$SECRET_VALUE" ] && fail "Kein Wert angegeben"

echo ""
info "Aktualisiere: $SECRET_NAME"

# ── 2. .env aktualisieren ────────────────────────────────────
info ".env aktualisieren..."
if grep -q "^${SECRET_NAME}=" "$STACK_DIR/.env"; then
  sed -i "s|^${SECRET_NAME}=.*|${SECRET_NAME}=${SECRET_VALUE}|" "$STACK_DIR/.env"
  log ".env aktualisiert"
else
  echo "${SECRET_NAME}=${SECRET_VALUE}" >> "$STACK_DIR/.env"
  log ".env — neuer Eintrag hinzugefügt"
fi

unset SECRET_VALUE

# ── 3. .env verschlüsseln → .env.gpg ────────────────────────
info ".env verschlüsseln..."
gpg --batch --yes \
  --passphrase "$BACKUP_MAIL_GPG_PASSWORD" \
  --symmetric \
  --cipher-algo AES256 \
  -o "$STACK_DIR/.env.gpg" \
  "$STACK_DIR/.env" || fail "GPG Verschlüsselung fehlgeschlagen"
log ".env.gpg aktualisiert"

# ── 4. git commit + push ─────────────────────────────────────
info "git push..."
cd "$STACK_DIR"
git add .env.gpg
git diff --cached --quiet && warn "Keine Änderung in .env.gpg — kein Commit nötig" || {
  git commit -m "secret: ${SECRET_NAME} gesichert und aktualisiert"
  git push origin main || fail "git push fehlgeschlagen"
  log "git push — OK"
}

# ── 5. Container neu starten? ────────────────────────────────
echo ""

case "$SECRET_NAME" in
  CLOUDFLARE_TUNNEL_TOKEN)
    CONTAINER="cloudflared"
    ;;
  MAIL_DOMAIN|BREVO_SMTP_USER|BREVO_SMTP_API_KEY)
    CONTAINER="posteio"
    ;;
  POSTGRES_PASSWORD|JWT_SECRET|API_EXTERNAL_URL)
    CONTAINER="supabase-db supabase-auth supabase-rest supabase-studio supabase-meta supabase-realtime supabase-storage"
    ;;
  ANTHROPIC_API_KEY)
    # Kein Container — nur Umgebungsvariable für User alex neu setzen
    if [ -f /home/alex/.bashrc ]; then
      sed -i '/^export ANTHROPIC_API_KEY=/d' /home/alex/.bashrc
      echo "export ANTHROPIC_API_KEY=\"${ANTHROPIC_API_KEY}\"" >> /home/alex/.bashrc
      log "ANTHROPIC_API_KEY in /home/alex/.bashrc aktualisiert — neu anmelden oder: source ~/.bashrc"
    fi
    CONTAINER=""
    ;;
  *)
    CONTAINER=""
    ;;
esac

if [ -n "$CONTAINER" ]; then
  ask "Betroffene(n) Container '$CONTAINER' neu starten? (j/n)"
  read -p "  > " RESTART
  if [ "$RESTART" = "j" ] || [ "$RESTART" = "J" ]; then
    cd "$STACK_DIR"
    docker compose up -d --force-recreate $CONTAINER
    log "$CONTAINER neu gestartet um neues Secret zu übernehmen"
  else
    warn "Container laufen noch mit altem Wert — manuell neu starten:"
    warn "  cd $STACK_DIR && docker compose up -d --force-recreate $CONTAINER"
  fi
fi

echo ""
log "Fertig — $SECRET_NAME aktualisiert und sicher in Github verankert"
echo ""
