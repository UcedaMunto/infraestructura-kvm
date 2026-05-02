#!/usr/bin/env bash
set -euo pipefail

# Crea/recrea el stack MariaDB + MaxScale en KVM.
# Uso:
#   bash configuraciones-mysql.sh
# Variables opcionales:
#   VM_USER=userinfrakv VM_PASSWORD='passphrase2620-07' bash configuraciones-mysql.sh

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE_VM_SCRIPT="$BASE_DIR/create-kvm-vm.sh"

VM_USER="${VM_USER:-userinfrakv}"
VM_PASSWORD="${VM_PASSWORD:-passphrase2620-07}"

if [[ ! -x "$CREATE_VM_SCRIPT" ]]; then
  echo "[ERROR] No se encontro script ejecutable: $CREATE_VM_SCRIPT"
  exit 1
fi

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

echo "[OK] VMs solicitadas. Verifica estado con: virsh list --all | grep -E 'mariadb-|maxscale-1'"
