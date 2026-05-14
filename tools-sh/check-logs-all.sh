#!/bin/bash
##############################################################################
# check-logs-all.sh
# Revisar logs de todos los componentes de la infraestructura
# Uso: bash tools-sh/check-logs-all.sh [component]
#   component: todos | lb | winter | mariadb | maxscale | redis | dns | systemd
##############################################################################

set -euo pipefail

KEY="${PWD}/ssh-keys/id_rsa"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
COMPONENT="${1:-todos}"

FILTER_LINES=50
SYSTEMD_LINES=30

print_section() {
  echo ""
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║ $1"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
}

check_lb_logs() {
  print_section "NGINX LB - Error Logs"
  for ip in 192.168.10.20 192.168.10.21; do
    echo "[lb] $ip"
    ssh -i "$KEY" $SSH_OPTS userinfrakv@$ip "sudo tail -n $FILTER_LINES /var/log/nginx/error.log 2>/dev/null | head -20" 2>/dev/null || echo "  ✗ Connection failed"
    echo ""
  done
  
  print_section "NGINX LB - Access Logs (last 10)"
  for ip in 192.168.10.20 192.168.10.21; do
    echo "[lb] $ip"
    ssh -i "$KEY" $SSH_OPTS userinfrakv@$ip "sudo tail -n 10 /var/log/nginx/access.log 2>/dev/null" 2>/dev/null || echo "  ✗ Connection failed"
    echo ""
  done

  print_section "NGINX LB - Systemd"
  for ip in 192.168.10.20 192.168.10.21; do
    echo "[lb] $ip"
    ssh -i "$KEY" $SSH_OPTS userinfrakv@$ip "sudo journalctl -u nginx -n $SYSTEMD_LINES --no-pager 2>/dev/null" 2>/dev/null || echo "  ✗ Connection failed"
    echo ""
  done
}

check_winter_logs() {
  print_section "WinterCMS - Nginx Error Logs"
  for ip in 192.168.20.10 192.168.20.11 192.168.20.12; do
    echo "[winter] $ip"
    ssh -i "$KEY" $SSH_OPTS userinfrakv@$ip "sudo tail -n $FILTER_LINES /var/log/nginx/error.log 2>/dev/null | head -15" 2>/dev/null || echo "  ✗ Connection failed"
    echo ""
  done

  print_section "WinterCMS - PHP-FPM Logs"
  for ip in 192.168.20.10 192.168.20.11 192.168.20.12; do
    echo "[winter] $ip"
    ssh -i "$KEY" $SSH_OPTS userinfrakv@$ip "sudo tail -n $FILTER_LINES /var/log/php*-fpm.log 2>/dev/null | head -15" 2>/dev/null || echo "  ✗ Connection failed"
    echo ""
  done

  print_section "WinterCMS - Systemd"
  for ip in 192.168.20.10 192.168.20.11 192.168.20.12; do
    echo "[winter] $ip"
    ssh -i "$KEY" $SSH_OPTS userinfrakv@$ip "sudo journalctl -u php*-fpm -n $SYSTEMD_LINES --no-pager 2>/dev/null | head -15" 2>/dev/null || echo "  ✗ Connection failed"
    echo ""
  done
}

check_mariadb_logs() {
  print_section "MariaDB - Error Logs"
  for ip in 192.168.30.21 192.168.30.22 192.168.30.23; do
    echo "[mariadb] $ip"
    ssh -i "$KEY" $SSH_OPTS userinfrakv@$ip "sudo tail -n $FILTER_LINES /var/log/mysql/error.log 2>/dev/null | head -20" 2>/dev/null || echo "  ✗ Connection failed"
    echo ""
  done

  print_section "MariaDB - Systemd"
  for ip in 192.168.30.21 192.168.30.22 192.168.30.23; do
    echo "[mariadb] $ip"
    ssh -i "$KEY" $SSH_OPTS userinfrakv@$ip "sudo journalctl -u mariadb -n $SYSTEMD_LINES --no-pager 2>/dev/null" 2>/dev/null || echo "  ✗ Connection failed"
    echo ""
  done

  print_section "MariaDB - Galera Status"
  ssh -i "$KEY" $SSH_OPTS userinfrakv@192.168.30.21 "MYSQL_PWD='root' mysql -u root -e 'SHOW STATUS LIKE \"wsrep%\";' 2>/dev/null" 2>/dev/null || echo "  ✗ Connection failed"
}

check_maxscale_logs() {
  print_section "MaxScale - Service Log"
  ssh -i "$KEY" $SSH_OPTS userinfrakv@192.168.30.20 "sudo tail -n $FILTER_LINES /var/log/maxscale/maxscale.log 2>/dev/null | head -30" 2>/dev/null || echo "  ✗ Connection failed"

  print_section "MaxScale - Systemd"
  ssh -i "$KEY" $SSH_OPTS userinfrakv@192.168.30.20 "sudo journalctl -u maxscale -n $SYSTEMD_LINES --no-pager 2>/dev/null" 2>/dev/null || echo "  ✗ Connection failed"

  print_section "MaxScale - Services Status"
  ssh -i "$KEY" $SSH_OPTS userinfrakv@192.168.30.20 "maxctrl list services 2>/dev/null" 2>/dev/null || echo "  ✗ Connection failed"
}

check_redis_logs() {
  print_section "Redis Cluster - Systemd Logs"
  for ip in 192.168.30.10 192.168.30.11 192.168.30.12 192.168.30.13 192.168.30.14 192.168.30.15 192.168.30.16; do
    echo "[redis] $ip"
    ssh -i "$KEY" $SSH_OPTS userinfrakv@$ip "sudo journalctl -u redis-server -n $SYSTEMD_LINES --no-pager 2>/dev/null" 2>/dev/null || echo "  ✗ Connection failed"
    echo ""
  done

  print_section "Redis Cluster - Status"
  ssh -i "$KEY" $SSH_OPTS userinfrakv@192.168.30.10 "redis-cli -h 127.0.0.1 cluster info 2>/dev/null" 2>/dev/null || echo "  ✗ Connection failed"
}

check_dns_logs() {
  print_section "DNS BIND Master - Query Log"
  ssh -i "$KEY" $SSH_OPTS userinfrakv@192.168.10.10 "sudo tail -n $FILTER_LINES /var/log/bind/query.log 2>/dev/null | head -20" 2>/dev/null || echo "  ✗ Connection failed"

  print_section "DNS BIND Master - Systemd"
  ssh -i "$KEY" $SSH_OPTS userinfrakv@192.168.10.10 "sudo journalctl -u bind9 -n $SYSTEMD_LINES --no-pager 2>/dev/null" 2>/dev/null || echo "  ✗ Connection failed"

  print_section "DNS BIND Delegado - Query Log"
  ssh -i "$KEY" $SSH_OPTS userinfrakv@192.168.10.11 "sudo tail -n $FILTER_LINES /var/log/bind/query.log 2>/dev/null | head -20" 2>/dev/null || echo "  ✗ Connection failed"

  print_section "DNS BIND Delegado - Systemd"
  ssh -i "$KEY" $SSH_OPTS userinfrakv@192.168.10.11 "sudo journalctl -u bind9 -n $SYSTEMD_LINES --no-pager 2>/dev/null" 2>/dev/null || echo "  ✗ Connection failed"
}

check_systemd_logs() {
  print_section "System Errors (todos los servidores)"
  for ip in 192.168.10.10 192.168.10.11 192.168.10.20 192.168.10.21 192.168.20.10 192.168.20.11 192.168.20.12 192.168.30.20 192.168.30.21; do
    echo "[system] $ip"
    ssh -i "$KEY" $SSH_OPTS userinfrakv@$ip "sudo journalctl -p err -n 15 --no-pager 2>/dev/null" 2>/dev/null || echo "  ✗ Connection failed"
    echo ""
  done
}

# Main
case "$COMPONENT" in
  todos)
    check_lb_logs
    check_winter_logs
    check_mariadb_logs
    check_maxscale_logs
    check_redis_logs
    check_dns_logs
    check_systemd_logs
    ;;
  lb)
    check_lb_logs
    ;;
  winter)
    check_winter_logs
    ;;
  mariadb)
    check_mariadb_logs
    ;;
  maxscale)
    check_maxscale_logs
    ;;
  redis)
    check_redis_logs
    ;;
  dns)
    check_dns_logs
    ;;
  systemd)
    check_systemd_logs
    ;;
  *)
    echo "Uso: bash $0 [componente]"
    echo ""
    echo "Componentes disponibles:"
    echo "  todos       - Revisar todos los logs"
    echo "  lb          - Nginx Load Balancer"
    echo "  winter      - WinterCMS (Nginx + PHP-FPM)"
    echo "  mariadb     - MariaDB Galera"
    echo "  maxscale    - MaxScale proxy"
    echo "  redis       - Redis cluster"
    echo "  dns         - BIND9 DNS"
    echo "  systemd     - Errores de systemd en todos los servers"
    exit 1
    ;;
esac

print_section "✓ Revision de logs completada"
