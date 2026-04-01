#!/bin/bash
# modules/04_backup.sh — Configuración de backups con restic

source "$(dirname "$0")/modules/lib/ui.sh"
source "$(dirname "$0")/modules/lib/utils.sh"

_write_backup_script() {
    local backup_repo="$1"
    local nas_mount="$2"
    cat > /tmp/backup-nas.sh << SCRIPT
#!/bin/bash
# backup-nas.sh — Backup incremental de Immich
# Generado por nas-setup el $(date '+%Y-%m-%d')
set -euo pipefail

RESTIC_REPO="${backup_repo}"
RESTIC_PASSWORD_FILE="/etc/restic-nas.password"
DUMP_DIR="${backup_repo}-dumps"
LOG="/var/log/nas-backup.log"
DATE=\$(date '+%Y-%m-%d %H:%M:%S')

log() { echo "[\$DATE] \$*" >> "\$LOG"; }

log "========================================"
log "Iniciando backup NAS"

# Verificar que el disco NAS esté montado
if ! mountpoint -q "${nas_mount}"; then
    log "ERROR: Disco NAS no montado en ${nas_mount}. Abortando."
    exit 1
fi

# 1. Dump de PostgreSQL
mkdir -p "\$DUMP_DIR"
log "Dumpeando PostgreSQL..."
if docker exec immich_postgres pg_dump -U immich immich > "\$DUMP_DIR/immich-db.sql"; then
    log "Dump OK — \$(du -sh \$DUMP_DIR/immich-db.sql | cut -f1)"
else
    log "ERROR: Fallo el dump de PostgreSQL"
    exit 1
fi

# 2. Backup incremental con restic
log "Ejecutando backup restic..."
restic -r "\$RESTIC_REPO" \\
    --password-file "\$RESTIC_PASSWORD_FILE" \\
    backup \\
    "${nas_mount}/immich/library" \\
    "\$DUMP_DIR" \\
    --tag "auto" \\
    --tag "\$(date '+%Y-%m-%d')" \\
    2>&1 >> "\$LOG"

log "Backup completado"

# 3. Últimos 5 snapshots
log "Snapshots recientes:"
restic -r "\$RESTIC_REPO" --password-file "\$RESTIC_PASSWORD_FILE" \\
    snapshots --latest 5 2>&1 >> "\$LOG"

log "========================================"
SCRIPT
    chmod +x /tmp/backup-nas.sh
    sudo cp /tmp/backup-nas.sh /usr/local/bin/backup-nas.sh
}

_write_systemd_units() {
    local install_dir="$1"
    # Service
    cat > /tmp/nas-backup.service << 'EOF'
[Unit]
Description=Backup incremental Immich → disco local
After=immich.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup-nas.sh
User=root
EOF
    sudo cp /tmp/nas-backup.service /etc/systemd/system/nas-backup.service

    # Timer
    cat > /tmp/nas-backup.timer << 'EOF'
[Unit]
Description=Timer backup nocturno NAS

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
    sudo cp /tmp/nas-backup.timer /etc/systemd/system/nas-backup.timer
    sudo systemctl daemon-reload
    sudo systemctl enable nas-backup.timer &>/dev/null
}

run_backup_setup() {
    print_section "Configuración de backups"

    local nas_mount; nas_mount=$(state_get "NAS_MOUNT")
    local nas_disk; nas_disk=$(state_get "NAS_DISK")

    # ── Selección del destino de backup ──────────────────────────────────────
    info "El backup guardará copias de tus fotos en un disco diferente al NAS."
    info "Recomendado: el disco interno del sistema (HDD/SSD de arranque)."
    echo ""

    # Mostrar discos disponibles excluyendo el disco NAS
    local nas_dev; nas_dev=$(lsblk -no PKNAME "$nas_disk" 2>/dev/null | head -1)
    nas_dev="/dev/${nas_dev:-$(echo "$nas_disk" | sed 's/[0-9]*$//')}"

    echo -e "  ${DIM}Discos disponibles para backup:${RESET}"
    local disk_options=()
    while IFS= read -r line; do
        local dev; dev=$(echo "$line" | awk '{print $1}')
        [ "/dev/$dev" = "$nas_dev" ] && continue
        local label; label=$(get_disk_label "/dev/$dev")
        local free_gb; free_gb=$(df -BG "/dev/$dev" --output=avail 2>/dev/null | tail -1 | tr -dc '0-9')
        disk_options+=("/dev/$dev — $label")
        echo -e "    ${CYAN}$((${#disk_options[@]}))${RESET}) /dev/${dev} — ${label}"
    done < <(list_physical_disks)

    echo -e "    ${CYAN}$((${#disk_options[@]} + 1))${RESET}) Ingresar ruta personalizada"

    local backup_path=""
    while true; do
        echo -en "\n  ${YELLOW}?${RESET}  Selecciona destino para backup ${DIM}[1-$((${#disk_options[@]} + 1))]${RESET}: "
        read -r sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#disk_options[@]}" ]; then
            local sel_dev; sel_dev=$(echo "${disk_options[$((sel-1))]}" | awk '{print $1}')
            backup_path="${sel_dev%/*}/var/backups/immich"
            # Usar /var/backups por defecto si el disco seleccionado es el sistema
            if df "$sel_dev" 2>/dev/null | grep -q "^/dev/$(df / --output=source | tail -1 | tr -dc 'a-z0-9')"; then
                backup_path="/var/backups/immich"
            else
                backup_path="${sel_dev}/backups/immich"
            fi
            backup_path="/var/backups/immich"
            break
        elif [ "$sel" -eq "$((${#disk_options[@]} + 1))" ] 2>/dev/null; then
            ask_input "Ruta completa para el repositorio de backup" "/var/backups/immich" "CUSTOM_PATH"
            backup_path="$CUSTOM_PATH"
            break
        fi
        warn "Selección inválida."
    done

    # Confirmar espacio disponible
    local backup_parent; backup_parent=$(dirname "$backup_path")
    mkdir -p "$backup_parent" 2>/dev/null || sudo mkdir -p "$backup_parent"
    local free_gb; free_gb=$(df -BG "$backup_parent" --output=avail | tail -1 | tr -dc '0-9')
    info "Espacio disponible en destino: ${free_gb} GB"

    local nas_size; nas_size=$(du -sGB "$nas_mount" 2>/dev/null | cut -f1 | tr -dc '0-9' || echo "?")
    info "Tamaño actual de la librería NAS: ~${nas_size} GB"

    if [ "${free_gb:-0}" -lt "${nas_size:-10}" ] 2>/dev/null; then
        warn "El espacio disponible puede ser insuficiente para el backup completo"
        ask_yes_no "¿Deseas continuar de todas formas?" "n" || return 0
    fi

    # ── Hora del backup ───────────────────────────────────────────────────────
    ask_input "Hora del backup automático (formato 24h, ej: 03)" "03" "BACKUP_HOUR"
    local backup_hour="${BACKUP_HOUR:-03}"
    [[ "$backup_hour" =~ ^[0-9]{1,2}$ ]] || backup_hour="03"
    backup_hour=$(printf "%02d" "$backup_hour")

    # ── Crear directorio y password ───────────────────────────────────────────
    spinner_start "Preparando repositorio de backup..."
    sudo mkdir -p "$backup_path"
    sudo chown "$USER:$USER" "$backup_path"
    sudo mkdir -p "$(dirname "$backup_path")-dumps"
    sudo chown "$USER:$USER" "$(dirname "$backup_path")-dumps"
    spinner_stop

    # Contraseña restic
    local restic_pass; restic_pass=$(gen_password 32)
    echo "$restic_pass" | sudo tee /etc/restic-nas.password > /dev/null
    sudo chmod 600 /etc/restic-nas.password
    sudo chown root:root /etc/restic-nas.password
    ok "Contraseña del repositorio generada y guardada en /etc/restic-nas.password"

    # Inicializar repositorio restic
    spinner_start "Inicializando repositorio restic..."
    if run_logged "restic init" sudo restic -r "$backup_path" \
        --password-file /etc/restic-nas.password init; then
        spinner_stop
        ok "Repositorio restic inicializado en ${backup_path}"
    else
        spinner_stop
        fail "No se pudo inicializar el repositorio restic"
        return 1
    fi

    state_set "BACKUP_PATH" "$backup_path"
    state_set "BACKUP_HOUR" "$backup_hour"

    # ── Escribir script y unidades systemd ───────────────────────────────────
    spinner_start "Instalando script y timer de backup..."
    _write_backup_script "$backup_path" "$nas_mount"

    # Ajustar hora en timer
    _write_systemd_units
    sudo sed -i "s|03:00:00|${backup_hour}:00:00|g" /etc/systemd/system/nas-backup.timer
    sudo systemctl daemon-reload
    sudo systemctl enable --now nas-backup.timer &>/dev/null
    spinner_stop

    ok "Script instalado en /usr/local/bin/backup-nas.sh"
    ok "Timer configurado — backup diario a las ${backup_hour}:00"

    # ── Primer backup de prueba ───────────────────────────────────────────────
    echo ""
    if ask_yes_no "¿Ejecutar el primer backup ahora? (recomendado, puede tardar varios minutos)"; then
        info "Ejecutando primer backup..."
        echo ""
        if sudo systemctl start nas-backup.service; then
            ok "Primer backup completado"
            info "Log disponible en: /var/log/nas-backup.log"
        else
            warn "El backup puede estar en curso o hubo un error"
            info "Verifica con: sudo journalctl -u nas-backup.service"
        fi
    else
        info "El primer backup automático correrá esta noche a las ${backup_hour}:00"
    fi

    return 0
}
