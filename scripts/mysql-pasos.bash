#!/usr/bin/env bash
set -euo pipefail

# Guia manual para MariaDB Galera (3 nodos) + MaxScale.
# Ejecutar por bloque para evitar errores de copy/paste con heredocs.
#
# Uso:
#   bash scripts/mysql-pasos.bash 1
#   bash scripts/mysql-pasos.bash 2
#   bash scripts/mysql-pasos.bash 2.01
#   bash scripts/mysql-pasos.bash 2.1
#   bash scripts/mysql-pasos.bash 2.2
#   bash scripts/mysql-pasos.bash 3
#   bash scripts/mysql-pasos.bash 4
#   bash scripts/mysql-pasos.bash 5
#   bash scripts/mysql-pasos.bash all

KEY="${KEY_OVERRIDE:-/home/uceda/Documents/cluster-ceph/proyecto-manual-infraestructura/ssh-keys/id_rsa}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8}"
SSH_USER="${SSH_USER:-userinfrakv}"
DB_NODES=(192.168.30.21 192.168.30.22 192.168.30.23)
DB1_IP="${DB1_IP:-192.168.30.21}"
MAXSCALE_IP="${MAXSCALE_IP:-192.168.30.20}"

require_key() {
  if [[ ! -r "$KEY" ]]; then
    echo "[ERROR] No se puede leer la clave SSH: $KEY"
    echo "[INFO] Ajusta KEY_OVERRIDE con una ruta valida y vuelve a ejecutar."
    exit 1
  fi
}

ssh_cmd() {
  local ip="$1"
  shift
  ssh -i "$KEY" $SSH_OPTS "${SSH_USER}@${ip}" "$@"
}

block_1_install() {
  require_key
  for ip in "${DB_NODES[@]}"; do
    echo "[INFO] Instalando MariaDB/Galera en $ip"
    ssh_cmd "$ip" "sudo bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl
curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | bash
apt-get update
apt-get install -y mariadb-server galera-4 rsync
REMOTE
  done
}

block_2_config() {
  require_key
  declare -A NODOS=(
    [192.168.30.21]="mariadb-1"
    [192.168.30.22]="mariadb-2"
    [192.168.30.23]="mariadb-3"
  )

  for ip in "${DB_NODES[@]}"; do
    local node_name="${NODOS[$ip]}"
    echo "[INFO] Configurando Galera en $node_name ($ip)"
    ssh_cmd "$ip" "sudo bash -s" <<REMOTE
set -euo pipefail
sudo tee /etc/mysql/mariadb.conf.d/60-galera.cnf >/dev/null <<'EOF'
[mysqld]
query_cache_size=0
query_cache_type=0
binlog_format=ROW
default_storage_engine=InnoDB
innodb_autoinc_lock_mode=2
bind-address=0.0.0.0

# Galera Provider Configuration
wsrep_on=ON
wsrep_provider=/usr/lib/galera/libgalera_smm.so

# Galera Cluster Configuration
wsrep_cluster_name="galera_cluster_lab"
wsrep_cluster_address="gcomm://192.168.30.21,192.168.30.22,192.168.30.23"

# Galera Synchronization Configuration
wsrep_sst_method=rsync

# Galera Node Configuration
wsrep_node_address="${ip}"
wsrep_node_name="${node_name}"
EOF
REMOTE
  done
}

block_201_bootstrap() {
  require_key

  for ip in "${DB_NODES[@]}"; do
    ssh_cmd "$ip" "sudo systemctl stop mariadb || true"
  done

  local bootstrap_ip=""
  local fallback_ip=""
  local fallback_seq=-999999
  local has_state="false"

  for ip in "${DB_NODES[@]}"; do
    local state seq safe
    state="$(ssh_cmd "$ip" "sudo cat /var/lib/mysql/grastate.dat 2>/dev/null || true")"

    if [[ -n "$state" ]]; then
      has_state="true"
      seq="$(awk -F': *' '/^seqno:/{print $2}' <<<"$state")"
      safe="$(awk -F': *' '/^safe_to_bootstrap:/{print $2}' <<<"$state")"
      [[ -z "$seq" ]] && seq="-999999"
      [[ -z "$safe" ]] && safe="0"
    else
      seq="-999999"
      safe="0"
    fi

    echo "[INFO] $ip seqno=$seq safe_to_bootstrap=$safe"

    if [[ "$safe" == "1" ]]; then
      bootstrap_ip="$ip"
    fi

    if [[ "$seq" =~ ^-?[0-9]+$ ]] && (( seq > fallback_seq )); then
      fallback_seq=$seq
      fallback_ip="$ip"
    fi
  done

  if [[ "$has_state" == "false" ]]; then
    bootstrap_ip="192.168.30.21"
    echo "[INFO] Instalacion fresca detectada. Bootstrap fijo en $bootstrap_ip."
  elif [[ -z "$bootstrap_ip" ]]; then
    bootstrap_ip="$fallback_ip"
    echo "[WARN] Ningun nodo con safe_to_bootstrap=1. Se fuerza en $bootstrap_ip (seqno=$fallback_seq)."
    ssh_cmd "$bootstrap_ip" "sudo sed -i 's/^safe_to_bootstrap:.*/safe_to_bootstrap: 1/' /var/lib/mysql/grastate.dat"
  fi

  if [[ -z "$bootstrap_ip" ]]; then
    bootstrap_ip="192.168.30.21"
    echo "[WARN] No se pudo detectar nodo. Se usa fallback fijo: $bootstrap_ip"
  fi

  echo "[INFO] Bootstrap de Galera en $bootstrap_ip"
  ssh_cmd "$bootstrap_ip" "sudo galera_new_cluster"

  for ip in "${DB_NODES[@]}"; do
    if [[ "$ip" != "$bootstrap_ip" ]]; then
      ssh_cmd "$ip" "sudo systemctl enable --now mariadb"
    fi
  done

  for ip in "${DB_NODES[@]}"; do
    echo "=== $ip ==="
    ssh_cmd "$ip" "sudo mariadb -Nse \"SHOW STATUS LIKE 'wsrep_cluster_size'; SHOW STATUS LIKE 'wsrep_cluster_status'; SHOW STATUS LIKE 'wsrep_ready';\""
  done

  ssh_cmd "192.168.30.21" "sudo sed -i 's/^127\\.0\\.1\\.1.*/127.0.1.1 db1 db1.ti.mimas.net/' /etc/hosts"
}

block_21_users() {
  require_key
  ssh_cmd "$DB1_IP" "sudo bash -s" <<'REMOTE'
set -euo pipefail
mariadb <<'SQL'
CREATE USER IF NOT EXISTS 'maxscale'@'%' IDENTIFIED BY 'icc115';
CREATE USER IF NOT EXISTS 'maxscale'@'192.168.30.20' IDENTIFIED BY 'icc115';
CREATE USER IF NOT EXISTS 'maxscale'@'db.ti.mimas.net' IDENTIFIED BY 'icc115';
ALTER USER 'maxscale'@'%' IDENTIFIED BY 'icc115';
ALTER USER 'maxscale'@'192.168.30.20' IDENTIFIED BY 'icc115';
ALTER USER 'maxscale'@'db.ti.mimas.net' IDENTIFIED BY 'icc115';

GRANT SELECT ON mysql.user TO 'maxscale'@'%';
GRANT SELECT ON mysql.db TO 'maxscale'@'%';
GRANT SELECT ON mysql.tables_priv TO 'maxscale'@'%';
GRANT SELECT ON mysql.columns_priv TO 'maxscale'@'%';
GRANT SELECT ON mysql.proxies_priv TO 'maxscale'@'%';
GRANT SELECT ON mysql.procs_priv TO 'maxscale'@'%';
GRANT SELECT ON mysql.roles_mapping TO 'maxscale'@'%';
GRANT SHOW DATABASES ON *.* TO 'maxscale'@'%';
GRANT REPLICATION CLIENT ON *.* TO 'maxscale'@'%';

GRANT SELECT ON mysql.user TO 'maxscale'@'192.168.30.20';
GRANT SELECT ON mysql.db TO 'maxscale'@'192.168.30.20';
GRANT SELECT ON mysql.tables_priv TO 'maxscale'@'192.168.30.20';
GRANT SELECT ON mysql.columns_priv TO 'maxscale'@'192.168.30.20';
GRANT SELECT ON mysql.proxies_priv TO 'maxscale'@'192.168.30.20';
GRANT SELECT ON mysql.procs_priv TO 'maxscale'@'192.168.30.20';
GRANT SELECT ON mysql.roles_mapping TO 'maxscale'@'192.168.30.20';
GRANT SHOW DATABASES ON *.* TO 'maxscale'@'192.168.30.20';
GRANT REPLICATION CLIENT ON *.* TO 'maxscale'@'192.168.30.20';

GRANT SELECT ON mysql.user TO 'maxscale'@'db.ti.mimas.net';
GRANT SELECT ON mysql.db TO 'maxscale'@'db.ti.mimas.net';
GRANT SELECT ON mysql.tables_priv TO 'maxscale'@'db.ti.mimas.net';
GRANT SELECT ON mysql.columns_priv TO 'maxscale'@'db.ti.mimas.net';
GRANT SELECT ON mysql.proxies_priv TO 'maxscale'@'db.ti.mimas.net';
GRANT SELECT ON mysql.procs_priv TO 'maxscale'@'db.ti.mimas.net';
GRANT SELECT ON mysql.roles_mapping TO 'maxscale'@'db.ti.mimas.net';
GRANT SHOW DATABASES ON *.* TO 'maxscale'@'db.ti.mimas.net';
GRANT REPLICATION CLIENT ON *.* TO 'maxscale'@'db.ti.mimas.net';

CREATE USER IF NOT EXISTS 'maxscale_monitor'@'%' IDENTIFIED BY 'icc115-monitor';
CREATE USER IF NOT EXISTS 'maxscale_monitor'@'192.168.30.20' IDENTIFIED BY 'icc115-monitor';
CREATE USER IF NOT EXISTS 'maxscale_monitor'@'db.ti.mimas.net' IDENTIFIED BY 'icc115-monitor';
ALTER USER 'maxscale_monitor'@'%' IDENTIFIED BY 'icc115-monitor';
ALTER USER 'maxscale_monitor'@'192.168.30.20' IDENTIFIED BY 'icc115-monitor';
ALTER USER 'maxscale_monitor'@'db.ti.mimas.net' IDENTIFIED BY 'icc115-monitor';

GRANT REPLICATION CLIENT, FILE, SUPER, RELOAD, PROCESS, SHOW DATABASES, EVENT, SLAVE MONITOR ON *.* TO 'maxscale_monitor'@'%';
GRANT REPLICATION CLIENT, FILE, SUPER, RELOAD, PROCESS, SHOW DATABASES, EVENT, SLAVE MONITOR ON *.* TO 'maxscale_monitor'@'192.168.30.20';
GRANT REPLICATION CLIENT, FILE, SUPER, RELOAD, PROCESS, SHOW DATABASES, EVENT, SLAVE MONITOR ON *.* TO 'maxscale_monitor'@'db.ti.mimas.net';

FLUSH PRIVILEGES;
SQL
REMOTE
}

block_22_maxscale() {
  require_key
  ssh_cmd "$MAXSCALE_IP" "sudo bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | sudo bash -s -- --mariadb-maxscale-version=latest
sudo apt-get update
sudo apt-get install -y maxscale

sudo tee /etc/maxscale.cnf >/dev/null <<'EOF'
[maxscale]
threads=auto

[maria1]
type=server
address=192.168.30.21
port=3306
protocol=MariaDBBackend

[maria2]
type=server
address=192.168.30.22
port=3306
protocol=MariaDBBackend

[maria3]
type=server
address=192.168.30.23
port=3306
protocol=MariaDBBackend

[MariaDB-Monitor]
type=monitor
module=mariadbmon
servers=maria1,maria2,maria3
user=maxscale_monitor
password=icc115-monitor
monitor_interval=25s

[Read-Con-Route-Service]
type=service
router=readconnroute
router_options=synced
servers=maria1,maria2,maria3
user=maxscale
password=icc115

[Read-Con-Route-Listener]
type=listener
service=Read-Con-Route-Service
protocol=MariaDBClient
port=3306
address=192.168.30.20

[Read-Write-Service]
type=service
router=readwritesplit
servers=maria1,maria2,maria3
user=maxscale
password=icc115

[Read-Write-Listener]
type=listener
service=Read-Write-Service
protocol=MariaDBClient
port=4008
address=192.168.30.20
EOF

sudo systemctl enable --now maxscale
sudo systemctl status maxscale --no-pager
REMOTE
}

block_3_manual_bootstrap() {
  require_key
  for ip in "${DB_NODES[@]}"; do
    ssh_cmd "$ip" "sudo systemctl stop mariadb || true"
  done

  ssh_cmd "192.168.30.21" "sudo galera_new_cluster"
  ssh_cmd "192.168.30.22" "sudo systemctl enable --now mariadb"
  ssh_cmd "192.168.30.23" "sudo systemctl enable --now mariadb"
}

block_4_validate() {
  require_key
  for ip in "${DB_NODES[@]}"; do
    echo "=== $ip ==="
    ssh_cmd "$ip" "sudo mariadb -Nse \"SHOW STATUS LIKE 'wsrep_cluster_size'; SHOW STATUS LIKE 'wsrep_cluster_status'; SHOW STATUS LIKE 'wsrep_ready';\""
  done
}

block_5_validate_maxscale() {
  require_key
  ssh_cmd "$MAXSCALE_IP" "sudo maxctrl list servers"
  ssh_cmd "$MAXSCALE_IP" "sudo maxctrl list services"
  ssh_cmd "$MAXSCALE_IP" "sudo maxctrl list listeners"
}

usage() {
  cat <<'EOF'
Uso: bash scripts/mysql-pasos.bash <bloque>

Bloques disponibles:
  1       Instalar MariaDB/Galera en db1, db2, db3
  2       Escribir /etc/mysql/mariadb.conf.d/60-galera.cnf en db1, db2, db3
  2.01    Bootstrap robusto de Galera (detecta nodo por grastate.dat)
  2.1     Crear usuarios y grants para MaxScale
  2.2     Instalar y configurar MaxScale
  3       Bootstrap manual rapido (solo referencia)
  4       Validar estado wsrep en db1, db2, db3
  5       Validar estado MaxScale (servers/services/listeners)
  all     Ejecutar 1,2,2.01,2.1,2.2,4,5
EOF
}

main() {
  local block="${1:-}"
  case "$block" in
    1) block_1_install ;;
    2) block_2_config ;;
    2.01) block_201_bootstrap ;;
    2.1) block_21_users ;;
    2.2) block_22_maxscale ;;
    3) block_3_manual_bootstrap ;;
    4) block_4_validate ;;
    5) block_5_validate_maxscale ;;
    all)
      block_1_install
      block_2_config
      block_201_bootstrap
      block_21_users
      block_22_maxscale
      block_4_validate
      block_5_validate_maxscale
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
