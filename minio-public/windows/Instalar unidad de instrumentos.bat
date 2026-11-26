@echo off
rem ============================================================================
rem  Doble clic aqui para instalar la unidad del almacen de instrumentos.
rem
rem  Este archivo solo lanza el script de PowerShell que esta a su lado. Existe
rem  porque un .ps1 no se ejecuta con doble clic: Windows lo abre en el bloc de
rem  notas. El -ExecutionPolicy Bypass afecta unicamente a esta ejecucion; no
rem  cambia ninguna configuracion del equipo.
rem ============================================================================

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar-UnidadInstrumentos.ps1" %*

rem Si PowerShell no llego siquiera a arrancar, el script no mostro nada y la
rem ventana se cerraria sin explicacion.
if errorlevel 1 (
    echo.
    echo Si esta ventana se cerro sin hacer nada, avisa a quien te envio este archivo.
    pause
)
