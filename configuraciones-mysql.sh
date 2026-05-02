#!/usr/bin/env bash
set -euo pipefail

# Guia MariaDB + MaxScale en KVM con bloques separables.
# Uso:
#   bash configuraciones-mysql.sh 1
#   bash configuraciones-mysql.sh 2
#   bash configuraciones-mysql.sh all

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE_VM_SCRIPT="$BASE_DIR/create-kvm-vm.sh"
KEY="${KEY_OVERRIDE:-$BASE_DIR/ssh-keys/id_rsa}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8}"

VM_USER="${VM_USER:-userinfrakv}"
VM_PASSWORD="${VM_PASSWORD:-passphrase2620-07}"
WAIT_SSH_RETRIES="${WAIT_SSH_RETRIES:-80}"
WAIT_SSH_SLEEP="${WAIT_SSH_SLEEP:-5}"
MYSQL_STACK_NODES=(192.168.30.21 192.168.30.22 192.168.30.23 192.168.30.20)

if [[ ! -x "$CREATE_VM_SCRIPT" ]]; then
  echo "[ERROR] No se encontro script ejecutable: $CREATE_VM_SCRIPT"
  exit 1
fi

if [[ ! -r "$KEY" ]]; then
  echo "[ERROR] No se puede leer la clave SSH: $KEY"
  echo "[INFO] Ajusta KEY_OVERRIDE con una ruta valida y vuelve a ejecutar."
  exit 1
fi

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

wait_for_stack_ready() {
  local ip
  for ip in "${MYSQL_STACK_NODES[@]}"; do
    wait_for_ssh_node "$ip"
    ssh_cmd "$ip" "sudo bash -s" <<'REMOTE'
set -euo pipefail

# Espera cloud-init para reducir carreras con apt/dpkg.
cloud-init status --wait >/dev/null 2>&1 || true

systemctl stop apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
pkill -9 apt apt-get unattended-upgrade 2>/dev/null || true
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
rm -f /var/lib/dpkg/updates/*
dpkg --configure -a || true
apt-get -y -f install || true
REMOTE
  done
}

write_net_xml() {
  local name="$1"
  local mode="$2"
  local gw="$3"
  local mask="$4"
  local xml="/tmp/${name}.xml"

  if [[ "$mode" == "nat" ]]; then
    cat > "$xml" <<XML
<network>
  <name>${name}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='${name}' stp='on' delay='0'/>
  <ip address='${gw}' netmask='${mask}'/>
</network>
XML
  else
    cat > "$xml" <<XML
<network>
  <name>${name}</name>
  <bridge name='${name}' stp='on' delay='0'/>
  <ip address='${gw}' netmask='${mask}'/>
</network>
XML
  fi
}

recreate_net() {
  local name="$1"
  local mode="$2"
  local gw="$3"
  local mask="$4"

  write_net_xml "$name" "$mode" "$gw" "$mask"

  sudo virsh net-destroy "$name" 2>/dev/null || true
  sudo virsh net-undefine "$name" 2>/dev/null || true
  sudo virsh net-define "/tmp/${name}.xml"
  sudo virsh net-start "$name"
  sudo virsh net-autostart "$name"
}

block_1_create_networks() {
  # NAT necesarios:
  # - red-principal: salida general a internet.
  # - red-backend: VMs backend (apps/LB) sin WAN directa necesitan apt/update.
  # - red-db-redis: nodos DB necesitan salida para paquetes.
  recreate_net red-principal nat 192.168.10.1 255.255.255.0
  recreate_net red-backend nat 192.168.20.1 255.255.255.0
  recreate_net red-db-redis nat 192.168.30.1 255.255.255.0

  # Sin NAT (segmentos internos):
  recreate_net red-storage bridge 192.168.40.1 255.255.255.0
  recreate_net red-admin bridge 192.168.50.1 255.255.255.0

  echo "[OK] Redes recreadas"
  sudo virsh net-list --all
}

block_2_create_mysql_stack() {
  EXTRA_HOSTS="192.168.30.20 db.ti.mimas.net maxscale-1;192.168.30.21 db1.ti.mimas.net mariadb-1;192.168.30.22 db2.ti.mimas.net mariadb-2;192.168.30.23 db3.ti.mimas.net mariadb-3"

  echo "[INFO] Creando mariadb-1"
  bash "$CREATE_VM_SCRIPT" \
    --name mariadb-1 \
    --hostname db1.ti.mimas.net \
    --user "$VM_USER" \
    --password "$VM_PASSWORD" \
    --ram 4096 \
    --vcpus 2 \
    --system-disk 30 \
    --data-disk 20 \
    --libvirt-nets "red-db-redis;red-storage" \
    --ifaces "enp1s0,192.168.30.21/24,192.168.30.1,192.168.10.10,8.8.8.8;enp2s0,192.168.40.21/24,,192.168.10.10,8.8.8.8" \
    --extra-hosts "$EXTRA_HOSTS"

  echo "[INFO] Creando mariadb-2"
  bash "$CREATE_VM_SCRIPT" \
    --name mariadb-2 \
    --hostname db2.ti.mimas.net \
    --user "$VM_USER" \
    --password "$VM_PASSWORD" \
    --ram 4096 \
    --vcpus 2 \
    --system-disk 30 \
    --data-disk 40 \
    --libvirt-nets "red-db-redis;red-storage" \
    --ifaces "enp1s0,192.168.30.22/24,192.168.30.1,192.168.10.10,8.8.8.8;enp2s0,192.168.40.22/24,,192.168.10.10,8.8.8.8" \
    --extra-hosts "$EXTRA_HOSTS"

  echo "[INFO] Creando mariadb-3"
  bash "$CREATE_VM_SCRIPT" \
    --name mariadb-3 \
    --hostname db3.ti.mimas.net \
    --user "$VM_USER" \
    --password "$VM_PASSWORD" \
    --ram 4096 \
    --vcpus 2 \
    --system-disk 30 \
    --data-disk 40 \
    --libvirt-nets "red-db-redis;red-storage" \
    --ifaces "enp1s0,192.168.30.23/24,192.168.30.1,192.168.10.10,8.8.8.8;enp2s0,192.168.40.23/24,,192.168.10.10,8.8.8.8" \
    --extra-hosts "$EXTRA_HOSTS"

  echo "[INFO] Creando maxscale-1"
  bash "$CREATE_VM_SCRIPT" \
    --name maxscale-1 \
    --hostname db.ti.mimas.net \
    --user "$VM_USER" \
    --password "$VM_PASSWORD" \
    --ram 2048 \
    --vcpus 2 \
    --system-disk 30 \
    --data-disk 0 \
    --libvirt-nets "red-db-redis;red-admin" \
    --ifaces "enp1s0,192.168.30.20/24,192.168.30.1,192.168.10.10,8.8.8.8;enp2s0,192.168.50.50/24,,192.168.10.10,8.8.8.8" \
    --extra-hosts "$EXTRA_HOSTS"

  echo "[OK] Stack MariaDB/MaxScale solicitado"
  sudo virsh list --all | grep -E 'mariadb-|maxscale-1' || true

  echo "[INFO] Validando SSH y saneando cloud-init/apt en stack DB"
  wait_for_stack_ready
}

usage() {
  cat <<'EOF2'
Uso: bash configuraciones-mysql.sh <bloque>

Bloques disponibles:
  1      Re-crear redes libvirt con NAT/bridge correctos
  2      Crear VMs MariaDB + MaxScale + esperar SSH estable
  all    Ejecutar 1,2
EOF2
}

main() {
  local block="${1:-}"
  case "$block" in
    1) block_1_create_networks ;;
    2) block_2_create_mysql_stack ;;
    all)
      block_1_create_networks
      block_2_create_mysql_stack
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
