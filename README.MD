# Infraestructura HA/HC Empresarial para Django sobre KVM  
## Dominio principal: mimas.net  
## Subdominio delegado: ti.mimas.net  

---

# Tabla principal de nodos, interfaces, puertos y dominios

| Nodo | IP / Interfaz | Uso de interfaz | Puertos abiertos | Dominio / Subdominio |
|------|----------------|-----------------|------------------|----------------------|
| **KVM Host-1** | eth0 → WAN/LAN física | Hypervisor principal / acceso externo | 22, 443, 16509, 5900-5999 | host1.infra.mimas.net |
|  | br0 → 192.168.10.0/24 | Red principal VMs | Según VM | — |
|  | br1 → 192.168.20.0/24 | Backend aplicaciones | — | — |
|  | br2 → 192.168.30.0/24 | DB / Redis | — | — |
|  | br3 → 192.168.40.0/24 | Ceph / Storage | — | — |
|  | br4 → 192.168.50.0/24 | Administración | — | — |
| **KVM Host-2** | Igual estructura | Hypervisor secundario | 22, 443, 16509, 5900-5999 | host2.infra.mimas.net |
| **KVM Host-3** | Igual estructura | Hypervisor terciario | 22, 443, 16509, 5900-5999 | host3.infra.mimas.net |
| **DNS Principal** | eth0 → 192.168.10.10 | DNS raíz mimas.net | 53 TCP/UDP, 22, 80, 443 | ns1.mimas.net |
|  | eth1 → 192.168.50.10 | Administración | 22 | admin.ns1.mimas.net |
| **DNS Delegado TI** | eth0 → 192.168.10.11 | Zona ti.mimas.net | 53 TCP/UDP, 22, 80, 443 | ns1.ti.mimas.net |
|  | eth1 → 192.168.50.11 | Administración | 22 | admin.ns1.ti.mimas.net |
| **NGINX LB-1** | eth0 → 192.168.10.20 | Entrada pública principal | 80, 443, 22, VRRP 112 | www.ti.mimas.net |
|  | eth1 → 192.168.20.20 | Proxy a Django | 80, 443 | lb1.ti.mimas.net |
|  | eth2 → 192.168.50.20 | Administración | 22 | admin.lb1.ti.mimas.net |
| **NGINX LB-2** | eth0 → 192.168.10.21 | Balanceador contingencia | 80, 443, 22, VRRP 112 | lb2.ti.mimas.net |
|  | eth1 → 192.168.20.21 | Proxy a Django | 80, 443 | — |
|  | eth2 → 192.168.50.21 | Administración | 22 | admin.lb2.ti.mimas.net |
| **Django App-1 / VM appDjango1** | eth0 → 192.168.20.10 | Aplicación Django/Gunicorn | 80, 22 | app1.ti.mimas.net |
|  | eth1 → 192.168.30.30 | Redis / MariaDB acceso | 3306, 6379 | — |
|  | eth2 → 192.168.40.30 | CephFS archivos | 2049, 7480 | — |
|  | eth3 → 192.168.50.30 | Administración | 22 | admin.app1.ti.mimas.net |
| **Django App-2 / VM appDjango2** | eth0 → 192.168.20.11 | Aplicación Django/Gunicorn | 80, 22 | app2.ti.mimas.net |
|  | eth1 → 192.168.30.31 | Redis / MariaDB acceso | 3306, 6379 | — |
|  | eth2 → 192.168.40.31 | CephFS archivos | 2049, 7480 | — |
|  | eth3 → 192.168.50.31 | Administración | 22 | admin.app2.ti.mimas.net |
| **Django App-3 / VM appDjango3** | eth0 → 192.168.20.12 | Aplicación Django/Gunicorn | 80, 22 | app3.ti.mimas.net |
|  | eth1 → 192.168.30.32 | Redis / MariaDB acceso | 3306, 6379 | — |
|  | eth2 → 192.168.40.32 | CephFS archivos | 2049, 7480 | — |
|  | eth3 → 192.168.50.32 | Administración | 22 | admin.app3.ti.mimas.net |
| **Redis-1** | eth0 → 192.168.30.10 | Cluster sesiones | 6379, 16379, 22 | redis1.ti.mimas.net |
|  | eth1 → 192.168.50.40 | Administración | 22 | admin.redis1.ti.mimas.net |
| **Redis-2** | eth0 → 192.168.30.11 | Réplica / failover | 6379, 16379, 22 | redis2.ti.mimas.net |
|  | eth1 → 192.168.50.41 | Administración | 22 | admin.redis2.ti.mimas.net |
| **MaxScale** | eth0 → 192.168.30.20 | Balanceador DB | 3306 (read), 4008 (read-write), 8989, 22 | db.ti.mimas.net |
|  | eth1 → 192.168.50.50 | Administración | 22 | admin.db.ti.mimas.net |
| **MariaDB-1 Primary** | eth0 → 192.168.30.21 | Base de datos principal | 3306, 4444, 4567, 4568, 22 | db1.ti.mimas.net |
|  | eth1 → 192.168.40.21 | Backups / storage | CephFS | — |
| **MariaDB-2 Replica** | eth0 → 192.168.30.22 | Replica | 3306, 4444, 4567, 4568, 22 | db2.ti.mimas.net |
|  | eth1 → 192.168.40.22 | Backups / storage | CephFS | — |
| **MariaDB-3 Replica** | eth0 → 192.168.30.23 | Replica | 3306, 4444, 4567, 4568, 22 | db3.ti.mimas.net |
|  | eth1 → 192.168.40.23 | Backups / storage | CephFS | — |
| **Ceph Gateway / VIP** | eth0 → 192.168.40.20 | Cluster CephFS | 6789, 3300, 7480, 2049, 22 | storage.ti.mimas.net |
|  | eth1 → 192.168.50.60 | Administración | 22 | admin.storage.ti.mimas.net |
| **Storage Node-1** | eth0 → 192.168.40.10 | Ceph OSD | 6800-7300, 22 | storage1.ti.mimas.net |
| **Storage Node-2** | eth0 → 192.168.40.11 | Ceph OSD | 6800-7300, 22 | storage2.ti.mimas.net |
| **Storage Node-3** | eth0 → 192.168.40.12 | Ceph OSD | 6800-7300, 22 | storage3.ti.mimas.net |
| **Bastion Server** | eth0 → 192.168.50.2 | Administración central | 22, 443 | bastion.mimas.net |
| **Monitorización** | eth0 → 192.168.50.3 | Grafana / Prometheus | 3000, 9090, 22 | monitor.mimas.net |

---

# Tabla de redes y usos

| Red | Segmento | Uso principal | Sistemas involucrados | Seguridad recomendada |
|-----|----------|---------------|------------------------|-----------------------|
| **Red Principal** | 192.168.10.0/24 | DNS, acceso público, balanceadores, entrada externa | DNS, NGINX, clientes | Firewall público, WAF, TLS |
| **Red Backend** | 192.168.20.0/24 | Aplicaciones Django, Gunicorn, servicios internos web | Django nodes, NGINX interno | Solo balanceadores y admin |
| **Red DB / Redis** | 192.168.30.0/24 | Base de datos, sesiones, cache | MariaDB, MaxScale, Redis | Acceso restringido por backend |
| **Red Storage** | 192.168.40.0/24 | CephFS, archivos, media, backups | Ceph cluster, DB backups, Django media | Solo nodos autorizados |
| **Red Administrativa** | 192.168.50.0/24 | SSH, monitoreo, gestión, bastion | Todos los nodos | VPN, MFA, acceso limitado |

---

# Tabla de redes KVM a crear (libvirt)

| Nombre red | Bridge KVM | Segmento | Gateway | DHCP | Modo libvirt | Nodos conectados |
|------------|-----------|----------|---------|------|--------------|-----------------|
| **red-principal** | br0 | 192.168.10.0/24 | 192.168.10.1 | No (IPs fijas) | bridge / NAT | KVM Hosts, DNS-1, DNS-2, NGINX LB-1/2 |
| **red-backend** | br1 | 192.168.20.0/24 | 192.168.20.1 | No (IPs fijas) | bridge | NGINX LB-1, appDjango1/appDjango2/appDjango3 |
| **red-db-redis** | br2 | 192.168.30.0/24 | 192.168.30.1 | No (IPs fijas) | bridge | appDjango1/appDjango2/appDjango3, Redis-1/2, MaxScale, MariaDB-1/2/3 |
| **red-storage** | br3 | 192.168.40.0/24 | 192.168.40.1 | No (IPs fijas) | bridge | appDjango1/appDjango2/appDjango3, MariaDB-1/2/3, Ceph Gateway, Storage-1/2/3 |
| **red-admin** | br4 | 192.168.50.0/24 | 192.168.50.1 | No (IPs fijas) | bridge | Todos los nodos (interfaz de gestión), Bastion, Monitorización |

**Notas:**
- Todas las redes usan IPs estáticas asignadas por cloud-init (sin DHCP).
- `red-principal` usa modo NAT en entornos de laboratorio para salida a internet.
- `red-backend` y `red-db-redis` también usan NAT en laboratorio para permitir `apt-get` durante el aprovisionamiento inicial. En producción estas redes serían bridge aisladas sin NAT.
- `red-storage` y `red-admin` son redes internas aisladas (modo `bridge` sin NAT).
- El Bastion (192.168.50.2) es el único punto de acceso SSH externo a `red-admin`.

---

# Plan de trabajo general

1. Configurar las redes base de KVM y validar conectividad entre segmentos.
2. Implementar los servidores DNS y comprobar resolucion de `mimas.net` y `ti.mimas.net`.
3. Desplegar los balanceadores NGINX y verificar acceso por la red principal y backend.
4. Preparar los nodos Django backend (`appDjango1`, `appDjango2`, `appDjango3`) y validar la aplicacion en cada servidor.
5. Implementar Redis para sesiones y comprobar replicacion o failover.
6. Montar MariaDB con MaxScale y validar acceso, replicacion y balanceo.
7. Desplegar la capa de almacenamiento Ceph y probar montaje y acceso desde Django y MariaDB.
8. Configurar la red administrativa, bastion y monitorizacion.
9. Ejecutar pruebas integrales de alta disponibilidad, conectividad y servicios publicados.

---

# Subdominios operativos requeridos

```txt
mimas.net
ns1.mimas.net
ti.mimas.net
ns1.ti.mimas.net
www.ti.mimas.net
api.ti.mimas.net
db.ti.mimas.net
redis.ti.mimas.net
storage.ti.mimas.net
bastion.mimas.net
monitor.mimas.net


