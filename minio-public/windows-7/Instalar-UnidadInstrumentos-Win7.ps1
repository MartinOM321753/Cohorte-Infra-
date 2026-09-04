<#
    Instalador de la unidad de red del almacen de instrumentos -- WINDOWS 7.

    Hace lo mismo que el de ../windows/, pero Windows 7 obliga a hacerlo con
    otras herramientas. Es un script aparte y no una variante del otro porque
    casi todo el mecanismo cambia:

      - PowerShell 2.0 es lo que trae Windows 7 SP1. No existen
        Invoke-WebRequest, Expand-Archive, Get-CimInstance, [pscustomobject]
        ni los cmdlets *-ScheduledTask. Aqui se usan WebClient, la shell COM
        para descomprimir, WMI, New-Object PSObject y schtasks.exe.
      - Las versiones se FIJAN, no se busca "la mas reciente":
          rclone  1.63.1  -- la ultima compilada con Go 1.20. De la 1.64 en
                             adelante se compilan con Go 1.21, que dejo fuera a
                             Windows 7: el binario ni siquiera arranca.
          WinFsp  1.12.22339 -- la ultima que el proyecto probo en Windows 7 SP1.
                             Las 2.x no lo mencionan en sus notas.
      - TLS 1.2: Windows 7 negocia TLS 1.0 por defecto y los servidores de
        descarga ya no lo aceptan. Se fuerza por valor numerico porque el
        nombre Tls12 no existe en .NET 3.5/4.0.

    Si la descarga falla (equipo sin .NET moderno o sin los parches de TLS),
    se pueden dejar los dos archivos junto a este script y los usa sin bajar
    nada. Ver LEEME.txt.

    Uso:
        .\Instalar-UnidadInstrumentos-Win7.ps1
        .\Instalar-UnidadInstrumentos-Win7.ps1 -Letra U
        .\Instalar-UnidadInstrumentos-Win7.ps1 -Desinstalar
#>

[CmdletBinding()]
param(
    # Credenciales de subida. Si no se pasan, el script las pide. No se
    # incrustan en el archivo a proposito: este instalador se reparte por
    # correo, y una llave dentro de el seria una llave publicada.
    [string] $AccessKey,
    [string] $SecretKey,

    [string] $Endpoint = 'https://staging.hwcs.cipps.unam.mx',
    [string] $Bucket   = 'archivos-instrumentos',
    [string] $Remoto   = 'instrumentos',

    [ValidatePattern('^[D-Zd-z]$')]
    [string] $Letra    = 'S',

    [switch] $Desinstalar,
    [switch] $ConservarCredenciales
)

$ErrorActionPreference = 'Stop'

$Tarea      = 'Unidad almacen de instrumentos'
$DirRclone  = Join-Path $env:LOCALAPPDATA 'rclone'
$LogMontaje = Join-Path $DirRclone 'mount-instrumentos.log'
$script:Rclone = $null

# Versiones fijadas para Windows 7 (ver cabecera).
$RcloneVersion = 'v1.63.1'
$WinFspMsi     = 'winfsp-1.12.22339.msi'
$WinFspUrl     = 'https://github.com/winfsp/winfsp/releases/download/v1.12.22339/winfsp-1.12.22339.msi'

# Carpeta donde vive este script: es donde se buscan los instaladores si se
# quiso preparar un paquete sin conexion.
$DirScript = Split-Path -Parent $MyInvocation.MyCommand.Definition

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

function Preguntar($Texto) {
    Write-Host ''
    $r = Read-Host "   $Texto [s/N]"
    return ($r -match '^[sSyY]')
}

# -- TLS 1.2 ------------------------------------------------------------------
# Windows 7 negocia TLS 1.0 por defecto y github.com y downloads.rclone.org ya
# no lo aceptan. El nombre [Net.SecurityProtocolType]::Tls12 no existe en las
# versiones viejas de .NET, pero el valor numerico 3072 si se acepta cuando el
# .NET instalado lo soporta (4.5 o superior).
function Habilitar-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor 3072
        return $true
    } catch {
        return $false
    }
}

# -- Descargar ----------------------------------------------------------------
# WebClient en vez de Invoke-WebRequest, que no existe en PowerShell 2.0.
function Descargar($Url, $Destino) {
    $cliente = New-Object System.Net.WebClient
    $cliente.Headers.Add('User-Agent', 'instalador-instrumentos')
    $cliente.DownloadFile($Url, $Destino)
}

# -- Descomprimir -------------------------------------------------------------
# Expand-Archive es de PowerShell 5. En Windows 7 se usa la shell de Windows,
# que sabe abrir .zip desde que existe el Explorador y no necesita nada extra.
function Descomprimir($Zip, $Destino) {
    if (-not (Test-Path $Destino)) { New-Item -ItemType Directory -Force $Destino | Out-Null }
    $shell = New-Object -ComObject Shell.Application
    $origen = $shell.NameSpace($Zip)
    $dest   = $shell.NameSpace($Destino)
    if ($origen -eq $null -or $dest -eq $null) { throw 'no se pudo abrir el archivo comprimido' }
    # 16 = responder "si" a todo; 4 = sin barra de progreso.
    $dest.CopyHere($origen.Items(), 20)
}

# -- Buscar rclone ------------------------------------------------------------
function Buscar-Rclone {
    $enPath = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if ($enPath) { return $enPath.Definition }
    $propio = Join-Path $DirRclone 'rclone.exe'
    if (Test-Path $propio) { return $propio }
    return $null
}

# -- Llamar a rclone sin que un aviso suyo tumbe el script --------------------
# PowerShell convierte CADA linea que un .exe escribe en stderr en un error
# propio; con ErrorActionPreference='Stop' eso aborta el script aunque el
# programa haya terminado bien. Y rclone usa stderr para avisos de rutina: en un
# equipo recien instalado lo primero que dice es que aun no hay configuracion.
function Invocar-Rclone {
    param([string[]] $Argumentos)

    $previo = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $salida = & $script:Rclone @Argumentos --log-level ERROR 2>&1
        $codigo = $LASTEXITCODE

        $lineas = @()
        foreach ($linea in $salida) {
            if ($linea -is [System.Management.Automation.ErrorRecord]) { $lineas += $linea.Exception.Message }
            else { $lineas += [string]$linea }
        }

        return New-Object PSObject -Property @{
            Texto  = ($lineas -join [Environment]::NewLine).Trim()
            Codigo = $codigo
        }
    } finally {
        $ErrorActionPreference = $previo
    }
}

# -- Tarea programada (schtasks, no cmdlets) ----------------------------------
function Existe-Tarea {
    $null = & schtasks.exe /Query /TN $Tarea 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Borrar-Tarea {
    $null = & schtasks.exe /Delete /TN $Tarea /F 2>&1
    return ($LASTEXITCODE -eq 0)
}

# -----------------------------------------------------------------------------
#  Comprobaciones previas
# -----------------------------------------------------------------------------
if ($PSVersionTable -eq $null -or $PSVersionTable.PSVersion.Major -lt 2) {
    Salir-ConError 'Este equipo tiene PowerShell 1.0. Instala Windows Management Framework 2.0 o superior y vuelve a intentarlo.'
}

# -----------------------------------------------------------------------------
#  Desinstalacion
# -----------------------------------------------------------------------------
if ($Desinstalar) {
    Paso 'Quitando la unidad'

    if (Existe-Tarea) {
        $null = & schtasks.exe /End /TN $Tarea 2>&1
        if (Borrar-Tarea) { Bien 'Tarea programada eliminada.' }
        else { Aviso 'No se pudo eliminar la tarea programada.' }
    } else {
        Aviso 'No habia tarea programada.'
    }

    # Solo se detienen los procesos de rclone que montan ESTE remoto: el equipo
    # puede tener otros montajes o respaldos propios corriendo.
    $procesos = Get-WmiObject Win32_Process -Filter "Name = 'rclone.exe'" |
                Where-Object { $_.CommandLine -like "*${Remoto}:*" }
    foreach ($p in $procesos) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Bien 'Montaje detenido.'
    }

    # Borrar la credencial es la mitad importante de desinstalar. Quitar la
    # unidad solo la saca de la vista: mientras el remoto siga configurado,
    # cualquiera con esta sesion de Windows conserva permiso de ESCRITURA sobre
    # el bucket, que es justo lo que no se quiere al entregar un equipo.
    $script:Rclone = Buscar-Rclone
    if ($ConservarCredenciales) {
        Aviso 'Se conserva la credencial guardada (-ConservarCredenciales).'
    } elseif ($script:Rclone) {
        Invocar-Rclone @('config', 'delete', $Remoto) | Out-Null
        Bien 'Credencial borrada de este equipo.'
    }

    # -- Programas de apoyo, opcional -----------------------------------------
    Write-Host ''
    Escribir '  WinFsp y rclone se quedan instalados salvo que pidas lo contrario.'
    if (Preguntar 'Desinstalarlos tambien?') {
        Write-Host ''
        Aviso 'Al quitar WinFsp el Explorador puede quedarse colgado un momento.'
        Aviso 'Si el escritorio desaparece, reinicia el equipo y vuelve solo.'

        # rclone se instala como copia portable en la carpeta del usuario: se
        # quita borrandola. En Windows 7 no hay winget que valga.
        Paso 'Quitando rclone'
        if (Test-Path $DirRclone) {
            Remove-Item $DirRclone -Recurse -Force -ErrorAction SilentlyContinue
            Bien 'Eliminado.'
        } else {
            Aviso 'No estaba la carpeta de rclone.'
        }

        # WinFsp si es un MSI: se busca su codigo de producto en el registro y
        # se desinstala con msiexec, que es lo que hay sin winget.
        Paso 'Desinstalando WinFsp'
        $claves = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $entrada = $null
        foreach ($k in $claves) {
            $entrada = Get-ItemProperty $k -ErrorAction SilentlyContinue |
                       Where-Object { $_.DisplayName -like 'WinFsp*' } | Select-Object -First 1
            if ($entrada) { break }
        }

        if ($entrada) {
            $codigo = Split-Path -Leaf $entrada.PSPath
            Escribir '   Windows va a pedir permiso de administrador...'
            $m = Start-Process msiexec.exe -ArgumentList @('/x', $codigo, '/qn', '/norestart') -Verb RunAs -Wait -PassThru
            if ($m.ExitCode -eq 0 -or $m.ExitCode -eq 3010) { Bien 'Desinstalado.' }
            else { Aviso "No se pudo (codigo $($m.ExitCode)). Quitalo desde Panel de control > Programas." }
        } else {
            Aviso 'No se encontro WinFsp instalado. Quitalo desde Panel de control > Programas si hace falta.'
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
Write-Host '  Almacen de instrumentos - instalacion (Windows 7)' -ForegroundColor White
Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray
Escribir "  Servidor : $Endpoint"
Escribir "  Bucket   : $Bucket"
Escribir "  Unidad   : ${Letra}:"

# -- 1. Comprobar que la letra este libre -------------------------------------
Paso "Comprobando que la unidad ${Letra}: este libre"
if (Test-Path "${Letra}:\") {
    $yaEsNuestra = Get-WmiObject Win32_Process -Filter "Name = 'rclone.exe'" |
                   Where-Object { $_.CommandLine -like "*${Remoto}:*" -and $_.CommandLine -like "*${Letra}:*" }
    if ($yaEsNuestra) {
        Aviso 'Ya estaba montada por una instalacion anterior; se volvera a montar.'
        foreach ($p in $yaEsNuestra) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
    } else {
        Salir-ConError "La letra ${Letra}: ya esta ocupada por otra unidad. Pide a quien te envio esto que te indique otra letra."
    }
} else {
    Bien 'Libre.'
}

# -- 2. WinFsp ----------------------------------------------------------------
Paso 'Comprobando WinFsp'

$pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
$winfspInstalado = (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\WinFsp') -or
                   (Test-Path 'HKLM:\SOFTWARE\WinFsp') -or
                   ($pf86 -and (Test-Path (Join-Path $pf86 'WinFsp'))) -or
                   (Test-Path (Join-Path $env:ProgramFiles 'WinFsp'))

if ($winfspInstalado) {
    Bien 'Ya estaba instalado.'
} else {
    # Primero se mira al lado del script: permite preparar un paquete sin
    # conexion para equipos donde la descarga por TLS 1.2 no funciona.
    $msi = Join-Path $DirScript $WinFspMsi
    if (Test-Path $msi) {
        Bien "Usando el instalador incluido ($WinFspMsi)."
    } else {
        Escribir '   No esta. Descargando...'
        if (-not (Habilitar-Tls12)) {
            Salir-ConError "Este equipo no puede negociar TLS 1.2 y los servidores de descarga ya no aceptan menos.`n       Pide el paquete con los instaladores incluidos, o instala .NET Framework 4.6 y los`n       parches de Windows 7, y vuelve a intentarlo."
        }
        $msi = Join-Path $env:TEMP $WinFspMsi
        try {
            Descargar $WinFspUrl $msi
        } catch {
            Salir-ConError "No se pudo descargar WinFsp ($($_.Exception.Message)).`n       Revisa la conexion, o pide el paquete con los instaladores incluidos."
        }
    }

    Escribir '   Instalando. Windows va a pedir permiso de administrador...'
    $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') -Verb RunAs -Wait -PassThru

    # 3010 = instalado correctamente pero pide reinicio.
    if ($p.ExitCode -eq 3010) {
        Aviso 'WinFsp quedo instalado pero Windows pide reiniciar.'
        Aviso 'Si al final la unidad no aparece, reinicia y vuelve a ejecutar este archivo.'
    } elseif ($p.ExitCode -ne 0) {
        Salir-ConError "El instalador de WinFsp termino con codigo $($p.ExitCode).`n       Si cancelaste el aviso de administrador, vuelve a intentarlo.`n       Si dice que el controlador no esta firmado, a este Windows 7 le faltan`n       las actualizaciones de firma SHA-2 (KB4474419)."
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
    # Windows 7 puede ser de 32 o de 64 bits y el binario es distinto.
    $es64 = ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64') -or ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64')
    $arq  = '386'
    if ($es64) { $arq = 'amd64' }
    $nombreZip = "rclone-$RcloneVersion-windows-$arq.zip"
    Escribir "   Equipo de $(if ($es64) { '64' } else { '32' }) bits: hace falta $nombreZip"

    New-Item -ItemType Directory -Force $DirRclone | Out-Null

    $zip = Join-Path $DirScript $nombreZip
    if (Test-Path $zip) {
        Bien 'Usando la copia incluida.'
    } else {
        Escribir '   Descargando...'
        if (-not (Habilitar-Tls12)) {
            Salir-ConError "Este equipo no puede negociar TLS 1.2 y los servidores de descarga ya no aceptan menos.`n       Pide el paquete con los instaladores incluidos."
        }
        $zip = Join-Path $env:TEMP $nombreZip
        try {
            Descargar "https://downloads.rclone.org/$RcloneVersion/$nombreZip" $zip
        } catch {
            Salir-ConError "No se pudo descargar rclone ($($_.Exception.Message)).`n       Revisa la conexion, o pide el paquete con los instaladores incluidos."
        }
    }

    $tmp = Join-Path $env:TEMP 'rclone-extraido'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    try {
        Descomprimir $zip $tmp
    } catch {
        Salir-ConError "No se pudo descomprimir rclone ($($_.Exception.Message))."
    }

    # El zip trae el ejecutable dentro de una carpeta con el numero de version.
    $exe = Get-ChildItem $tmp -Recurse -Filter 'rclone.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { Salir-ConError 'El archivo descargado de rclone no contenia el ejecutable.' }

    Copy-Item $exe.FullName (Join-Path $DirRclone 'rclone.exe') -Force
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

    $script:Rclone = Join-Path $DirRclone 'rclone.exe'
    Bien "Instalado en $script:Rclone"
}

# -- 4. Credenciales ----------------------------------------------------------
Paso 'Credenciales de acceso'

# Si el remoto ya esta configurado y responde, no se vuelve a pedir nada: la
# razon mas comun para re-ejecutar esto es reparar un montaje que desaparecio.
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
        Escribir '      completa y pulsa Enter.'
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
    # cualquier otro remoto ya configurado y no hay riesgo de dejar el archivo
    # con una codificacion que rclone no entienda.
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
# Separar esta prueba del montaje permite distinguir "la contrasena esta mal" de
# "el driver no arranco". Si falla aqui, no se registra ninguna tarea.
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
$usuario = "$env:USERDOMAIN\$env:USERNAME"

# En Windows 7 no existen los cmdlets *-ScheduledTask, asi que la tarea se
# define en XML y se registra con schtasks. Tres valores no son opcionales:
#   LogonType InteractiveToken -- la unidad pertenece a la sesion de Windows. Si
#     la tarea corriera fuera de la sesion, el proceso viviria pero la unidad no
#     apareceria nunca en el Explorador.
#   ExecutionTimeLimit PT0S -- sin limite. Por defecto Windows mata las tareas a
#     los 3 dias, y aqui el proceso ES la unidad.
#   Delay PT30S -- da tiempo a que la red este lista; en muchos equipos el inicio
#     de sesion ocurre antes de que haya conectividad.
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Monta el almacen de instrumentos como unidad de red al iniciar sesion.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$usuario</UserId>
      <Delay>PT30S</Delay>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$usuario</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$($script:Rclone)</Command>
      <Arguments>$argsMontaje</Arguments>
    </Exec>
  </Actions>
</Task>
"@

# schtasks exige el XML en Unicode (UTF-16). Escrito de otra forma responde
# "El archivo XML no es valido" sin mas explicacion.
$xmlPath = Join-Path $env:TEMP 'unidad-instrumentos.xml'
[System.IO.File]::WriteAllText($xmlPath, $xml, [System.Text.Encoding]::Unicode)

if (Existe-Tarea) { Borrar-Tarea | Out-Null }

$salida = & schtasks.exe /Create /TN $Tarea /XML $xmlPath /F 2>&1
$codigo = $LASTEXITCODE
Remove-Item $xmlPath -ErrorAction SilentlyContinue

if ($codigo -ne 0) {
    Salir-ConError "No se pudo crear la tarea programada.`n`n$(($salida | Out-String).Trim())"
}
Bien 'Se montara sola en cada inicio de sesion.'

# -- 8. Montar ahora ----------------------------------------------------------
Paso 'Montando la unidad'
$null = & schtasks.exe /Run /TN $Tarea 2>&1

$montada = $false
foreach ($i in 1..20) {
    Start-Sleep -Seconds 1
    if (Test-Path "${Letra}:\") { $montada = $true; break }
}

Write-Host ''
if ($montada) {
    Write-Host "  Listo. La unidad ${Letra}: ya esta disponible en Equipo." -ForegroundColor Green
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
    Escribir '  En Windows 7 casi siempre es que WinFsp necesita un reinicio para'
    Escribir '  activarse. Reinicia el equipo: la unidad deberia aparecer sola al'
    Escribir '  volver a entrar.'
    Escribir '  Si no aparece, el detalle del error esta en:'
    Escribir "    $LogMontaje"
}

Write-Host ''
Read-Host 'Pulsa Enter para cerrar'
