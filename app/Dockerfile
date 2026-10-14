# syntax=docker/dockerfile:1
# =============================================================================
# Image de l'API FastAPI — durcie (Phase 2)
#   - multi-stage : les outils de build (pip, cache) ne sont pas dans l'image finale
#   - base slim versionnée (Debian 13 « trixie ») : moins de paquets = moins de CVE
#   - utilisateur non-root à UID fixe (compatible runAsNonRoot de Kubernetes)
#   - pip supprimé de l'image finale : impossible d'installer un paquet depuis un conteneur compromis
# =============================================================================
ARG PYTHON_IMAGE=python:3.12.15-slim-trixie

# --- Étape 1 : construction de l'environnement virtuel ------------------------
FROM ${PYTHON_IMAGE} AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
COPY backend/requirements.txt /tmp/requirements.txt
# Les roues binaires (psycopg[binary]) évitent d'installer un compilateur
RUN /opt/venv/bin/pip install --no-compile -r /tmp/requirements.txt \
 && /opt/venv/bin/pip uninstall -y pip

# --- Étape 2 : image d'exécution ----------------------------------------------
FROM ${PYTHON_IMAGE} AS runtime
ARG APP_VERSION=dev
LABEL org.opencontainers.image.title="plateforme-api" \
      org.opencontainers.image.description="API FastAPI de la plateforme DevSecOps" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.licenses="MIT"

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${APP_VERSION}

# Utilisateur dédié (UID fixe 10001, hors plage des UID de l'hôte),
# sans shell de connexion ni répertoire personnel ;
# suppression du pip de l'image de base (inutile à l'exécution, porteur de CVE)
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app \
 && python -m pip uninstall -y --root-user-action=ignore pip \
 && rm -rf /root/.cache

COPY --from=build /opt/venv /opt/venv
WORKDIR /app
# Code en lecture seule pour l'utilisateur applicatif (propriété root, pas d'écriture)
COPY --chown=root:root backend/api ./api

USER 10001:10001
EXPOSE 8000

# Utilisé par Docker/Compose ; Kubernetes utilise ses propres probes
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"]

CMD ["uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-server-header"]
