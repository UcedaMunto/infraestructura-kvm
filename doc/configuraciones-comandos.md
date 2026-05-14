# Comandos utiles de operacion (backend Winter/WinterCMS)

## Variables sugeridas

```bash
BASE_DIR="${BASE_DIR:-$HOME/Documents/cluster-ceph/proyecto-manual-infraestructura}"
KEY="${KEY_OVERRIDE:-$BASE_DIR/ssh-keys/id_rsa}"
VM_USER="${VM_USER:-userinfrakv}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
```

## Arranque y apagado global por stack

```bash
cd "$BASE_DIR"

# AUTO: usa Winter si existen appWinter1/2/3, si no WinterCMS
bash configuraciones-run.sh
bash configuraciones-stop.sh

# Forzado a Winter
APP_STACK=winter bash configuraciones-run.sh
APP_STACK=winter bash configuraciones-stop.sh
```

## Backend WinterCMS (flujo por bloques)

```bash
cd "$BASE_DIR"

bash configuraciones-wintercms.sh 1
bash configuraciones-wintercms.sh 2
bash configuraciones-wintercms.sh 3
bash configuraciones-wintercms.sh 17
bash configuraciones-wintercms.sh 18
bash configuraciones-wintercms.sh 19
bash configuraciones-wintercms.sh 20
bash configuraciones-wintercms.sh 21
bash configuraciones-wintercms.sh create-vms
bash configuraciones-wintercms.sh 5
bash configuraciones-wintercms.sh 7
bash configuraciones-wintercms.sh 9
bash configuraciones-wintercms.sh 10
bash configuraciones-wintercms.sh 12
bash configuraciones-wintercms.sh 13
```

## Comandos SSH rapidos

```bash
# DNS
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.10.10"
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.10.11"

# Load balancers
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.10.20"
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.10.21"

# Backend apps (IPs compartidas WinterCMS/Winter)
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.20.10"
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.20.11"
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.20.12"

# DB / MaxScale
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.30.20"
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.30.21"
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.30.22"
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.30.23"

# Redis cluster (7 nodos)
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.30.10"
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.30.11"
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.30.12"
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.30.13"
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.30.14"
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.30.15"
ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.30.16"
```

## Redis cluster - verificaciones rapidas

```bash
cd "$BASE_DIR"

ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.30.10" \
	"redis-cli -h 127.0.0.1 cluster info | egrep 'cluster_state|cluster_known_nodes'"

ssh -i "$KEY" $SSH_OPTS "$VM_USER@192.168.30.10" \
	"redis-cli -h 127.0.0.1 cluster nodes | wc -l"
```

## Winter + Redis cluster (anti-MOVED)

```bash
# Mantener prefijo con hash-tag fijo para sesiones/cache Winter
# (debe caer en un slot del master objetivo)
REDIS_PREFIX={k3}_
```

## Limpieza Winter temporal (destructivo)

```bash
cd "$BASE_DIR"
bash configuraciones-wintercms.sh 15
```



