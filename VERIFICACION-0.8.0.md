# Verificación de Luma 0.8.0

Revisión del 11 de septiembre de 2026. La app continúa siendo exclusiva de macOS, con captura manual e IA local opcional.

**Suite completa: 106 pruebas correctas, 0 fallos.** Ejecutada el 11 de septiembre de 2026 a las 20:53 en macOS arm64.

## Comportamientos comprobados

- Presupuesto real: 120 minutos iniciales, 45 trabajados y 30 añadidos dejan 105. La pausa se incluye en el tiempo disponible y las clases no se descuentan dos veces.
- Una prioridad urgente puede tener varias sesiones distintas. Registrar un avance parcial conserva el bloque restante y no vuelve a descontar el mismo evento.
- El conjunto comparte capacidad diaria. La prueba de 720 minutos de trabajo frente a 420 disponibles antes de las entregas informa un faltante de 300.
- Las entregas de hoy siguen siendo accionables; los pasos previos heredan urgencia. Cambiar solo el peso académico cambia la prioridad en el caso controlado.
- Una fecha de trabajo elegida para otro día no se adelanta silenciosamente. El plan conserva las prioridades ante altas y cambios de nombre. Los compromisos externos siguen respetándose al regresar a Hoy.
- El estudio respeta el comienzo elegido, incluso a más de dos semanas de distancia. Editar un examen conserva las identidades y los avances existentes; el temario es opcional.
- Focus conserva tiempo entre pantallas y al recuperarse. Su reloj cuenta también intervalos fraccionarios; una pausa no se usa para aprender hábitos de trabajo.
- El respaldo completo se restaura en una base vacía. Los archivos con identidades duplicadas se rechazan antes de insertar registros. Las preferencias portátiles excluyen credenciales.
- Una base sintética con el modelo de tarea de 0.7.3 abre con el esquema nuevo y conserva identidad, ponderación y minutos trabajados.
- Las notificaciones respetan un contador diario persistente que incluye los avisos aplazados.

## Servidor

Se aplicaron las dos migraciones aditivas incluidas en el repositorio: metadatos de preparación, procedencia de sesiones y registros durables de borrado. Una prueba transaccional con dos identidades temporales comprobó aislamiento entre usuarios y bloqueo de reinserción de una tarea borrada. Los datos de prueba se revirtieron. Las políticas de acceso por usuario permanecen activas.

## Revisión visual

Recorrido en una instancia Debug con base y preferencias separadas: Hoy, barra lateral, Calendario, captura sin fecha, Inbox agrupado, carga de examen y sesión parcial de Focus. Se repitió el recorrido después de compilar 0.8.0: formulario compacto y ampliado, semana, mes y alta de examen con materia nueva sin temario. Se comprobó que el pendiente guardado aparece en Inbox y que navegar fuera de Focus conserva la sesión. Las pruebas no modificaron los datos personales de la instancia habitual.

## Alcance de estas comprobaciones

La semana futura es una propuesta basada en la disponibilidad habitual; se calcula hasta 60 días y debe ajustarse cuando cambia el tiempo disponible. Las alertas buscan dejar el trabajo listo antes del día de entrega; si vence hoy, el tiempo de hoy sigue contando. Las horas quedan sin asignar cuando no se conocen ventanas concretas.

La recuperación de cuenta entre dispositivos sigue siendo distinta de la recuperación mediante respaldo completo. No se ensayaron todas las combinaciones de desconexión y concurrencia entre dos Macs. Tampoco se midió en esta entrega la calidad de conversaciones abiertas con el modelo local ni se añadió música, rachas o nuevas integraciones.

El instalador es una compilación de desarrollo con firma local, para Apple Silicon y macOS 14 o posterior. La distribución sin advertencias de macOS requiere firma Developer ID y notarización.

## Entrega verificada

- Código compilado: `cbc913d586c48bead0f532b0eae4ae6e84077546`.
- Compilación Release correcta: Luma 0.8.0, build 14, arquitectura arm64. Arranque comprobado durante 11 segundos con base en memoria; se cerró esa instancia de comprobación.
- Firma local validada con comprobación estricta del paquete completo.
- `Luma-0.8.0-macOS.dmg`: 31.280.226 bytes. Imagen verificada, montada en modo de solo lectura y desmontada correctamente; contiene la app 0.8.0 (14), enlace a Aplicaciones y notas.
- SHA-256 del instalador: `3c4b73533122f01b6f0b18a26c6a1ed51a8810f5060c458b7ee7377afb5aa199`.
