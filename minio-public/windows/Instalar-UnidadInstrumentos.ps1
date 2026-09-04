<#
    Instalador de la unidad de red del almacen de instrumentos.

    Deja el equipo con una unidad (S: por defecto) que el Explorador trata como
    una carpeta normal pero que en realidad es el bucket de MinIO. Hace las
    cuatro cosas que hay que hacer una sola vez por maquina:

        1. Instala WinFsp (el driver que permite montar sistemas de archivos
           que no son discos reales). Es lo unico que pide permisos de
           administrador.
        2. Instala rclone si no esta.
        3. Escribe el remoto en la configuracion de rclone del usuario.
        4. Registra una tarea programada que monta la unidad en cada inicio de
           sesion, y la arranca en el momento.

    Se puede volver a ejecutar sin miedo: cada paso comprueba antes de actuar.

    A proposito NO eleva todo el script a administrador, solo la instalacion de
    WinFsp. Si alguien aprueba el UAC con una cuenta de administrador distinta a
    la suya, un script elevado escribiria la configuracion y la tarea en el
    perfil equivocado y la unidad no le apareceria nunca.

    Uso:
        .\Instalar-UnidadInstrumentos.ps1
        .\Instalar-UnidadInstrumentos.ps1 -Letra U
        .\Instalar-UnidadInstrumentos.ps1 -Desinstalar
#>

[CmdletBinding()]
param(
    # Credenciales de subida. Si no se pasan, el script las pide. No se
    # incrustan en el archivo a proposito: este instalador se reparte por
    # correo, y una llave dentro de el seria una llave publicada. Cada persona
    # debe recibir la suya por separado, para poder revocarla sola.
    [string] $AccessKey,
    [string] $SecretKey,

    [string] $Endpoint = 'https://staging.hwcs.cipps.unam.mx',
    [string] $Bucket   = 'archivos-instrumentos',
    [string] $Remoto   = 'instrumentos',

    [ValidatePattern('^[D-Zd-z]$')]
    [string] $Letra    = 'S',

    [switch] $Desinstalar,

    # Al desinstalar se borra tambien la credencial guardada en este equipo.
    # Este interruptor la conserva, para el caso de quitar la unidad un rato y
    # volver a ponerla sin tener que pedir la llave otra vez.
    [switch] $ConservarCredenciales
)

$ErrorActionPreference = 'Stop'
$Tarea = 'Unidad almacen de instrumentos'
$DirRclone = Join-Path $env:LOCALAPPDATA 'rclone'
$LogMontaje = Join-Path $DirRclone 'mount-instrumentos.log'
$script:Rclone = $null

function Escribir($Texto) { Write-Host $Texto -ForegroundColor Gray }
function Paso($Texto)  { Write-Host ''; Write-Host "== $Texto" -ForegroundColor Cyan }
function Bien($Texto)  { Write-Host "   OK  $Texto" -ForegroundColor Green }
function Aviso($Texto) { Write-Host "   !   $Texto" -ForegroundColor Yellow }

function Salir-ConError($Texto) {
    Write-Host ''
    Write-Host "ERROR: $Texto" -ForegroundColor Red
    Write-Host ''
    Read-Host 'Pulsa Enter para cerrar'
    exit 1
}

# -- Localizar rclone ---------------------------------------------------------
# Puede estar en el PATH (instalado con winget) o en la carpeta propia que crea
# este script. Se devuelve la ruta completa porque la tarea programada no hereda
# el PATH del usuario de forma fiable.
function Buscar-Rclone {
    $enPath = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if ($enPath) { return $enPath.Source }
    $propio = Join-Path $DirRclone 'rclone.exe'
    if (Test-Path $propio) { return $propio }
    return $null
}

# -- Llamar a rclone sin que un aviso suyo tumbe el script --------------------
# PowerShell 5.1 convierte CADA linea que un .exe escribe en stderr en un error
# de PowerShell; con ErrorActionPreference='Stop' eso aborta el script aunque el
# programa haya terminado perfectamente. Y rclone usa stderr para avisos de
# rutina: en un equipo recien instalado lo primero que dice es que todavia no
# hay archivo de configuracion. Sin esta funcion el instalador moria justo ahi,
# un paso antes de pedir las credenciales, y el usuario no llegaba a escribirlas.
function Invocar-Rclone {
    param([string[]] $Argumentos)

    $previo = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $salida = & $script:Rclone @Argumentos --log-level ERROR 2>&1
        $codigo = $LASTEXITCODE

        # Las lineas de stderr llegan envueltas en ErrorRecord y "Out-String"
        # les pega encima el numero de linea y el rastro de PowerShell. Se
        # desenvuelven para que un fallo se lea como lo escribio rclone y no
        # como un volcado del script.
        $lineas = foreach ($linea in $salida) {
            if ($linea -is [System.Management.Automation.ErrorRecord]) { $linea.Exception.Message }
            else { [string]$linea }
        }

        return [pscustomobject]@{
            Texto  = (($lineas -join [Environment]::NewLine)).Trim()
            Codigo = $codigo
        }
    } finally {
        $ErrorActionPreference = $previo
    }
}

# -- Preguntar si/no ----------------------------------------------------------
function Preguntar($Texto) {
    Write-Host ''
    $r = Read-Host "   $Texto [s/N]"
    return ($r -match '^[sSyY]')
}

# -----------------------------------------------------------------------------
#  Desinstalacion
# -----------------------------------------------------------------------------
if ($Desinstalar) {
    Paso 'Quitando la unidad'

    $t = Get-ScheduledTask -TaskName $Tarea -ErrorAction SilentlyContinue
    if ($t) {
        try { Stop-ScheduledTask -TaskName $Tarea -ErrorAction SilentlyContinue } catch { }
        Unregister-ScheduledTask -TaskName $Tarea -Confirm:$false
        Bien 'Tarea programada eliminada.'
    } else {
        Aviso 'No habia tarea programada.'
    }

    # Solo se matan los procesos de rclone que esten montando ESTE remoto: la
    # gente puede tener otros montajes o respaldos suyos corriendo.
    $procesos = Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" |
                Where-Object { $_.CommandLine -like "*${Remoto}:*" }
    foreach ($p in $procesos) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Bien 'Montaje detenido.'
    }

    # Borrar la credencial es la mitad importante de desinstalar. Quitar la
    # unidad solo la saca de la vista: mientras el remoto siga configurado,
    # cualquiera con esta sesion de Windows conserva permiso de ESCRITURA sobre
    # el bucket, que es exactamente lo que no se quiere al entregar un equipo.
    $script:Rclone = Buscar-Rclone
    if ($ConservarCredenciales) {
        Aviso 'Se conserva la credencial guardada (-ConservarCredenciales).'
    } elseif ($script:Rclone) {
        Invocar-Rclone @('config', 'delete', $Remoto) | Out-Null
        Bien 'Credencial borrada de este equipo.'
    }

    # -- Programas de apoyo, opcional -----------------------------------------
    # Se pregunta en vez de quitarlos sin avisar: otras herramientas pueden
    # depender de WinFsp, y quitarlo con el Explorador abierto puede dejarlo
    # colgado hasta reiniciar.
    Write-Host ''
    Escribir '  WinFsp y rclone se quedan instalados salvo que pidas lo contrario.'
    if (Preguntar 'Desinstalarlos tambien?') {

        if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
            Write-Host ''
            Aviso 'Al quitar WinFsp el Explorador puede quedarse colgado un momento.'
            Aviso 'Si el escritorio desaparece, reinicia el equipo y vuelve solo.'

            Paso 'Desinstalando rclone'
            $r = Start-Process winget.exe -ArgumentList 'uninstall','--id','Rclone.Rclone','--silent','--disable-interactivity','--accept-source-agreements' -Wait -PassThru -NoNewWindow
            if ($r.ExitCode -eq 0) { Bien 'Desinstalado.' } else { Aviso "No se pudo (codigo $($r.ExitCode)). Quitalo desde Configuracion > Aplicaciones." }

            # La carpeta propia solo existe si rclone se instalo desde aqui.
            if (Test-Path $DirRclone) { Remove-Item $DirRclone -Recurse -Force -ErrorAction SilentlyContinue }

            Paso 'Desinstalando WinFsp'
            Escribir '   Windows va a pedir permiso de administrador...'
            $w = Start-Process winget.exe -ArgumentList 'uninstall','--id','WinFsp.WinFsp','--silent','--disable-interactivity','--accept-source-agreements' -Verb RunAs -Wait -PassThru
            if ($w.ExitCode -eq 0) { Bien 'Desinstalado.' } else { Aviso "No se pudo (codigo $($w.ExitCode)). Quitalo desde Configuracion > Aplicaciones." }

        } else {
            Aviso 'Este equipo no tiene winget.'
            Escribir '   Quitalos a mano desde Configuracion > Aplicaciones.'
        }
    }

    Write-Host ''
    Write-Host '  Listo. La unidad ya no se montara al iniciar sesion.' -ForegroundColor Green
    Escribir '  Los archivos siguen en el servidor.'
    Write-Host ''
    Read-Host 'Pulsa Enter para cerrar'
    exit 0
}

# -----------------------------------------------------------------------------
#  Instalacion
# -----------------------------------------------------------------------------
Write-Host ''
Write-Host '  Almacen de instrumentos - instalacion de la unidad de red' -ForegroundColor White
Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
Escribir "  Servidor : $Endpoint"
Escribir "  Bucket   : $Bucket"
Escribir "  Unidad   : ${Letra}:"

# -- 1. Comprobar que la letra este libre -------------------------------------
Paso "Comprobando que la unidad ${Letra}: este libre"
if (Test-Path "${Letra}:\") {
    # Si ya la monto una instalacion previa de este mismo script, no es un
    # conflicto: se va a reemplazar. Cualquier otra cosa si lo es.
    $yaEsNuestra = Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" |
                   Where-Object { $_.CommandLine -like "*${Remoto}:*" -and $_.CommandLine -like "*${Letra}:*" }
    if ($yaEsNuestra) {
        Aviso 'Ya estaba montada por una instalacion anterior; se volvera a montar.'
        foreach ($p in $yaEsNuestra) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
    } else {
        Salir-ConError "La letra ${Letra}: ya esta ocupada por otra unidad. Vuelve a ejecutar con otra letra, por ejemplo:`n         .\Instalar-UnidadInstrumentos.ps1 -Letra U"
    }
} else {
    Bien 'Libre.'
}

# -- 2. WinFsp ----------------------------------------------------------------
Paso 'Comprobando WinFsp'

$winfspInstalado = (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\WinFsp') -or
                   (Test-Path 'HKLM:\SOFTWARE\WinFsp') -or
                   (Test-Path (Join-Path ${env:ProgramFiles(x86)} 'WinFsp')) -or
                   (Test-Path (Join-Path $env:ProgramFiles 'WinFsp'))

if ($winfspInstalado) {
    Bien 'Ya estaba instalado.'
} else {
    Escribir '   No esta. Descargando el instalador oficial...'

    # Se resuelve la version mas reciente en el momento en vez de fijar una URL:
    # un enlace con numero de version envejece y deja el instalador roto para
    # quien lo ejecute dentro de un anio.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod 'https://api.github.com/repos/winfsp/winfsp/releases/latest' -UseBasicParsing
        $asset = $release.assets | Where-Object { $_.name -like '*.msi' -and $_.name -notlike '*tests*' } | Select-Object -First 1
        if (-not $asset) { throw 'la ultima version publicada no trae instalador .msi' }
    } catch {
        Salir-ConError "No se pudo averiguar la version de WinFsp ($($_.Exception.Message)).`n       Instalalo a mano desde https://winfsp.dev y vuelve a ejecutar este archivo."
    }

    $msi = Join-Path $env:TEMP $asset.name
    try {
        Invoke-WebRequest $asset.browser_download_url -OutFile $msi -UseBasicParsing
    } catch {
        Salir-ConError "No se pudo descargar WinFsp ($($_.Exception.Message)). Revisa la conexion a internet."
    }

    Escribir '   Instalando. Windows va a pedir permiso de administrador...'
    $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') -Verb RunAs -Wait -PassThru
    Remove-Item $msi -ErrorAction SilentlyContinue

    # 3010 = instalado correctamente pero pide reinicio.
    if ($p.ExitCode -eq 3010) {
        Aviso 'WinFsp quedo instalado pero Windows pide reiniciar.'
        Aviso 'Si al final la unidad no aparece, reinicia y vuelve a ejecutar este archivo.'
    } elseif ($p.ExitCode -ne 0) {
        Salir-ConError "El instalador de WinFsp termino con codigo $($p.ExitCode). Si cancelaste el aviso de administrador, vuelve a intentarlo."
    } else {
        Bien 'Instalado.'
    }
}

# -- 3. rclone ----------------------------------------------------------------
Paso 'Comprobando rclone'

$script:Rclone = Buscar-Rclone
if ($script:Rclone) {
    Bien "Ya estaba instalado ($script:Rclone)."
} else {
    Escribir '   No esta. Descargando...'
    New-Item -ItemType Directory -Force $DirRclone | Out-Null
    $zip = Join-Path $env:TEMP 'rclone-current-windows-amd64.zip'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest 'https://downloads.rclone.org/rclone-current-windows-amd64.zip' -OutFile $zip -UseBasicParsing
    } catch {
        Salir-ConError "No se pudo descargar rclone ($($_.Exception.Message)). Revisa la conexion a internet."
    }

    $tmp = Join-Path $env:TEMP 'rclone-extraido'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force

    # El zip trae el ejecutable dentro de una carpeta con el numero de version.
    $exe = Get-ChildItem $tmp -Recurse -Filter 'rclone.exe' | Select-Object -First 1
    if (-not $exe) { Salir-ConError 'El archivo descargado de rclone no contenia el ejecutable.' }

    Copy-Item $exe.FullName (Join-Path $DirRclone 'rclone.exe') -Force
    Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue

    $script:Rclone = Join-Path $DirRclone 'rclone.exe'
    Bien "Instalado en $script:Rclone"
}

# -- 4. Credenciales ----------------------------------------------------------
Paso 'Credenciales de acceso'

# Si el remoto ya esta configurado y responde, no se vuelve a pedir nada. Esto
# importa porque la razon mas comun para re-ejecutar el instalador es reparar
# un montaje que desaparecio, y en ese caso obligar a teclear otra vez la
# contrasena solo consigue que la persona no lo intente.
$yaConfigurado = $false
if (-not $AccessKey) {
    $lista = Invocar-Rclone @('listremotes')
    if ($lista.Codigo -eq 0 -and $lista.Texto -match "(?m)^$([regex]::Escape($Remoto)):\s*$") {
        $prueba = Invocar-Rclone @('lsd', "${Remoto}:$Bucket")
        if ($prueba.Codigo -eq 0) { $yaConfigurado = $true }
    }
}

if ($yaConfigurado) {
    Bien 'Este equipo ya estaba configurado y el servidor responde; se conservan los datos.'
} else {
    Write-Host ''
    Escribir '   Ahora hacen falta los dos datos que te dieron para este equipo.'
    Escribir '   No son los de tu correo ni los del sistema Cohorte: son aparte,'
    Escribir '   solo para esta carpeta.'
    Write-Host ''

    if (-not $AccessKey) {
        Write-Host '   1) Usuario  (algo parecido a "instrumentos-upload")' -ForegroundColor White
        $AccessKey = Read-Host '      Escribelo aqui y pulsa Enter'
        if (-not $AccessKey) { Salir-ConError 'No se escribio ningun usuario. Vuelve a ejecutar este archivo.' }
    }

    if (-not $SecretKey) {
        Write-Host ''
        Write-Host '   2) Contrasena' -ForegroundColor White
        Escribir '      No se vera nada mientras la escribes. Es normal: escribela'
        Escribir '      completa, o pegala con clic derecho, y pulsa Enter.'
        $segura = Read-Host '      Contrasena' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($segura)
        try {
            $SecretKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        if (-not $SecretKey) { Salir-ConError 'No se escribio ninguna contrasena. Vuelve a ejecutar este archivo.' }
    }

    # -- 5. Configurar el remoto ----------------------------------------------
    Paso 'Guardando la configuracion'

    # Se usa el propio rclone en vez de escribir el .conf a mano: asi respeta
    # cualquier otro remoto que la persona ya tenga configurado, y no hay riesgo
    # de dejar el archivo con codificacion o saltos de linea que no entienda.
    Invocar-Rclone @('config', 'delete', $Remoto) | Out-Null

    $cfg = Invocar-Rclone @(
        'config', 'create', $Remoto, 's3',
        'provider=Minio',
        "endpoint=$Endpoint",
        "access_key_id=$AccessKey",
        "secret_access_key=$SecretKey",
        'region=us-east-1',
        'force_path_style=true',
        # no_check_bucket no es opcional: sin el, rclone empieza preguntando por
        # la raiz del servidor, que no cae en la ruta del bucket y se la queda la
        # aplicacion web. Con el, todo va bajo el prefijo correcto.
        'no_check_bucket=true'
    )
    if ($cfg.Codigo -ne 0) { Salir-ConError "No se pudo guardar la configuracion.`n`n$($cfg.Texto)" }
    Bien 'Configuracion guardada.'
}

# -- 6. Probar la conexion ANTES de montar ------------------------------------
# Separar esta prueba del montaje es lo que permite distinguir "la contrasena
# esta mal" de "el driver no arranco". Si se falla aqui, no se registra nada.
Paso 'Probando la conexion con el servidor'

$prueba = Invocar-Rclone @('lsd', "${Remoto}:$Bucket")
if ($prueba.Codigo -ne 0) {
    if ($prueba.Texto -match 'AccessDenied|InvalidAccessKeyId|SignatureDoesNotMatch') {
        Salir-ConError "El servidor rechazo los datos. Revisa el usuario y la contrasena, y vuelve a ejecutar este archivo.`n`n$($prueba.Texto)"
    }
    Salir-ConError "No se pudo conectar con el servidor.`n`n$($prueba.Texto)"
}
Bien 'Conexion correcta.'

# -- 7. Tarea programada ------------------------------------------------------
Paso 'Programando el montaje automatico'

$argsMontaje = "mount ${Remoto}:$Bucket ${Letra}: --network-mode --vfs-cache-mode full --no-console --log-file `"$LogMontaje`" --log-level INFO"

$accion = New-ScheduledTaskAction -Execute $script:Rclone -Argument $argsMontaje

# El retraso da tiempo a que la red este lista: en muchos equipos el inicio de
# sesion ocurre antes de que haya conectividad, y el montaje arrancaria a ciegas.
$disparador = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$disparador.Delay = 'PT30S'

# LogonType Interactive: la unidad pertenece a la sesion de Windows. Si la tarea
# corriera fuera de la sesion del usuario, el proceso viviria pero la unidad no
# apareceria nunca en su Explorador.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

# ExecutionTimeLimit en cero es imprescindible: por defecto Windows mata las
# tareas a los 3 dias, y esta tiene que vivir indefinidamente porque el proceso
# ES la unidad.
$ajustes = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
             -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

try {
    Register-ScheduledTask -TaskName $Tarea -Action $accion -Trigger $disparador `
        -Principal $principal -Settings $ajustes -Force `
        -Description 'Monta el almacen de instrumentos como unidad de red al iniciar sesion.' | Out-Null
} catch {
    Salir-ConError "No se pudo crear la tarea programada ($($_.Exception.Message))."
}
Bien 'Se montara sola en cada inicio de sesion.'

# -- 8. Montar ahora ----------------------------------------------------------
Paso 'Montando la unidad'
Start-ScheduledTask -TaskName $Tarea

$montada = $false
foreach ($i in 1..20) {
    Start-Sleep -Seconds 1
    if (Test-Path "${Letra}:\") { $montada = $true; break }
}

Write-Host ''
if ($montada) {
    Write-Host "  Listo. La unidad ${Letra}: ya esta disponible en el Explorador." -ForegroundColor Green
    Write-Host ''
    Escribir '  Lo que conviene saber:'
    Escribir '   - Los archivos viven en el servidor, no en este equipo. Sin'
    Escribir '     internet la unidad aparece vacia o no responde; no se ha'
    Escribir '     perdido nada.'
    Escribir '   - Borrar ahi borra en el servidor, y no pasa por la Papelera.'
    Escribir '   - Sirve para depositar y consultar archivos. Para trabajar un'
    Escribir '     documento durante horas, copialo al disco y devuelvelo.'
} else {
    Aviso "La unidad ${Letra}: no aparecio todavia."
    Escribir ''
    Escribir '  Casi siempre es que WinFsp necesita un reinicio para activarse.'
    Escribir '  Reinicia el equipo: la unidad deberia aparecer sola al entrar.'
    Escribir '  Si no, el detalle del error esta en:'
    Escribir "    $LogMontaje"
}

Write-Host ''
Read-Host 'Pulsa Enter para cerrar'
