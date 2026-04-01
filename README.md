# NAS Setup — Servidor de fotos familiar con Immich

Convierte cualquier equipo con **Ubuntu 20.04+** en un NAS familiar con backup automático desde dispositivos Android, acceso remoto seguro vía Tailscale y monitoreo de salud del sistema.

## ¿Qué instala?

| Componente | Descripción |
|---|---|
| **Immich** | Servidor de fotos y videos autoalojado (alternativa a Google Photos) |
| **Docker** | Plataforma de contenedores para ejecutar Immich |
| **Tailscale** | VPN mesh para acceso remoto seguro sin abrir puertos |
| **restic** | Backups incrementales y deduplicados |
| **smartmontools** | Monitoreo de salud de discos duros |

## Requisitos

- Ubuntu 20.04 LTS o superior (x86_64 o ARM64)
- Al menos **4 GB de RAM** (recomendado: 8 GB)
- Al menos **20 GB libres** en el disco del sistema
- Un disco dedicado para almacenar las fotos (interno o externo)
- Conexión a internet durante la instalación
- Cuenta en [Tailscale](https://tailscale.com) (gratuita para uso personal)

## Instalación

```bash
# 1. Clona el repositorio
git clone https://github.com/tu-usuario/nas-setup.git
cd nas-setup

# 2. Dale permisos de ejecución al script
chmod +x setup.sh

# 3. Ejecuta el instalador
./setup.sh
```

> No ejecutes el script con `sudo` directamente. El script pedirá tu contraseña cuando sea necesario.

## Proceso de instalación paso a paso

El instalador es completamente interactivo. A continuación se describe cada etapa:

### Paso 1 — Verificación del sistema
El script comprueba que el sistema sea compatible: versión de Ubuntu, permisos sudo, RAM mínima, espacio en disco y conexión a internet.

### Paso 2 — Dependencias
Instala o verifica Docker, Tailscale, smartmontools y restic. Si Tailscale no tiene sesión iniciada, el script mostrará una URL para que completes el login en el navegador y continuará automáticamente.

### Paso 3 — Configuración del disco NAS
Muestra todos los discos físicos del sistema con su tamaño, tipo (SSD/HDD, USB/SATA) y estado de salud SMART. Seleccionas cuál usar para almacenar las fotos. El disco se formateará como **ext4** y se configurará para montarse automáticamente al arrancar.

> ⚠️ **Advertencia:** El disco seleccionado será formateado. Asegúrate de que no contenga datos importantes.

### Paso 4 — Instalación de Immich
Descarga y configura Immich con Docker Compose. Genera una contraseña segura para la base de datos automáticamente. Crea un servicio systemd para que Immich arranque automáticamente con el sistema.

### Paso 5 — Backups automáticos
Configura un repositorio restic en el disco del sistema para guardar copias de seguridad diarias de todas las fotos. El backup es incremental (solo copia lo nuevo cada día) y deduplicado. Puedes elegir la hora del backup (por defecto: 3:00 AM).

### Paso 6 — Monitoreo
Configura `smartd` para monitorear la temperatura y salud del disco. Instala un script de health check que se ejecuta automáticamente cada domingo a las 8:00 AM.

### Paso 7 — Reporte final
Muestra el estado de todos los componentes instalados y las instrucciones para conectar tus dispositivos Android.

## Conectar un dispositivo Android

1. Instala **[Immich](https://play.google.com/store/apps/details?id=app.alextran.immich)** desde Google Play
2. Instala **[Tailscale](https://play.google.com/store/apps/details?id=com.tailscale.ipn)** desde Google Play
3. Inicia sesión en Tailscale con la **misma cuenta** que usaste al instalar el NAS
4. Abre Immich e ingresa la URL del servidor que te mostró el instalador:
   ```
   http://<tailscale-ip>:2283
   ```
5. Crea tu usuario o inicia sesión con la cuenta administrador
6. Ve a **Configuración → Backup** y activa el backup automático
7. Deja **desactivadas** las opciones *"Usar datos móviles"* para que solo haga backup en WiFi

Para agregar más usuarios, el administrador puede crearlos desde la interfaz web de Immich en **Administración → Usuarios**.

## Apagado y encendido seguro

Cuando necesites apagar el equipo (para moverlo, mantenimiento, etc.):

```bash
# Detener Immich limpiamente y apagar
sudo systemctl stop immich && sudo poweroff
```

Al encender:
- Si el disco NAS estaba conectado al arrancar, Immich inicia automáticamente
- Si el disco NAS se conectó **después** del arranque:
  ```bash
  sudo mount /mnt/nas
  sudo systemctl start immich
  ```

## Comandos útiles

```bash
# Estado de los contenedores
docker ps

# Logs de Immich
docker logs immich_server -f

# Backup manual
sudo systemctl start nas-backup.service

# Ver log del último backup
sudo tail -50 /var/log/nas-backup.log

# Health check manual del sistema
sudo nas-health-check.sh

# Actualizar Immich a la última versión
cd /opt/immich
docker compose pull
sudo systemctl restart immich
```

## Estructura del proyecto

```
nas-setup/
├── setup.sh                    # Script principal
├── modules/
│   ├── lib/
│   │   ├── ui.sh               # Colores, spinners, prompts
│   │   └── utils.sh            # Funciones utilitarias
│   ├── 00_checks.sh            # Verificación del sistema
│   ├── 01_dependencies.sh      # Docker, Tailscale, restic, smartmontools
│   ├── 02_disk.sh              # Detección y formateo del disco NAS
│   ├── 03_immich.sh            # Instalación de Immich
│   ├── 04_backup.sh            # Configuración de backups con restic
│   ├── 05_monitoring.sh        # smartd y health check
│   └── 06_verify.sh            # Verificación final y reporte
└── README.md
```

## Probado en

| Hardware | OS | Estado |
|---|---|---|
| Apple Mac Mini 6.2 (i7-3615QM, 10 GB RAM) | Ubuntu 24.04 LTS | ✅ Probado |
| Cualquier PC con Ubuntu 20.04+ | Ubuntu 20.04 / 22.04 / 24.04 | ✅ Compatible |

---

## FAQ — Preguntas frecuentes

### ¿Por qué no arrancan los contenedores después de reiniciar?

**Causa más común:** el disco NAS no estaba conectado cuando arrancó el sistema. El servicio `immich.service` depende del montaje del disco y falla si este no está disponible.

**Solución:**
```bash
sudo mount /mnt/nas          # Monta el disco
sudo systemctl start immich  # Inicia Immich
```

Para evitarlo: conecta el disco NAS **antes** de encender el equipo.

---

### El formateo del disco falla con "Error de entrada/salida"

**Causa:** algunos enclosures USB-NVMe (especialmente con el chipset Realtek RTL9210B) no soportan correctamente el cierre del sistema de archivos estándar.

**Solución:** el script ya usa los parámetros correctos para este hardware (`lazy_itable_init=0,lazy_journal_init=0`). Si el error persiste:
```bash
sudo sync && sudo blockdev --flushbufs /dev/sdb && sleep 3
sudo mkfs.ext4 -F -E lazy_itable_init=0,lazy_journal_init=0 -L nas-data /dev/sdb1
```

---

### El contenedor de PostgreSQL no para de reiniciarse

**Causa más común:** el directorio de datos de PostgreSQL existe pero está corrupto o incompleto.

**Solución:**
```bash
cd /opt/immich
docker compose stop database
docker compose rm -f database
sudo find /mnt/nas/immich/postgres -mindepth 1 -delete
docker compose up -d database
```

---

### No puedo acceder a Immich desde fuera de mi red WiFi

**Verifica que:**
1. Tailscale esté instalado y conectado en **ambos** dispositivos (el NAS y tu teléfono)
2. Ambos usen la **misma cuenta** de Tailscale
3. La URL use la IP de Tailscale (100.x.x.x), no la IP local (192.168.x.x)

```bash
# Ver la IP de Tailscale del NAS
tailscale ip --4
```

---

### La app de Immich en Android no hace backup automático

**Causas frecuentes:**
- El teléfono no está conectado a WiFi (el backup solo funciona en WiFi si tienes datos móviles desactivados)
- El sistema operativo del Android está matando la app en segundo plano (común en Xiaomi, Huawei, Samsung con "optimización de batería")

**Solución:**
1. Ve a **Ajustes → Batería → Optimización** y excluye la app de Immich
2. En Xiaomi/MIUI: activa "Inicio automático" para Immich en la configuración de apps
3. Asegúrate de que el teléfono esté conectado a WiFi

---

### ¿Cómo actualizo Immich a la última versión?

```bash
cd /opt/immich
docker compose pull
sudo systemctl restart immich
```

> Consulta el [changelog de Immich](https://github.com/immich-app/immich/releases) antes de actualizar. Algunas versiones requieren migración de base de datos que puede tardar varios minutos.

---

### El backup falla con "No space left on device"

El disco del sistema no tiene suficiente espacio para el repositorio de restic.

**Verifica el espacio:**
```bash
df -h /var/backups/immich
```

**Opciones:**
- Usa un disco externo adicional como destino del backup
- Ejecuta `sudo restic -r /var/backups/immich --password-file /etc/restic-nas.password prune` para liberar espacio eliminando snapshots antiguos

> ⚠️ El script **nunca borra** snapshots automáticamente. Si ejecutas `prune` manualmente, los snapshots eliminados no podrán recuperarse.

---

### ¿Cómo restauro fotos desde el backup?

```bash
# Ver snapshots disponibles
sudo restic -r /var/backups/immich --password-file /etc/restic-nas.password snapshots

# Restaurar al directorio original (cuidado: sobreescribe)
sudo restic -r /var/backups/immich --password-file /etc/restic-nas.password \
    restore latest --target /

# Restaurar a un directorio temporal para revisión
sudo restic -r /var/backups/immich --password-file /etc/restic-nas.password \
    restore latest --target /tmp/restore-nas
```

---

### ¿Cómo agrego más dispositivos Android?

1. Entra a Immich web desde el navegador
2. Ve a **Administración → Usuarios → Nuevo usuario**
3. Crea una cuenta para cada dispositivo
4. En el teléfono nuevo: instala Immich + Tailscale, inicia sesión con la nueva cuenta

---

### ¿Qué pasa si el disco NAS se llena?

Immich detendrá la recepción de nuevos archivos pero no borrará los existentes. Recibirás un aviso en el health check semanal cuando el uso supere el 85%.

**Para liberar espacio:**
1. Desde la interfaz de Immich, revisa y elimina fotos duplicadas o no deseadas
2. Vacía la papelera de Immich (las fotos eliminadas van a papelera por defecto)
3. Considera agregar un segundo disco

---

## Licencia

MIT License — libre para uso personal y profesional.
