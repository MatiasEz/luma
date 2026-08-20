# Supabase de Luma

La base remota funciona como respaldo sincronizado. SwiftData sigue siendo la caché offline y la fuente inmediata de la interfaz.

La migración crea tablas para perfiles, pendientes, sesiones, chat y reacomodos. Todas tienen Row Level Security: una sesión autenticada solo puede leer y modificar filas cuyo `user_id` coincide con `auth.uid()`.

El MVP usa una identidad anónima persistida por Supabase Auth para no obligar a crear una cuenta. Antes de publicar, hay que activar **Anonymous Sign-Ins** y protección antiabuso en el panel de Supabase. Una fase posterior puede vincular esa identidad con Apple o correo para recuperar los datos en otra Mac.
