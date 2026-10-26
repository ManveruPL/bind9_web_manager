# Coolify Deployment Plan: BIND9 Web Manager

This document outlines the architecture, repository modifications, host configuration, and deployment steps required to run **PRIVUM BIND9 Web Manager** as a containerized Coolify project on `local-dns-root` while managing the server's existing native BIND9 installation.

---

## 1. Context & Architecture

### Target Environment (`local-dns-root`)
* **Host OS**: Debian 13 (Trixie) x86_64, Linux kernel 6.12.
* **Native BIND9**: Running natively as `named.service` on port 53 (TCP/UDP), with zones stored in `/etc/bind/zones` and configured in `/etc/bind/named.conf.local`.
* **Coolify**: Running v4.5 with Traefik proxy (`coolify-proxy`) handling ports 80/443 on the `coolify` Docker network (bridge gateway `10.0.1.1`).
* **Objective**: Avoid installing Python, virtual environments, and host Nginx configurations directly on the OS. Package the web manager and API inside a Coolify container that seamlessly controls the native BIND9 instance.

### System Diagram
```
                     ┌────────────────────────────────────────────────────────┐
                     │                   HOST: local-dns-root                 │
                     │                                                        │
                     │   ┌────────────────┐         ┌─────────────────────┐   │
                     │   │ Coolify        │         │ Native BIND 9       │   │
                     │   │ Traefik Proxy  │         │ (:53 TCP/UDP)       │   │
                     │   └───────┬────────┘         │ (:953 RNDC)         │   │
                     │           │                  └──────────▲──────────┘   │
                     │           │ HTTP                        │              │
                     │           ▼                             │              │
                     │  ┌──────────────────────────────────┐   │ RNDC reload  │
                     │  │ Coolify Container                │───┘ (:953)       │
                     │  │  - Nginx (SPA static + /api)     │                  │
                     │  │  - Gunicorn / Flask backend      │                  │
                     │  │  - bind9-dnsutils (rndc binary)  │──┐               │
                     │  └──────────────────────────────────┘  │               │
                     │            │                           │ Direct volume │
                     │            ▼                           │ mount         │
                     │     Persistent DB                      ▼               │
                     │     (SQLite in Docker)      /etc/bind & /etc/bind/zones│
                     └────────────────────────────────────────────────────────┘
```

---

## 2. Planned Repository Changes

### 2.1 Multi-Stage `Dockerfile` (Root)
Builds the React frontend and packages it with the Python backend, Nginx, and BIND9 client utilities (`rndc`, `named-checkzone`):

```dockerfile
# ==========================================
# Stage 1: Build Frontend SPA
# ==========================================
FROM node:20-alpine AS frontend-builder
WORKDIR /app/frontend

COPY frontend/package*.json ./
RUN npm ci

COPY frontend/ ./
RUN npm run build

# ==========================================
# Stage 2: Runtime Environment
# ==========================================
FROM python:3.11-slim-bookworm

# Install rndc, named-checkzone, dig, nginx, and supervisor
RUN apt-get update && apt-get install -y --no-install-recommends \
    bind9-utils \
    bind9-dnsutils \
    nginx \
    supervisor \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python backend dependencies
COPY web-manager/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copy backend code
COPY web-manager/ /app/backend/

# Copy built frontend assets
COPY --from=frontend-builder /app/frontend/dist /var/www/dns-manager

# Copy configurations
COPY docker/nginx.conf /etc/nginx/sites-available/default
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

ENV FLASK_ENV=production
ENV DOCKER_CONTAINER=true
ENV PYTHONUNBUFFERED=1
ENV ZONES_PATH=/etc/bind/zones
ENV NAMED_CONF_LOCAL=/etc/bind/named.conf.local
ENV RNDC_KEY_PATH=/etc/bind/rndc.key
ENV DATABASE_URL=sqlite:////app/data/dns_manager.db

RUN mkdir -p /app/data /var/log/dns-manager

EXPOSE 80

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
```

### 2.2 `docker/nginx.conf`
Internal Nginx server to handle SPA client routing and forward `/api` requests to Gunicorn:

```nginx
server {
    listen 80;
    server_name _;

    root /var/www/dns-manager;
    index index.html;

    client_max_body_size 50M;

    # React SPA routing
    location / {
        try_files $uri $uri/ /index.html;
    }

    # API Proxy to Gunicorn
    location /api {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Health check endpoint
    location /health {
        proxy_pass http://127.0.0.1:5000/health;
    }
}
```

### 2.3 `docker/supervisord.conf`
Process supervisor running both services inside the single container:

```ini
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisord.log
pidfile=/var/run/supervisord.pid

[program:gunicorn]
directory=/app/backend
command=gunicorn --workers 2 --bind 127.0.0.1:5000 --access-logfile - --error-logfile - app:app
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:nginx]
command=nginx -g "daemon off;"
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
```

### 2.4 `docker-compose.coolify.yml`
Coolify-compatible Docker Compose file:

```yaml
services:
  bind9-web-manager:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: bind9-web-manager
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      - FLASK_ENV=production
      - FLASK_SECRET_KEY=${FLASK_SECRET_KEY}
      - DNS_MASTER_HOST=host.docker.internal
      - DNS_MASTER_IP=192.168.35.3
      - ZONES_PATH=/etc/bind/zones
      - NAMED_CONF_LOCAL=/etc/bind/named.conf.local
      - RNDC_KEY_PATH=/etc/bind/rndc.key
      - DATABASE_URL=sqlite:////app/data/dns_manager.db
    volumes:
      - /etc/bind:/etc/bind
      - dns_manager_data:/app/data
    networks:
      - coolify

volumes:
  dns_manager_data:

networks:
  coolify:
    external: true
```

### 2.5 `.dockerignore`
Ensures clean and fast Docker builds:
```
node_modules
frontend/dist
frontend/node_modules
web-manager/venv
web-manager/__pycache__
web-manager/data
.git
.env
```

### 2.6 Bugfix in `web-manager/services/dns_service.py`
On Debian servers, zone statements often use the `IN` keyword:
```bind
zone "local.fehu-web.dev" IN { ... };
```
The upstream regex ignores zones with `IN`. The fix makes `IN` optional:

* In `get_zones()`:
  ```python
  # Change:
  zone_pattern = r'zone\s+"([^"]+)"\s*\{[^}]*?type\s+master[^}]*?file\s+"([^"]+)"'
  # To:
  zone_pattern = r'zone\s+"([^"]+)"(?:\s+IN)?\s*\{[^}]*?type\s+master[^}]*?file\s+"([^"]+)"'
  ```
* In `delete_zone()`:
  ```python
  # Change:
  pattern = rf'\n*zone\s+"{re.escape(zone_name)}"\s*\{{[\s\S]*?^\}};\s*'
  # To:
  pattern = rf'\n*zone\s+"{re.escape(zone_name)}"(?:\s+IN)?\s*\{{[\s\S]*?^\}};\s*'
  ```

---

## 3. Host-Side Configuration (`local-dns-root`)

By default, Debian's BIND9 only listens for RNDC commands on loopback (`127.0.0.1:953`). To allow the Coolify container to trigger `rndc reload`:

1. Add a `controls` statement to `/etc/bind/named.conf`:
   ```bind
   controls {
       inet 127.0.0.1 port 953 allow { 127.0.0.1; } keys { "rndc-key"; };
       inet 10.0.1.1 port 953 allow { 10.0.1.0/24; 127.0.0.1; } keys { "rndc-key"; };
   };
   ```
2. Check configuration syntax:
   ```bash
   named-checkconf /etc/bind/named.conf
   ```
3. Reload BIND9:
   ```bash
   rndc reload
   ```

---

## 4. Deployment Steps in Coolify

1. **Push Changes to GitHub**:
   Commit and push the new files and fixes to `git@github.com:ManveruPL/bind9_web_manager.git`.
2. **Create Project / Application in Coolify**:
   * Open Coolify Dashboard (port `8000`).
   * Select or create a Project.
   * Add Resource → **Git Repository (Private or Public)**.
   * Enter repository: `git@github.com:ManveruPL/bind9_web_manager.git` on branch `main`.
   * Set Build Pack to **Docker Compose**.
   * Specify compose file: `docker-compose.coolify.yml`.
3. **Configure Environment Variables**:
   * `FLASK_SECRET_KEY`: Generate a random 64-character hex key (e.g. `openssl rand -hex 32`).
4. **Configure Domain & SSL**:
   * Set your desired FQDN (e.g., `https://dns.local.fehu-web.dev` or `https://dns-admin.yourdomain.com`).
   * Coolify will automatically configure Traefik and issue Let's Encrypt / local SSL certificates.
5. **Deploy & Verify**:
   * Click **Deploy**.
   * Once started, visit the web interface.
   * Log in with default credentials: `admin` / `admin`.
   * Immediately update the admin password and check that existing zones are visible and manageable.
