# Almacén de instrumentos (MinIO público)

Repositorio de imágenes y documentos de instrumentos, **separado** del sistema
CohorteApp. No lo consume el backend ni el frontend: es un stack propio, con sus
credenciales, su volumen y su respaldo.

No confundir con el MinIO del `docker-compose.yml` raíz (`cohorte-minio`), que sí
es dependencia del backend y guarda documentos del sistema. **Las credenciales de
uno nunca deben usarse en el otro.**

## Cómo se publica sin subdominio propio

No hay registro DNS para este servicio, así que cuelga del host que ya existe
mediante **prefijo de ruta**. S3 direcciona en *path-style* —
`https://<host>/<bucket>/<objeto>`— de modo que un router de Traefik que atrape
todo lo que empiece con el nombre del bucket es suficiente:

| | |
| --- | --- |
| Regla del router | ``Host(`staging.hwcs.cipps.unam.mx`) && PathPrefix(`/archivos-instrumentos`)`` |
| URL pública de una imagen | `https://staging.hwcs.cipps.unam.mx/archivos-instrumentos/INS-042/frontal.jpg` |
| Endpoint S3 (rclone) | `https://staging.hwcs.cipps.unam.mx` |
| Consola web | `http://127.0.0.1:9005` — **solo por túnel SSH**, nunca pública |

> **El router no lleva `StripPrefix`, y no es un detalle de estilo.** La firma
> SigV4 que calcula el cliente incluye la ruta completa. Si Traefik la recorta,
> MinIO firma sobre otra ruta y rechaza todo con `SignatureDoesNotMatch`. Por eso
> el nombre del bucket y el prefijo de ruta son forzosamente la misma cadena.

## Puesta en marcha

### 1. Credencial en Jenkins (una sola vez)

Crear una credencial tipo **Secret file** con ID `minio-public-env-file`, cuyo
contenido sea un `.env` basado en [`.env.example`](.env.example). Los valores que
hay que cambiar sí o sí son las dos contraseñas raíz y la del usuario de subida.

Generar cada una con:

```bash
openssl rand -base64 24
```

### 2. Desplegar

La stage *Asegurar almacén de instrumentos* del `Jenkinsfile` lo levanta en cada
deploy (de producción o de staging, da igual: el servicio es uno solo). Crea el
volumen si falta, levanta el stack y deja en el log la configuración inicial del
bucket.

A mano, desde el servidor:

```bash
docker compose -p minio-public -f minio-public/docker-compose.yml up -d
```

### 3. Verificar

```bash
docker logs minio-public-init
```

Debe terminar con el resumen del bucket. Después, la prueba de fuego — una imagen
subida se abre sin credenciales, y una subida sin llave se rechaza:

```bash
curl -I https://staging.hwcs.cipps.unam.mx/archivos-instrumentos/prueba.jpg
```

## Qué deja configurado el arranque

`init-bucket.sh` corre en cada `up` y es idempotente:

- **Bucket creado** con el nombre de `MINIO_PUBLIC_BUCKET`.
- **Versionado activo.** Un borrado accidental desde la unidad de red montada en
  Windows se puede deshacer: es la única protección que actúa en el instante del
  error.
- **Lectura anónima** (`anonymous set download`): cualquiera con la URL descarga;
  nadie sube, nadie borra y nadie puede *listar* el contenido del bucket.
- **Cuota**, para que al llenarse MinIO rechace escrituras nuevas en vez de dejar
  sin espacio al disco que también aloja MySQL y los dos ambientes.
- **Purga de versiones antiguas** pasados `MINIO_PUBLIC_NONCURRENT_DAYS` días.
- **Usuario de subida** con una política acotada a este bucket. A propósito no es
  `s3:*`: eso incluiría cambiar la política del bucket, es decir, la posibilidad
  de abrirlo a escritura anónima desde una credencial de subida.

## Dar de alta a más personas

Una credencial por equipo, para poder revocarlas por separado. Desde el servidor:

```bash
docker run --rm --network traefik-net -it --entrypoint sh minio/mc
```

El `--entrypoint sh` no es opcional: la imagen trae `mc` como entrypoint, asi
que sin sobreescribirlo cualquier `sh -c ...` se lo come `mc` como argumentos
suyos y responde "`sh` is not a recognized command".

Y dentro del contenedor (sustituyendo usuario y contraseña):

```bash
mc alias set pub http://minio-public:9000 <ROOT_USER> <ROOT_PASSWORD>
mc admin user add pub laura-pc "<contraseña-generada>"
mc admin policy attach pub archivos-instrumentos-rw --user laura-pc
```

Para revocar a alguien:

```bash
mc admin user remove pub laura-pc
```

## Montar el bucket como unidad de red en Windows

Convierte el bucket en una unidad `S:` que el Explorador trata como una carpeta
más. Requiere permisos de administrador **una sola vez** en cada equipo.

### La vía normal: el instalador

Para equipos ajenos —y sobre todo remotos— usa [`windows/`](windows/): se manda
la carpeta comprimida, la persona hace doble clic en
*Instalar unidad de instrumentos.bat* y queda todo hecho. El script instala
WinFsp y rclone si faltan, guarda la configuración, comprueba la conexión antes
de tocar nada más, registra la tarea de inicio de sesión y monta la unidad.

Las credenciales **no** viajan dentro del archivo: el instalador las pide al
ejecutarse. Manda a cada persona las suyas por otro canal, para poder revocar a
una sin afectar a las demás. Si prefieres automatizarlo del todo:

```powershell
.\Instalar-UnidadInstrumentos.ps1 -AccessKey laura-pc -SecretKey "<contraseña>"
```

Para quitarlo hay un segundo archivo, *Desinstalar unidad de instrumentos.bat*:
elimina la tarea y detiene el montaje, y no toca nada del servidor — los
archivos siguen ahí. WinFsp y rclone se dejan instalados por si otra unidad
depende de ellos.

Otras opciones del script: `-Letra U` si la S está ocupada, y `-Endpoint` /
`-Bucket` si algún día cambia el dominio.

Re-ejecutar el instalador es la forma de reparar un montaje que desapareció: si
el equipo ya estaba configurado y el servidor responde, conserva las
credenciales y no vuelve a pedir nada.

No es un `.exe` a propósito. Un ejecutable sin firma digital hace que SmartScreen
lo bloquee con la pantalla de *"Windows protegió tu PC"*, que es justo el
problema cuando quien lo recibe está a un país de distancia y no tienes cómo
guiarlo. El par `.bat` + `.ps1` se comporta igual para el usuario y no cruza
ningún filtro.

### A mano, si prefieres hacerlo paso a paso

#### Instalación

1. Instalar [WinFsp](https://winfsp.dev) — el driver que permite a Windows montar
   sistemas de archivos que no son discos reales (es lo mismo que usan las
   unidades de Google Drive y similares).
2. Instalar [rclone](https://rclone.org/downloads/) y dejar el ejecutable en una
   ruta fija, por ejemplo `C:\rclone\rclone.exe`.

#### Configuración del remoto

Ejecutar `rclone config` y crear un remoto nuevo con estos valores:

| Campo | Valor |
| --- | --- |
| `name` | `instrumentos` |
| `type` | `s3` |
| `provider` | `Minio` |
| `endpoint` | `https://staging.hwcs.cipps.unam.mx` |
| `access_key_id` | el usuario de subida |
| `secret_access_key` | su contraseña |
| `region` | `us-east-1` |

Y añadir a mano en el archivo de configuración (`rclone config file` dice dónde
está), dentro de la sección `[instrumentos]`:

```ini
force_path_style = true
no_check_bucket = true
```

> `no_check_bucket` no es opcional aquí. Sin él, rclone empieza por comprobar la
> existencia del bucket con una petición a la raíz del endpoint — que no cae en
> nuestro prefijo y se la queda el frontend. Con el bucket fijado en la ruta,
> todas las peticiones quedan bajo `/archivos-instrumentos` y el router las atrapa.

#### Montaje

```bash
rclone mount instrumentos:archivos-instrumentos S: --network-mode --vfs-cache-mode full
```

- `--network-mode` hace que Windows la trate como unidad de red y no como disco
  local: no la indexa entera ni la considera almacenamiento permanente.
- `--vfs-cache-mode full` da caché de escritura en disco, que es lo que permite
  que Word, Photoshop y demás abran y guarden archivos en el lugar con
  normalidad.

Para que aparezca sola al encender: **Programador de tareas** → nueva tarea →
disparador *Al iniciar sesión* → acción: ese mismo comando.

**No** marques *"Ejecutar tanto si el usuario inició sesión como si no"*. Una
unidad montada pertenece a la sesión de Windows: con esa opción la tarea corre
fuera de la sesión, el proceso vive pero la unidad nunca aparece en el
Explorador. Conviene también quitarle el límite de ejecución —por defecto
Windows mata las tareas a los 3 días, y aquí el proceso *es* la unidad.

### Lo que hay que saber antes de repartirla

| Comportamiento | Por qué |
| --- | --- |
| Sin internet, la unidad no existe | No hay copia local del contenido. |
| Copiar carpetas grandes es más lento que en disco | Cada archivo es una petición HTTPS; miles de archivos chicos tardan mucho más que uno grande del mismo peso. |
| Renombrar una carpeta copia y borra todo su contenido | S3 no sabe renombrar: el prefijo es parte del nombre de cada objeto. |
| Borrar es inmediato y no pasa por la Papelera | Lo cubre el versionado del bucket, no Windows. |
| Dos personas editando el mismo archivo se pisan | No hay bloqueo de archivos: gana quien guarda al último. |
| La unidad la ve solo el usuario que la montó | Es propia de la sesión de Windows, no de la máquina. |

Sirve muy bien para **depositar y consultar**. Para trabajar un archivo durante
horas, conviene copiarlo al disco, trabajarlo y devolverlo.

## Administración: consola web

Nunca se publica. Desde el equipo propio:

```bash
ssh -L 9005:127.0.0.1:9005 usuario@servidor
```

Y abrir `http://127.0.0.1:9005`. Se entra con la cuenta raíz, que **solo** se usa
para administrar: altas de usuarios y revisar contenido, nunca para subir.

> Si tras iniciar sesión el navegador termina en un puerto que no existe, añadir
> `MINIO_BROWSER_REDIRECT_URL: http://127.0.0.1:9005` al bloque `environment` del
> servicio `minio-public` en el compose.

## Respaldo

`scripts/backup-bucket.sh` copia el bucket a Google Drive todos los días a las
00:20, con el mismo mecanismo que el respaldo de base de datos (cron del usuario
`jenkins`, instalado y mantenido por el propio pipeline). Lee las credenciales de
dentro del contenedor, así que no depende de ningún `.env` del workspace.

Usa `copy` y no `sync` a propósito: un borrado en el bucket **no** se propaga al
respaldo. La contrapartida es que lo borrado se acumula en Drive; si algún día
estorba, se limpia a mano.

El versionado y el respaldo cubren riesgos distintos y por eso están los dos: el
versionado protege del error humano, la copia en Drive protege de perder el disco
del servidor.

## El día que exista un subdominio propio

El cambio es **aditivo**: nada se rompe y no hay prisa.

1. Pedir el registro A (`files.hwcs.cipps.unam.mx` → misma IP) y esperar a que
   resuelva.
2. Cambiar `MINIO_PUBLIC_HOST` en la credencial `minio-public-env-file` y volver
   a levantar el stack. Traefik emite el certificado nuevo solo.
3. **Opcional pero recomendable:** dejar también el router viejo, duplicando la
   etiqueta con el host anterior y otro nombre de router. Las ligas ya repartidas
   en oficios y presentaciones siguen sirviendo indefinidamente, y las PCs con la
   unidad montada no se tocan.

Las URLs conservan la forma —`https://<host>/archivos-instrumentos/<objeto>`—
porque en *path-style* el bucket va en la ruta pase lo que pase. Solo cambia el
origen.

Por eso mismo, **en la base de datos y en cualquier otro lado se guarda la llave
del objeto** (`INS-042/frontal.jpg`), nunca la URL absoluta: la base se arma al
mostrar, desde una sola constante. Guardar URLs completas convierte este cambio en
un `UPDATE` masivo, y las que ya salieron por correo quedan fuera de alcance.

Si más adelante hacen falta **URLs firmadas** (con caducidad, para material que no
deba ser público), hay que fijar además `MINIO_SERVER_URL` al mismo origen público
en el `environment` del servicio, para que MinIO las genere apuntando al host
correcto y no a su nombre interno.

## Advertencias

- **Nada sensible en este bucket.** Todo lo que entre es descargable por
  cualquiera que conozca la URL, sin contraseña y sin registro. Sirve para fotos
  de instrumentos y material de difusión; no para datos de pacientes,
  identificadores ni documentos internos. Si hace falta guardar algo restringido,
  se crea un segundo bucket privado en este mismo MinIO y se accede con URLs
  firmadas.
- **El nombre del bucket es permanente.** Va dentro de la URL pública en cualquier
  escenario, y ninguna ruta del SPA (`Cohorte-front`) puede llamarse igual.
- **La versión de la imagen no se sube a ciegas.** Releases comunitarios de MinIO
  posteriores al fijado recortaron el explorador de archivos de la consola web.
  Antes de actualizar, abrir la consola de la versión candidata y confirmar que
  el explorador sigue ahí.
