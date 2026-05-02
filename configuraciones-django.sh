#!/usr/bin/env bash
set -euo pipefail

# Guia Django (SOLO Gunicorn en puerto 80, sin Nginx en app nodes).
# Uso:
#   bash configuraciones-django.sh 1   # BORRAR VMs Django (destructivo)
#   bash configuraciones-django.sh 2   # Esperar SSH en app nodes
#   bash configuraciones-django.sh 3   # Instalar runtime Python + proyecto
#   bash configuraciones-django.sh 4   # Configurar settings.py/.env y migraciones
#   bash configuraciones-django.sh 5   # Configurar Gunicorn systemd en puerto 80
#   bash configuraciones-django.sh 6   # Validar servicios HTTP
#   bash configuraciones-django.sh all # Ejecuta 2,3,4,5,6

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY="${KEY_OVERRIDE:-$BASE_DIR/ssh-keys/id_rsa}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8}"
SSH_USER="${SSH_USER:-userinfrakv}"

WAIT_SSH_RETRIES="${WAIT_SSH_RETRIES:-80}"
WAIT_SSH_SLEEP="${WAIT_SSH_SLEEP:-5}"

APP_NODES=(192.168.20.10 192.168.20.11 192.168.20.12)

DB_HOST="${DB_HOST:-192.168.30.20}"
DB_PORT="${DB_PORT:-3306}"
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
  wait_for_all_apps_ssh

  run_script_on_apps <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3-venv python3-pip python3-dev build-essential libmariadb-dev pkg-config git curl

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
sudo -u '$APP_USER' '$VENV_DIR/bin/pip' install django gunicorn mysqlclient redis python-dotenv

if [[ ! -f '$PROJECT_DIR/manage.py' ]]; then
  sudo -u '$APP_USER' mkdir -p '$PROJECT_DIR'
  sudo -u '$APP_USER' '$VENV_DIR/bin/django-admin' startproject '$DJANGO_PROJECT_NAME' '$PROJECT_DIR'
fi
REMOTE
}

block_4_config_django_settings() {
  wait_for_all_apps_ssh

  run_script_on_apps <<REMOTE
set -euo pipefail
cat >'$PROJECT_DIR/.env' <<'EOF2'
DJANGO_DEBUG=False
DJANGO_SECRET_KEY=replace-this-with-real-secret
DJANGO_ALLOWED_HOSTS=django1.ti.mimas.net,django2.ti.mimas.net,django3.ti.mimas.net,lb1.ti.mimas.net,lb2.ti.mimas.net,app1.ti.mimas.net,app2.ti.mimas.net,app3.ti.mimas.net,192.168.10.20,192.168.10.21,192.168.20.10,192.168.20.11,192.168.20.12
MYSQL_DATABASE=$DB_NAME
MYSQL_USER=$DB_USER
MYSQL_PASSWORD=$DB_PASSWORD
MYSQL_HOST=$DB_HOST
MYSQL_PORT=$DB_PORT
REDIS_HOST=$REDIS_HOST
REDIS_PORT=$REDIS_PORT
EOF2

cat >'$PROJECT_DIR/$DJANGO_PROJECT_NAME/settings.py' <<'EOF2'
import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent


def read_env(path):
    data = {}
    if not os.path.exists(path):
        return data
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            data[k.strip()] = v.strip()
    return data


ENV = read_env(BASE_DIR / ".env")

SECRET_KEY = ENV.get("DJANGO_SECRET_KEY", "replace-this-with-real-secret")
DEBUG = ENV.get("DJANGO_DEBUG", "False").lower() == "true"
ALLOWED_HOSTS = [h.strip() for h in ENV.get("DJANGO_ALLOWED_HOSTS", "").split(",") if h.strip()]

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "config.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "config.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.mysql",
        "NAME": ENV.get("MYSQL_DATABASE", "appdb"),
        "USER": ENV.get("MYSQL_USER", "appuser"),
        "PASSWORD": ENV.get("MYSQL_PASSWORD", "app-pass-2620"),
        "HOST": ENV.get("MYSQL_HOST", "192.168.30.20"),
        "PORT": ENV.get("MYSQL_PORT", "3306"),
        "OPTIONS": {"init_command": "SET sql_mode='STRICT_TRANS_TABLES'"},
    }
}

REDIS_HOST = ENV.get("REDIS_HOST", "192.168.30.10")
REDIS_PORT = ENV.get("REDIS_PORT", "6379")

LANGUAGE_CODE = "en-us"
TIME_ZONE = "America/El_Salvador"
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
EOF2

chown '$APP_USER':'$APP_GROUP' '$PROJECT_DIR/.env' '$PROJECT_DIR/$DJANGO_PROJECT_NAME/settings.py'
chmod 640 '$PROJECT_DIR/.env'

sudo -u '$APP_USER' bash -lc "set -euo pipefail; cd '$PROJECT_DIR'; '$VENV_DIR/bin/python' manage.py migrate --noinput; '$VENV_DIR/bin/python' manage.py check"
REMOTE
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
    ssh_cmd "$ip" "curl -fsS --max-time 5 http://127.0.0.1/ >/dev/null && echo '[OK] HTTP local responde'"
    ssh_cmd "$ip" "sudo -u '$APP_USER' bash -lc 'cd $PROJECT_DIR && $VENV_DIR/bin/python manage.py check'"
  done
}

usage() {
  cat <<'EOF2'
Uso: bash configuraciones-django.sh <bloque>

Bloques disponibles:
  1      BORRAR VMs Django y discos (destructivo)
  2      Esperar SSH en app nodes (creadas manualmente)
  3      Instalar runtime Python + proyecto Django (sin nginx)
  4      Configurar .env/settings y migraciones
  5      Configurar Gunicorn systemd en puerto 80
  6      Validar estado final de app nodes
  all    Ejecutar 2,3,4,5,6

Nota:
  Este script YA NO crea VMs Django. Debes crearlas manualmente antes del bloque 2.
EOF2
}

main() {
  local block="${1:-}"
  case "$block" in
    1) block_1_delete_django_vms ;;
    2) block_2_wait_ssh_apps ;;
    3) block_3_install_runtime ;;
    4) block_4_config_django_settings ;;
    5) block_5_configure_gunicorn_80 ;;
    6) block_6_validate_apps ;;
    all)
      block_2_wait_ssh_apps
      block_3_install_runtime
      block_4_config_django_settings
      block_5_configure_gunicorn_80
      block_6_validate_apps
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
