pipeline {
    agent any

    // El mismo pipeline despliega produccion o staging segun el parametro
    // DEPLOY_ENV. Todo lo que difiere entre ambientes (rama, credencial del
    // .env, nombre del proyecto de Compose, prefijo de contenedores) se resuelve
    // en la stage 'Resolver ambiente'.
    parameters {
        choice(
            name: 'DEPLOY_ENV',
            choices: ['prod', 'staging'],
            description: 'Ambiente a desplegar. Un webhook de GitHub usa el valor por defecto (prod).'
        )
    }

    environment {
        BACKEND_REPO  = 'https://github.com/MartinOM321753/Cohorte-IMSS.git'
        FRONTEND_REPO = 'https://github.com/MartinOM321753/Cohorte-front.git'
        // Rama de ESTE repo (infraestructura) desde la que se permite desplegar.
        // No tiene nada que ver con la rama de las aplicaciones: la infra vive
        // en una sola rama y sirve a los dos ambientes.
        INFRA_BRANCH  = 'main'
    }

    triggers {
        githubPush()
    }

    stages {

        // 1. Obtener el código de este repo (docker-compose.yml, Jenkinsfile, .env.example)
        stage('Checkout infra') {
            steps {
                checkout scm
            }
        }

        // 2. Traducir DEPLOY_ENV a los valores concretos del ambiente y verificar
        //    que el build venga de la rama de infraestructura. Un push a una rama
        //    distinta se verifica pero no despliega.
        stage('Resolver ambiente') {
            steps {
                script {
                    if (params.DEPLOY_ENV == 'staging') {
                        env.APP_BRANCH       = 'develop'
                        env.COMPOSE_PROJECT  = 'cohorteapp-staging'
                        env.ENV_CREDENTIAL   = 'cohorte-env-file-staging'
                        env.CONTAINER_PREFIX = 'cohorte-staging'
                    } else {
                        env.APP_BRANCH       = 'main'
                        env.COMPOSE_PROJECT  = 'cohorteapp'
                        env.ENV_CREDENTIAL   = 'cohorte-env-file'
                        env.CONTAINER_PREFIX = 'cohorte'
                    }

                    // Lo que se comprueba es la rama de ESTE repo, no la de las
                    // aplicaciones. Antes se comparaba contra la rama de las apps y
                    // staging nunca desplegaba: esperaba un build de 'develop' que
                    // en un repo con una sola rama no llega nunca. El pipeline
                    // terminaba en verde sin haber levantado nada.
                    def branch = (env.BRANCH_NAME ?: env.GIT_BRANCH ?: '').replaceFirst(/^origin\//, '')
                    env.SHOULD_DEPLOY = (branch == env.INFRA_BRANCH).toString()

                    echo """Ambiente:   ${params.DEPLOY_ENV}
Rama infra: '${branch}'  (esperada: '${env.INFRA_BRANCH}')
Rama apps:  '${env.APP_BRANCH}'
Proyecto:   ${env.COMPOSE_PROJECT}
Desplegar:  ${env.SHOULD_DEPLOY}"""
                }
            }
        }

        // 3. Clonar el backend y el frontend como hermanos de este repo.
        //    docker-compose.yml usa build.context: ./cohorte_test y ./client.
        stage('Clonar repos de aplicación') {
            when { expression { env.SHOULD_DEPLOY == 'true' } }
            steps {
                sh '''
                    rm -rf cohorte_test
                    git clone --depth 1 --branch "$APP_BRANCH" "$BACKEND_REPO" cohorte_test
                    rm -rf client
                    git clone --depth 1 --branch "$APP_BRANCH" "$FRONTEND_REPO" client
                '''
            }
        }

        // 4. Copiar el .env real al workspace desde una credencial de Jenkins tipo
        //    "Secret file". Cada ambiente tiene la suya (cohorte-env-file /
        //    cohorte-env-file-staging). Nunca se versiona: vive solo en el
        //    workspace de este build y Jenkins lo borra al terminar.
        stage('Preparar variables de entorno') {
            when { expression { env.SHOULD_DEPLOY == 'true' } }
            steps {
                withCredentials([file(credentialsId: env.ENV_CREDENTIAL, variable: 'ENV_FILE')]) {
                    sh 'cp -f "$ENV_FILE" .env'
                }
            }
        }

        // 5. Garantizar que existan las redes y volumenes externos del ambiente.
        //    Son "external: true" en el compose para sobrevivir a un "down", asi
        //    que alguien tiene que crearlos; hacerlo aqui evita depender de que
        //    se hayan creado a mano. Idempotente: si ya existen, no hace nada.
        stage('Preparar redes y volúmenes') {
            when { expression { env.SHOULD_DEPLOY == 'true' } }
            steps {
                sh '''
                    set -a
                    . ./.env
                    set +a

                    docker network create traefik-net 2>/dev/null || true
                    docker network create "${INTERNAL_NET:-cohorte-net}" 2>/dev/null || true
                    docker volume  create "${DB_VOLUME:-cohorte-volume}" >/dev/null
                    docker volume  create "${MINIO_VOLUME:-minio-volume}" >/dev/null
                    echo "Redes y volúmenes listos."
                '''
            }
        }

        // 6. Respaldar la base de datos ANTES de tocar los contenedores existentes,
        //    contra el contenedor que todavía corre con los datos previos al deploy.
        //    Si el dump falla de verdad (no el caso de "el contenedor aún no existe",
        //    que scripts/backup-db.sh trata como éxito), esta stage aborta el
        //    pipeline antes de "docker compose down".
        //
        //    Staging respalda a su propio directorio y NO sube a Drive: son datos
        //    de prueba y no deben mezclarse con los respaldos reales.
        stage('Respaldo de base de datos') {
            when { expression { env.SHOULD_DEPLOY == 'true' } }
            steps {
                sh '''
                    chmod +x scripts/backup-db.sh

                    if [ "$DEPLOY_ENV" = "staging" ]; then
                        export DB_CONTAINER="${CONTAINER_PREFIX}-database"
                        export BACKUP_DIR="$HOME/backups/cohorte-staging"
                        export SKIP_CLOUD_UPLOAD=1
                    fi

                    ./scripts/backup-db.sh
                '''
            }
        }

        // 7. Detener los servicios en ejecución de ESTE ambiente
        stage('Parando servicios existentes') {
            when { expression { env.SHOULD_DEPLOY == 'true' } }
            steps {
                sh '''
                    docker compose -p "$COMPOSE_PROJECT" down || true
                '''
            }
        }

        // 8. Construir y levantar todos los servicios
        stage('Construyendo y desplegando servicios') {
            when { expression { env.SHOULD_DEPLOY == 'true' } }
            steps {
                sh '''
                    docker compose -p "$COMPOSE_PROJECT" up --build -d
                '''
            }
        }

        // 9. Asegurar que Traefik (proxy compartido) esté corriendo. Es un stack
        //    aparte a proposito: sirve a produccion y staging a la vez, asi que un
        //    "down" de cualquiera de los dos no debe tumbarlo. Idempotente.
        //
        //    Es OBLIGATORIO: desde que el frontend dejo de publicar 80/443, sin
        //    Traefik no hay forma de llegar al sitio. Si la credencial falta, esta
        //    stage falla en vez de dejar el deploy "exitoso" con el sitio caido.
        //
        //    El .env viene de una credencial (no del workspace) porque esta en
        //    .gitignore: el checkout nunca lo traeria, y un workspace limpio lo
        //    perderia.
        stage('Asegurar Traefik en ejecución') {
            when { expression { env.SHOULD_DEPLOY == 'true' } }
            steps {
                withCredentials([file(credentialsId: 'traefik-env-file', variable: 'TRAEFIK_ENV')]) {
                    sh '''
                        cp -f "$TRAEFIK_ENV" traefik/.env
                        docker compose -p traefik -f traefik/docker-compose.yml up -d

                        # El proxy es el unico camino al sitio: si no quedo arriba,
                        # el deploy no sirve de nada.
                        sleep 5
                        state=$(docker inspect -f '{{.State.Status}}' traefik 2>/dev/null || echo "ausente")
                        if [ "$state" != "running" ]; then
                            echo "ERROR: Traefik quedó en estado '$state'. El sitio no es alcanzable."
                            docker logs traefik --tail 40 2>&1 || true
                            exit 1
                        fi
                        echo "Traefik en ejecución."
                    '''
                }
            }
        }

        // 9b. Asegurar el almacén de instrumentos (MinIO público). Igual que
        //     Traefik: stack independiente, idempotente, con su propia credencial.
        //     Corre en los dos ambientes porque el servicio es uno solo y no
        //     tiene gemelo de staging: da igual qué deploy lo levante.
        //
        //     NO es bloqueante, a diferencia de Traefik: sin el proxy el sitio
        //     es inalcanzable, pero que el repositorio de imágenes falle no
        //     justifica marcar en rojo un despliegue de la aplicación que ya
        //     salió bien. El fallo se reporta con los logs a la vista.
        stage('Asegurar almacén de instrumentos') {
            when { expression { env.SHOULD_DEPLOY == 'true' } }
            steps {
                // El try/catch es lo que hace que esta etapa sea de verdad no
                // bloqueante: sin el, withCredentials aborta el build cuando la
                // credencial todavia no existe, que es justo el estado normal
                // del primer deploy despues de agregar este stack.
                script {
                  try {
                    withCredentials([file(credentialsId: 'minio-public-env-file', variable: 'MINIO_PUBLIC_ENV')]) {
                    sh '''
                        set +e
                        cp -f "$MINIO_PUBLIC_ENV" minio-public/.env

                        # Se extrae solo el nombre del volumen en vez de hacer
                        # "source" del archivo completo: las contraseñas de este
                        # .env pueden llevar caracteres que el shell interpretaría.
                        # Compose lee el resto del .env por su cuenta, porque vive
                        # en el directorio del proyecto.
                        #
                        # El filtro final no es adorno: la credencial se edita en
                        # Windows, asi que el archivo llega con saltos de linea
                        # CRLF y el valor sale con un "" pegado al final.
                        # Compose lo tolera, pero docker no: rechaza el nombre
                        # "minio-public-volume" y sin volumen no levanta nada.
                        # Se deja solo el juego de caracteres que docker admite en
                        # un nombre de volumen, que es justo lo que dice su error.
                        vol=$(sed -n 's/^MINIO_PUBLIC_VOLUME=//p' minio-public/.env | tail -1 | tr -dc 'A-Za-z0-9_.-')
                        docker volume create "${vol:-minio-public-volume}" >/dev/null

                        docker compose -p minio-public -f minio-public/docker-compose.yml up -d

                        sleep 5
                        state=$(docker inspect -f '{{.State.Status}}' minio-public 2>/dev/null || echo "ausente")
                        if [ "$state" != "running" ]; then
                            echo "ADVERTENCIA: minio-public quedó en estado '$state'. El almacén de instrumentos no está disponible."
                            docker logs minio-public --tail 40 2>&1 || true
                            exit 0
                        fi

                        # El contenedor de configuración inicial es de un solo uso y
                        # termina enseguida: sus logs son el único lugar donde se ve
                        # si el bucket quedó bien configurado.
                        echo "=== Configuración inicial del bucket ==="
                        docker logs minio-public-init --tail 30 2>&1 || true
                        exit 0
                    '''
                    }
                  } catch (err) {
                    echo "ADVERTENCIA: no se pudo asegurar el almacén de instrumentos (${err.message}). El despliegue de la aplicación no se ve afectado."
                  }
                }
            }
        }

        // 10. Verificar que los contenedores quedaron en ejecución
        stage('Verificando despliegue') {
            when { expression { env.SHOULD_DEPLOY == 'true' } }
            steps {
                sh '''
                    echo "Esperando 15s para que los servicios inicien..."
                    sleep 15
                    docker compose -p "$COMPOSE_PROJECT" ps

                    for svc in backend frontend; do
                        cid=$(docker compose -p "$COMPOSE_PROJECT" ps -q "$svc")
                        if [ -z "$cid" ]; then
                            echo "ERROR: el servicio '$svc' no existe"
                            exit 1
                        fi
                        state=$(docker inspect -f '{{.State.Status}}' "$cid")
                        if [ "$state" != "running" ]; then
                            echo "ERROR: el servicio '$svc' está en estado '$state'"
                            exit 1
                        fi
                        echo "OK: $svc en ejecución"
                    done

                    echo "Despliegue verificado correctamente"
                '''
            }
        }

        // 11. Mantener instalado y actualizado el cron de respaldo diario (12:01am)
        //     en el propio servidor, independiente de Jenkins. Copia el script a una
        //     ruta fija (fuera del workspace de Jenkins, que puede limpiarse) y
        //     reemplaza cualquier entrada previa en el crontab del usuario que
        //     ejecuta este pipeline (jenkins) para que apunte siempre a la versión
        //     más reciente del script. No bloqueante: un fallo aquí no debe tumbar
        //     un deploy que ya se completó bien.
        //
        //     Solo produccion instala el cron: los datos de staging son de prueba
        //     y no justifican respaldos diarios.
        stage('Instalar cron de respaldo diario') {
            when {
                allOf {
                    expression { env.SHOULD_DEPLOY == 'true' }
                    expression { params.DEPLOY_ENV == 'prod' }
                }
            }
            steps {
                sh '''
                    set +e
                    mkdir -p "$HOME/cohorte-infra-scripts" "$HOME/backups/cohorte"
                    cp -f scripts/backup-db.sh "$HOME/cohorte-infra-scripts/backup-db.sh"
                    cp -f scripts/backup-bucket.sh "$HOME/cohorte-infra-scripts/backup-bucket.sh"
                    chmod +x "$HOME/cohorte-infra-scripts/backup-db.sh" "$HOME/cohorte-infra-scripts/backup-bucket.sh"

                    DB_LINE="1 0 * * * $HOME/cohorte-infra-scripts/backup-db.sh >> $HOME/backups/cohorte/backup.log 2>&1"
                    # 20 minutos después del dump, para no competir por disco y red
                    # con el respaldo de la base.
                    BUCKET_LINE="20 0 * * * $HOME/cohorte-infra-scripts/backup-bucket.sh >> $HOME/backups/cohorte/backup-bucket.log 2>&1"

                    ( crontab -l 2>/dev/null | grep -vF "backup-db.sh" | grep -vF "backup-bucket.sh" ; echo "$DB_LINE" ; echo "$BUCKET_LINE" ) | crontab -
                    echo "Crons de respaldo diario instalados/actualizados."
                    exit 0
                '''
            }
        }
    }

    post {
        success {
            script {
                if (env.SHOULD_DEPLOY == 'true') {
                    echo "Despliegue de '${params.DEPLOY_ENV}' completado."
                } else {
                    echo "Build fuera de la rama '${env.INFRA_BRANCH}' del repo de infraestructura: verificado, sin desplegar."
                }
            }
        }
        failure {
            sh '''
                echo "=== LOGS DEL BACKEND (ultimas 80 lineas) ==="
                docker compose -p "$COMPOSE_PROJECT" logs --tail=80 backend || true
            '''
        }
        always {
            echo 'Pipeline finalizado'
        }
    }
}
