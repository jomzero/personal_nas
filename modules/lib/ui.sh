#!/bin/bash
# modules/lib/ui.sh — Colores, ASCII art, spinners y progress bars

# ─── Colores ──────────────────────────────────────────────────────────────────
if [ -t 1 ] && command -v tput &>/dev/null; then
    RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4); MAGENTA=$(tput setaf 5); CYAN=$(tput setaf 6)
    WHITE=$(tput setaf 7); BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
else
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
    WHITE='\033[0;37m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
fi

# ─── ASCII Art ────────────────────────────────────────────────────────────────
print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
  ███╗   ██╗ █████╗ ███████╗    ███████╗███████╗████████╗██╗   ██╗██████╗
  ████╗  ██║██╔══██╗██╔════╝    ██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗
  ██╔██╗ ██║███████║███████╗    ███████╗█████╗     ██║   ██║   ██║██████╔╝
  ██║╚██╗██║██╔══██║╚════██║    ╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝
  ██║ ╚████║██║  ██║███████║    ███████║███████╗   ██║   ╚██████╔╝██║
  ╚═╝  ╚═══╝╚═╝  ╚═╝╚══════╝    ╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝
EOF
    echo -e "${RESET}"
    echo -e "${DIM}  Convierte cualquier equipo Ubuntu en un NAS familiar con Immich${RESET}"
    echo -e "${DIM}  Backup automático desde Android · Acceso remoto vía Tailscale${RESET}"
    echo ""
    print_divider
}

# ─── Dividers ─────────────────────────────────────────────────────────────────
print_divider() {
    echo -e "${DIM}  ────────────────────────────────────────────────────────────────${RESET}"
}

print_section() {
    local title="$1"
    echo ""
    echo -e "${BOLD}${BLUE}  ▶ ${title}${RESET}"
    print_divider
}

# ─── Mensajes de estado ───────────────────────────────────────────────────────
ok()   { echo -e "  ${GREEN}✓${RESET}  $*"; }
fail() { echo -e "  ${RED}✗${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
info() { echo -e "  ${CYAN}→${RESET}  $*"; }
step() { echo -e "\n  ${BOLD}${WHITE}[$1]${RESET} $2"; }

# ─── Spinner ──────────────────────────────────────────────────────────────────
_SPINNER_PID=""

spinner_start() {
    local msg="${1:-Procesando...}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    (
        while true; do
            printf "\r  ${CYAN}%s${RESET}  %s  " "${frames[$i]}" "$msg"
            i=$(( (i+1) % ${#frames[@]} ))
            sleep 0.1
        done
    ) &
    _SPINNER_PID=$!
    disown "$_SPINNER_PID" 2>/dev/null
}

spinner_stop() {
    if [ -n "$_SPINNER_PID" ] && kill -0 "$_SPINNER_PID" 2>/dev/null; then
        kill "$_SPINNER_PID" 2>/dev/null
        wait "$_SPINNER_PID" 2>/dev/null
    fi
    _SPINNER_PID=""
    printf "\r\033[K"
}

# ─── Progress bar ─────────────────────────────────────────────────────────────
progress_bar() {
    local current=$1
    local total=$2
    local label="${3:-}"
    local width=40
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))
    local pct=$(( current * 100 / total ))
    local bar
    bar="$(printf '%0.s█' $(seq 1 $filled))$(printf '%0.s░' $(seq 1 $empty))"
    printf "\r  ${CYAN}%s${RESET} [%s] %3d%%" "$label" "$bar" "$pct"
    [ "$current" -eq "$total" ] && echo ""
}

# ─── Prompts interactivos ─────────────────────────────────────────────────────
ask_yes_no() {
    local question="$1"
    local default="${2:-y}"
    local prompt
    [ "$default" = "y" ] && prompt="[Y/n]" || prompt="[y/N]"
    while true; do
        echo -en "\n  ${YELLOW}?${RESET}  ${question} ${DIM}${prompt}${RESET} "
        read -r reply
        reply="${reply:-$default}"
        case "${reply,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     warn "Responde 'y' (sí) o 'n' (no)" ;;
        esac
    done
}

ask_input() {
    local question="$1"
    local default="$2"
    local varname="$3"
    if [ -n "$default" ]; then
        echo -en "\n  ${YELLOW}?${RESET}  ${question} ${DIM}[${default}]${RESET}: "
    else
        echo -en "\n  ${YELLOW}?${RESET}  ${question}: "
    fi
    read -r _input
    _input="${_input:-$default}"
    eval "$varname='$_input'"
}

ask_select() {
    local question="$1"
    shift
    local options=("$@")
    echo -e "\n  ${YELLOW}?${RESET}  ${question}"
    for i in "${!options[@]}"; do
        echo -e "      ${CYAN}$((i+1))${RESET}) ${options[$i]}"
    done
    while true; do
        echo -en "\n  ${DIM}Ingresa el número:${RESET} "
        read -r sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#options[@]}" ]; then
            SELECTED_INDEX=$(( sel - 1 ))
            SELECTED_VALUE="${options[$SELECTED_INDEX]}"
            return 0
        fi
        warn "Selección inválida. Ingresa un número entre 1 y ${#options[@]}."
    done
}

# ─── Reporte final ────────────────────────────────────────────────────────────
print_summary() {
    local -n _results=$1
    echo ""
    print_divider
    echo -e "  ${BOLD}Resumen de instalación${RESET}"
    print_divider
    for key in "${!_results[@]}"; do
        local status="${_results[$key]}"
        case "$status" in
            OK)   ok  "$(printf '%-30s' "$key") ${GREEN}Completado${RESET}" ;;
            WARN) warn "$(printf '%-30s' "$key") ${YELLOW}Con advertencias${RESET}" ;;
            FAIL) fail "$(printf '%-30s' "$key") ${RED}Falló${RESET}" ;;
            SKIP) info "$(printf '%-30s' "$key") ${DIM}Omitido${RESET}" ;;
        esac
    done
    print_divider
}
