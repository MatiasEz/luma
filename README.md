# Luma para macOS

Luma convierte pendientes en un plan manejable. Calendario muestra las entregas y los avances de la semana; Hoy propone hasta tres prioridades y explica por qué conviene empezar por ellas. La captura principal es manual y rápida. El asistente con IA local es opcional.

## Qué incluye

- Un plan común de bloques para Hoy y Calendario, con fecha de entrega separada del trabajo programado, horarios opcionales y aviso si el tiempo no alcanza.
- Reacomodos según tiempo y energía. Agregar un pendiente conserva el plan confirmado; podés cambiar una prioridad concreta. El presupuesto descuenta el trabajo real y permite deshacerlo.
- Exámenes con materia creable, inicio de preparación ajustable, temario opcional, temas en orden y repasos. Editarlos conserva los avances existentes.
- Inbox agrupado, captura rápida desde la barra de menú y atajo `⌘ ⇧ Espacio`.
- Focus con sesiones recuperables, registro del tiempo y distinción entre terminar una sesión y terminar la tarea.
- Preferencias explícitas, balance basado en registros y aprendizaje que separa las pausas del trabajo.
- Respaldo JSON versión 2 con tareas, temarios, exámenes, clases, rutinas, historial y preferencias. Antes de restaurarlo se muestra una vista previa; los respaldos anteriores siguen siendo legibles.
- Sincronización con Supabase, registros de borrado durables y control de acceso por usuario. La app utiliza una identidad anónima de dispositivo; el respaldo portátil permite recuperar los datos sin exportar credenciales.
- Calendario de macOS y notificaciones opcionales, con un límite diario de tres avisos.

## Desarrollo

Requiere macOS 14 o posterior y Apple Silicon. Abrí `Luma.xcodeproj` con Xcode 26 o posterior y ejecutá el esquema `Luma` en My Mac. `project.yml` es la fuente del proyecto; después de agregar archivos, regeneralo con `xcodegen generate`.

Los modelos locales se descargan desde Ajustes. La planificación, la captura manual y los datos funcionan sin descargar IA. Cada solicitud de IA carga su modelo y lo libera al terminar; el análisis de un PDF conserva una misma carga durante sus secciones.

Para una revisión visual aislada, compilá Debug y ejecutá la app con `--luma-preview`. Ese modo usa datos de muestra, una base separada y preferencias propias, con la nube desactivada. No existe en Release. Los tests alojados tampoco abren la base personal.

Las migraciones aditivas de esta versión están en `supabase/migrations`. Las pruebas cubren el cálculo de tiempo, la estabilidad del plan, dependencias, preparación académica, recuperación, respaldo y apertura de una base de la versión anterior.
