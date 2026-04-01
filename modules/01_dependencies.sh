#!/bin/bash
# modules/01_dependencies.sh — Instalación de dependencias

source "$(dirname "$0")/modules/lib/ui.sh"
source "$(dirname "$0")/modules/lib/utils.sh"

_install_docker() {
    spinner_start "Instalando Docker..."
    run_logged "apt update" sudo apt-get update -qq
    run_logged "install docker deps" sudo apt-get install -y -qq \
        ca-certificates curl gnupg lsb-release

    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    run_logged "apt update docker" sudo apt-get update -qq
    run_logged "install docker" sudo apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    spinner_stop
    sudo usermod -aG docker "$USER"
    sudo systemctl enable --now docker &>/dev/null
}

_install_tailscale() {
    spinner_start "Instalando Tailscale..."
    run_logged "install tailscale" \
        bash -c "curl -fsSL https://tailscale.com/install.sh | sh"
    spinner_stop
    sudo systemctl enable --now tailscaled &>/dev/null
}

_connect_tailscale() {
    info "Iniciando sesión en Tailscale..."
    echo ""
    echo -e "  ${YELLOW}Se abrirá una URL de autenticación.${RESET}"
    echo -e "  ${DIM}Ábrela en tu navegador y completa el login.${RESET}"
    echo -e "  ${DIM}El script continuará automáticamente al terminar.${RESET}"
    echo ""

    # tailscale up imprime la URL y bloquea hasta que el login es exitoso
    sudo tailscale up 2>&1 | while IFS= read -r line; do
        if echo "$line" | grep -qE "^https://"; then
            echo -e "  ${BOLD}${CYAN}URL:${RESET} ${line}"
        fi
    done

    # Esperar confirmación de conexión
    local retries=0
    spinner_start "Esperando autenticación de Tailscale..."
    while ! tailscale_connected; do
        sleep 2
        retries=$((retries + 1))
        [ $retries -gt 60 ] && { spinner_stop; return 1; }
    done
    spinner_stop
}

run_dependencies() {
    print_section "Instalando dependencias"
    local step=0
    local total=4

    # ── Docker ──────────────────────────────────────────────────────────────
    step=$((step + 1)); progress_bar $step $total "Dependencias"
    if cmd_exists docker && docker compose version &>/dev/null; then
        local dver; dver=$(docker --version | grep -oP '[\d.]+' | head -1)
        ok "Docker ${dver} — ya instalado"
    else
        _install_docker
        if cmd_exists docker; then
            ok "Docker instalado correctamente"
            warn "Sesión reiniciada para aplicar permisos de grupo docker"
            warn "Si los contenedores fallan con permisos, ejecuta: newgrp docker"
        else
            fail "No se pudo instalar Docker"
            return 1
        fi
    fi

    # ── Docker daemon config ─────────────────────────────────────────────────
    if [ ! -f /etc/docker/daemon.json ]; then
        sudo mkdir -p /etc/docker
        cat << 'EOF' | sudo tee /etc/docker/daemon.json > /dev/null
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
        run_logged "restart docker" sudo systemctl restart docker
    fi

    # ── Tailscale ────────────────────────────────────────────────────────────
    step=$((step + 1)); progress_bar $step $total "Dependencias"
    if cmd_exists tailscale; then
        local tsver; tsver=$(tailscale version 2>/dev/null | head -1)
        ok "Tailscale ${tsver} — ya instalado"
    else
        _install_tailscale
        if cmd_exists tailscale; then
            ok "Tailscale instalado"
        else
            fail "No se pudo instalar Tailscale"
            return 1
        fi
    fi

    # Verificar login de Tailscale
    if tailscale_connected; then
        local ts_ip; ts_ip=$(get_tailscale_ip)
        ok "Tailscale conectado — IP: ${ts_ip}"
        state_set "TAILSCALE_IP" "$ts_ip"
    else
        if _connect_tailscale; then
            local ts_ip; ts_ip=$(get_tailscale_ip)
            ok "Tailscale autenticado — IP: ${ts_ip}"
            state_set "TAILSCALE_IP" "$ts_ip"
        else
            fail "No se completó el login de Tailscale"
            return 1
        fi
    fi

    # ── smartmontools ────────────────────────────────────────────────────────
    step=$((step + 1)); progress_bar $step $total "Dependencias"
    if cmd_exists smartctl; then
        ok "smartmontools — ya instalado"
    else
        spinner_start "Instalando smartmontools..."
        run_logged "install smartmontools" sudo apt-get install -y -qq smartmontools
        spinner_stop
        cmd_exists smartctl && ok "smartmontools instalado" || { fail "Error instalando smartmontools"; return 1; }
    fi

    # ── restic ───────────────────────────────────────────────────────────────
    step=$((step + 1)); progress_bar $step $total "Dependencias"
    if cmd_exists restic; then
        ok "restic — ya instalado"
    else
        spinner_start "Instalando restic..."
        run_logged "install restic" sudo apt-get install -y -qq restic
        spinner_stop
        cmd_exists restic && ok "restic instalado" || { fail "Error instalando restic"; return 1; }
    fi

    echo ""
    return 0
}
