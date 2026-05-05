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
#   bash configuraciones-ceph-cluster.sh 11
#   bash configuraciones-ceph-cluster.sh 12
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
ExecStartPost=/bin/mkdir -p ${DJANGO_MEDIA_MOUNT}/ubicaciones
ExecStartPost=/bin/chown django:django ${DJANGO_MEDIA_MOUNT}
ExecStartPost=/bin/chmod 775 ${DJANGO_MEDIA_MOUNT}
ExecStartPost=/bin/chown django:django ${DJANGO_MEDIA_MOUNT}/ubicaciones
ExecStartPost=/bin/chmod 775 ${DJANGO_MEDIA_MOUNT}/ubicaciones
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

block_11_configure_django_photo_persistence() {
  echo "[INFO] Configurando Django para foto opcional persistente en CephFS"
  local ip
  for ip in "${DJANGO_NODES[@]}"; do
    wait_for_ssh_node "$ip"
    echo "[INFO] Ajustando app Django en $ip"
    ssh_cmd "$ip" "sudo bash -s" <<'REMOTE'
set -euo pipefail
APP_DIR="/opt/apps/mi-proyecto"
MEDIA_MOUNT="/srv/django-media"

if [[ ! -d "$APP_DIR" ]]; then
  echo "[ERROR] No existe $APP_DIR"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3-pip >/dev/null 2>&1 || true
sudo -u django /opt/apps/venv/bin/pip install --disable-pip-version-check Pillow >/dev/null

mkdir -p "$MEDIA_MOUNT" "$MEDIA_MOUNT/ubicaciones"
chown django:django "$MEDIA_MOUNT" "$MEDIA_MOUNT/ubicaciones"
chmod 775 "$MEDIA_MOUNT" "$MEDIA_MOUNT/ubicaciones"

cat >"$APP_DIR/core/models.py" <<'PYMODEL'
from django.conf import settings
from django.db import models


class Ubicacion(models.Model):
  id = models.AutoField(primary_key=True)
  usuario = models.ForeignKey(
    settings.AUTH_USER_MODEL,
    on_delete=models.CASCADE,
    related_name='ubicaciones',
  )
  latitud = models.DecimalField(max_digits=9, decimal_places=6)
  longitud = models.DecimalField(max_digits=9, decimal_places=6)
  fecha_hora = models.DateTimeField(auto_now_add=True)
  foto = models.ImageField(upload_to='ubicaciones/', null=True, blank=True)

  class Meta:
    ordering = ['-fecha_hora']

  def __str__(self):
    return f"{self.usuario.username} ({self.latitud}, {self.longitud})"
PYMODEL

cat >"$APP_DIR/core/views.py" <<'PYVIEWS'
from django.conf import settings
from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.shortcuts import redirect, render
from django.views.decorators.http import require_POST

from .models import Ubicacion


@login_required
def home(request):
  ubicaciones = Ubicacion.objects.filter(usuario=request.user)
  return render(
    request,
    'core/index.html',
    {
      'server_id': settings.SERVER_ID,
      'ubicaciones': ubicaciones,
    },
  )


@login_required
@require_POST
def guardar_ubicacion(request):
  latitud = request.POST.get('latitud')
  longitud = request.POST.get('longitud')

  if not latitud or not longitud:
    messages.error(request, 'No se recibieron coordenadas validas.')
    return redirect('home')

  try:
    latitud_float = float(latitud)
    longitud_float = float(longitud)
  except ValueError:
    messages.error(request, 'Las coordenadas deben ser numericas.')
    return redirect('home')

  if not (-90 <= latitud_float <= 90 and -180 <= longitud_float <= 180):
    messages.error(request, 'Las coordenadas estan fuera de rango.')
    return redirect('home')

  Ubicacion.objects.create(
    usuario=request.user,
    latitud=latitud_float,
    longitud=longitud_float,
    foto=request.FILES.get('foto') or None,
  )
  messages.success(request, 'Ubicacion guardada correctamente.')
  return redirect('home')
PYVIEWS

chown django:django "$APP_DIR/core/models.py" "$APP_DIR/core/views.py"

python3 - <<'PY'
from pathlib import Path

app_dir = Path('/opt/apps/mi-proyecto')
template_path = app_dir / 'templates' / 'core' / 'index.html'

tpl = template_path.read_text(encoding='utf-8')
if 'name="foto"' not in tpl:
    tpl = tpl.replace(
        '<form id="ubicacion-form" method="post" action="{% url \'guardar_ubicacion\' %}" hidden>',
        '<form id="ubicacion-form" method="post" action="{% url \'guardar_ubicacion\' %}" enctype="multipart/form-data">'
    )
    tpl = tpl.replace(
        '<input type="hidden" id="longitud" name="longitud">\n        </form>',
        '<input type="hidden" id="longitud" name="longitud">\n'
        '          <label for="foto" style="display:block;margin-top:10px;">Foto (opcional)</label>\n'
        '          <input id="foto" name="foto" type="file" accept="image/*" style="margin:6px 0 12px;">\n'
        '          <button class="btn" id="guardar-btn" type="submit" disabled>Guardar ubicacion</button>\n'
        '        </form>'
    )
    tpl = tpl.replace('<th>Fecha y hora</th>', '<th>Fecha y hora</th>\n                <th>Foto</th>')
    tpl = tpl.replace(
        "<td>{{ ubicacion.fecha_hora|date:'Y-m-d H:i:s' }}</td>",
        "<td>{{ ubicacion.fecha_hora|date:'Y-m-d H:i:s' }}</td>\n"
        "                  <td>{% if ubicacion.foto %}<a href=\"{{ ubicacion.foto.url }}\" target=\"_blank\" rel=\"noopener\"><img src=\"{{ ubicacion.foto.url }}\" alt=\"foto ubicacion\" style=\"width:72px;height:72px;object-fit:cover;border-radius:8px;border:1px solid #d1ddce;\"></a>{% else %}Sin foto{% endif %}</td>"
    )
    tpl = tpl.replace(
        "const lonInput = document.getElementById('longitud');",
        "const lonInput = document.getElementById('longitud');\n      const saveBtn = document.getElementById('guardar-btn');"
    )
    tpl = tpl.replace(
        '            form.submit();',
        "            saveBtn.disabled = false;\n            saveBtn.textContent = 'Guardar ubicacion';"
    )
    tpl = tpl.replace(
        "            button.textContent = 'Tomar mi ubicacion actual';",
        "            button.textContent = 'Tomar mi ubicacion actual';\n            saveBtn.disabled = true;"
    )
    template_path.write_text(tpl, encoding='utf-8')
PY

if [[ ! -f "$APP_DIR/core/migrations/0003_ubicacion_foto.py" ]]; then
  cat >"$APP_DIR/core/migrations/0003_ubicacion_foto.py" <<'PYMIG'
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0002_alter_ubicacion_id'),
    ]

    operations = [
        migrations.AddField(
            model_name='ubicacion',
            name='foto',
            field=models.ImageField(blank=True, null=True, upload_to='ubicaciones/'),
        ),
    ]
PYMIG
  chown django:django "$APP_DIR/core/migrations/0003_ubicacion_foto.py"
fi

cd "$APP_DIR"
sudo -u django /opt/apps/venv/bin/python3 manage.py migrate --noinput
systemctl restart django-gunicorn.service
REMOTE
  done
}

block_12_validate_django_photo_persistence() {
  echo "[INFO] Validando escritura de Django en CephFS y visualizacion de media"

  local ip
  for ip in "${DJANGO_NODES[@]}"; do
    echo "[INFO] Validando permisos de escritura para usuario django en $ip"
    ssh_cmd "$ip" "sudo bash -s" <<REMOTE
set -euo pipefail
mountpoint -q ${DJANGO_MEDIA_MOUNT}
sudo -u django bash -lc 'touch ${DJANGO_MEDIA_MOUNT}/.django-write-'"$(hostname)"
ls -la ${DJANGO_MEDIA_MOUNT} | head -n 10
REMOTE
  done

  echo "[INFO] Creando registro de prueba con foto opcional desde app1"
  ssh_cmd "${DJANGO_NODES[0]}" "sudo bash -s" <<'REMOTE'
set -euo pipefail
cd /opt/apps/mi-proyecto
sudo -u django /opt/apps/venv/bin/python3 - <<'PY'
import base64
import os
from django.core.files.uploadedfile import SimpleUploadedFile

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings')
import django
django.setup()

from django.contrib.auth import get_user_model
from core.models import Ubicacion

user = get_user_model().objects.order_by('id').first()
if not user:
    raise SystemExit('NO_USER')

png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7x1XQAAAAASUVORK5CYII=')
foto = SimpleUploadedFile('prueba-ceph.png', png, content_type='image/png')
obj = Ubicacion.objects.create(usuario=user, latitud=13.700000, longitud=-89.200000, foto=foto)
with open('/tmp/ceph_media_url.txt', 'w', encoding='utf-8') as f:
    f.write(obj.foto.url.strip())
PY
REMOTE

  local media_url
  media_url="$(ssh_cmd "${DJANGO_NODES[0]}" "sudo cat /tmp/ceph_media_url.txt" 2>/dev/null || true)"

if [[ -z "$media_url" || "$media_url" == "NO_USER" ]]; then
    echo "[ERROR] No se pudo crear registro de prueba con foto (verifica usuario Django existente)"
    return 1
  fi

  echo "[INFO] Probando visualizacion por HTTPS: https://app1.ti.mimas.net${media_url}"
  curl -kfsS --max-time 15 "https://app1.ti.mimas.net${media_url}" >/dev/null
  echo "[OK] Foto de prueba creada y accesible en app1"
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
  11  Configurar Django (foto opcional + migracion + reinicio gunicorn)
  12  Validar persistencia y visualizacion de foto en app1
  all Ejecutar 0,1,2,3,4,5,6,7,8,9,10,11,12

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
    11) block_11_configure_django_photo_persistence ;;
    12) block_12_validate_django_photo_persistence ;;
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
      block_11_configure_django_photo_persistence
      block_12_validate_django_photo_persistence
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
