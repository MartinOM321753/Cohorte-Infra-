@echo off
rem ============================================================================
rem  Doble clic aqui si la unidad S: desaparecio del Explorador.
rem
rem  Normalmente no hace falta: Windows la vuelve a montar solo cada pocos
rem  minutos. Esto es para no esperar.
rem
rem  Si tampoco aparece asi, lo mas probable es que el servidor no sea
rem  alcanzable desde esta red. Avisa a quien te envio esto.
rem ============================================================================

echo Volviendo a montar la unidad...
schtasks /Run /TN "Unidad almacen de instrumentos"

if errorlevel 1 (
    echo.
    echo No se encontro la tarea. Vuelve a ejecutar el instalador.
) else (
    echo.
    echo Listo. Espera unos segundos y abre el Explorador.
)
echo.
pause
