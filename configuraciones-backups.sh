#!/usr/bin/env bash
set -euo pipefail

# Full KVM/libvirt environment backup:
# 1) Graceful shutdown of all defined VMs
# 2) Export each VM XML definition
# 3) Copy each disk attached as "disk"
# 4) Optional compression of backup directory

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backups-lab}"
TIMESTAMP="$(date +%F-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-$BACKUP_ROOT/cluster-$TIMESTAMP}"
COMPRESS="${COMPRESS:-0}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

copy_disk() {
  local src="$1"
  local dst="$2"

  if cp --reflink=auto --sparse=always "$src" "$dst" 2>/dev/null; then
    return 0
  fi

  if sudo -n cp --reflink=auto --sparse=always "$src" "$dst"; then
    sudo -n chown "$(id -u):$(id -g)" "$dst" || true
    return 0
  fi

  return 1
}

mkdir -p "$BACKUP_DIR"

mapfile -t VMS < <(virsh list --all --name | sed '/^$/d')

if [[ ${#VMS[@]} -eq 0 ]]; then
  echo "No hay VMs definidas en libvirt."
  exit 0
fi

echo "Backup destino: $BACKUP_DIR"
echo "VMs detectadas: ${#VMS[@]}"
printf ' - %s\n' "${VMS[@]}"

echo
echo "[1/5] Apagando VMs de forma ordenada..."
for vm in "${VMS[@]}"; do
  state="$(virsh domstate "$vm" 2>/dev/null | tr -d '\r')"
  if [[ "$state" != "shut off" ]]; then
    echo "  -> shutdown $vm"
    virsh shutdown "$vm" >/dev/null || true
  else
    echo "  -> $vm ya estaba apagada"
  fi
done

echo
echo "[2/5] Esperando apagado completo (timeout ${WAIT_TIMEOUT}s por VM)..."
for vm in "${VMS[@]}"; do
  waited=0
  while true; do
    state="$(virsh domstate "$vm" 2>/dev/null | tr -d '\r')"
    if [[ "$state" == "shut off" ]]; then
      echo "  -> $vm apagada"
      break
    fi

    if (( waited >= WAIT_TIMEOUT )); then
      echo "  -> timeout en $vm, forzando apagado"
      virsh destroy "$vm" >/dev/null || true
      break
    fi

    sleep 2
    waited=$((waited + 2))
  done
done

echo
echo "[3/5] Exportando XML y copiando discos..."
for vm in "${VMS[@]}"; do
  echo "  -> respaldo de $vm"
  virsh dumpxml "$vm" > "$BACKUP_DIR/$vm.xml"

  disk_index=0
  while read -r target source; do
    [[ -z "$source" ]] && continue
    disk_index=$((disk_index + 1))
    ext="${source##*.}"
    [[ "$ext" == "$source" ]] && ext="img"
    dst="$BACKUP_DIR/${vm}-disk${disk_index}-${target}.${ext}"
    echo "     copiando $source -> $dst"
    if ! copy_disk "$source" "$dst"; then
      echo "     error: no fue posible copiar $source"
      exit 1
    fi
  done < <(virsh domblklist "$vm" --details | awk '$2=="disk" && $4!="-" {print $3, $4}')

  if (( disk_index == 0 )); then
    echo "     aviso: no se detectaron discos para $vm"
  fi
done

echo
echo "[4/5] Generando manifest..."
{
  echo "timestamp=$TIMESTAMP"
  echo "backup_dir=$BACKUP_DIR"
  echo "host=$(hostname -f 2>/dev/null || hostname)"
  echo "vm_count=${#VMS[@]}"
  printf 'vm=%s\n' "${VMS[@]}"
} > "$BACKUP_DIR/manifest.txt"

echo
if [[ "$COMPRESS" == "1" ]]; then
  echo "[5/5] Comprimiendo backup con zstd..."
  if command -v zstd >/dev/null 2>&1; then
    tar -I 'zstd -19 -T0' -cf "${BACKUP_DIR}.tar.zst" -C "$(dirname "$BACKUP_DIR")" "$(basename "$BACKUP_DIR")"
    echo "Archivo comprimido: ${BACKUP_DIR}.tar.zst"
  else
    echo "zstd no disponible. Omitiendo compresion."
  fi
else
  echo "[5/5] Compresion omitida (COMPRESS=0)."
fi

echo
echo "Backup completado: $BACKUP_DIR"