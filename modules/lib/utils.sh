#!/bin/bash
# modules/lib/utils.sh — Funciones utilitarias compartidas

# ─── Estado de sesión ─────────────────────────────────────────────────────────
STATE_FILE="/tmp/nas-setup.state"

state_set() { echo "$1=$2" >> "$STATE_FILE"; }
state_get() { grep "^$1=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-; }
state_init() { : > "$STATE_FILE"; }

# ─── Verificación de comandos ─────────────────────────────────────────────────
cmd_exists()     { command -v "$1" &>/dev/null; }
service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
service_enabled(){ systemctl is-enabled --quiet "$1" 2>/dev/null; }

# ─── Ejecución silenciosa con log ─────────────────────────────────────────────
LOG_FILE="/var/log/nas-setup.log"

run_logged() {
    local desc="$1"; shift
    echo "" >> "$LOG_FILE"
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') — ${desc} ===" >> "$LOG_FILE"
    if "$@" >> "$LOG_FILE" 2>&1; then
        return 0
    else
        local exit_code=$?
        echo ">>> FAILED (exit $exit_code)" >> "$LOG_FILE"
        return $exit_code
    fi
}

# ─── Versión de Ubuntu ────────────────────────────────────────────────────────
get_ubuntu_version() {
    lsb_release -rs 2>/dev/null || grep VERSION_ID /etc/os-release | cut -d'"' -f2
}

is_ubuntu() {
    [ -f /etc/os-release ] && grep -qi "ubuntu" /etc/os-release
}

ubuntu_version_gte() {
    local required="$1"
    local current; current=$(get_ubuntu_version)
    [ "$(printf '%s\n' "$required" "$current" | sort -V | head -1)" = "$required" ]
}

# ─── Detección de discos ──────────────────────────────────────────────────────
list_physical_disks() {
    lsblk -d -o NAME,SIZE,ROTA,TRAN,MODEL --noheadings 2>/dev/null \
        | grep -v "^loop" \
        | grep -v "^sr"
}

disk_is_ssd() {
    local disk="${1#/dev/}"
    [ "$(cat /sys/block/${disk}/queue/rotational 2>/dev/null)" = "0" ]
}

disk_has_partitions() {
    local disk="${1#/dev/}"
    lsblk -n "/dev/$disk" 2>/dev/null | grep -q "part"
}

disk_is_mounted() {
    local disk="$1"
    mount | grep -q "^${disk}"
}

get_disk_label() {
    local dev="$1"
    local rota tran model size type
    rota=$(cat "/sys/block/${dev#/dev/}/queue/rotational" 2>/dev/null)
    tran=$(cat "/sys/block/${dev#/dev/}/device/transport" 2>/dev/null || \
          lsblk -d -o TRAN --noheadings "$dev" 2>/dev/null | tr -d ' ')
    model=$(lsblk -d -o MODEL --noheadings "$dev" 2>/dev/null | xargs)
    size=$(lsblk -d -o SIZE --noheadings "$dev" 2>/dev/null | xargs)

    [ "$rota" = "0" ] && type="SSD" || type="HDD"
    [ "$tran" = "usb" ] && type="USB-${type}"

    echo "${size} ${type} — ${model:-Desconocido}"
}

# ─── Red ──────────────────────────────────────────────────────────────────────
get_local_ip() {
    ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' | head -1
}

get_tailscale_ip() {
    tailscale ip --4 2>/dev/null | head -1
}

tailscale_connected() {
    tailscale status &>/dev/null && \
    tailscale status 2>/dev/null | grep -q "^[0-9]"
}

# ─── Docker ───────────────────────────────────────────────────────────────────
docker_container_healthy() {
    local name="$1"
    local status
    status=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null)
    [ "$status" = "healthy" ]
}

wait_for_healthy() {
    local container="$1"
    local timeout="${2:-120}"
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if docker_container_healthy "$container"; then
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    return 1
}

# ─── Generación de contraseña ─────────────────────────────────────────────────
gen_password() {
    local len="${1:-32}"
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$len"
}

# ─── Permisos ─────────────────────────────────────────────────────────────────
require_sudo() {
    if ! sudo -n true 2>/dev/null; then
        echo -e "\n  Este script requiere acceso sudo. Ingresa tu contraseña:"
        sudo -v || { echo "No se pudo obtener acceso sudo."; exit 1; }
    fi
    # Mantener sudo activo durante la ejecución
    ( while true; do sudo -n true; sleep 50; done ) &
    _SUDO_KEEPALIVE_PID=$!
    disown "$_SUDO_KEEPALIVE_PID" 2>/dev/null
}

cleanup_sudo_keepalive() {
    if [ -n "${_SUDO_KEEPALIVE_PID:-}" ]; then
        kill "$_SUDO_KEEPALIVE_PID" 2>/dev/null
    fi
}
