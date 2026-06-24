pipeline {
    agent any

    environment {
        COMPOSE_PROJECT = 'cohorteapp'
        BACKEND_REPO    = 'https://github.com/MartinOM321753/Cohorte-IMSS.git'
        FRONTEND_REPO   = 'https://github.com/MartinOM321753/Cohorte-front.git'
        DEPLOY_BRANCH   = 'main'
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

        // 2. El despliegue solo corre si la rama es main (funciona tanto en job simple
        //    apuntado a main como en Multibranch Pipeline con varias ramas).
        stage('Verificar rama') {
            steps {
                script {
                    def branch = (env.BRANCH_NAME ?: env.GIT_BRANCH ?: '').replaceFirst(/^origin\//, '')
                    env.IS_MAIN = (branch == env.DEPLOY_BRANCH).toString()
                    echo "Rama detectada: '${branch}' -- desplegar=${env.IS_MAIN}"
                }
            }
        }

        // 3. Clonar el backend y el frontend en main, como hermanos de este repo.
        //    docker-compose.yml usa build.context: ./cohorte_test y ./client.
        stage('Clonar repos de aplicación') {
            when { expression { env.IS_MAIN == 'true' } }
            steps {
                sh '''
                    rm -rf cohorte_test
                    git clone --depth 1 --branch "$DEPLOY_BRANCH" "$BACKEND_REPO" cohorte_test
                    rm -rf client
                    git clone --depth 1 --branch "$DEPLOY_BRANCH" "$FRONTEND_REPO" client
                '''
            }
        }

        // 4. Copiar el .env real al workspace desde una credencial de Jenkins tipo
        //    "Secret file" (ID: cohorte-env-file). Nunca se versiona: vive solo en
        //    el workspace de este build y Jenkins lo borra al terminar.
        stage('Preparar variables de entorno') {
            when { expression { env.IS_MAIN == 'true' } }
            steps {
                withCredentials([file(credentialsId: 'cohorte-env-file', variable: 'ENV_FILE')]) {
                    sh 'cp -f "$ENV_FILE" .env'
                }
            }
        }

        // 5. Detener los servicios en ejecución
        stage('Parando servicios existentes') {
            when { expression { env.IS_MAIN == 'true' } }
            steps {
                sh '''
                    docker compose -p "$COMPOSE_PROJECT" down || true
                '''
            }
        }

        // 6. Construir y levantar todos los servicios
        stage('Construyendo y desplegando servicios') {
            when { expression { env.IS_MAIN == 'true' } }
            steps {
                sh '''
                    docker compose -p "$COMPOSE_PROJECT" up --build -d
                '''
            }
        }

        // 7. Verificar que los contenedores quedaron en ejecución
        stage('Verificando despliegue') {
            when { expression { env.IS_MAIN == 'true' } }
            steps {
                sh '''
                    echo "Esperando 15s para que los servicios inicien..."
                    sleep 15
                    docker compose -p "$COMPOSE_PROJECT" ps
                    docker compose -p "$COMPOSE_PROJECT" ps --filter "status=running" | grep -q "cohorte-backend" || {
                        echo "ERROR: el backend no está en ejecución"
                        exit 1
                    }
                    docker compose -p "$COMPOSE_PROJECT" ps --filter "status=running" | grep -q "cohorte-frontend" || {
                        echo "ERROR: el frontend no está en ejecución"
                        exit 1
                    }
                    echo "Despliegue verificado correctamente"
                '''
            }
        }

        // 8. Emitir el certificado SSL la primera vez (idempotente: si ya existe, no
        //    hace nada). El contenedor "frontend" arranca sirviendo HTTP-only mientras
        //    no haya certificado (ver docker-entrypoint.sh del repo Cohorte-front),
        //    asi que el reto HTTP-01 de Let's Encrypt puede resolverse sin que el
        //    pipeline falle.
        stage('Emitir certificado SSL si falta') {
            when { expression { env.IS_MAIN == 'true' } }
            steps {
                sh '''
                    set -a
                    . ./.env
                    set +a
                    DOMAIN="hwcs.cipps.unam.mx"

                    if docker compose -p "$COMPOSE_PROJECT" exec -T frontend test -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"; then
                        echo "Certificado ya existe para $DOMAIN, no se vuelve a emitir."
                    else
                        echo "No hay certificado para $DOMAIN, solicitando uno a Let's Encrypt..."
                        docker compose -p "$COMPOSE_PROJECT" run --rm certbot certonly \
                            --webroot --webroot-path=/var/www/certbot \
                            -d "$DOMAIN" \
                            --email "$CERTBOT_EMAIL" --agree-tos --no-eff-email --non-interactive

                        echo "Certificado emitido. Reiniciando frontend para activar HTTPS..."
                        docker compose -p "$COMPOSE_PROJECT" restart frontend
                    fi
                '''
            }
        }

        // 9. Renovar si ya esta cerca de expirar (certbot renew no hace nada si le
        //    quedan mas de 30 dias). Si renovo, recarga nginx sin downtime.
        stage('Renovar certificado SSL si aplica') {
            when { expression { env.IS_MAIN == 'true' } }
            steps {
                sh '''
                    docker compose -p "$COMPOSE_PROJECT" run --rm certbot renew --quiet || true
                    docker compose -p "$COMPOSE_PROJECT" exec -T frontend nginx -s reload || true
                '''
            }
        }
    }

    post {
        success {
            script {
                if (env.IS_MAIN == 'true') {
                    echo 'Despliegue completado. Frontend: http://<servidor>  Backend (solo localhost): http://127.0.0.1:8081'
                } else {
                    echo 'Rama distinta de main: build verificado, sin desplegar.'
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
