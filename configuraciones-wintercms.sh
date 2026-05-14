#!/usr/bin/env bash
set -euo pipefail

# Guia WinterCMS en KVM con despliegue progresivo.
# Uso:
#   bash configuraciones-wintercms.sh 1   # Apagar nodos Django actuales
#   bash configuraciones-wintercms.sh 2   # Configuracion de red (bloque separado)
#   bash configuraciones-wintercms.sh 3   # Configuracion MySQL cluster (bloque separado)
#   bash configuraciones-wintercms.sh 4   # Crear VM Winter 1
#   bash configuraciones-wintercms.sh 5   # Instalar WinterCMS limpio en VM Winter 1
#   bash configuraciones-wintercms.sh 6   # Crear VM Winter 2
#   bash configuraciones-wintercms.sh 7   # Instalar WinterCMS en VM Winter 2
#   bash configuraciones-wintercms.sh 8   # Crear VM Winter 3
#   bash configuraciones-wintercms.sh 9   # Instalar WinterCMS en VM Winter 3
#   bash configuraciones-wintercms.sh 10  # Validar cluster Winter
#   bash configuraciones-wintercms.sh 17  # Crear VM redis-1 (minima)
#   bash configuraciones-wintercms.sh 18  # Crear VMs redis-2..redis-7 (minimas)
#   bash configuraciones-wintercms.sh 19  # Instalar/ajustar Redis cluster en 7 nodos
#   bash configuraciones-wintercms.sh 20  # Bootstrap Redis cluster (7 nodos)
#   bash configuraciones-wintercms.sh 21  # Validar Redis cluster
#   bash configuraciones-wintercms.sh create-vms # Crear las 3 VMs Winter
#   bash configuraciones-wintercms.sh 15  # Borrar VMs Winter (destructivo)
#   bash configuraciones-wintercms.sh 16  # Mostrar comandos para crear VMs Winter
#   bash configuraciones-wintercms.sh all # Flujo completo (1 -> 14 + Redis 17 -> 21)

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE_VM_SCRIPT="${CREATE_VM_SCRIPT:-$BASE_DIR/create-kvm-vm.sh}"
KEY="${KEY_OVERRIDE:-$BASE_DIR/ssh-keys/id_rsa}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8}"

SSH_USER="${SSH_USER:-userinfrakv}"
VM_PASSWORD="${VM_PASSWORD:-passphrase2620-07}"

WAIT_SSH_RETRIES="${WAIT_SSH_RETRIES:-80}"
WAIT_SSH_SLEEP="${WAIT_SSH_SLEEP:-5}"

WINTER_VM1="${WINTER_VM1:-appWinter1}"
WINTER_VM2="${WINTER_VM2:-appWinter2}"
WINTER_VM3="${WINTER_VM3:-appWinter3}"

WINTER_IP1="${WINTER_IP1:-192.168.20.10}"
WINTER_IP2="${WINTER_IP2:-192.168.20.11}"
WINTER_IP3="${WINTER_IP3:-192.168.20.12}"
WINTER_NODES=("$WINTER_IP1" "$WINTER_IP2" "$WINTER_IP3")

LB1_IP="${LB1_IP:-192.168.10.20}"
LB2_IP="${LB2_IP:-192.168.10.21}"
LB_NODES=("$LB1_IP" "$LB2_IP")

NETWORK_BACKEND="${NETWORK_BACKEND:-red-backend}"
NETWORK_DB="${NETWORK_DB:-red-db-redis}"

APP_USER="${APP_USER:-winter}"
APP_GROUP="${APP_GROUP:-winter}"
APP_BASE_DIR="${APP_BASE_DIR:-/opt/apps}"
PROJECT_DIR="${PROJECT_DIR:-/opt/apps/wintercms}"
APP_URL_1="${APP_URL_1:-http://app1.ti.mimas.net}"
APP_URL_2="${APP_URL_2:-http://app2.ti.mimas.net}"
APP_URL_3="${APP_URL_3:-http://app3.ti.mimas.net}"

# Bloque MySQL separado: apuntamos al cluster existente por MaxScale.
DB_HOST="${DB_HOST:-192.168.30.20}"
DB_PORT="${DB_PORT:-4008}"
DB_NAME="${DB_NAME:-appdb}"
DB_USER="${DB_USER:-appuser}"
DB_PASSWORD="${DB_PASSWORD:-app-pass-2620}"
DB_ADMIN_NODE="${DB_ADMIN_NODE:-192.168.30.21}"
AUTO_FIX_DB_GRANTS="${AUTO_FIX_DB_GRANTS:-true}"

REDIS_HOST="${REDIS_HOST:-192.168.30.10}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_DB="${REDIS_DB:-0}"
REDIS_USER="${REDIS_USER:-}"
REDIS_USERNAME="${REDIS_USERNAME:-$REDIS_USER}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
REDIS_PREFIX="${REDIS_PREFIX:-{k3}_}"

REDIS_VM1="${REDIS_VM1:-redis-1}"
REDIS_VM2="${REDIS_VM2:-redis-2}"
REDIS_VM3="${REDIS_VM3:-redis-3}"
REDIS_VM4="${REDIS_VM4:-redis-4}"
REDIS_VM5="${REDIS_VM5:-redis-5}"
REDIS_VM6="${REDIS_VM6:-redis-6}"
REDIS_VM7="${REDIS_VM7:-redis-7}"

REDIS_IP1="${REDIS_IP1:-192.168.30.10}"
REDIS_IP2="${REDIS_IP2:-192.168.30.11}"
REDIS_IP3="${REDIS_IP3:-192.168.30.12}"
REDIS_IP4="${REDIS_IP4:-192.168.30.13}"
REDIS_IP5="${REDIS_IP5:-192.168.30.14}"
REDIS_IP6="${REDIS_IP6:-192.168.30.15}"
REDIS_IP7="${REDIS_IP7:-192.168.30.16}"

REDIS_CLUSTER_NODES=(
  "$REDIS_IP1:$REDIS_PORT"
  "$REDIS_IP2:$REDIS_PORT"
  "$REDIS_IP3:$REDIS_PORT"
  "$REDIS_IP4:$REDIS_PORT"
  "$REDIS_IP5:$REDIS_PORT"
  "$REDIS_IP6:$REDIS_PORT"
  "$REDIS_IP7:$REDIS_PORT"
)

REDIS_CLUSTER_NODES_CSV="${REDIS_CLUSTER_NODES_CSV:-$REDIS_IP1:$REDIS_PORT,$REDIS_IP2:$REDIS_PORT,$REDIS_IP3:$REDIS_PORT,$REDIS_IP4:$REDIS_PORT,$REDIS_IP5:$REDIS_PORT,$REDIS_IP6:$REDIS_PORT,$REDIS_IP7:$REDIS_PORT}"

# Se usa para pruebas HTTP locales en las VMs.
HOST_HEADER_1="${HOST_HEADER_1:-app1.ti.mimas.net}"
HOST_HEADER_2="${HOST_HEADER_2:-app2.ti.mimas.net}"
HOST_HEADER_3="${HOST_HEADER_3:-app3.ti.mimas.net}"
WINTER_LB_HOSTS="${WINTER_LB_HOSTS:-app1.ti.mimas.net app2.ti.mimas.net app3.ti.mimas.net www.ti.mimas.net api.ti.mimas.net}"

EXTRA_HOSTS="${EXTRA_HOSTS:-192.168.10.10 ns1.mimas.net dns-principal;192.168.10.11 ns1.ti.mimas.net dns-delegado;192.168.10.20 lb1.ti.mimas.net lb1;192.168.10.21 lb2.ti.mimas.net lb2;192.168.20.10 winter1.ti.mimas.net appWinter1;192.168.20.11 winter2.ti.mimas.net appWinter2;192.168.20.12 winter3.ti.mimas.net appWinter3;192.168.30.20 db.ti.mimas.net maxscale-1;192.168.30.10 redis.ti.mimas.net redis-1;192.168.30.10 redis1.ti.mimas.net redis-1;192.168.30.11 redis2.ti.mimas.net redis-2;192.168.30.12 redis3.ti.mimas.net redis-3;192.168.30.13 redis4.ti.mimas.net redis-4;192.168.30.14 redis5.ti.mimas.net redis-5;192.168.30.15 redis6.ti.mimas.net redis-6;192.168.30.16 redis7.ti.mimas.net redis-7}"

if [[ ! -x "$CREATE_VM_SCRIPT" ]]; then
  echo "[ERROR] No se encontro script ejecutable: $CREATE_VM_SCRIPT"
  exit 1
fi

if [[ ! -r "$KEY" ]]; then
  echo "[ERROR] No se puede leer la clave SSH: $KEY"
  exit 1
fi

ssh_cmd() {
  local ip="$1"
  shift
  ssh -i "$KEY" $SSH_OPTS "${SSH_USER}@${ip}" "$@"
}

wait_for_ssh_node() {
  local ip="$1"
  local attempt=1

  while (( attempt <= WAIT_SSH_RETRIES )); do
    if ssh -i "$KEY" $SSH_OPTS "${SSH_USER}@${ip}" "echo ready" >/dev/null 2>&1; then
      echo "[OK] SSH listo en $ip"
      return 0
    fi

    echo "[INFO] Esperando SSH en $ip (intento ${attempt}/${WAIT_SSH_RETRIES})"
    sleep "$WAIT_SSH_SLEEP"
    attempt=$((attempt + 1))
  done

  echo "[ERROR] SSH no estuvo listo en $ip"
  return 1
}

apply_winter_runtime_permissions() {
  local ip="$1"

  wait_for_ssh_node "$ip"
  ssh_cmd "$ip" "APP_USER='$APP_USER' PROJECT_DIR='$PROJECT_DIR' sudo -E bash -s" <<'REMOTE'
set -euo pipefail

install -d -m 775 -o "$APP_USER" -g www-data "$PROJECT_DIR/storage"
install -d -m 775 -o "$APP_USER" -g www-data "$PROJECT_DIR/storage/logs"
install -d -m 775 -o "$APP_USER" -g www-data "$PROJECT_DIR/storage/framework"
install -d -m 775 -o "$APP_USER" -g www-data "$PROJECT_DIR/bootstrap/cache"
install -d -m 775 -o "$APP_USER" -g www-data "$PROJECT_DIR/themes"

chown -R "$APP_USER":www-data "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache" "$PROJECT_DIR/themes"
chmod -R ug+rwX "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache" "$PROJECT_DIR/themes"
find "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache" "$PROJECT_DIR/themes" -type d -exec chmod 2775 {} +
find "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache" "$PROJECT_DIR/themes" -type f -exec chmod 664 {} +

if [[ -f "$PROJECT_DIR/.env" ]]; then
  chown "$APP_USER":www-data "$PROJECT_DIR/.env"
  chmod 640 "$PROJECT_DIR/.env"
fi

chgrp -R www-data "$PROJECT_DIR"
find "$PROJECT_DIR" -type d -exec chmod o+rx {} +
find "$PROJECT_DIR" -type f -exec chmod o+r {} +
chmod +x "$PROJECT_DIR/artisan" 2>/dev/null || true
REMOTE
}

prepare_node_package_manager() {
  local ip="$1"
  ssh_cmd "$ip" "sudo bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

cloud-init status --wait >/dev/null 2>&1 || true

systemctl stop apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
pkill -9 apt apt-get unattended-upgrade 2>/dev/null || true
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
rm -f /var/lib/dpkg/updates/*
dpkg --configure -a || true
apt-get -y -f install || true
REMOTE
}

block_1_poweroff_django_nodes() {
  local vm
  for vm in appDjango1 appDjango2 appDjango3 app1 app2 app3; do
    if sudo virsh dominfo "$vm" >/dev/null 2>&1; then
      local state
      state="$(sudo virsh domstate "$vm" | tr -d '\r')"
      if [[ "$state" == "running" ]]; then
        echo "[INFO] Apagando VM Django activa: $vm"
        sudo virsh destroy "$vm"
      else
        echo "[INFO] VM Django ya estaba apagada: $vm"
      fi
    fi
  done

  echo "[OK] Nodos Django actuales apagados"
}

# Bloque de red separado para dejar explicitos los segmentos que usa WinterCMS.
block_2_network_cluster_settings() {
  echo "[INFO] Red backend apps: $NETWORK_BACKEND"
  echo "[INFO] Red datos DB: $NETWORK_DB"
  echo "[INFO] Verificando redes en libvirt"
  sudo virsh net-info "$NETWORK_BACKEND"
  sudo virsh net-info "$NETWORK_DB"

  echo "[OK] Bloque de red validado"
}

# Bloque MySQL separado: solo valida y prepara parametros de conexion contra MaxScale.
block_3_mysql_cluster_settings() {
  echo "[INFO] Cluster MySQL via MaxScale: $DB_HOST:$DB_PORT"
  echo "[INFO] Base de datos WinterCMS: $DB_NAME"
  echo "[INFO] Usuario de aplicacion: $DB_USER"
  echo "[INFO] Redis sesiones: $REDIS_HOST:$REDIS_PORT db=$REDIS_DB"
  echo "[INFO] Redis prefix (hash-tag fijo): $REDIS_PREFIX"
  if [[ -z "$REDIS_PASSWORD" ]]; then
    echo "[INFO] Redis password: vacio (sin AUTH)"
  else
    echo "[INFO] Redis password: configurado"
  fi

  if [[ -z "$DB_PASSWORD" ]]; then
    echo "[ERROR] DB_PASSWORD vacio"
    exit 1
  fi

  if [[ -z "$REDIS_HOST" || -z "$REDIS_PORT" ]]; then
    echo "[ERROR] Configuracion Redis incompleta"
    exit 1
  fi

  if [[ "$AUTO_FIX_DB_GRANTS" == "true" ]]; then
    echo "[INFO] Asegurando grants SQL para nodos Winter (opcional)"
    if ! ssh_cmd "$DB_ADMIN_NODE" "DB_USER='$DB_USER' DB_PASSWORD='$DB_PASSWORD' DB_NAME='$DB_NAME' sudo -E bash -s" <<'REMOTE'
set -euo pipefail
sudo mariadb -e "
CREATE USER IF NOT EXISTS '${DB_USER}'@'192.168.30.%' IDENTIFIED BY '${DB_PASSWORD}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'192.168.20.%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'192.168.30.%';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'192.168.20.%';
FLUSH PRIVILEGES;
"
REMOTE
    then
      echo "[WARN] No se pudieron aplicar grants automaticamente; continuaras con los grants existentes"
    else
      echo "[OK] Grants SQL verificados/aplicados para ${DB_USER}"
    fi
  fi

  echo "[OK] Bloque MySQL validado"
}

create_winter_vm() {
  local vm_name="$1"
  local vm_hostname="$2"
  local ip_backend="$3"
  local ip_db_iface="$4"

  echo "[INFO] Creando $vm_name ($vm_hostname)"
  bash "$CREATE_VM_SCRIPT" \
    --name "$vm_name" \
    --hostname "$vm_hostname" \
    --user "$SSH_USER" \
    --password "$VM_PASSWORD" \
    --ram 1536 \
    --vcpus 2 \
    --system-disk 15 \
    --data-disk 0 \
    --libvirt-nets "$NETWORK_BACKEND;$NETWORK_DB" \
    --ifaces "enp1s0,${ip_backend}/24,192.168.20.1,192.168.10.10,8.8.8.8;enp2s0,${ip_db_iface}/24,,192.168.10.10,8.8.8.8" \
    --extra-hosts "$EXTRA_HOSTS"
}

block_4_create_vm1() {
  create_winter_vm "$WINTER_VM1" "winter1.ti.mimas.net" "$WINTER_IP1" "192.168.30.30"
  wait_for_ssh_node "$WINTER_IP1"
}

block_6_create_vm2() {
  create_winter_vm "$WINTER_VM2" "winter2.ti.mimas.net" "$WINTER_IP2" "192.168.30.31"
  wait_for_ssh_node "$WINTER_IP2"
}

block_8_create_vm3() {
  create_winter_vm "$WINTER_VM3" "winter3.ti.mimas.net" "$WINTER_IP3" "192.168.30.32"
  wait_for_ssh_node "$WINTER_IP3"
}

block_create_vms() {
  block_4_create_vm1
  block_6_create_vm2
  block_8_create_vm3
  echo "[OK] Las 3 VMs Winter fueron creadas/procesadas"
}

create_redis_vm() {
  local vm_name="$1"
  local vm_hostname="$2"
  local ip_db_iface="$3"

  echo "[INFO] Creando $vm_name ($vm_hostname)"
  bash "$CREATE_VM_SCRIPT" \
    --name "$vm_name" \
    --hostname "$vm_hostname" \
    --user "$SSH_USER" \
    --password "$VM_PASSWORD" \
    --ram 512 \
    --vcpus 1 \
    --system-disk 8 \
    --data-disk 0 \
    --libvirt-nets "$NETWORK_DB" \
    --ifaces "enp1s0,${ip_db_iface}/24,192.168.30.1,192.168.10.10,8.8.8.8" \
    --extra-hosts "$EXTRA_HOSTS"
}

configure_redis_node() {
  local ip="$1"

  wait_for_ssh_node "$ip"
  prepare_node_package_manager "$ip"

  ssh_cmd "$ip" "REDIS_BIND_IP='$ip' REDIS_PORT='$REDIS_PORT' REDIS_PASSWORD='$REDIS_PASSWORD' sudo -E bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends redis-server redis-tools

if [[ ! -f /etc/redis/redis.conf ]]; then
  echo "[ERROR] No existe /etc/redis/redis.conf"
  exit 1
fi

sed -i -E "s/^bind .*/bind 0.0.0.0/" /etc/redis/redis.conf
sed -i -E "s/^#?port .*/port ${REDIS_PORT}/" /etc/redis/redis.conf
sed -i -E "s/^#?protected-mode .*/protected-mode yes/" /etc/redis/redis.conf
sed -i -E "s/^#?cluster-enabled .*/cluster-enabled yes/" /etc/redis/redis.conf
sed -i -E "s|^#?cluster-config-file .*|cluster-config-file /var/lib/redis/nodes.conf|" /etc/redis/redis.conf
sed -i -E "s/^#?cluster-node-timeout .*/cluster-node-timeout 5000/" /etc/redis/redis.conf
sed -i -E "s/^#?appendonly .*/appendonly yes/" /etc/redis/redis.conf

if [[ -n "$REDIS_PASSWORD" ]]; then
  if grep -q '^requirepass ' /etc/redis/redis.conf; then
    sed -i -E "s|^requirepass .*|requirepass ${REDIS_PASSWORD}|" /etc/redis/redis.conf
  else
    printf '\nrequirepass %s\n' "$REDIS_PASSWORD" >> /etc/redis/redis.conf
  fi

  if grep -q '^masterauth ' /etc/redis/redis.conf; then
    sed -i -E "s|^masterauth .*|masterauth ${REDIS_PASSWORD}|" /etc/redis/redis.conf
  else
    printf 'masterauth %s\n' "$REDIS_PASSWORD" >> /etc/redis/redis.conf
  fi
else
  sed -i -E '/^requirepass /d' /etc/redis/redis.conf
  sed -i -E '/^masterauth /d' /etc/redis/redis.conf
fi

install -d -m 750 -o redis -g redis /var/lib/redis
chown redis:redis /var/lib/redis

systemctl enable redis-server
systemctl restart redis-server
systemctl is-active redis-server

ss -ltnp | grep ":${REDIS_PORT} " || true
REMOTE
}

block_17_create_redis_vm1() {
  create_redis_vm "$REDIS_VM1" "redis1.ti.mimas.net" "$REDIS_IP1"
  wait_for_ssh_node "$REDIS_IP1"
  echo "[OK] VM Redis 1 lista ($REDIS_IP1)"
}

block_18_create_redis_vm2_to_7() {
  create_redis_vm "$REDIS_VM2" "redis2.ti.mimas.net" "$REDIS_IP2"
  create_redis_vm "$REDIS_VM3" "redis3.ti.mimas.net" "$REDIS_IP3"
  create_redis_vm "$REDIS_VM4" "redis4.ti.mimas.net" "$REDIS_IP4"
  create_redis_vm "$REDIS_VM5" "redis5.ti.mimas.net" "$REDIS_IP5"
  create_redis_vm "$REDIS_VM6" "redis6.ti.mimas.net" "$REDIS_IP6"
  create_redis_vm "$REDIS_VM7" "redis7.ti.mimas.net" "$REDIS_IP7"

  wait_for_ssh_node "$REDIS_IP2"
  wait_for_ssh_node "$REDIS_IP3"
  wait_for_ssh_node "$REDIS_IP4"
  wait_for_ssh_node "$REDIS_IP5"
  wait_for_ssh_node "$REDIS_IP6"
  wait_for_ssh_node "$REDIS_IP7"
  echo "[OK] VMs Redis 2..7 listas"
}

block_19_install_redis_cluster_nodes() {
  configure_redis_node "$REDIS_IP1"
  configure_redis_node "$REDIS_IP2"
  configure_redis_node "$REDIS_IP3"
  configure_redis_node "$REDIS_IP4"
  configure_redis_node "$REDIS_IP5"
  configure_redis_node "$REDIS_IP6"
  configure_redis_node "$REDIS_IP7"
  echo "[OK] Redis instalado/configurado en los 7 nodos"
}

block_20_bootstrap_redis_cluster() {
  local nodes_csv
  nodes_csv="${REDIS_CLUSTER_NODES[*]}"

  wait_for_ssh_node "$REDIS_IP1"
  ssh_cmd "$REDIS_IP1" "REDIS_PASSWORD='$REDIS_PASSWORD' REDIS_PORT='$REDIS_PORT' NODES='$nodes_csv' sudo -E bash -s" <<'REMOTE'
set -euo pipefail

read -r -a NODES_ARR <<< "$NODES"

if [[ -n "$REDIS_PASSWORD" ]]; then
  if redis-cli -h 127.0.0.1 -p "$REDIS_PORT" -a "$REDIS_PASSWORD" cluster info 2>/dev/null | grep -q 'cluster_state:ok'; then
    echo "[INFO] Cluster Redis ya estaba inicializado"
    exit 0
  fi
  yes yes | redis-cli --cluster create "${NODES_ARR[@]}" --cluster-replicas 1 -a "$REDIS_PASSWORD"
else
  if redis-cli -h 127.0.0.1 -p "$REDIS_PORT" cluster info 2>/dev/null | grep -q 'cluster_state:ok'; then
    echo "[INFO] Cluster Redis ya estaba inicializado"
    exit 0
  fi
  yes yes | redis-cli --cluster create "${NODES_ARR[@]}" --cluster-replicas 1
fi
REMOTE

  echo "[OK] Bootstrap de cluster Redis completado"
}

block_21_validate_redis_cluster() {
  wait_for_ssh_node "$REDIS_IP1"

  if [[ -n "$REDIS_PASSWORD" ]]; then
    ssh_cmd "$REDIS_IP1" "REDIS_PASSWORD='$REDIS_PASSWORD' REDIS_PORT='$REDIS_PORT' sudo -E bash -s" <<'REMOTE'
set -euo pipefail
redis-cli -h 127.0.0.1 -p "$REDIS_PORT" -a "$REDIS_PASSWORD" cluster info | grep -E 'cluster_state:ok|cluster_known_nodes:7'
redis-cli -h 127.0.0.1 -p "$REDIS_PORT" -a "$REDIS_PASSWORD" cluster nodes | wc -l
REMOTE
  else
    ssh_cmd "$REDIS_IP1" "REDIS_PORT='$REDIS_PORT' sudo -E bash -s" <<'REMOTE'
set -euo pipefail
redis-cli -h 127.0.0.1 -p "$REDIS_PORT" cluster info | grep -E 'cluster_state:ok|cluster_known_nodes:7'
redis-cli -h 127.0.0.1 -p "$REDIS_PORT" cluster nodes | wc -l
REMOTE
  fi

  echo "[OK] Cluster Redis validado (7 nodos)"
}

install_wintercms_node() {
  local ip="$1"
  local app_url="$2"
  local host_header="$3"

  wait_for_ssh_node "$ip"
  prepare_node_package_manager "$ip"

  ssh_cmd "$ip" "APP_USER='$APP_USER' APP_GROUP='$APP_GROUP' APP_BASE_DIR='$APP_BASE_DIR' PROJECT_DIR='$PROJECT_DIR' APP_URL='$app_url' DB_HOST='$DB_HOST' DB_PORT='$DB_PORT' DB_NAME='$DB_NAME' DB_USER='$DB_USER' DB_PASSWORD='$DB_PASSWORD' REDIS_HOST='$REDIS_HOST' REDIS_PORT='$REDIS_PORT' REDIS_DB='$REDIS_DB' REDIS_USERNAME='$REDIS_USERNAME' REDIS_PASSWORD='$REDIS_PASSWORD' REDIS_CLUSTER_NODES_CSV='$REDIS_CLUSTER_NODES_CSV' HOST_HEADER='$host_header' sudo -E bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  nginx \
  php-fpm php-cli php-common php-mysql php-sqlite3 php-curl php-xml php-mbstring php-zip php-gd php-intl php-bcmath \
  php-redis \
  curl unzip git composer mariadb-client redis-tools

systemctl enable nginx || true
systemctl stop nginx 2>/dev/null || true

id -u "$APP_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$APP_USER"
mkdir -p "$APP_BASE_DIR"
chown -R "$APP_USER":"$APP_GROUP" "$APP_BASE_DIR"

if [[ ! -f "$PROJECT_DIR/artisan" ]]; then
  sudo -u "$APP_USER" env COMPOSER_MEMORY_LIMIT=-1 composer create-project --no-interaction --no-scripts wintercms/winter "$PROJECT_DIR"
fi

if [[ ! -f "$PROJECT_DIR/.env" ]]; then
  cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
fi

if [[ ! -f "$PROJECT_DIR/vendor/autoload.php" ]]; then
  sudo -u "$APP_USER" env COMPOSER_MEMORY_LIMIT=-1 bash -lc "cd '$PROJECT_DIR' && composer install --no-interaction --no-dev --optimize-autoloader"
fi

upsert_env() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$PROJECT_DIR/.env"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$PROJECT_DIR/.env"
  else
    printf '%s=%s\n' "$key" "$value" >> "$PROJECT_DIR/.env"
  fi
}

upsert_env APP_URL "$APP_URL"
upsert_env DB_CONNECTION "mysql"
upsert_env DB_HOST "$DB_HOST"
upsert_env DB_PORT "$DB_PORT"
upsert_env DB_DATABASE "$DB_NAME"
upsert_env DB_USERNAME "$DB_USER"
upsert_env DB_PASSWORD "$DB_PASSWORD"
upsert_env SESSION_DRIVER "redis"
upsert_env SESSION_CONNECTION "default"
upsert_env SESSION_LIFETIME "120"
upsert_env SESSION_SECURE_COOKIE "false"
upsert_env SESSION_DOMAIN "$HOST_HEADER"
upsert_env CACHE_DRIVER "redis"
upsert_env QUEUE_CONNECTION "database"
upsert_env REDIS_CLIENT "phpredis"
upsert_env REDIS_CLUSTER "redis"
upsert_env REDIS_HOST "$REDIS_HOST"
upsert_env REDIS_PASSWORD "$REDIS_PASSWORD"
upsert_env REDIS_PORT "$REDIS_PORT"
upsert_env REDIS_DB "$REDIS_DB"
upsert_env REDIS_CACHE_DB "2"
upsert_env REDIS_PREFIX "$REDIS_PREFIX"
upsert_env REDIS_CLUSTER_NODES "$REDIS_CLUSTER_NODES_CSV"
if [[ -n "$REDIS_USERNAME" ]]; then
  upsert_env REDIS_USERNAME "$REDIS_USERNAME"
fi

if [[ -z "$REDIS_PASSWORD" ]]; then
  upsert_env REDIS_PASSWORD ""
fi

chown "$APP_USER":"$APP_GROUP" "$PROJECT_DIR/.env"
chmod 640 "$PROJECT_DIR/.env"

chown -R "$APP_USER":www-data "$PROJECT_DIR"
find "$PROJECT_DIR" -type d -exec chmod 755 {} +
find "$PROJECT_DIR" -type f -exec chmod 644 {} +
chmod 640 "$PROJECT_DIR/.env"
chmod +x "$PROJECT_DIR/artisan"
install -d -m 775 -o "$APP_USER" -g www-data "$PROJECT_DIR/storage"
install -d -m 775 -o "$APP_USER" -g www-data "$PROJECT_DIR/storage/logs"
install -d -m 775 -o "$APP_USER" -g www-data "$PROJECT_DIR/storage/framework"
install -d -m 775 -o "$APP_USER" -g www-data "$PROJECT_DIR/bootstrap/cache"
install -d -m 775 -o "$APP_USER" -g www-data "$PROJECT_DIR/themes"
chown -R "$APP_USER":www-data "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache" "$PROJECT_DIR/themes"
chmod -R ug+rwX "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache" "$PROJECT_DIR/themes"
find "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache" "$PROJECT_DIR/themes" -type d -exec chmod 2775 {} +
find "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache" "$PROJECT_DIR/themes" -type f -exec chmod 664 {} +

sudo -u "$APP_USER" bash -lc "cd '$PROJECT_DIR' && php artisan key:generate --force"
sudo -u "$APP_USER" bash -lc "cd '$PROJECT_DIR' && php artisan optimize:clear" || true
sudo -u "$APP_USER" bash -lc "cd '$PROJECT_DIR' && php artisan cache:clear" || true
sudo -u "$APP_USER" bash -lc "cd '$PROJECT_DIR' && php artisan config:clear" || true
sudo -u "$APP_USER" bash -lc "cd '$PROJECT_DIR' && php artisan route:clear" || true
sudo -u "$APP_USER" bash -lc "cd '$PROJECT_DIR' && php artisan view:clear" || true
sudo -u "$APP_USER" bash -lc "cd '$PROJECT_DIR' && php artisan package:discover --ansi"
sudo -u "$APP_USER" bash -lc "cd '$PROJECT_DIR' && php artisan winter:up"

MYSQL_PWD="$DB_PASSWORD" mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME" -e 'select 1' >/dev/null

if [[ -n "$REDIS_PASSWORD" ]]; then
  if redis_out="$(redis-cli -c -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" ping 2>&1 || true)"; then
    :
  fi
  if echo "$redis_out" | grep -qi '^PONG$'; then
    :
  elif echo "$redis_out" | grep -qi 'AUTH .*without any password configured'; then
    echo "[WARN] Redis no requiere password; ajustando .env con REDIS_PASSWORD vacio"
    upsert_env REDIS_PASSWORD ""
  else
    echo "[ERROR] Redis ping fallo: $redis_out"
    exit 1
  fi
else
  redis-cli -c -h "$REDIS_HOST" -p "$REDIS_PORT" ping | grep -qi '^PONG$'
fi

PHP_FPM_SOCK="$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n 1 || true)"
if [[ -z "$PHP_FPM_SOCK" ]]; then
  echo "[ERROR] No se encontro socket php-fpm en /run/php"
  exit 1
fi

cat >/etc/nginx/sites-available/wintercms.conf <<EOF2
server {
    listen 80;
    server_name _;
    root $PROJECT_DIR;

    index index.php index.html;

    location = / {
      try_files /index.html /index.php?\$query_string;
    }

    location / {
      try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
      fastcgi_pass unix:$PHP_FPM_SOCK;
      fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF2

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/wintercms.conf /etc/nginx/sites-enabled/wintercms.conf

while read -r fpm_svc _; do
  [[ -n "$fpm_svc" ]] && systemctl restart "$fpm_svc" 2>/dev/null || true
done < <(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null)
systemctl enable --now nginx
systemctl restart nginx

systemctl is-active nginx
curl -sS -H "Host: $HOST_HEADER" http://127.0.0.1/ >/dev/null || true
REMOTE
}

# Paso inicial solicitado: primero terminar instalacion limpia en una sola VM.
block_5_install_clean_vm1() {
  install_wintercms_node "$WINTER_IP1" "$APP_URL_1" "$HOST_HEADER_1"

  echo "[OK] Instalacion limpia de WinterCMS completada en VM1 ($WINTER_IP1)"
  echo "[INFO] Cuando este validada, ejecuta bloque 6 para crear VM2"
}

block_7_install_vm2() {
  install_wintercms_node "$WINTER_IP2" "$APP_URL_2" "$HOST_HEADER_2"
  echo "[OK] Instalacion de WinterCMS completada en VM2 ($WINTER_IP2)"
}

block_9_install_vm3() {
  install_wintercms_node "$WINTER_IP3" "$APP_URL_3" "$HOST_HEADER_3"
  echo "[OK] Instalacion de WinterCMS completada en VM3 ($WINTER_IP3)"
}

validate_winter_data_connectivity() {
  local ip="$1"

  ssh_cmd "$ip" "DB_HOST='$DB_HOST' DB_PORT='$DB_PORT' DB_NAME='$DB_NAME' DB_USER='$DB_USER' DB_PASSWORD='$DB_PASSWORD' REDIS_HOST='$REDIS_HOST' REDIS_PORT='$REDIS_PORT' REDIS_DB='$REDIS_DB' REDIS_PASSWORD='$REDIS_PASSWORD' PROJECT_DIR='$PROJECT_DIR' APP_USER='$APP_USER' sudo -E bash -s" <<'REMOTE'
set -euo pipefail

MYSQL_PWD="$DB_PASSWORD" mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME" -e 'select @@hostname, @@port, database()' >/dev/null

if [[ -n "$REDIS_PASSWORD" ]]; then
  redis_out="$(redis-cli -c -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" ping 2>&1 || true)"
  if echo "$redis_out" | grep -qi '^PONG$'; then
    :
  elif echo "$redis_out" | grep -qi 'AUTH .*without any password configured'; then
    sed -i 's|^REDIS_PASSWORD=.*|REDIS_PASSWORD=|' "$PROJECT_DIR/.env"
  else
    echo "[ERROR] Redis ping fallo: $redis_out"
    exit 1
  fi
else
  redis-cli -c -h "$REDIS_HOST" -p "$REDIS_PORT" ping | grep -qi '^PONG$'
fi
REMOTE

  echo "[OK] $ip conectado a MariaDB(MaxScale) y Redis"
}

validate_winter_node() {
  local ip="$1"
  local host_header="$2"

  echo "=== Validacion WinterCMS en $ip ==="
  ssh_cmd "$ip" "hostname -f || hostname"
  ssh_cmd "$ip" "systemctl is-active nginx"
  ssh_cmd "$ip" "sudo ss -ltnp | grep ':80' || true"
  ssh_cmd "$ip" "curl -sS --max-time 8 -H 'Host: $host_header' -o /dev/null -w '%{http_code}\n' http://127.0.0.1/"
}

block_10_validate_cluster() {
  validate_winter_node "$WINTER_IP1" "$HOST_HEADER_1"
  validate_winter_data_connectivity "$WINTER_IP1"

  if ssh -i "$KEY" $SSH_OPTS "${SSH_USER}@${WINTER_IP2}" "echo ready" >/dev/null 2>&1; then
    validate_winter_node "$WINTER_IP2" "$HOST_HEADER_2"
    validate_winter_data_connectivity "$WINTER_IP2"
  else
    echo "[WARN] VM2 no disponible, se omite validacion"
  fi

  if ssh -i "$KEY" $SSH_OPTS "${SSH_USER}@${WINTER_IP3}" "echo ready" >/dev/null 2>&1; then
    validate_winter_node "$WINTER_IP3" "$HOST_HEADER_3"
    validate_winter_data_connectivity "$WINTER_IP3"
  else
    echo "[WARN] VM3 no disponible, se omite validacion"
  fi

  echo "[OK] Validacion de WinterCMS finalizada"
}

publish_winter_homepage() {
  local ip="$1"
  local title="$2"

  wait_for_ssh_node "$ip"
  ssh_cmd "$ip" "PROJECT_DIR='$PROJECT_DIR' TITLE='$title' sudo -E bash -s" <<'REMOTE'
set -euo pipefail

cat >"$PROJECT_DIR/index.html" <<EOF2
<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$TITLE</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f4efe6;
      --ink: #1f2937;
      --accent: #ad5c2a;
      --panel: #fffaf4;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      font-family: Georgia, "Times New Roman", serif;
      background:
        radial-gradient(circle at top left, rgba(173, 92, 42, 0.18), transparent 30%),
        linear-gradient(135deg, var(--bg), #efe4d2 55%, #e8d7c1);
      color: var(--ink);
    }
    main {
      width: min(720px, calc(100vw - 48px));
      padding: 40px;
      border: 1px solid rgba(31, 41, 55, 0.12);
      background: var(--panel);
      box-shadow: 0 20px 60px rgba(31, 41, 55, 0.12);
    }
    h1 {
      margin: 0 0 12px;
      font-size: clamp(2rem, 4vw, 3.4rem);
      line-height: 0.95;
      letter-spacing: -0.04em;
    }
    p {
      margin: 0;
      font-size: 1.05rem;
      line-height: 1.7;
    }
    strong {
      color: var(--accent);
    }
  </style>
</head>
<body>
  <main>
    <h1>$TITLE</h1>
    <p><strong>WinterCMS</strong> esta operativo en este nodo del laboratorio KVM y responde correctamente en la raiz <strong>/</strong>.</p>
  </main>
</body>
</html>
EOF2

chown root:root "$PROJECT_DIR/index.html"
chmod 644 "$PROJECT_DIR/index.html"
REMOTE
}

block_11_publish_homepages() {
  publish_winter_homepage "$WINTER_IP1" "WinterCMS Nodo 1"
  publish_winter_homepage "$WINTER_IP2" "WinterCMS Nodo 2"
  publish_winter_homepage "$WINTER_IP3" "WinterCMS Nodo 3"
  echo "[OK] Portadas publicadas en los tres nodos Winter"
}

wait_for_all_lb_ssh() {
  local ip
  for ip in "${LB_NODES[@]}"; do
    wait_for_ssh_node "$ip"
  done
}

prepare_lb_package_manager() {
  local ip="$1"
  ssh_cmd "$ip" "sudo bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

cloud-init status --wait >/dev/null 2>&1 || true

systemctl stop apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
pkill -9 apt apt-get unattended-upgrade 2>/dev/null || true
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
rm -f /var/lib/dpkg/updates/*
dpkg --configure -a || true
apt-get -y -f install || true
REMOTE
}

block_12_configure_winter_lb() {
  wait_for_all_lb_ssh

  local lb_ip
  for lb_ip in "${LB_NODES[@]}"; do
    prepare_lb_package_manager "$lb_ip"
    ssh_cmd "$lb_ip" "APP1_IP='$WINTER_IP1' APP2_IP='$WINTER_IP2' APP3_IP='$WINTER_IP3' WINTER_LB_HOSTS='$WINTER_LB_HOSTS' sudo -E bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y nginx curl

cat >/etc/nginx/sites-available/wintercms-lb.conf <<EOF2
upstream winter_kvm_pool {
  ip_hash;
  server $APP1_IP:80 max_fails=3 fail_timeout=10s;
  server $APP2_IP:80 max_fails=3 fail_timeout=10s;
  server $APP3_IP:80 max_fails=3 fail_timeout=10s;
  keepalive 32;
}

server {
  listen 80 default_server;
  server_name $WINTER_LB_HOSTS;

  location / {
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 60s;
    proxy_connect_timeout 5s;
    proxy_pass http://winter_kvm_pool;
  }

  location /nginx-health {
    return 200 "ok\n";
    add_header Content-Type text/plain;
  }
}
EOF2

ln -sfn /etc/nginx/sites-available/wintercms-lb.conf /etc/nginx/sites-enabled/wintercms-lb.conf
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-enabled/django-lb.conf
nginx -t
systemctl enable --now nginx
systemctl restart nginx
REMOTE
  done

  echo "[OK] LBs configurados para WinterCMS"
}

block_13_validate_winter_lb() {
  wait_for_all_lb_ssh

  local lb_ip
  for lb_ip in "${LB_NODES[@]}"; do
    echo "=== LB Winter $lb_ip ==="
    ssh_cmd "$lb_ip" "systemctl is-active nginx"
    ssh_cmd "$lb_ip" "curl -fsS --max-time 5 http://127.0.0.1/nginx-health"
    ssh_cmd "$lb_ip" "for target in $WINTER_IP1 $WINTER_IP2 $WINTER_IP3; do code=000; for _ in 1 2 3; do code=\$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' http://\$target:80/ || true); [[ \"\$code\" != \"000\" ]] && break; done; [[ \"\$code\" != \"000\" ]] && echo \"[OK] backend \$target reachable (codigo \$code)\" || { echo \"[ERROR] backend \$target sin respuesta\"; exit 1; }; done"
  done

  local host
  for host in "$HOST_HEADER_1" "$HOST_HEADER_2" "$HOST_HEADER_3"; do
    for lb_ip in "${LB_NODES[@]}"; do
      code="000"
      for _ in 1 2 3; do
        code="$(curl -sS --max-time 10 -H "Host: $host" -o /dev/null -w '%{http_code}' "http://$lb_ip/" || true)"
        [[ "$code" != "000" ]] && break
      done
      [[ "$code" != "000" ]] && echo "[OK] $host via $lb_ip (codigo $code)" || { echo "[ERROR] $host via $lb_ip sin respuesta"; exit 1; }
    done
  done

  echo "[OK] Validacion de LB WinterCMS finalizada"
}

block_14_fix_runtime_permissions() {
  apply_winter_runtime_permissions "$WINTER_IP1"
  apply_winter_runtime_permissions "$WINTER_IP2"
  apply_winter_runtime_permissions "$WINTER_IP3"
  echo "[OK] Permisos de runtime corregidos en los tres nodos Winter"
}

block_15_delete_winter_vms() {
  local vm
  for vm in "$WINTER_VM1" "$WINTER_VM2" "$WINTER_VM3" winter1 winter2 winter3; do
    if sudo virsh dominfo "$vm" >/dev/null 2>&1; then
      local state
      state="$(sudo virsh domstate "$vm" | tr -d '\r')"
      if [[ "$state" == "running" ]]; then
        echo "[INFO] Deteniendo VM Winter activa: $vm"
        sudo virsh destroy "$vm"
      fi

      mapfile -t disk_paths < <(sudo virsh domblklist "$vm" | awk 'NR>2 {print $2}' | grep -E '^/' || true)
      sudo virsh undefine "$vm" --managed-save --snapshots-metadata || sudo virsh undefine "$vm"
      for disk in "${disk_paths[@]}"; do
        [[ -f "$disk" ]] && sudo rm -f "$disk"
      done
      echo "[OK] VM eliminada: $vm"
    fi
  done

  echo "[OK] Limpieza de VMs Winter finalizada"
  sudo virsh list --all | grep -E 'appWinter|winter[123]' || true
}

block_16_print_create_vm_commands() {
  cat <<EOF2
bash $CREATE_VM_SCRIPT \
  --name $WINTER_VM1 \
  --hostname winter1.ti.mimas.net \
  --user $SSH_USER \
  --password '$VM_PASSWORD' \
  --ram 1536 --vcpus 2 --system-disk 15 --data-disk 0 \
  --libvirt-nets '$NETWORK_BACKEND;$NETWORK_DB' \
  --ifaces 'enp1s0,$WINTER_IP1/24,192.168.20.1,192.168.10.10,8.8.8.8;enp2s0,192.168.30.30/24,,192.168.10.10,8.8.8.8' \
  --extra-hosts "$EXTRA_HOSTS"

bash $CREATE_VM_SCRIPT \
  --name $WINTER_VM2 \
  --hostname winter2.ti.mimas.net \
  --user $SSH_USER \
  --password '$VM_PASSWORD' \
  --ram 1536 --vcpus 2 --system-disk 15 --data-disk 0 \
  --libvirt-nets '$NETWORK_BACKEND;$NETWORK_DB' \
  --ifaces 'enp1s0,$WINTER_IP2/24,192.168.20.1,192.168.10.10,8.8.8.8;enp2s0,192.168.30.31/24,,192.168.10.10,8.8.8.8' \
  --extra-hosts "$EXTRA_HOSTS"

bash $CREATE_VM_SCRIPT \
  --name $WINTER_VM3 \
  --hostname winter3.ti.mimas.net \
  --user $SSH_USER \
  --password '$VM_PASSWORD' \
  --ram 1536 --vcpus 2 --system-disk 15 --data-disk 0 \
  --libvirt-nets '$NETWORK_BACKEND;$NETWORK_DB' \
  --ifaces 'enp1s0,$WINTER_IP3/24,192.168.20.1,192.168.10.10,8.8.8.8;enp2s0,192.168.30.32/24,,192.168.10.10,8.8.8.8' \
  --extra-hosts "$EXTRA_HOSTS"
EOF2
}

usage() {
  cat <<'EOF2'
Uso: bash configuraciones-wintercms.sh <bloque>

Bloques disponibles:
  1      Apagar nodos Django actuales
  2      Configurar/validar bloque de red WinterCMS
  3      Configurar/validar bloque MySQL cluster WinterCMS
  4      Crear VM Winter 1 (1.5 GB RAM, 15 GB disco)
  5      Instalacion limpia WinterCMS solo en VM1
  6      Crear VM Winter 2 (1.5 GB RAM, 15 GB disco)
  7      Instalar WinterCMS en VM2
  8      Crear VM Winter 3 (1.5 GB RAM, 15 GB disco)
  9      Instalar WinterCMS en VM3
  10     Validar nodos Winter activos
  17     Crear VM redis-1 (512MB RAM, 8GB disco)
  18     Crear VMs redis-2..redis-7 (512MB RAM, 8GB disco)
  19     Instalar Redis en los 7 nodos (cluster-enabled)
  20     Crear/arrancar cluster Redis de 7 nodos
  21     Validar cluster Redis (state ok + known_nodes=7)
  create-vms Crear/procesar las 3 VMs Winter
  11     Publicar portadas 200 en / para los tres nodos
  12     Configurar balanceadores para WinterCMS
  13     Validar WinterCMS via balanceadores
  14     Corregir permisos runtime (storage/bootstrap/themes/.env)
  15     BORRAR VMs Winter y discos (destructivo)
  16     Mostrar comandos para crear VMs Winter
  all    Ejecutar 1,2,3,17,18,19,20,21,4,5,6,7,8,9,10,11,12,13,14

Flujo recomendado:
  1 -> 2 -> 3
  17 -> 18 -> 19 -> 20 -> 21
  4 -> 5
  (validar VM1 limpia)
  6 -> 7
  8 -> 9
  10
  11 -> 12 -> 13
  14 si el backend muestra error de permisos
  15 al finalizar pruebas para limpiar Winter

Variables utiles para replicar:
  DB_ADMIN_NODE=192.168.30.21
  AUTO_FIX_DB_GRANTS=true|false
  APP_URL_1=http://app1.ti.mimas.net
  APP_URL_2=http://app2.ti.mimas.net
  APP_URL_3=http://app3.ti.mimas.net
  HOST_HEADER_1=app1.ti.mimas.net (idem _2, _3)
  REDIS_PREFIX={k3}_
EOF2
}

main() {
  local block="${1:-}"

  case "$block" in
    1) block_1_poweroff_django_nodes ;;
    2) block_2_network_cluster_settings ;;
    3) block_3_mysql_cluster_settings ;;
    4) block_4_create_vm1 ;;
    5) block_5_install_clean_vm1 ;;
    6) block_6_create_vm2 ;;
    7) block_7_install_vm2 ;;
    8) block_8_create_vm3 ;;
    9) block_9_install_vm3 ;;
    10) block_10_validate_cluster ;;
    17) block_17_create_redis_vm1 ;;
    18) block_18_create_redis_vm2_to_7 ;;
    19) block_19_install_redis_cluster_nodes ;;
    20) block_20_bootstrap_redis_cluster ;;
    21) block_21_validate_redis_cluster ;;
    create-vms) block_create_vms ;;
    11) block_11_publish_homepages ;;
    12) block_12_configure_winter_lb ;;
    13) block_13_validate_winter_lb ;;
    14) block_14_fix_runtime_permissions ;;
    15) block_15_delete_winter_vms ;;
    16) block_16_print_create_vm_commands ;;
    all)
      block_1_poweroff_django_nodes
      block_2_network_cluster_settings
      block_3_mysql_cluster_settings
      block_17_create_redis_vm1
      block_18_create_redis_vm2_to_7
      block_19_install_redis_cluster_nodes
      block_20_bootstrap_redis_cluster
      block_21_validate_redis_cluster
      block_4_create_vm1
      block_5_install_clean_vm1
      block_6_create_vm2
      block_7_install_vm2
      block_8_create_vm3
      block_9_install_vm3
      block_10_validate_cluster
      block_11_publish_homepages
      block_12_configure_winter_lb
      block_13_validate_winter_lb
      block_14_fix_runtime_permissions
      ;;
    create-vms-commands) block_16_print_create_vm_commands ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
