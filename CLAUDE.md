# CLAUDE.md — Plateforme DevSecOps de déploiement continu sur Kubernetes

Mémoire de travail du projet : contexte, décisions, état réel, conventions.
**À lire avant toute intervention. À mettre à jour à la fin de chaque phase.**

## 1. Contexte et objectif

Projet personnel de portfolio (recherche de stage PFE Cloud / DevOps / DevSecOps en France).

Problématique : une équipe déploie manuellement, sans contrôle de sécurité, sans rollback ni supervision.
Objectif : chaque push sur GitHub déclenche une chaîne automatisée
lint/tests → Gitleaks → SAST → build → Trivy → GHCR → mise à jour GitOps → Argo CD → k3s → Prometheus/Grafana.

Toute la documentation et les explications sont **en français**.

## 2. Environnement réel (audit du 2026-10-14)

| Élément | Valeur observée |
|---|---|
| OS | Ubuntu 24.04.5 LTS, noyau 7.0.0-38-generic, VM VMware |
| CPU | **2 vCPU** (i5-11400H) — principal facteur limitant |
| RAM | 11 GiB (≈ 8,8 GiB disponibles, bureau GNOME actif) + swap 3,8 GiB |
| Disque | 79 Go, 42 Go libres |
| cgroups | v2 (compatible k3s) |
| Réseau | `ens33` 192.168.231.234/24 (NAT VMware) |
| Ports occupés | 53 (systemd-resolved, loopback), 631 (CUPS, loopback) — 80/443/6443/10250 libres |
| Pare-feu | UFW installé mais **inactif** (`ufw status` ; le service systemd est actif mais ne filtre rien). Activé et configuré par Ansible en Phase 3 |
| SSH serveur | inactif |
| sudo | sans mot de passe pour l'agent (`/etc/sudoers.d/claude-nopasswd`, ajouté par l'utilisateur le 2026-10-14) |

Outils présents : git 2.43, python3 3.12.3, curl, jq, ufw.
Installés en Phase 0 : Docker Engine 29.9.0, Compose v5.6.0, Buildx 0.38.0, containerd 2.4.2, python3-venv, pip, make.
Encore absents : kubectl, helm, k3s, terraform, ansible, trivy, gitleaks, semgrep, pandoc, marp, node.

## 3. Stack retenue et justification courte

| Besoin | Outil | Pourquoi |
|---|---|---|
| API | FastAPI (Python) | Simple, typé, OpenAPI natif, écosystème Prometheus |
| Frontend | HTML/CSS/JS + Nginx | Aucun framework : focus sur l'infra |
| BDD | PostgreSQL | Standard, image officielle maintenue |
| Tests | pytest | Standard Python |
| Conteneurs | Docker Engine + Compose v2 (dépôt APT officiel) | Dev local reproductible ; snap Docker évité (confinement, versions) |
| Kubernetes | k3s single-node | Léger (2 vCPU), Traefik + local-path inclus |
| Packaging | Helm | Templating par environnement, historique de releases |
| CI | GitHub Actions | Intégré à GitHub/GHCR, gratuit pour dépôt public |
| Secrets Git | Gitleaks | Rapide, règles maintenues |
| SAST | Semgrep (CE) | Pas de serveur à opérer (SonarQube trop coûteux en RAM/CPU ici) |
| Scan image/IaC | Trivy | Un seul outil pour images, IaC, config |
| Registre | GHCR | Gratuit, lié au dépôt, auth via GITHUB_TOKEN |
| GitOps | Argo CD | UI pédagogique, self-heal, historique |
| Secrets K8s | Sealed Secrets (prévu) | Secrets chiffrés commitables, sans service externe |
| Supervision | kube-prometheus-stack (réduit) | Prometheus + Grafana + Alertmanager standard |
| IaC | Terraform (local + AWS non appliqué), Ansible | Provisionnement + configuration/durcissement |

## 4. Plan de capacité (2 vCPU / 11 GiB)

Estimation **à vérifier par mesure** (Phase 4+) :
k3s ≈ 0,5–1 GiB ; Argo CD ≈ 0,5–0,8 GiB ; kube-prometheus-stack réduit ≈ 1–1,5 GiB ;
app + PostgreSQL ≈ 0,3 GiB ; bureau GNOME ≈ 2 GiB. → RAM suffisante.
CPU : 2 vCPU est juste. Stratégie : requests/limits partout, Prometheus rétention courte
(ex. 24 h), composants inutiles désactivés (ex. Argo CD Dex/notifications), installation progressive.
**Recommandation : passer la VM à 4 vCPU si possible** (gratuit, réglage VMware).

## 5. Risques identifiés

1. **sudo sans mot de passe pour l'agent** : pratique, mais élargit ce qu'un agent peut faire. À retirer (`sudo rm /etc/sudoers.d/claude-nopasswd`) une fois le projet terminé.
2. **Docker contourne UFW** : un port publié (`-p 8080:80`) est exposé malgré UFW (règles iptables DOCKER).
   → Convention : en Compose, publier sur `127.0.0.1:` uniquement.
3. **UFW (à activer en Phase 3) + k3s** : le trafic pods/services (10.42.0.0/16, 10.43.0.0/16) et l'API (6443) doivent être autorisés, sinon DNS/pods en échec.
4. **Docker et k3s cohabitent** : deux runtimes (dockerd/containerd de Docker et containerd embarqué de k3s). Pas de conflit de ports, mais double consommation disque ; les images construites par Docker doivent être importées ou poussées dans GHCR pour k3s.
5. **Groupe docker = root** : accepté sur VM perso, documenté (alternative : Docker rootless).
6. **Noyau 7.0 récent** : compatibilité Docker/k3s à confirmer par les tests réels.

## 6. Conventions

- **Sécurité** : aucun secret en dur ; `.env` ignoré, `.env.example` sans valeur ; tokens jamais affichés ; Base64 ≠ chiffrement ; exceptions de scan documentées, jamais de règle désactivée en silence.
- **Git** : Conventional Commits en français ; branche `main` ; pas de push forcé ; commit seulement si validations OK.
- **Shell** : `set -euo pipefail`, pas de `|| true` pour masquer un échec.
- **Images** : tags versionnés (jamais `latest` en prod), utilisateur non-root.
- **AWS** : code Terraform écrit et validé statiquement, **jamais appliqué sans accord explicite**.
- **Méthode** : une phase à la fois, arrêt et attente du message `continue`.

## 7. Structure du dépôt (créée progressivement)

```
app/{backend/api,frontend,tests/{unit,integration}}, app/Dockerfile (API), app/frontend/Dockerfile (contexte de build propre au frontend)
  infra/{terraform/{local,aws},ansible}
k8s/{helm/plateforme,argocd}  monitoring/  .github/workflows/
docs/{apprentissage.md,mesures.md,architecture,rapport,presentation}
scripts/{install.sh,demo.sh}  .gitignore  .env.example  README.md  CLAUDE.md
```

## 8. Plan des phases

- [x] **Phase 0 — Audit et préparation** (terminée le 2026-10-14)
  - [x] Audit VM (ressources, outils, ports, services)
  - [x] Dépôt Git initialisé, `.gitignore`, `CLAUDE.md`, docs de base
  - [x] `scripts/install.sh base` écrit et validé syntaxiquement
  - [x] Docker + Compose + venv installés et vérifiés (`hello-world` OK)
  - [x] Identité Git configurée (locale au dépôt), commit de fin de phase
- [x] **Phase 1 — Application de démonstration** (terminée le 2026-10-14)
  - [x] API FastAPI (`/health`, `/ready`, `/metrics`, `/api/version`, CRUD `/api/tasks`)
  - [x] Frontend HTML/CSS/JS + Nginx (proxy `/api`, en-têtes de sécurité)
  - [x] PostgreSQL 18 via Compose, ports sur 127.0.0.1
  - [x] 16 tests unitaires + 4 d'intégration (réussis contre un vrai PostgreSQL)
  - [x] Panne de base simulée : liveness OK, readiness 503, reprise ≈ 1 s
  - [ ] (Phase 2) Dockerfiles encore naïfs : root, 1,69 GB
- [ ] Phase 2 — Conteneurisation sécurisée (+ installation Trivy)
- [ ] Phase 3 — Terraform et Ansible (+ installation terraform, ansible ; k3s via Ansible)
- [ ] Phase 4 — Kubernetes et Helm (+ kubectl, helm)
- [ ] Phase 5 — Pipeline CI DevSecOps (+ gitleaks, semgrep en local ; token GitHub à ce moment)
- [ ] Phase 6 — GitOps avec Argo CD
- [ ] Phase 7 — Supervision
- [ ] Phase 8 — Documentation professionnelle
- [ ] Phase 9 — Rapport (pandoc)
- [ ] Phase 10 — Présentation (marp)

Installation des outils : **juste-à-temps**, dans la phase qui en a besoin (cibles ajoutées à `scripts/install.sh`).

## 9. Commandes de validation

```bash
# Application (depuis app/)
../.venv/bin/ruff check . && ../.venv/bin/ruff format --check . && ../.venv/bin/pytest -q
docker compose --env-file ../.env up -d --build
set -a; . ../.env; set +a; DB_PASSWORD="$POSTGRES_PASSWORD" RUN_INTEGRATION=1 ../.venv/bin/pytest
# Environnement
bash scripts/install.sh check        # prérequis Phase 0
docker run --rm hello-world          # moteur Docker fonctionnel
docker compose version
git status
```

## 10. Décisions techniques (journal)

| Date | Décision | Raison |
|---|---|---|
| 2026-10-14 | Docker via dépôt APT officiel, pas snap | Snap : confinement gênant pour les volumes, mises à jour non maîtrisées |
| 2026-10-14 | Installation juste-à-temps par phase | Limiter la surface installée et lier chaque outil à un usage vérifié |
| 2026-10-14 | Semgrep plutôt que SonarQube | SonarQube demande ≈ 2 GiB RAM + PostgreSQL dédié, disproportionné sur 2 vCPU |
| 2026-10-14 | Ports Compose liés à 127.0.0.1 | Docker contourne UFW |
| 2026-10-14 | Docker CE 29.9.0 / Compose v5.6.0 | Versions stables du dépôt officiel au jour de l'installation |
| 2026-10-14 | psycopg 3 + pool, sans ORM | Peu de tables ; SQL explicite, plus simple à expliquer |
| 2026-10-14 | Liveness `/health` sans base, readiness `/ready` avec base | Éviter les redémarrages en cascade |
| 2026-10-14 | `httpx` gardé malgré l'avertissement Starlette (httpx2) | Paquet éprouvé ; avertissement filtré et documenté |
| 2026-10-14 | Dockerfiles naïfs en Phase 1, durcis en Phase 2 | Avant/après Trivy réellement mesuré |
| 2026-10-14 | Images : python 3.12.15, nginx 1.30.5 (branche stable), postgres 18.6-alpine3.24 | Tags précis relevés sur Docker Hub |
| 2026-10-14 | Enchaînement des phases sans attendre `continue` | Demande explicite de l'utilisateur ; arrêt uniquement pour token, dépôt, AWS ou coût |
