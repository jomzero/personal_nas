#!/bin/bash
# modules/05_monitoring.sh — smartd y health check semanal

source "$(dirname "$0")/modules/lib/ui.sh"
source "$(dirname "$0")/modules/lib/utils.sh"

_write_health_script() {
    local nas_mount="$1"
    cat > /tmp/nas-health-check.sh << SCRIPT
#!/bin/bash
# nas-health-check.sh — Reporte semanal de salud del NAS
REPORT=""
WARN=0

HDD_TEMP=\$(smartctl -A /dev/sda 2>/dev/null | awk '/Airflow_Temperature/{print \$10}')
HDD_PENDING=\$(smartctl -A /dev/sda 2>/dev/null | awk '/Current_Pending_Sector/{print \$10}')
HDD_REALLOC=\$(smartctl -A /dev/sda 2>/dev/null | awk '/Reallocated_Sector_Ct/{print \$10}')
DISK_USED=\$(df -h / 2>/dev/null | awk 'NR==2{print \$5}')
NAS_USED=\$(df -h "${nas_mount}" 2>/dev/null | awk 'NR==2{print \$5}')
NAS_AVAIL=\$(df -h "${nas_mount}" 2>/dev/null | awk 'NR==2{print \$4}')
CONTAINERS_UP=\$(docker ps --filter "name=immich" --format "{{.Names}}" 2>/dev/null | wc -l)
TS_STATUS=\$(tailscale status 2>/dev/null | grep -c "^[0-9]" || echo 0)

echo ""
echo "=== \$(date '+%Y-%m-%d %H:%M') — NAS Health Report ==="
echo "  OS disk used     : \${DISK_USED:-N/A}"
echo "  NAS disk used    : \${NAS_USED:-N/A} (libre: \${NAS_AVAIL:-N/A})"
echo "  HDD temp         : \${HDD_TEMP:-N/A}°C"
echo "  HDD pending sect : \${HDD_PENDING:-0}"
echo "  HDD reallocated  : \${HDD_REALLOC:-0}"
echo "  Immich containers: \${CONTAINERS_UP}/4"
echo "  Tailscale peers  : \${TS_STATUS}"

[ "\${HDD_PENDING:-0}" -gt 0 ] 2>/dev/null && WARN=1 && echo "  ⚠  ALERTA: Sectores pendientes en HDD"
[ "\${HDD_TEMP:-0}" -gt 45 ] 2>/dev/null && WARN=1 && echo "  ⚠  ALERTA: Temperatura HDD elevada"
[ "\${CONTAINERS_UP:-0}" -lt 4 ] && WARN=1 && echo "  ⚠  ALERTA: Contenedores Immich caídos"

NAS_PCT=\$(df "${nas_mount}" 2>/dev/null | awk 'NR==2{print \$5}' | tr -d '%')
[ "\${NAS_PCT:-0}" -gt 85 ] 2>/dev/null && WARN=1 && echo "  ⚠  ALERTA: Disco NAS >85% lleno"

[ \$WARN -eq 1 ] && echo "  *** REVISAR ALERTAS ANTERIORES ***"
echo ""
exit \$WARN
SCRIPT
    chmod +x /tmp/nas-health-check.sh
    sudo cp /tmp/nas-health-check.sh /usr/local/bin/nas-health-check.sh
}

run_monitoring_setup() {
    print_section "Configurando monitoreo del sistema"

    local nas_mount; nas_mount=$(state_get "NAS_MOUNT")

    # ── smartd ────────────────────────────────────────────────────────────────
    spinner_start "Configurando smartd..."

    # Detectar disco del sistema (excluyendo el NAS)
    local sys_disk
    sys_disk=$(df / --output=source | tail -1 | sed 's/[0-9]*$//')

    cat > /tmp/smartd.conf << EOF
# Configuración smartd — generada por nas-setup

# Disco del sistema
${sys_disk} -a -o on -S on \\
  -W 2,40,45 \\
  -n standby,15 \\
  -s (S/../../[1-6]/02|L/../../0/03) \\
  -m root \\
  -M daily
EOF
    sudo cp /tmp/smartd.conf /etc/smartd.conf

    if sudo systemctl restart smartd 2>/dev/null && service_active smartd; then
        spinner_stop
        ok "smartd activo — alerta si temp HDD >45°C o sectores pendientes"
    else
        spinner_stop
        warn "smartd no pudo iniciarse (puede ser normal en VMs o discos sin SMART)"
    fi

    # ── Health check script ───────────────────────────────────────────────────
    spinner_start "Instalando script de health check..."
    _write_health_script "$nas_mount"
    spinner_stop
    ok "Script instalado en /usr/local/bin/nas-health-check.sh"

    # ── Cron semanal (domingos 8am) ───────────────────────────────────────────
    spinner_start "Configurando cron semanal..."
    local cron_entry="0 8 * * 0 /usr/local/bin/nas-health-check.sh >> /var/log/nas-health.log 2>&1"
    if ! sudo crontab -l 2>/dev/null | grep -qF "nas-health-check"; then
        ( sudo crontab -l 2>/dev/null; echo "$cron_entry" ) | sudo crontab -
    fi
    spinner_stop
    ok "Health check automático: domingos a las 08:00"
    info "Ejecuta manualmente con: sudo nas-health-check.sh"

    return 0
}
