# Luma MVP

Luma es un organizador personal nativo para macOS que transforma pendientes sueltos en un plan diario de tres prioridades. El MVP guarda todo con SwiftData, prioriza localmente y puede interpretar tareas con DeepSeek-R1 1.5B ejecutado dentro de la aplicación mediante MLX Swift.

## Incluye

- Dashboard con tres prioridades y explicación.
- Inbox con captura en lenguaje natural.
- Captura rápida desde la barra de menú.
- Captura global con `⌘ ⇧ Espacio`, incluso cuando Luma está en segundo plano.
- Reacomodo según energía disponible.
- Agenda diaria que encuentra horarios reales y evita compromisos del Calendario.
- Avisos tranquilos con acciones para empezar, posponer o reacomodar.
- Vista semanal y radar de acumulación.
- Chat contextual “Preguntale a Luma” para consultar por dónde empezar, qué posponer o cómo reacomodar el día.
- Balance por áreas de vida.
- Focus Room con temporizador.
- Disponibilidad semanal configurable y bienvenida guiada.
- Respaldo local exportable e importable.
- Búsqueda manual de actualizaciones de la beta.
- DeepSeek local, opcional y descargable desde Ajustes.
- Carga del modelo por solicitud y liberación inmediata de memoria.
- Intérprete y priorizador esenciales que funcionan sin descargar IA.

## Abrir el proyecto

1. Abrí `Luma.xcodeproj` con Xcode 26 o posterior.
2. Esperá a que Xcode resuelva los paquetes de MLX y Hugging Face.
3. Seleccioná el esquema `Luma` y ejecutá en `My Mac`.
4. Para activar DeepSeek, abrí Ajustes y elegí **Descargar IA privada**.

El modelo rápido ocupa aproximadamente 1,1 GB. El modelo avanzado, recomendado para respuestas más precisas en el chat, se descarga por separado y ocupa aproximadamente 4,3 GB. Después pueden funcionar offline. El proyecto requiere macOS 14 o posterior y está optimizado para Apple Silicon. Luma funciona sin descargar modelos: DeepSeek mejora la interpretación y la conversación, pero no bloquea la agenda ni la priorización esencial.

Los permisos de avisos y Calendario son opcionales y revocables desde macOS. Luma no crea una cuenta, no usa API keys y no envía métricas de uso.

## Arquitectura de memoria

Ningún modelo permanece residente. Cada solicitud crea un contenedor MLX, genera una respuesta limitada, libera el contenedor y limpia la caché. Para estudiar un PDF, Luma mantiene una sola carga del modelo de 7B durante el análisis por secciones y la libera apenas termina. Las tareas, fechas, materiales y prioridades permanecen en SwiftData.

## Regenerar el proyecto

El archivo `project.yml` es la fuente del proyecto. Si se agregan archivos o cambia la configuración, ejecutá `xcodegen generate` dentro de esta carpeta.
