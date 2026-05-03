#!/usr/bin/env bash
set -euo pipefail

# Guia de balanceo Nginx para dominios Django en KVM.
# Uso:
#   bash configuraciones-nginx-dominio.sh 1
#   bash configuraciones-nginx-dominio.sh 2
#   bash configuraciones-nginx-dominio.sh 3
#   bash configuraciones-nginx-dominio.sh 4
#   bash configuraciones-nginx-dominio.sh 6   # Let's Encrypt django1 en LB
#   bash configuraciones-nginx-dominio.sh 7   # Let's Encrypt app1 directo
#   bash configuraciones-nginx-dominio.sh 8   # Validar HTTPS
#   bash configuraciones-nginx-dominio.sh all

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE_VM_SCRIPT="$BASE_DIR/create-kvm-vm.sh"
KEY="${KEY_OVERRIDE:-$BASE_DIR/ssh-keys/id_rsa}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8}"

VM_USER="${VM_USER:-userinfrakv}"
VM_PASSWORD="${VM_PASSWORD:-passphrase2620-07}"
WAIT_SSH_RETRIES="${WAIT_SSH_RETRIES:-60}"
WAIT_SSH_SLEEP="${WAIT_SSH_SLEEP:-5}"

LB1_VM="${LB1_VM:-lb1}"
LB2_VM="${LB2_VM:-lb2}"
LB1_IP="${LB1_IP:-192.168.10.20}"
LB2_IP="${LB2_IP:-192.168.10.21}"
LB_NODES=("$LB1_IP" "$LB2_IP")

APP1_IP="${APP1_IP:-192.168.20.10}"
APP2_IP="${APP2_IP:-192.168.20.11}"
APP3_IP="${APP3_IP:-192.168.20.12}"

LE_EMAIL="${LE_EMAIL:-}"
LE_STAGING="${LE_STAGING:-false}"
LE_DJANGO1_DOMAIN="${LE_DJANGO1_DOMAIN:-django1.ti.mimas.net}"
LE_APP1_DOMAIN="${LE_APP1_DOMAIN:-app1.ti.mimas.net}"
LE_DJANGO1_TARGET_LB_IP="${LE_DJANGO1_TARGET_LB_IP:-$LB1_IP}"
WILDCARD_BASE_DOMAIN="${WILDCARD_BASE_DOMAIN:-ti.mimas.net}"
WILDCARD_CERT_DAYS="${WILDCARD_CERT_DAYS:-825}"

if [[ ! -x "$CREATE_VM_SCRIPT" ]]; then
  echo "[ERROR] No se encontro script ejecutable: $CREATE_VM_SCRIPT"
  exit 1
fi

if [[ ! -r "$KEY" ]]; then
  echo "[ERROR] No se puede leer la clave SSH: $KEY"
  echo "[INFO] Define KEY_OVERRIDE con ruta valida y vuelve a ejecutar."
  exit 1
fi

EXTRA_HOSTS="192.168.10.10 ns1.mimas.net dns-principal;192.168.10.11 ns1.ti.mimas.net dns-delegado;192.168.10.20 lb1.ti.mimas.net lb1;192.168.10.21 lb2.ti.mimas.net lb2;192.168.20.10 app1.ti.mimas.net app1;192.168.20.11 app2.ti.mimas.net app2;192.168.20.12 app3.ti.mimas.net app3"

ssh_cmd() {
  local ip="$1"
  shift
  ssh -i "$KEY" $SSH_OPTS "${VM_USER}@${ip}" "$@"
}

ssh_app_cmd() {
  local ip="$1"
  shift
  ssh -i "$KEY" $SSH_OPTS "${VM_USER}@${ip}" "$@"
}

require_le_email() {
  if [[ -z "$LE_EMAIL" ]]; then
    echo "[ERROR] Debes definir LE_EMAIL para Let's Encrypt."
    echo "[INFO] Ejemplo: LE_EMAIL=admin@tu-dominio.com bash configuraciones-nginx-dominio.sh 6"
    exit 1
  fi
}

certbot_stage_flag() {
  if [[ "$LE_STAGING" == "true" ]]; then
    echo "--test-cert"
  fi
}

validate_single_a_record() {
  local domain="$1"
  local expected_ip="$2"

  mapfile -t resolved_ips < <(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u)

  if (( ${#resolved_ips[@]} == 0 )); then
    echo "[ERROR] No hay resolucion A para $domain en este host"
    return 1
  fi

  if (( ${#resolved_ips[@]} > 1 )); then
    echo "[ERROR] $domain tiene multiples IPs: ${resolved_ips[*]}"
    echo "[INFO] Para HTTP-01 de Let's Encrypt debes apuntar temporalmente a una sola IP: $expected_ip"
    return 1
  fi

  if [[ "${resolved_ips[0]}" != "$expected_ip" ]]; then
    echo "[ERROR] $domain resuelve a ${resolved_ips[0]}, se esperaba $expected_ip"
    return 1
  fi

  echo "[OK] $domain resuelve unicamente a $expected_ip"
}

wait_for_ssh_node() {
  local ip="$1"
  local attempt=1

  while (( attempt <= WAIT_SSH_RETRIES )); do
    if ssh -i "$KEY" $SSH_OPTS "${VM_USER}@${ip}" "echo ready" >/dev/null 2>&1; then
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

block_0_preflight_lbs() {
  wait_for_all_lb_ssh

  local ip
  for ip in "${LB_NODES[@]}"; do
    echo "[INFO] Preflight cloud-init/apt en $ip"
    prepare_lb_package_manager "$ip"
  done
}

ensure_vm_running() {
  local vm="$1"
  if sudo virsh dominfo "$vm" >/dev/null 2>&1; then
    local state
    state="$(sudo virsh domstate "$vm" | tr -d '\r')"
    if [[ "$state" != "running" ]]; then
      sudo virsh start "$vm"
    fi
  fi
}

block_1_create_or_start_lbs() {
  echo "[INFO] Creando/validando $LB1_VM"
  bash "$CREATE_VM_SCRIPT" \
    --name "$LB1_VM" \
    --hostname lb1.ti.mimas.net \
    --user "$VM_USER" \
    --password "$VM_PASSWORD" \
    --ram 2048 \
    --vcpus 2 \
    --system-disk 30 \
    --data-disk 0 \
    --libvirt-nets "red-principal;red-backend;red-admin" \
    --ifaces "enp1s0,192.168.10.20/24,192.168.10.1,192.168.10.10,8.8.8.8;enp2s0,192.168.20.20/24,,192.168.10.10,8.8.8.8;enp3s0,192.168.50.20/24,,192.168.10.10,8.8.8.8" \
    --extra-hosts "$EXTRA_HOSTS"

  echo "[INFO] Creando/validando $LB2_VM"
  bash "$CREATE_VM_SCRIPT" \
    --name "$LB2_VM" \
    --hostname lb2.ti.mimas.net \
    --user "$VM_USER" \
    --password "$VM_PASSWORD" \
    --ram 2048 \
    --vcpus 2 \
    --system-disk 30 \
    --data-disk 0 \
    --libvirt-nets "red-principal;red-backend;red-admin" \
    --ifaces "enp1s0,192.168.10.21/24,192.168.10.1,192.168.10.10,8.8.8.8;enp2s0,192.168.20.21/24,,192.168.10.10,8.8.8.8;enp3s0,192.168.50.21/24,,192.168.10.10,8.8.8.8" \
    --extra-hosts "$EXTRA_HOSTS"

  ensure_vm_running "$LB1_VM"
  ensure_vm_running "$LB2_VM"

  echo "[INFO] Esperando SSH en LB1/LB2"
  wait_for_all_lb_ssh
}

block_2_configure_nginx_lb() {
  block_0_preflight_lbs

  local lb_ip
  for lb_ip in "${LB_NODES[@]}"; do
    echo "[INFO] Configurando Nginx en $lb_ip"
    ssh_cmd "$lb_ip" "sudo bash -s" <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx curl

cat >/etc/nginx/sites-available/django-lb.conf <<'NGINX'
upstream django_kvm_pool {
  least_conn;
  server ${APP1_IP}:80 max_fails=3 fail_timeout=10s;
  server ${APP2_IP}:80 max_fails=3 fail_timeout=10s;
  server ${APP3_IP}:80 max_fails=3 fail_timeout=10s;
  keepalive 32;
}

server {
  listen 80 default_server;
  server_name django1.ti.mimas.net django2.ti.mimas.net django3.ti.mimas.net;

  location / {
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 60s;
    proxy_connect_timeout 5s;
    proxy_pass http://django_kvm_pool;
  }

  location /nginx-health {
    return 200 "ok\\n";
    add_header Content-Type text/plain;
  }
}
NGINX

ln -sfn /etc/nginx/sites-available/django-lb.conf /etc/nginx/sites-enabled/django-lb.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl restart nginx
REMOTE
  done
}

block_3_validate_lb() {
  wait_for_all_lb_ssh

  local lb_ip
  for lb_ip in "${LB_NODES[@]}"; do
    echo "=== LB $lb_ip ==="
    ssh_cmd "$lb_ip" "hostname -f || hostname"
    ssh_cmd "$lb_ip" "systemctl is-active nginx"
    ssh_cmd "$lb_ip" "curl -fsS --max-time 5 http://127.0.0.1/nginx-health"

    ssh_cmd "$lb_ip" "code=\$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://${APP1_IP}:80 || true); if [[ \"\$code\" != \"000\" ]]; then echo \"[OK] app1 backend reachable (codigo \$code)\"; else echo '[ERROR] app1 backend sin respuesta'; exit 1; fi"
    ssh_cmd "$lb_ip" "code=\$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://${APP2_IP}:80 || true); if [[ \"\$code\" != \"000\" ]]; then echo \"[OK] app2 backend reachable (codigo \$code)\"; else echo '[ERROR] app2 backend sin respuesta'; exit 1; fi"
    ssh_cmd "$lb_ip" "code=\$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://${APP3_IP}:80 || true); if [[ \"\$code\" != \"000\" ]]; then echo \"[OK] app3 backend reachable (codigo \$code)\"; else echo '[ERROR] app3 backend sin respuesta'; exit 1; fi"

    code="$(curl -sS --max-time 8 -H "Host: django1.ti.mimas.net" -o /dev/null -w '%{http_code}' "http://$lb_ip/" || true)"
    [[ "$code" != "000" ]] && echo "[OK] django1 via $lb_ip (codigo $code)" || { echo "[ERROR] django1 via $lb_ip sin respuesta"; exit 1; }

    code="$(curl -sS --max-time 8 -H "Host: django2.ti.mimas.net" -o /dev/null -w '%{http_code}' "http://$lb_ip/" || true)"
    [[ "$code" != "000" ]] && echo "[OK] django2 via $lb_ip (codigo $code)" || { echo "[ERROR] django2 via $lb_ip sin respuesta"; exit 1; }

    code="$(curl -sS --max-time 8 -H "Host: django3.ti.mimas.net" -o /dev/null -w '%{http_code}' "http://$lb_ip/" || true)"
    [[ "$code" != "000" ]] && echo "[OK] django3 via $lb_ip (codigo $code)" || { echo "[ERROR] django3 via $lb_ip sin respuesta"; exit 1; }
  done
}

block_4_manual_dns_commands() {
  cat <<'EOF2'
################################################################################
# BLOQUE 4 (MANUAL): comandos DNS para publicar dominios en LB1/LB2
################################################################################

KEY="/home/uceda/Documents/cluster-ceph/proyecto-manual-infraestructura/ssh-keys/id_rsa"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# 1) DNS PRINCIPAL: asegurar delegacion de ti.mimas.net
ssh -i "$KEY" $SSH_OPTS userinfrakv@192.168.10.10 "sudo bash -s" <<'REMOTE'
set -euo pipefail
sudo cp /etc/bind/db.mimas.net /etc/bind/db.mimas.net.bak.$(date +%F-%H%M%S)
sudo tee /etc/bind/db.mimas.net >/dev/null <<'ZONE'
$TTL 86400
@   IN  SOA ns1.mimas.net. admin.mimas.net. (
        2026050204
        3600
        1800
        1209600
        86400 )
;
@       IN  NS  ns1.mimas.net.
ns1     IN  A   192.168.10.10
@       IN  A   192.168.10.10
ti      IN  NS  ns1.ti.mimas.net.
ns1.ti  IN  A   192.168.10.11
ZONE
sudo named-checkzone mimas.net /etc/bind/db.mimas.net
sudo systemctl restart bind9
REMOTE

# 2) DNS DELEGADO: publicar dominios en LB1/LB2 (RR DNS)
ssh -i "$KEY" $SSH_OPTS userinfrakv@192.168.10.11 "sudo bash -s" <<'REMOTE'
set -euo pipefail
sudo cp /etc/bind/db.ti.mimas.net /etc/bind/db.ti.mimas.net.bak.$(date +%F-%H%M%S)
sudo tee /etc/bind/db.ti.mimas.net >/dev/null <<'ZONE'
$TTL 86400
@   IN  SOA ns1.ti.mimas.net. admin.ti.mimas.net. (
        2026050204
        3600
        1800
        1209600
        86400 )
;
@       IN  NS  ns1.ti.mimas.net.
ns1     IN  A   192.168.10.11
@       IN  A   192.168.10.11

db      IN  A   192.168.30.20
lb1     IN  A   192.168.10.20
lb2     IN  A   192.168.10.21

django1 IN  A   192.168.10.20
django1 IN  A   192.168.10.21
django2 IN  A   192.168.10.20
django2 IN  A   192.168.10.21
django3 IN  A   192.168.10.20
django3 IN  A   192.168.10.21
ZONE
sudo named-checkzone ti.mimas.net /etc/bind/db.ti.mimas.net
sudo systemctl restart bind9
REMOTE

# 3) Validacion desde host
for d in django1.ti.mimas.net django2.ti.mimas.net django3.ti.mimas.net; do
  echo "=== $d ==="
  dig +short @192.168.10.10 "$d" A
  dig +short @192.168.10.11 "$d" A
done
################################################################################
EOF2
}

block_5_validate_host_domains() {
  local domain
  for domain in django1.ti.mimas.net django2.ti.mimas.net django3.ti.mimas.net; do
    echo "=== Host -> $domain ==="
    getent hosts "$domain" || {
      echo "[ERROR] El resolver del host no resuelve $domain"
      return 1
    }

    local code
    code="$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' "http://$domain/" || true)"
    if [[ "$code" == "000" ]]; then
      echo "[ERROR] $domain no responde desde el host"
      return 1
    fi

    echo "[OK] $domain responde desde el host (codigo $code)"
  done
}

block_6_letsencrypt_django1_lb() {
  wait_for_all_lb_ssh
  require_le_email
  validate_single_a_record "$LE_DJANGO1_DOMAIN" "$LE_DJANGO1_TARGET_LB_IP"

  local le_flag
  le_flag="$(certbot_stage_flag)"

  echo "[INFO] Emitiendo certificado Let's Encrypt para $LE_DJANGO1_DOMAIN en LB $LE_DJANGO1_TARGET_LB_IP"
  ssh_cmd "$LE_DJANGO1_TARGET_LB_IP" "sudo bash -s" <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y certbot python3-certbot-nginx

certbot --nginx -n --agree-tos -m '$LE_EMAIL' $le_flag --redirect -d '$LE_DJANGO1_DOMAIN'

nginx -t
systemctl reload nginx
REMOTE

  echo "[OK] Certificado y redireccion HTTPS aplicados para $LE_DJANGO1_DOMAIN"
}

block_7_letsencrypt_app1_direct() {
  wait_for_ssh_node "$APP1_IP"
  require_le_email
  validate_single_a_record "$LE_APP1_DOMAIN" "$APP1_IP"

  local le_flag
  le_flag="$(certbot_stage_flag)"

  echo "[INFO] Emitiendo certificado Let's Encrypt para $LE_APP1_DOMAIN en app1 ($APP1_IP)"
  ssh_app_cmd "$APP1_IP" "sudo bash -s" <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx certbot

certbot certonly --standalone -n --agree-tos -m '$LE_EMAIL' $le_flag -d '$LE_APP1_DOMAIN' \
  --pre-hook 'systemctl stop django-gunicorn.service' \
  --post-hook 'systemctl start django-gunicorn.service'

cat >/etc/nginx/sites-available/app1-https.conf <<'NGINX'
server {
  listen 443 ssl;
  server_name app1.ti.mimas.net;

  ssl_certificate /etc/letsencrypt/live/app1.ti.mimas.net/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/app1.ti.mimas.net/privkey.pem;

  location / {
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 60s;
    proxy_connect_timeout 5s;
    proxy_pass http://127.0.0.1:80;
  }
}
NGINX

ln -sfn /etc/nginx/sites-available/app1-https.conf /etc/nginx/sites-enabled/app1-https.conf
nginx -t
systemctl enable --now nginx
systemctl restart nginx

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/reload-app1-nginx.sh <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
systemctl reload nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-app1-nginx.sh
REMOTE

  echo "[OK] Certificado y Nginx HTTPS aplicados para $LE_APP1_DOMAIN"
}

block_8_validate_https() {
  local domain
  for domain in "$LE_DJANGO1_DOMAIN" "$LE_APP1_DOMAIN"; do
    echo "=== HTTPS -> $domain ==="
    code="$(curl -sS --max-time 12 -o /dev/null -w '%{http_code}' "https://$domain/" || true)"
    if [[ "$code" == "000" ]]; then
      echo "[ERROR] $domain no responde por HTTPS"
      return 1
    fi
    echo "[OK] $domain responde por HTTPS (codigo $code)"
  done
}

block_9_wildcard_selfsigned_apply() {
  wait_for_all_lb_ssh
  wait_for_ssh_node "$APP1_IP"

  local wildcard="*.${WILDCARD_BASE_DOMAIN}"
  local cert_path="/etc/nginx/ssl/wildcard-${WILDCARD_BASE_DOMAIN}.crt"
  local key_path="/etc/nginx/ssl/wildcard-${WILDCARD_BASE_DOMAIN}.key"

  echo "[INFO] Aplicando certificado wildcard local en LB ${LE_DJANGO1_TARGET_LB_IP}"
  ssh_cmd "$LE_DJANGO1_TARGET_LB_IP" "sudo bash -s" <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx openssl

mkdir -p /etc/nginx/ssl
if [[ ! -f '$cert_path' || ! -f '$key_path' ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days '$WILDCARD_CERT_DAYS' \
    -keyout '$key_path' \
    -out '$cert_path' \
    -subj '/CN=$wildcard' \
    -addext 'subjectAltName=DNS:$wildcard,DNS:${WILDCARD_BASE_DOMAIN}'
fi

cat >/etc/nginx/sites-available/django1-wildcard-ssl.conf <<'NGINX'
upstream django_kvm_pool_ssl {
  least_conn;
  server ${APP1_IP}:80 max_fails=3 fail_timeout=10s;
  server ${APP2_IP}:80 max_fails=3 fail_timeout=10s;
  server ${APP3_IP}:80 max_fails=3 fail_timeout=10s;
  keepalive 32;
}

server {
  listen 443 ssl;
  server_name django1.ti.mimas.net;

  ssl_certificate /etc/nginx/ssl/wildcard-${WILDCARD_BASE_DOMAIN}.crt;
  ssl_certificate_key /etc/nginx/ssl/wildcard-${WILDCARD_BASE_DOMAIN}.key;

  location / {
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 60s;
    proxy_connect_timeout 5s;
    proxy_pass http://django_kvm_pool_ssl;
  }
}
NGINX

ln -sfn /etc/nginx/sites-available/django1-wildcard-ssl.conf /etc/nginx/sites-enabled/django1-wildcard-ssl.conf
nginx -t
systemctl enable --now nginx
systemctl restart nginx
REMOTE

  echo "[INFO] Aplicando certificado wildcard local en app1 (${APP1_IP})"
  ssh_app_cmd "$APP1_IP" "sudo bash -s" <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx openssl

mkdir -p /etc/nginx/ssl
if [[ ! -f '$cert_path' || ! -f '$key_path' ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days '$WILDCARD_CERT_DAYS' \
    -keyout '$key_path' \
    -out '$cert_path' \
    -subj '/CN=$wildcard' \
    -addext 'subjectAltName=DNS:$wildcard,DNS:${WILDCARD_BASE_DOMAIN}'
fi

cat >/etc/nginx/sites-available/app1-wildcard-ssl.conf <<'NGINX'
server {
  listen 443 ssl;
  server_name app1.ti.mimas.net;

  ssl_certificate /etc/nginx/ssl/wildcard-${WILDCARD_BASE_DOMAIN}.crt;
  ssl_certificate_key /etc/nginx/ssl/wildcard-${WILDCARD_BASE_DOMAIN}.key;

  location / {
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 60s;
    proxy_connect_timeout 5s;
    proxy_pass http://127.0.0.1:80;
  }
}
NGINX

ln -sfn /etc/nginx/sites-available/app1-wildcard-ssl.conf /etc/nginx/sites-enabled/app1-wildcard-ssl.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl restart nginx
REMOTE

  echo "[OK] Wildcard SSL local aplicado en django1/app1"
}

block_10_validate_wildcard_tls() {
  local domain
  for domain in "$LE_DJANGO1_DOMAIN" "$LE_APP1_DOMAIN"; do
    echo "=== Wildcard HTTPS -> $domain ==="
    code="$(curl -k -sS --max-time 12 -o /dev/null -w '%{http_code}' "https://$domain/" || true)"
    if [[ "$code" == "000" ]]; then
      echo "[ERROR] $domain no responde por HTTPS (wildcard)"
      return 1
    fi
    echo "[OK] $domain responde por HTTPS con wildcard (codigo $code)"
  done
}

usage() {
  cat <<'EOF2'
Uso: bash configuraciones-nginx-dominio.sh <bloque>

Bloques disponibles:
  0      Preflight LB nodes (SSH + cloud-init + saneo apt/dpkg)
  1      Crear/levantar VMs LB1 y LB2
  2      Instalar y configurar Nginx LB en LB1/LB2
  3      Validar Nginx y acceso por dominios via Host header
  4      Mostrar comandos MANUALES para publicar dominios en DNS
  5      Validar acceso real desde el host usando dominios resueltos
  6      Let's Encrypt para django1.ti.mimas.net en LB objetivo
  7      Let's Encrypt para app1.ti.mimas.net en app1 directo
  8      Validar HTTPS de django1/app1
  9      Aplicar wildcard SSL local (*.ti.mimas.net) en django1/app1
  10     Validar wildcard HTTPS (curl -k)
  all    Ejecutar 1,2,3

Variables para Let's Encrypt:
  LE_EMAIL=admin@dominio.com
  LE_STAGING=true|false
  LE_DJANGO1_TARGET_LB_IP=192.168.10.20

Variables wildcard local:
  WILDCARD_BASE_DOMAIN=ti.mimas.net
  WILDCARD_CERT_DAYS=825
EOF2
}

main() {
  local block="${1:-}"
  case "$block" in
    0) block_0_preflight_lbs ;;
    1) block_1_create_or_start_lbs ;;
    2) block_2_configure_nginx_lb ;;
    3) block_3_validate_lb ;;
    4) block_4_manual_dns_commands ;;
    5) block_5_validate_host_domains ;;
    6) block_6_letsencrypt_django1_lb ;;
    7) block_7_letsencrypt_app1_direct ;;
    8) block_8_validate_https ;;
    9) block_9_wildcard_selfsigned_apply ;;
    10) block_10_validate_wildcard_tls ;;
    all)
      block_1_create_or_start_lbs
      block_0_preflight_lbs
      block_2_configure_nginx_lb
      block_3_validate_lb
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
