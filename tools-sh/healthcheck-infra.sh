#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="${KEY:-$BASE_DIR/ssh-keys/id_rsa}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8}"
SSH_USER="${SSH_USER:-userinfrakv}"

IPS=(
  192.168.10.10 192.168.10.11
  192.168.10.20 192.168.10.21
  192.168.20.10 192.168.20.11 192.168.20.12
  192.168.30.10 192.168.30.11
  192.168.30.20 192.168.30.21 192.168.30.22 192.168.30.23
)

echo "=== virsh ==="
virsh list --all

echo
echo "=== ping ==="
for ip in "${IPS[@]}"; do
  if ping -c1 -W1 "$ip" >/dev/null 2>&1; then
    echo "PING $ip OK"
  else
    echo "PING $ip FAIL"
  fi
done

echo
echo "=== ssh + docker ==="
for ip in "${IPS[@]}"; do
  echo "--- $ip ---"
  ssh -i "$KEY" $SSH_OPTS "$SSH_USER@$ip" '
set -e
host="$(hostname -f 2>/dev/null || hostname)"
echo "HOST: $host"
if command -v docker >/dev/null 2>&1; then
  echo "DOCKER: present"
  sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
else
  echo "DOCKER: not-installed"
fi
' 2>/dev/null || echo "SSH FAIL"
done

echo
echo "=== servicios clave ==="
ssh -i "$KEY" $SSH_OPTS "$SSH_USER@192.168.30.20" "echo -n '192.168.30.20 maxscale='; sudo systemctl is-active maxscale || true"
for ip in 192.168.30.21 192.168.30.22 192.168.30.23; do
  ssh -i "$KEY" $SSH_OPTS "$SSH_USER@$ip" "echo -n '$ip mariadb='; sudo systemctl is-active mariadb || true"
done
for ip in 192.168.10.20 192.168.10.21; do
  ssh -i "$KEY" $SSH_OPTS "$SSH_USER@$ip" "echo -n '$ip nginx='; sudo systemctl is-active nginx || true"
done
for ip in 192.168.20.10 192.168.20.11 192.168.20.12; do
  ssh -i "$KEY" $SSH_OPTS "$SSH_USER@$ip" "echo -n '$ip nginx='; sudo systemctl is-active nginx || true; echo -n '$ip php-fpm='; (sudo systemctl is-active php8.1-fpm || sudo systemctl is-active php8.2-fpm)"
done

echo
echo "=== sitio ==="
for url in \
  http://django1.ti.mimas.net/ \
  http://django2.ti.mimas.net/ \
  http://django3.ti.mimas.net/ \
  https://django1.ti.mimas.net/ \
  https://django1.ti.mimas.net/backend; do
  code="$(curl -k -sS -o /dev/null -w '%{http_code}' "$url" || true)"
  echo "$url -> $code"
done

echo
echo "=== redis session test ==="
ssh -i "$KEY" $SSH_OPTS "$SSH_USER@192.168.20.10" "redis-cli -h 192.168.30.10 PING || true"
ssh -i "$KEY" $SSH_OPTS "$SSH_USER@192.168.20.10" "redis-cli -h 192.168.30.10 SET hc:session:test 'ok-$(date +%s)' EX 120 || true"
ssh -i "$KEY" $SSH_OPTS "$SSH_USER@192.168.20.10" "redis-cli -h 192.168.30.10 GET hc:session:test || true"
ssh -i "$KEY" $SSH_OPTS "$SSH_USER@192.168.20.10" "redis-cli -h 192.168.30.11 PING || true"
