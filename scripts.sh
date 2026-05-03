


KEY="/home/uceda/Documents/cluster-ceph/proyecto-manual-infraestructura/ssh-keys/id_rsa"
SSH_OPTS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6'
USER="userinfrakv"
PASS="passphrase2620-07"
NODES=(192.168.30.21 192.168.30.22 192.168.30.23)
#ssh -i "$KEY" $SSH_OPTIONS "userinfrakv@$ip" \

for ip in "${NODES[@]}"; do
echo "=== stop $ip ==="
ssh -i "$KEY" $SSH_OPTS "$USER@$ip" "echo '$PASS' | sudo -S -p '' systemctl stop mariadb || true"
done

python manage.py changepassword admin

NODES=(192.168.30.21 192.168.30.22 192.168.30.23)

for ip in "${NODES[@]}"; do
echo "---$ip ---"
ssh -i "$KEY" $SSH_OPTIONS "userinfrakv@$ip" \
"sudo cat /var/lib/mysql/grastate.dat || true"
echo
done    

ssh -i "$KEY" $SSH_OPTS "userinfrakv@192.168.30.23" \
"echo '$PASS' | sudo -S -p '' systemctl start mariadb && \
 echo '$PASS' | sudo -S -p '' systemctl is-active mariadb && \
 journalctl -xeu mariadb.service"


 