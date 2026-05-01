
''' 
    CREANDO LAS REDES NECESARIAS
'''
cat > /tmp/red-principal.xml << 'EOF'
<network>
  <name>red-principal</name>
  <forward mode='nat'/>
  <bridge name='red-principal' stp='on' delay='0'/>
  <ip address='192.168.10.1' netmask='255.255.255.0'/>
</network>
EOF
sudo virsh net-define /tmp/red-principal.xml
sudo virsh net-start red-principal
sudo virsh net-autostart red-principal


cat > /tmp/red-backend.xml << 'EOF'
<network>
    <name>red-backend</name>
    <bridge name='red-backend' stp='on' delay='0'/>
    <ip address='192.168.20.1' netmask='255.255.255.0'/>
</network>
EOF
sudo virsh net-define /tmp/red-backend.xml
sudo virsh net-start red-backend
sudo virsh net-autostart red-backend

cat > /tmp/red-db-redis.xml << 'EOF'
<network>
  <name>red-db-redis</name>
  <bridge name='red-db-redis' stp='on' delay='0'/>
  <ip address='192.168.30.1' netmask='255.255.255.0'/>
</network>
EOF
sudo virsh net-define /tmp/red-db-redis.xml
sudo virsh net-start red-db-redis
sudo virsh net-autostart red-db-redis


cat > /tmp/red-storage.xml << 'EOF'
<network>
  <name>red-storage</name>
  <bridge name='red-storage' stp='on' delay='0'/>
  <ip address='192.168.40.1' netmask='255.255.255.0'/>
</network>
EOF
sudo virsh net-define /tmp/red-storage.xml
sudo virsh net-start red-storage
sudo virsh net-autostart red-storage


cat > /tmp/red-admin.xml << 'EOF'
<network>
  <name>red-admin</name>
  <bridge name='red-admin' stp='on' delay='0'/>
  <ip address='192.168.50.1' netmask='255.255.255.0'/>
</network>
EOF
sudo virsh net-define /tmp/red-admin.xml
sudo virsh net-start red-admin
sudo virsh net-autostart red-admin

# ── Verificar todas ───────────────────────────────────────────────────────────
sudo virsh net-list --all



''' 
    CREANDO DNS PRINCIPAL
'''
bash /home/uceda/Documents/cluster-ceph/proyecto-manual-infraestructura/create-kvm-vm.sh \
  --name dns-principal \
  --hostname ns1.mimas.net \
  --user userinfrakv \
  --password 'passphrase2620-07' \
  --ram 2048 \
  --vcpus 2 \
  --system-disk 20 \
  --data-disk 0 \
  --libvirt-nets "red-principal;red-admin" \
  --ifaces "enp1s0,192.168.10.10/24,192.168.10.1,1.1.1.1,8.8.8.8;enp7s0,192.168.50.10/24,,1.1.1.1,8.8.8.8" \
  --extra-hosts "192.168.10.10 ns1.mimas.net;192.168.10.11 ns1.ti.mimas.net" \

ssh -i /home/uceda/Documents/cluster-ceph/proyecto-manual-infraestructura/ssh-keys/id_rsa \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  userinfrakv@192.168.10.10


sudo apt install bind9
# Abre el archivo principal de zonas por defecto de BIND.
# Aqui se registran las zonas que este DNS servira como maestro (authoritative).
sudo nano /etc/bind/named.conf.default-zones


# Registrar dominios y subdominios
# Agregar estos bloques al final de named.conf.default-zones:
# - mimas.net: zona principal
# - ti.mimas.net: subzona/subdominio
'''
zone "mimas.net" {
type master;
file "/etc/bind/db.mimas.net";
};
zone "ti.mimas.net" {
type master;
file "/etc/bind/db.ti.mimas.net";
};
'''


# Edita/crea el archivo de zona principal.
# Esta zona resuelve mimas.net y ns1.mimas.net.
sudo nano /etc/bind/db.mimas.net
'''
$TTL 86400
@ IN SOA ns1.mimas.net. admin.mimas.net. (
2026050101 ; Serial (incrementar en cada cambio de zona)
3600 ; Refresh
1800 ; Retry
1209600 ; Expire
86400 ) ; Negative Cache TTL
;
@   IN NS ns1.mimas.net.    ; Servidor DNS autoritativo
ns1 IN A  192.168.10.10     ; ns1.mimas.net
@   IN A  192.168.10.10     ; mimas.net
ti  IN NS ns1.mimas.net.    ; Delegacion del subdominio ti
'''


# Edita/crea el archivo de zona del subdominio ti.mimas.net.
# Aqui se definen los hosts que viven bajo ese subdominio.
sudo nano /etc/bind/db.ti.mimas.net
'''
$TTL 86400
@ IN SOA ns1.mimas.net. admin.mimas.net. (
2026050101 ; Serial (incrementar en cada cambio de zona)
3600
1800
1209600
86400 )
;
@   IN NS ns1.mimas.net.    ; DNS autoritativo para ti.mimas.net
ns1 IN A  192.168.10.10     ; ns1.ti.mimas.net (si se consulta)
@   IN A  192.168.10.10     ; ti.mimas.net
db  IN A  192.168.10.11     ; db.ti.mimas.net
'''


# Validar y reiniciar
# 1) Verifica sintaxis global de BIND.
sudo named-checkconf
# 2) Verifica la zona principal.
sudo named-checkzone mimas.net /etc/bind/db.mimas.net
# 3) Verifica la zona de subdominio.
sudo named-checkzone ti.mimas.net /etc/bind/db.ti.mimas.net
# 4) Recarga el servicio para aplicar cambios.
sudo systemctl restart bind9
# 5) Comprueba estado del servicio.
sudo systemctl status bind9 --no-pager



''' 
    CREANDO DNS ALTERNO
'''
bash /home/uceda/Documents/cluster-ceph/proyecto-manual-infraestructura/create-kvm-vm.sh \
  --name dns-delegado \
  --hostname ns1.ti.mimas.net \
  --user userinfrakv \
  --password 'passphrase2620-07' \
  --ram 2048 \
  --vcpus 1 \
  --system-disk 20 \
  --data-disk 0 \
  --libvirt-nets "red-principal;red-admin" \
  --ifaces "enp1s0,192.168.10.11/24,192.168.10.1,1.1.1.1,8.8.8.8;enp7s0,192.168.50.11/24,,1.1.1.1,8.8.8.8" \
  --extra-hosts "192.168.10.10 ns1.mimas.net;192.168.10.11 ns1.ti.mimas.net"

# CONFIGURAMOS EL DNS PRINCIPAL '''
ssh -i /home/uceda/Documents/cluster-ceph/proyecto-manual-infraestructura/ssh-keys/id_rsa \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  userinfrakv@192.168.10.10

# Respaldo del archivo
sudo cp /etc/bind/named.conf.default-zones /etc/bind/named.conf.default-zones.bak

# Editamos la configuracion
sudo nano /etc/bind/named.conf.default-zones
''' dejamos solo este contenido
zone "mimas.net" {
    type master;
    file "/etc/bind/db.mimas.net";
};
'''

# Configuramos la delegacion
sudo nano /etc/bind/db.mimas.net
$TTL 86400
@   IN  SOA ns1.mimas.net. admin.mimas.net. (
        2026050103 ; Serial
        3600
        1800
        1209600
        86400 )
;
@       IN  NS  ns1.mimas.net.
ns1     IN  A   192.168.10.10
@       IN  A   192.168.10.10

; Delegacion del subdominio
ti      IN  NS  ns1.ti.mimas.net.
; Glue record
ns1.ti  IN  A   192.168.10.11

sudo named-checkconf
sudo named-checkzone mimas.net /etc/bind/db.mimas.net
sudo systemctl restart bind9
sudo systemctl status bind9 --no-pager

''' 
    CONFIGURANDO EL DNS DELEGADO PARTE 2
'''
sudo apt update
sudo apt install bind9
sudo cp /etc/bind/named.conf.default-zones /etc/bind/named.conf.default-zones.bak
sudo nano /etc/bind/named.conf.default-zones
''' dejamos solo este contenido
zone "ti.mimas.net" {
    type master;
    file "/etc/bind/db.ti.mimas.net";
};
'''
sudo nano /etc/bind/db.ti.mimas.net
'''
$TTL 86400
@   IN  SOA ns1.ti.mimas.net. admin.ti.mimas.net. (
        2026050103 ; Serial
        3600
        1800
        1209600
        86400 )
;
@       IN  NS  ns1.ti.mimas.net.
ns1     IN  A   192.168.10.11
@       IN  A   192.168.10.11
db      IN  A   192.168.10.11
'''
# verificar sintaxis y reiniciar
sudo named-checkconf
sudo named-checkzone ti.mimas.net /etc/bind/db.ti.mimas.net
sudo systemctl restart bind9
sudo systemctl status bind9 --no-pager

# comprobar resolucion desde el host
# Consulta al DNS principal
dig @192.168.10.10 mimas.net +short
dig @192.168.10.10 ns1.ti.mimas.net +short
dig @192.168.10.11 db.ti.mimas.net +short