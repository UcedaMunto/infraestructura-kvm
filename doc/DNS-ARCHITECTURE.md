# DNS Architecture - Gepardo & Mimas Domains

## Overview

Tu infraestructura DNS tiene una arquitectura de **master-delegado** con dos servidores BIND9 que manejan múltiples dominios y subdominios con resolución local.

---

## Servidores DNS

### 1. **ns1 (Primary DNS Server)**
- **IP:** 192.168.10.10
- **Hostname:** ns1.mimas.net
- **Rol:** Servidor DNS principal (master)
- **Puertos:** 53/UDP, 53/TCP (DNS), 953/TCP (RNDC)

**Zonas configuradas:**
- `mimas.net` (master) → `/etc/bind/db.mimas.net`
- `ti.mimas.net` (forward only) → Reenvía a 192.168.10.11
- `gepardo.com` (master) → `/etc/bind/db.gepardo.com`

### 2. **ns1.ti.mimas.net (Secondary/Delegated DNS Server)**
- **IP:** 192.168.10.11
- **Rol:** Servidor delegado (autoridad para subzonas)
- **Puertos:** 53/UDP, 53/TCP (DNS)

**Zonas configuradas:**
- `ti.mimas.net` (master) → `/etc/bind/db.ti.mimas.net`
- `occidente.gepardo.com` (master) → `/etc/bind/db.occidente.gepardo.com`

---

## Domain Hierarchy & Delegation

```
.
├── mimas.net (ns1 @ 192.168.10.10)
│   ├── ti.mimas.net (ns1.ti.mimas.net @ 192.168.10.11)
│   │   ├── app1.ti.mimas.net → 192.168.20.10
│   │   ├── app2.ti.mimas.net → 192.168.20.11
│   │   ├── app3.ti.mimas.net → 192.168.20.12
│   │   ├── lb1.ti.mimas.net → 192.168.10.20
│   │   ├── db.ti.mimas.net → 192.168.30.20
│   │   └── redis1/2.ti.mimas.net → 192.168.30.10/11
│   └──
├── gepardo.com (ns @ 192.168.20.10)
│   └── occidente.gepardo.com (ns.occidente.gepardo.com @ 192.168.10.11)
│       ├── occidente.gepardo.com → 192.168.20.12 ✓
│       ├── mail.occidente.gepardo.com → NOT DEFINED ✗
│       └── www.occidente.gepardo.com → NOT DEFINED ✗
```

---

## Query Resolution Flow

### Scenario 1: Query `occidente.gepardo.com` desde cliente

```
Client (192.168.20.10) 
  ↓ queries ns1 (192.168.10.10)
  ↓ ns1 checks zone "gepardo.com"
  ↓ ns1 finds delegation: occidente.gepardo.com → NS ns.occidente.gepardo.com
  ↓ ns1 resolves ns.occidente.gepardo.com → 192.168.10.11
  ↓ ns1 forwards query to 192.168.10.11
  ↓ ns1.ti.mimas.net (192.168.10.11) checks zone "occidente.gepardo.com"
  ↓ ns1.ti.mimas.net finds A record: occidente.gepardo.com → 192.168.20.12
  ↓ Response: 192.168.20.12 ✓
```

### Scenario 2: Query `mail.occidente.gepardo.com` desde cliente

```
Client
  ↓ queries ns1 (192.168.10.10)
  ↓ ns1 delegates to ns1.ti.mimas.net (192.168.10.11)
  ↓ ns1.ti.mimas.net checks zone "occidente.gepardo.com"
  ↓ NO A RECORD FOUND for mail.occidente.gepardo.com
  ↓ Response: NXDOMAIN (Name does not exist) ✗
```

### Scenario 3: Query `app1.ti.mimas.net` desde cliente

```
Client
  ↓ queries ns1 (192.168.10.10)
  ↓ ns1 has "ti.mimas.net" as FORWARD ONLY zone
  ↓ ns1 forwards entire query to 192.168.10.11
  ↓ ns1.ti.mimas.net checks zone "ti.mimas.net" (master)
  ↓ ns1.ti.mimas.net finds A record: app1.ti.mimas.net → 192.168.20.10
  ↓ Response: 192.168.20.10 ✓
```

---

## Zone Files Summary

### `/etc/bind/db.mimas.net` (ns1)
```dns
; SOA: ns1.mimas.net, Serial 2026050218
mimas.net. IN SOA ns1.mimas.net. admin.mimas.net. (...)
mimas.net. IN NS ns1.mimas.net.
ns1.mimas.net. IN A 192.168.10.10
```

### `/etc/bind/db.gepardo.com` (ns1)
```dns
; SOA: ns, Serial 6
gepardo.com. IN SOA ns.gepardo.com. admin.gepardo.com. (...)
gepardo.com. IN NS ns.gepardo.com.
ns.gepardo.com. IN A 192.168.20.10

; Delegation to occidente.gepardo.com
occidente.gepardo.com. IN NS ns.occidente.gepardo.com.
ns.occidente.gepardo.com. IN A 192.168.10.11
```

### `/etc/bind/db.ti.mimas.net` (ns1.ti.mimas.net)
```dns
; SOA: ns1.ti.mimas.net
ti.mimas.net. IN SOA ns1.ti.mimas.net. admin.ti.mimas.net. (...)
ti.mimas.net. IN NS ns1.ti.mimas.net.
ns1.ti.mimas.net. IN A 192.168.10.11

; A Records
app1.ti.mimas.net. IN A 192.168.20.10
app2.ti.mimas.net. IN A 192.168.20.11
app3.ti.mimas.net. IN A 192.168.20.12
lb1.ti.mimas.net. IN A 192.168.10.20
db.ti.mimas.net. IN A 192.168.30.20
redis1.ti.mimas.net. IN A 192.168.30.10
redis2.ti.mimas.net. IN A 192.168.30.11
```

### `/etc/bind/db.occidente.gepardo.com` (ns1.ti.mimas.net)
```dns
; SOA: ns.occidente.gepardo.com
occidente.gepardo.com. IN SOA ns.occidente.gepardo.com. admin.occidente.gepardo.com. (...)
occidente.gepardo.com. IN NS ns.occidente.gepardo.com.
ns.occidente.gepardo.com. IN A 192.168.10.11

; A Records (INCOMPLETE - causing NXDOMAIN)
occidente.gepardo.com. IN A 192.168.20.12
; mail.occidente.gepardo.com NOT DEFINED
; www.occidente.gepardo.com NOT DEFINED
```

---

## Current Issues & Solutions

### ❌ Problem 1: NXDOMAIN for mail.occidente.gepardo.com

**Cause:** No A record defined for `mail.occidente.gepardo.com`

**Solution:** Add to `/etc/bind/db.occidente.gepardo.com`:
```dns
mail.occidente.gepardo.com. IN A <IP_ADDRESS>
www.occidente.gepardo.com. IN A <IP_ADDRESS>
```

Then reload zone:
```bash
sudo rndc reload occidente.gepardo.com
# or
sudo systemctl reload bind9
```

---

## Query Testing Commands

```bash
# Test occidente.gepardo.com resolution
nslookup occidente.gepardo.com localhost

# Test with dig (more detailed)
dig @localhost occidente.gepardo.com +short
dig @192.168.10.10 occidente.gepardo.com +short

# Test mail subdomain (currently NXDOMAIN)
nslookup mail.occidente.gepardo.com localhost

# Test ti.mimas.net subdomain
nslookup app1.ti.mimas.net 192.168.10.10

# Check zone delegation
dig occidente.gepardo.com +trace

# Check AXFR (zone transfer) for security
dig @192.168.10.11 ti.mimas.net AXFR
```

---

## Network Topology

```
┌─────────────────────────────────────────────────────┐
│              DNS Infrastructure                      │
├─────────────────────────────────────────────────────┤
│                                                       │
│  ┌──────────────────┐         ┌──────────────────┐  │
│  │ ns1              │         │ ns1.ti.mimas.net │  │
│  │ 192.168.10.10    │◄──────►│ 192.168.10.11    │  │
│  │ Port 53/UDP      │ forward │ Port 53/UDP      │  │
│  │ Port 953/TCP     │ zone    │                  │  │
│  └──────────────────┘         └──────────────────┘  │
│   Master for:                   Master for:          │
│   - mimas.net                   - ti.mimas.net      │
│   - gepardo.com                 - occidente.gepardo │
│                                                       │
└─────────────────────────────────────────────────────┘
         │             │              │       │
         ▼             ▼              ▼       ▼
     Clients      App Nodes      Database  Cache
     192.168.20  192.168.20     192.168.30 192.168.30
```

---

## Configuration Files Location

- Primary DNS Config: `/etc/bind/named.conf` (ns1)
- Zone Definitions: `/etc/bind/named.conf.default-zones` (both servers)
- Zone Files (ns1): `/etc/bind/db.*.mimas.net`, `/etc/bind/db.gepardo.com`
- Zone Files (ns2): `/etc/bind/db.ti.mimas.net`, `/etc/bind/db.occidente.gepardo.com`

---

## Verification Checklist

- ✅ ns1 (192.168.10.10) responding on port 53
- ✅ ns1.ti.mimas.net (192.168.10.11) responding on port 53
- ✅ mimas.net zone resolves correctly
- ✅ ti.mimas.net forward zone working (forwards to 192.168.10.11)
- ✅ app1/2/3.ti.mimas.net resolves to correct IPs
- ✅ gepardo.com zone resolves correctly
- ✅ occidente.gepardo.com resolves to 192.168.20.12
- ❌ mail.occidente.gepardo.com returns NXDOMAIN (NEEDS FIX)
- ❌ www.occidente.gepardo.com returns NXDOMAIN (NEEDS FIX)

---

**Last Updated:** May 10, 2026
**Status:** Functional with minor missing A records for subdomains
