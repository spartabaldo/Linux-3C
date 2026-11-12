#!/usr/bin/env bash
# dns.sh — Kali Linux: IP actual -> estática + BIND9 + Nginx + página con los
# comandos vistos en clase + SSH para revisar la carpeta del sitio.
# Ejecutar EN EL KALI QUE SERA EL SERVIDOR: sudo bash dns.sh
# IP esperada del servidor: 10.10.24.158 (variable EXPECTED_IP, más abajo).
# Solicita el dominio en la terminal y lo guarda para las siguientes acciones.
# No instala DHCP ni cambia el router. Los clientes deben usar este DNS.
# IMPORTANTE: fijar una IP en Kali NO la reserva en el servidor DHCP.
# Sin reserva/exclusión en DHCP no se puede garantizar que no haya colisiones.
# Es preferible ejecutar desde la consola de la máquina/VM: la red se reactiva.
# VM accesible desde equipos físicos: adaptador puente o una red con rutas a ella.
# Si dnsmasq.service ocupa el DNS de la LAN y solo presta DNS, se respalda
# su estado y se detiene/deshabilita para sustituirlo por BIND9. No se eliminan
# paquetes ni se detienen instancias DHCP/TFTP, de NetworkManager o libvirt.
# Documentación utilizada:
# https://netplan.readthedocs.io/en/stable/netplan-set/
# https://networkmanager.dev/docs/api/latest/nm-settings-nmcli.html
# https://bind9.readthedocs.io/en/stable/reference.html
# https://nginx.org/en/docs/http/ngx_http_core_module.html
# https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html
set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 022

DEFAULT_DOMAIN='midominio.linux'
# IP que debe tener Kali en la LAN. Si la detectada es otra, se avisa y se pregunta.
# Para cambiarla sin editar: sudo bash dns.sh --ip 10.10.x.x
EXPECTED_IP='10.10.24.158'
DOMAIN=''
OLD_DOMAIN=''
OLD_SITE_DIR=''
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
SITE_DIR=''
WEB_ROOT=''
STATE_DIR='/var/lib/dns-midominio'
BACKUP_BASE='/var/backups/dns-midominio'
STATE_FILE="$STATE_DIR/estado.json"
MODE='instalar'
IFACE=''
UPSTREAM_INPUT=''
BACKUP=''
ROLLBACK_UNIT=''
TRANSACTION=0

info() { printf '\n[DNS] %s\n' "$*"; }
warn() { printf '\n[AVISO] %s\n' "$*" >&2; }
die() {
    printf '\n[ERROR] %s\n' "$*" >&2
    if ((TRANSACTION)); then on_error 1; else exit 1; fi
}
need_root() { [[ $EUID -eq 0 ]] || die "Ejecuta: sudo bash \"$SCRIPT_PATH\""; }

usage() {
    cat <<'HELP'
USO
  sudo bash dns.sh                         Instalar y configurar.
  sudo bash dns.sh --interfaz eth0          Elegir la tarjeta de la LAN.
  sudo bash dns.sh --ip 10.10.24.158        IP esperada del servidor (por defecto 10.10.24.158).
  sudo bash dns.sh --dns-upstream 1.1.1.1,8.8.8.8
  sudo bash dns.sh --diagnostico            Revisar red, DNS y HTTP.
  sudo bash dns.sh --publicar               Regenerar y publicar la página de comandos.
  sudo bash dns.sh --restaurar              Volver al respaldo previo.
  bash dns.sh --ayuda

Al instalar se pregunta el dominio (ejemplo: escuela.linux). Intro conserva
el sugerido. Si ese dominio ya estaba configurado, solo se regenera la página,
se publica y se enciende SSH (no se toca la red ni el DNS). Si ya hay una instalación, escribir otro dominio la actualiza,
con respaldo de la configuración anterior. Los modos --publicar,
--diagnostico y --restaurar utilizan el dominio guardado sin volver a pedirlo.

Requisitos: Kali Linux (o Debian/Ubuntu) con systemd y conexión para instalar paquetes por apt.
Compatible con una conexión Ethernet/Wi-Fi gestionada por NetworkManager
(lo normal en Kali) o una interfaz Ethernet/Wi-Fi de Netplan. Rechaza topologías avanzadas.

Toma la IPv4 actual (normalmente obtenida por DHCP), máscara y gateway;
desactiva el DHCP IPv4 SOLO EN ESA INTERFAZ DEL SERVIDOR y los hace fijos.
No configura un servidor DHCP ni cambia el DHCP del router.
La IPv4 fija NO constituye una reserva DHCP: podrían aparecer duplicados.

Los demás equipos siguen con IP por DHCP, pero deben usar como único DNS
la IPv4 del servidor. Abre http://TU-DOMINIO (HTTP, puerto 80).
Una VM necesita una interfaz alcanzable desde la LAN, normalmente puente.
Si dnsmasq.service ocupa 53 en la LAN y solo proporciona DNS, el script
lo sustituye por BIND9 y conserva su estado anterior en el respaldo.
Las instancias de DHCP/TFTP o de redes virtuales no se detienen.
HELP
}

while (($#)); do
    case "$1" in
        --ayuda|-h|--help) usage; exit 0 ;;
        --diagnostico|--publicar|--restaurar)
            [[ $MODE == instalar ]] || die 'Usa una sola acción por ejecución.'
            MODE="${1#--}"; shift ;;
        --interfaz)
            (($# >= 2)) || die 'Falta el nombre después de --interfaz.'
            IFACE="$2"; shift 2 ;;
        --ip)
            (($# >= 2)) || die 'Falta la IPv4 después de --ip.'
            EXPECTED_IP="$2"; shift 2 ;;
        --dns-upstream)
            (($# >= 2)) || die 'Faltan las IPv4 después de --dns-upstream.'
            UPSTREAM_INPUT="$2"; shift 2 ;;
        *) die "Opción desconocida: $1. Consulta --ayuda." ;;
    esac
done

json_get() {
    python3 - "$1" "$2" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))[sys.argv[2]]
print(value if not isinstance(value, (dict, list)) else json.dumps(value))
PY
}

validate_domain() {
    python3 - "$1" <<'PY'
import ipaddress, re, sys
name = sys.argv[1].strip().lower()
if name.endswith('.'):
    name = name[:-1]
try:
    name = name.encode('idna').decode('ascii')
except UnicodeError:
    sys.exit('El dominio contiene caracteres no válidos.')
try:
    ipaddress.ip_address(name)
except ValueError:
    pass
else:
    sys.exit('Escribe un dominio, no una dirección IP.')
labels = name.split('.')
if (len(name) > 253 or len(labels) < 2 or
    any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', x) for x in labels) or
    not re.search(r'[a-z]', labels[-1])):
    sys.exit('Usa un nombre como escuela.linux: al menos dos partes, letras, números y guiones; sin http://, puertos ni rutas.')
# BIND también generará www.<dominio>, dns.<dominio> y admin.<dominio>.
if len('admin.' + name) > 253:
    sys.exit('El dominio es demasiado largo para generar sus nombres auxiliares.')
print(name)
PY
}

set_domain_paths() {
    DOMAIN="$1"
    SITE_DIR="$SCRIPT_DIR/sitio-$DOMAIN"
    WEB_ROOT="/var/www/$DOMAIN"
}

load_installed_config() {
    [[ -f $STATE_FILE ]] || die 'Aún no hay una instalación registrada. Ejecuta sudo bash dns.sh.'
    local saved_domain
    # Los estados creados por la primera versión usaban midominio.linux.
    saved_domain="$(python3 - "$STATE_FILE" "$DEFAULT_DOMAIN" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get('domain', sys.argv[2]))
PY
)"
    saved_domain="$(validate_domain "$saved_domain")"
    set_domain_paths "$saved_domain"
    SITE_DIR="$(json_get "$STATE_FILE" site_dir)"
}

ask_domain() {
    local suggested="${DOMAIN:-$DEFAULT_DOMAIN}" entered normalized
    while true; do
        printf '\nNombre del dominio local [%s]: ' "$suggested" >&2
        IFS= read -r entered || die 'No se recibió el dominio. Ejecuta el script desde una terminal o proporciona una línea por la entrada estándar.'
        [[ -n $entered ]] || entered="$suggested"
        if normalized="$(validate_domain "$entered")"; then
            set_domain_paths "$normalized"
            info "Dominio seleccionado: $DOMAIN"
            return
        fi
        warn 'Nombre no válido. Inténtalo de nuevo.'
    done
}

cancel_timer() {
    if [[ -n $ROLLBACK_UNIT ]]; then
        systemctl stop "$ROLLBACK_UNIT.timer"
    fi
}

on_error() {
    local status=$1
    trap - ERR HUP INT TERM
    set +e
    if ((TRANSACTION)); then
        warn 'La configuración no terminó. Restaurando los archivos y la red anteriores.'
        # Solo se cancela el temporizador si la restauración terminó bien.
        if bash "$BACKUP/restaurar.sh"; then cancel_timer; fi
        warn "Registro y respaldo: $BACKUP"
    fi
    ((status != 0)) || status=1
    exit "$status"
}

detect_network() {
    # Se usan los datos reales de iproute2; no se adivina /24 ni un gateway .1.
    python3 - "$IFACE" > "$STATE_DIR/red.json" <<'PY'
import ipaddress, json, pathlib, subprocess, sys
def run(*a):
    return subprocess.check_output(a, text=True).strip()
routes = json.loads(run('ip', '-j', '-4', 'route', 'show', 'default'))
requested = sys.argv[1]
routes = [r for r in routes if r.get('dev') and
          (not requested or r['dev'] == requested) and r.get('gateway')]
if not routes:
    sys.exit('No hay una ruta IPv4 por defecto con gateway. Conecta la LAN; usa --interfaz si hace falta.')
route = min(routes, key=lambda r: r.get('metric', 0))
iface, gateway = route['dev'], route['gateway']
if any(iface.startswith(p) for p in ('tun', 'tap', 'wg', 'docker', 'veth', 'virbr', 'br-', 'tailscale')):
    sys.exit('La ruta seleccionada parece de VPN/contenedor. Elige la LAN con --interfaz.')
data = json.loads(run('ip', '-j', '-4', 'address', 'show', 'dev', iface))[0]
addrs = [a for a in data['addr_info'] if a.get('family') == 'inet' and a.get('scope') == 'global']
if len(addrs) != 1:
    sys.exit('Se requiere una sola IPv4 global en la interfaz para no cambiar una configuración ambigua.')
address = ipaddress.IPv4Interface(f"{addrs[0]['local']}/{addrs[0]['prefixlen']}")
gw = ipaddress.IPv4Address(gateway)
rfc1918 = [ipaddress.IPv4Network(n) for n in ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16')]
if not any(address.network.subnet_of(n) for n in rfc1918):
    sys.exit('La dirección debe pertenecer a una red privada local.')
if address.network.prefixlen > 30 or gw not in address.network or gw == address.ip:
    sys.exit('La dirección/gateway no corresponde a una LAN IPv4 convencional.')
print(json.dumps({'iface': iface, 'ip': str(address.ip), 'cidr': str(address),
                  'network': str(address.network), 'gateway': gateway,
                  'metric': route.get('metric', 100), 'mac': data.get('address', ''),
                  'reverse': address.ip.reverse_pointer,
                  'dynamic': addrs[0].get('dynamic', False)}))
PY
    IFACE="$(json_get "$STATE_DIR/red.json" iface)"
    IP="$(json_get "$STATE_DIR/red.json" ip)"
    CIDR="$(json_get "$STATE_DIR/red.json" cidr)"
    NETWORK="$(json_get "$STATE_DIR/red.json" network)"
    GATEWAY="$(json_get "$STATE_DIR/red.json" gateway)"
    REVERSE="$(json_get "$STATE_DIR/red.json" reverse)"
}

check_ports() {
    # BIND solo escucha en la IP LAN. Los resolutores de loopback pueden seguir.
    ss -H -lnutp > "$STATE_DIR/puertos.txt"
    python3 - "$STATE_DIR/puertos.txt" "$IP" "$STATE_DIR/dns-conflictos.json" "${1:-plan}" <<'PY'
import json, pathlib, re, subprocess, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
conflicts = []
dnsmasq_lines = []
for line in lines:
    fields = line.split()
    if len(fields) < 5:
        continue
    host, _, port = fields[4].rpartition(':')
    host = host.strip('[]')
    targets = ('0.0.0.0', '*', '::', sys.argv[2])
    if port == '80':
        targets += ('127.0.0.1',)
    if port not in ('53', '80') or host not in targets:
        continue
    expected = '"named"' if port == '53' else '"nginx"'
    if expected in line:
        continue
    names = re.findall(r'\("([^"\n]+)"', line)
    if port == '53' and names and set(names) == {'dnsmasq'} and sys.argv[4] == 'plan':
        dnsmasq_lines.append(line)
    else:
        hint = '\nEn Kali suele ser Apache: sudo systemctl disable --now apache2' if port == '80' else ''
        sys.exit(f'Puerto {port} ocupado por otro servicio en {host}. Resuelve el conflicto antes de continuar.\n{line}{hint}')
if dnsmasq_lines:
    unit = 'dnsmasq.service'
    result = subprocess.run(['systemctl', 'show', '--property=MainPID', '--value', unit], capture_output=True, text=True)
    main_pid = result.stdout.strip()
    occupied_pids = {p for line in dnsmasq_lines for p in re.findall(r'\bpid=(\d+)\b', line)}
    if result.returncode or not main_pid.isdigit() or main_pid == '0' or main_pid not in occupied_pids:
        sys.exit('El DNS pertenece a una instancia de dnsmasq distinta de dnsmasq.service. '
                 'No se detienen instancias de NetworkManager, libvirt o procesos ajenos. '
                 'Comprueba la interfaz LAN con --interfaz y el propietario con: systemctl status dnsmasq')
    try:
        command = pathlib.Path(f'/proc/{main_pid}/cmdline').read_bytes().split(b'\0')
        argv = [x.decode(errors='replace') for x in command if x]
    except OSError:
        sys.exit('La instancia dnsmasq cambió durante la revisión. Ejecuta dns.sh de nuevo.')
    if not argv or pathlib.Path(argv[0]).name != 'dnsmasq':
        sys.exit('No se pudo confirmar el proceso dnsmasq del servicio; no se modifica.')
    # El estado del proceso importa: no tocar DHCP, DHCPv6, TFTP o PXE activos.
    for line in lines:
        if re.search(r'\bpid=' + re.escape(main_pid) + r'\b', line):
            fields = line.split()
            if len(fields) >= 5 and fields[4].rpartition(':')[2] in ('67', '547', '69', '4011'):
                sys.exit('dnsmasq.service también escucha puertos de otros servicios. '
                         'Se conserva para no interrumpir DHCP/TFTP/PXE. Solo se sustituyen instancias que prestan DNS exclusivamente.')
    # También proteger servicios configurados para interfaces que hoy no están arriba.
    protected = ('--dhcp-range', '--dhcp-relay', '--enable-tftp', '--conf-script')
    if any(any(a == k or a.startswith(k + '=') for k in protected) for a in argv[1:]):
        sys.exit('dnsmasq tiene DHCP/TFTP o configuración dinámica: no se detiene automáticamente.')
    if any(a.startswith('-F') for a in argv[1:]):
        sys.exit('dnsmasq tiene un rango DHCP en su línea de orden; no se detiene automáticamente.')
    root_file = pathlib.Path('/etc/dnsmasq.conf')
    roots = [root_file]
    default_dir = pathlib.Path('/etc/dnsmasq.d')
    # Dnsmasq puede recibir otros archivos de configuración por la línea de orden.
    for i, arg in enumerate(argv[1:], 1):
        if arg in ('-C', '--conf-file', '-7', '--conf-dir'):
            if i + 1 >= len(argv):
                sys.exit('No se pudo interpretar la configuración dnsmasq; no se detiene.')
            value = argv[i + 1]
            kind = 'dir' if arg in ('-7', '--conf-dir') else 'file'
        elif arg.startswith(('--conf-file=', '--conf-dir=')):
            kind = 'dir' if arg.startswith('--conf-dir=') else 'file'
            value = arg.split('=', 1)[1]
        elif arg.startswith('-C') and len(arg) > 2:
            kind, value = 'file', arg[2:]
        elif arg.startswith('-7') and len(arg) > 2:
            kind, value = 'dir', arg[2:]
        else:
            continue
        p = pathlib.Path(value.split(',')[0])
        if not p.is_absolute() or (kind == 'dir' and p != default_dir) or (kind == 'file' and p != root_file and default_dir not in p.parents):
            sys.exit('dnsmasq utiliza configuración personalizada fuera de /etc/dnsmasq.conf y /etc/dnsmasq.d. No se detiene automáticamente.')
        if kind == 'file':
            roots.append(p)
    if default_dir.exists():
        roots.extend(p for p in default_dir.rglob('*') if p.is_file())
    pattern = re.compile(r'^\s*(dhcp-range|dhcp-relay|enable-tftp|conf-script)(?:\s*=|\s*$)', re.M)
    for path in dict.fromkeys(roots):
        if not path.exists():
            continue
        text = path.read_text(errors='replace')
        active_text = '\n'.join(line.split('#', 1)[0] for line in text.splitlines())
        if pattern.search(active_text):
            sys.exit(f'dnsmasq tiene DHCP/TFTP o configuración dinámica en {path}; no se detiene automáticamente.')
        # Rechazar inclusiones fuera de las ubicaciones conocidas.
        for key, value in re.findall(r'^\s*(conf-file|conf-dir)\s*=\s*([^#\n]+)', text, re.M):
            p = pathlib.Path(value.strip().split(',')[0])
            if (not p.is_absolute() or (key == 'conf-dir' and p != default_dir) or
                (key == 'conf-file' and p != root_file and default_dir not in p.parents)):
                sys.exit(f'dnsmasq incluye otra configuración desde {path}; no se detiene automáticamente.')
    conflicts.append({'unit': unit, 'pid': int(main_pid), 'reason': 'DNS exclusivamente'})
pathlib.Path(sys.argv[3]).write_text(json.dumps(conflicts))
PY
}

resolve_dns_conflicts() {
    # Comprobar de nuevo justo antes del cambio; no matar un PID por su nombre.
    check_ports
    local unit
    while IFS= read -r unit; do
        [[ -n $unit ]] || continue
        info "Sustituyendo $unit (solo DNS) por BIND9. Su estado anterior está respaldado."
        systemctl disable --now "$unit"
    done < <(python3 - "$STATE_DIR/dns-conflictos.json" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1])):
    print(item['unit'])
PY
)
    check_ports estricto
}

detect_manager() {
    MANAGER=''
    ORIGINAL_UUID=''
    if command -v nmcli >/dev/null && systemctl is-active --quiet NetworkManager; then
        ORIGINAL_UUID="$(nmcli -g GENERAL.CON-UUID device show "$IFACE" 2>/dev/null || true)"
        if [[ $ORIGINAL_UUID =~ ^[a-fA-F0-9-]{36}$ ]]; then
            local type
            type="$(nmcli -g connection.type connection show uuid "$ORIGINAL_UUID")"
            [[ $type == 802-3-ethernet || $type == 802-11-wireless ]] ||
                die 'Solo se admiten conexiones Ethernet o Wi-Fi normales de NetworkManager.'
            local method
            method="$(nmcli -g ipv4.method connection show uuid "$ORIGINAL_UUID")"
            [[ $method == auto || $method == manual ]] || die 'La conexión no es una LAN IPv4 normal (auto/manual).'
            MANAGER='NetworkManager'
            return
        fi
    fi
    command -v netplan >/dev/null || die 'No se encontró Netplan ni una conexión activa de NetworkManager.'
    systemctl is-active --quiet systemd-networkd || die 'La interfaz no está gestionada por NetworkManager o systemd-networkd.'
    netplan get > "$STATE_DIR/netplan-antes.yaml"
    python3 - "$STATE_DIR/red.json" "$STATE_DIR/netplan-antes.yaml" "$STATE_DIR/netplan-cambio.json" "$DOMAIN" <<'PY'
import copy, fnmatch, json, subprocess, sys, yaml
red = json.load(open(sys.argv[1]))
config = (yaml.safe_load(open(sys.argv[2])) or {}).get('network', {})
found = []
for group in ('ethernets', 'wifis'):
    for ident, entry in (config.get(group) or {}).items():
        match = entry.get('match', {})
        by_name = ident == red['iface'] or entry.get('set-name') == red['iface']
        if match:
            # Un selector compartido por varias tarjetas no se convierte en estático.
            names = json.loads(subprocess.check_output(['ip', '-j', 'link', 'show'], text=True))
            matches = [n for n in names if
                (not match.get('name') or fnmatch.fnmatchcase(n['ifname'], match['name'])) and
                (not match.get('macaddress') or n.get('address', '').lower() == match['macaddress'].lower())]
            if match.get('driver'):
                continue
            by_name = len(matches) == 1 and matches[0]['ifname'] == red['iface']
        if by_name:
            found.append((group, ident, entry))
if len(found) != 1:
    sys.exit('No se puede identificar una definición Netplan exclusiva para esta tarjeta.')
group, ident, original = found[0]
if original.get('renderer', config.get('renderer', 'networkd')) != 'networkd':
    sys.exit('Netplan usa un renderer distinto de networkd; revisa la conexión activa de NetworkManager.')
if original.get('routing-policy'):
    sys.exit('La interfaz tiene reglas avanzadas de enrutamiento; se necesita configuración manual.')
entry = copy.deepcopy(original)
entry['dhcp4'] = False
addresses = entry.get('addresses', [])
if any(not isinstance(a, str) for a in addresses):
    sys.exit('La interfaz usa opciones avanzadas de dirección; no se modificó.')
entry['addresses'] = list(dict.fromkeys(addresses + [red['cidr']]))
entry.pop('gateway4', None)
routes = [r for r in entry.get('routes', []) if not
          (str(r.get('to')) in ('default', '0.0.0.0/0') and ':' not in str(r.get('via', '')))]
routes.append({'to': '0.0.0.0/0', 'via': red['gateway'], 'metric': red['metric']})
# Conservar rutas adicionales recibidas del DHCP, si existen.
live = json.loads(subprocess.check_output(['ip', '-j', '-4', 'route', 'show', 'dev', red['iface']], text=True))
for r in live:
    if r.get('protocol') == 'dhcp' and r.get('dst') not in (None, 'default', red['network']) and r.get('gateway'):
        item = {'to': r['dst'], 'via': r['gateway'], 'metric': r.get('metric', red['metric'])}
        if item not in routes:
            routes.append(item)
entry['routes'] = routes
entry['nameservers'] = {'addresses': [red['ip']], 'search': [sys.argv[4]]}
json.dump({'group': group, 'id': ident, 'entry': entry}, open(sys.argv[3], 'w'))
PY
    MANAGER='Netplan'
}

detect_upstreams() {
    : > "$STATE_DIR/dns-candidatos.txt"
    if [[ -n $UPSTREAM_INPUT ]]; then
        printf '%s\n' "$UPSTREAM_INPUT" > "$STATE_DIR/dns-candidatos.txt"
    else
        if [[ -n $OLD_DOMAIN ]]; then
            # Cambiar el dominio no debe perder los reenviadores originales:
            # el DNS de la tarjeta ya apunta a este mismo servidor.
            python3 - "$STATE_FILE" /etc/bind/named.conf.options >> "$STATE_DIR/dns-candidatos.txt" <<'PY'
import json, pathlib, re, sys
saved = json.load(open(sys.argv[1])).get('upstreams')
if saved:
    print('\n'.join(saved))
else:
    text = pathlib.Path(sys.argv[2]).read_text()
    match = re.search(r'\bforwarders\s*\{([^}]*)\}', text, re.S)
    if match:
        print(match.group(1))
PY
        fi
        if command -v resolvectl >/dev/null; then
            resolvectl dns "$IFACE" >> "$STATE_DIR/dns-candidatos.txt" 2>/dev/null || true
        fi
        if command -v nmcli >/dev/null; then
            nmcli -g IP4.DNS device show "$IFACE" >> "$STATE_DIR/dns-candidatos.txt" 2>/dev/null || true
        fi
        # No sustituir el DNS original por servidores públicos sin necesidad.
        if [[ -r /run/systemd/resolve/resolv.conf ]]; then
            cat /run/systemd/resolve/resolv.conf >> "$STATE_DIR/dns-candidatos.txt"
        else
            cat /etc/resolv.conf >> "$STATE_DIR/dns-candidatos.txt"
        fi
    fi
    python3 - "$STATE_DIR/dns-candidatos.txt" "$IP" "$GATEWAY" "$UPSTREAM_INPUT" > "$STATE_DIR/upstreams.txt" <<'PY'
import ipaddress, re, sys
text = '\n'.join(l.split('#')[0] for l in open(sys.argv[1]))
valid = []
if sys.argv[4]:
    try:
        [ipaddress.IPv4Address(x.strip()) for x in sys.argv[4].split(',')]
    except ValueError:
        sys.exit('--dns-upstream solo acepta IPv4 separadas por comas.')
for token in re.findall(r'(?<![\d.:])(?:\d{1,3}\.){3}\d{1,3}(?![\d.:])', text):
    try:
        ip = ipaddress.IPv4Address(token)
    except ValueError:
        continue
    if token != sys.argv[2] and not (ip.is_loopback or ip.is_unspecified or ip.is_multicast or ip.is_link_local):
        if token not in valid:
            valid.append(token)
if not valid and not sys.argv[4] and sys.argv[3] != sys.argv[2]:
    valid.append(sys.argv[3])
if not valid and sys.argv[4]:
    sys.exit('Los DNS upstream no pueden ser el propio servidor ni direcciones de loopback.')
print('\n'.join(valid))
PY
    mapfile -t UPSTREAMS < "$STATE_DIR/upstreams.txt"
}

create_backup() {
    BACKUP="$BACKUP_BASE/$(date +%Y%m%d-%H%M%S)-$$"
    install -d -m 700 "$BACKUP" "$BACKUP/files"
    export BACKUP MANAGER ORIGINAL_UUID IFACE DOMAIN OLD_DOMAIN STATE_FILE STATE_DIR
    python3 - <<'PY'
import json, os, pathlib, shutil, subprocess
b = pathlib.Path(os.environ['BACKUP'])
paths = ['/etc/bind/named.conf.options', '/etc/bind/named.conf.local',
         '/etc/hosts', '/etc/cloud/cloud.cfg.d/99-dns-midominio-network.cfg',
         '/etc/systemd/system/named.service.d/99-dns-midominio-network.conf',
         os.environ['STATE_FILE']]
for domain in dict.fromkeys(d for d in (os.environ['DOMAIN'], os.environ['OLD_DOMAIN']) if d):
    paths += [f'/etc/bind/db.{domain}', f'/etc/bind/db.{domain}.rev',
              f'/etc/nginx/sites-available/{domain}', f'/etc/nginx/sites-enabled/{domain}',
              f'/var/www/{domain}']
ufw = shutil.which('ufw')
if ufw and subprocess.run([ufw,'status'],capture_output=True,text=True).stdout.startswith('Status: active'):
    paths += ['/etc/ufw/user.rules', '/etc/ufw/user6.rules']
    (b/'ufw-active').touch()
if os.environ['MANAGER'] == 'Netplan':
    paths.append('/etc/netplan')
manifest = []
for i, value in enumerate(paths):
    p, dest = pathlib.Path(value), b / 'files' / str(i)
    exists = p.exists() or p.is_symlink()
    if exists:
        if p.is_dir() and not p.is_symlink():
            shutil.copytree(p, dest, symlinks=True)
        else:
            shutil.copy2(p, dest, follow_symlinks=False)
    manifest.append({'path': value, 'saved': str(dest), 'existed': exists})
json.dump(manifest, open(b/'manifest.json', 'w'))
if os.environ['MANAGER'] == 'NetworkManager':
    old = subprocess.check_output(['nmcli', '-g', 'connection.autoconnect', 'con', 'show', 'uuid', os.environ['ORIGINAL_UUID']], text=True).strip()
    json.dump({'uuid': os.environ['ORIGINAL_UUID'], 'autoconnect': old, 'iface': os.environ['IFACE']}, open(b/'nm-original.json','w'))
services = {}
units = ['named.service', 'nginx.service']
units += [item['unit'] for item in json.load(open(pathlib.Path(os.environ['STATE_DIR'])/'dns-conflictos.json'))]
for unit in dict.fromkeys(units):
    services[unit] = {'active': subprocess.run(['systemctl','is-active','--quiet',unit]).returncode == 0,
                      'enabled': subprocess.run(['systemctl','is-enabled',unit],text=True,capture_output=True).stdout.strip()}
json.dump(services, open(b/'services.json','w'))
PY
    cat > "$BACKUP/restaurar.sh" <<'RESTORE'
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
BACKUP="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec 8> "$BACKUP/restauracion.lock"
flock -w 60 8 || exit 1
[[ ! -f $BACKUP/restaurado ]] || exit 0
touch "$BACKUP/restauracion-iniciada"
python3 - "$BACKUP" <<'PY'
import json, pathlib, shutil, subprocess, sys
b = pathlib.Path(sys.argv[1])
services = json.load(open(b/'services.json'))
def run(args, critical=False):
    r = subprocess.run(args)
    if critical and r.returncode:
        sys.exit(r.returncode)
def remove(p):
    if p.is_symlink() or p.is_file(): p.unlink()
    elif p.exists(): shutil.rmtree(p)
if 'dnsmasq.service' in services:
    # Liberar el puerto antes de recuperar la instancia DNS que lo tenía.
    run(['systemctl','stop','named.service'], True)
for item in json.load(open(b/'manifest.json')):
    p, saved = pathlib.Path(item['path']), pathlib.Path(item['saved'])
    if item['existed'] and p.is_file() and not p.is_symlink() and saved.is_file() and not saved.is_symlink():
        # /etc/hosts puede ser un punto de montaje: conservar su inodo.
        shutil.copyfile(saved, p)
        shutil.copystat(saved, p)
    else:
        remove(p)
        if item['existed']:
            p.parent.mkdir(parents=True, exist_ok=True)
            if saved.is_dir() and not saved.is_symlink(): shutil.copytree(saved, p, symlinks=True)
            else: shutil.copy2(saved, p, follow_symlinks=False)
if (b/'ufw-active').exists():
    run(['ufw','reload'], True)
if (b/'nm-original.json').exists():
    n = json.load(open(b/'nm-original.json'))
    run(['nmcli','con','modify','uuid',n['uuid'],'connection.autoconnect',n['autoconnect']], True)
    run(['nmcli','--wait','45','con','up','uuid',n['uuid'],'ifname',n['iface']], True)
    if (b/'nm-clone.uuid').exists():
        run(['nmcli','con','delete','uuid',(b/'nm-clone.uuid').read_text().strip()])
else:
    run(['netplan','generate'], True)
    run(['netplan','apply'], True)
run(['systemctl','daemon-reload'], True)
units = sorted(services, key=lambda u: (u != 'dnsmasq.service', u))
for unit in units:
    s = services[unit]
    run(['systemctl', 'enable' if s['enabled'] in ('enabled','enabled-runtime') else 'disable', unit])
    run(['systemctl', 'restart' if s['active'] else 'stop', unit], s['active'])
if shutil.which('resolvectl'):
    run(['resolvectl','flush-caches'])
(b/'restaurado').touch()
PY
    printf '\nRestauración terminada. Los paquetes y la carpeta del sitio se conservan.\n'
RESTORE
    chmod 700 "$BACKUP/restaurar.sh"
    # Un temporizador independiente recupera la red incluso si se pierde la sesión.
    ROLLBACK_UNIT="dns-midominio-rollback-$$"
    systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active=5m \
        /bin/bash "$BACKUP/restaurar.sh"
    TRANSACTION=1
    trap 'on_error $?' ERR
    trap 'on_error 130' INT
    trap 'on_error 129' HUP
    trap 'on_error 143' TERM
}

remove_old_domain_config() {
    [[ -n $OLD_DOMAIN && $OLD_DOMAIN != "$DOMAIN" ]] || return 0
    info "Sustituyendo $OLD_DOMAIN por $DOMAIN."
    python3 - "$OLD_DOMAIN" <<'PY'
import pathlib, re, shutil, sys
domain = sys.argv[1]
p = pathlib.Path('/etc/bind/named.conf.local')
escaped = re.escape(domain)
pattern = r'\n?// BEGIN dns\.sh ' + escaped + r'\n.*?// END dns\.sh ' + escaped + r'\n?'
p.write_text(re.sub(pattern, '\n', p.read_text(), flags=re.S))
for value in (f'/etc/bind/db.{domain}', f'/etc/bind/db.{domain}.rev',
              f'/etc/nginx/sites-enabled/{domain}', f'/etc/nginx/sites-available/{domain}',
              f'/var/www/{domain}'):
    target = pathlib.Path(value)
    if target.is_symlink() or target.is_file():
        target.unlink()
    elif target.is_dir():
        shutil.rmtree(target)
PY
}

configure_bind() {
    info 'Configurando BIND9 para la red local.'
    cat > /etc/bind/named.conf.options <<EOF
// Administrado por dns.sh. Respaldo: $BACKUP
acl lan_dns_local { 127.0.0.1; $NETWORK; };
options {
    directory "/var/cache/bind";
    listen-on port 53 { $IP; };
    listen-on-v6 { none; };
    allow-query { lan_dns_local; };
    allow-recursion { lan_dns_local; };
    allow-query-cache { lan_dns_local; };
    allow-transfer { none; };
    recursion yes;
    dnssec-validation auto;
    minimal-responses yes;
    forward first;
    forwarders {
EOF
    local server
    for server in "${UPSTREAMS[@]}"; do [[ -z $server ]] || printf '        %s;\n' "$server" >> /etc/bind/named.conf.options; done
    cat >> /etc/bind/named.conf.options <<'EOF'
    };
};
EOF
    local serial
    serial="$(date +%s)"
    cat > "/etc/bind/db.$DOMAIN" <<EOF
\$TTL 300
@ IN SOA dns.$DOMAIN. admin.$DOMAIN. (
    $serial 3600 900 604800 300 )
@   IN NS dns.$DOMAIN.
@   IN A $IP
dns IN A $IP
www IN A $IP
EOF
    # Zona del host exacto: funciona también en /16, /23, /25, sin fingir /24.
    cat > "/etc/bind/db.$DOMAIN.rev" <<EOF
\$TTL 300
@ IN SOA dns.$DOMAIN. admin.$DOMAIN. (
    $serial 3600 900 604800 300 )
@ IN NS dns.$DOMAIN.
@ IN PTR $DOMAIN.
EOF
    cat >> /etc/bind/named.conf.local <<EOF

// BEGIN dns.sh $DOMAIN
zone "$DOMAIN" {
    type master;
    file "/etc/bind/db.$DOMAIN";
    allow-update { none; };
};
zone "$REVERSE" {
    type master;
    file "/etc/bind/db.$DOMAIN.rev";
    allow-update { none; };
};
// END dns.sh $DOMAIN
EOF
    chmod 644 /etc/bind/named.conf.options /etc/bind/named.conf.local "/etc/bind/db.$DOMAIN" "/etc/bind/db.$DOMAIN.rev"
    named-checkzone "$DOMAIN" "/etc/bind/db.$DOMAIN"
    named-checkzone "$REVERSE" "/etc/bind/db.$DOMAIN.rev"
    named-checkconf -z
    install -d -m 755 /etc/systemd/system/named.service.d
    cat > /etc/systemd/system/named.service.d/99-dns-midominio-network.conf <<'EOF'
[Unit]
Wants=network-online.target
After=network-online.target
EOF
    systemctl daemon-reload
    systemctl enable named.service
    systemctl restart named.service
}

# ---------------------------------------------------------------------------
# Página con los comandos vistos en clase (Sistema Operativo Linux, 3C).
# Para agregar un comando: añade una línea a la lista de cargar_comandos con el
# formato  "unidad^comando^qué hace^ejemplo"  y ejecuta: sudo bash dns.sh --publicar
# ---------------------------------------------------------------------------
cargar_comandos() {
    local d="$DOMAIN" ip="${IP:-IP_DEL_SERVIDOR}" u="${SUDO_USER:-usuario}"
    COMANDOS=(
"1^pwd^Muestra la ruta de la carpeta donde estás parado.^pwd"
"1^whoami^Dice con qué usuario tienes la sesión abierta.^whoami"
"1^ls^Lista lo que hay en la carpeta actual.^ls"
"1^ls -lah^Lista todo, incluidos ocultos, con permisos, dueño y tamaño legible.^ls -lah docs"
"1^cd^Cambia de carpeta. Con .. sube un nivel y con ~ vuelve a tu home.^cd ~/laboratorio-cli"
"1^tree^Dibuja una carpeta y todo lo que tiene adentro en forma de árbol.^tree ~/laboratorio-cli"
"1^mkdir -p^Crea carpetas, incluidas las intermedias que falten. Con llaves crea varias de un jalón.^mkdir -p ~/laboratorio-cli/{docs,src,logs}"
"1^touch^Crea archivos vacíos (o actualiza su fecha si ya existen).^touch docs/{guia,notas}.md src/{main,test}.py README.txt"
"1^cp^Copia archivos. Con -r copia carpetas completas.^cp -r docs docs_respaldo"
"1^mv^Mueve o renombra archivos y carpetas.^mv notas.md apuntes.md"
"1^rm^Borra archivos. Con -r borra carpetas; no hay papelera, así que cuidado.^rm -r docs_respaldo"
"1^rmdir^Borra una carpeta solo si está vacía.^rmdir carpeta_vacia"
"1^ln -s^Crea un acceso directo (enlace simbólico) a otro archivo o carpeta.^ln -s ~/laboratorio-cli/logs ~/logs"
"1^file^Dice qué tipo de archivo es, sin importar su extensión.^file README.txt"
"1^stat^Muestra todos los datos de un archivo: tamaño, permisos y fechas.^stat README.txt"
"1^printf + >^Escribe texto con saltos de línea y lo manda a un archivo, sobrescribiéndolo.^printf 'error\\nok\\nerror\\n' > logs/app.log"
"1^>>^Agrega texto al final de un archivo sin borrar lo que ya tenía.^echo 'ok' >> logs/app.log"
"1^2>^Manda los mensajes de error a un archivo aparte.^ls carpeta_que_no_existe 2> errores.txt"
"1^| (tubería)^Pasa la salida de un comando como entrada del siguiente.^cat logs/app.log | grep error"
"1^&& y ||^&& corre el segundo comando si el primero salió bien; || solo si falló.^mkdir pruebas && cd pruebas"
"1^nano^Editor de texto dentro de la terminal. Ctrl+O guarda, Ctrl+X sale.^nano logs/app.log"
"1^cat^Imprime el contenido de un archivo en la terminal.^cat logs/app.log"
"1^less^Abre un archivo largo para leerlo por partes. q sale, / busca.^less /var/log/syslog"
"1^head y tail^Muestran las primeras o las últimas líneas de un archivo.^tail -n 20 logs/app.log"
"1^tail -f^Sigue un archivo en vivo y muestra las líneas nuevas conforme llegan.^sudo tail -f /var/log/nginx/access.log"
"1^wc^Cuenta líneas, palabras y caracteres.^wc -l logs/app.log"
"1^grep^Busca texto dentro de archivos. -i ignora mayúsculas, -r busca en carpetas, -n da el número de línea.^grep -n error logs/app.log"
"1^sort y uniq^Ordenan líneas y quitan las repetidas. uniq -c además las cuenta.^sort logs/app.log | uniq -c"
"1^cut^Saca una columna de cada línea usando un separador.^cut -d: -f1 /etc/passwd"
"1^diff^Compara dos archivos y muestra en qué líneas son distintos.^diff guia.md notas.md"
"1^find^Busca archivos por nombre, tipo, tamaño o fecha.^find ~ -name '*.sh'"
"1^chmod^Cambia permisos. 7 = rwx, 6 = rw-, 5 = r-x, 4 = r--; en orden dueño, grupo, otros.^chmod 775 logs && chmod 664 README.txt"
"1^chmod u+x^Cambia permisos con letras: u dueño, g grupo, o otros; + da y - quita.^chmod g-w README.txt"
"1^chown^Cambia el dueño (y el grupo) de un archivo.^sudo chown $u:$u README.txt"
"1^umask^Muestra qué permisos se le quitan por defecto a los archivos nuevos.^umask"
"1^man^Abre el manual de cualquier comando. q para salir.^man ls"
"1^--help^Muestra una ayuda corta del comando, más rápida que man.^ls --help"
"1^history^Lista los comandos que has escrito. !número repite uno.^history | tail"
"1^clear^Limpia la pantalla de la terminal (o Ctrl+L).^clear"
"2^#!/bin/bash^Primera línea del script: le dice al sistema qué intérprete lo ejecuta.^#!/bin/bash"
"2^chmod +x y ./^Le da permiso de ejecución al script y luego lo corre desde la carpeta actual.^chmod +x saludo.sh && ./saludo.sh"
"2^bash script.sh^Corre un script sin darle permiso de ejecución.^bash saludo.sh"
"2^bash -n y -x^-n revisa la sintaxis sin ejecutar; -x muestra cada línea conforme corre.^bash -x saludo.sh"
"2^echo^Imprime texto o el valor de una variable.^echo \"Hola \$nombre! Bienvenido a Linux!\""
"2^variable=valor^Guarda un valor. Sin espacios alrededor del =, y se lee con \$.^nombre=\"Jonathan\"; echo \$nombre"
"2^\$(comando)^Guarda en una variable lo que imprime un comando.^hoy=\$(date +%d/%m/%Y)"
"2^read -p^Pide un dato al usuario mostrando un mensaje y lo guarda en una variable.^read -p \"¿Cuál es tu nombre? \" nombre"
"2^\${var:-0}^Usa el valor de la variable o, si viene vacía, un valor por defecto.^base=\${base:-0}"
"2^\$(( ))^Hace operaciones aritméticas con enteros.^area=\$((base*altura))"
"2^\$0, \$1 y \$#^\$0 es el nombre del script, \$1 el primer argumento y \$# cuántos argumentos llegaron.^./listado.sh /home/$u/weas/Scripts"
"2^\$?^Guarda cómo terminó el último comando: 0 es que salió bien.^ls /noexiste; echo \$?"
"2^exit^Termina el script y devuelve un código; 0 es éxito.^exit 1"
"2^función()^Agrupa instrucciones con un nombre para reutilizarlas. local hace que una variable solo exista adentro.^mostrar_ayuda(){ echo \"Uso: \$0 <directorio_origen>\"; }"
"2^for^Repite instrucciones por cada elemento de una lista, por ejemplo cada archivo de una carpeta.^for archivo in \"\$origen\"/*; do echo \"\$archivo\"; done"
"2^for con rango^Repite contando de un número a otro.^for i in {1..5}; do echo \"Vuelta \$i\"; done"
"2^while^Repite mientras se cumpla una condición; lo usamos para el menú de respaldo.^while true; do read -p 'Opción [1-3]: ' op; done"
"2^break^Sale de un ciclo antes de que termine.^[ \"\$op\" = 3 ] && break"
"2^if [ -f ]^Revisa una condición. -f pregunta si la ruta es un archivo normal.^if [ -f \"\$archivo\" ]; then echo sí; fi"
"2^[ -d ] y [ -e ]^-d pregunta si es carpeta; -e, si existe cualquier cosa con ese nombre.^[ -d logs ] || mkdir logs"
"2^-eq, -lt, -gt^Comparan números: igual, menor que, mayor que.^if [ \"\$edad\" -ge 18 ]; then echo mayor; fi"
"2^= y -z^Comparan texto: = si son iguales, -z si viene vacío.^if [ -z \"\$nombre\" ]; then echo 'Falta el nombre'; fi"
"2^case^Elige qué hacer según un valor, como la extensión de un archivo o la opción de un menú.^case \"\${archivo##*.}\" in txt|md) echo texto ;; *) echo otro ;; esac"
"2^\${var##*.}^Corta todo lo que hay antes del último punto; sirve para sacar la extensión.^echo \"\${archivo##*.}\""
"2^basename y dirname^basename deja solo el nombre del archivo; dirname deja solo la carpeta.^basename /home/$u/weas/notas.md"
"2^arreglos^Guardan varios valores en una sola variable.^frutas=(uva pera); echo \"\${frutas[0]}\""
"2^export^Hace que una variable la vean también los programas que abras desde ahí.^export EDITOR=nano"
"2^alias^Crea un atajo para un comando largo. Se guarda en ~/.zshrc o ~/.bashrc.^alias ll='ls -lah'"
"2^source^Vuelve a leer un archivo de configuración sin cerrar la terminal.^source ~/.zshrc"
"2^date^Muestra la fecha y la hora, con el formato que le pidas.^date '+%d/%m/%Y %H:%M'"
"2^sleep^Hace una pausa de los segundos que le digas.^sleep 2"
"2^crontab -e^Programa un script para que corra solo cada cierto tiempo.^0 8 * * * /home/$u/weas/Scripts/respaldo.sh"
"3^sudo^Corre un comando con permisos de administrador.^sudo apt update"
"3^su^Cambia a otro usuario; sin nombre cambia a root.^su - $u"
"3^apt update / install^Actualiza la lista de paquetes e instala programas.^sudo apt install -y lynis"
"3^apt upgrade^Actualiza los programas que ya tienes instalados.^sudo apt upgrade -y"
"3^apt remove^Desinstala un programa.^sudo apt remove cowsay"
"3^apt search / show^Busca paquetes por nombre o muestra la información de uno.^apt show nginx"
"3^apt --fix-broken install^Intenta reparar dependencias rotas antes de instalar algo más.^sudo apt --fix-broken install"
"3^dpkg -l^Lista los paquetes instalados.^dpkg -l | grep bind9"
"3^gpg --dearmor^Convierte la llave de un repositorio al formato que usa apt.^curl -fsSL URL | sudo gpg --dearmor -o /usr/share/keyrings/cisofy.gpg"
"3^tee^Escribe en un archivo (aunque sea de root) y muestra lo mismo en pantalla.^echo 'deb ...' | sudo tee /etc/apt/sources.list.d/cisofy-lynis.list"
"3^lynis audit system^Audita la seguridad del sistema y guarda el reporte en /var/log.^sudo lynis audit system"
"3^id y groups^Muestran tu usuario, tu número de usuario y a qué grupos perteneces.^id $u"
"3^useradd / adduser^Crean un usuario nuevo; adduser pregunta los datos paso a paso.^sudo adduser invitado"
"3^passwd^Cambia la contraseña de un usuario.^sudo passwd invitado"
"3^usermod -aG^Agrega un usuario a un grupo sin sacarlo de los demás.^sudo usermod -aG sudo invitado"
"3^userdel -r^Borra un usuario junto con su carpeta personal.^sudo userdel -r invitado"
"3^ps aux^Lista todos los procesos que están corriendo.^ps aux | grep nginx"
"3^top / htop^Muestran en vivo qué procesos usan más CPU y memoria. q para salir.^htop"
"3^kill^Detiene un proceso usando su número (PID). -9 lo fuerza.^kill 1234"
"3^pkill^Detiene procesos usando su nombre.^pkill firefox"
"3^& , jobs, fg y bg^& manda un comando al fondo; jobs lista, fg lo trae al frente y bg lo sigue en el fondo.^sleep 60 & jobs"
"3^df -h^Muestra cuánto espacio libre queda en cada disco.^df -h"
"3^du -sh^Dice cuánto pesa una carpeta.^du -sh ~/weas"
"3^free -h^Muestra cuánta memoria RAM se está usando.^free -h"
"3^uname -a^Muestra la versión del kernel y el tipo de sistema.^uname -a"
"3^uptime^Cuánto tiempo lleva prendida la máquina y qué tan cargada está.^uptime"
"3^lsblk^Lista los discos y sus particiones.^lsblk"
"3^which^Dice en qué carpeta está el programa que se ejecuta con ese nombre.^which nginx"
"3^journalctl^Muestra los registros (logs) del sistema y de cada servicio.^sudo journalctl -u named -n 30"
"3^tar^Junta carpetas en un solo archivo y lo comprime (c crea, x extrae, z comprime).^tar -czf respaldo.tar.gz ~/weas/Scripts"
"3^zip / unzip^Comprimen y descomprimen archivos .zip.^unzip practica.zip -d practica"
"3^sha256sum^Calcula la huella de un archivo para revisar que no cambió.^sha256sum dns.sh"
"3^ufw^Firewall sencillo: permite o bloquea puertos.^sudo ufw allow 22/tcp"
"3^reboot / shutdown^Reinician o apagan la máquina.^sudo shutdown now"
"4^hostname^Muestra el nombre de la máquina; con -I, sus IPs.^hostname -I"
"4^ip -br address^Muestra cada tarjeta de red con su IP en una línea.^ip -br -4 address"
"4^ip route^Muestra la ruta por defecto, o sea el gateway de la red.^ip -4 route show default"
"4^nmcli^Configura la red de NetworkManager; aquí se usa para dejar la IP fija.^nmcli connection show"
"4^ping^Comprueba si otra máquina responde por la red.^ping -c 4 $ip"
"4^traceroute^Muestra por qué equipos pasa un paquete hasta llegar a su destino.^traceroute 10.10.24.1"
"4^ss -lnut^Lista los puertos abiertos: 53 es el DNS, 80 la web y 22 SSH.^ss -lnut"
"4^/etc/hosts^Archivo donde se le dice a la máquina a qué IP va un nombre, sin preguntar al DNS.^cat /etc/hosts"
"4^/etc/resolv.conf^Archivo que dice a qué servidor DNS le pregunta la máquina.^cat /etc/resolv.conf"
"4^systemctl^Arranca, reinicia, habilita o revisa servicios como named, nginx y ssh.^sudo systemctl enable --now ssh"
"4^systemctl status^Muestra si un servicio está corriendo y sus últimos mensajes.^systemctl status named"
"4^named-checkconf^Revisa que la configuración de BIND9 no tenga errores.^sudo named-checkconf -z"
"4^named-checkzone^Revisa que el archivo de zona del dominio esté bien escrito.^sudo named-checkzone $d /etc/bind/db.$d"
"4^dig^Pregunta a un servidor DNS a qué IP apunta un nombre.^dig @$ip $d +short"
"4^dig -x^Consulta inversa: a qué nombre pertenece una IP.^dig @$ip -x $ip +short"
"4^nslookup^Hace lo mismo que dig con una salida más sencilla; sirve en Windows.^nslookup $d $ip"
"4^host^Otra forma rápida de preguntar la IP de un nombre.^host $d $ip"
"4^nginx -t^Revisa que la configuración de nginx esté bien antes de recargarla.^sudo nginx -t && sudo systemctl reload nginx"
"4^ln -s (nginx)^Crea un enlace; así se activa un sitio de nginx.^sudo ln -s /etc/nginx/sites-available/$d /etc/nginx/sites-enabled/"
"4^curl^Pide una página web desde la terminal. -I muestra solo los encabezados.^curl -I http://$d"
"4^wget^Descarga un archivo de una URL.^wget http://$d/comandos.txt"
"4^ssh^Abre una sesión en otra máquina o le manda un solo comando y regresa.^ssh $u@$ip \"ls -lah /var/www/$d\""
"4^ssh-keygen^Crea un par de llaves para entrar por SSH sin escribir la contraseña.^ssh-keygen -t ed25519"
"4^ssh-copy-id^Copia tu llave pública al servidor para que te reconozca.^ssh-copy-id $u@$ip"
"4^scp^Copia archivos entre máquinas usando SSH.^scp $u@$ip:/var/www/$d/comandos.txt ."
"4^rsync^Copia o sincroniza carpetas entre máquinas; solo manda lo que cambió.^rsync -av ~/weas/ $u@$ip:/home/$u/respaldo/"
    )
}

escapar_html() {
    # Reemplazos entre comillas: en bash 5.2 un & sin comillas significa "lo encontrado".
    local t="$1"
    t=${t//'&'/'&amp;'}
    t=${t//'<'/'&lt;'}
    t=${t//'>'/'&gt;'}
    t=${t//'"'/'&quot;'}
    printf '%s' "$t"
}

titulo_unidad() {
    case "$1" in
        1) printf 'Terminal y archivos' ;;
        2) printf 'Scripts en bash' ;;
        3) printf 'Sistema, usuarios y paquetes' ;;
        4) printf 'DNS, web y SSH' ;;
        *) printf 'Otros' ;;
    esac
}

generar_pagina() {
    local html="$SITE_DIR/index.html" txt="$SITE_DIR/comandos.txt"
    local fecha linea unidad cmd que ejemplo unidad_actual=''
    fecha="$(date '+%d/%m/%Y %H:%M')"
    cargar_comandos

    cat > "$html" <<'EOF'
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Comandos de Linux · 3C</title>
<style>
:root{
  --papel:#E6ECF3; --tinta:#182544; --kali:#2F6FDE; --gris:#5F6E8C;
  --marca:#F3C64F; --linea:#C3CEDD;
  --mono:"JetBrains Mono","DejaVu Sans Mono","Noto Sans Mono",ui-monospace,monospace;
  --sans:"Cantarell","Noto Sans","DejaVu Sans",system-ui,sans-serif;
}
*{box-sizing:border-box}
html{background:var(--papel)}
body{margin:0;color:var(--tinta);font:17px/1.55 var(--sans);background:var(--papel)}
.marco{max-width:1040px;margin:0 auto;padding:0 20px 80px}
header{padding:64px 0 40px;border-bottom:2px solid var(--tinta)}
.quien{font:500 14px/1.4 var(--mono);color:var(--gris);margin:0 0 28px}
.quien b{color:var(--kali);font-weight:600}
h1{font-size:clamp(44px,8vw,96px);line-height:.95;letter-spacing:-.035em;font-weight:800;margin:0 0 36px;max-width:12ch}
.prompt{display:flex;align-items:center;gap:12px;background:var(--tinta);color:var(--papel);padding:16px 20px;border-radius:6px;font:400 clamp(16px,2.4vw,22px)/1.3 var(--mono)}
.prompt span{color:var(--marca);white-space:nowrap}
.prompt input{flex:1;min-width:0;background:none;border:0;color:var(--papel);font:inherit;caret-color:var(--marca)}
.prompt input::placeholder{color:#7F8DAD}
.prompt input:focus{outline:none}
.prompt:focus-within{box-shadow:0 0 0 3px var(--kali)}
.resumen{margin:14px 0 0;color:var(--gris);font-size:15px}
section{display:grid;grid-template-columns:200px 1fr;gap:0 40px;padding:44px 0 8px;border-bottom:1px solid var(--linea)}
section h2{margin:0;font-size:22px;line-height:1.2;font-weight:600;position:sticky;top:20px;align-self:start}
section h2 small{display:block;font:700 64px/1 var(--sans);color:var(--kali);letter-spacing:-.04em;margin-bottom:6px}
ol{list-style:none;margin:0;padding:0}
li{display:grid;grid-template-columns:minmax(150px,220px) 1fr;gap:4px 24px;padding:16px 0;border-top:1px solid var(--linea)}
li:first-child{border-top:0;padding-top:4px}
.cmd{font:600 16px/1.4 var(--mono);color:var(--tinta);background:none;border:0;padding:0;text-align:left;cursor:copy;align-self:start}
.cmd mark{background:linear-gradient(transparent 55%,var(--marca) 55%);color:inherit;padding:0 2px}
.cmd:focus-visible{outline:2px solid var(--kali);outline-offset:3px}
.que{margin:0}
code.ej{grid-column:2;display:block;font:400 14px/1.5 var(--mono);color:#3A4C74;overflow-x:auto;white-space:pre}
.oculto{display:none}
.vacio{padding:40px 0;color:var(--gris)}
footer{padding-top:32px;color:var(--gris);font-size:15px}
footer code{font-family:var(--mono);color:var(--tinta)}
.aviso{position:fixed;left:50%;bottom:24px;transform:translateX(-50%) translateY(20px);opacity:0;background:var(--tinta);color:var(--papel);padding:10px 16px;border-radius:6px;font:14px var(--mono);transition:.2s}
.aviso.ver{opacity:1;transform:translateX(-50%)}
@media (max-width:720px){
  section{grid-template-columns:1fr}
  section h2{position:static;margin-bottom:16px}
  section h2 small{font-size:44px}
  li{grid-template-columns:1fr}
  code.ej{grid-column:1}
}
@media (prefers-reduced-motion:reduce){.aviso{transition:none}}
</style>
</head>
<body>
<div class="marco">
<header>
EOF

    cat >> "$html" <<EOF
<p class="quien"><b>$(escapar_html "${SUDO_USER:-root}")@$(escapar_html "$DOMAIN")</b> · servido desde $(escapar_html "${IP:-}") · generado el $(escapar_html "$fecha")</p>
<h1>Lo que vimos en la terminal</h1>
<label class="prompt" for="buscar"><span>\$ grep</span>
<input id="buscar" type="search" autocomplete="off" spellcheck="false" placeholder="escribe un comando o una palabra, p. ej. permisos"></label>
<p class="resumen" id="resumen">${#COMANDOS[@]} comandos en 4 unidades. Haz clic en cualquiera para copiarlo.</p>
</header>
EOF

    {
        printf 'COMANDOS VISTOS EN CLASE - Sistema Operativo Linux 3C\n'
        printf 'Dominio: %s   IP: %s   Generado: %s\n' "$DOMAIN" "${IP:-}" "$fecha"
    } > "$txt"

    for linea in "${COMANDOS[@]}"; do
        IFS='^' read -r unidad cmd que ejemplo <<< "$linea"
        if [[ $unidad != "$unidad_actual" ]]; then
            if [[ -n $unidad_actual ]]; then printf '</ol></section>\n' >> "$html"; fi
            printf '<section><h2><small>%s</small>%s</h2><ol>\n' "$unidad" "$(titulo_unidad "$unidad")" >> "$html"
            printf '\n== Unidad %s: %s ==\n' "$unidad" "$(titulo_unidad "$unidad")" >> "$txt"
            unidad_actual="$unidad"
        fi
        printf '<li><button class="cmd" type="button" data-copiar="%s">%s</button><p class="que">%s</p><code class="ej">%s</code></li>\n' \
            "$(escapar_html "$ejemplo")" "$(escapar_html "$cmd")" "$(escapar_html "$que")" "$(escapar_html "$ejemplo")" >> "$html"
        printf '  %-26s %s\n  %-26s $ %s\n' "$cmd" "$que" '' "$ejemplo" >> "$txt"
    done
    printf '</ol></section>\n' >> "$html"

    cat >> "$html" <<EOF
<p class="vacio oculto" id="vacio">Ningún comando coincide. Prueba con otra palabra, como «archivo» o «red».</p>
<footer>
<p>Esta página vive en <code>$(escapar_html "$WEB_ROOT")</code>. Para revisar la carpeta desde otra máquina:<br>
<code>ssh $(escapar_html "${SUDO_USER:-usuario}")@$(escapar_html "${IP:-IP}") "ls -lah $(escapar_html "$WEB_ROOT")"</code></p>
</footer>
</div>
EOF

    cat >> "$html" <<'EOF'
<div class="aviso" id="aviso" role="status" aria-live="polite"></div>
<script>
const buscar=document.getElementById('buscar');
const filas=[...document.querySelectorAll('li')];
const secciones=[...document.querySelectorAll('section')];
const resumen=document.getElementById('resumen');
const textoOriginal=resumen.textContent;
buscar.addEventListener('input',()=>{
  const q=buscar.value.trim().toLowerCase();
  let visibles=0;
  filas.forEach(li=>{
    const btn=li.querySelector('.cmd');
    const nombre=btn.dataset.nombre ??= btn.textContent;
    const ok=!q||li.textContent.toLowerCase().includes(q);
    li.classList.toggle('oculto',!ok);
    if(ok)visibles++;
    const i=q?nombre.toLowerCase().indexOf(q):-1;
    btn.textContent='';
    if(i<0){btn.textContent=nombre}
    else{
      btn.append(nombre.slice(0,i));
      const m=document.createElement('mark');m.textContent=nombre.slice(i,i+q.length);btn.append(m);
      btn.append(nombre.slice(i+q.length));
    }
  });
  secciones.forEach(s=>s.classList.toggle('oculto',!s.querySelector('li:not(.oculto)')));
  document.getElementById('vacio').classList.toggle('oculto',visibles>0);
  resumen.textContent=q?`${visibles} coincidencias para «${buscar.value.trim()}».`:textoOriginal;
});
const aviso=document.getElementById('aviso');
document.addEventListener('click',e=>{
  const b=e.target.closest('.cmd');if(!b)return;
  const t=b.dataset.copiar;
  const listo=()=>{aviso.textContent='Copiado: '+t;aviso.classList.add('ver');setTimeout(()=>aviso.classList.remove('ver'),1600)};
  if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(t).then(listo)}
  else{const a=document.createElement('textarea');a.value=t;document.body.append(a);a.select();document.execCommand('copy');a.remove();listo()}
});
</script>
</body>
</html>
EOF
}

create_site() {
    info "Generando la página de comandos en $SITE_DIR"
    [[ ! -L $SITE_DIR ]] || die "La carpeta $SITE_DIR no puede ser un enlace simbólico."
    install -d -m 755 "$SITE_DIR"
    local file
    for file in index.html comandos.txt LEEME.txt; do
        [[ ! -L $SITE_DIR/$file ]] || die "El archivo no puede ser un enlace: $SITE_DIR/$file"
        [[ ! -e $SITE_DIR/$file || -f $SITE_DIR/$file ]] || die "La ruta no es un archivo regular: $SITE_DIR/$file"
    done
    # La página se genera siempre a partir de la lista de comandos.
    generar_pagina
    chmod 644 "$SITE_DIR/index.html" "$SITE_DIR/comandos.txt"
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
        chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$SITE_DIR" "$SITE_DIR/index.html" "$SITE_DIR/comandos.txt"
    fi
}

publish_site() {
    local file
    [[ -d $SITE_DIR && ! -L $SITE_DIR ]] || die "No existe una carpeta válida: $SITE_DIR"
    [[ ! -L $WEB_ROOT ]] || die "El directorio web no debe ser un enlace: $WEB_ROOT"
    install -d -m 755 "$WEB_ROOT"
    for file in index.html comandos.txt; do
        [[ -f $SITE_DIR/$file && ! -L $SITE_DIR/$file ]] || die "Falta un archivo regular: $SITE_DIR/$file"
        install -m 644 -o root -g root "$SITE_DIR/$file" "$WEB_ROOT/$file"
    done
    # Restos de la página "Hola mundo" anterior; la nueva no los usa.
    for file in style.css script.js index.html.bak; do
        if [[ -f $WEB_ROOT/$file && ! -L $WEB_ROOT/$file ]]; then rm -f -- "$WEB_ROOT/$file"; fi
    done
}

configure_ssh() {
    info 'Encendiendo SSH para poder revisar la carpeta del sitio desde otro equipo.'
    if ! dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep -q 'install ok installed'; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
    fi
    systemctl enable ssh.service
    systemctl restart ssh.service
    systemctl is-active --quiet ssh.service || die 'SSH no quedó activo. Revisa: systemctl status ssh'
}

show_site_folder() {
    info "Contenido de $WEB_ROOT (lo mismo que verás por SSH):"
    ls -lah "$WEB_ROOT"
    printf '\nDesde otro equipo de la red:\n'
    printf '  ssh %s@%s "ls -lah %s"\n' "${SUDO_USER:-usuario}" "$IP" "$WEB_ROOT"
    printf '  ssh %s@%s "cat %s/comandos.txt"\n' "${SUDO_USER:-usuario}" "$IP" "$WEB_ROOT"
}

# Ejecuciones posteriores con el mismo dominio: no toca red ni DNS,
# solo regenera la página, la publica y se asegura de que SSH esté arriba.
update_existing() {
    IP="$(json_get "$STATE_FILE" ip)"
    create_site
    publish_site
    nginx -t
    systemctl reload nginx.service
    configure_ssh
    info "Página actualizada en http://$DOMAIN"
}

configure_nginx() {
    publish_site
    cat > "/etc/nginx/sites-available/$DOMAIN" <<EOF
# Administrado por dns.sh. No se eliminan los otros sitios de Nginx.
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN $IP;
    root $WEB_ROOT;
    index index.html;
    charset utf-8;
    server_tokens off;
    allow 127.0.0.1;
    allow $NETWORK;
    deny all;
    add_header X-Content-Type-Options nosniff always;
    location / { try_files \$uri \$uri/ =404; }
    location ~ /\. { deny all; }
}
EOF
    ln -sfn "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
    nginx -t
    systemctl enable nginx.service
    systemctl restart nginx.service
}

configure_firewall() {
    # No habilitar UFW si estaba deshabilitado, ni abrir DNS fuera de la LAN.
    if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
        info 'Permitiendo DNS UDP/TCP y HTTP en UFW solo desde la subred local.'
        local port proto
        for port in 53 80; do
            for proto in udp tcp; do
                [[ $port == 53 || $proto == tcp ]] || continue
                ufw allow in on "$IFACE" from "$NETWORK" to "$IP" port "$port" proto "$proto" comment DNS-MIDOMINIO
            done
        done
    fi
    if systemctl is-active --quiet firewalld.service; then
        warn 'Hay firewalld activo. Autoriza 53/UDP, 53/TCP y 80/TCP desde la LAN en su zona correspondiente.'
    fi
}

configure_network() {
    info "Fijando $CIDR en $IFACE mediante $MANAGER. La conexión puede interrumpirse unos segundos."
    if [[ $MANAGER == NetworkManager ]]; then
        local clone_name clone_uuid
        clone_name="dns-midominio-$IFACE-$(date +%s)-$$"
        nmcli connection clone uuid "$ORIGINAL_UUID" "$clone_name" >/dev/null
        clone_uuid="$(nmcli -g connection.uuid connection show "$clone_name")"
        printf '%s\n' "$clone_uuid" > "$BACKUP/nm-clone.uuid"
        nmcli connection modify uuid "$clone_uuid" \
            connection.interface-name "$IFACE" connection.autoconnect yes connection.autoconnect-priority 999 \
            ipv4.method manual ipv4.addresses "$CIDR" ipv4.gateway "$GATEWAY" \
            ipv4.dns "$IP" ipv4.ignore-auto-dns yes ipv4.dns-search "$DOMAIN" \
            ipv6.ignore-auto-dns yes ipv6.dns ''
        # Las rutas DHCP adicionales no están guardadas en el perfil clonado.
        python3 - "$IFACE" "$NETWORK" > "$STATE_DIR/rutas-dhcp.txt" <<'PY'
import json, subprocess, sys
routes = json.loads(subprocess.check_output(['ip','-j','-4','route','show','dev',sys.argv[1]], text=True))
for r in routes:
    if r.get('protocol') == 'dhcp' and r.get('dst') not in (None, 'default', sys.argv[2]) and r.get('gateway'):
        print(f"{r['dst']} {r['gateway']} {r.get('metric', 100)}")
PY
        local route
        while IFS= read -r route; do
            [[ -z $route ]] || nmcli connection modify uuid "$clone_uuid" +ipv4.routes "$route"
        done < "$STATE_DIR/rutas-dhcp.txt"
        nmcli connection modify uuid "$ORIGINAL_UUID" connection.autoconnect no
        nmcli --wait 45 connection up uuid "$clone_uuid" ifname "$IFACE"
    else
        # netplan set sustituye el subárbol conservando los datos de Wi-Fi/match.
        python3 - "$STATE_DIR/netplan-cambio.json" <<'PY'
import json, subprocess, sys
c = json.load(open(sys.argv[1]))
ident = c['id'].replace('.', r'\.')
value = f"network.{c['group']}.{ident}=" + json.dumps(c['entry'])
subprocess.run(['netplan', 'set', '--origin-hint=99-dns-midominio', value], check=True)
PY
        # Evita que cloud-init regenere el DHCP en el siguiente arranque.
        if [[ -d /etc/cloud/cloud.cfg.d ]]; then
            printf 'network: {config: disabled}\n' > /etc/cloud/cloud.cfg.d/99-dns-midominio-network.cfg
            chmod 600 /etc/cloud/cloud.cfg.d/99-dns-midominio-network.cfg
        fi
        netplan generate
        netplan apply
    fi
    python3 - "$IFACE" "$CIDR" <<'PY'
import json, subprocess, sys
d = json.loads(subprocess.check_output(['ip','-j','-4','addr','show','dev',sys.argv[1]], text=True))
ok = any(f"{a['local']}/{a['prefixlen']}" == sys.argv[2] for a in d[0]['addr_info'] if a.get('family') == 'inet')
if not ok: sys.exit('La interfaz no conserva la IP/prefijo esperado después del cambio.')
if any(a.get('dynamic', False) for a in d[0]['addr_info'] if a.get('family') == 'inet' and f"{a['local']}/{a['prefixlen']}" == sys.argv[2]):
    sys.exit('La dirección todavía figura como dinámica; no se confirmó la conversión a estática.')
PY
}

configure_hosts() {
    # Entrada del propio servidor; los clientes resuelven con BIND, no con hosts.
    python3 - "$IP" "$DOMAIN" "$OLD_DOMAIN" <<'PY'
import pathlib, re, sys
p = pathlib.Path('/etc/hosts')
s = p.read_text()
domain = sys.argv[2]
domains = {d for d in (domain, sys.argv[3]) if d}
for d in domains:
    escaped = re.escape(d)
    pattern = r'\n?# BEGIN dns\.sh ' + escaped + r'\n.*?# END dns\.sh ' + escaped + r'\n?'
    s = re.sub(pattern, '\n', s, flags=re.S)
names = {name for d in domains for name in (d, 'www.' + d, 'dns.' + d)}
lines = []
for line in s.splitlines():
    body, sep, comment = line.partition('#')
    fields = body.split()
    if fields and any(n in names for n in fields[1:]):
        kept = [n for n in fields[1:] if n not in names]
        if not kept:
            if sep: lines.append('#' + comment)
            continue
        line = fields[0] + '\t' + ' '.join(kept) + (' #' + comment if sep else '')
    lines.append(line)
lines += ['# BEGIN dns.sh ' + domain,
          sys.argv[1] + '\t' + ' '.join((domain, 'www.' + domain, 'dns.' + domain)),
          '# END dns.sh ' + domain]
# Escribir en el inodo existente, por si /etc/hosts es un punto de montaje.
p.write_text('\n'.join(lines) + '\n')
PY
}

verify_install() {
    info 'Comprobando IP, servicio DNS por UDP/TCP, zona inversa y sitio HTTP.'
    local answer
    systemctl is-active --quiet named.service
    systemctl is-active --quiet nginx.service
    answer="$(dig +time=2 +tries=1 +short @"$IP" "$DOMAIN" A)"
    [[ $answer == "$IP" ]] || die "La consulta DNS UDP devolvió: $answer"
    answer="$(dig +tcp +time=2 +tries=1 +short @"$IP" "www.$DOMAIN" A)"
    [[ $answer == "$IP" ]] || die "La consulta DNS TCP devolvió: $answer"
    answer="$(dig +time=2 +tries=1 +short @"$IP" -x "$IP")"
    [[ $answer == "$DOMAIN." ]] || die "La consulta inversa devolvió: $answer"
    curl --noproxy '*' --fail --silent --show-error --max-time 8 \
        --resolve "$DOMAIN:80:$IP" "http://$DOMAIN/" > "$STATE_DIR/http-verificado.html"
    cmp -s "$WEB_ROOT/index.html" "$STATE_DIR/http-verificado.html" || die 'El contenido HTTP no coincide con el HTML publicado.'
    curl --noproxy '*' --fail --silent --show-error --max-time 8 \
        --resolve "$DOMAIN:80:$IP" "http://$DOMAIN/comandos.txt" >/dev/null
    systemctl is-active --quiet ssh.service || die 'SSH no está activo.'
    if ! dig +time=3 +tries=1 +short @"$IP" example.com A | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        warn 'El dominio local funciona, pero no se pudo confirmar la resolución de Internet. Revisa los DNS upstream o la salida a Internet.'
    fi
    if command -v resolvectl >/dev/null; then resolvectl flush-caches || true; fi
}

write_guide() {
    cat > "$SITE_DIR/LEEME.txt" <<EOF
DNS LOCAL Y SITIO WEB — $DOMAIN

Servidor Kali: $IP
IP/prefijo: $CIDR
Interfaz: $IFACE
Gateway: $GATEWAY
Clientes admitidos: $NETWORK
Página: http://$DOMAIN
Alias: http://www.$DOMAIN

1. CONFIGURAR CADA CLIENTE (sin modificar router ni DHCP)
Mantén su dirección IP en automática/DHCP. Cambia solamente su DNS:
usa $IP como ÚNICO servidor DNS para esta conexión, sin DNS público
alternativo. Un DNS externo no conoce $DOMAIN y puede causar
fallos intermitentes; BIND reenvía las consultas de Internet.

Windows, PowerShell como administrador:
  Get-NetAdapter
  Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses "$IP"
  Clear-DnsClientCache
Cambia "Ethernet" por el nombre real, por ejemplo "Wi-Fi".
Para volver al DNS automático:
  Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ResetServerAddresses

Kali / Ubuntu Desktop / Linux con NetworkManager:
  Ajustes > Red (o Wi-Fi) > conexión > IPv4.
  Conserva IP automática y desactiva SOLO el DNS automático.
  DNS: $IP. Dominio de búsqueda: $DOMAIN. Guarda y reconecta.
  Comprueba que DNS recibidos por IPv6 no se usen para este dominio.
  Si es necesario, ignora el DNS IPv6 automático de esa conexión.

macOS:
  Ajustes del Sistema > Red > conexión > Detalles > DNS.
  Sustituye los DNS por $IP y guarda.

2. PROBAR DESDE OTRO EQUIPO
  nslookup $DOMAIN $IP
  nslookup $DOMAIN
Ambos deben devolver $IP. Abre: http://$DOMAIN
Si la primera consulta responde y la segunda no, revisa el DNS del cliente.
No se necesita editar el archivo hosts de los clientes.

3. LA PÁGINA DE COMANDOS Y SSH
La página se genera desde la lista de comandos de dns.sh (función
cargar_comandos). Junto a esta guía quedan:
  index.html     la página
  comandos.txt   la misma lista en texto plano
Nginx sirve una copia en $WEB_ROOT para no abrir permisos de tu carpeta
personal. Para agregar comandos edita la lista y publica desde la
ubicación de dns.sh:
  sudo bash dns.sh --publicar
Revisar la carpeta del sitio por SSH desde otro equipo:
  ssh ${SUDO_USER:-usuario}@$IP "ls -lah $WEB_ROOT"
  ssh ${SUDO_USER:-usuario}@$IP "cat $WEB_ROOT/comandos.txt"
Para cambiar el dominio ejecuta sudo bash dns.sh y escribe el nuevo nombre.
La página se genera de nuevo en sitio-NUEVO-DOMINIO. La carpeta anterior
se conserva.

4. DIAGNÓSTICO Y RESTAURACIÓN
  sudo bash dns.sh --diagnostico
  sudo bash dns.sh --restaurar
Restauración directa desde la consola si dns.sh no está disponible:
  sudo bash "$BACKUP/restaurar.sh"
Respaldo protegido: $BACKUP
La restauración recupera archivos, perfil de red y estados de servicios
previos a la configuración, y retira las reglas UFW añadidas por el script.
Si se sustituyó dnsmasq.service porque solo prestaba DNS, recupera también
su estado anterior. Sus archivos de configuración no se modifican.
Si cambiaste el dominio, restaura el dominio anterior y su estado guardado.
Puedes volver a ejecutar --restaurar para regresar al respaldo precedente.
Conserva los paquetes instalados y los archivos editables del sitio.
No restaures este respaldo sobre cambios posteriores que quieras conservar.

5. CONDICIONES DE LA RED
- En una VM, usa adaptador puente o una red con rutas hacia ella. El NAT
  simple del hipervisor no hace accesible el servicio a la LAN física.
- Desactiva aislamiento de clientes en la red Wi-Fi, si está habilitado.
- UFW activo recibe reglas 53/UDP, 53/TCP y 80/TCP solo para $NETWORK.
  Si usas otro firewall, autoriza esos puertos desde la LAN.
- Si el navegador usa DNS seguro/DoH externo, configúralo para utilizar
  el DNS del sistema en esta red. Usa HTTP; no se instala certificado TLS.
- El servidor debe permanecer encendido para resolver los nombres.
- Este dominio solo existe en este DNS local; no se publica en Internet.
- BIND9 escucha en $IP:53. Los resolutores que usan solo loopback,
  como systemd-resolved o el DNS local de NetworkManager, pueden coexistir.
- Si dnsmasq.service ocupaba el DNS de la LAN y solo prestaba DNS, se
  detiene y deshabilita con respaldo de su estado. No se desinstala.
  Si presta DHCP/TFTP o pertenece a libvirt/NetworkManager, no se detiene.
- La configuración del servidor es IPv4. El DNS IPv6 de los clientes
  no debe desviar las consultas locales a un servidor externo.
- Si eliges un dominio terminado en .local, Linux puede utilizar mDNS:
  agrega $DOMAIN como dominio de búsqueda de la conexión del cliente
  para dirigir esas consultas al DNS indicado. Un sufijo como .test
  evita el tratamiento especial de .local.

IMPORTANTE: IP FIJA NO ES RESERVA DHCP
El script convierte la IP recibida en estática en Kali, pero no puede
impedir que el DHCP del router vuelva a asignarla a otro dispositivo.
La prueba ARP detecta algunos duplicados actuales, no conflictos futuros.
Para garantizar una IP sin colisiones debe reservarse/excluirse en DHCP
o utilizarse una IP confirmada fuera de su rango. Sin tocar el router/DHCP,
esa garantía no existe. Si cambias de red, restaura y configura de nuevo.
EOF
    chmod 644 "$SITE_DIR/LEEME.txt"
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
        chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$SITE_DIR/LEEME.txt"
    fi
}

diagnostic() {
    load_installed_config
    local address iface failed=0
    address="$(json_get "$STATE_FILE" ip)"
    iface="$(json_get "$STATE_FILE" iface)"
    info "Servidor registrado: $DOMAIN -> $address ($iface)"
    ip -br -4 address show dev "$iface" || failed=1
    ip -4 route show default
    systemctl --no-pager --full status named.service nginx.service || failed=1
    ss -lnut | grep -E '(:53|:80)[[:space:]]' || failed=1
    if command -v dig >/dev/null; then
        local reply
        reply="$(dig +time=2 +tries=1 +short @"$address" "$DOMAIN" A)" || failed=1
        [[ $reply == "$address" ]] || { warn "Respuesta DNS UDP incorrecta: $reply"; failed=1; }
        reply="$(dig +tcp +time=2 +tries=1 +short @"$address" "$DOMAIN" A)" || failed=1
        [[ $reply == "$address" ]] || { warn "Respuesta DNS TCP incorrecta: $reply"; failed=1; }
        reply="$(dig +time=2 +tries=1 +short @"$address" -x "$address")" || failed=1
        [[ $reply == "$DOMAIN." ]] || { warn "Respuesta PTR incorrecta: $reply"; failed=1; }
    else
        warn 'No se encuentra dig. Reinstala dnsutils.'
        failed=1
    fi
    curl --noproxy '*' --fail --show-error --max-time 8 --resolve "$DOMAIN:80:$address" "http://$DOMAIN/" >/dev/null || failed=1
    if command -v ufw >/dev/null; then ufw status verbose || true; fi
    systemctl is-active --quiet ssh.service || { warn 'SSH no está activo.'; failed=1; }
    IP="$address"
    show_site_folder
    printf '\nEn otro equipo: DNS = %s; abrir http://%s\n' "$address" "$DOMAIN"
    return "$failed"
}

main() {
    need_root
    command -v python3 >/dev/null || die 'Instala primero python3: sudo apt-get update && sudo apt-get install -y python3'
    install -d -m 700 "$STATE_DIR"
    exec 9> "$STATE_DIR/instalacion.lock"
    flock -n 9 || die 'Ya hay otra ejecución de dns.sh en curso.'
    case "$MODE" in
        diagnostico) diagnostic; return ;;
        restaurar)
            [[ -f $STATE_FILE ]] || die 'No hay un respaldo registrado que restaurar.'
            local restore_path
            restore_path="$(json_get "$STATE_FILE" backup)"
            [[ -f $restore_path/restaurar.sh && $restore_path == "$BACKUP_BASE/"* ]] || die 'La ruta de respaldo no es válida.'
            bash "$restore_path/restaurar.sh"
            # Los respaldos nuevos recuperan también el estado del dominio previo.
            # Compatibilidad: el respaldo de la primera versión no incluía estado.
            if [[ -f $STATE_FILE ]] && [[ "$(json_get "$STATE_FILE" backup)" == "$restore_path" ]]; then
                mv "$STATE_FILE" "$STATE_DIR/estado-restaurado-$(date +%s).json"
            fi
            return ;;
        publicar)
            load_installed_config
            [[ $(dirname -- "$SITE_DIR") == "$SCRIPT_DIR" ]] || die 'Ejecuta la copia de dns.sh que está junto a la carpeta original del sitio.'
            IP="$(json_get "$STATE_FILE" ip)"
            create_site
            publish_site
            nginx -t
            systemctl reload nginx.service
            info "Archivos publicados. Abre http://$DOMAIN"
            return ;;
    esac
    [[ -f /etc/os-release ]] || die 'No se reconoce el sistema operativo.'
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        kali|debian|ubuntu) ;;
        *) [[ " ${ID_LIKE:-} " == *' debian '* ]] || die 'Este script está preparado para Kali Linux (o sistemas basados en Debian).' ;;
    esac
    [[ ${ID:-} == kali ]] || warn "Sistema detectado: ${PRETTY_NAME:-desconocido}. Este script está pensado para Kali."
    [[ -d /run/systemd/system ]] || die 'Se requiere Kali iniciado con systemd.'
    [[ $EXPECTED_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "IP esperada no válida: $EXPECTED_IP"
    command -v ip >/dev/null && command -v ss >/dev/null || die 'Falta iproute2. Instala: sudo apt-get install -y iproute2'
    command -v flock >/dev/null || die 'Falta flock (paquete util-linux).'
    install -d -m 700 "$STATE_DIR" "$BACKUP_BASE"
    if [[ -f $STATE_FILE ]]; then
        load_installed_config
        OLD_DOMAIN="$DOMAIN"
        OLD_SITE_DIR="$SITE_DIR"
        [[ -n $IFACE ]] || IFACE="$(json_get "$STATE_FILE" iface)"
    fi
    ask_domain
    if [[ -n $OLD_DOMAIN && $OLD_DOMAIN == "$DOMAIN" ]]; then
        info 'Este dominio ya está configurado: se regenera la página y se enciende SSH (la red y el DNS no se tocan).'
        update_existing
        diagnostic
        return
    fi
    detect_network
    if [[ $IP != "$EXPECTED_IP" ]]; then
        warn "Kali tiene la IP $IP en $IFACE, pero se esperaba $EXPECTED_IP."
        warn 'Probablemente el DHCP de la red la cambió. Se fijará la IP ACTUAL, no la esperada.'
        printf '¿Continuar fijando %s? [s/N]: ' "$IP" >&2
        local reply=''
        IFS= read -r reply || true
        [[ $reply =~ ^([sS]|[sS][iI])$ ]] || die "Cancelado. Si quieres otra IP, edita EXPECTED_IP o usa --ip. No se cambió nada."
    else
        info "IP esperada confirmada: $IP en $IFACE"
    fi
    check_ports
    info "IP que se conservará: $CIDR | gateway $GATEWAY | interfaz $IFACE"
    warn 'Esta IP se hará fija en Kali, pero NO quedará reservada en DHCP; puede haber colisiones futuras.'
    if [[ $IP == 10.0.2.* ]]; then warn 'Si usas VirtualBox, verifica el modo puente: 10.0.2.x suele ser una red NAT.'; fi
    info 'Instalando BIND9, Nginx y herramientas de diagnóstico.'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    # Kali puede traer el 'arping' de herramientas (Habets), que choca con iputils-arping.
    # Si ya está, no se reemplaza: se omite la prueba ARP más adelante.
    local pkgs=(bind9 bind9-utils bind9-dnsutils nginx curl iproute2 python3-yaml openssh-server)
    if dpkg-query -W -f='${Status}' arping 2>/dev/null | grep -q 'install ok installed'; then
        warn "Se conserva el paquete 'arping' de Kali; no se instala iputils-arping."
    else
        pkgs+=(iputils-arping)
    fi
    apt-get install -y "${pkgs[@]}"
    detect_manager
    detect_upstreams
    # No asegura que DHCP no reasigne esta IP en el futuro.
    info 'Buscando conflictos ARP actuales (no reserva la IP en DHCP).'
    if command -v arping >/dev/null && arping -V 2>&1 | grep -qi iputils; then
        arping -D -I "$IFACE" -c 2 -w 3 "$IP" || die 'La prueba ARP no pasó. Revisa IP duplicada, adaptador o acceso a la LAN.'
    else
        warn 'No hay arping de iputils; se omite la prueba de IP duplicada.'
    fi
    if [[ -z $OLD_DOMAIN ]] && grep -q 'BEGIN dns.sh ' /etc/bind/named.conf.local; then
        die 'Hay una configuración anterior sin estado registrado. Restaura su respaldo antes de instalar de nuevo.'
    fi
    create_backup
    resolve_dns_conflicts
    remove_old_domain_config
    configure_bind
    create_site
    configure_nginx
    configure_firewall
    configure_network
    configure_hosts
    configure_ssh
    # Reiniciar tras reactivar la tarjeta permite a named actualizar sus sockets.
    systemctl restart named.service
    verify_install
    write_guide
    cancel_timer
    [[ ! -e $BACKUP/restauracion-iniciada ]] || die 'Se activó la recuperación por tiempo excedido. Restaura y ejecuta de nuevo.'
    python3 - "$STATE_DIR/red.json" "$STATE_FILE" "$BACKUP" "$SITE_DIR" "$MANAGER" "$DOMAIN" "$STATE_DIR/upstreams.txt" <<'PY'
import json, pathlib, sys
d = json.load(open(sys.argv[1]))
d.update(backup=sys.argv[3], site_dir=sys.argv[4], manager=sys.argv[5], domain=sys.argv[6])
d['upstreams'] = [v.strip() for v in pathlib.Path(sys.argv[7]).read_text().splitlines() if v.strip()]
p = pathlib.Path(sys.argv[2]); temp = p.with_suffix('.tmp')
temp.write_text(json.dumps(d, indent=2) + '\n'); temp.chmod(0o600); temp.replace(p)
PY
    TRANSACTION=0
    trap - ERR HUP INT TERM
    info "Configuración terminada. En cada cliente configura DNS = $IP"
    printf '\nPágina: http://%s\nCarpeta editable: %s\nGuía de clientes: %s/LEEME.txt\n' "$DOMAIN" "$SITE_DIR" "$SITE_DIR"
    show_site_folder
    printf '\nPara publicar cambios: sudo bash dns.sh --publicar\n'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
