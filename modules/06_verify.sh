#!/bin/bash
# modules/06_verify.sh — Verificación final y reporte

source "$(dirname "$0")/modules/lib/ui.sh"
source "$(dirname "$0")/modules/lib/utils.sh"

run_verify() {
    print_section "Verificación final del sistema"

    local nas_mount; nas_mount=$(state_get "NAS_MOUNT")
    local tailscale_ip; tailscale_ip=$(state_get "TAILSCALE_IP")
    local local_ip; local_ip=$(get_local_ip)
    local immich_port; immich_port=$(state_get "IMMICH_PORT")
    local backup_path; backup_path=$(state_get "BACKUP_PATH")
    local backup_hour; backup_hour=$(state_get "BACKUP_HOUR")

    # Verificar cada componente
    declare -A results

    # Disco NAS
    if mountpoint -q "${nas_mount:-/mnt/nas}" 2>/dev/null; then
        ok "Disco NAS montado en ${nas_mount}"
        results["Disco NAS"]="OK"
    else
        fail "Disco NAS NO está montado"
        results["Disco NAS"]="FAIL"
    fi

    # Contenedores Docker
    local containers=("immich_postgres" "immich_server" "immich_machine_learning" "immich_redis")
    local all_healthy=true
    for c in "${containers[@]}"; do
        if docker_container_healthy "$c" 2>/dev/null; then
            ok "${c} — healthy"
        else
            local status; status=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null || echo "no encontrado")
            warn "${c} — ${status}"
            all_healthy=false
        fi
    done
    $all_healthy && results["Immich (Docker)"]="OK" || results["Immich (Docker)"]="WARN"

    # API de Immich
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 "http://localhost:${immich_port:-2283}/api/server/ping" 2>/dev/null)
    if [ "$http_code" = "200" ]; then
        ok "Immich API responde (HTTP 200)"
        results["Immich API"]="OK"
    else
        warn "Immich API no responde (código: ${http_code:-sin respuesta})"
        results["Immich API"]="WARN"
    fi

    # Servicio systemd Immich
    if service_enabled "immich" && service_active "immich"; then
        ok "immich.service habilitado y activo"
        results["Servicio Immich"]="OK"
    else
        warn "immich.service no está activo"
        results["Servicio Immich"]="WARN"
    fi

    # Tailscale
    if tailscale_connected; then
        ok "Tailscale conectado — IP: ${tailscale_ip}"
        results["Tailscale"]="OK"
    else
        fail "Tailscale no está conectado"
        results["Tailscale"]="FAIL"
    fi

    # Backup
    if service_enabled "nas-backup.timer" 2>/dev/null; then
        local next; next=$(systemctl list-timers nas-backup.timer --no-pager 2>/dev/null | awk 'NR==2{print $1, $2}')
        ok "Backup timer activo — próximo: ${next:-$(date -d "tomorrow ${backup_hour}:00" '+%Y-%m-%d %H:%M' 2>/dev/null)}"
        results["Backup automático"]="OK"
    else
        warn "Timer de backup no activo"
        results["Backup automático"]="WARN"
    fi

    # smartd
    if service_active "smartd"; then
        ok "smartd activo"
        results["Monitoreo SMART"]="OK"
    else
        warn "smartd inactivo (puede ser normal en entornos virtualizados)"
        results["Monitoreo SMART"]="WARN"
    fi

    # ── Tabla de resultados ───────────────────────────────────────────────────
    print_summary results

    # ── Instrucciones de acceso ───────────────────────────────────────────────
    echo ""
    print_divider
    echo -e "  ${BOLD}Acceso al NAS${RESET}"
    print_divider
    echo ""
    echo -e "  ${BOLD}Red local:${RESET}"
    echo -e "    http://${local_ip}:${immich_port:-2283}"
    echo ""
    echo -e "  ${BOLD}Acceso remoto (Tailscale):${RESET}"
    echo -e "    http://${tailscale_ip}:${immich_port:-2283}"
    echo ""
    print_divider
    echo -e "  ${BOLD}${GREEN}Cómo conectar tu Android${RESET}"
    print_divider
    echo ""
    echo -e "  ${CYAN}1.${RESET} Instala ${BOLD}Immich${RESET} desde Google Play Store"
    echo -e "  ${CYAN}2.${RESET} Instala ${BOLD}Tailscale${RESET} desde Google Play Store"
    echo -e "  ${CYAN}3.${RESET} Inicia sesión en Tailscale con la misma cuenta que usaste aquí"
    echo -e "  ${CYAN}4.${RESET} Abre Immich → ingresa la URL del servidor:"
    echo -e "       ${YELLOW}http://${tailscale_ip}:${immich_port:-2283}${RESET}"
    echo -e "  ${CYAN}5.${RESET} Crea tu cuenta o inicia sesión con el admin"
    echo -e "  ${CYAN}6.${RESET} Ve a ${BOLD}Configuración → Backup${RESET} y activa el backup automático"
    echo -e "  ${CYAN}7.${RESET} Deja ${BOLD}desactivadas${RESET} las opciones de ${DIM}\"Usar datos móviles\"${RESET}"
    echo -e "       (así solo hará backup en WiFi)"
    echo ""
    print_divider
    echo -e "  ${BOLD}Comandos útiles${RESET}"
    print_divider
    echo -e "  ${DIM}Ver estado de contenedores:${RESET}  docker ps"
    echo -e "  ${DIM}Ver logs de Immich:${RESET}          docker logs immich_server"
    echo -e "  ${DIM}Apagar NAS de forma segura:${RESET}  sudo systemctl stop immich && sudo poweroff"
    echo -e "  ${DIM}Ejecutar backup manual:${RESET}      sudo systemctl start nas-backup.service"
    echo -e "  ${DIM}Ver log de backup:${RESET}           sudo tail -50 /var/log/nas-backup.log"
    echo -e "  ${DIM}Health check manual:${RESET}         sudo nas-health-check.sh"
    echo ""
}
