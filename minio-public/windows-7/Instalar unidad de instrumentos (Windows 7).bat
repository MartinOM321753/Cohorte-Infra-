@echo off
rem ============================================================================
rem  WINDOWS 7 -- doble clic aqui para instalar la unidad del almacen.
rem
rem  Para Windows 8, 10 y 11 usa la carpeta "windows", no esta: alli se instalan
rem  las versiones actuales de las herramientas. Windows 7 necesita versiones
rem  concretas y otro mecanismo para la tarea programada.
rem ============================================================================

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar-UnidadInstrumentos-Win7.ps1" %*

if errorlevel 1 (
    echo.
    echo Si esta ventana se cerro sin hacer nada, avisa a quien te envio este archivo.
    pause
)
