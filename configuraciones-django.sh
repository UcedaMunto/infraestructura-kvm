#!/usr/bin/env bash
set -euo pipefail

# Guia Django (SOLO Gunicorn en puerto 80, sin Nginx en app nodes).
# Uso:
#   bash configuraciones-django.sh 1   # BORRAR VMs Django (destructivo)
#   bash configuraciones-django.sh 2   # Esperar SSH en app nodes
#   bash configuraciones-django.sh 3   # Instalar runtime Python + dependencias
#   bash configuraciones-django.sh 8   # Copiar proyecto local (./django) a app nodes
#   bash configuraciones-django.sh 4   # Crear .env por nodo y ejecutar migraciones
#   bash configuraciones-django.sh 5   # Configurar Gunicorn systemd en puerto 80
#   bash configuraciones-django.sh 6   # Validar servicios HTTP
#   bash configuraciones-django.sh all # Ejecuta 2,3,4,5,6

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY="${KEY_OVERRIDE:-$BASE_DIR/ssh-keys/id_rsa}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8}"
SSH_USER="${SSH_USER:-userinfrakv}"
VM_PASSWORD="${VM_PASSWORD:-passphrase2620-07}"
CREATE_VM_SCRIPT="${CREATE_VM_SCRIPT:-$BASE_DIR/create-kvm-vm.sh}"
LOCAL_DJANGO_DIR="${LOCAL_DJANGO_DIR:-$BASE_DIR/django}"

WAIT_SSH_RETRIES="${WAIT_SSH_RETRIES:-80}"
WAIT_SSH_SLEEP="${WAIT_SSH_SLEEP:-5}"

APP_NODES=(192.168.20.10 192.168.20.11 192.168.20.12)

DB_HOST="${DB_HOST:-192.168.30.20}"
DB_PORT="${DB_PORT:-4008}"
DB_NAME="${DB_NAME:-appdb}"
DB_USER="${DB_USER:-appuser}"
DB_PASSWORD="${DB_PASSWORD:-app-pass-2620}"

REDIS_HOST="${REDIS_HOST:-192.168.30.10}"
REDIS_PORT="${REDIS_PORT:-6379}"

APP_USER="${APP_USER:-django}"
APP_GROUP="${APP_GROUP:-django}"
APP_BASE_DIR="${APP_BASE_DIR:-/opt/apps}"
VENV_DIR="${VENV_DIR:-/opt/apps/venv}"
PROJECT_DIR="${PROJECT_DIR:-/opt/apps/mi-proyecto}"
DJANGO_PROJECT_NAME="${DJANGO_PROJECT_NAME:-config}"
SERVICE_NAME="${SERVICE_NAME:-django-gunicorn.service}"

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

wait_for_all_apps_ssh() {
  local ip
  for ip in "${APP_NODES[@]}"; do
    wait_for_ssh_node "$ip"
  done
}

run_script_on_apps() {
  local payload
  payload="$(cat)"
  local ip
  for ip in "${APP_NODES[@]}"; do
    echo "[INFO] Ejecutando en $ip"
    ssh_cmd "$ip" "sudo bash -s" <<<"$payload"
  done
}

prepare_app_package_manager() {
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

copy_local_project_to_node() {
  local ip="$1"

  if [[ ! -f "$LOCAL_DJANGO_DIR/manage.py" ]]; then
    echo "[ERROR] No existe proyecto Django local en: $LOCAL_DJANGO_DIR"
    echo "[ERROR] Se esperaba: $LOCAL_DJANGO_DIR/manage.py"
    exit 1
  fi

  echo "[INFO] Copiando proyecto local desde $LOCAL_DJANGO_DIR hacia $ip:$PROJECT_DIR"
  tar \
    --exclude='.git' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='.venv*' \
    --exclude='db.sqlite3' \
    -czf - -C "$LOCAL_DJANGO_DIR" . \
    | ssh_cmd "$ip" "sudo mkdir -p '$PROJECT_DIR' && sudo tar xzf - -C '$PROJECT_DIR' && sudo chown -R '$APP_USER':'$APP_GROUP' '$PROJECT_DIR'"
}

block_create_vms() {
    if [[ ! -f "$CREATE_VM_SCRIPT" ]]; then
      echo "[ERROR] No se encontro: $CREATE_VM_SCRIPT"
      exit 1
    fi

    local extra="192.168.10.10 ns1.mimas.net dns-principal;192.168.10.11 ns1.ti.mimas.net dns-delegado;192.168.10.20 lb1.ti.mimas.net lb1;192.168.10.21 lb2.ti.mimas.net lb2;192.168.20.10 app1.ti.mimas.net appDjango1;192.168.20.11 app2.ti.mimas.net appDjango2;192.168.20.12 app3.ti.mimas.net appDjango3;192.168.30.20 db.ti.mimas.net maxscale-1"

    echo "[INFO] Creando appDjango1"
    bash "$CREATE_VM_SCRIPT" \
      --name appDjango1 \
      --hostname app1.ti.mimas.net \
      --user "$SSH_USER" \
      --password "$VM_PASSWORD" \
      --ram 4096 --vcpus 2 --system-disk 30 --data-disk 0 \
      --libvirt-nets "red-backend;red-db-redis" \
      --ifaces "enp1s0,192.168.20.10/24,192.168.20.1,192.168.10.10,8.8.8.8;enp2s0,192.168.30.30/24,,192.168.10.10,8.8.8.8" \
      --extra-hosts "$extra"

    echo "[INFO] Creando appDjango2"
    bash "$CREATE_VM_SCRIPT" \
      --name appDjango2 \
      --hostname app2.ti.mimas.net \
      --user "$SSH_USER" \
      --password "$VM_PASSWORD" \
      --ram 4096 --vcpus 2 --system-disk 30 --data-disk 0 \
      --libvirt-nets "red-backend;red-db-redis" \
      --ifaces "enp1s0,192.168.20.11/24,192.168.20.1,192.168.10.10,8.8.8.8;enp2s0,192.168.30.31/24,,192.168.10.10,8.8.8.8" \
      --extra-hosts "$extra"

    echo "[INFO] Creando appDjango3"
    bash "$CREATE_VM_SCRIPT" \
      --name appDjango3 \
      --hostname app3.ti.mimas.net \
      --user "$SSH_USER" \
      --password "$VM_PASSWORD" \
      --ram 4096 --vcpus 2 --system-disk 30 --data-disk 0 \
      --libvirt-nets "red-backend;red-db-redis" \
      --ifaces "enp1s0,192.168.20.12/24,192.168.20.1,192.168.10.10,8.8.8.8;enp2s0,192.168.30.32/24,,192.168.10.10,8.8.8.8" \
      --extra-hosts "$extra"

    echo "[OK] VMs Django creadas"
    sudo virsh list --all | grep -E 'appDjango' || true
    wait_for_all_apps_ssh
}

block_0_preflight_apps() {
  wait_for_all_apps_ssh

  local ip
  for ip in "${APP_NODES[@]}"; do
    echo "[INFO] Preflight cloud-init/apt en $ip"
    prepare_app_package_manager "$ip"
  done
}

block_1_delete_django_vms() {
  local vm
  for vm in appDjango1 appDjango2 appDjango3 app1 app2 app3; do
    if sudo virsh dominfo "$vm" >/dev/null 2>&1; then
      local state
      state="$(sudo virsh domstate "$vm" | tr -d '\r')"
      if [[ "$state" == "running" ]]; then
        sudo virsh destroy "$vm"
      fi

      mapfile -t disk_paths < <(sudo virsh domblklist "$vm" | awk 'NR>2 {print $2}' | grep -E '^/' || true)
      sudo virsh undefine "$vm" --managed-save --snapshots-metadata || sudo virsh undefine "$vm"
      for disk in "${disk_paths[@]}"; do
        [[ -f "$disk" ]] && sudo rm -f "$disk"
      done
    fi
  done

  echo "[OK] VMs Django eliminadas"
  sudo virsh list --all | grep -E 'appDjango|app[123]' || true
}

block_2_wait_ssh_apps() {
  wait_for_all_apps_ssh
}

block_3_install_runtime() {
  block_0_preflight_apps

  run_script_on_apps <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends python3-venv python3-pip python3-dev build-essential libmariadb-dev pkg-config git curl

# Las apps NO usan nginx local.
systemctl disable --now nginx 2>/dev/null || true
apt-get purge -y nginx nginx-common 2>/dev/null || true

id -u '$APP_USER' >/dev/null 2>&1 || useradd -m -s /bin/bash '$APP_USER'
mkdir -p '$APP_BASE_DIR'
chown -R '$APP_USER':'$APP_GROUP' '$APP_BASE_DIR'

if [[ ! -d '$VENV_DIR' ]]; then
  sudo -u '$APP_USER' python3 -m venv '$VENV_DIR'
fi
sudo -u '$APP_USER' '$VENV_DIR/bin/pip' install --upgrade pip wheel
sudo -u '$APP_USER' '$VENV_DIR/bin/pip' install gunicorn mysqlclient redis python-dotenv
REMOTE
}

block_8_sync_project() {
  wait_for_all_apps_ssh

  local ip
  for ip in "${APP_NODES[@]}"; do
    copy_local_project_to_node "$ip"
    ssh_cmd "$ip" "if [[ ! -f '$PROJECT_DIR/requirements.txt' ]]; then echo '[ERROR] No existe requirements.txt en $PROJECT_DIR'; exit 1; fi"
    ssh_cmd "$ip" "sudo -u '$APP_USER' '$VENV_DIR/bin/pip' install -r '$PROJECT_DIR/requirements.txt'"
    ssh_cmd "$ip" "sudo -u '$APP_USER' '$VENV_DIR/bin/pip' install gunicorn mysqlclient redis python-dotenv"
  done
}

block_4_config_django_settings() {
  wait_for_all_apps_ssh

  local ip
  for ip in "${APP_NODES[@]}"; do
    ssh_cmd "$ip" "sudo bash -s" <<REMOTE
set -euo pipefail

if [[ ! -f '$PROJECT_DIR/manage.py' ]]; then
  echo "[ERROR] No existe proyecto Django en $PROJECT_DIR"
  exit 1
fi

cat >'$PROJECT_DIR/.env' <<EOF2
DJANGO_DEBUG=False
DJANGO_SECRET_KEY=replace-this-with-real-secret
DJANGO_ALLOWED_HOSTS=django1.ti.mimas.net,django2.ti.mimas.net,django3.ti.mimas.net,lb1.ti.mimas.net,lb2.ti.mimas.net,app1.ti.mimas.net,app2.ti.mimas.net,app3.ti.mimas.net,192.168.10.20,192.168.10.21,192.168.20.10,192.168.20.11,192.168.20.12
DJANGO_COOP_POLICY=unsafe-none

SERVIDOR=$ip
servidor=$ip
SERVER=$ip

MYSQL_ENABLED=1
MYSQL_DATABASE=$DB_NAME
MYSQL_USER=$DB_USER
MYSQL_PASSWORD=$DB_PASSWORD
MYSQL_HOST=$DB_HOST
MYSQL_PORT=$DB_PORT

REDIS_ENABLED=1
REDIS_HOST=$REDIS_HOST
REDIS_PORT=$REDIS_PORT
EOF2

chown '$APP_USER':'$APP_GROUP' '$PROJECT_DIR/.env'
chmod 640 '$PROJECT_DIR/.env'

attempt=1
max_attempts=8
while (( attempt <= max_attempts )); do
  if sudo -u '$APP_USER' bash -lc "set -euo pipefail; cd '$PROJECT_DIR'; '$VENV_DIR/bin/python' manage.py migrate --noinput; '$VENV_DIR/bin/python' manage.py check"; then
    echo "[OK] Django migrate/check correcto"
    break
  fi

  if (( attempt == max_attempts )); then
    echo "[ERROR] Django migrate/check fallo tras \${max_attempts} intentos"
    exit 1
  fi

  echo "[WARN] Fallo transitorio DB/MaxScale (intento \${attempt}/\${max_attempts}), reintentando..."
  sleep 6
  attempt=\$((attempt + 1))
done
REMOTE
  done
}

block_5_configure_gunicorn_80() {
  wait_for_all_apps_ssh

  run_script_on_apps <<REMOTE
set -euo pipefail
cat >/etc/systemd/system/$SERVICE_NAME <<'EOF2'
[Unit]
Description=Gunicorn Django Service (Port 80)
After=network.target

[Service]
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$PROJECT_DIR
Environment=PATH=$VENV_DIR/bin
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=$VENV_DIR/bin/gunicorn --workers 3 --bind 0.0.0.0:80 $DJANGO_PROJECT_NAME.wsgi:application
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF2

systemctl daemon-reload
systemctl enable --now $SERVICE_NAME
systemctl restart $SERVICE_NAME
systemctl is-active $SERVICE_NAME
REMOTE
}

block_6_validate_apps() {
  wait_for_all_apps_ssh

  local ip
  for ip in "${APP_NODES[@]}"; do
    echo "=== $ip ==="
    ssh_cmd "$ip" "hostname -f || hostname"
    ssh_cmd "$ip" "systemctl is-active $SERVICE_NAME"
    ssh_cmd "$ip" "sudo ss -lntp | grep ':80' || true"
    ssh_cmd "$ip" "code=\$(curl -sS --max-time 5 -H 'Host: app1.ti.mimas.net' -o /dev/null -w '%{http_code}' http://127.0.0.1/ || true); if [[ \"\$code\" != \"000\" ]]; then echo \"[OK] HTTP local responde (codigo \$code)\"; else echo '[ERROR] HTTP local sin respuesta'; exit 1; fi"
    ssh_cmd "$ip" "sudo -u '$APP_USER' bash -lc 'cd $PROJECT_DIR && $VENV_DIR/bin/python manage.py check'"
  done
}

block_7_validate_db_from_apps() {
  wait_for_all_apps_ssh

  local ip
  for ip in "${APP_NODES[@]}"; do
    echo "=== Django -> MySQL desde $ip ==="
    ssh_cmd "$ip" "sudo -u '$APP_USER' '$VENV_DIR/bin/python' - <<'PY'
import MySQLdb

conn = MySQLdb.connect(
    host='${DB_HOST}',
    port=${DB_PORT},
    user='${DB_USER}',
    passwd='${DB_PASSWORD}',
    db='${DB_NAME}',
    connect_timeout=5,
)
cur = conn.cursor()
cur.execute('select @@hostname, @@port')
row = cur.fetchone()
print(f'[OK] conectado a {row[0]}:{row[1]} via MaxScale ${DB_HOST}:${DB_PORT}')
conn.close()
PY"
  done
}

usage() {
  cat <<'EOF2'
Uso: bash configuraciones-django.sh <bloque>

Bloques disponibles:
  0      Preflight app nodes (SSH + cloud-init + saneo apt/dpkg)
  1      BORRAR VMs Django y discos (destructivo)
  2      Esperar SSH en app nodes (creadas manualmente)
  3      Instalar runtime Python + dependencias Django (sin nginx)
  8      Copiar proyecto local (./django) a app nodes + pip -r requirements
  4      Crear .env por nodo y ejecutar migraciones
  5      Configurar Gunicorn systemd en puerto 80
  6      Validar estado final de app nodes
  7      Validar conectividad Django -> MySQL/MaxScale
  all    Ejecutar 0,2,3,8,4,5,6,7

Nota:
  create-vms  Crear VMs Django (appDjango1/2/3) automaticamente
  Este script gestiona la infraestructura Django completa.
EOF2
}

main() {
  local block="${1:-}"
  case "$block" in
    0) block_0_preflight_apps ;;
    1) block_1_delete_django_vms ;;
    2) block_2_wait_ssh_apps ;;
    3) block_3_install_runtime ;;
    8) block_8_sync_project ;;
    4) block_4_config_django_settings ;;
    5) block_5_configure_gunicorn_80 ;;
    6) block_6_validate_apps ;;
    7) block_7_validate_db_from_apps ;;
      create-vms) block_create_vms ;;
    all)
      block_0_preflight_apps
      block_2_wait_ssh_apps
      block_3_install_runtime
      block_8_sync_project
      block_4_config_django_settings
      block_5_configure_gunicorn_80
      block_6_validate_apps
      block_7_validate_db_from_apps
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
