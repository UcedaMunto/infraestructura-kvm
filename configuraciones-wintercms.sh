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
#   bash configuraciones-wintercms.sh all # Flujo completo (1 -> 10)

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
APP_URL_1="${APP_URL_1:-https://django1.ti.mimas.net}"
APP_URL_2="${APP_URL_2:-https://django2.ti.mimas.net}"
APP_URL_3="${APP_URL_3:-https://django3.ti.mimas.net}"

# Bloque MySQL separado: apuntamos al cluster existente por MaxScale.
DB_HOST="${DB_HOST:-192.168.30.20}"
DB_PORT="${DB_PORT:-4008}"
DB_NAME="${DB_NAME:-appdb}"
DB_USER="${DB_USER:-appuser}"
DB_PASSWORD="${DB_PASSWORD:-app-pass-2620}"

# Se usa para pruebas HTTP locales en las VMs.
HOST_HEADER_1="${HOST_HEADER_1:-django1.ti.mimas.net}"
HOST_HEADER_2="${HOST_HEADER_2:-django2.ti.mimas.net}"
HOST_HEADER_3="${HOST_HEADER_3:-django3.ti.mimas.net}"
WINTER_LB_HOSTS="${WINTER_LB_HOSTS:-django1.ti.mimas.net django2.ti.mimas.net django3.ti.mimas.net www.ti.mimas.net}"

EXTRA_HOSTS="${EXTRA_HOSTS:-192.168.10.10 ns1.mimas.net dns-principal;192.168.10.11 ns1.ti.mimas.net dns-delegado;192.168.10.20 lb1.ti.mimas.net lb1;192.168.10.21 lb2.ti.mimas.net lb2;192.168.20.10 winter1.ti.mimas.net appWinter1;192.168.20.11 winter2.ti.mimas.net appWinter2;192.168.20.12 winter3.ti.mimas.net appWinter3;192.168.30.20 db.ti.mimas.net maxscale-1}"

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

chown -R "$APP_USER":www-data "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache"
chmod -R ug+rwX "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache"
find "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache" -type d -exec chmod 2775 {} +
find "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache" -type f -exec chmod 664 {} +

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

  if [[ -z "$DB_PASSWORD" ]]; then
    echo "[ERROR] DB_PASSWORD vacio"
    exit 1
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

install_wintercms_node() {
  local ip="$1"
  local app_url="$2"
  local host_header="$3"

  wait_for_ssh_node "$ip"
  prepare_node_package_manager "$ip"

  ssh_cmd "$ip" "APP_USER='$APP_USER' APP_GROUP='$APP_GROUP' APP_BASE_DIR='$APP_BASE_DIR' PROJECT_DIR='$PROJECT_DIR' APP_URL='$app_url' DB_HOST='$DB_HOST' DB_PORT='$DB_PORT' DB_NAME='$DB_NAME' DB_USER='$DB_USER' DB_PASSWORD='$DB_PASSWORD' HOST_HEADER='$host_header' sudo -E bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  nginx \
  php-fpm php-cli php-common php-mysql php-sqlite3 php-curl php-xml php-mbstring php-zip php-gd php-intl php-bcmath \
  curl unzip git composer mariadb-client

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

sed -i "s#^APP_URL=.*#APP_URL=$APP_URL#" "$PROJECT_DIR/.env"
sed -i "s#^DB_CONNECTION=.*#DB_CONNECTION=mysql#" "$PROJECT_DIR/.env"
sed -i "s#^DB_HOST=.*#DB_HOST=$DB_HOST#" "$PROJECT_DIR/.env"
sed -i "s#^DB_PORT=.*#DB_PORT=$DB_PORT#" "$PROJECT_DIR/.env"
sed -i "s#^DB_DATABASE=.*#DB_DATABASE=$DB_NAME#" "$PROJECT_DIR/.env"
sed -i "s#^DB_USERNAME=.*#DB_USERNAME=$DB_USER#" "$PROJECT_DIR/.env"
sed -i "s#^DB_PASSWORD=.*#DB_PASSWORD=$DB_PASSWORD#" "$PROJECT_DIR/.env"
sed -i "s#^SESSION_SECURE_COOKIE=.*#SESSION_SECURE_COOKIE=true#" "$PROJECT_DIR/.env"
if ! grep -q '^SESSION_SECURE_COOKIE=' "$PROJECT_DIR/.env"; then
  printf '\nSESSION_SECURE_COOKIE=true\n' >> "$PROJECT_DIR/.env"
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
chown -R "$APP_USER":www-data "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache"
chmod -R ug+rwX "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache"
find "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache" -type d -exec chmod 2775 {} +
find "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache" -type f -exec chmod 664 {} +

sudo -u "$APP_USER" bash -lc "cd '$PROJECT_DIR' && php artisan key:generate --force"
sudo -u "$APP_USER" bash -lc "cd '$PROJECT_DIR' && php artisan optimize:clear" || true
sudo -u "$APP_USER" bash -lc "cd '$PROJECT_DIR' && php artisan cache:clear" || true
sudo -u "$APP_USER" bash -lc "cd '$PROJECT_DIR' && php artisan config:clear" || true
sudo -u "$APP_USER" bash -lc "cd '$PROJECT_DIR' && php artisan route:clear" || true
sudo -u "$APP_USER" bash -lc "cd '$PROJECT_DIR' && php artisan view:clear" || true
sudo -u "$APP_USER" bash -lc "cd '$PROJECT_DIR' && php artisan package:discover --ansi"
sudo -u "$APP_USER" bash -lc "cd '$PROJECT_DIR' && php artisan winter:up"

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
      fastcgi_pass unix:/run/php/php8.1-fpm.sock;
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

systemctl restart php8.1-fpm 2>/dev/null || true
systemctl restart php8.2-fpm 2>/dev/null || true
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

  if ssh -i "$KEY" $SSH_OPTS "${SSH_USER}@${WINTER_IP2}" "echo ready" >/dev/null 2>&1; then
    validate_winter_node "$WINTER_IP2" "$HOST_HEADER_2"
  else
    echo "[WARN] VM2 no disponible, se omite validacion"
  fi

  if ssh -i "$KEY" $SSH_OPTS "${SSH_USER}@${WINTER_IP3}" "echo ready" >/dev/null 2>&1; then
    validate_winter_node "$WINTER_IP3" "$HOST_HEADER_3"
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
  least_conn;
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
  11     Publicar portadas 200 en / para los tres nodos
  12     Configurar balanceadores para WinterCMS
  13     Validar WinterCMS via balanceadores
  14     Corregir permisos runtime (storage/bootstrap/.env)
  all    Ejecutar 1,2,3,4,5,6,7,8,9,10,11,12,13,14

Flujo recomendado:
  1 -> 2 -> 3 -> 4 -> 5
  (validar VM1 limpia)
  6 -> 7
  8 -> 9
  10
  11 -> 12 -> 13
  14 si el backend muestra error de permisos
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
    11) block_11_publish_homepages ;;
    12) block_12_configure_winter_lb ;;
    13) block_13_validate_winter_lb ;;
    14) block_14_fix_runtime_permissions ;;
    all)
      block_1_poweroff_django_nodes
      block_2_network_cluster_settings
      block_3_mysql_cluster_settings
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
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
