#!/bin/sh
# Configuración inicial del almacén de instrumentos. Lo ejecuta el contenedor
# "minio-public-init" en cada "docker compose up", y es idempotente: correrlo
# de nuevo no duplica nada ni pisa lo que ya esté configurado.
#
# Deja el bucket:
#   - creado y con versionado activo (un borrado accidental se puede deshacer),
#   - con política de lectura anónima (público por URL, escritura autenticada),
#   - con cuota y con purga de versiones antiguas,
#   - y con el usuario de subida dado de alta, acotado a ese bucket.
#
# Los comandos de "mc" cambiaron de nombre entre releases y la imagen no está
# fijada a una versión, así que cada paso contempla la sintaxis nueva y la
# anterior. Ningún paso opcional aborta el script: se registra la advertencia y
# se sigue, para que un cambio de sintaxis no deje el bucket a medio configurar.

set -eu

BUCKET="${MINIO_PUBLIC_BUCKET}"
QUOTA="${MINIO_PUBLIC_QUOTA:-50gb}"
NONCURRENT_DAYS="${MINIO_PUBLIC_NONCURRENT_DAYS:-30}"
UPLOADER_USER="${MINIO_PUBLIC_UPLOADER_USER}"
UPLOADER_PASSWORD="${MINIO_PUBLIC_UPLOADER_PASSWORD}"
PUBLIC_HOST="${MINIO_PUBLIC_HOST}"
POLICY_NAME="${BUCKET}-rw"

log()  { echo "[init-bucket] $*"; }
warn() { echo "[init-bucket] ADVERTENCIA: $*"; }

# ── Conexión ─────────────────────────────────────────────────────────────────
# Por la red interna de Docker, no por el dominio público: así este paso no
# depende de que Traefik ya haya emitido el certificado ni de que el DNS resuelva.
log "Conectando con minio-public..."
mc alias set pub "http://minio-public:9000" \
    "$MINIO_PUBLIC_ROOT_USER" "$MINIO_PUBLIC_ROOT_PASSWORD" >/dev/null

# ── Bucket y versionado ──────────────────────────────────────────────────────
log "Creando bucket '$BUCKET' (si no existe)..."
mc mb --ignore-existing "pub/$BUCKET"

log "Activando versionado..."
mc version enable "pub/$BUCKET" >/dev/null

# ── Acceso público de SOLO LECTURA ───────────────────────────────────────────
# "download" = cualquiera con la URL descarga; nadie sube, nadie borra y nadie
# puede listar el contenido del bucket. La alternativa "public" permitiría
# escritura anónima: no usarla nunca aquí.
log "Aplicando política de lectura anónima..."
mc anonymous set download "pub/$BUCKET" >/dev/null

# ── Cuota ────────────────────────────────────────────────────────────────────
log "Fijando cuota en $QUOTA..."
mc quota set "pub/$BUCKET" --size "$QUOTA" >/dev/null 2>&1 \
    || mc admin bucket quota "pub/$BUCKET" --hard "$QUOTA" >/dev/null 2>&1 \
    || warn "no se pudo fijar la cuota (revisar la sintaxis de 'mc quota' de esta versión)."

# ── Purga de versiones antiguas ──────────────────────────────────────────────
# Se añade solo si el bucket todavía no tiene ninguna regla: "ilm rule add" no
# es idempotente y en cada deploy agregaría una regla duplicada.
# "mc ilm rule ls" falla cuando el bucket no tiene ninguna configuración de
# ciclo de vida, que es justo la condición para crearla.
if mc ilm rule ls "pub/$BUCKET" >/dev/null 2>&1; then
    log "Ya existe configuración de ciclo de vida; no se toca."
else
    log "Purgando versiones no vigentes después de $NONCURRENT_DAYS días..."
    mc ilm rule add --noncurrent-expire-days "$NONCURRENT_DAYS" "pub/$BUCKET" >/dev/null 2>&1 \
        || mc ilm add --noncurrent-expiration-days "$NONCURRENT_DAYS" "pub/$BUCKET" >/dev/null 2>&1 \
        || warn "no se pudo crear la regla de ciclo de vida; el versionado crecerá sin tope hasta que se configure a mano."
fi

# ── Política del usuario de subida ───────────────────────────────────────────
# Lectura y escritura acotadas a este bucket. A propósito NO es "s3:*": eso
# incluiría cambiar la política del bucket, es decir, la posibilidad de abrirlo
# a escritura anónima desde una credencial de subida.
cat > /tmp/policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
        "s3:GetBucketLocation"
      ],
      "Resource": ["arn:aws:s3:::$BUCKET"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": ["arn:aws:s3:::$BUCKET/*"]
    }
  ]
}
EOF

log "Registrando política '$POLICY_NAME'..."
mc admin policy create pub "$POLICY_NAME" /tmp/policy.json >/dev/null 2>&1 \
    || mc admin policy add pub "$POLICY_NAME" /tmp/policy.json >/dev/null 2>&1 \
    || warn "no se pudo registrar la política."

# ── Usuario de subida ────────────────────────────────────────────────────────
if mc admin user info pub "$UPLOADER_USER" >/dev/null 2>&1; then
    log "El usuario '$UPLOADER_USER' ya existe; no se toca su contraseña."
else
    log "Dando de alta al usuario '$UPLOADER_USER'..."
    mc admin user add pub "$UPLOADER_USER" "$UPLOADER_PASSWORD" >/dev/null \
        || warn "no se pudo crear el usuario de subida."
fi

mc admin policy attach pub "$POLICY_NAME" --user "$UPLOADER_USER" >/dev/null 2>&1 \
    || mc admin policy set pub "$POLICY_NAME" "user=$UPLOADER_USER" >/dev/null 2>&1 \
    || log "La política ya estaba asignada a '$UPLOADER_USER'."

# ── Resumen ──────────────────────────────────────────────────────────────────
log "Listo."
log "  Bucket:      $BUCKET"
log "  URL pública: https://$PUBLIC_HOST/$BUCKET/<objeto>"
log "  Endpoint S3: https://$PUBLIC_HOST  (path-style, para rclone)"
