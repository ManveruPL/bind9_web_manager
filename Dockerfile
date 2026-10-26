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
