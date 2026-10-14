#!/usr/bin/env bash
# =============================================================================
# monitoring/install.sh — Installe kube-prometheus-stack dans le namespace monitoring
# Idempotent. Le mot de passe admin Grafana est généré une seule fois et jamais affiché.
# =============================================================================
set -euo pipefail

CHART_VERSION="91.8.2"
NS=monitoring
DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '\033[1;34m[monitoring]\033[0m %s\n' "$*"; }

if ! kubectl -n "$NS" get secret grafana-admin >/dev/null 2>&1; then
  log "Création du Secret grafana-admin (mot de passe aléatoire, non affiché)"
  pw_file=$(mktemp); chmod 600 "$pw_file"
  openssl rand -base64 24 | tr -d '/+=\n' > "$pw_file"
  kubectl -n "$NS" create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-file=admin-password="$pw_file"
  shred -u "$pw_file"
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update prometheus-community >/dev/null

log "kube-prometheus-stack ${CHART_VERSION}"
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --version "$CHART_VERSION" -n "$NS" \
  -f "$DIR/values-kps.yaml" \
  --set-file "grafana.dashboards.plateforme.application.json=$DIR/dashboards/plateforme.json" \
  --wait --timeout 10m

log "Grafana    : kubectl -n $NS port-forward svc/kps-grafana 3000:80 → http://localhost:3000 (admin)"
log "Prometheus : kubectl -n $NS port-forward svc/kps-kube-prometheus-stack-prometheus 9090"
log "Mot de passe Grafana : kubectl -n $NS get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
