# Guía de Uso Diario - Infraestructura HA/HC ti.mimas.net

## Tabla de contenidos

1. [Conexiones SSH](#conexiones-ssh)
2. [Comandos Globales](#comandos-globales)
3. [DNS](#dns)
4. [NGINX Load Balancers](#nginx-load-balancers)
5. [Django Apps](#django-apps)
6. [Redis](#redis)
7. [MySQL/MariaDB](#mysqlmariadb)
8. [MaxScale](#maxscale)
9. [Ceph Storage](#ceph-storage)
10. [Monitorización](#monitorización)
11. [Troubleshooting](#troubleshooting)

---

## Conexiones SSH

### Variables de entorno recomendadas

```bash
# Ejecutar en tu terminal local (fuera del lab)
BASE_DIR="${BASE_DIR:-$HOME/Documents/cluster-ceph/proyecto-manual-infraestructura}"
KEY="$BASE_DIR/ssh-keys/id_rsa"
VM_USER="userinfrakv"  # O el usuario que uses en tus VMs
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"

# Alias útiles
alias ssh-bastion="ssh -i $KEY $SSH_OPTS ${VM_USER}@192.168.50.2"
alias ssh-app1="ssh -i $KEY $SSH_OPTS ${VM_USER}@192.168.20.10"
alias ssh-app2="ssh -i $KEY $SSH_OPTS ${VM_USER}@192.168.20.11"
alias ssh-app3="ssh -i $KEY $SSH_OPTS ${VM_USER}@192.168.20.12"
alias ssh-redis1="ssh -i $KEY $SSH_OPTS ${VM_USER}@192.168.30.10"
alias ssh-redis2="ssh -i $KEY $SSH_OPTS ${VM_USER}@192.168.30.11"
alias ssh-mysql1="ssh -i $KEY $SSH_OPTS ${VM_USER}@192.168.30.21"
alias ssh-mysql2="ssh -i $KEY $SSH_OPTS ${VM_USER}@192.168.30.22"
alias ssh-mysql3="ssh -i $KEY $SSH_OPTS ${VM_USER}@192.168.30.23"
alias ssh-maxscale="ssh -i $KEY $SSH_OPTS ${VM_USER}@192.168.30.20"
alias ssh-lb1="ssh -i $KEY $SSH_OPTS ${VM_USER}@192.168.10.20"
alias ssh-lb2="ssh -i $KEY $SSH_OPTS ${VM_USER}@192.168.10.21"
alias ssh-dns1="ssh -i $KEY $SSH_OPTS ${VM_USER}@192.168.10.10"
alias ssh-dns2="ssh -i $KEY $SSH_OPTS ${VM_USER}@192.168.10.11"
```

### Conexiones directas

```bash
# Bastion (punto de entrada recomendado)
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.50.2

# Apps Django
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.20.10  # app1
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.20.11  # app2
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.20.12  # app3

# Redis
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.30.10  # redis1
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.30.11  # redis2

# MariaDB
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.30.21  # db1 (Primary)
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.30.22  # db2 (Replica)
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.30.23  # db3 (Replica)

# MaxScale
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.30.20

# Load Balancers
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.10.20  # lb1
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.10.21  # lb2

# DNS
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.10.10  # dns1 (Principal)
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.10.11  # dns2 (Delegado)
```

---

## Comandos Globales

### Health Check rápido de la infraestructura

```bash
# Verificar conectividad básica a todos los nodos
for ip in 192.168.20.10 192.168.20.11 192.168.20.12 \
          192.168.30.10 192.168.30.11 \
          192.168.30.20 192.168.30.21 192.168.30.22 192.168.30.23 \
          192.168.10.20 192.168.10.21 \
          192.168.10.10 192.168.10.11; do
  echo -n "Testing $ip: "
  ping -c 1 -W 2 $ip >/dev/null 2>&1 && echo "OK" || echo "FAIL"
done

# Script con SSH para chequeo global
for ip in 192.168.20.10 192.168.20.11 192.168.20.12 \
          192.168.30.10 192.168.30.11 \
          192.168.30.20 192.168.30.21 192.168.30.22 192.168.30.23 \
          192.168.10.20 192.168.10.21 \
          192.168.10.10 192.168.10.11; do
  echo "=== $ip ==="
  ssh -i $KEY $SSH_OPTS userinfrakv@$ip "hostname; uptime" 2>/dev/null || echo "SSH FAIL"
done
```

### Monitorización de recursos

```bash
# En cada servidor: CPU, memoria, disco
top -bn1 | head -n 12  # CPU y memoria
df -h                  # Disco
free -h                # Memoria detallada
```

---

## DNS

### Verificar estado del servicio DNS

```bash
# En ns1.mimas.net (192.168.10.10)
sudo systemctl status named         # Estado del servicio
sudo journalctl -u named -f         # Logs en tiempo real

# O si usas CoreDNS
docker ps | grep coredns
docker logs -f <coredns_container>  # Logs en tiempo real
```

### Validar resolución DNS

```bash
# Desde cualquier servidor
nslookup www.ti.mimas.net 192.168.10.10
nslookup app1.ti.mimas.net 192.168.10.10
nslookup db.ti.mimas.net 192.168.10.10

# O con dig
dig @192.168.10.10 www.ti.mimas.net
dig @192.168.10.10 app1.ti.mimas.net
dig @192.168.10.10 db.ti.mimas.net

# Validar zona completa
dig @192.168.10.10 ti.mimas.net AXFR  # Transferencia de zona (si está permitida)
```

### Recargar zonas sin reiniciar

```bash
# BIND named
sudo rndc reload                    # Recargar todas las zonas
sudo rndc reload ti.mimas.net       # Recargar zona específica

# O reiniciar limpio
sudo systemctl restart named
```

### Logs DNS

```bash
# BIND
sudo tail -f /var/log/syslog | grep named
sudo journalctl -u named -n 100 -f  # Últimas 100 líneas

# Aumentar verbosidad de logs
sudo rndc querylog on               # Activar query logging
sudo tail -f /var/log/syslog | grep "queries"
sudo rndc querylog off              # Desactivar query logging
```

### Archivos críticos DNS

```bash
# Principal (ns1.mimas.net)
/etc/bind/named.conf                # Configuración principal
/etc/bind/zones/db.mimas.net        # Zona raíz
/etc/bind/zones/db.10.168.192       # Zona inversa raíz

# Delegado (ns1.ti.mimas.net)
/etc/bind/zones/db.ti.mimas.net     # Zona ti.mimas.net
/etc/bind/zones/db.11.168.192       # Zona inversa ti.mimas.net

# Validar sintaxis de zonas
sudo named-checkconf /etc/bind/named.conf
sudo named-checkzone ti.mimas.net /etc/bind/zones/db.ti.mimas.net
```

---

## NGINX Load Balancers

### Verificar estado del servicio

```bash
# En lb1 (192.168.10.20) o lb2 (192.168.10.21)
sudo systemctl status nginx
sudo systemctl status keepalived    # Para VRRP HA

# Logs en tiempo real
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log
sudo journalctl -u nginx -f
sudo journalctl -u keepalived -f
```

### Validar configuración

```bash
# Chequear sintaxis
sudo nginx -t

# Recargar configuración sin downtime
sudo systemctl reload nginx

# O reiniciar
sudo systemctl restart nginx
```

### Ver estado de upstream backends

```bash
# Chequear si los backends Django están respondiendo
curl -I http://app1.ti.mimas.net:80
curl -I http://app2.ti.mimas.net:80
curl -I http://app3.ti.mimas.net:80

# O a través del LB
curl -I http://www.ti.mimas.net
curl -I http://app1.ti.mimas.net

# Con verbose para ver headers
curl -v http://www.ti.mimas.net
```

### Verificar VIP VRRP

```bash
# Estado del VRRP (debe haber una VIP 192.168.10.20 activa)
ip addr show
ip link show

# En el LB principal debería mostrar:
# inet 192.168.10.20/32 scope global primary

# Logs de keepalived
sudo journalctl -u keepalived -n 50 -f
```

### Archivos críticos NGINX

```bash
/etc/nginx/nginx.conf               # Config principal
/etc/nginx/sites-enabled/default    # Config del dominio ti.mimas.net
/etc/nginx/sites-available/         # Configuraciones disponibles

# Backup y validar
sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup
sudo nginx -t  # Validar antes de reload
```

### Troubleshoot NGINX

```bash
# Ver conexiones activas
sudo ss -antup | grep -E "80|443"
netstat -antup | grep -E "80|443"

# Ver upstream status (si tiene el módulo habilitado)
curl http://localhost/nginx_status

# Aumentar log verbosity en nginx.conf
# error_log /var/log/nginx/error.log debug;
```

---

## Django Apps

### Verificar estado de Gunicorn

```bash
# En app1/app2/app3 (192.168.20.10/11/12)
sudo systemctl status gunicorn      # O gunicorn-app1, gunicorn-app2, etc.
sudo systemctl status django        # Algunos setups lo llaman django

# Logs en tiempo real
sudo tail -f /var/log/gunicorn/access.log
sudo tail -f /var/log/gunicorn/error.log
sudo journalctl -u gunicorn -f
```

### Verificar que Django esté respondiendo

```bash
# En el mismo servidor Django
curl http://localhost:8000/
curl http://localhost:8000/admin/

# Desde otro servidor
curl http://192.168.20.10:8000/
curl http://app1.ti.mimas.net:8000/  # Si DNS está disponible
```

### Logs Django

```bash
# Ubicación típica
sudo tail -f /home/userinfrakv/django/logs/gunicorn.log
sudo tail -f /home/userinfrakv/django/logs/access.log

# O via journalctl
sudo journalctl -u gunicorn -n 100 -f

# Logs de aplicación Django
tail -f /var/log/django/django.log
```

### Reiniciar Gunicorn

```bash
# Opción 1: systemctl
sudo systemctl restart gunicorn

# Opción 2: recargar (sin downtime)
sudo systemctl reload gunicorn

# Opción 3: matar procesos y reiniciar
sudo pkill -f gunicorn
sudo systemctl start gunicorn
```

### Revisar configuración Django

```bash
# Ubicación típica
/home/userinfrakv/django/config/settings.py
/home/userinfrakv/django/config/urls.py

# Validar sintaxis
cd /home/userinfrakv/django
python manage.py check

# Ver migraciones aplicadas
python manage.py showmigrations

# Aplicar migraciones pendientes
python manage.py migrate
```

### Recolectar archivos estáticos

```bash
# Si cambias CSS/JS
cd /home/userinfrakv/django
python manage.py collectstatic --noinput

# Luego reiniciar Gunicorn
sudo systemctl restart gunicorn
```

### Archivos críticos Django

```bash
/home/userinfrakv/django/config/settings.py
/home/userinfrakv/django/config/urls.py
/home/userinfrakv/django/config/wsgi.py
/etc/systemd/system/gunicorn.service
/etc/systemd/system/gunicorn.socket
```

### Health check Django

```bash
# Endpoint health check
curl -s http://app1.ti.mimas.net:8000/health/ || echo "Healthcheck failed"

# O simplemente la raíz
curl -s -o /dev/null -w "%{http_code}" http://app1.ti.mimas.net:8000/
# Debe retornar 200 o similar, no 500 o 503
```

---

## Redis

### Verificar estado del servicio

```bash
# En redis1 (192.168.30.10) o redis2 (192.168.30.11)
sudo systemctl status redis-server
sudo journalctl -u redis-server -f

# O si está en Docker
docker ps | grep redis
docker logs -f <redis_container>
```

### Conectar a Redis CLI

```bash
# En el servidor Redis
redis-cli
# Luego:
> PING
> INFO server
> INFO stats
> INFO replication

# O con una línea
redis-cli PING
redis-cli INFO server
```

### Conectar desde otro servidor

```bash
# Redis es accesible desde 192.168.30.x
redis-cli -h 192.168.30.10 PING
redis-cli -h 192.168.30.10 INFO replication
redis-cli -h 192.168.30.10 KEYS "*"
```

### Replicación Redis (Master-Slave)

```bash
# En redis-cli del master (redis1)
INFO replication
# Debe mostrar "role:master" y "connected_slaves:1"

# En redis-cli del slave (redis2)
INFO replication
# Debe mostrar "role:slave", "master_host:192.168.30.10", "master_port:6379"
```

### Failover manual Redis

```bash
# Si el master redis1 cae y quieres promover redis2 como master:

# En redis2, promover a master
redis-cli -h 192.168.30.11 SLAVEOF NO ONE

# Luego actualizar configuración de aplicación para apuntar a 192.168.30.11
# O si tienes una VIP, actualizar DNS
```

### Logs Redis

```bash
# Ver archivo de log
sudo tail -f /var/log/redis/redis-server.log

# O por syslog
sudo journalctl -u redis-server -n 100 -f

# Aumentar verbosity
redis-cli CONFIG SET loglevel debug
redis-cli CONFIG GET loglevel
```

### Monitorizar memoria Redis

```bash
# Ver uso de memoria
redis-cli INFO memory
# Buscar: used_memory_human

# Limpar memoria (CUIDADO: borra datos)
redis-cli FLUSHDB    # Base de datos actual
redis-cli FLUSHALL   # TODAS las bases de datos

# Evitar que Redis consuma demasiada RAM
redis-cli CONFIG SET maxmemory 1gb
redis-cli CONFIG SET maxmemory-policy allkeys-lru
```

### Archivos críticos Redis

```bash
/etc/redis/redis.conf               # Configuración
/var/log/redis/redis-server.log    # Logs

# RDB (snapshots)
/var/lib/redis/dump.rdb

# AOF (Append-Only File)
/var/lib/redis/appendonly.aof
```

### Troubleshoot Redis

```bash
# Chequear conexión
redis-cli -h 192.168.30.10 ping

# Monitor de comandos en tiempo real
redis-cli MONITOR

# Estadísticas de clientes conectados
redis-cli CLIENT LIST
redis-cli CLIENT INFO

# Desconectar clientes
redis-cli CLIENT KILL ADDR 192.168.20.10:12345
```

---

## MySQL/MariaDB

### Verificar estado del servicio

```bash
# En db1/db2/db3 (192.168.30.21/22/23)
sudo systemctl status mariadb
sudo journalctl -u mariadb -f
```

### Conectar a MariaDB

```bash
# Localmente (requiere credenciales)
mysql -u root -p

# O especificar servidor remoto
mysql -h 192.168.30.21 -u root -p

# Con variables de entorno
MYSQL_HOST=192.168.30.21
MYSQL_USER=root
mysql -h $MYSQL_HOST -u $MYSQL_USER -p
```

### Verificar replicación Galera

```bash
# En cualquier nodo MariaDB, dentro de mysql>
SHOW STATUS LIKE 'wsrep%';

# Información importante:
# wsrep_cluster_size        = Nodos en cluster
# wsrep_local_state         = 4 (synced), 2 (donor)
# wsrep_connected           = ON
# wsrep_ready               = ON
# wsrep_local_index         = Índice del nodo
```

### Ver nodos del cluster

```bash
# En mysql>
SELECT * FROM information_schema.INNODB_SYS_TABLES \G

# O mejor:
SHOW STATUS LIKE 'wsrep_cluster_members';
```

### Logs MariaDB

```bash
# Ubicación típica
sudo tail -f /var/log/mariadb/mariadb.log
sudo tail -f /var/log/mysql/error.log

# Via journalctl
sudo journalctl -u mariadb -n 50 -f

# Aumentar verbosity
mysql> SET GLOBAL general_log = 'ON';
mysql> SET GLOBAL log_output = 'TABLE';
mysql> SELECT * FROM mysql.general_log;
```

### Backup MariaDB

```bash
# Backup completo con mysqldump
mysqldump -h 192.168.30.21 -u root -p --all-databases > backup-$(date +%Y%m%d-%H%M%S).sql

# Backup específica
mysqldump -h 192.168.30.21 -u root -p nombre_bd > backup-nombre_bd-$(date +%Y%m%d-%H%M%S).sql

# Con compresión
mysqldump -h 192.168.30.21 -u root -p --all-databases | gzip > backup-$(date +%Y%m%d-%H%M%S).sql.gz

# Restaurar
mysql -h 192.168.30.21 -u root -p < backup-20260505-120000.sql
```

### Bajar un nodo MariaDB

```bash
# 1. Detener el nodo gracefully
sudo systemctl stop mariadb

# 2. Verificar en otros nodos
mysql -h 192.168.30.22 -u root -p
> SHOW STATUS LIKE 'wsrep_cluster_size';  # Debe ser N-1

# El cluster sigue funcionando si queda quórum (>50%)
```

### Subir un nodo MariaDB

```bash
# 1. Iniciar el nodo
sudo systemctl start mariadb

# 2. Esperar a que se sincronice (puede tardar minutos)
mysql -h 192.168.30.21 -u root -p
> SHOW STATUS LIKE 'wsrep%';
# Esperar a que wsrep_local_state = 4 (synced)

# 3. Verificar estado final
> SHOW STATUS LIKE 'wsrep_cluster_size';  # Debe ser N nuevamente
```

### Crear nuevo nodo en cluster

```bash
# 1. Instalar MariaDB igual a otros nodos
sudo apt-get install mariadb-server

# 2. Copiar configuración de un nodo existente
scp -i $KEY userinfrakv@192.168.30.21:/etc/mysql/mariadb.conf.d/galera.cnf /tmp/
# Editar y cambiar:
#   wsrep_node_name=db4         # Nuevo nombre
#   wsrep_node_address=192.168.30.24  # Nueva IP

# 3. Iniciar como joiner (no como bootstrapper)
sudo systemctl start mariadb

# 4. Validar sincronización
mysql -u root -p
> SHOW STATUS LIKE 'wsrep%';
```

### Health check MariaDB

```bash
# Test básico de conexión
mysqladmin -h 192.168.30.21 -u root -p ping
# Responde "mysqld is alive" si OK

# Ver bases de datos
mysql -h 192.168.30.21 -u root -p -e "SHOW DATABASES;"

# Ver tamaño de bases de datos
mysql -h 192.168.30.21 -u root -p -e "
SELECT table_schema, 
       ROUND(SUM(data_length+index_length)/1024/1024,0) AS size_MB 
FROM information_schema.tables 
GROUP BY table_schema 
ORDER BY size_MB DESC;"
```

### Archivos críticos MariaDB

```bash
/etc/mysql/mariadb.conf.d/galera.cnf      # Configuración Galera
/etc/mysql/mariadb.conf.d/mysqld.cnf      # Configuración general
/var/log/mariadb/mariadb.log              # Logs
/var/lib/mysql                             # Directorio de datos
```

---

## MaxScale

### Verificar estado de MaxScale

```bash
# En 192.168.30.20
sudo systemctl status maxscale
sudo journalctl -u maxscale -f
```

### Conectar a MaxScale Admin CLI

```bash
# En el servidor MaxScale
maxctrl list servers
maxctrl list services

# Ver status de backends
maxctrl list servers --format vertical

# Ver status de servicios
maxctrl list services --format vertical
```

### Validar balanceo de carga

```bash
# Desde Django app, conectar a MaxScale
mysql -h 192.168.30.20 -u django -p -e "SELECT @@server_id;"
# Ejecutar varias veces: debe alternar entre db1 (id=1), db2 (id=2), db3 (id=3)

# Ver qué backends están en servicio
maxctrl list backends

# O por SQL
mysql -h 192.168.30.20 -u root -p
> SELECT * FROM information_schema.processlist;
```

### Logs MaxScale

```bash
# Ubicación típica
sudo tail -f /var/log/maxscale/maxscale.log

# Via journalctl
sudo journalctl -u maxscale -n 100 -f
```

### Conectar a base específica (lectura/escritura)

```bash
# Puerto 4008 = read-write (siempre va a PRIMARY db1)
mysql -h 192.168.30.20 -P 4008 -u django -p

# Puerto 3306 = read (balancea entre replicas)
mysql -h 192.168.30.20 -P 3306 -u django -p
```

### Archivos críticos MaxScale

```bash
/etc/maxscale/maxscale.cnf          # Configuración
/var/log/maxscale/maxscale.log      # Logs
/var/run/maxscale/maxscale.sock     # Socket Unix
```

### Troubleshoot MaxScale

```bash
# Validar conectividad a backends
maxctrl debug authentication

# Ver métricas
maxctrl list listeners

# Monitorizar en tiempo real
maxctrl watch servers

# Recargar configuración
sudo systemctl reload maxscale

# O reiniciar
sudo systemctl restart maxscale
```

---

## Ceph Storage

### Verificar estado del cluster Ceph

```bash
# En el nodo Ceph o desde cualquier servidor con acceso
ceph status
ceph health detail
ceph node ls

# Ver OSDs
ceph osd tree
ceph osd stat

# Ver MONs
ceph mon status
ceph quorum_status

# Ver MGR
ceph mgr dump
```

### Conectar a Ceph CLI

```bash
# En el servidor Ceph (ceph1.ti.mimas.net)
ceph -s                              # Status
ceph health                           # Health check
ceph osd utilization                  # Uso de discos
```

### Ver pools de Ceph

```bash
ceph osd pool ls
ceph osd pool get <nombre_pool> all
```

### Crear snapshot CephFS

```bash
# En un nodo autorizado
mkdir .snap/snapshot-nombre
# El snapshot se crea automáticamente
```

### Montar CephFS desde Django

```bash
# En los servidores Django (app1/app2/app3)
mount -t ceph 192.168.40.30:/ /mnt/ceph -o name=admin,secret=<ceph_secret>

# Si está mounted automáticamente:
df -h | grep ceph

# Ver punto de montaje
mount | grep ceph
```

### Logs Ceph

```bash
# Logs del cluster
sudo tail -f /var/log/ceph/ceph.log

# Logs de OSD específico
sudo tail -f /var/log/ceph/ceph-osd.0.log

# Logs de MON
sudo tail -f /var/log/ceph/ceph-mon.ceph1.log

# Logs de MGR
sudo tail -f /var/log/ceph/ceph-mgr.ceph1.log
```

### Troubleshoot Ceph

```bash
# Chequear PGs (Placement Groups)
ceph pg stat

# Reparar PGs corrupted
ceph pg repair <pg_id>

# Aumentar número de replicas
ceph osd pool set <nombre_pool> size 3

# Ver capacidad y utilización
ceph df

# Monitorizar en tiempo real
ceph -W cephfs
```

### Archivos críticos Ceph

```bash
/etc/ceph/ceph.conf                 # Configuración
/var/lib/ceph/                      # Datos de Ceph
/var/log/ceph/                      # Logs
```

---

## Monitorización

### Prometheus

```bash
# Verificar estado
sudo systemctl status prometheus
curl http://localhost:9090

# Interface web: http://192.168.50.3:9090
```

### Grafana

```bash
# Verificar estado
sudo systemctl status grafana-server
curl http://localhost:3000

# Interface web: http://192.168.50.3:3000
# Usuario/pass por defecto: admin/admin (cambiar en prod)
```

### Node Exporter (métricas del servidor)

```bash
# En cada servidor, debe estar corriendo
sudo systemctl status node-exporter
curl http://localhost:9100/metrics
```

---

## Troubleshooting

### Problema: No hay conectividad a un servidor

```bash
# 1. Verificar ping básico
ping -c 3 192.168.20.10

# 2. Chequear SSH
ssh -v -i $KEY userinfrakv@192.168.20.10

# 3. Ver interfaces de red en el servidor
ip addr show
ip link show

# 4. Chequear firewall en el host KVM
sudo iptables -L -n | grep 192.168
sudo ufw status

# 5. Si es VM, verificar en el host KVM
sudo virsh list --all
sudo virsh domiflist app1  # Ver interfaces de la VM
```

### Problema: Servicio no inicia

```bash
# 1. Ver estado y logs
sudo systemctl status <servicio>
sudo journalctl -u <servicio> -n 50

# 2. Validar configuración
# MySQL: mysql -u root -p -e "SELECT 1;"
# NGINX: sudo nginx -t
# Django: python /home/userinfrakv/django/manage.py check
# Redis: redis-cli PING

# 3. Chequear permisos
ls -la /etc/<servicio>/
ls -la /var/log/<servicio>/

# 4. Chequear puerto ya en uso
sudo ss -antup | grep :<puerto>
sudo lsof -i :<puerto>

# 5. Reiniciar limpio
sudo systemctl restart <servicio>
sudo journalctl -u <servicio> -n 20 -f
```

### Problema: Alto uso de CPU/Memoria

```bash
# 1. Identificar proceso culpable
top -b -n 1 | head -20
ps aux --sort=-%cpu | head -10
ps aux --sort=-%mem | head -10

# 2. Según el servicio:

# Django/Gunicorn
sudo systemctl status gunicorn
# Aumentar workers si hay muchas conexiones
# Disminuir si hay falta de memoria

# MySQL
mysql -u root -p
> SHOW PROCESSLIST;
> KILL <query_id>;

# Redis
redis-cli INFO memory
redis-cli KEYS '*' | wc -l  # Cuántas claves hay

# Ceph
ceph status
ceph osd utilization
```

### Problema: Disco lleno

```bash
# 1. Identificar qué consume espacio
df -h
du -sh /*

# 2. Según el servicio:

# MySQL (desactivar logs antiguos)
mysql -u root -p
> PURGE BINARY LOGS BEFORE DATE_SUB(NOW(), INTERVAL 7 DAY);

# Nginx logs
sudo find /var/log/nginx -type f -name '*.log.*' -mtime +30 -delete

# Django logs
sudo find /var/log/django -type f -mtime +30 -delete

# Limpieza general
sudo apt-get autoclean
sudo apt-get autoremove
```

### Problema: Red lenta / Timeouts

```bash
# 1. Chequear latencia
ping -c 10 192.168.30.21
mtr 192.168.30.21  # Multi-hop traceroute

# 2. Chequear interfaces de red
ethtool eth0
ethtool -S eth0 | grep -E "rx_errors|tx_errors"

# 3. Chequear estado de conexiones
ss -antup | wc -l
netstat -antup | wc -l

# 4. En MariaDB, chequear slow log
mysql> SET GLOBAL slow_query_log = 'ON';
mysql> SET GLOBAL long_query_time = 2;
tail -f /var/log/mysql/slow.log
```

### Problema: Replicación MariaDB/Redis desincronizada

```bash
# MariaDB
mysql -h 192.168.30.22 -u root -p
> SHOW SLAVE STATUS \G
# Verificar: Seconds_Behind_Master debería ser 0 o muy pequeño

# Redis
redis-cli -h 192.168.30.11 INFO replication
# Verificar: master_repl_offset debe ser similar al master

# Sincronizar manualmente
# MariaDB: generalmente se sincroniza sola
# Redis: puede necesitar SLAVEOF si se perdió conexión
redis-cli -h 192.168.30.11 SLAVEOF 192.168.30.10 6379
```

### Problema: MaxScale no balancea

```bash
# 1. Chequear estado de backends
maxctrl list servers

# 2. Si un backend está DOWN, validar acceso directo
mysql -h 192.168.30.21 -u root -p -e "SELECT 1;"
mysql -h 192.168.30.22 -u root -p -e "SELECT 1;"

# 3. Recargar MaxScale
sudo systemctl reload maxscale

# 4. Validar credenciales de usuario
mysql -u root -p -e "SELECT user FROM mysql.user;"
```

### Problema: DNS no resuelve

```bash
# 1. Chequear servidor DNS
sudo systemctl status named  # o coredns

# 2. Validar desde cliente
nslookup app1.ti.mimas.net 192.168.10.10

# 3. Validar zona
sudo named-checkzone ti.mimas.net /etc/bind/zones/db.ti.mimas.net

# 4. Recargar zonas
sudo rndc reload

# 5. Verificar /etc/resolv.conf en el cliente
cat /etc/resolv.conf
# Debe tener "nameserver 192.168.10.10" o similar
```

### Problema: NGINX no routea a Django

```bash
# 1. Chequear que backends estén UP
curl http://192.168.20.10:8000/
curl http://192.168.20.11:8000/
curl http://192.168.20.12:8000/

# 2. Validar configuración NGINX
sudo nginx -t
sudo grep -A 20 "upstream" /etc/nginx/nginx.conf

# 3. Ver logs de NGINX
sudo tail -f /var/log/nginx/error.log

# 4. Chequear conectividad entre LB y Django
ssh -i $KEY userinfrakv@192.168.10.20
ping 192.168.20.10
```

---

## Automatización y Scripts Útiles

### Script de Health Check completo

```bash
#!/bin/bash
# health-check-all.sh

KEY="/path/a/ssh-keys/id_rsa"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

declare -A SERVERS=(
  [Django-app1]="192.168.20.10"
  [Django-app2]="192.168.20.11"
  [Django-app3]="192.168.20.12"
  [Redis-1]="192.168.30.10"
  [Redis-2]="192.168.30.11"
  [MySQL-1]="192.168.30.21"
  [MySQL-2]="192.168.30.22"
  [MySQL-3]="192.168.30.23"
  [MaxScale]="192.168.30.20"
  [LB-1]="192.168.10.20"
  [LB-2]="192.168.10.21"
  [DNS-1]="192.168.10.10"
  [DNS-2]="192.168.10.11"
)

for name in "${!SERVERS[@]}"; do
  ip="${SERVERS[$name]}"
  echo -n "[$name] $ip: "
  
  if ssh -i $KEY $SSH_OPTS -o ConnectTimeout=2 userinfrakv@$ip "exit" 2>/dev/null; then
    echo "✓ UP"
  else
    echo "✗ DOWN"
  fi
done
```

### Script para crear backup de todos los DBs

```bash
#!/bin/bash
# backup-all-dbs.sh

DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/backup/mysql"

mkdir -p $BACKUP_DIR

for ip in 192.168.30.21 192.168.30.22 192.168.30.23; do
  echo "Backing up $ip..."
  mysqldump -h $ip -u root -p --all-databases 2>/dev/null | \
    gzip > $BACKUP_DIR/backup-$ip-$DATE.sql.gz
done

echo "Backups completados en $BACKUP_DIR"
ls -lh $BACKUP_DIR
```

### Script para monitorizar logs en todos los servidores

```bash
#!/bin/bash
# watch-all-logs.sh

KEY="/path/a/ssh-keys/id_rsa"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "Monitorizing Django app1..."
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.20.10 \
  "sudo tail -f /var/log/gunicorn/error.log" &

echo "Monitorizing MySQL..."
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.30.21 \
  "sudo tail -f /var/log/mariadb/mariadb.log" &

echo "Monitorizing NGINX..."
ssh -i $KEY $SSH_OPTS userinfrakv@192.168.10.20 \
  "sudo tail -f /var/log/nginx/error.log" &

wait
```

---

## Checklist Diario

- [ ] Health check general (all servers)
- [ ] Chequear disco en todos los nodos (df -h)
- [ ] Revisar logs de errores
  - [ ] NGINX error.log
  - [ ] Django gunicorn error
  - [ ] MySQL error log
- [ ] Validar replicación MySQL (wsrep_cluster_size)
- [ ] Validar replicación Redis
- [ ] Chequear Ceph health
- [ ] Revisar Grafana para anomalías
- [ ] Verificar backups completaron (última 24h)

---

## Links útiles

- Grafana: http://192.168.50.3:3000
- Prometheus: http://192.168.50.3:9090
- NGINX: http://www.ti.mimas.net
- Django: http://app1.ti.mimas.net, http://app2.ti.mimas.net, http://app3.ti.mimas.net

---

**Última actualización:** Mayo 2026  
**Versión:** 1.0
