# Cohorte-Infra

Repositorio de orquestación para CohorteApp: `docker-compose.yml` + `Jenkinsfile`.
No contiene código de aplicación — el backend (`Cohorte-IMSS`) y el frontend
(`Cohorte-front`) se clonan en tiempo de build dentro del workspace de Jenkins,
en `./cohorte_test` y `./client` respectivamente (ver `.gitignore`).

Ninguna credencial real vive en este repo. `.env.example` y `.env.staging.example`
son plantillas con valores ficticios; el `.env` real solo existe en disco (nunca
se commitea) y en el servidor lo genera el propio Jenkinsfile a partir de
credenciales de Jenkins.

## Arquitectura

Un solo servidor aloja **dos ambientes** (producción y staging) más un reverse
proxy compartido. Traefik es el único contenedor que publica puertos a internet
(80/443) y decide a qué ambiente entregar cada petición según el dominio:

```
Internet (80/443)
       │
       ▼
  ┌─────────┐   stack "traefik"  ·  traefik/docker-compose.yml
  │ Traefik │   TLS automático (Let's Encrypt)
  └────┬────┘
       │  enruta por Host header
  ┌────┴──────────────────┐
  ▼                       ▼
hwcs.cipps.unam.mx    staging.hwcs.cipps.unam.mx
stack "cohorteapp"    stack "cohorteapp-staging"
cohorte-net           cohorte-staging-net
cohorte-volume        cohorte-staging-volume
minio-volume          minio-staging-volume
```

`docker-compose.yml` es **el mismo archivo para ambos ambientes**. Lo que cambia
son variables del `.env`; los valores por defecto son los de producción, así que
un deploy de producción se comporta igual que antes de introducir staging:

| Variable            | Producción           | Staging                      |
| ------------------- | -------------------- | ---------------------------- |
| `CONTAINER_PREFIX`  | `cohorte`            | `cohorte-staging`            |
| `INTERNAL_NET`      | `cohorte-net`        | `cohorte-staging-net`        |
| `DB_VOLUME`         | `cohorte-volume`     | `cohorte-staging-volume`     |
| `MINIO_VOLUME`      | `minio-volume`       | `minio-staging-volume`       |
| `APP_DOMAIN`        | `hwcs.cipps.unam.mx` | `staging.hwcs.cipps.unam.mx` |
| `DB_HOST_PORT`      | 3307                 | 3308                         |
| `BACKEND_HOST_PORT` | 8081                 | 8082                         |
| `MINIO_*_HOST_PORT` | 9000 / 9001          | 9002 / 9003                  |

Los puertos de MySQL, MinIO y el backend directo están atados a `127.0.0.1`:
solo se alcanzan desde el propio servidor (vía SSH tunnel). Ver *Notas de
seguridad* al final.

## Requisitos en el servidor

### Red compartida del proxy (una sola vez)

```
docker network create traefik-net
```

Las redes y volúmenes de cada ambiente los crea el propio pipeline (stage
*Preparar redes y volúmenes*), así que no hay que crearlos a mano. Si necesitas
hacerlo manualmente:

```
docker network create cohorte-net
docker volume create cohorte-volume
docker volume create minio-volume
```

Todo se declara `external: true` en el compose para que sobreviva a un
`docker compose down` (no se pierden datos entre despliegues).

### Levantar Traefik (una sola vez)

```
cd traefik
cp .env.example .env      # completa ACME_EMAIL
docker compose -p traefik up -d
```

Traefik es un stack aparte **a propósito**: sirve a producción y staging al mismo
tiempo, así que un `docker compose down` de cualquiera de los dos ambientes no
debe tumbarlo. El pipeline lo levanta si no está corriendo, pero nunca lo baja.

Los certificados se emiten y renuevan solos, y persisten en el volumen
`traefik_traefik-acme`. Ya no se usa Certbot.

> **Antes del primer arranque con la CA real**, valida el setup con la CA de
> pruebas de Let's Encrypt descomentando `ACME_CA_SERVER` en `traefik/.env`. La
> CA real solo permite 5 emisiones por dominio por semana; si se agota el límite
> hay que esperar. Al cambiar de CA, borra el almacén para que vuelva a emitir:
> `docker volume rm traefik_traefik-acme`.

## Desarrollo / prueba manual local

```
git clone https://github.com/MartinOM321753/Cohorte-IMSS.git cohorte_test
git clone https://github.com/MartinOM321753/Cohorte-front.git client
cp .env.example .env   # y completa los valores reales
docker compose -p cohorteapp up --build -d
```

Para staging, el mismo comando con su propio `.env` y proyecto:

```
cp .env.staging.example .env
docker compose -p cohorteapp-staging up --build -d
```

## Configuración de Jenkins

### 1. Credenciales (Manage Jenkins → Credentials → Global)

Una credencial tipo **Secret file** por ambiente:

| ID de la credencial         | Contenido                       | Se usa en       |
| --------------------------- | ------------------------------- | --------------- |
| `cohorte-env-file`          | `.env` real de producción       | producción      |
| `cohorte-env-file-staging`  | `.env` real de staging          | staging         |
| `traefik-env-file`          | `traefik/.env` real (ACME_EMAIL)| ambos ambientes |

La de Traefik es **obligatoria**: desde que el frontend dejó de publicar 80/443,
sin el proxy no hay forma de llegar al sitio. Si falta, el pipeline falla en esa
etapa en lugar de reportar un deploy exitoso con el sitio caído. Va como credencial
y no en el repo porque `traefik/.env` está en `.gitignore` — un `checkout` nunca lo
traería y un workspace limpio lo perdería.

Para cada una:

1. *Add Credentials* → **Kind**: `Secret file`.
2. **File**: sube el `.env` real completo, con `FRONTEND_URL` y `APP_DOMAIN`
   apuntando al dominio real de ese ambiente (no a `localhost`).
3. **ID**: exactamente el de la tabla — el Jenkinsfile los referencia por nombre.
4. *Create*.

Cuando cambie cualquier valor (rotas una contraseña, cambias el dominio, etc.),
edita esa misma credencial y vuelve a subir el archivo actualizado — no hay que
tocar el Jenkinsfile.

Usa `SECRET_KEY`, `DB_PASSWORD` y claves de MinIO **distintas** en staging: un
token o una credencial de pruebas nunca debe ser válido en producción.

> Alternativa más granular: si prefieres una credencial por variable (más fácil
> de auditar quién cambió qué, pero más tedioso de mantener), se puede volver al
> esquema de 8 `Secret text` + `withCredentials([string(...), ...])` armando el
> `.env` línea por línea en el Jenkinsfile. No es la opción actual de este repo.

Si `Cohorte-IMSS` o `Cohorte-front` son repos privados, agrega además una
credencial de tipo **Username with password** (token de GitHub) y úsala en el
job (Pipeline → "Use a credential" o vía `git` con `credentialsId` en el clone).

### 2. Crear el job

- Tipo: **Pipeline** (o **Multibranch Pipeline** si quieres builds de verificación
  en otras ramas, sin desplegar — el Jenkinsfile ya filtra por rama).
- "Pipeline script from SCM" → Git → URL de este repo (`Cohorte-Infra`) → rama `main`.
- Build Triggers: **"GitHub hook trigger for GITScm polling"**.

El pipeline recibe un parámetro **`DEPLOY_ENV`** (`prod` | `staging`) que resuelve
todo lo que difiere entre ambientes:

| `DEPLOY_ENV` | Rama que despliega | Proyecto Compose      | Credencial del `.env`      |
| ------------ | ------------------ | --------------------- | -------------------------- |
| `prod`       | `main`             | `cohorteapp`          | `cohorte-env-file`         |
| `staging`    | `develop`          | `cohorteapp-staging`  | `cohorte-env-file-staging` |

Un build cuya rama no coincida con la esperada del ambiente se verifica pero **no
despliega**. El webhook de GitHub usa el valor por defecto (`prod`); para
desplegar staging usa *Build with Parameters* y elige `staging`.

> Un mismo job sirve para ambos ambientes. Si prefieres separarlos (útil para
> permisos distintos o historiales independientes), crea un segundo job idéntico
> apuntando al mismo repo y deja `staging` como valor por defecto del parámetro.

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
2. **Resuelve el ambiente** desde `DEPLOY_ENV` (rama, proyecto, credencial,
   prefijo de contenedores) y verifica que la rama construida sea la esperada.
   Si no lo es, termina sin desplegar.
3. Clona `Cohorte-IMSS` → `./cohorte_test` y `Cohorte-front` → `./client`.
4. Copia el `.env` en el workspace desde la credencial del ambiente.
5. **Crea la red y los volúmenes externos** del ambiente si faltan (idempotente).
6. **Respalda la base de datos** (`scripts/backup-db.sh`) contra el contenedor
   que está a punto de bajarse. Si el dump falla de verdad, el pipeline se
   detiene aquí — nunca baja los contenedores sin backup fresco. Staging respalda
   a su propio directorio y no sube a Drive.
7. `docker compose down` (libera contenedores; los volúmenes externos persisten).
8. `docker compose up --build -d`.
9. **Asegura que Traefik esté corriendo** (nunca lo baja: es compartido).
10. Verifica que los servicios `backend` y `frontend` del ambiente queden en
    estado `running`.
11. **Instala/actualiza el cron de respaldo diario** (12:01am) en el servidor,
    apuntando siempre a la última versión de `scripts/backup-db.sh`. Solo en
    producción.
12. Si algo falla, imprime los últimos logs del backend.

Ya no hay etapas de Certbot: los certificados los gestiona Traefik.

## Migración a Traefik (una sola vez)

Antes de este cambio, el contenedor `frontend` publicaba 80/443 directo y servía
TLS él mismo con certificados de Certbot. Ahora esos puertos los toma Traefik.
**Los dos no pueden coexistir en 80/443**, así que la transición implica un corte
breve de producción (minutos). Hazlo en una ventana tranquila.

```bash
# 0. Respaldo fresco por si acaso
sudo -u jenkins /var/lib/jenkins/cohorte-infra-scripts/backup-db.sh

# 1. Red compartida del proxy
docker network create traefik-net

# 2. Configurar Traefik (desde el repo actualizado, en el servidor)
cd traefik
cp .env.example .env
#    edita .env: pon tu ACME_EMAIL real.
#    Recomendado la primera vez: descomenta ACME_CA_SERVER (CA de pruebas).

# 3. Bajar producción — esto libera 80/443
cd ..
docker compose -p cohorteapp down

# 4. Levantar Traefik (ya con 80/443 libres)
docker compose -p traefik -f traefik/docker-compose.yml up -d
docker logs traefik --tail 30

# 5. Volver a levantar producción, ya con las etiquetas de Traefik
docker compose -p cohorteapp up --build -d

# 6. Verificar que el certificado se emitió y el sitio responde
docker logs traefik 2>&1 | grep -i certificate
curl -I https://hwcs.cipps.unam.mx
```

Si en el paso 2 usaste la CA de pruebas, el navegador va a marcar el certificado
como no confiable — es lo esperado. Cuando confirmes que el enrutamiento funciona,
comenta `ACME_CA_SERVER`, borra el almacén y reinicia Traefik para obtener el
certificado real:

```bash
docker compose -p traefik -f traefik/docker-compose.yml down
docker volume rm traefik_traefik-acme
docker compose -p traefik -f traefik/docker-compose.yml up -d
```

Los volúmenes viejos de Certbot (`cohorteapp_certbot-conf`,
`cohorteapp_certbot-www`) quedan huérfanos. Una vez que Traefik esté emitiendo
certificados correctamente, se pueden borrar:

```bash
docker volume rm cohorteapp_certbot-conf cohorteapp_certbot-www
```

## Levantar staging (una sola vez)

Requiere que el registro DNS `staging.hwcs.cipps.unam.mx` → misma IP del servidor
ya exista y resuelva públicamente (si no, todo funciona salvo la emisión del
certificado).

1. Crea la credencial `cohorte-env-file-staging` en Jenkins con un `.env` basado
   en `.env.staging.example`, con secretos **propios** de staging.
2. En Jenkins: *Build with Parameters* → `DEPLOY_ENV = staging`.
3. El pipeline crea la red y los volúmenes de staging, construye y levanta.

El primer arranque crea el esquema desde cero (Hibernate) con roles, institución
raíz, usuario `admin` y permisos. Para poblar los catálogos, ver el script de
carga de catálogos que se usó en producción.

## Respaldo de base de datos

`scripts/backup-db.sh` genera un dump comprimido de la base `cohorte` y sube
una copia a Google Drive (vía `rclone`). Se ejecuta en dos momentos:

- **Antes de cada deploy** (stage `Respaldo de base de datos` del Jenkinsfile),
  contra los contenedores actuales, antes de tocarlos.
- **Todos los días a las 12:01am**, vía un cron del usuario `jenkins` (el mismo
  bajo el que corre el pipeline) que el propio pipeline instala y mantiene
  actualizado (`$HOME/cohorte-infra-scripts/backup-db.sh`, donde `$HOME` es el
  home de `jenkins` — normalmente `/var/lib/jenkins`).

No depende del `.env` del deploy: lee la contraseña de MySQL directamente de
la variable de entorno `MYSQL_ROOT_PASSWORD` que ya vive dentro del contenedor
`cohorte-database`, así que el script funciona igual sin importar quién lo invoque.

Retención: **14 días** de dumps locales en `$HOME/backups/cohorte/` (home del
usuario `jenkins`) y **30 días** en Drive (se borran automáticamente los más
viejos en cada corrida).

Todos esos valores son sobreescribibles por variable de entorno; los defaults son
los de producción, así que invocar el script sin nada sigue respaldando prod igual
que siempre:

| Variable             | Default                             | Para qué                              |
| -------------------- | ----------------------------------- | ------------------------------------- |
| `DB_CONTAINER`       | `cohorte-database`                  | Contenedor al que se le hace el dump  |
| `BACKUP_DIR`         | `$HOME/backups/cohorte`             | Destino de los dumps locales          |
| `RCLONE_REMOTE`      | `gdrive-cohorte:CohorteApp-Backups` | Remote de rclone                      |
| `SKIP_CLOUD_UPLOAD`  | `0`                                 | `1` omite la subida a Drive           |
| `LOCAL_RETENTION_DAYS` | `14`                              | Días de dumps locales                 |
| `CLOUD_RETENTION_DAYS` | `30`                              | Días de dumps en Drive                |

El pipeline usa esto para que **staging respalde a `$HOME/backups/cohorte-staging`
y no suba nada a Drive** — son datos de prueba y no deben mezclarse con los
respaldos reales.

### Setup único: autorizar Google Drive con rclone

El pipeline de Jenkins corre como el usuario de sistema `jenkins` (no `root`),
así que el remote de rclone debe configurarse con ESE usuario — si lo
configuras como `root` o con tu usuario de SSH, `jenkins` no lo va a ver.

Este paso requiere interacción humana (flujo OAuth) y solo se hace una vez,
como usuario `jenkins` en el servidor:

```bash
# 1. Instalar rclone (si no está ya instalado) — esto sí como root/sudo
curl https://rclone.org/install.sh | sudo bash

# 2. Abrir una shell interactiva como el usuario "jenkins"
sudo -iu jenkins

# 3. Crear el remote "gdrive-cohorte" (ya como jenkins)
rclone config
#   n) New remote
#   name> gdrive-cohorte
#   Storage> drive   (Google Drive)
#   client_id / client_secret> (vacío, Enter)
#   scope> 1 (acceso completo de lectura/escritura)
#   Sigue el flujo de autorización OAuth. Si el servidor no tiene navegador
#   ("Use auto config?" → n), corre el comando "rclone authorize ..." que te
#   da en TU propia laptop (con rclone instalado ahí), autoriza en el
#   navegador, y pega el token resultante de vuelta en esta terminal.
#   Cuando pregunte "Configure this as a Shared Drive?" → no, a menos que uses
#   una Unidad Compartida de Drive.

# 4. Verificar que funciona (todavía como jenkins)
rclone lsd gdrive-cohorte:

# 5. Salir de la shell de jenkins
exit
```

La carpeta `CohorteApp-Backups` en Drive se crea sola en la primera subida —
no hace falta crearla a mano.

Si en algún momento el token de Drive expira o deja de funcionar, el script
sigue guardando el dump local normalmente (solo se pierde la subida a la
nube ese día) y lo reporta como advertencia en el log; para renovarlo, repite
el paso 2 (`rclone config`, `Edit existing remote`).

### Restaurar un backup a mano

```bash
gunzip -c /var/lib/jenkins/backups/cohorte/cohorte_<fecha>.sql.gz | \
  docker exec -i cohorte-database sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD" cohorte'
```

Verifica primero que tienes un backup reciente de seguridad antes de restaurar
sobre una base de datos con datos que quieras conservar — esto sobreescribe
las tablas existentes con las del dump.

## Notas de seguridad

- **El único contenedor con puertos públicos es Traefik** (80/443). Los puertos de
  MySQL, MinIO y el backend directo están bindeados a `127.0.0.1` — no son
  accesibles desde internet, solo desde el propio servidor (vía SSH tunnel si
  necesitas acceso remoto). Los contenedores de frontend no publican nada:
  Traefik los alcanza por la red `traefik-net`.
- **TLS lo termina Traefik**, con certificados de Let's Encrypt emitidos y
  renovados automáticamente. Todo HTTP se redirige a HTTPS con un 301 permanente.
  `COOKIE_SECURE=true` es correcto en ambos ambientes.
- El backend recibe `SERVER_FORWARD_HEADERS_STRATEGY=framework` para que Spring
  respete los headers `X-Forwarded-*` que inyecta el proxy. Sin esto, Spring
  asumiría que la petición original fue HTTP y generaría URLs absolutas con el
  esquema equivocado.
- **Traefik monta el socket de Docker en modo solo lectura** (`:ro`). Aun así,
  acceso de lectura al socket permite enumerar todos los contenedores del host, así
  que Traefik debe mantenerse actualizado como cualquier componente expuesto.
- El dashboard de Traefik está **deshabilitado** (`--api.dashboard=false`): no hay
  razón para exponer la topología del proxy. Para inspeccionar el enrutamiento,
  revisa los logs: `docker logs traefik`.
- **`ufw` no es la única capa que decide qué está expuesto.** Docker escribe sus
  propias reglas en `iptables` al publicar un puerto, y esas reglas se evalúan en la
  cadena `FORWARD`, no en `INPUT` — así que un puerto publicado por Docker queda
  accesible aunque `ufw` no lo liste. La forma correcta de *no* exponer algo es no
  publicarlo (o publicarlo en `127.0.0.1`), no confiar en `ufw`.

## Traefik: operación

```bash
# Estado y logs
docker ps --filter name=traefik
docker logs traefik --tail 50

# Ver qué rutas y certificados conoce (los logs los reportan al arrancar)
docker logs traefik 2>&1 | grep -i "certificate\|router"

# Recargar tras cambiar traefik/.env
cd traefik && docker compose -p traefik up -d

# Reemitir todos los certificados desde cero (p. ej. al cambiar de CA)
docker compose -p traefik down
docker volume rm traefik_traefik-acme
docker compose -p traefik up -d
```

Traefik no necesita reiniciarse cuando se despliega un ambiente: detecta los
contenedores nuevos por el socket de Docker y actualiza su enrutamiento solo.

### Probar staging antes de que exista el DNS

El enrutamiento depende del header `Host`, no del DNS, así que se puede validar
desde el propio servidor antes de que el subdominio resuelva públicamente:

```bash
curl -H "Host: staging.hwcs.cipps.unam.mx" http://127.0.0.1
```

Debe responder un 301 hacia HTTPS. Lo que **sí** requiere DNS público es la
emisión del certificado: Let's Encrypt tiene que poder resolver el nombre y
alcanzar el reto HTTP-01 en el puerto 80.
