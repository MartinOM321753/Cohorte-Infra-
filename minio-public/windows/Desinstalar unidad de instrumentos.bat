@echo off
rem ============================================================================
rem  Doble clic aqui para quitar la unidad del almacen de instrumentos.
rem
rem  Elimina la tarea programada y detiene el montaje: la letra deja de aparecer
rem  en el Explorador y no vuelve a montarse al iniciar sesion.
rem
rem  NO borra nada del servidor. Los archivos siguen ahi y se siguen viendo por
rem  su direccion publica; esto solo quita el acceso desde este equipo.
rem
rem  WinFsp y rclone se dejan instalados, por si hay otras unidades que dependan
rem  de ellos. Para quitarlos: Configuracion > Aplicaciones.
rem ============================================================================

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar-UnidadInstrumentos.ps1" -Desinstalar

if errorlevel 1 (
    echo.
    echo Si esta ventana se cerro sin hacer nada, avisa a quien te envio este archivo.
    pause
)
