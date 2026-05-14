#!/usr/bin/env bash
# First-boot script para la VM bastion (192.168.50.2 / bastion.mimas.net)
# Se ejecuta una sola vez en el primer arranque via cloud-init runcmd.
# No requiere acceso a internet: usa solo paquetes presentes en la imagen base.
set -euo pipefail

echo "[bastion] Iniciando configuracion de bastion..."

# ── 1. SSH hardening para soporte ProxyJump ──────────────────────────────────
SSHD_CONF=/etc/ssh/sshd_config

apply_sshd_param() {
  local param="$1"
  local value="$2"
  if grep -qE "^\s*#?\s*${param}\s" "$SSHD_CONF" 2>/dev/null; then
    sed -i "s|^\s*#\?\s*${param}\s.*|${param} ${value}|" "$SSHD_CONF"
  else
    echo "${param} ${value}" >> "$SSHD_CONF"
  fi
}

# Habilitar TCP forwarding (obligatorio para ProxyJump / -J)
apply_sshd_param AllowTcpForwarding       yes
# Habilitar reenvio de agente SSH (permite usar clave local en destinos finales)
apply_sshd_param AllowAgentForwarding     yes
# No exponer puertos remotos hacia el exterior
apply_sshd_param GatewayPorts            no
# Solo autenticacion por llave (no contrasenia)
apply_sshd_param PasswordAuthentication  no
apply_sshd_param PubkeyAuthentication    yes
apply_sshd_param PermitRootLogin         no
# Reducir tiempo de espera en conexiones inactivas
apply_sshd_param ClientAliveInterval     60
apply_sshd_param ClientAliveCountMax     3
# Limite de intentos de autenticacion por conexion
apply_sshd_param MaxAuthTries            3

sshd -t && systemctl restart sshd
echo "[bastion] sshd reconfigurado OK"

# ── 2. Firewall UFW ───────────────────────────────────────────────────────────
if command -v ufw >/dev/null 2>&1; then
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  # Permitir SSH entrante unicamente
  ufw allow 22/tcp comment 'SSH admin'
  ufw --force enable
  echo "[bastion] UFW activo: solo puerto 22 entrante"
else
  echo "[bastion] ufw no disponible, saltando firewall"
fi

# ── 3. Banner informativo en /etc/motd ───────────────────────────────────────
cat > /etc/motd <<'MOTD'
########################################################################
#  BASTION HOST  -  bastion.mimas.net  -  192.168.50.2
#  Red administrativa: 192.168.50.0/24
#
#  Uso como ProxyJump:
#    ssh -J userinfrakv@192.168.50.2 userinfrakv@<IP_DESTINO>
#
#  Solo acceso SSH con llave autorizada.
########################################################################
MOTD

echo "[bastion] Configuracion completada OK"
