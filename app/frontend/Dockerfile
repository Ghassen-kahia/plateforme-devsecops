# syntax=docker/dockerfile:1
# =============================================================================
# Image du frontend — durcie (Phase 2)
#   - nginx-unprivileged : maintenue par l'équipe Nginx, tourne en UID 101, écoute sur 8080
#     (un port < 1024 exigerait la capacité NET_BIND_SERVICE)
#   - Alpine : image minimale (musl, BusyBox)
# =============================================================================
FROM nginxinc/nginx-unprivileged:1.30.6-alpine

ARG APP_VERSION=dev
LABEL org.opencontainers.image.title="plateforme-frontend" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.licenses="MIT"

# Correctifs Alpine publiés après l'image amont (ex. brotli, curl : CVE HIGH bloquées par Trivy
# le 2026-10-28) ; l'image de base reste figée, seuls les paquets corrigés sont mis à jour
USER root
RUN apk upgrade --no-cache

# Fichiers statiques en lecture seule (propriété root) ; Nginx (UID 101) ne fait que les lire
COPY --chown=root:root index.html style.css app.js /usr/share/nginx/html/
COPY --chown=root:root default.conf.template /etc/nginx/templates/default.conf.template

USER 101
EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]
