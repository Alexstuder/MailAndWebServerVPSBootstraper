#!/bin/bash
# Wird von certbot nach jedem Renewal automatisch ausgeführt
set -e

STACK_DIR="/home/alex/vps-stack"
source "$STACK_DIR/.env" 2>/dev/null || true
MAIL_DOMAIN="${MAIL_DOMAIN:-alexstuder.cloud}"

cp "/etc/letsencrypt/live/mail.${MAIL_DOMAIN}/fullchain.pem" /tmp/mail-fullchain.pem
cp "/etc/letsencrypt/live/mail.${MAIL_DOMAIN}/privkey.pem" /tmp/mail-privkey.pem
chmod 644 /tmp/mail-fullchain.pem /tmp/mail-privkey.pem

docker cp /tmp/mail-fullchain.pem posteio:/etc/ssl/server-combined.crt
docker cp /tmp/mail-privkey.pem posteio:/etc/ssl/server.key
docker restart posteio

echo "[$(date)] mail.${MAIL_DOMAIN} cert erneuert und in posteio installiert"
