#!/usr/bin/env bash
set -euo pipefail

# Arranque ordenado de VMs del laboratorio KVM/libvirt.
# Fases:
# 1) DNS
# 2) Base de datos y capa de datos
# 3) Aplicacion (Django o Winter)
# 4) Balanceadores
# 5) Otras VMs definidas (si existen)

SSH_USER="${SSH_USER:-userinfrakv}"
SSH_KEY="${SSH_KEY:-$(cd "$(dirname "$0")" && pwd)/ssh-keys/id_rsa}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
WAIT_VM_TIMEOUT="${WAIT_VM_TIMEOUT:-120}"
WAIT_SSH_TIMEOUT="${WAIT_SSH_TIMEOUT:-180}"
APP_STACK="${APP_STACK:-auto}"  # auto|django|winter

declare -A VM_IPS=(
  [dns-principal]="192.168.10.10"
  [dns-delegado]="192.168.10.11"
  [mariadb-1]="192.168.30.21"
  [mariadb-2]="192.168.30.22"
  [mariadb-3]="192.168.30.23"
  [maxscale-1]="192.168.30.20"
  [redis-1]="192.168.30.10"
  [redis-2]="192.168.30.11"
  [redis-3]="192.168.30.12"
  [redis-4]="192.168.30.13"
  [redis-5]="192.168.30.14"
  [redis-6]="192.168.30.15"
  [redis-7]="192.168.30.16"
  [appDjango1]="192.168.20.10"
  [appDjango2]="192.168.20.11"
  [appDjango3]="192.168.20.12"
  [appWinter1]="192.168.20.10"
  [appWinter2]="192.168.20.11"
  [appWinter3]="192.168.20.12"
  [lb1]="192.168.10.20"
  [lb2]="192.168.10.21"
)

GROUP_DNS=(dns-principal dns-delegado)
GROUP_DATA=(mariadb-1 mariadb-2 mariadb-3 maxscale-1 redis-1 redis-2 redis-3 redis-4 redis-5 redis-6 redis-7)
GROUP_APP_DJANGO=(appDjango1 appDjango2 appDjango3)
GROUP_APP_WINTER=(appWinter1 appWinter2 appWinter3)
GROUP_LB=(lb1 lb2)

if ! command -v virsh >/dev/null 2>&1; then
  echo "[ERROR] virsh no esta disponible en el host."
  exit 1
fi

mapfile -t ALL_VMS < <(virsh list --all --name | sed '/^$/d')
if [[ ${#ALL_VMS[@]} -eq 0 ]]; then
  echo "[ERROR] No hay VMs definidas en libvirt."
  exit 1
fi

declare -A EXISTS=()
declare -A STARTED=()
for vm in "${ALL_VMS[@]}"; do
  EXISTS["$vm"]=1
done

vm_exists() {
  local vm="$1"
  [[ -n "${EXISTS[$vm]:-}" ]]
}

is_any_app_vm() {
  local vm="$1"
  case "$vm" in
    appDjango1|appDjango2|appDjango3|appWinter1|appWinter2|appWinter3) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_app_group() {
  local -n out_group_ref="$1"
  local -n out_label_ref="$2"

  case "$APP_STACK" in
    django)
      out_group_ref=("${GROUP_APP_DJANGO[@]}")
      out_label_ref="Django"
      return 0
      ;;
    winter)
      out_group_ref=("${GROUP_APP_WINTER[@]}")
      out_label_ref="Winter"
      return 0
      ;;
    auto)
      if vm_exists "appWinter1" || vm_exists "appWinter2" || vm_exists "appWinter3"; then
        out_group_ref=("${GROUP_APP_WINTER[@]}")
        out_label_ref="Winter (auto)"
      else
        out_group_ref=("${GROUP_APP_DJANGO[@]}")
        out_label_ref="Django (auto)"
      fi
      return 0
      ;;
    *)
      echo "[ERROR] APP_STACK invalido: $APP_STACK (valores: auto|django|winter)"
      exit 1
      ;;
  esac
}

wait_vm_running() {
  local vm="$1"
  local waited=0
  while true; do
    local state
    state="$(virsh domstate "$vm" 2>/dev/null | tr -d '\r')"
    if [[ "$state" == "running" ]]; then
      return 0
    fi
    if (( waited >= WAIT_VM_TIMEOUT )); then
      echo "[WARN] Timeout esperando estado running en $vm"
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
}

wait_ssh() {
  local ip="$1"
  local waited=0

  if [[ ! -f "$SSH_KEY" ]]; then
    echo "[WARN] Clave SSH no encontrada en $SSH_KEY; omitiendo espera SSH"
    return 0
  fi

  while true; do
    if ssh -i "$SSH_KEY" $SSH_OPTS "$SSH_USER@$ip" 'echo ok' >/dev/null 2>&1; then
      return 0
    fi

    if (( waited >= WAIT_SSH_TIMEOUT )); then
      echo "[WARN] Timeout esperando SSH en $ip"
      return 1
    fi

    sleep 3
    waited=$((waited + 3))
  done
}

start_vm_if_needed() {
  local vm="$1"

  if ! vm_exists "$vm"; then
    echo "[SKIP] $vm no existe en este host"
    return 0
  fi

  if [[ "$(virsh domstate "$vm" 2>/dev/null | tr -d '\r')" == "running" ]]; then
    echo "[OK] $vm ya estaba running"
    STARTED["$vm"]=1
    return 0
  fi

  echo "[INFO] Iniciando $vm"
  virsh start "$vm" >/dev/null
  wait_vm_running "$vm" || true
  STARTED["$vm"]=1

  local ip="${VM_IPS[$vm]:-}"
  if [[ -n "$ip" ]]; then
    wait_ssh "$ip" || true
  fi
}

start_group() {
  local label="$1"
  shift
  local vms=("$@")

  echo
  echo "=== $label ==="
  for vm in "${vms[@]}"; do
    start_vm_if_needed "$vm"
  done
}

APP_GROUP=()
APP_LABEL=""
resolve_app_group APP_GROUP APP_LABEL
echo "[INFO] Stack de aplicacion seleccionado: $APP_LABEL"

start_group "Fase 1 - DNS" "${GROUP_DNS[@]}"
start_group "Fase 2 - Datos (MariaDB/MaxScale)" "${GROUP_DATA[@]}"
start_group "Fase 3 - Aplicacion ($APP_LABEL)" "${APP_GROUP[@]}"
start_group "Fase 4 - Balanceadores" "${GROUP_LB[@]}"

echo
echo "=== Fase 5 - VMs restantes ==="
for vm in "${ALL_VMS[@]}"; do
  if [[ -n "${STARTED[$vm]:-}" ]]; then
    continue
  fi
  # Evita encender el stack de aplicacion no seleccionado.
  if is_any_app_vm "$vm"; then
    echo "[SKIP] $vm pertenece a otro stack de aplicacion"
    continue
  fi
  start_vm_if_needed "$vm"
done

echo
echo "=== Estado final ==="
virsh list --all

echo
echo "[OK] Arranque completado."