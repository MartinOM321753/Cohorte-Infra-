#!/usr/bin/env bash
# Respaldo de la base de datos de CohorteApp: dump local + copia en Google Drive.
#
# Se usa desde dos lugares distintos con el mismo comportamiento:
#   1. Jenkinsfile, justo antes de "docker compose down" en cada deploy.
#   2. Cron diario en el servidor (independiente de Jenkins), instalado por
#      la propia stage "Instalar cron de respaldo diario" del pipeline.
#
# No depende del .env del deploy: lee MYSQL_ROOT_PASSWORD directamente de
# dentro del contenedor de la base de datos, así que funciona igual sin
# importar quién lo invoque.

set -euo pipefail

# Todo es sobreescribible por variable de entorno: los valores por defecto son
# los de PRODUCCION, para que invocarlo sin argumentos siga respaldando prod
# igual que siempre (asi lo hace el cron diario).
#
# Staging exporta DB_CONTAINER/BACKUP_DIR propios y SKIP_CLOUD_UPLOAD=1 para no
# mezclar sus dumps de prueba con los respaldos reales en Drive.
BACKUP_DIR="${BACKUP_DIR:-${HOME}/backups/cohorte}"
DB_CONTAINER="${DB_CONTAINER:-cohorte-database}"
DB_NAME="${DB_NAME:-cohorte}"
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive-cohorte:CohorteApp-Backups}"
SKIP_CLOUD_UPLOAD="${SKIP_CLOUD_UPLOAD:-0}"
LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-14}"
CLOUD_RETENTION_DAYS="${CLOUD_RETENTION_DAYS:-30}"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(timestamp)] [backup-db] $*"; }

mkdir -p "$BACKUP_DIR"

if ! docker ps --format '{{.Names}}' | grep -qx "$DB_CONTAINER"; then
    log "El contenedor '$DB_CONTAINER' no está corriendo — se omite el respaldo (probablemente aún no existe, ej. primer deploy)."
    exit 0
fi

FILENAME="cohorte_$(date +%Y-%m-%d_%H%M%S).sql.gz"
DUMP_PATH="$BACKUP_DIR/$FILENAME"

log "Generando dump de '$DB_NAME'..."
# $MYSQL_ROOT_PASSWORD queda escapado a propósito: debe expandirlo el shell
# DENTRO del contenedor (donde sí existe esa variable), no este script.
REMOTE_CMD="exec mysqldump -u root -p\"\$MYSQL_ROOT_PASSWORD\" --single-transaction --no-tablespaces --routines --triggers $DB_NAME"

if ! docker exec "$DB_CONTAINER" sh -c "$REMOTE_CMD" | gzip > "$DUMP_PATH"; then
    log "ERROR: mysqldump falló."
    rm -f "$DUMP_PATH"
    exit 1
fi

if [ ! -s "$DUMP_PATH" ]; then
    log "ERROR: el dump quedó vacío."
    rm -f "$DUMP_PATH"
    exit 1
fi

log "Dump generado: $DUMP_PATH ($(du -h "$DUMP_PATH" | cut -f1))"

if [ "$SKIP_CLOUD_UPLOAD" = "1" ]; then
    log "SKIP_CLOUD_UPLOAD=1 — se omite la subida a Drive (solo respaldo local)."
elif command -v rclone >/dev/null 2>&1; then
    log "Subiendo copia a Google Drive ($RCLONE_REMOTE)..."
    if rclone copy "$DUMP_PATH" "$RCLONE_REMOTE"; then
        log "Subida a Drive exitosa."
    else
        log "ADVERTENCIA: falló la subida a Drive. La copia local se conserva de todas formas."
    fi
else
    log "ADVERTENCIA: rclone no está instalado — se omite la subida a Drive (ver README para el setup inicial)."
fi

log "Limpiando respaldos locales con más de $LOCAL_RETENTION_DAYS días..."
find "$BACKUP_DIR" -maxdepth 1 -name 'cohorte_*.sql.gz' -mtime "+$LOCAL_RETENTION_DAYS" -delete

if [ "$SKIP_CLOUD_UPLOAD" != "1" ] && command -v rclone >/dev/null 2>&1; then
    log "Limpiando respaldos en Drive con más de $CLOUD_RETENTION_DAYS días..."
    rclone delete "$RCLONE_REMOTE" --min-age "${CLOUD_RETENTION_DAYS}d" || log "ADVERTENCIA: no se pudo aplicar la retención en Drive."
fi

log "Respaldo completo."
