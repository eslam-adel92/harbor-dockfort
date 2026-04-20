# Harbor Registry — Production Setup Guide

> **Target:** Hetzner Cloud CX22 (2 vCPU, 4GB RAM, SSD)
> **Harbor Version:** v2.12.0 (⚠️ EOL 2026-03-20 — upgrade to v2.14.x+ recommended)
> **Reverse Proxy:** Traefik + ModSecurity WAF (existing `traefik_waf_modsec_nginx` stack)

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [DNS Configuration (Hetzner DNS)](#2-dns-configuration-hetzner-dns)
3. [Server Preparation](#3-server-preparation)
4. [Harbor Installation](#4-harbor-installation)
5. [Initial Configuration](#5-initial-configuration)
6. [Verification](#6-verification)
7. [Upgrade Strategy](#7-upgrade-strategy)
8. [Maintenance Schedule](#8-maintenance-schedule)
9. [Troubleshooting](#9-troubleshooting)
10. [Rollback Procedures](#10-rollback-procedures)

---

## 1. Prerequisites

| Requirement   | Details                                                                                                   |
| :------------ | :-------------------------------------------------------------------------------------------------------- |
| Server        | Hetzner Cloud CX22 or equivalent (2 vCPU, 4GB RAM, SSD)                                                   |
| OS            | Ubuntu 22.04+ / Debian 12+                                                                                |
| Docker        | v24.0+ with Compose V2 plugin                                                                             |
| Traefik Stack | [traefik_waf_modsec_nginx](https://github.com/eslam-adel92/traefik_waf_modsec_nginx) deployed and running |
| DNS           | Domain with access to manage A-records                                                                    |
| Storage Box   | Hetzner Storage Box (optional, for backups)                                                               |
| rclone        | v1.60+ (optional, for remote backups)                                                                     |

---

## 2. DNS Configuration (Hetzner DNS)

### Step-by-Step: Adding the A-Record

1. **Log in** to the [Hetzner DNS Console](https://dns.hetzner.com/).

2. **Select your domain** from the domain list (e.g., `yourdomain.com`).

3. **Click "Add Record"** and configure:

   | Field     | Value                                                                       |
   | :-------- | :-------------------------------------------------------------------------- |
   | **Type**  | `A`                                                                         |
   | **Name**  | `registry`                                                                  |
   | **Value** | `<YOUR_SERVER_IPv4>`                                                        |
   | **TTL**   | `300` (5 minutes — lower for initial setup, increase to `3600` once stable) |

4. **Click "Save"**.

5. **(Optional) Add an AAAA record** if your server has IPv6:

   | Field     | Value                |
   | :-------- | :------------------- |
   | **Type**  | `AAAA`               |
   | **Name**  | `registry`           |
   | **Value** | `<YOUR_SERVER_IPv6>` |
   | **TTL**   | `300`                |

6. **Verify DNS propagation** (may take 1–5 minutes):

   ```bash
   # Check A-record resolution
   dig +short registry.yourdomain.com A

   # Expected output: your server's IPv4 address
   # Example: 5.78.xx.xx

   # Alternative check
   nslookup registry.yourdomain.com
   ```

> **Note:** Hetzner DNS typically propagates within 1–2 minutes. If using Cloudflare
> or another DNS provider, ensure the record is **DNS Only** (gray cloud), not proxied,
> since Traefik handles TLS termination.

### Alternative: Using Hetzner DNS API

```bash
# Set your API token
export HETZNER_DNS_TOKEN="your-api-token"

# Get your zone ID
curl -s -H "Auth-API-Token: ${HETZNER_DNS_TOKEN}" \
  "https://dns.hetzner.com/api/v1/zones" | jq '.zones[] | {id, name}'

# Create A-record (replace ZONE_ID and SERVER_IP)
curl -X POST "https://dns.hetzner.com/api/v1/records" \
  -H "Auth-API-Token: ${HETZNER_DNS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "zone_id": "YOUR_ZONE_ID",
    "type": "A",
    "name": "registry",
    "value": "YOUR_SERVER_IP",
    "ttl": 300
  }'
```

---

## 3. Server Preparation

### 3.1 System Updates and Docker Installation

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Install Docker (if not already installed)
curl -fsSL https://get.docker.com | sudo sh

# Add current user to docker group
sudo usermod -aG docker $USER

# Verify Docker Compose V2 is available
docker compose version
# Expected: Docker Compose version v2.x.x
```

### 3.2 Hetzner MTU Configuration

Hetzner Cloud uses VXLAN overlays with a maximum MTU of 1450. This is already configured
in `docker-compose.yml` for the Harbor internal network, but you should also set it
system-wide to prevent issues with other containers:

```bash
# Check current MTU
ip link show eth0 | grep mtu

# If MTU is 1500, set it to 1450
sudo ip link set dev eth0 mtu 1450

# Make persistent across reboots (Netplan — Ubuntu 22.04+)
sudo tee /etc/netplan/99-hetzner-mtu.yaml << 'EOF'
network:
  version: 2
  ethernets:
    eth0:
      mtu: 1450
EOF
sudo netplan apply
```

### 3.3 Docker Daemon Configuration

```bash
# Configure Docker daemon defaults
sudo tee /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "mtu": 1450,
  "storage-driver": "overlay2",
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  }
}
EOF

sudo systemctl restart docker
```

### 3.4 Verify Traefik Network Exists

```bash
docker network inspect webproxy
# Should return network details. If not found, deploy Traefik stack first.
```

---

## 4. Harbor Installation

### 4.1 Clone This Repository

```bash
sudo mkdir -p /opt/harbor-registry
cd /opt/harbor-registry

# Copy files from this repository
# (or git clone if you've pushed this to a repo)
cp docker-compose.yml .env.example harbor-backup.sh /opt/harbor-registry/
```

### 4.2 Generate Secrets

```bash
cd /opt/harbor-registry

# Copy environment template
cp .env.example .env

# Generate strong secrets
HARBOR_DB_PASSWORD=$(openssl rand -hex 16)
HARBOR_SECRET_KEY=$(openssl rand -hex 8)
CORE_SECRET=$(openssl rand -hex 16)
JOBSERVICE_SECRET=$(openssl rand -hex 16)
REGISTRY_HTTP_SECRET=$(openssl rand -hex 16)
REGISTRY_CRED_PASSWORD=$(openssl rand -hex 16)
CSRF_KEY=$(openssl rand -base64 32 | head -c 32)
ADMIN_PASSWORD=$(openssl rand -base64 16)

# Write secrets to .env (replace placeholders)
sed -i "s|CHANGE_ME_STRONG_PASSWORD_HERE|${ADMIN_PASSWORD}|" .env
sed -i "s|CHANGE_ME_ANOTHER_STRONG_PASSWORD|${HARBOR_DB_PASSWORD}|" .env
sed -i "s|CHANGE_ME_16CHARS|${HARBOR_SECRET_KEY}|" .env
sed -i "s|CHANGE_ME_32HEX_CHARS|${CORE_SECRET}|" .env  # Will replace first match
sed -i "0,/CHANGE_ME_32HEX_CHARS/{s|CHANGE_ME_32HEX_CHARS|${JOBSERVICE_SECRET}|}" .env
sed -i "s|CHANGE_ME_REGISTRY_SECRET|${REGISTRY_HTTP_SECRET}|" .env
sed -i "s|CHANGE_ME_REGISTRY_CRED_PASSWORD|${REGISTRY_CRED_PASSWORD}|" .env
sed -i "s|CHANGE_ME_32CHAR_CSRF_KEY_BASE64|${CSRF_KEY}|" .env

# IMPORTANT: Update the hostname
sed -i "s|registry.yourdomain.com|registry.YOUR_ACTUAL_DOMAIN.com|" .env

# Print generated admin password (save this!)
echo "============================================"
echo "Harbor Admin Password: ${ADMIN_PASSWORD}"
echo "SAVE THIS PASSWORD — you'll need it for first login"
echo "============================================"
```

### 4.3 Download and Run Harbor Installer

Harbor requires initial configuration files generated by its installer. This is a
**one-time step** — the installer creates the `config/` directory with all service
configuration files.

```bash
cd /opt/harbor-registry

# Download Harbor offline installer
HARBOR_VERSION="v2.12.0"
curl -sL "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-offline-installer-${HARBOR_VERSION}.tgz" \
  -o harbor-installer.tgz

# Extract installer (we only need the config templates)
tar -xzf harbor-installer.tgz
cd harbor

# Copy and edit harbor.yml from template
cp harbor.yml.tmpl harbor.yml
```

Edit `harbor.yml` with your settings:

```yaml
# harbor.yml — Key settings to modify:
hostname: registry.yourdomain.com

# Disable internal TLS — Traefik handles TLS termination
https:
  # Comment out or remove the https section entirely
  # port: 443
  # certificate: /your/certificate/path
  # private_key: /your/private/key/path

http:
  port: 8080

harbor_admin_password: <from .env HARBOR_ADMIN_PASSWORD>

database:
  password: <from .env HARBOR_DB_PASSWORD>
  max_idle_conns: 10
  max_open_conns: 50

data_volume: /opt/harbor-registry/data

trivy:
  ignore_unfixed: false
  skip_update: false
  insecure: false

jobservice:
  max_job_workers: 2 # Low worker count for 2 vCPU server

log:
  level: info
  local:
    rotate_count: 10
    rotate_size: 50M
    location: /var/log/harbor
```

Run the installer to generate configuration files:

```bash
# Generate configs (--with-trivy enables vulnerability scanning)
sudo ./install.sh --with-trivy

# Stop the containers started by the installer
# (we'll use our own docker-compose.yml with Traefik labels)
docker compose down

# Copy generated config to our deployment directory
cp -r /opt/harbor-registry/harbor/common/config /opt/harbor-registry/config
```

### 4.4 Deploy with Our Compose File

```bash
cd /opt/harbor-registry

# Pull all images first
docker compose pull

# Start the stack
docker compose up -d

# Monitor startup
docker compose logs -f --tail=50
# Wait for all health checks to pass (1-2 minutes)
```

---

## 5. Initial Configuration

### 5.1 Access Harbor UI

1. Open `https://registry.yourdomain.com` in your browser.
2. Log in with:
   - **Username:** `admin`
   - **Password:** The generated password from step 4.2
3. **Change the admin password immediately** via Administration → Users.

### 5.2 Create the `library` Project as Public

1. Navigate to **Projects → New Project**.
2. Set:
   - **Project Name:** `library`
   - **Access Level:** ✅ Public
3. Click **OK**.

This allows anonymous `docker pull` while requiring authentication for `docker push`.

### 5.3 Configure Docker Hub Proxy Cache

Reduce bandwidth and avoid Docker Hub rate limits by caching base images locally:

1. Navigate to **Administration → Registries → New Endpoint**.
2. Configure:
   - **Provider:** Docker Hub
   - **Name:** `dockerhub-cache`
   - **Endpoint URL:** `https://hub.docker.com`
   - **Access ID/Secret:** (optional — use Docker Hub credentials for higher rate limits)
3. Create a **proxy cache project**:
   - Navigate to **Projects → New Project**
   - **Project Name:** `dockerhub-cache`
   - **Access Level:** ✅ Public
   - **Proxy Cache:** ✅ Enable, select `dockerhub-cache` registry

Usage:

```bash
# Instead of: docker pull alpine:latest
docker pull registry.yourdomain.com/dockerhub-cache/library/alpine:latest
```

### 5.4 Configure Trivy Scanning Policy

1. Navigate to **Projects → library → Configuration**.
2. Enable:
   - ✅ **Automatically scan images on push**
   - ✅ **Prevent vulnerable images from running** (set to `Critical`)
3. Navigate to **Administration → Interrogation Services → Vulnerability**.
4. Set scan schedule to every **12 hours**.

### 5.5 Configure Robot Accounts for CI/CD

For GitHub Actions or other CI systems:

1. Navigate to **Projects → library → Robot Accounts → New Robot Account**.
2. Configure:
   - **Name:** `github-actions`
   - **Expiration:** 365 days
   - **Permissions:** Push Artifact, Pull Artifact
3. **Save the generated token** — it won't be shown again.

Usage in GitHub Actions:

```yaml
- name: Login to Harbor
  uses: docker/login-action@v3
  with:
    registry: registry.yourdomain.com
    username: robot$library+github-actions
    password: ${{ secrets.HARBOR_ROBOT_TOKEN }}
```

---

## 6. Verification

Run these checks after deployment to verify everything works:

```bash
# 1. Health check — all components should be "healthy"
curl -sk https://registry.yourdomain.com/api/v2.0/health | jq .

# 2. Registry v2 endpoint (should return {})
curl -sk https://registry.yourdomain.com/v2/

# 3. Anonymous pull test
docker pull registry.yourdomain.com/library/alpine:latest 2>&1 || echo "No images yet — expected"

# 4. Authenticated push test
docker login registry.yourdomain.com -u admin
docker pull alpine:latest
docker tag alpine:latest registry.yourdomain.com/library/alpine:test
docker push registry.yourdomain.com/library/alpine:test

# 5. Verify push succeeded
curl -sk https://registry.yourdomain.com/api/v2.0/projects/library/repositories | jq .

# 6. Check resource usage (should be well under 4GB total)
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | grep harbor

# 7. Verify WAF is not blocking blob uploads
# (The push test in step 4 validates this — if it succeeds, WAF bypass works)

# 8. Check Traefik routing
curl -sk -o /dev/null -w "%{http_code}" https://registry.yourdomain.com/v2/
# Expected: 401 (unauthorized — correct, means routing works)

# 9. Clean up test image
docker rmi registry.yourdomain.com/library/alpine:test
```

---

## 7. Upgrade Strategy

### 7.1 Version Classification

| Upgrade Type | Example           | Risk   | Procedure                       |
| :----------- | :---------------- | :----- | :------------------------------ |
| **Patch**    | v2.12.0 → v2.12.1 | Low    | Direct image tag update         |
| **Minor**    | v2.12.x → v2.13.x | Medium | Auto-migration on first start   |
| **Major**    | v2.x → v3.x       | High   | Requires migration guide review |

### 7.2 Pre-Upgrade Checklist

```bash
# 1. Run a full backup BEFORE any upgrade
/opt/harbor-registry/harbor-backup.sh

# 2. Check Harbor release notes
# https://github.com/goharbor/harbor/releases

# 3. Dump current database schema (for rollback reference)
docker exec harbor-db pg_dumpall -U postgres > /tmp/harbor-pre-upgrade-schema.sql

# 4. Record current image versions
docker compose images | tee /tmp/harbor-pre-upgrade-images.txt

# 5. Verify current health
curl -sk https://registry.yourdomain.com/api/v2.0/health | jq .
```

### 7.3 Upgrade Execution (Patch/Minor)

```bash
cd /opt/harbor-registry

# 1. Update image tags in docker-compose.yml
# Example: Change all v2.12.0 → v2.12.4
sed -i 's/v2.12.0/v2.12.4/g' docker-compose.yml

# 2. Pull new images
docker compose pull

# 3. Rolling restart — update one service at a time to minimize downtime
docker compose up -d --no-deps --force-recreate harbor-db
docker compose up -d --no-deps --force-recreate harbor-redis
sleep 10  # Wait for DB and Redis to be healthy

docker compose up -d --no-deps --force-recreate harbor-registry
docker compose up -d --no-deps --force-recreate harbor-registryctl
sleep 5

docker compose up -d --no-deps --force-recreate harbor-core
sleep 15  # Core runs migrations on start — give it time

docker compose up -d --no-deps --force-recreate harbor-portal
docker compose up -d --no-deps --force-recreate harbor-jobservice
docker compose up -d --no-deps --force-recreate trivy-adapter
docker compose up -d --no-deps --force-recreate harbor-exporter
```

### 7.4 Post-Upgrade Validation

```bash
# 1. Verify all services are healthy
docker compose ps
# All services should show "healthy" status

# 2. API health check
curl -sk https://registry.yourdomain.com/api/v2.0/health | jq .

# 3. Functional test — pull and push
docker pull alpine:latest
docker tag alpine:latest registry.yourdomain.com/library/test:upgrade-check
docker push registry.yourdomain.com/library/test:upgrade-check

# 4. Verify version in UI
curl -sk https://registry.yourdomain.com/api/v2.0/systeminfo | jq .harbor_version

# 5. Check for migration errors
docker compose logs harbor-core | grep -i "migration\|upgrade\|error"

# 6. Clean up test image
docker rmi registry.yourdomain.com/library/test:upgrade-check
```

### 7.5 Rollback Procedure

If the upgrade fails:

```bash
# 1. Stop all services
cd /opt/harbor-registry
docker compose down

# 2. Restore database from pre-upgrade backup
docker compose up -d harbor-db
sleep 10
cat /tmp/harbor-pre-upgrade-schema.sql | docker exec -i harbor-db psql -U postgres

# 3. Revert image tags in docker-compose.yml
# (restore from backup or manually revert sed changes)
cp /opt/harbor-backups/LATEST/config/docker-compose.yml .

# 4. Start with previous version
docker compose up -d

# 5. Verify rollback
curl -sk https://registry.yourdomain.com/api/v2.0/health | jq .
```

### 7.6 Recommended Upgrade Path (from v2.12.0)

Since Harbor v2.12.x reached EOL on 2026-03-20, plan an upgrade:

```
v2.12.0 → v2.12.4 (latest patch, safe) → v2.13.5 → v2.14.3 → v2.15.0
```

> **Important:** Do NOT skip minor versions. Each minor version may include
> database migrations that must run sequentially.

---

## 8. Maintenance Schedule

| Task                    | Frequency       | Method                    | Time               |
| :---------------------- | :-------------- | :------------------------ | :----------------- |
| **Garbage Collection**  | Daily           | Automatic (Harbor native) | 03:00 UTC          |
| **Database Backup**     | Daily           | `harbor-backup.sh`        | 02:00 UTC          |
| **PostgreSQL VACUUM**   | Weekly (Sunday) | `harbor-backup.sh` (auto) | 02:00 UTC          |
| **Trivy DB Update**     | Every 12 hours  | Automatic (Trivy)         | —                  |
| **Log Rotation**        | Automatic       | Docker `json-file` driver | —                  |
| **Security Patches**    | Monthly         | Manual upgrade            | Maintenance window |
| **Certificate Renewal** | Automatic       | Traefik Let's Encrypt     | —                  |
| **Backup Verification** | Monthly         | Manual restore test       | —                  |

### Setting Up the Backup Cron Job

```bash
# Make backup script executable
chmod +x /opt/harbor-registry/harbor-backup.sh

# Add to root crontab
sudo crontab -e

# Add this line (runs daily at 02:00 UTC):
0 2 * * * /opt/harbor-registry/harbor-backup.sh >> /var/log/harbor-backup.log 2>&1

# Test with dry-run first
/opt/harbor-registry/harbor-backup.sh --dry-run
```

### Setting Up rclone for Hetzner Storage Box

```bash
# Install rclone
sudo apt install rclone

# Configure Hetzner Storage Box as S3-compatible remote
rclone config

# Choose: n) New remote
# Name: hetzner-storagebox
# Storage: s3
# Provider: Other
# env_auth: false
# access_key_id: YOUR_STORAGEBOX_ACCESS_KEY
# secret_access_key: YOUR_STORAGEBOX_SECRET_KEY
# endpoint: YOUR_STORAGEBOX_S3_ENDPOINT
# (For Hetzner Storage Box with S3 protocol, use the provided endpoint)

# Test connectivity
rclone lsd hetzner-storagebox:
```

---

## 9. Troubleshooting

### Common Issues

#### Layer Push Timeouts

**Symptom:** `docker push` hangs or fails with timeout errors on large layers.

**Cause:** MTU mismatch. Hetzner Cloud uses 1450 MTU; default Docker uses 1500.

**Fix:**

```bash
# Verify MTU on harbor-internal network
docker network inspect harbor-internal | jq '.[0].Options'
# Should show: "com.docker.network.driver.mtu": "1450"

# Also check host interface
ip link show eth0 | grep mtu
# Should show: mtu 1450
```

#### WAF Blocking Pushes

**Symptom:** `docker push` returns 403 or 500 errors. `docker pull` works fine.

**Cause:** ModSecurity inspecting binary blob uploads and detecting false positives.

**Fix:** Verify the blob router exists and has NO middlewares:

```bash
# Check Traefik routers
curl -sk https://localhost:8080/api/http/routers | jq '.[] | select(.name | contains("harbor-blobs"))'
# The middlewares field should be empty or absent
```

#### OOM Kills

**Symptom:** Services randomly restart. `dmesg | grep -i oom` shows kills.

**Fix:** Check which service is consuming the most memory:

```bash
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}"
```

If Trivy is the culprit, reduce its memory limit or disable it temporarily:

```bash
docker compose stop trivy-adapter
# This frees ~1GB of RAM
```

#### Database Connection Refused

**Symptom:** Harbor Core fails to start with "connection refused" to database.

**Fix:** Ensure harbor-db is healthy before core starts:

```bash
docker compose logs harbor-db | tail -20
docker exec harbor-db pg_isready -U postgres
```

#### Certificate Issues

**Symptom:** Browser shows certificate errors or `docker login` fails with TLS errors.

**Fix:** Traefik handles TLS. Check Traefik logs:

```bash
docker compose -f /path/to/traefik/docker-compose.yml logs traefik | grep -i "acme\|cert\|tls"
```

---

## 10. Rollback Procedures

### Full Disaster Recovery

In case of complete server failure:

```bash
# 1. Provision new Hetzner CX22 server
# 2. Install Docker and clone this repository
# 3. Configure DNS to point to new server IP
# 4. Restore from backup:

# Download latest backup from Storage Box
rclone copy hetzner-storagebox:harbor-backups/LATEST/ /opt/harbor-restore/

# Restore database
cd /opt/harbor-registry
docker compose up -d harbor-db
sleep 15
zcat /opt/harbor-restore/harbor-db-*.sql.gz | docker exec -i harbor-db psql -U postgres

# Restore registry data
tar -xzf /opt/harbor-restore/harbor-registry-data-*.tar.gz -C /opt/harbor-registry/

# Restore configuration
cp -r /opt/harbor-restore/config/harbor-config/* /opt/harbor-registry/config/
cp /opt/harbor-restore/config/env.backup /opt/harbor-registry/.env
cp /opt/harbor-restore/config/docker-compose.yml /opt/harbor-registry/

# Start all services
docker compose up -d

# Verify
curl -sk https://registry.yourdomain.com/api/v2.0/health | jq .
```

---

## Architecture Overview

```
                    ┌─────────────────────────────────────────┐
                    │          Internet / Clients             │
                    └──────────────────┬──────────────────────┘
                                       │
                              ┌────────▼────────┐
                              │     Traefik     │
                              │   + ModSecurity │
                              │    (External)   │
                              └────────┬────────┘
                                       │
                    ┌──────────────────┼──── webproxy
                    │                  │
                    │        ┌─────────▼─────────┐
                    │        │   Harbor Core     │◄─── API + Auth + Proxy
                    │        │   (port 8080)     │
                    │        └──┬──┬──┬──┬──┬────┘
                    │           │  │  │  │  │
          ┌─────────┘    ┌──────┘  │  │  │  └──────┐
          │              │         │  │  │         │
  ┌───────▼───┐  ┌──────▼──┐ ┌──▼──▼──▼──┐ ┌────▼──────┐
  │  Portal   │  │Registry │ │  DB  Redis│ │ Jobservice│
  │  (Nginx)  │  │(Distrib)│ │  (PG) (KV)│ │  (Async)  │
  └───────────┘  └────┬────┘ └───────────┘ └─────┬─────┘
                       │                          │
                 ┌─────▼─────┐             ┌──────▼──────┐
                 │Registryctl│             │Trivy Adapter│
                 │  (GC Mgr) │             │ (Scanner)   │
                 └───────────┘             └─────────────┘

                 ──── harbor-internal network (MTU 1450) ────
```

---

## File Reference

| File                 | Purpose                                                          |
| :------------------- | :--------------------------------------------------------------- |
| `docker-compose.yml` | Main service definitions with resource limits and Traefik labels |
| `.env.example`       | Environment variable template with secret placeholders           |
| `.env`               | Actual secrets (never commit to git)                             |
| `harbor-backup.sh`   | Automated backup script with rclone sync                         |
| `config/`            | Harbor service configuration (generated by installer)            |
