#!/usr/bin/env bash
set -euo pipefail

# Apagado ordenado de VMs del laboratorio KVM/libvirt.
# Fases:
# 1) Balanceadores
# 2) Aplicacion (Django o Winter)
# 3) Base de datos y capa de datos
# 4) DNS
# 5) Otras VMs definidas (si existen)

WAIT_VM_TIMEOUT="${WAIT_VM_TIMEOUT:-180}"
FORCE_OFF_ON_TIMEOUT="${FORCE_OFF_ON_TIMEOUT:-true}"
APP_STACK="${APP_STACK:-auto}"  # auto|django|winter

GROUP_LB=(lb1 lb2)
GROUP_APP_DJANGO=(appDjango1 appDjango2 appDjango3)
GROUP_APP_WINTER=(appWinter1 appWinter2 appWinter3)
GROUP_DATA=(mariadb-1 mariadb-2 mariadb-3 maxscale-1 redis-1 redis-2 redis-3 redis-4 redis-5 redis-6 redis-7)
GROUP_DNS=(dns-principal dns-delegado)

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
declare -A HANDLED=()
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

vm_state() {
  local vm="$1"
  virsh domstate "$vm" 2>/dev/null | tr -d '\r'
}

wait_vm_shutoff() {
  local vm="$1"
  local waited=0

  while true; do
    local state
    state="$(vm_state "$vm")"
    if [[ "$state" == "shut off" ]]; then
      return 0
    fi

    if (( waited >= WAIT_VM_TIMEOUT )); then
      echo "[WARN] Timeout esperando apagado en $vm"
      return 1
    fi

    sleep 2
    waited=$((waited + 2))
  done
}

stop_vm_if_needed() {
  local vm="$1"

  if ! vm_exists "$vm"; then
    echo "[SKIP] $vm no existe en este host"
    return 0
  fi

  local state
  state="$(vm_state "$vm")"
  if [[ "$state" == "shut off" ]]; then
    echo "[OK] $vm ya estaba apagada"
    HANDLED["$vm"]=1
    return 0
  fi

  echo "[INFO] Apagando $vm (shutdown)"
  virsh shutdown "$vm" >/dev/null || true

  if wait_vm_shutoff "$vm"; then
    echo "[OK] $vm apagada"
  else
    if [[ "$FORCE_OFF_ON_TIMEOUT" == "true" ]]; then
      echo "[WARN] Forzando apagado de $vm (destroy)"
      virsh destroy "$vm" >/dev/null || true
    fi
  fi

  HANDLED["$vm"]=1
}

stop_group() {
  local label="$1"
  shift
  local vms=("$@")

  echo
  echo "=== $label ==="
  for vm in "${vms[@]}"; do
    stop_vm_if_needed "$vm"
  done
}

APP_GROUP=()
APP_LABEL=""
resolve_app_group APP_GROUP APP_LABEL
echo "[INFO] Stack de aplicacion seleccionado para apagado: $APP_LABEL"

stop_group "Fase 1 - Balanceadores" "${GROUP_LB[@]}"
stop_group "Fase 2 - Aplicacion ($APP_LABEL)" "${APP_GROUP[@]}"
stop_group "Fase 3 - Datos (MariaDB/MaxScale)" "${GROUP_DATA[@]}"
stop_group "Fase 4 - DNS" "${GROUP_DNS[@]}"

echo
echo "=== Fase 5 - VMs restantes ==="
for vm in "${ALL_VMS[@]}"; do
  if [[ -n "${HANDLED[$vm]:-}" ]]; then
    continue
  fi
  # Evita tocar el stack de aplicacion no seleccionado en esta corrida.
  if is_any_app_vm "$vm"; then
    echo "[SKIP] $vm pertenece a otro stack de aplicacion"
    continue
  fi
  stop_vm_if_needed "$vm"
done

echo
echo "=== Estado final ==="
virsh list --all

echo
echo "[OK] Apagado completado."
