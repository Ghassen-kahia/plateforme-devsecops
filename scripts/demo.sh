#!/usr/bin/env bash
# =============================================================================
# demo.sh — Démonstration de la plateforme DevSecOps (soutenance, entretien)
#
#   bash scripts/demo.sh etat            Vue d'ensemble (cluster, Argo CD, versions, alertes)
#   bash scripts/demo.sh securite        Contrôles de sécurité en direct (PSA, NetworkPolicy, non-root)
#   bash scripts/demo.sh derive          Modification manuelle → annulée par Argo CD (self-heal)
#   bash scripts/demo.sh historique      Historique GitOps et derniers pipelines CI
#   bash scripts/demo.sh panne --oui     Panne contrôlée de PostgreSQL en dev via Git, détection, retour
#   bash scripts/demo.sh acces           Commandes d'accès aux interfaces (Argo CD, Grafana)
#
# Tous les scénarios sont sans effet durable, sauf `panne`, qui pousse deux commits sur main
# (panne puis revert) et exige donc la confirmation --oui.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AM=/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-alertmanager:9093/proxy

titre() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
info()  { printf '\033[1;34m→\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
ko()    { printf '\033[1;31m✘\033[0m %s\n' "$*"; }

version_servie() {  # $1 = hôte Ingress
  curl -s -m 3 --resolve "$1:80:127.0.0.1" "http://$1/api/version" | jq -r '.version // "indisponible"' 2>/dev/null \
    || echo indisponible
}

alertes_plateforme() {  # alertes de l'application actives dans Alertmanager
  kubectl get --raw "$AM/api/v2/alerts" 2>/dev/null \
    | jq -r '[.[] | select(.labels.alertname|startswith("Plateforme")) | "\(.labels.alertname)(\(.labels.namespace // "?"))"] | if length==0 then "aucune" else join(", ") end'
}

etat() {
  titre "Cluster"
  kubectl get nodes -o wide --no-headers | awk '{print "nœud", $1, $2, $5, $10, $11}'
  titre "Applications Argo CD (état désiré Git ↔ cluster)"
  kubectl -n argocd get applications -o custom-columns=APPLICATION:.metadata.name,SYNC:.status.sync.status,SANTÉ:.status.health.status,RÉVISION:.status.sync.revision \
    | cut -c1-80
  titre "Versions servies (via l'Ingress Traefik)"
  info "dev  : $(version_servie dev.plateforme.local)"
  info "prod : $(version_servie plateforme.local)"
  titre "Pods applicatifs"
  for ns in plateforme-dev plateforme-prod; do kubectl -n "$ns" get pods --no-headers | sed "s/^/$ns  /"; done
  titre "Alertes de l'application (Alertmanager)"
  info "$(alertes_plateforme)"
}

securite() {
  titre "1. Pod Security Admission : un pod root est refusé (dry-run, rien n'est créé)"
  if kubectl run demo-root -n plateforme-dev --image=nginx:1.30.5 --dry-run=server >/dev/null 2>&1; then
    ko "pod accepté (inattendu)"
  else
    ok "refusé par la politique « restricted »"
  fi

  titre "2. Conteneurs non-root, sans jeton d'API"
  for c in api frontend; do
    pod=pod/$(kubectl -n plateforme-prod get pod -l "app.kubernetes.io/component=$c" -o jsonpath='{.items[0].metadata.name}')
    uid=$(kubectl -n plateforme-prod exec "$pod" -- id -u)
    if kubectl -n plateforme-prod exec "$pod" -- ls /var/run/secrets/kubernetes.io >/dev/null 2>&1; then jeton=présent; else jeton=absent; fi
    info "$c : UID=$uid, jeton ServiceAccount $jeton"
  done

  titre "3. NetworkPolicy : le frontend ne peut pas joindre la base directement"
  fe=pod/$(kubectl -n plateforme-prod get pod -l app.kubernetes.io/component=frontend -o jsonpath='{.items[0].metadata.name}')
  if kubectl -n plateforme-prod exec "$fe" -- nc -z -w 3 plateforme-prod-db 5432 >/dev/null 2>&1; then
    ko "frontend → PostgreSQL : AUTORISÉ (inattendu)"
  else
    ok "frontend → PostgreSQL : bloqué"
  fi
  if kubectl -n plateforme-prod exec "$fe" -- wget -q -T 3 -O /dev/null http://plateforme-prod-api:8000/health; then
    ok "frontend → API : autorisé (flux légitime)"
  else
    ko "frontend → API : bloqué (inattendu)"
  fi

  titre "4. Secrets : versionnés chiffrés (SealedSecret), jamais en clair dans Git"
  kubectl -n plateforme-prod get sealedsecret plateforme-db \
    -o jsonpath='{.metadata.name} → statut {.status.conditions[0].type}={.status.conditions[0].status}{"\n"}'
}

derive() {
  local ns=plateforme-dev deploy=plateforme-dev-frontend avant t0
  avant=$(kubectl -n "$ns" get deploy "$deploy" -o jsonpath='{.spec.replicas}')
  titre "Dérive : kubectl scale $deploy de $avant à 3 répliques (modification hors Git)"
  kubectl -n "$ns" scale deploy "$deploy" --replicas=3 >/dev/null
  t0=$(date +%s.%N)
  until [ "$(kubectl -n "$ns" get deploy "$deploy" -o jsonpath='{.spec.replicas}')" = "$avant" ]; do
    sleep 0.5
    if [ "$(echo "$(date +%s.%N) - $t0 > 120" | bc)" -eq 1 ]; then ko "non corrigé après 120 s"; return 1; fi
  done
  ok "Argo CD a rétabli l'état de Git ($avant répliques) en $(printf '%.1f' "$(echo "$(date +%s.%N) - $t0" | bc)") s"
}

historique() {
  titre "Historique GitOps (commits modifiant l'état désiré)"
  git -C "$ROOT" log --format='%h %ad %s' --date=format:'%Y-%m-%d %H:%M' -12 -- k8s/environments
  titre "Derniers pipelines CI"
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    (cd "$ROOT" && gh run list --limit 6)
  else
    info "gh non authentifié : voir l'onglet Actions du dépôt GitHub"
  fi
}

etat_ligne() {
  local db code
  db=$(kubectl -n plateforme-dev get pod plateforme-dev-db-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo absente)
  code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' --resolve dev.plateforme.local:80:127.0.0.1 http://dev.plateforme.local/api/tasks || true)
  echo "base prête=$db | HTTP=$code | alertes=$(alertes_plateforme)"
}

suivre() {  # $1 = motif de fin, $2 = délai max, $3 = t0
  local prev="" st
  while true; do
    st=$(etat_ligne)
    [ "$st" != "$prev" ] && info "t+$(( $(date +%s) - $3 ))s  $st"
    prev=$st
    echo "$st" | grep -qE "$1" && return 0
    [ $(( $(date +%s) - $3 )) -gt "$2" ] && { ko "délai dépassé"; return 1; }
    sleep 5
  done
}

panne() {
  [ "${1:-}" = "--oui" ] || { ko "Ce scénario pousse 2 commits sur main. Relancer avec : bash scripts/demo.sh panne --oui"; exit 2; }
  cd "$ROOT"
  [ -z "$(git status --porcelain)" ] || { ko "Répertoire de travail non propre : commiter ou mettre de côté d'abord"; exit 1; }
  git pull -q --rebase origin main
  local f=k8s/environments/dev/values.yaml t1 t2
  grep -q "^  replicas: 0" "$f" && { ko "Une panne est déjà en cours dans $f"; exit 1; }

  # Trafic utilisateur simulé pendant la démonstration
  ( while [ ! -f /tmp/demo-panne-stop ]; do
      curl -s -o /dev/null -m 2 --resolve dev.plateforme.local:80:127.0.0.1 http://dev.plateforme.local/api/tasks || true
      sleep 0.33
    done ) &
  local trafic=$!; rm -f /tmp/demo-panne-stop
  trap 'touch /tmp/demo-panne-stop' EXIT

  titre "1. Panne : arrêt de PostgreSQL en dev, via un commit Git"
  sed -i 's/^database:$/database:\n  # PANNE CONTRÔLÉE (demo.sh) — annulée par git revert\n  replicas: 0/' "$f"
  git commit -qam "chore(gitops): panne contrôlée (demo.sh) - arrêt de PostgreSQL en dev"
  git push -q origin main; t1=$(date +%s)
  info "commit $(git log --format=%h -1) poussé — Argo CD l'appliquera sous 60 s"
  suivre "PlateformeApiIndisponible.*PlateformeBaseDeDonneesIndisponible|PlateformeBaseDeDonneesIndisponible.*PlateformeApiIndisponible" 600 "$t1"
  ok "Panne détectée : alertes reçues par Alertmanager $(( $(date +%s) - t1 )) s après le push"

  titre "2. Retour à la normale : git revert"
  git revert --no-edit HEAD >/dev/null
  git push -q origin main; t2=$(date +%s)
  suivre "base prête=true \| HTTP=200" 600 "$t2"
  ok "Service rétabli $(( $(date +%s) - t2 )) s après le revert"
  suivre "alertes=aucune" 900 "$t2"
  ok "Alertes résolues $(( $(date +%s) - t2 )) s après le revert"
  touch /tmp/demo-panne-stop; wait "$trafic" 2>/dev/null || true
}

acces() {
  titre "Interfaces (port-forward, pas d'exposition publique)"
  cat <<'EOT'
Argo CD : kubectl -n argocd port-forward svc/argocd-server 8443:443      → https://localhost:8443
          mot de passe : kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
Grafana : kubectl -n monitoring port-forward svc/kps-grafana 3000:80     → http://localhost:3000
          mot de passe : kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
Application : http://dev.plateforme.local et http://plateforme.local
          (ajouter « 127.0.0.1 dev.plateforme.local plateforme.local » dans /etc/hosts, ou curl --resolve)
EOT
}

case "${1:-}" in
  etat) etat ;;
  securite) securite ;;
  derive) derive ;;
  historique) historique ;;
  panne) panne "${2:-}" ;;
  acces) acces ;;
  *) sed -n '3,14p' "$0"; exit 2 ;;
esac
