#!/bin/bash
# modules/03_immich.sh — Instalación y configuración de Immich

source "$(dirname "$0")/modules/lib/ui.sh"
source "$(dirname "$0")/modules/lib/utils.sh"

IMMICH_VERSION="release"
IMMICH_PORT=2283

_write_compose() {
    local install_dir="$1"
    cat > "${install_dir}/docker-compose.yml" << 'COMPOSE'
name: immich

services:
  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}
    volumes:
      - ${UPLOAD_LOCATION}:/usr/src/app/upload
      - /etc/localtime:/etc/localtime:ro
    env_file:
      - .env
    ports:
      - "2283:2283"
    depends_on:
      - redis
      - database
    restart: always
    healthcheck:
      disable: false

  immich-machine-learning:
    container_name: immich_machine_learning
    image: ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION:-release}
    volumes:
      - ${MODEL_CACHE_LOCATION}:/cache
    env_file:
      - .env
    restart: always
    healthcheck:
      disable: false
    environment:
      - MACHINE_LEARNING_WORKERS=2
      - MACHINE_LEARNING_WORKER_TIMEOUT=120

  redis:
    container_name: immich_redis
    image: docker.io/redis:6.2-alpine
    healthcheck:
      test: redis-cli ping || exit 1
    restart: always

  database:
    container_name: immich_postgres
    image: docker.io/tensorchord/pgvecto-rs:pg14-v0.2.0
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_DB: ${DB_DATABASE_NAME}
      POSTGRES_INITDB_ARGS: "--data-checksums"
    volumes:
      - ${DB_DATA_LOCATION}:/var/lib/postgresql/data
    healthcheck:
      test: >-
        pg_isready --dbname="$${POSTGRES_DB}" --username="$${POSTGRES_USER}" || exit 1;
        Chksum="$$(psql --dbname="$${POSTGRES_DB}" --username="$${POSTGRES_USER}"
        --tuples-only --no-align
        --command='SELECT COALESCE(SUM(checksum_failures), 0) FROM pg_stat_database')";
        echo "checksum failure count is $$Chksum";
        [ "$$Chksum" = '0' ] || exit 1
      interval: 5m
      start_interval: 30s
      start_period: 5m
    command: >-
      postgres
      -c shared_preload_libraries=vectors.so
      -c 'search_path="$$user", public, vectors'
      -c logging_collector=on
      -c max_wal_size=2GB
      -c shared_buffers=256MB
      -c wal_compression=on
    restart: always
COMPOSE
}

_write_env() {
    local install_dir="$1"
    local nas_mount="$2"
    local db_pass="$3"

    cat > "${install_dir}/.env" << EOF
# Immich — generado por nas-setup el $(date '+%Y-%m-%d')
UPLOAD_LOCATION=${nas_mount}/immich/library
DB_DATA_LOCATION=${nas_mount}/immich/postgres
MODEL_CACHE_LOCATION=${nas_mount}/immich/model-cache
IMMICH_VERSION=release
DB_PASSWORD=${db_pass}
DB_USERNAME=immich
DB_DATABASE_NAME=immich
EOF
    chmod 600 "${install_dir}/.env"
}

_write_systemd_service() {
    local install_dir="$1"
    cat > /tmp/immich.service << EOF
[Unit]
Description=Immich NAS — servidor de fotos
After=docker.service mnt-nas.mount network-online.target
Requires=docker.service mnt-nas.mount
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${install_dir}
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
TimeoutStopSec=60
User=${SUDO_USER:-$USER}
Group=${SUDO_USER:-$USER}

[Install]
WantedBy=multi-user.target
EOF
    # Adaptar el nombre del mount unit según el punto de montaje real
    local mount_point; mount_point=$(state_get "NAS_MOUNT")
    local mount_unit; mount_unit=$(systemd-escape --path "$mount_point").mount
    sed -i "s|mnt-nas.mount|${mount_unit}|g" /tmp/immich.service

    sudo cp /tmp/immich.service /etc/systemd/system/immich.service
    sudo systemctl daemon-reload
    sudo systemctl enable immich.service &>/dev/null
}

run_immich_setup() {
    print_section "Instalando Immich"

    local nas_mount; nas_mount=$(state_get "NAS_MOUNT")
    if [ -z "$nas_mount" ] || ! mountpoint -q "$nas_mount"; then
        fail "El disco NAS no está montado. Ejecuta primero la configuración del disco."
        return 1
    fi

    # Directorio de instalación
    local install_dir="/opt/immich"
    ask_input "Directorio de configuración de Immich" "$install_dir" "IMMICH_DIR_INPUT"
    install_dir="$IMMICH_DIR_INPUT"
    sudo mkdir -p "$install_dir"
    sudo chown "$USER:$USER" "$install_dir"

    # Estructura de datos en el NAS
    spinner_start "Creando estructura de directorios..."
    mkdir -p \
        "${nas_mount}/immich/library" \
        "${nas_mount}/immich/postgres" \
        "${nas_mount}/immich/model-cache"
    spinner_stop
    ok "Directorios creados en ${nas_mount}/immich/"

    # Generar contraseña de DB
    local db_pass; db_pass=$(gen_password 32)

    # Escribir archivos de configuración
    spinner_start "Escribiendo configuración..."
    _write_compose "$install_dir"
    _write_env "$install_dir" "$nas_mount" "$db_pass"
    spinner_stop
    ok "docker-compose.yml y .env generados"

    # Guardar contraseña en archivo seguro
    echo "$db_pass" | sudo tee /etc/immich-db.password > /dev/null
    sudo chmod 600 /etc/immich-db.password

    # Systemd service
    spinner_start "Configurando servicio systemd..."
    _write_systemd_service "$install_dir"
    spinner_stop
    ok "Servicio immich.service habilitado"

    state_set "IMMICH_DIR" "$install_dir"
    state_set "IMMICH_PORT" "$IMMICH_PORT"

    # Descargar imágenes Docker
    info "Descargando imágenes Docker (puede tardar varios minutos)..."
    echo ""
    local step=0; local total=4
    for img in \
        "ghcr.io/immich-app/immich-server:release" \
        "ghcr.io/immich-app/immich-machine-learning:release" \
        "docker.io/redis:6.2-alpine" \
        "docker.io/tensorchord/pgvecto-rs:pg14-v0.2.0"
    do
        step=$((step+1))
        progress_bar $step $total "Descargando"
        run_logged "pull $img" docker pull "$img"
    done
    echo ""
    ok "Imágenes descargadas"

    # Iniciar stack
    spinner_start "Iniciando Immich..."
    run_logged "docker compose up" bash -c "cd '$install_dir' && docker compose up -d --remove-orphans"
    spinner_stop

    # Esperar a que todos los contenedores estén healthy
    info "Esperando que los contenedores estén listos (máx. 3 min)..."
    local containers=("immich_postgres" "immich_server" "immich_machine_learning" "immich_redis")
    local all_ok=true
    for c in "${containers[@]}"; do
        spinner_start "Verificando ${c}..."
        if wait_for_healthy "$c" 180; then
            spinner_stop; ok "${c} — healthy"
        else
            spinner_stop; warn "${c} — no alcanzó estado healthy en el tiempo esperado"
            all_ok=false
        fi
    done

    if $all_ok; then
        ok "Immich v$(docker exec immich_server cat /usr/src/app/package.json 2>/dev/null | grep '"version"' | head -1 | grep -oP '[\d.]+'|| echo '?') iniciado correctamente"
        return 0
    else
        warn "Immich inició pero algunos contenedores tardaron más de lo esperado"
        warn "Verifica el estado con: docker ps"
        return 0
    fi
}
