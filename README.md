# Cohorte-Infra

Repositorio de orquestación para CohorteApp: `docker-compose.yml` + `Jenkinsfile`.
No contiene código de aplicación — el backend (`Cohorte-IMSS`) y el frontend
(`Cohorte-front`) se clonan en tiempo de build dentro del workspace de Jenkins,
en `./cohorte_test` y `./client` respectivamente (ver `.gitignore`).

Ninguna credencial real vive en este repo. `.env.example` es una plantilla con
valores ficticios; el `.env` real solo existe en disco (nunca se commitea) y en
producción lo genera el propio Jenkinsfile a partir de credenciales de Jenkins.

## Requisitos en el servidor (una sola vez)

```
docker network create cohorte-net
docker volume create cohorte-volume
docker volume create minio-volume
```

El compose declara red y volúmenes como `external: true` para que sobrevivan a
un `docker compose down` (no se pierden datos entre despliegues).

## Desarrollo / prueba manual local

```
git clone https://github.com/MartinOM321753/Cohorte-IMSS.git cohorte_test
git clone https://github.com/MartinOM321753/Cohorte-front.git client
cp .env.example .env   # y completa los valores reales
docker compose -p cohorteapp up --build -d
```

## Configuración de Jenkins

### 1. Credencial (Manage Jenkins → Credentials → Global)

Una sola credencial tipo **Secret file**:

1. *Add Credentials* → **Kind**: `Secret file`.
2. **File**: sube tu `.env` real completo (el mismo que usas en local, con
   `FRONTEND_URL` apuntando al dominio real de producción, no a `localhost`).
3. **ID**: `cohorte-env-file` (el Jenkinsfile lo referencia por este nombre exacto).
4. *Create*.

Cuando cambie cualquier valor (rotas una contraseña, cambias el dominio, etc.),
edita esa misma credencial y vuelve a subir el archivo actualizado — no hay que
tocar el Jenkinsfile.

> Alternativa más granular: si prefieres una credencial por variable (más fácil
> de auditar quién cambió qué, pero más tedioso de mantener), se puede volver al
> esquema de 8 `Secret text` + `withCredentials([string(...), ...])` armando el
> `.env` línea por línea en el Jenkinsfile. No es la opción actual de este repo.

Si `Cohorte-IMSS` o `Cohorte-front` son repos privados, agrega además una
credencial de tipo **Username with password** (token de GitHub) y úsala en el
job (Pipeline → "Use a credential" o vía `git` con `credentialsId` en el clone).

### 2. Crear el job

- Tipo: **Pipeline** (o **Multibranch Pipeline** si quieres builds de verificación
  en otras ramas, sin desplegar — el Jenkinsfile ya filtra y solo despliega en `main`).
- "Pipeline script from SCM" → Git → URL de este repo (`Cohorte-Infra`) → rama `main`.
- Build Triggers: **"GitHub hook trigger for GITScm polling"**.

### 3. Webhook en GitHub

En el repo `Cohorte-Infra` (Settings → Webhooks → Add webhook):
- Payload URL: `http://<tu-jenkins>/github-webhook/`
- Content type: `application/json`
- Evento: `Just the push event`

Si quieres que un push al backend o al frontend también dispare el deploy
(no solo un push a este repo), agrega el mismo webhook en `Cohorte-IMSS` y
`Cohorte-front`, apuntando al mismo job de Jenkins.

## Qué hace el pipeline

1. Checkout de este repo.
2. Verifica que la rama sea `main` (si no, termina sin desplegar).
3. Clona `Cohorte-IMSS` → `./cohorte_test` y `Cohorte-front` → `./client`.
4. Copia el `.env` en el workspace desde la credencial `cohorte-env-file`.
5. **Respalda la base de datos** (`scripts/backup-db.sh`) contra el contenedor
   que está a punto de bajarse. Si el dump falla de verdad, el pipeline se
   detiene aquí — nunca baja los contenedores sin backup fresco.
6. `docker compose down` (libera contenedores; los volúmenes externos persisten).
7. `docker compose up --build -d`.
8. Verifica que `cohorte-backend` y `cohorte-frontend` queden corriendo.
9. Emite/renueva el certificado SSL si aplica.
10. **Instala/actualiza el cron de respaldo diario** (12:01am) en el servidor,
    apuntando siempre a la última versión de `scripts/backup-db.sh`.
11. Si algo falla, imprime los últimos logs del backend.

## Respaldo de base de datos

`scripts/backup-db.sh` genera un dump comprimido de la base `cohorte` y sube
una copia a Google Drive (vía `rclone`). Se ejecuta en dos momentos:

- **Antes de cada deploy** (stage `Respaldo de base de datos` del Jenkinsfile),
  contra los contenedores actuales, antes de tocarlos.
- **Todos los días a las 12:01am**, vía un cron en el servidor que el propio
  pipeline instala y mantiene actualizado (`/root/cohorte-infra-scripts/backup-db.sh`).

No depende del `.env` del deploy: lee la contraseña de MySQL directamente de
la variable de entorno `MYSQL_ROOT_PASSWORD` que ya vive dentro del contenedor
`cohorte-database`, así que el script funciona igual sin importar quién lo invoque.

Retención: **14 días** de dumps locales en `/root/backups/cohorte/` y **30
días** en Drive (se borran automáticamente los más viejos en cada corrida).
Para cambiar estos valores, o la ruta de backups, edita las constantes al
inicio de `scripts/backup-db.sh`.

### Setup único: autorizar Google Drive con rclone

Este paso requiere interacción humana (flujo OAuth) y solo se hace una vez,
como root en el servidor:

```bash
# 1. Instalar rclone (si no está ya instalado)
curl https://rclone.org/install.sh | sudo bash

# 2. Crear el remote "gdrive-cohorte"
rclone config
#   n) New remote
#   name> gdrive-cohorte
#   Storage> drive   (Google Drive)
#   Sigue el flujo de autorización OAuth (copia/pega el link en un navegador)
#   Cuando pregunte "Configure this as a Shared Drive?" → no, a menos que uses
#   una Unidad Compartida de Drive.

# 3. Verificar que funciona
rclone lsd gdrive-cohorte:
```

La carpeta `CohorteApp-Backups` en Drive se crea sola en la primera subida —
no hace falta crearla a mano.

Si en algún momento el token de Drive expira o deja de funcionar, el script
sigue guardando el dump local normalmente (solo se pierde la subida a la
nube ese día) y lo reporta como advertencia en el log; para renovarlo, repite
el paso 2 (`rclone config`, `Edit existing remote`).

### Restaurar un backup a mano

```bash
gunzip -c /root/backups/cohorte/cohorte_<fecha>.sql.gz | \
  docker exec -i cohorte-database sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD" cohorte'
```

Verifica primero que tienes un backup reciente de seguridad antes de restaurar
sobre una base de datos con datos que quieras conservar — esto sobreescribe
las tablas existentes con las del dump.

## Notas de seguridad

- Los puertos de MySQL (3307), MinIO (9000/9001) y el backend directo (8081)
  están bindeados a `127.0.0.1` en `docker-compose.yml` — no son accesibles desde
  internet, solo desde el propio servidor (vía SSH tunnel si necesitas acceso remoto).
  El único puerto público es el 80 (frontend).
- TLS/HTTPS no está incluido en este compose — se asume que hay un reverse proxy
  o balanceador (Cloudflare, ALB, nginx con certbot, etc.) terminando TLS delante
  del puerto 80. `COOKIE_SECURE=true` requiere que el tráfico real llegue por HTTPS.
