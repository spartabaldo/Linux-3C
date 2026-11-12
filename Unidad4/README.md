# Unidad 4 · DNS, dominio, página y SSH

`dns.sh` deja una máquina Kali funcionando como servidor de la red local. En una sola corrida:

1. Fija la IP actual de la máquina para que no cambie.
2. Instala y configura **BIND9** con un dominio propio (por ejemplo `spartabaldo.linux`), con su zona directa y la inversa.
3. Instala **nginx** y publica una página con los comandos vistos en clase (131, agrupados por unidad y con buscador).
4. Deja junto a la página un `comandos.txt` con la misma lista en texto plano.
5. Enciende **SSH** para revisar la carpeta del sitio desde otro equipo.
6. Al final comprueba que todo responde: DNS por UDP y TCP, consulta inversa, HTTP y SSH.

Antes de cambiar algo guarda un respaldo, y si falla a la mitad regresa todo como estaba.

## Ver la página en línea

Una copia de la página está publicada con GitHub Pages:
**https://spartabaldo.github.io/Linux-3C/Unidad4/pagina/**

Es la misma página que sirve nginx en el servidor, generada por `dns.sh`. La copia en línea se puede abrir desde cualquier lugar; el servidor real (DNS, nginx y SSH) solo responde dentro de la red de la escuela.

## Requisitos

- Kali Linux (o Debian/Ubuntu) con systemd y NetworkManager.
- Internet para instalar los paquetes con `apt`.
- Si es una máquina virtual, la red en **Adaptador puente** para que los demás equipos la vean.

## Cómo correrlo

```bash
sudo bash dns.sh
```

Pide el nombre del dominio; debe tener al menos dos partes, como `escuela.linux`.

| Opción | Qué hace |
|---|---|
| `sudo bash dns.sh` | Instala todo. Si el dominio ya existe, solo regenera la página y revisa SSH. |
| `sudo bash dns.sh --publicar` | Regenera y publica la página (por ejemplo, después de agregar comandos). |
| `sudo bash dns.sh --diagnostico` | Revisa red, DNS, web y SSH sin cambiar nada. |
| `sudo bash dns.sh --restaurar` | Regresa al respaldo anterior. |
| `bash dns.sh --ayuda` | Muestra la ayuda completa. |

Para agregar comandos a la página se edita la lista de la función `cargar_comandos` y se corre `--publicar`.

## Cómo verificarlo

En el servidor:

```bash
dig @10.10.24.199 spartabaldo.linux +short      # debe responder 10.10.24.199
dig @10.10.24.199 -x 10.10.24.199 +short        # debe responder spartabaldo.linux.
curl -s http://spartabaldo.linux | grep -o '<h1>.*</h1>'
```

Desde otro equipo de la misma red (Linux, macOS o PowerShell en Windows):

```bash
nslookup spartabaldo.linux 10.10.24.199
ssh spartabaldo@10.10.24.199 "ls -lah /var/www/spartabaldo.linux"
ssh spartabaldo@10.10.24.199 "cat /var/www/spartabaldo.linux/comandos.txt"
```

Para abrir la página desde otro equipo, ese equipo tiene que usar `10.10.24.199` como DNS; después basta con entrar a `http://spartabaldo.linux`.

## Capturas

| Captura | Qué muestra |
|---|---|
| `Screenshot 2026-11-11 184207.png` | El script corriendo: dominio, página generada, nginx validado y SSH encendido. |
| `Screenshot 2026-11-11 184221.png` | `named` y `nginx` activos, y los puertos 53 y 80 escuchando. |
| `Screenshot 2026-11-11 184235.png` | La carpeta del sitio con `index.html` y `comandos.txt`, y la página publicada con los 131 comandos. |
| `Screenshot 2026-11-11 184737.png` | La página abierta en `http://spartabaldo.linux`. |

## Nota sobre la red

La IP `10.10.24.199` pertenece a la red de la escuela. Fuera de ella el servidor sigue funcionando dentro de la propia máquina, pero los demás equipos no lo alcanzan.
