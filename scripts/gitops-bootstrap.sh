#!/usr/bin/env bash
# =============================================================================
# gitops-bootstrap.sh — Amorçage GitOps du cluster (à lancer une seule fois)
#   1. Contrôleur Sealed Secrets (déchiffre les SealedSecret versionnés dans Git)
#   2. Argo CD
#   3. Application racine « app of apps » : à partir de là, tout vient de Git
# Idempotent : `helm upgrade --install` et `kubectl apply` peuvent être relancés.
# =============================================================================
set -euo pipefail

ARGOCD_CHART_VERSION="10.9.7"          # Argo CD v3.5.4 (correctifs de sécurité du 2026-10-07)
SEALED_SECRETS_CHART_VERSION="2.20.0"  # contrôleur 0.40.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf '\033[1;34m[gitops]\033[0m %s\n' "$*"; }

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets >/dev/null
helm repo update argo sealed-secrets >/dev/null

log "Sealed Secrets ${SEALED_SECRETS_CHART_VERSION}"
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --version "$SEALED_SECRETS_CHART_VERSION" -n kube-system \
  -f "$ROOT/k8s/argocd/values-sealed-secrets.yaml" --wait

log "Argo CD (chart ${ARGOCD_CHART_VERSION})"
helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" -n argocd \
  -f "$ROOT/k8s/argocd/values-argocd.yaml" --wait --timeout 10m

log "Application racine (app of apps)"
kubectl apply -f "$ROOT/k8s/argocd/root-app.yaml"

log "Terminé. Interface : kubectl -n argocd port-forward svc/argocd-server 8443:443"
log "Mot de passe admin initial : kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
