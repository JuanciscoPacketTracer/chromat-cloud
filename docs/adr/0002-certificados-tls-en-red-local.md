# ADR-0002: Certificados TLS en la red local

- **Estado:** Aceptada
- **Fecha:** 2026-11-07
- **Alcance:** Nginx y clientes autorizados de CHROMAT Server

## Contexto

CHROMAT necesita HTTPS entre los clientes de la red local y Nginx. La red no
dispone necesariamente de un dominio público resoluble por una autoridad
certificadora, y el despliegue inicial debe evitar una infraestructura ACME
adicional.

## Decisión

Se usará una CA interna propia, sin certificados autofirmados individuales y
sin Let's Encrypt:

- La CA raíz será ECDSA P-256, con vigencia de 10 años y sin CA intermedia.
- El certificado de servidor tendrá vigencia de 1 año e incluirá los SAN
  `chromat.lan` y la IP fija de la VM.
- La clave de la CA permanecerá fuera del servidor. La VM solo recibirá
  `server.key` con permisos 600 y `server.crt`, montados en Nginx como
  solo lectura y fuera de Git.
- Solo `ca.crt` se distribuirá a clientes autorizados.
- La Raspberry Pi validará TLS contra `ca.crt`; nunca se desactivará la
  verificación. Los navegadores importarán la CA como autoridad de confianza y
  la aplicación móvil futura incluirá `ca.crt` en su configuración de red.
- `chromat.lan` se resolverá mediante `/etc/hosts` en cada cliente o mediante
  el DNS del router, si está disponible.
- La renovación será manual: se emitirá un certificado nuevo antes del
  vencimiento y se recargará Nginx con `nginx -s reload`.
- Un temporizador diario ejecutará `openssl x509 -checkend` y alertará cuando
  falten menos de 30 días.

Se acepta el riesgo de que la renovación anual dependa de atender la alerta.
No se adopta una CA con ACME, como `step-ca`, por la complejidad adicional que
introduciría en esta etapa.

## Consecuencias

- Cada cliente autorizado debe recibir e instalar `ca.crt`.
- La pérdida o exposición de la clave de la CA requiere reemplazar la CA y
  redistribuir la confianza a todos los clientes.
- La renovación debe completarse antes de la expiración anual para evitar
  interrupciones.

## Fuera de alcance

La implementación de los scripts de emisión, la distribución automatizada y el
temporizador de revisión se agenda como trabajo de implementación posterior.
