#!/bin/bash
# modules/02_disk.sh — Detección, selección y formateo del disco NAS

source "$(dirname "$0")/modules/lib/ui.sh"
source "$(dirname "$0")/modules/lib/utils.sh"

_show_disk_health() {
    local dev="$1"
    local smart_result
    smart_result=$(sudo smartctl -H "$dev" 2>/dev/null | grep "overall-health" | awk '{print $NF}')
    local pending
    pending=$(sudo smartctl -A "$dev" 2>/dev/null | awk '/Current_Pending_Sector/{print $10}')
    local realloc
    realloc=$(sudo smartctl -A "$dev" 2>/dev/null | awk '/Reallocated_Sector_Ct/{print $10}')

    if [ "$smart_result" = "PASSED" ]; then
        echo -ne "    ${GREEN}SMART: OK${RESET}"
    elif [ -n "$smart_result" ]; then
        echo -ne "    ${RED}SMART: ${smart_result}${RESET}"
    else
        echo -ne "    ${DIM}SMART: N/A${RESET}"
    fi
    [ -n "$pending" ] && [ "$pending" -gt 0 ] && echo -ne " ${RED}[⚠ Sectores pendientes: ${pending}]${RESET}"
    [ -n "$realloc" ] && [ "$realloc" -gt 0 ] && echo -ne " ${YELLOW}[Reubicados: ${realloc}]${RESET}"
    echo ""
}

_select_disk() {
    local purpose="$1"           # "nas" o "backup"
    local exclude_dev="${2:-}"   # Disco a excluir de la lista

    echo ""
    info "Escaneando discos disponibles..."
    echo ""

    local disk_names=()
    local disk_labels=()

    while IFS= read -r line; do
        local dev size rota tran model
        dev=$(echo "$line" | awk '{print $1}')
        [ "/dev/$dev" = "$exclude_dev" ] && continue
        [ "$dev" = "loop" ] && continue

        local label; label=$(get_disk_label "/dev/$dev")
        local mount_info=""
        if disk_is_mounted "/dev/$dev"; then
            mount_info="${DIM} [montado]${RESET}"
        fi

        echo -e "  ${CYAN}$((${#disk_names[@]} + 1))${RESET}) /dev/${dev}  —  ${label}${mount_info}"
        _show_disk_health "/dev/$dev"

        disk_names+=("/dev/$dev")
        disk_labels+=("$label")
    done < <(list_physical_disks)

    if [ ${#disk_names[@]} -eq 0 ]; then
        fail "No se encontraron discos físicos disponibles"
        return 1
    fi

    while true; do
        echo -en "\n  ${YELLOW}?${RESET}  Selecciona el disco para ${purpose} ${DIM}[1-${#disk_names[@]}]${RESET}: "
        read -r sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#disk_names[@]}" ]; then
            SELECTED_DISK="${disk_names[$((sel-1))]}"
            return 0
        fi
        warn "Selección inválida."
    done
}

_confirm_format() {
    local dev="$1"
    local label; label=$(get_disk_label "$dev")

    echo ""
    echo -e "  ${BOLD}Disco seleccionado:${RESET} ${dev} — ${label}"

    if disk_has_partitions "$dev"; then
        echo ""
        warn "Este disco tiene particiones existentes:"
        lsblk "$dev" 2>/dev/null | sed 's/^/    /'
        echo ""
        local mounted_data
        mounted_data=$(lsblk -o MOUNTPOINT -n "$dev" 2>/dev/null | grep -v '^$' | head -5)
        if [ -n "$mounted_data" ]; then
            fail "El disco tiene particiones montadas. Desmóntalas antes de continuar."
            return 1
        fi
        echo -e "  ${RED}${BOLD}⚠  ADVERTENCIA: Todo el contenido del disco será ELIMINADO permanentemente.${RESET}"
        if ! ask_yes_no "¿Confirmas que deseas formatear ${dev}?" "n"; then
            info "Selección cancelada."
            return 2
        fi
    fi
    return 0
}

_format_and_mount() {
    local dev="$1"
    local mount_point="$2"
    local partition="${dev}1"

    # Desmontar si está montado
    spinner_start "Preparando disco..."
    sudo umount "${dev}"* 2>/dev/null || true
    sleep 1
    spinner_stop

    # Crear tabla de particiones GPT + partición única
    spinner_start "Creando tabla de particiones GPT..."
    if ! run_logged "parted" sudo parted "$dev" --script mklabel gpt mkpart primary ext4 0% 100%; then
        spinner_stop; fail "Error al particionar el disco"; return 1
    fi
    sleep 1
    spinner_stop

    # Formatear ext4 (lazy_itable_init=0 para evitar el bug del RTL9210B USB)
    spinner_start "Formateando como ext4... (puede tardar 1-2 min)"
    if ! run_logged "mkfs.ext4" sudo mkfs.ext4 -F -E lazy_itable_init=0,lazy_journal_init=0 -L nas-data "$partition"; then
        spinner_stop; fail "Error al formatear el disco"; return 1
    fi
    spinner_stop
    ok "Disco formateado como ext4"

    # Obtener UUID
    local uuid
    uuid=$(sudo blkid -s UUID -o value "$partition" 2>/dev/null)
    if [ -z "$uuid" ]; then
        fail "No se pudo obtener el UUID del disco"
        return 1
    fi

    # Crear punto de montaje
    sudo mkdir -p "$mount_point"

    # Agregar a fstab (si no existe ya)
    if ! grep -q "$uuid" /etc/fstab; then
        echo "" | sudo tee -a /etc/fstab > /dev/null
        echo "# Disco NAS — agregado por nas-setup" | sudo tee -a /etc/fstab > /dev/null
        echo "UUID=${uuid} ${mount_point} ext4 defaults,nofail,x-systemd.device-timeout=30 0 2" \
            | sudo tee -a /etc/fstab > /dev/null
        ok "Entrada agregada en /etc/fstab"
    fi

    # Montar
    spinner_start "Montando disco en ${mount_point}..."
    if ! run_logged "mount" sudo mount -a; then
        spinner_stop; fail "Error al montar el disco"; return 1
    fi
    spinner_stop

    if mountpoint -q "$mount_point"; then
        local free_gb; free_gb=$(df -BG "$mount_point" --output=avail | tail -1 | tr -dc '0-9')
        ok "Disco montado en ${mount_point} — ${free_gb} GB disponibles"
        state_set "NAS_DISK" "$partition"
        state_set "NAS_MOUNT" "$mount_point"
        state_set "NAS_UUID" "$uuid"
        return 0
    else
        fail "El disco no quedó montado correctamente"
        return 1
    fi
}

run_disk_setup() {
    print_section "Configuración del disco NAS"

    # Seleccionar disco
    _select_disk "almacenamiento NAS (fotos y videos)"
    local nas_disk="$SELECTED_DISK"

    # Confirmar formateo
    local confirm_result
    _confirm_format "$nas_disk"
    confirm_result=$?
    [ $confirm_result -eq 1 ] && return 1
    [ $confirm_result -eq 2 ] && return 2

    # Punto de montaje
    ask_input "Punto de montaje para el NAS" "/mnt/nas" "NAS_MOUNT_INPUT"
    local mount_point="$NAS_MOUNT_INPUT"

    # Formatear y montar
    _format_and_mount "$nas_disk" "$mount_point"
    return $?
}
