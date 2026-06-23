pipeline {
    agent any
    // Si tienes un nodo Windows etiquetado:
    // agent { label 'windows' }

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
                bat '''
                    if exist cohorte_test rmdir /s /q cohorte_test
                    git clone --depth 1 --branch %DEPLOY_BRANCH% %BACKEND_REPO% cohorte_test
                    if exist client rmdir /s /q client
                    git clone --depth 1 --branch %DEPLOY_BRANCH% %FRONTEND_REPO% client
                '''
            }
        }

        // 4. Generar .env en el workspace a partir de credenciales de Jenkins.
        //    Nunca se versiona: vive solo en el workspace de este build.
        //    Credenciales esperadas (tipo "Secret text") en Jenkins, ver README.md:
        //    cohorte-db-password, cohorte-minio-access-key, cohorte-minio-secret-key,
        //    cohorte-jwt-secret, cohorte-mail-username, cohorte-mail-password,
        //    cohorte-mail-from, cohorte-frontend-url
        stage('Preparar variables de entorno') {
            when { expression { env.IS_MAIN == 'true' } }
            steps {
                withCredentials([
                    string(credentialsId: 'cohorte-db-password',      variable: 'DB_PASSWORD'),
                    string(credentialsId: 'cohorte-minio-access-key', variable: 'MINIO_ACCESS_KEY'),
                    string(credentialsId: 'cohorte-minio-secret-key', variable: 'MINIO_SECRET_KEY'),
                    string(credentialsId: 'cohorte-jwt-secret',       variable: 'SECRET_KEY'),
                    string(credentialsId: 'cohorte-mail-username',    variable: 'MAIL_USERNAME'),
                    string(credentialsId: 'cohorte-mail-password',    variable: 'MAIL_PASSWORD'),
                    string(credentialsId: 'cohorte-mail-from',        variable: 'MAIL_FROM'),
                    string(credentialsId: 'cohorte-frontend-url',     variable: 'FRONTEND_URL'),
                ]) {
                    bat '''
                        (
                          echo DB_USER_NAME=root
                          echo DB_PASSWORD=%DB_PASSWORD%
                          echo MINIO_ACCESS_KEY=%MINIO_ACCESS_KEY%
                          echo MINIO_SECRET_KEY=%MINIO_SECRET_KEY%
                          echo SECRET_KEY=%SECRET_KEY%
                          echo MAIL_USERNAME=%MAIL_USERNAME%
                          echo MAIL_PASSWORD=%MAIL_PASSWORD%
                          echo MAIL_FROM=%MAIL_FROM%
                          echo FRONTEND_URL=%FRONTEND_URL%
                          echo COOKIE_SECURE=true
                          echo SPRING_PROFILES_ACTIVE=prod
                          echo VITE_API_URL=/api
                        ) > .env
                    '''
                }
            }
        }

        // 5. Detener los servicios en ejecución
        stage('Parando servicios existentes') {
            when { expression { env.IS_MAIN == 'true' } }
            steps {
                bat '''
                    docker compose -p %COMPOSE_PROJECT% down || exit /b 0
                '''
            }
        }

        // 6. Construir y levantar todos los servicios
        stage('Construyendo y desplegando servicios') {
            when { expression { env.IS_MAIN == 'true' } }
            steps {
                bat '''
                    docker compose -p %COMPOSE_PROJECT% up --build -d
                '''
            }
        }

        // 7. Verificar que los contenedores quedaron en ejecución
        stage('Verificando despliegue') {
            when { expression { env.IS_MAIN == 'true' } }
            steps {
                bat '''
                    echo Esperando 15s para que los servicios inicien...
                    timeout /t 15 /nobreak > nul
                    docker compose -p %COMPOSE_PROJECT% ps
                    docker compose -p %COMPOSE_PROJECT% ps --filter "status=running" | find "cohorte-backend" > nul
                    if errorlevel 1 (
                        echo ERROR: el backend no está en ejecución
                        exit /b 1
                    )
                    docker compose -p %COMPOSE_PROJECT% ps --filter "status=running" | find "cohorte-frontend" > nul
                    if errorlevel 1 (
                        echo ERROR: el frontend no está en ejecución
                        exit /b 1
                    )
                    echo Despliegue verificado correctamente
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
            bat '''
                echo === LOGS DEL BACKEND (ultimas 80 lineas) ===
                docker compose -p %COMPOSE_PROJECT% logs --tail=80 backend || exit /b 0
            '''
        }
        always {
            echo 'Pipeline finalizado'
        }
    }
}
