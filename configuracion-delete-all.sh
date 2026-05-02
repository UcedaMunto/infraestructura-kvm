#!/usr/bin/env bash
set -euo pipefail

# Limpieza total del laboratorio KVM para instalacion limpia.
# Borra VMs, discos, redes y artefactos temporales conocidos del proyecto.
#
# Uso:
#   bash configuracion-delete-all.sh plan
#   bash configuracion-delete-all.sh 1 --yes
#   bash configuracion-delete-all.sh 2 --yes
#   bash configuracion-delete-all.sh 3 --yes
#   bash configuracion-delete-all.sh 4 --yes
#   bash configuracion-delete-all.sh all --yes
#
# NOTA: requiere --yes para ejecutar bloques destructivos.

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_DIR="${IMG_DIR:-/var/lib/libvirt/images}"

CONFIRM=false
BLOCK="${1:-}"

VM_NAMES=(
  dns-principal dns-delegado
  lb1 lb2
  appDjango1 appDjango2 appDjango3
  app1 app2 app3
  mariadb-1 mariadb-2 mariadb-3
  maxscale-1
  redis-1 redis-2 redis1 redis2
  ceph-admin cephfs-1
  ceph-gateway storage1 storage2 storage3
  dns-1
  bastion monitor
)

NETWORK_NAMES=(
  red-principal
  red-backend
  red-db-redis
  red-storage
  red-admin
)

for arg in "$@"; do
  if [[ "$arg" == "--yes" ]]; then
    CONFIRM=true
  fi
done

log() {
  echo "[INFO] $*"
}

ok() {
  echo "[OK] $*"
}

warn() {
  echo "[WARN] $*"
}

err() {
  echo "[ERROR] $*" >&2
}

require_confirm() {
  if [[ "$CONFIRM" != "true" ]]; then
    err "Operacion destructiva. Debes confirmar con --yes"
    exit 1
  fi
}

show_plan() {
  cat <<'EOF'
Plan de limpieza:
  1) Detener servicios en VMs accesibles por SSH (best effort)
  2) Eliminar VMs y discos adjuntos (domblklist + patrones de discos)
  3) Eliminar redes libvirt del laboratorio
  4) Limpiar artefactos temporales y logs generados

Ejemplo recomendado:
  bash configuracion-delete-all.sh all --yes
EOF
}

ssh_stop_services_best_effort() {
  local key="$BASE_DIR/ssh-keys/id_rsa"
  local user="${SSH_USER:-userinfrakv}"
  local opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4"

  if [[ ! -r "$key" ]]; then
    warn "No se encontro clave SSH para detener servicios remotamente: $key"
    return 0
  fi

  local ips=(
    192.168.10.10 192.168.10.11
    192.168.10.20 192.168.10.21
    192.168.20.10 192.168.20.11 192.168.20.12
    192.168.30.10
    192.168.30.20 192.168.30.21 192.168.30.22 192.168.30.23
  )

  local ip
  for ip in "${ips[@]}"; do
    log "Intentando detener servicios en $ip (best effort)"
    ssh -i "$key" $opts "$user@$ip" "sudo bash -s" <<'REMOTE' || true
set -euo pipefail
systemctl stop nginx 2>/dev/null || true
systemctl stop django-gunicorn.service 2>/dev/null || true
systemctl stop bind9 2>/dev/null || true
systemctl stop maxscale 2>/dev/null || true
systemctl stop mariadb 2>/dev/null || true
systemctl stop redis-server 2>/dev/null || true
REMOTE
  done
}

block_1_stop_services() {
  require_confirm
  ssh_stop_services_best_effort
  ok "Paso 1 completado"
}

remove_vm_and_disks() {
  local vm="$1"

  if ! sudo virsh dominfo "$vm" >/dev/null 2>&1; then
    return 0
  fi

  local state
  state="$(sudo virsh domstate "$vm" | tr -d '\r')"
  if [[ "$state" == "running" ]]; then
    sudo virsh destroy "$vm" || true
  fi

  mapfile -t disk_paths < <(sudo virsh domblklist "$vm" | awk 'NR>2 {print $2}' | grep -E '^/' || true)

  sudo virsh undefine "$vm" --managed-save --snapshots-metadata 2>/dev/null || sudo virsh undefine "$vm" 2>/dev/null || true

  local disk
  for disk in "${disk_paths[@]}"; do
    if [[ -f "$disk" ]]; then
      log "Borrando disco adjunto: $disk"
      sudo rm -f "$disk"
    fi
  done

  # Limpieza adicional por patron de nombre.
  sudo rm -f "$IMG_DIR/${vm}.qcow2" "$IMG_DIR/${vm}-data.qcow2" "$IMG_DIR/${vm}"*.iso 2>/dev/null || true
}

block_2_delete_vms_disks() {
  require_confirm

  local vm
  for vm in "${VM_NAMES[@]}"; do
    log "Procesando VM: $vm"
    remove_vm_and_disks "$vm"
  done

  ok "Paso 2 completado"
  sudo virsh list --all || true
}

block_3_delete_networks() {
  require_confirm

  local net
  for net in "${NETWORK_NAMES[@]}"; do
    if sudo virsh net-info "$net" >/dev/null 2>&1; then
      log "Eliminando red: $net"
      sudo virsh net-destroy "$net" 2>/dev/null || true
      sudo virsh net-undefine "$net" 2>/dev/null || true
    fi
  done

  ok "Paso 3 completado"
  sudo virsh net-list --all || true
}

block_4_cleanup_artifacts() {
  require_confirm

  log "Limpiando cloud-init temporales"
  rm -f /tmp/user-data-*.yaml /tmp/network-config-*.yaml 2>/dev/null || true

  log "Limpiando archivos de comandos/logs generados del proyecto"
  rm -f "$BASE_DIR"/logs/*.txt 2>/dev/null || true

  log "Limpiando discos huerfanos conocidos"
  sudo rm -f \
    "$IMG_DIR"/vm-bridge-1.qcow2 \
    "$IMG_DIR"/vm-bridge-2.qcow2 \
    "$IMG_DIR"/cloud-init.iso \
    "$IMG_DIR"/dns-1.qcow2 \
    2>/dev/null || true

  ok "Paso 4 completado"
}

usage() {
  cat <<'EOF'
Uso: bash configuracion-delete-all.sh <bloque> [--yes]

Bloques disponibles:
  plan   Mostrar plan de limpieza
  1      Detener servicios en nodos (best effort)
  2      Eliminar VMs y discos
  3      Eliminar redes del laboratorio
  4      Limpiar artefactos temporales/logs
  all    Ejecutar 1,2,3,4

Importante:
  --yes  Confirmacion obligatoria para bloques destructivos
EOF
}

main() {
  case "$BLOCK" in
    plan)
      show_plan
      ;;
    1)
      block_1_stop_services
      ;;
    2)
      block_2_delete_vms_disks
      ;;
    3)
      block_3_delete_networks
      ;;
    4)
      block_4_cleanup_artifacts
      ;;
    all)
      block_1_stop_services
      block_2_delete_vms_disks
      block_3_delete_networks
      block_4_cleanup_artifacts
      ok "Limpieza total completada"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
