# LNURL y Lightning Address

## Que es LNURL

[LNURL](https://github.com/lnurl/luds) es un protocolo UX sobre Lightning Network que reemplaza los invoices de un solo uso por interacciones reutilizables: pagar, recibir, autenticarse, todo desde un QR estatico o una URL fija.

Sub-protocolos principales:

| Protocolo | Que hace |
|-----------|----------|
| **lnurl-pay** (LUD-06) | El remitente escanea un QR/link y el servidor genera un invoice BOLT11 en el momento |
| **lnurl-withdraw** | El receptor escanea un QR y "retira" sats de un servicio |
| **lnurl-auth** | Login sin password — firma con la llave del nodo |
| **lightning address** (LUD-16) | Direccion legible tipo `usuario@dominio.com` que internamente resuelve a lnurl-pay |

## Que es una Lightning Address

Una Lightning Address funciona igual que un email pero para recibir Bitcoin. En vez de compartir un invoice de 200 caracteres, compartes algo como:

```
satoshi@tudominio.com
```

Cuando alguien paga a esa direccion, su wallet hace internamente:

1. Toma `satoshi@tudominio.com` y hace un GET a `https://tudominio.com/.well-known/lnurlp/satoshi`
2. Tu servidor responde con un JSON (callback URL, montos min/max, metadata)
3. El wallet llama al callback con el monto elegido
4. Tu servidor genera un invoice BOLT11 desde tu nodo LND y lo devuelve
5. El wallet paga el invoice

```
Wallet del pagador                    Tu servidor + LND
       |                                      |
       |  GET /.well-known/lnurlp/satoshi      |
       |  -----------------------------------> |
       |                                      |
       |  { callback, minSendable, ... }       |
       |  <----------------------------------- |
       |                                      |
       |  GET callback?amount=50000            |
       |  -----------------------------------> |
       |                                      |
       |  { pr: "lnbc500n1..." }               |
       |  <----------------------------------- |
       |                                      |
       |  Paga el invoice BOLT11               |
       |  -----------------------------------> |
```

## Que necesitas

### 1. Un dominio

Necesitas comprar un dominio (puede ser en [Namecheap](https://www.namecheap.com/), Porkbun, Cloudflare, etc.). El dominio es lo que va despues del `@` en tu Lightning Address.

**Lo unico que haces con el dominio es apuntar el DNS a tu servidor** — no hay configuracion compleja, solo un registro A:

```
Tipo: A
Host: @    (o el subdominio que quieras)
Valor: IP_DE_TU_VPS
TTL: Automatic
```

Si quieres usar un subdominio (ej. `ln.tudominio.com`):

```
Tipo: A
Host: ln
Valor: IP_DE_TU_VPS
TTL: Automatic
```

### 2. HTTPS (certificado SSL)

LNURL requiere HTTPS obligatoriamente. La opcion mas simple es [Caddy](https://caddyserver.com/) como reverse proxy — obtiene certificados de Let's Encrypt automaticamente:

```
tudominio.com {
    reverse_proxy 127.0.0.1:8080
}
```

Alternativamente puedes usar nginx + certbot.

### 3. Un servidor LNURL

El servidor recibe las peticiones HTTP en `/.well-known/lnurlp/<usuario>` y genera invoices desde tu nodo LND. La libreria [lnurl-rs](https://github.com/benthecarman/lnurl-rs) implementa el protocolo completo en Rust.

## Respuesta del endpoint

El endpoint `GET https://tudominio.com/.well-known/lnurlp/usuario` debe devolver:

```json
{
  "status": "OK",
  "tag": "payRequest",
  "callback": "https://tudominio.com/lnurl/pay/usuario",
  "minSendable": 1000,
  "maxSendable": 100000000,
  "metadata": "[[\"text/plain\",\"Pago a usuario\"]]",
  "commentAllowed": 140
}
```

- `minSendable` / `maxSendable` en **millisatoshis** (1000 msat = 1 sat)
- `callback` es la URL que el wallet llama con `?amount=<msat>` para obtener el invoice BOLT11
- `metadata` es un JSON-string con al menos `text/plain`

## Resumen del flujo

```
[Comprar dominio] --> [DNS: A record apuntando a tu VPS]
                            |
                            v
                  [Reverse proxy con HTTPS]
                     (Caddy o nginx)
                            |
                            v
                  [Servidor LNURL en tu VPS]
                   /.well-known/lnurlp/*
                            |
                            v
                     [Tu nodo LND]
                  (genera invoices BOLT11)
```

La parte pesada (nodo LND, canales, liquidez) ya la tienes con este setup. El servidor LNURL es solo el puente HTTP que convierte peticiones web en invoices de tu nodo.
