#!/bin/bash
# modules/00_checks.sh — Verificaciones previas del sistema

source "$(dirname "$0")/modules/lib/ui.sh"
source "$(dirname "$0")/modules/lib/utils.sh"

run_checks() {
    print_section "Verificando compatibilidad del sistema"
    local errors=0

    # Ubuntu
    spinner_start "Verificando sistema operativo..."
    sleep 0.5
    spinner_stop
    if is_ubuntu; then
        local ver; ver=$(get_ubuntu_version)
        if ubuntu_version_gte "20.04"; then
            ok "Ubuntu ${ver} — compatible"
        else
            fail "Ubuntu ${ver} — se requiere 20.04 o superior"
            errors=$((errors + 1))
        fi
    else
        fail "Este script solo funciona en Ubuntu"
        errors=$((errors + 1))
    fi

    # No correr como root directo
    if [ "$EUID" -eq 0 ]; then
        fail "No ejecutes el script como root. Usa un usuario con sudo."
        errors=$((errors + 1))
    else
        ok "Usuario actual: $(whoami)"
    fi

    # Acceso sudo
    spinner_start "Verificando permisos sudo..."
    sleep 0.3
    spinner_stop
    if sudo -n true 2>/dev/null || sudo -v 2>/dev/null; then
        ok "Acceso sudo disponible"
    else
        fail "El usuario no tiene permisos sudo"
        errors=$((errors + 1))
    fi

    # Arquitectura
    local arch; arch=$(uname -m)
    if [[ "$arch" == "x86_64" || "$arch" == "aarch64" ]]; then
        ok "Arquitectura: ${arch}"
    else
        warn "Arquitectura ${arch} no probada — puede funcionar con limitaciones"
    fi

    # RAM mínima (4GB)
    local ram_kb; ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local ram_gb=$(( ram_kb / 1024 / 1024 ))
    if [ "$ram_gb" -ge 4 ]; then
        ok "RAM: ${ram_gb} GB"
    else
        warn "RAM: ${ram_gb} GB — se recomiendan al menos 4 GB para Immich"
    fi

    # Disco de sistema (mínimo 20GB libres para Docker/OS)
    local free_gb
    free_gb=$(df / --output=avail -BG | tail -1 | tr -dc '0-9')
    if [ "$free_gb" -ge 20 ]; then
        ok "Espacio libre en /: ${free_gb} GB"
    else
        fail "Espacio libre en /: ${free_gb} GB — se necesitan al menos 20 GB"
        errors=$((errors + 1))
    fi

    # Conexión a internet
    spinner_start "Verificando conexión a internet..."
    if curl -s --max-time 5 https://github.com > /dev/null 2>&1; then
        spinner_stop
        ok "Conexión a internet disponible"
    else
        spinner_stop
        fail "Sin conexión a internet — requerida para descargar paquetes"
        errors=$((errors + 1))
    fi

    if [ "$errors" -gt 0 ]; then
        echo ""
        fail "Se encontraron ${errors} error(es) crítico(s). Corrígelos antes de continuar."
        return 1
    fi

    return 0
}
