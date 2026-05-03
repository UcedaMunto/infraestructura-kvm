#!/usr/bin/env bash
set -euo pipefail

# Orquestador principal de despliegue para el laboratorio KVM.
# Ejecuta los scripts configuraciones-* en secuencia valida y controlada.
#
# Uso:
#   bash configuraciones-despliegue.sh precheck
#   bash configuraciones-despliegue.sh run
#   bash configuraciones-despliegue.sh run-sin-mysql-pasos
#
# Variables opcionales:
#   AUTO_APPROVE_DJANGO=true   # omite la pausa de confirmacion antes de Django
#   INCLUDE_MYSQL_PASOS=false  # desactiva scripts/mysql-pasos.bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DNS_SCRIPT="$BASE_DIR/configuraciones-dns.bash"
MYSQL_SCRIPT="$BASE_DIR/configuraciones-mysql.sh"
DJANGO_SCRIPT="$BASE_DIR/configuraciones-django.sh"
NGINX_SCRIPT="$BASE_DIR/configuraciones-nginx-dominio.sh"
MYSQL_PASOS_SCRIPT="$BASE_DIR/scripts/mysql-pasos.bash"

AUTO_APPROVE_DJANGO="${AUTO_APPROVE_DJANGO:-false}"
INCLUDE_MYSQL_PASOS="${INCLUDE_MYSQL_PASOS:-true}"

STEP_COUNTER=0

log() {
  echo "[INFO] $*"
}

ok() {
  echo "[OK] $*"
}

err() {
  echo "[ERROR] $*" >&2
}

step() {
  STEP_COUNTER=$((STEP_COUNTER + 1))
  echo
  echo "=================================================================="
  echo "[STEP ${STEP_COUNTER}] $*"
  echo "=================================================================="
}

require_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    err "Falta archivo requerido: $f"
    exit 1
  fi
}

syntax_check() {
  step "Validacion de sintaxis de scripts"
  bash -n "$DNS_SCRIPT"
  bash -n "$MYSQL_SCRIPT"
  bash -n "$DJANGO_SCRIPT"
  bash -n "$NGINX_SCRIPT"

  if [[ "$INCLUDE_MYSQL_PASOS" == "true" ]]; then
    require_file "$MYSQL_PASOS_SCRIPT"
    bash -n "$MYSQL_PASOS_SCRIPT"
  fi

  ok "Sintaxis validada"
}

print_plan() {
  echo
  echo "Plan de ejecucion:"
  echo "  1) Redes base (DNS bloque 1)"
  echo "  2) DNS: crear VMs + configurar principal y delegado + validar"
  echo "  3) MySQL infra: crear VMs de MariaDB/MaxScale"
  echo "  4) (Opcional) MySQL servicio: Galera + MaxScale (mysql-pasos)"
  echo "  5) Crear VMs Django (automatico): appDjango1/2/3 via create-kvm-vm.sh"
  echo "  6) Django: runtime + settings + Gunicorn + validacion"
  echo "  7) Nginx LB: crear LBs + configurar + validar"
  echo "  8) Nota final: si necesitas, imprimir comandos DNS manuales del LB bloque 4"
}

run_checked() {
  local script="$1"
  local block="$2"
  log "Ejecutando: $(basename "$script") $block"
  bash "$script" "$block"
}

confirm_django_manual_creation() {
  local create="$BASE_DIR/create-kvm-vm.sh"
  local vm_user="${VM_USER:-userinfrakv}"
  local vm_pass="${VM_PASSWORD:-passphrase2620-07}"
  local extra="192.168.10.10 ns1.mimas.net dns-principal;192.168.10.11 ns1.ti.mimas.net dns-delegado;192.168.10.20 lb1.ti.mimas.net lb1;192.168.10.21 lb2.ti.mimas.net lb2;192.168.20.10 app1.ti.mimas.net appDjango1;192.168.20.11 app2.ti.mimas.net appDjango2;192.168.20.12 app3.ti.mimas.net appDjango3;192.168.30.20 db.ti.mimas.net maxscale-1"

  echo
  echo "******************************************************************"
  echo "PASO MANUAL: crear las tres VMs Django con interfaces correctas."
  echo "Copia y ejecuta estos tres comandos:"
  echo
  echo "bash $create \\"
  echo "  --name appDjango1 --hostname app1.ti.mimas.net \\"
  echo "  --user $vm_user --password '$vm_pass' \\"
  echo "  --ram 4096 --vcpus 2 --system-disk 30 --data-disk 0 \\"
  echo "  --libvirt-nets 'red-backend;red-db-redis' \\"
  echo "  --ifaces 'enp1s0,192.168.20.10/24,192.168.20.1,192.168.10.10,8.8.8.8;enp2s0,192.168.30.30/24,,192.168.10.10,8.8.8.8' \\"
  echo "  --extra-hosts '$extra'"
  echo
  echo "bash $create \\"
  echo "  --name appDjango2 --hostname app2.ti.mimas.net \\"
  echo "  --user $vm_user --password '$vm_pass' \\"
  echo "  --ram 4096 --vcpus 2 --system-disk 30 --data-disk 0 \\"
  echo "  --libvirt-nets 'red-backend;red-db-redis' \\"
  echo "  --ifaces 'enp1s0,192.168.20.11/24,192.168.20.1,192.168.10.10,8.8.8.8;enp2s0,192.168.30.31/24,,192.168.10.10,8.8.8.8' \\"
  echo "  --extra-hosts '$extra'"
  echo
  echo "bash $create \\"
  echo "  --name appDjango3 --hostname app3.ti.mimas.net \\"
  echo "  --user $vm_user --password '$vm_pass' \\"
  echo "  --ram 4096 --vcpus 2 --system-disk 30 --data-disk 0 \\"
  echo "  --libvirt-nets 'red-backend;red-db-redis' \\"
  echo "  --ifaces 'enp1s0,192.168.20.12/24,192.168.20.1,192.168.10.10,8.8.8.8;enp2s0,192.168.30.32/24,,192.168.10.10,8.8.8.8' \\"
  echo "  --extra-hosts '$extra'"
  echo
  echo "  Interfaces por VM:"
  echo "    enp1s0 -> red-backend  (LB accede aqui para trafico HTTP)"
  echo "    enp2s0 -> red-db-redis (Django accede MaxScale 192.168.30.20 y Redis desde aqui)"
  echo "******************************************************************"

  if [[ "$AUTO_APPROVE_DJANGO" == "true" ]]; then
    log "AUTO_APPROVE_DJANGO=true, se omite confirmacion interactiva"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    err "No hay TTY para confirmar creacion manual de VMs Django"
    err "Vuelve a correr con AUTO_APPROVE_DJANGO=true cuando ya existan las VMs"
    exit 1
  fi

  local answer
  read -r -p "Escribe SI para continuar cuando las VMs Django ya esten listas: " answer
  if [[ "$answer" != "SI" ]]; then
    err "Confirmacion no recibida, abortando despliegue"
    exit 1
  fi
}

run_full_deploy() {
  print_plan

  step "Redes base"
  run_checked "$DNS_SCRIPT" 1

  step "DNS completo"
  run_checked "$DNS_SCRIPT" 2
  run_checked "$DNS_SCRIPT" 3
  run_checked "$DNS_SCRIPT" 4
  run_checked "$DNS_SCRIPT" 5

  step "MySQL infraestructura (VMs)"
  run_checked "$MYSQL_SCRIPT" 2

  if [[ "$INCLUDE_MYSQL_PASOS" == "true" ]]; then
    step "MySQL servicio (Galera + MaxScale)"
    run_checked "$MYSQL_PASOS_SCRIPT" all
  else
    log "INCLUDE_MYSQL_PASOS=false, se omite configuracion de servicio MySQL"
  fi

  step "Crear VMs Django (automatico)"
  run_checked "$DJANGO_SCRIPT" create-vms

  step "Django completo"
  run_checked "$DJANGO_SCRIPT" all

  step "Nginx dominio completo"
  run_checked "$NGINX_SCRIPT" all

  step "Comandos DNS manuales de soporte (informativo)"
  run_checked "$NGINX_SCRIPT" 4

  ok "Despliegue finalizado"
}

usage() {
  cat <<'EOF'
Uso: bash configuraciones-despliegue.sh <accion>

Acciones:
  precheck              Valida archivos requeridos y sintaxis
  check                 Alias de precheck
  run                   Ejecuta despliegue completo (incluye mysql-pasos)
  run-sin-mysql-pasos   Ejecuta despliegue sin scripts/mysql-pasos.bash

Variables opcionales:
  AUTO_APPROVE_DJANGO=true
  INCLUDE_MYSQL_PASOS=false
EOF
}

main() {
  require_file "$DNS_SCRIPT"
  require_file "$MYSQL_SCRIPT"
  require_file "$DJANGO_SCRIPT"
  require_file "$NGINX_SCRIPT"

  local action="${1:-}"
  case "$action" in
    precheck|check)
      syntax_check
      ;;
    run)
      INCLUDE_MYSQL_PASOS=true
      syntax_check
      run_full_deploy
      ;;
    run-sin-mysql-pasos)
      INCLUDE_MYSQL_PASOS=false
      syntax_check
      run_full_deploy
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
