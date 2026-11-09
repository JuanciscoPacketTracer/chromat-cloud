# ADR-0006: Autenticación, autorización y exposición de la API

- **Estado:** Aceptada
- **Fecha:** 2026-11-07
- **Alcance:** Nginx, API, operadores y Fuentes de monitoreo

## Contexto

CHROMAT recibe Eventos de monitoreo desde varias fuentes y expone un panel
operativo. La autenticación debe aislar fuentes entre sí, proteger las
operaciones administrativas y mantener los servicios internos fuera de la
superficie pública.

## Decisión

### Fuentes de monitoreo

- Cada fuente tiene una API key de al menos 32 bytes aleatorios, con un
  identificador público como prefijo.
- Se envía como `Authorization: Bearer` únicamente sobre HTTPS. El servidor
  guarda solo SHA-256, compara en tiempo constante y deriva `source_id` de la
  key validada.
- La fuente puede crear Eventos de monitoreo y consultar solo los propios.
  No puede reprocesar, modificar Datos crudos ni modificar resultados.
- La rotación revoca la key anterior por defecto, pero el operador puede
  activar explícitamente una ventana de convivencia con vencimiento.
- Ante `401` o `403`, la fuente conserva los eventos y los reintenta después
  de corregir la credencial.

### Operadores

- Existe un único rol de operador. El primero se crea mediante un comando
  administrativo de uso único, sin contraseña por defecto.
- La contraseña se almacena con Argon2id y el panel usa una cookie
  `Secure`, `HttpOnly`, `SameSite=Strict`, con vencimiento por inactividad y
  vencimiento absoluto.
- El inicio de sesión tiene límite de intentos. Las acciones sensibles
  requieren token CSRF además de `SameSite=Strict`.
- Solo operadores pueden descargar imágenes crudas. También pueden consultar
  eventos autorizados, solicitar reprocesamientos y operar retención/alertas.

### Servicios, transporte y auditoría

- Nginx escucha solo HTTPS en el puerto 443; no se publica HTTP en el puerto
  80. API, worker, inferencia y MariaDB no tienen puertos públicos.
- Los servicios tienen credenciales separadas por entorno, montadas como
  secretos de archivo fuera de Git y nunca como variables de entorno. No hay
  valores por defecto productivos.
- El panel y la API comparten origen por defecto. No hay CORS abierto; los
  orígenes adicionales requieren una lista explícita.
- Los rate limits por fuente permiten ráfagas para reenviar acumulados tras
  una caída de conectividad. Los límites de autenticación fallida se aplican
  por IP e identificador público de key.
- Se auditan autenticaciones fallidas, accesos cruzados, emisión, rotación,
  revocación y reprocesamientos. La auditoría es append-only, se conserva 365
  días y nunca registra keys ni contraseñas, solo identificadores públicos.

## Consecuencias

- Una key comprometida puede revocarse por fuente sin afectar a las demás.
- La ventana de convivencia de rotación debe activarse y cerrarse
  explícitamente para evitar credenciales antiguas activas.
- La aplicación móvil futura requerirá una decisión de autenticación propia;
  no reutilizará la sesión del panel ni las keys de fuentes.

## Fuera de alcance

La autenticación específica de la aplicación móvil queda fuera de esta etapa.
