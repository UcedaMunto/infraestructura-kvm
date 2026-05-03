
/* 
    LISTA DE COMANDOS UTILES PARA EL MANEJO DEL STACK
*/

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY="${KEY_OVERRIDE:-$BASE_DIR/ssh-keys/id_rsa}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8}"

# CONECCION SSH

Django
ssh -i "$KEY" $SSH_OPTS "${VM_USER}@192.168.20.10" # 10,11,12

Redis
ssh -i "$KEY" $SSH_OPTS "${VM_USER}@192.168.30.10" # 10,11

BALANCEADOR
ssh -i "$KEY" $SSH_OPTS "${VM_USER}@192.168.10.21" # 20,21

MaraiaDB
ssh -i "$KEY" $SSH_OPTS "${VM_USER}@192.168.30.21" # 20,21,22,23 # 20(max-scale)



