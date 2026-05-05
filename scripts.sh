


KEY="/home/uceda/Documents/cluster-ceph/proyecto-manual-infraestructura/ssh-keys/id_rsa"
SSH_OPTS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6'
USER="userinfrakv"
PASS="passphrase2620-07"
NODES=(192.168.30.21 192.168.30.22 192.168.30.23)
#ssh -i "$KEY" $SSH_OPTIONS "userinfrakv@$ip" \
#python manage.py changepassword admin
#chrome://net-internals/#hsts

# DETENER MARIADB EN TODOS LOS NODOS
for ip in "${NODES[@]}"; do
echo "=== stop $ip ==="
ssh -i "$KEY" $SSH_OPTS "$USER@$ip" "echo '$PASS' | sudo -S -p '' systemctl stop mariadb || true"
done

# RECUEPERAR EL SECUENCE NUM DE CADA NODO PARA VER EL ESTADO DE LA GRUPO
for ip in "${NODES[@]}"; do
echo "---$ip ---"
ssh -i "$KEY" $SSH_OPTIONS "userinfrakv@$ip" \
"sudo cat /var/lib/mysql/grastate.dat || true"
echo
done

# LEVANTAR EL NODO INICIAL
ssh -i "$KEY" $SSH_OPTS "userinfrakv@192.168.30.23" \
"echo '$PASS' | sudo -S -p '' galera_new_cluster && \
 echo '$PASS' | sudo -S -p '' systemctl is-active mariadb && \
 echo '$PASS' | sudo -S -p '' mariadb -Nse \"SHOW STATUS LIKE 'wsrep_cluster_status'; SHOW STATUS LIKE 'wsrep_cluster_size'; SHOW STATUS LIKE 'wsrep_ready';\""

# LEVANTAR EL RESTO DE NODOS
for ip in 192.168.30.21 192.168.30.22; do
  ssh -i "$KEY" $SSH_OPTS "userinfrakv@$ip" \
  "echo '$PASS' | sudo -S -p '' systemctl start mariadb && \
   echo '$PASS' | sudo -S -p '' systemctl is-active mariadb"
done

# probar las respuestas DNS
for dns in 192.168.10.10 192.168.10.11; do
  echo "=== DNS $dns ==="
  dig +short @$dns ns1.mimas.net A
  dig +short @$dns ns1.ti.mimas.net A
  dig +short @$dns lb1.ti.mimas.net A
  dig +short @$dns app1.ti.mimas.net A
  dig +short @$dns django1.ti.mimas.net A
  dig +short @$dns google.com A
done
