#!/usr/bin/env bash
set -euo pipefail

# Guia DNS en KVM con bloques separables.
# Uso:
#   bash configuraciones-dns.bash 1
#   bash configuraciones-dns.bash 2
#   bash configuraciones-dns.bash 3
#   bash configuraciones-dns.bash 4
#   bash configuraciones-dns.bash 5
#   bash configuraciones-dns.bash all

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE_VM_SCRIPT="$BASE_DIR/create-kvm-vm.sh"
KEY="${KEY_OVERRIDE:-$BASE_DIR/ssh-keys/id_rsa}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8}"

VM_USER="${VM_USER:-userinfrakv}"
VM_PASSWORD="${VM_PASSWORD:-passphrase2620-07}"
WAIT_SSH_RETRIES="${WAIT_SSH_RETRIES:-60}"
WAIT_SSH_SLEEP="${WAIT_SSH_SLEEP:-5}"

DNS1_IP="${DNS1_IP:-192.168.10.10}"
DNS2_IP="${DNS2_IP:-192.168.10.11}"

if [[ ! -x "$CREATE_VM_SCRIPT" ]]; then
  echo "[ERROR] No se encontro script ejecutable: $CREATE_VM_SCRIPT"
  exit 1
fi

if [[ ! -r "$KEY" ]]; then
  echo "[ERROR] No se puede leer la clave SSH: $KEY"
  exit 1
fi

ssh_cmd() {
  local ip="$1"
  shift
  ssh -i "$KEY" $SSH_OPTS "${VM_USER}@${ip}" "$@"
}

prepare_dns_package_manager() {
  local ip="$1"
  ssh_cmd "$ip" "sudo bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

cloud-init status --wait >/dev/null 2>&1 || true

systemctl stop apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
pkill -9 apt apt-get unattended-upgrade 2>/dev/null || true
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
rm -f /var/lib/dpkg/updates/*
dpkg --configure -a || true
apt-get -y -f install || true
REMOTE
}

block_0_preflight_dns() {
  wait_for_ssh_node "$DNS1_IP"
  wait_for_ssh_node "$DNS2_IP"

  echo "[INFO] Preflight cloud-init/apt en $DNS1_IP"
  prepare_dns_package_manager "$DNS1_IP"
  echo "[INFO] Preflight cloud-init/apt en $DNS2_IP"
  prepare_dns_package_manager "$DNS2_IP"
}

wait_for_ssh_node() {
  local ip="$1"
  local attempt=1
  while (( attempt <= WAIT_SSH_RETRIES )); do
    if ssh -i "$KEY" $SSH_OPTS "${VM_USER}@${ip}" "echo ready" >/dev/null 2>&1; then
      echo "[OK] SSH listo en $ip"
      return 0
    fi
    echo "[INFO] Esperando SSH en $ip (intento ${attempt}/${WAIT_SSH_RETRIES})"
    sleep "$WAIT_SSH_SLEEP"
    attempt=$((attempt + 1))
  done
  echo "[ERROR] SSH no estuvo listo en $ip"
  return 1
}

write_net_xml() {
  local name="$1"
  local mode="$2"
  local gw="$3"
  local mask="$4"
  local xml="/tmp/${name}.xml"

  if [[ "$mode" == "nat" ]]; then
    cat > "$xml" <<XML
<network>
  <name>${name}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='${name}' stp='on' delay='0'/>
  <ip address='${gw}' netmask='${mask}'/>
</network>
XML
  else
    cat > "$xml" <<XML
<network>
  <name>${name}</name>
  <bridge name='${name}' stp='on' delay='0'/>
  <ip address='${gw}' netmask='${mask}'/>
</network>
XML
  fi
}

recreate_net() {
  local name="$1"
  local mode="$2"
  local gw="$3"
  local mask="$4"

  write_net_xml "$name" "$mode" "$gw" "$mask"

  sudo virsh net-destroy "$name" 2>/dev/null || true
  sudo virsh net-undefine "$name" 2>/dev/null || true
  sudo virsh net-define "/tmp/${name}.xml"
  sudo virsh net-start "$name"
  sudo virsh net-autostart "$name"
}

block_1_networks() {
  # NAT necesario para salida a internet desde VMs sin interfaz WAN directa.
  recreate_net red-principal nat 192.168.10.1 255.255.255.0
  recreate_net red-backend nat 192.168.20.1 255.255.255.0
  recreate_net red-db-redis nat 192.168.30.1 255.255.255.0

  # Redes internas sin NAT.
  recreate_net red-storage bridge 192.168.40.1 255.255.255.0
  recreate_net red-admin bridge 192.168.50.1 255.255.255.0

  echo "[OK] Redes recreadas"
  sudo virsh net-list --all
}

block_2_create_dns_vms() {
  bash "$CREATE_VM_SCRIPT" \
    --name dns-principal \
    --hostname ns1.mimas.net \
    --user "$VM_USER" \
    --password "$VM_PASSWORD" \
    --ram 2048 \
    --vcpus 2 \
    --system-disk 20 \
    --data-disk 0 \
    --libvirt-nets "red-principal;red-admin" \
    --ifaces "enp1s0,192.168.10.10/24,192.168.10.1,8.8.8.8,1.1.1.1;enp2s0,192.168.50.10/24,,8.8.8.8,1.1.1.1" \
    --extra-hosts "192.168.10.10 ns1.mimas.net;192.168.10.11 ns1.ti.mimas.net"

  bash "$CREATE_VM_SCRIPT" \
    --name dns-delegado \
    --hostname ns1.ti.mimas.net \
    --user "$VM_USER" \
    --password "$VM_PASSWORD" \
    --ram 2048 \
    --vcpus 1 \
    --system-disk 20 \
    --data-disk 0 \
    --libvirt-nets "red-principal;red-admin" \
    --ifaces "enp1s0,192.168.10.11/24,192.168.10.1,8.8.8.8,1.1.1.1;enp2s0,192.168.50.11/24,,8.8.8.8,1.1.1.1" \
    --extra-hosts "192.168.10.10 ns1.mimas.net;192.168.10.11 ns1.ti.mimas.net"

  wait_for_ssh_node "$DNS1_IP"
  wait_for_ssh_node "$DNS2_IP"
}

block_3_config_dns_principal() {
  block_0_preflight_dns

  local serial
  serial="$(date +%Y%m%d%H)"

  ssh_cmd "$DNS1_IP" "SERIAL=$serial sudo -E bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y bind9 dnsutils

sudo cp /etc/bind/named.conf.options /etc/bind/named.conf.options.bak.$(date +%F-%H%M%S)
sudo tee /etc/bind/named.conf.options >/dev/null <<'EOF2'
options {
  directory "/var/cache/bind";
  recursion yes;
  allow-recursion { any; };
  allow-query { any; };
  forward first;
  forwarders {
    8.8.8.8;
    1.1.1.1;
  };
  dnssec-validation auto;
  listen-on { any; };
  listen-on-v6 { any; };
};
EOF2

sudo tee /etc/bind/named.conf.default-zones >/dev/null <<'EOF2'
zone "mimas.net" {
    type master;
    file "/etc/bind/db.mimas.net";
};

zone "ti.mimas.net" {
  type forward;
  forward only;
  forwarders { 192.168.10.11; };
};
EOF2

sudo tee /etc/bind/db.mimas.net >/dev/null <<EOF2
\$TTL 86400
@   IN  SOA ns1.mimas.net. admin.mimas.net. (
        ${SERIAL}
        3600
        1800
        1209600
        86400 )
;
@       IN  NS  ns1.mimas.net.
ns1     IN  A   192.168.10.10
@       IN  A   192.168.10.10

ti      IN  NS  ns1.ti.mimas.net.
ns1.ti  IN  A   192.168.10.11
EOF2

sudo named-checkconf
sudo named-checkzone mimas.net /etc/bind/db.mimas.net
sudo systemctl restart bind9
sudo systemctl is-active bind9
REMOTE
}

block_4_config_dns_delegado() {
  block_0_preflight_dns

  local serial
  serial="$(date +%Y%m%d%H)"

  ssh_cmd "$DNS2_IP" "SERIAL=$serial sudo -E bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y bind9 dnsutils

sudo cp /etc/bind/named.conf.options /etc/bind/named.conf.options.bak.$(date +%F-%H%M%S)
sudo tee /etc/bind/named.conf.options >/dev/null <<'EOF2'
options {
  directory "/var/cache/bind";
  recursion yes;
  allow-recursion { any; };
  allow-query { any; };
  forward first;
  forwarders {
    8.8.8.8;
    1.1.1.1;
  };
  dnssec-validation auto;
  listen-on { any; };
  listen-on-v6 { any; };
};
EOF2

sudo tee /etc/bind/named.conf.default-zones >/dev/null <<'EOF2'
zone "ti.mimas.net" {
    type master;
    file "/etc/bind/db.ti.mimas.net";
};
EOF2

sudo tee /etc/bind/db.ti.mimas.net >/dev/null <<EOF2
\$TTL 86400
@   IN  SOA ns1.ti.mimas.net. admin.ti.mimas.net. (
        ${SERIAL}
        3600
        1800
        1209600
        86400 )
;
@       IN  NS  ns1.ti.mimas.net.
ns1     IN  A   192.168.10.11
@       IN  A   192.168.10.11

db      IN  A   192.168.30.20
lb1     IN  A   192.168.10.20
lb2     IN  A   192.168.10.21

django1 IN  A   192.168.10.20
django1 IN  A   192.168.10.21
django2 IN  A   192.168.10.20
django2 IN  A   192.168.10.21
django3 IN  A   192.168.10.20
django3 IN  A   192.168.10.21

app1    IN  A   192.168.20.10
app2    IN  A   192.168.20.11
app3    IN  A   192.168.20.12

redis1  IN  A   192.168.30.10
redis2  IN  A   192.168.30.11
EOF2

sudo named-checkconf
sudo named-checkzone ti.mimas.net /etc/bind/db.ti.mimas.net
sudo systemctl restart bind9
sudo systemctl is-active bind9
REMOTE
}

block_5_validate_dns() {
  echo "=== Autoridad / delegacion ==="
  dig +short @"$DNS1_IP" ti.mimas.net NS
  dig +short @"$DNS2_IP" ti.mimas.net SOA

  echo "=== Resolucion dominios internos ==="
  for d in django1.ti.mimas.net django2.ti.mimas.net django3.ti.mimas.net lb1.ti.mimas.net lb2.ti.mimas.net app1.ti.mimas.net app2.ti.mimas.net app3.ti.mimas.net; do
    echo "--- $d"
    dig +short @"$DNS1_IP" "$d" A
    dig +short @"$DNS2_IP" "$d" A
  done

  echo "=== Forwarders (internet) ==="
  dig +short @"$DNS1_IP" google.com A
  dig +short @"$DNS2_IP" google.com A
}

block_6_validate_host_to_dns() {
  echo "=== Host -> DNS reachability ==="
  dig +time=2 +tries=1 @"$DNS1_IP" ns1.ti.mimas.net A
  dig +time=2 +tries=1 @"$DNS2_IP" django1.ti.mimas.net A

  echo "=== Host resolver ==="
  if getent hosts django1.ti.mimas.net >/dev/null 2>&1; then
    getent hosts django1.ti.mimas.net
  else
    echo "[WARN] El resolver del host no usa actualmente la zona interna; el DNS interno si responde por consulta directa."
  fi
}

usage() {
  cat <<'EOF2'
Uso: bash configuraciones-dns.bash <bloque>

Bloques disponibles:
  0      Preflight DNS nodes (SSH + cloud-init + saneo apt/dpkg)
  1      Re-crear redes libvirt (NAT/bridge)
  2      Crear/levantar dns-principal y dns-delegado
  3      Configurar BIND en DNS principal (mimas.net + delegacion)
  4      Configurar BIND en DNS delegado (ti.mimas.net + registros)
  5      Validar DNS interno y forwarders
  6      Validar acceso del host a DNS y uso del resolver local
  all    Ejecutar 1,2,0,3,4,5,6
EOF2
}

main() {
  local block="${1:-}"
  case "$block" in
    0) block_0_preflight_dns ;;
    1) block_1_networks ;;
    2) block_2_create_dns_vms ;;
    3) block_3_config_dns_principal ;;
    4) block_4_config_dns_delegado ;;
    5) block_5_validate_dns ;;
    6) block_6_validate_host_to_dns ;;
    all)
      block_1_networks
      block_2_create_dns_vms
      block_0_preflight_dns
      block_3_config_dns_principal
      block_4_config_dns_delegado
      block_5_validate_dns
      block_6_validate_host_to_dns
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
