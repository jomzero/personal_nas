#!/bin/bash
# =============================================================================
# nas-setup — Instalador automático de NAS familiar con Immich
# https://github.com/jomzero/nas-setup
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/modules/lib/ui.sh"
source "${SCRIPT_DIR}/modules/lib/utils.sh"
source "${SCRIPT_DIR}/modules/00_checks.sh"
source "${SCRIPT_DIR}/modules/01_dependencies.sh"
source "${SCRIPT_DIR}/modules/02_disk.sh"
source "${SCRIPT_DIR}/modules/03_immich.sh"
source "${SCRIPT_DIR}/modules/04_backup.sh"
source "${SCRIPT_DIR}/modules/05_monitoring.sh"
source "${SCRIPT_DIR}/modules/06_verify.sh"

# ─── Inicialización ───────────────────────────────────────────────────────────
sudo mkdir -p /var/log
sudo touch /var/log/nas-setup.log
sudo chmod 666 /var/log/nas-setup.log
state_init

# ─── Limpieza al salir ────────────────────────────────────────────────────────
trap 'spinner_stop; cleanup_sudo_keepalive; echo ""' EXIT
trap 'spinner_stop; echo -e "\n\n  ${YELLOW}Instalación interrumpida.${RESET}\n"; exit 130' INT TERM

# ─── Encabezado ───────────────────────────────────────────────────────────────
print_header

echo -e "  ${BOLD}Este instalador configurará:${RESET}"
echo ""
echo -e "  ${GREEN}•${RESET} Docker + Tailscale + smartmontools + restic"
echo -e "  ${GREEN}•${RESET} Formateo y montaje permanente del disco NAS"
echo -e "  ${GREEN}•${RESET} Immich — servidor de fotos y videos"
echo -e "  ${GREEN}•${RESET} Backup automático nocturno con restic"
echo -e "  ${GREEN}•${RESET} Monitoreo de salud del sistema"
echo ""
echo -e "  ${DIM}Log de instalación: /var/log/nas-setup.log${RESET}"
echo ""

if ! ask_yes_no "¿Deseas continuar con la instalación?"; then
    echo -e "\n  Instalación cancelada.\n"
    exit 0
fi

# ─── Obtener sudo desde el inicio ────────────────────────────────────────────
require_sudo

# ─── Módulo 0: Verificaciones del sistema ────────────────────────────────────
if ! run_checks; then
    echo ""
    fail "El sistema no cumple los requisitos mínimos."
    exit 1
fi

# ─── Módulo 1: Dependencias ───────────────────────────────────────────────────
if ! run_dependencies; then
    fail "No se pudieron instalar las dependencias."
    exit 1
fi

# ─── Módulo 2: Disco NAS ─────────────────────────────────────────────────────
disk_result=0
run_disk_setup || disk_result=$?
if [ $disk_result -eq 1 ]; then
    fail "Error al configurar el disco. Abortando."
    exit 1
elif [ $disk_result -eq 2 ]; then
    warn "Configuración del disco cancelada."
    exit 0
fi

# ─── Módulo 3: Immich ────────────────────────────────────────────────────────
if ! run_immich_setup; then
    fail "Error al instalar Immich."
    exit 1
fi

# ─── Módulo 4: Backup ────────────────────────────────────────────────────────
if ! run_backup_setup; then
    warn "La configuración de backup falló o fue omitida."
    warn "Puedes configurarla luego ejecutando: bash modules/04_backup.sh"
fi

# ─── Módulo 5: Monitoreo ─────────────────────────────────────────────────────
run_monitoring_setup || warn "El monitoreo no pudo configurarse completamente."

# ─── Módulo 6: Verificación y reporte final ──────────────────────────────────
run_verify

echo ""
echo -e "  ${GREEN}${BOLD}✓ Instalación completada.${RESET}"
echo -e "  ${DIM}Para reinstalar o reconfigurar, vuelve a ejecutar este script.${RESET}"
echo ""
