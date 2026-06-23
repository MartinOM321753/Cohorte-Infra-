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

### 1. Credenciales (Manage Jenkins → Credentials → Global)

Crea cada una como **Secret text**, con exactamente estos IDs (el Jenkinsfile los
referencia por nombre):

| Credential ID              | Valor                                            |
|-----------------------------|---------------------------------------------------|
| `cohorte-db-password`       | contraseña de MySQL (root) en producción          |
| `cohorte-minio-access-key`  | usuario de MinIO en producción                    |
| `cohorte-minio-secret-key`  | contraseña de MinIO en producción                 |
| `cohorte-jwt-secret`        | clave JWT (`openssl rand -base64 32`)             |
| `cohorte-mail-username`     | usuario SMTP                                      |
| `cohorte-mail-password`     | contraseña/API key SMTP                           |
| `cohorte-mail-from`         | correo remitente de notificaciones                |
| `cohorte-frontend-url`      | URL pública del frontend, ej. `https://midominio.com` |

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
4. Genera `.env` en el workspace desde las credenciales de Jenkins.
5. `docker compose down` (libera contenedores; los volúmenes externos persisten).
6. `docker compose up --build -d`.
7. Verifica que `cohorte-backend` y `cohorte-frontend` queden corriendo.
8. Si falla, imprime los últimos logs del backend.

## Notas de seguridad

- Los puertos de MySQL (3307), MinIO (9000/9001) y el backend directo (8081)
  están bindeados a `127.0.0.1` en `docker-compose.yml` — no son accesibles desde
  internet, solo desde el propio servidor (vía SSH tunnel si necesitas acceso remoto).
  El único puerto público es el 80 (frontend).
- TLS/HTTPS no está incluido en este compose — se asume que hay un reverse proxy
  o balanceador (Cloudflare, ALB, nginx con certbot, etc.) terminando TLS delante
  del puerto 80. `COOKIE_SECURE=true` requiere que el tráfico real llegue por HTTPS.
