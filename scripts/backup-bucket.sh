#!/usr/bin/env bash
# Respaldo del almacén de instrumentos: copia el bucket público a Google Drive.
#
# Complemento de backup-db.sh, con la misma filosofía: no depende de ningún
# .env del workspace — lee las credenciales de MinIO directamente de dentro del
# contenedor, así que funciona igual lo invoque quien lo invoque.
#
# Lo instala como cron diario la stage "Instalar cron de respaldo diario" del
# Jenkinsfile, junto al respaldo de base de datos.
#
# Por qué existe, si el bucket ya tiene versionado: el versionado protege del
# error humano (un borrado desde la unidad de red montada en Windows), pero no
# de que se pierda el disco del servidor. Esta copia sí.

set -euo pipefail

# Valores por defecto = los de la instalación actual, para que el cron pueda
# invocarlo sin argumentos.
CONTAINER="${MINIO_CONTAINER:-minio-public}"
BUCKET="${MINIO_BUCKET:-archivos-instrumentos}"
# La API de MinIO publicada en el host (ver minio-public/.env). Se usa el puerto
# local y no el dominio público: así el respaldo no depende de Traefik, del DNS
# ni del certificado.
ENDPOINT="${MINIO_ENDPOINT:-http://127.0.0.1:9004}"
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive-cohorte:CohorteApp-Instrumentos}"
SKIP_CLOUD_UPLOAD="${SKIP_CLOUD_UPLOAD:-0}"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(timestamp)] [backup-bucket] $*"; }

if [ "$SKIP_CLOUD_UPLOAD" = "1" ]; then
    log "SKIP_CLOUD_UPLOAD=1 — no hay nada que hacer (este respaldo es solo hacia Drive)."
    exit 0
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    log "El contenedor '$CONTAINER' no está corriendo — se omite el respaldo (probablemente aún no se ha desplegado)."
    exit 0
fi

if ! command -v rclone >/dev/null 2>&1; then
    log "ADVERTENCIA: rclone no está instalado — se omite el respaldo (ver README para el setup inicial)."
    exit 0
fi

# Credenciales leídas del propio contenedor, igual que backup-db.sh hace con la
# contraseña de MySQL. Se pasan a rclone por variables de entorno y no por
# argumentos, para que no queden visibles en la lista de procesos del servidor.
ACCESS_KEY="$(docker exec "$CONTAINER" printenv MINIO_ROOT_USER)"
SECRET_KEY="$(docker exec "$CONTAINER" printenv MINIO_ROOT_PASSWORD)"

if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
    log "ERROR: no se pudieron leer las credenciales de '$CONTAINER'."
    exit 1
fi

# Remoto de rclone definido al vuelo por entorno: no toca ~/.config/rclone y no
# deja credenciales en disco.
export RCLONE_CONFIG_MINIOPUB_TYPE=s3
export RCLONE_CONFIG_MINIOPUB_PROVIDER=Minio
export RCLONE_CONFIG_MINIOPUB_ENDPOINT="$ENDPOINT"
export RCLONE_CONFIG_MINIOPUB_ACCESS_KEY_ID="$ACCESS_KEY"
export RCLONE_CONFIG_MINIOPUB_SECRET_ACCESS_KEY="$SECRET_KEY"
export RCLONE_CONFIG_MINIOPUB_FORCE_PATH_STYLE=true

log "Copiando '$BUCKET' hacia $RCLONE_REMOTE..."

# "copy" y no "sync": un borrado en el bucket NO debe propagarse al respaldo.
# La copia solo transfiere lo que cambió, así que el costo diario es bajo aunque
# el acervo crezca.
if rclone copy "miniopub:$BUCKET" "$RCLONE_REMOTE" --stats-one-line --stats 1m; then
    log "Respaldo completo."
else
    log "ERROR: falló la copia hacia Drive."
    exit 1
fi
