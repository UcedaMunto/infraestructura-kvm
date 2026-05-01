
bash /home/uceda/Documents/cluster-ceph/proyecto-manual-infraestructura/create-kvm-vm.sh \
  --name mariadb-1 \
  --hostname db1.ti.mimas.net \
  --user userinfrakv \
  --password 'passphrase2620-07' \
  --ram 4096 \
  --vcpus 2 \
  --system-disk 30 \
  --data-disk 40 \
  --libvirt-nets "red-db-redis;red-storage" \
  --ifaces "enp1s0,192.168.30.21/24,192.168.30.1,192.168.10.10,8.8.8.8;enp7s0,192.168.40.21/24,,192.168.10.10,8.8.8.8" \
  --extra-hosts "192.168.30.20 db.ti.mimas.net maxscale-1;192.168.30.21 db1.ti.mimas.net mariadb-1;192.168.30.22 db2.ti.mimas.net mariadb-2;192.168.30.23 db3.ti.mimas.net mariadb-3"


bash /home/uceda/Documents/cluster-ceph/proyecto-manual-infraestructura/create-kvm-vm.sh \
  --name mariadb-2 \
  --hostname db2.ti.mimas.net \
  --user userinfrakv \
  --password 'passphrase2620-07' \
  --ram 4096 \
  --vcpus 2 \
  --system-disk 30 \
  --data-disk 40 \
  --libvirt-nets "red-db-redis;red-storage" \
  --ifaces "enp1s0,192.168.30.22/24,192.168.30.1,192.168.10.10,8.8.8.8;enp7s0,192.168.40.22/24,,192.168.10.10,8.8.8.8" \
  --extra-hosts "192.168.30.20 db.ti.mimas.net maxscale-1;192.168.30.21 db1.ti.mimas.net mariadb-1;192.168.30.22 db2.ti.mimas.net mariadb-2;192.168.30.23 db3.ti.mimas.net mariadb-3"


bash /home/uceda/Documents/cluster-ceph/proyecto-manual-infraestructura/create-kvm-vm.sh \
  --name mariadb-3 \
  --hostname db3.ti.mimas.net \
  --user userinfrakv \
  --password 'passphrase2620-07' \
  --ram 4096 \
  --vcpus 2 \
  --system-disk 30 \
  --data-disk 40 \
  --libvirt-nets "red-db-redis;red-storage" \
  --ifaces "enp1s0,192.168.30.23/24,192.168.30.1,192.168.10.10,8.8.8.8;enp7s0,192.168.40.23/24,,192.168.10.10,8.8.8.8" \
  --extra-hosts "192.168.30.20 db.ti.mimas.net maxscale-1;192.168.30.21 db1.ti.mimas.net mariadb-1;192.168.30.22 db2.ti.mimas.net mariadb-2;192.168.30.23 db3.ti.mimas.net mariadb-3"








