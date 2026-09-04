@echo off
rem ============================================================================
rem  WINDOWS 7 -- doble clic aqui para quitar la unidad del almacen.
rem
rem  Elimina la tarea programada, detiene el montaje y borra la credencial
rem  guardada en este equipo. NO borra nada del servidor.
rem
rem  Al final pregunta si quieres desinstalar tambien WinFsp y rclone. Por
rem  defecto no los toca: otras herramientas pueden depender de ellos.
rem ============================================================================

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar-UnidadInstrumentos-Win7.ps1" -Desinstalar

if errorlevel 1 (
    echo.
    echo Si esta ventana se cerro sin hacer nada, avisa a quien te envio este archivo.
    pause
)
