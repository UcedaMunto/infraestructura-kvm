#!/usr/bin/env bash
set -euo pipefail

# Guia de balanceo Nginx para dominios Django en KVM.
# Uso:
#   bash configuraciones-nginx-dominio.sh 1
#   bash configuraciones-nginx-dominio.sh 2
#   bash configuraciones-nginx-dominio.sh 3
#   bash configuraciones-nginx-dominio.sh 4
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

usage() {
  cat <<'EOF2'
Uso: bash configuraciones-nginx-dominio.sh <bloque>

Bloques disponibles:
  0      Preflight LB nodes (SSH + cloud-init + saneo apt/dpkg)
  1      Crear/levantar VMs LB1 y LB2
  2      Instalar y configurar Nginx LB en LB1/LB2
  3      Validar Nginx y acceso por dominios via Host header
  4      Mostrar comandos MANUALES para publicar dominios en DNS
  all    Ejecutar 1,2,3
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
