#!/usr/bin/env bash
# Modo estricto de Bash:
# -e: termina si cualquier comando falla.
# -u: falla si se usa una variable no definida.
# -o pipefail: en tuberias, falla si falla cualquier comando (no solo el ultimo).
# Esto evita errores silenciosos y estados inconsistentes durante la creacion de VMs.
set -euo pipefail



# Ruta real del script en ejecucion (resuelve symlinks).
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"


# Directorio donde vive este script manual.
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"


# Dependencia local obligatoria de esta carpeta.
# Configura las llaves SSH compartidas y funciones comunes para crear VMs con cloud-init.
# Configura el autorized_keys para permitir acceso SSH desde el host usando la misma llave del proyecto.
# Modifica el cloud-init generado para incluir la llave publica del host si existe, evitando duplicados.
# Crea el first boot script opcionalmente, y lo anexa al cloud-init para ejecucion automatica en el primer arranque.
# Agrega comandos runcmd para normalizar saltos de linea CRLF
# Contruye el contenido de etc/hosts con las IPs y hostnames de las interfaces definidas, y lo inyecta en cloud-init.
# Genera el netplan de cloud-init a partir de la especificacion de interfaces, incluyendo configuracion de IP estatica si se define una MAC primaria.
# Genera el hostname y usuarios
# Ejecuta los comandos de inicio para la VM, incluyendo la creacion de discos, cloud-init y la VM con virt-install.
COMMON_SCRIPT="$SCRIPT_DIR/vm-common.sh"

# Validar en caso de no encontrar el script
if [[ ! -f "$COMMON_SCRIPT" ]]; then
  echo "[ERROR] No se encontro vm-common.sh junto a create-kvm-vm.sh en: $SCRIPT_DIR"
  exit 1
fi

# Forza el uso de llaves locales de esta carpeta manual.
export SSH_KEYS_DIR="$SCRIPT_DIR/ssh-keys"
export SSH_PRIVATE_KEY="$SSH_KEYS_DIR/id_rsa"
export SSH_PUBLIC_KEY="$SSH_KEYS_DIR/id_rsa.pub"

source "$COMMON_SCRIPT"

IMG_DIR="${IMG_DIR:-/var/lib/libvirt/images}"
BASE_IMG="${BASE_IMG:-$IMG_DIR/ubuntu-22.04-base.qcow2}"

VM_NAME=""
VM_HOSTNAME=""
VM_USER="${VM_USER:-ceph}"
VM_PASSWORD="${VM_PASSWORD:-ceph1234}"
RAM_MB="2048"
VCPUS="2"
SYSTEM_DISK_GB="20"
DATA_DISK_GB="0"
LIBVIRT_NETS="ceph-net"
IFACES_SPEC="enp1s0,192.168.5.40/24,192.168.5.1,8.8.8.8,8.8.4.4"
EXTRA_HOSTS=""
FIRST_BOOT_SCRIPT="${FIRST_BOOT_SCRIPT:-}"
PRIMARY_MAC="${PRIMARY_MAC:-}"
COMMANDS_ONLY="false"
LOGS_DIR="${LOGS_DIR:-$SCRIPT_DIR/logs}"
COMMANDS_FILE=""

resolve_commands_output_file() {
  local bucket_min
  bucket_min=$(( (10#$(date +%M) / 10) * 10 ))
  printf '%s/%s-%02d.txt' "$LOGS_DIR" "$(date +%m-%d-%H)" "$bucket_min"
}

init_commands_file() {
  [[ -n "$COMMANDS_FILE" ]] || COMMANDS_FILE="$(resolve_commands_output_file)"
  mkdir -p "$(dirname "$COMMANDS_FILE")"
  if [[ ! -f "$COMMANDS_FILE" ]]; then
    {
      echo "#!/usr/bin/env bash"
      echo "set -euo pipefail"
      echo
      echo "# Archivo generado por create-kvm-vm.sh --comandos"
      echo "# Ejecuta este archivo cuando quieras crear las VMs manualmente."
      echo
    } > "$COMMANDS_FILE"
    chmod +x "$COMMANDS_FILE"
  fi
}

append_file_as_heredoc() {
  local target_file="$1"
  local source_file="$2"

  {
    printf "cat > %q <<'EOF'\n" "$target_file"
    cat "$source_file"
    echo "EOF"
    echo
  } >> "$COMMANDS_FILE"
}

append_vm_commands() {
  local cloud_file="$1"
  local network_file="$2"

  init_commands_file

  {
    echo "# $(date '+%Y-%m-%d %H:%M:%S') ------------------------------------------------"
    echo "# VM: $VM_NAME"
    echo "# Paso 1: validar imagen base"
    printf "test -f %q || { echo '[ERROR] Falta imagen base: %s'; exit 1; }\n" "$BASE_IMG" "$BASE_IMG"
    echo

    echo "# Paso 2: generar disco del sistema (si no existe)"
    printf "if [[ ! -f %q ]]; then\n" "$SYSTEM_DISK"
    printf "  sudo qemu-img create -f qcow2 -b %q -F qcow2 %q %q\n" "$BASE_IMG" "$SYSTEM_DISK" "${SYSTEM_DISK_GB}G"
    echo "fi"
    echo

    if [[ "$DATA_DISK_GB" -gt 0 ]]; then
      echo "# Paso 3: generar disco de datos (si no existe)"
      printf "if [[ ! -f %q ]]; then\n" "$DATA_DISK"
      printf "  sudo qemu-img create -f qcow2 %q %q\n" "$DATA_DISK" "${DATA_DISK_GB}G"
      echo "fi"
      echo
    fi

    echo "# Paso 4: crear cloud-init user-data"
  } >> "$COMMANDS_FILE"

  append_file_as_heredoc "$cloud_file" "$cloud_file"

  {
    echo "# Paso 5: crear cloud-init network-config"
  } >> "$COMMANDS_FILE"

  append_file_as_heredoc "$network_file" "$network_file"

  {
    echo "# Paso 6: crear VM con virt-install"
    echo "if ! sudo virsh dominfo $(printf '%q' "$VM_NAME") >/dev/null 2>&1; then"
    echo '  sudo virt-install \'
  } >> "$COMMANDS_FILE"

  {
    printf "    --name %q \\\n" "$VM_NAME"
    printf "    --ram %q \\\n" "$RAM_MB"
    printf "    --vcpus %q \\\n" "$VCPUS"
    printf "    --disk %q \\\n" "path=$SYSTEM_DISK,format=qcow2"
    if [[ "$DATA_DISK_GB" -gt 0 ]]; then
      printf "    --disk %q \\\n" "path=$DATA_DISK,format=qcow2"
    fi
    for net_arg in "${VIRT_NETWORK_ARGS[@]}"; do
      printf "    --network %q \\\n" "$net_arg"
    done
    printf "    --os-variant %q \\\n" "ubuntu22.04"
    printf "    --cloud-init %q \\\n" "user-data=$cloud_file,network-config=$network_file"
    printf "    --noautoconsole \\\n"
    printf "    --import\n"
    echo "else"
    printf "  echo %q\n" "[WARN] La VM $VM_NAME ya existe en libvirt. Se omite creacion."
    echo "fi"
    echo
  } >> "$COMMANDS_FILE"
}

generate_vm_mac() {
  local seed="$1"
  local hash
  hash="$(printf '%s' "$seed" | md5sum | awk '{print $1}')"
  printf '52:54:00:%s:%s:%s' "${hash:0:2}" "${hash:2:2}" "${hash:4:2}"
}

usage() {
  cat <<'EOF'
Uso:
  bash create-kvm-vm.sh \
    --name ceph-admin \
    --hostname ceph-admin \
    --user ceph \
    --password 'Ceph1234!' \
    --ram 2048 \
    --vcpus 2 \
    --system-disk 20 \
    --data-disk 0 \
    --libvirt-nets "ceph-net" \
    --ifaces "enp1s0,192.168.5.40/24,192.168.5.1,8.8.8.8,8.8.4.4" \
    --extra-hosts "192.168.5.40 ceph-admin;192.168.5.41 ceph-mon" \
    --first-boot-script "$PWD/first-boot-example.sh" \
    --primary-mac "52:54:00:aa:bb:cc"

Notas:
- --user define el usuario admin dentro de la VM.
- --password define la contrasenia del usuario de la VM.
- --ifaces permite una o varias interfaces separadas por ';'.
- Formato por interfaz: nombre,ip_cidr,gateway,dns1,dns2
  (Tambien soporta dns1|dns2 por compatibilidad)
- --first-boot-script es opcional y se ejecuta una sola vez en el primer arranque.
- --primary-mac fija la MAC de la NIC principal para aplicar IP estatica de forma confiable.
- --comandos no crea la VM. Genera un archivo con comandos paso a paso comentados para crearla manualmente.
- --comandos-file permite definir el archivo de salida para los comandos generados.
- --logs-dir define el directorio para el archivo generado si no envias --comandos-file.

Ejemplo 2 interfaces (comentado):
# --ifaces "enp1s0,192.168.5.42/24,192.168.5.1,8.8.8.8,8.8.4.4;enp2s0,10.10.10.12/24,,10.10.10.1"

- --libvirt-nets permite adjuntar una o varias redes libvirt separadas por ';'.
  Ejemplo: --libvirt-nets "ceph-net;storage-net"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      VM_NAME="$2"
      shift 2
      ;;
    --hostname)
      VM_HOSTNAME="$2"
      shift 2
      ;;
    --user)
      VM_USER="$2"
      shift 2
      ;;
    --password)
      VM_PASSWORD="$2"
      shift 2
      ;;
    --ram)
      RAM_MB="$2"
      shift 2
      ;;
    --vcpus)
      VCPUS="$2"
      shift 2
      ;;
    --system-disk)
      SYSTEM_DISK_GB="$2"
      shift 2
      ;;
    --data-disk)
      DATA_DISK_GB="$2"
      shift 2
      ;;
    --libvirt-nets)
      LIBVIRT_NETS="$2"
      shift 2
      ;;
    --ifaces)
      IFACES_SPEC="$2"
      shift 2
      ;;
    --extra-hosts)
      EXTRA_HOSTS="$2"
      shift 2
      ;;
    --first-boot-script)
      FIRST_BOOT_SCRIPT="$2"
      shift 2
      ;;
    --primary-mac)
      PRIMARY_MAC="$2"
      shift 2
      ;;
    --comandos)
      COMMANDS_ONLY="true"
      shift
      ;;
    --comandos-file)
      COMMANDS_FILE="$2"
      shift 2
      ;;
    --logs-dir)
      LOGS_DIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Opcion no valida: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$VM_NAME" ]]; then
  echo "[ERROR] --name es obligatorio"
  usage
  exit 1
fi

if [[ -z "$VM_USER" ]]; then
  echo "[ERROR] --user no puede quedar vacio"
  exit 1
fi

if [[ -z "$VM_PASSWORD" ]]; then
  echo "[ERROR] --password no puede quedar vacio"
  exit 1
fi

if [[ -n "${FIRST_BOOT_SCRIPT// }" && ! -f "$FIRST_BOOT_SCRIPT" ]]; then
  echo "[ERROR] No existe --first-boot-script: $FIRST_BOOT_SCRIPT"
  exit 1
fi

if [[ -z "$PRIMARY_MAC" ]]; then
  PRIMARY_MAC="$(generate_vm_mac "$VM_NAME")"
fi

if [[ -z "$VM_HOSTNAME" ]]; then
  VM_HOSTNAME="$VM_NAME"
fi

if [[ ! -f "$BASE_IMG" ]]; then
  echo "[ERROR] No existe imagen base: $BASE_IMG"
  echo "Descargala con:"
  echo "sudo wget -O $BASE_IMG https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  exit 1
fi

ensure_shared_ssh_keys

# Disco principal de la VM (SO) en el storage de libvirt.
SYSTEM_DISK="$IMG_DIR/${VM_NAME}.qcow2"
# Disco secundario opcional para datos persistentes de la VM.
DATA_DISK="$IMG_DIR/${VM_NAME}-data.qcow2"
# Archivo temporal cloud-init con usuarios, llaves, paquetes y runcmd.
CLOUD_FILE="/tmp/user-data-${VM_NAME}.yaml"
# Archivo temporal cloud-init para netplan (interfaces, IP, gateway, DNS).
NETWORK_FILE="/tmp/network-config-${VM_NAME}.yaml"

write_cloud_init "$CLOUD_FILE" "$VM_HOSTNAME" "$VM_USER" "$VM_PASSWORD" "$IFACES_SPEC" "$EXTRA_HOSTS" "$FIRST_BOOT_SCRIPT" "$PRIMARY_MAC"
write_network_config "$NETWORK_FILE" "$IFACES_SPEC" "$PRIMARY_MAC"

VIRT_NETWORK_ARGS=()
IFS=';' read -r -a nets_array <<< "$LIBVIRT_NETS"
net_index=0
for net_name in "${nets_array[@]}"; do
  [[ -z "${net_name// }" ]] && continue
  if [[ $net_index -eq 0 ]]; then
    VIRT_NETWORK_ARGS+=("network=${net_name},model=virtio,mac=${PRIMARY_MAC}")
  else
    VIRT_NETWORK_ARGS+=("network=${net_name},model=virtio")
  fi
  net_index=$((net_index + 1))
done

EXEC_NETWORK_ARGS=()
for net_arg in "${VIRT_NETWORK_ARGS[@]}"; do
  EXEC_NETWORK_ARGS+=(--network "$net_arg")
done

if [[ "$COMMANDS_ONLY" == "true" ]]; then
  append_vm_commands "$CLOUD_FILE" "$NETWORK_FILE"
  echo "[OK] Comandos generados para $VM_NAME"
  echo "[INFO] Archivo: $COMMANDS_FILE"
  exit 0
fi

if ! sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  if [[ ! -f "$SYSTEM_DISK" ]]; then
    sudo qemu-img create -f qcow2 -b "$BASE_IMG" -F qcow2 "$SYSTEM_DISK" "${SYSTEM_DISK_GB}G"
  fi

  if [[ "$DATA_DISK_GB" -gt 0 ]]; then
    if [[ ! -f "$DATA_DISK" ]]; then
      sudo qemu-img create -f qcow2 "$DATA_DISK" "${DATA_DISK_GB}G"
    fi

    # Ejemplo del comando real:
    # sudo virt-install --name appDjango1 --ram 4096 --vcpus 2 \
    #   --disk path=/var/lib/libvirt/images/appDjango1.qcow2,format=qcow2 \
    #   --disk path=/var/lib/libvirt/images/appDjango1-data.qcow2,format=qcow2 \
    #   --network network=red-backend,model=virtio,mac=52:54:00:xx:yy:zz \
    #   --network network=red-db-redis,model=virtio \
    #   --os-variant ubuntu22.04 \
    #   --cloud-init user-data=/tmp/user-data-appDjango1.yaml,network-config=/tmp/network-config-appDjango1.yaml \
    #   --noautoconsole --import
    # Parametros:
    # --name: nombre del dominio en libvirt.
    # --ram: memoria RAM en MB.
    # --vcpus: cantidad de CPU virtuales.
    # --disk: define los discos de la VM (path + formato).
    # --network: NICs conectadas a redes libvirt definidas arriba.
    # --os-variant: optimiza defaults para Ubuntu 22.04.
    # --cloud-init: inyecta user-data y network-config al primer arranque.
    # --noautoconsole: no abrir consola interactiva al crear.
    # --import: usa la imagen qcow2 existente como base (sin instalador ISO).
    sudo virt-install \
      --name "$VM_NAME" \
      --ram "$RAM_MB" \
      --vcpus "$VCPUS" \
      --disk "path=$SYSTEM_DISK,format=qcow2" \
      --disk "path=$DATA_DISK,format=qcow2" \
      "${EXEC_NETWORK_ARGS[@]}" \
      --os-variant ubuntu22.04 \
      --cloud-init "user-data=$CLOUD_FILE,network-config=$NETWORK_FILE" \
      --noautoconsole \
      --import
  else
    # Mismo comando, pero solo con disco de sistema cuando --data-disk=0.
    sudo virt-install \
      --name "$VM_NAME" \
      --ram "$RAM_MB" \
      --vcpus "$VCPUS" \
      --disk "path=$SYSTEM_DISK,format=qcow2" \
      "${EXEC_NETWORK_ARGS[@]}" \
      --os-variant ubuntu22.04 \
      --cloud-init "user-data=$CLOUD_FILE,network-config=$NETWORK_FILE" \
      --noautoconsole \
      --import
  fi
else
  echo "[WARN] La VM $VM_NAME ya existe en libvirt. Se omite creacion."
fi

echo "[OK] VM procesada: $VM_NAME"
echo "[INFO] MAC primaria configurada: $PRIMARY_MAC"

vm_ip="$(sudo virsh domifaddr "$VM_NAME" --source agent 2>/dev/null | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}' || true)"
if [[ -z "${vm_ip// }" ]]; then
  vm_ip="$(sudo virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}' || true)"
fi

if [[ -n "${vm_ip// }" ]]; then
  echo "[INFO] IP detectada para $VM_NAME: $vm_ip"
  echo "[INFO] Conexion sugerida: ssh $VM_USER@$vm_ip"
else
  echo "[INFO] No se pudo detectar IP automaticamente para $VM_NAME."
  echo "[INFO] Verifica manualmente con: sudo virsh domifaddr $VM_NAME --source agent"
fi
