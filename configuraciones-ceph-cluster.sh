#!/usr/bin/env bash
set -euo pipefail

# Configuracion base Ceph (1 nodo activo) con flujo por bloques.
# Nota: el nombre del archivo sigue la solicitud del usuario (cep).
#
# Uso:
#   bash configuraciones-ceph-cluster.sh 0
#   bash configuraciones-ceph-cluster.sh 1
#   bash configuraciones-ceph-cluster.sh 2
#   bash configuraciones-ceph-cluster.sh 3
#   bash configuraciones-ceph-cluster.sh 4
#   bash configuraciones-ceph-cluster.sh 5
#   bash configuraciones-ceph-cluster.sh 6
#   bash configuraciones-ceph-cluster.sh 7
#   bash configuraciones-ceph-cluster.sh 8
#   bash configuraciones-ceph-cluster.sh 9
#   bash configuraciones-ceph-cluster.sh 10
#   bash configuraciones-ceph-cluster.sh all

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY="${KEY_OVERRIDE:-$BASE_DIR/ssh-keys/id_rsa}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8}"
VM_USER="${VM_USER:-userinfrakv}"

# Red nueva para cluster Ceph
CEPH_CLUSTER_NET="${CEPH_CLUSTER_NET:-192.168.60.0/24}"
CEPH_PUBLIC_NET="${CEPH_PUBLIC_NET:-192.168.40.0/24}"

# Nodo bootstrap (cephadm bootstrap)
CEPH_ADMIN_IP="${CEPH_ADMIN_IP:-192.168.60.11}"
CEPH_ADMIN_HOST="${CEPH_ADMIN_HOST:-ceph1.ti.mimas.net}"

# Nodos MySQL y Django para validaciones/configuracion de consumo CephFS
MYSQL_NODES=(
  "${MYSQL_NODE_1:-192.168.30.21}"
  "${MYSQL_NODE_2:-192.168.30.22}"
  "${MYSQL_NODE_3:-192.168.30.23}"
)

DJANGO_NODES=(
  "${DJANGO_NODE_1:-192.168.20.10}"
  "${DJANGO_NODE_2:-192.168.20.11}"
  "${DJANGO_NODE_3:-192.168.20.12}"
)

# CephFS para media de Django
CEPHFS_NAME="${CEPHFS_NAME:-cephfs_django}"
CEPHFS_DATA_POOL="${CEPHFS_DATA_POOL:-cephfs_django_data}"
CEPHFS_METADATA_POOL="${CEPHFS_METADATA_POOL:-cephfs_django_metadata}"
CEPHFS_CLIENT_ID="${CEPHFS_CLIENT_ID:-django}"
DJANGO_MEDIA_MOUNT="${DJANGO_MEDIA_MOUNT:-/srv/django-media}"

# Inventario Ceph activo (1 nodo)
# Formato: hostname_corto:ip (debe coincidir con 'hostname -f' del nodo)
CEPH_NODES=(
  "ceph1:192.168.60.11"
)

if [[ ! -r "$KEY" ]]; then
  echo "[ERROR] No se puede leer la clave SSH: $KEY"
  exit 1
fi

ssh_cmd() {
  local ip="$1"
  shift
  ssh -i "$KEY" $SSH_OPTS "${VM_USER}@${ip}" "$@"
}

wait_for_ssh_node() {
  local ip="$1"
  local retries="${WAIT_SSH_RETRIES:-60}"
  local sleep_s="${WAIT_SSH_SLEEP:-5}"
  local i=1

  while (( i <= retries )); do
    if ssh -i "$KEY" $SSH_OPTS "${VM_USER}@${ip}" "echo ready" >/dev/null 2>&1; then
      echo "[OK] SSH listo en $ip"
      return 0
    fi
    echo "[INFO] Esperando SSH en $ip (intento $i/$retries)"
    sleep "$sleep_s"
    i=$((i + 1))
  done

  echo "[ERROR] No hubo SSH en $ip"
  return 1
}

block_0_preflight() {
  echo "[INFO] Verificando acceso SSH al inventario Ceph activo"
  local node ip
  for node in "${CEPH_NODES[@]}"; do
    ip="${node#*:}"
    wait_for_ssh_node "$ip"
  done
}

block_1_install_cephadm_prereqs() {
  echo "[INFO] Instalando prerequisitos Ceph en nodos activos"
  local node ip
  for node in "${CEPH_NODES[@]}"; do
    ip="${node#*:}"
    ssh_cmd "$ip" "sudo bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl lvm2 chrony podman cephadm ceph-common
systemctl enable --now chrony || true
REMOTE
  done
}

block_2_bootstrap_cluster() {
  echo "[INFO] Bootstrap de Ceph en ${CEPH_ADMIN_IP}"
  ssh_cmd "$CEPH_ADMIN_IP" "sudo bash -s" <<REMOTE
set -euo pipefail
if [[ -f /etc/ceph/ceph.conf ]] && sudo ceph -s >/dev/null 2>&1; then
  echo "[INFO] Ceph ya estaba inicializado en este nodo"
  exit 0
fi

sudo cephadm bootstrap \
  --mon-ip ${CEPH_ADMIN_IP} \
  --cluster-network ${CEPH_CLUSTER_NET} \
  --allow-fqdn-hostname \
  --initial-dashboard-user admin \
  --initial-dashboard-password admin123
REMOTE
}

block_3_add_hosts_to_orchestrator() {
  echo "[INFO] Distribuyendo clave SSH de cephadm a nodos secundarios"
  local ceph_pub
  ceph_pub="$(ssh_cmd "$CEPH_ADMIN_IP" "sudo cat /etc/ceph/ceph.pub")"

  local node ip
  for node in "${CEPH_NODES[@]}"; do
    ip="${node#*:}"
    [[ "$ip" == "$CEPH_ADMIN_IP" ]] && continue
    ssh_cmd "$ip" "sudo bash -s" <<REMOTE
mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo '${ceph_pub}' | sudo tee -a /root/.ssh/authorized_keys >/dev/null
chmod 600 /root/.ssh/authorized_keys
REMOTE
    echo "[OK] Clave copiada en $ip"
  done

  echo "[INFO] Registrando hosts Ceph en el orchestrator"
  local host
  for node in "${CEPH_NODES[@]}"; do
    host="${node%%:*}"
    ip="${node#*:}"
    ssh_cmd "$CEPH_ADMIN_IP" "sudo ceph orch host add ${host} ${ip}" || true
  done

  ssh_cmd "$CEPH_ADMIN_IP" "sudo ceph orch host ls"
}

block_4_apply_services() {
  echo "[INFO] Aplicando MON/MGR para inventario activo"
  local hosts_csv
  hosts_csv="$(printf '%s,' "${CEPH_NODES[@]%%:*}")"
  hosts_csv="${hosts_csv%,}"

  ssh_cmd "$CEPH_ADMIN_IP" "sudo bash -s" <<REMOTE
set -euo pipefail
sudo ceph orch apply mon --placement="1 ${hosts_csv}"
sudo ceph orch apply mgr --placement="1 ${hosts_csv}"
REMOTE

  ssh_cmd "$CEPH_ADMIN_IP" "sudo ceph orch ps"
}

block_5_prepare_osd() {
  echo "[INFO] Preparando OSDs (modo all-available-devices)"
  ssh_cmd "$CEPH_ADMIN_IP" "sudo ceph orch apply osd --all-available-devices"
  ssh_cmd "$CEPH_ADMIN_IP" "sudo ceph orch ps --daemon_type osd"
}

block_6_validate_cluster() {
  echo "[INFO] Validando salud de cluster Ceph"
  ssh_cmd "$CEPH_ADMIN_IP" "sudo ceph -s"
  ssh_cmd "$CEPH_ADMIN_IP" "sudo ceph health detail || true"
}

block_7_disconnect_mysql_cephfs() {
  echo "[INFO] Verificando y desconectando CephFS de nodos MySQL (si aplica)"
  local ip
  for ip in "${MYSQL_NODES[@]}"; do
    wait_for_ssh_node "$ip"
    echo "[INFO] Revisando nodo MySQL $ip"
    ssh_cmd "$ip" "sudo bash -s" <<'REMOTE'
set -euo pipefail
changed=0

if mount | grep -Eiq 'type ceph|type ceph-fuse|rbd'; then
  echo "[WARN] Se detectaron montajes Ceph en MySQL, desmontando"
  while read -r mnt; do
    [[ -z "$mnt" ]] && continue
    umount "$mnt" 2>/dev/null || umount -l "$mnt" || true
    changed=1
  done < <(mount | awk '/ type ceph| type ceph-fuse|rbd/ {print $3}')
fi

if grep -Eiq 'ceph|ceph-fuse|rbd' /etc/fstab; then
  echo "[WARN] Entradas Ceph en /etc/fstab detectadas, limpiando"
  cp /etc/fstab /etc/fstab.bak.$(date +%F-%H%M%S)
  sed -i -E '/ceph|ceph-fuse|rbd/d' /etc/fstab
  changed=1
fi

if [[ "$changed" -eq 0 ]]; then
  echo "[OK] Sin uso de CephFS en este nodo MySQL"
else
  echo "[OK] Nodo MySQL desacoplado de CephFS"
fi
REMOTE
  done
}

block_8_prepare_cephfs_for_django() {
  echo "[INFO] Creando/ajustando CephFS para almacenamiento Django"
  ssh_cmd "$CEPH_ADMIN_IP" "sudo bash -s" <<REMOTE
set -euo pipefail

# En laboratorio de 1 nodo, Ceph requiere size/min_size=1 para evitar bloqueos.
sudo ceph config set global osd_pool_default_size 1
sudo ceph config set global osd_pool_default_min_size 1

sudo ceph osd pool set ${CEPHFS_METADATA_POOL} size 1 --yes-i-really-mean-it 2>/dev/null || true
sudo ceph osd pool set ${CEPHFS_METADATA_POOL} min_size 1 2>/dev/null || true
sudo ceph osd pool set ${CEPHFS_DATA_POOL} size 1 --yes-i-really-mean-it 2>/dev/null || true
sudo ceph osd pool set ${CEPHFS_DATA_POOL} min_size 1 2>/dev/null || true

if ! sudo ceph osd pool ls | grep -qx '${CEPHFS_METADATA_POOL}'; then
  sudo ceph osd pool create ${CEPHFS_METADATA_POOL} 16
fi

if ! sudo ceph osd pool ls | grep -qx '${CEPHFS_DATA_POOL}'; then
  sudo ceph osd pool create ${CEPHFS_DATA_POOL} 64
fi

if ! sudo ceph fs ls | awk '{print \$1}' | grep -qx '${CEPHFS_NAME}'; then
  sudo ceph fs new ${CEPHFS_NAME} ${CEPHFS_METADATA_POOL} ${CEPHFS_DATA_POOL}
fi

sudo ceph orch apply mds ${CEPHFS_NAME} --placement="1 ceph1" || true

sudo ceph osd pool set ${CEPHFS_METADATA_POOL} size 1 --yes-i-really-mean-it
sudo ceph osd pool set ${CEPHFS_METADATA_POOL} min_size 1
sudo ceph osd pool set ${CEPHFS_DATA_POOL} size 1 --yes-i-really-mean-it
sudo ceph osd pool set ${CEPHFS_DATA_POOL} min_size 1

sudo ceph fs ls
REMOTE

  echo "[INFO] Creando credenciales cliente CephFS para Django"
  ssh_cmd "$CEPH_ADMIN_IP" "sudo ceph auth get-or-create client.${CEPHFS_CLIENT_ID} mon 'allow r' mds 'allow rw' osd 'allow rw pool=${CEPHFS_METADATA_POOL}, allow rw pool=${CEPHFS_DATA_POOL}' >/dev/null"
}

block_9_mount_cephfs_on_django_nodes() {
  echo "[INFO] Montando CephFS en nodos Django"

  local ceph_conf ceph_key
  ceph_conf="$(ssh_cmd "$CEPH_ADMIN_IP" "sudo cat /etc/ceph/ceph.conf")"
  ceph_key="$(ssh_cmd "$CEPH_ADMIN_IP" "sudo ceph auth get-key client.${CEPHFS_CLIENT_ID}")"

  local ip
  for ip in "${DJANGO_NODES[@]}"; do
    wait_for_ssh_node "$ip"
    echo "[INFO] Configurando mount CephFS en Django $ip"
    ssh_cmd "$ip" "sudo bash -s" <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ceph-common ceph-fuse

mkdir -p /etc/ceph
cat >/etc/ceph/ceph.conf <<'CEPHCONF'
${ceph_conf}
CEPHCONF

cat >/etc/ceph/ceph.client.${CEPHFS_CLIENT_ID}.keyring <<'KEYRING'
[client.${CEPHFS_CLIENT_ID}]
  key = ${ceph_key}
KEYRING

echo '${ceph_key}' >/etc/ceph/client.${CEPHFS_CLIENT_ID}.secret
chmod 600 /etc/ceph/client.${CEPHFS_CLIENT_ID}.secret
chmod 600 /etc/ceph/ceph.client.${CEPHFS_CLIENT_ID}.keyring

mkdir -p ${DJANGO_MEDIA_MOUNT}

if mountpoint -q ${DJANGO_MEDIA_MOUNT}; then
  umount ${DJANGO_MEDIA_MOUNT} || umount -l ${DJANGO_MEDIA_MOUNT} || true
fi

cat >/etc/systemd/system/cephfs-django.service <<'UNIT'
[Unit]
Description=CephFS mount for Django media
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/bin/ceph-fuse -n client.${CEPHFS_CLIENT_ID} --client_fs ${CEPHFS_NAME} ${DJANGO_MEDIA_MOUNT}
ExecStop=/bin/fusermount -u ${DJANGO_MEDIA_MOUNT}
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now cephfs-django.service
REMOTE
  done
}

block_10_validate_django_cephfs() {
  echo "[INFO] Validando CephFS montado en Django"
  local ip
  for ip in "${DJANGO_NODES[@]}"; do
    echo "[INFO] Validando nodo Django $ip"
    ssh_cmd "$ip" "sudo bash -s" <<REMOTE
set -euo pipefail
mountpoint -q ${DJANGO_MEDIA_MOUNT}
touch ${DJANGO_MEDIA_MOUNT}/.cephfs-django-test
ls -la ${DJANGO_MEDIA_MOUNT} | head -n 5
REMOTE
  done
}

usage() {
  cat <<'EOF'
Uso: bash configuraciones-ceph-cluster.sh <bloque>

Bloques:
  0   Preflight SSH de nodos activos
  1   Instalar prerequisitos (cephadm/ceph-common/podman/lvm2/chrony)
  2   Bootstrap del cluster en ceph1
  3   Agregar hosts al orchestrator
  4   Aplicar MON/MGR
  5   Aplicar OSD sobre discos disponibles
  6   Validar estado del cluster
  7   Desconectar CephFS de MySQL (solo si detecta uso)
  8   Crear/Ajustar CephFS para Django
  9   Montar CephFS en appDjango1/appDjango2/appDjango3
  10  Validar montaje CephFS en Django
  all Ejecutar 0,1,2,3,4,5,6,7,8,9,10

Variables utiles:
  KEY_OVERRIDE, VM_USER, SSH_OPTS
  CEPH_CLUSTER_NET, CEPH_PUBLIC_NET
  CEPH_ADMIN_IP, CEPH_ADMIN_HOST
  MYSQL_NODE_1..3, DJANGO_NODE_1..3
  CEPHFS_NAME, CEPHFS_DATA_POOL, CEPHFS_METADATA_POOL
  CEPHFS_CLIENT_ID, DJANGO_MEDIA_MOUNT
EOF
}

main() {
  local block="${1:-}"
  case "$block" in
    0) block_0_preflight ;;
    1) block_1_install_cephadm_prereqs ;;
    2) block_2_bootstrap_cluster ;;
    3) block_3_add_hosts_to_orchestrator ;;
    4) block_4_apply_services ;;
    5) block_5_prepare_osd ;;
    6) block_6_validate_cluster ;;
    7) block_7_disconnect_mysql_cephfs ;;
    8) block_8_prepare_cephfs_for_django ;;
    9) block_9_mount_cephfs_on_django_nodes ;;
    10) block_10_validate_django_cephfs ;;
    all)
      block_0_preflight
      block_1_install_cephadm_prereqs
      block_2_bootstrap_cluster
      block_3_add_hosts_to_orchestrator
      block_4_apply_services
      block_5_prepare_osd
      block_6_validate_cluster
      block_7_disconnect_mysql_cephfs
      block_8_prepare_cephfs_for_django
      block_9_mount_cephfs_on_django_nodes
      block_10_validate_django_cephfs
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
