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
Installés en Phase 2 : Trivy 0.76.0.
Installés en Phase 7 : kube-prometheus-stack 91.8.2 (Helm). Images d'outillage documentaire : pandoc/latex:3.11.0, marpteam/marp-cli:v4.5.1.
Installés en Phase 6 : kubeseal 0.40.0 (release vérifiée), Sealed Secrets 0.40.0 et Argo CD v3.5.4 (Helm, `scripts/gitops-bootstrap.sh`).
Installés en Phase 5 : gh 2.102.0 (dépôt APT GitHub), gitleaks 8.30.1 et actionlint 1.7.12 (releases vérifiées), shellcheck 0.9.0 (Ubuntu), semgrep 1.178.0 (~/.venvs/semgrep). Trivy remplacé par le binaire 0.74.0 figé.
Installés en Phase 4 : k3s v1.36.5+k3s1 (Ansible), kubectl 1.36.5 (pkgs.k8s.io), Helm 4.3.0 (dépôt Helm).
Installés en Phase 3 : Terraform 1.16.6 (dépôt HashiCorp), Ansible (core 2.16.3) et ansible-lint 6.17.2 (dépôts Ubuntu).
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

## 4 ter. GitHub

- Dépôt : https://github.com/Ghassen-kahia/plateforme-devsecops (public), compte `Ghassen-kahia`.
- Authentification : `gh` (keyring de l'utilisateur, scopes repo/workflow) ; ne jamais afficher le token.
  Le token n'a PAS `read:packages` : vérifier GHCR par un accès anonyme (`ghcr.io/token`).
- Images : `ghcr.io/ghassen-kahia/plateforme-{api,frontend}:sha-<12>` (publiques).
- La CI pousse sur main (commits `chore(gitops)`) : faire `git pull --rebase` avant de travailler.

## 4 quinquies. Supervision

- Grafana : `kubectl -n monitoring port-forward svc/kps-grafana 3000:80` (admin, mot de passe dans le Secret `grafana-admin`).
- Requêtes sans port-forward : `kubectl get --raw /api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy/api/v1/...`
- **Ressources** : au repos ≈ 67–73 % des 2 vCPU utilisés. Éviter de lancer de lourdes opérations en parallèle. 4 vCPU recommandés.
- La VM peut être gelée par l'hôte (veille) : au réveil, une cascade de redémarrages est normale (≈ 8 min).

## 4 quater. GitOps — règles d'exploitation

- NE PLUS utiliser `helm upgrade` ni `kubectl apply/edit/scale` sur plateforme-dev/prod : Argo CD annule.
  Tout changement passe par Git (`k8s/environments/<env>/values.yaml` ou le chart).
- Rollback : `git revert <commit chore(gitops)>` puis push.
- Promotion prod : `gh workflow run promote.yml` (option `-f tag=sha-…`).
- Interface : `kubectl -n argocd port-forward svc/argocd-server 8443:443` → https://localhost:8443 (admin).
- Argo CD et Sealed Secrets eux-mêmes : `scripts/gitops-bootstrap.sh` (Helm).

## 4 bis. Accès local

- dev : `http://dev.plateforme.local` ; prod : `http://plateforme.local` (Traefik sur 80).
  Sans modifier /etc/hosts : `curl --resolve <hôte>:80:127.0.0.1 http://<hôte>/`.
- Images : GHCR (`ghcr.io/ghassen-kahia/…:sha-<12>`) pour dev et prod. Les images locales 0.1.0 ne servent plus.
- Secrets `plateforme-db` : désormais générés par les SealedSecret (valeurs d'environnement chiffrées).
- Stack Compose arrêtée (`docker compose stop`), volume conservé.

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
- [x] **Phase 2 — Conteneurisation sécurisée** (terminée le 2026-10-14)
  - [x] Trivy 0.76.0 installé (`install.sh scan`), politique `trivy.yaml`
  - [x] API : multi-stage slim, UID 10001, sans pip ; frontend : nginx-unprivileged alpine, UID 101
  - [x] `.dockerignore` en liste blanche, Compose : read_only, cap_drop ALL, no-new-privileges
  - [x] Avant/après mesuré (docs/mesures.md M3) ; contrôle négatif bloquant vérifié
  - [x] Politique de sécurité : docs/securite.md
- [x] **Phase 3 — Terraform et Ansible** (terminée le 2026-10-14)
  - [x] Terraform 1.16.6, ansible-core 2.16.3, ansible-lint 6.17.2 installés (`install.sh iac`)
  - [x] Module AWS (VPC, sous-réseau, SG, EC2, Flow Logs) : fmt, validate, Trivy OK — **jamais appliqué**
  - [x] Module local (namespaces, PSA, quotas, LimitRange) : validate OK — application en Phase 4
  - [x] Rôles Ansible common, ssh_hardening, firewall, k3s : lint production, `--check` OK
- [x] **Phase 4 — Kubernetes et Helm** (terminée le 2026-10-14)
  - [x] Ansible exécuté : UFW actif, sysctl, k3s v1.36.5+k3s1 durci ; idempotent (changed=0)
  - [x] kubectl 1.36.5 et Helm 4.3.0 (`install.sh k8s`) ; Terraform local appliqué (8 ressources, sans dérive)
  - [x] Chart Helm `k8s/helm/plateforme` (api, frontend, PostgreSQL StatefulSet, Ingress, HPA, NetworkPolicy)
  - [x] dev et prod déployés manuellement, temps mesurés
  - [x] Probes, NetworkPolicy (contrôle positif), HPA, quota, release défectueuse et rollback testés
  - [x] Incident 502 diagnostiqué et corrigé (label de version dans le pod PostgreSQL)
- [x] **Phase 5 — Pipeline CI DevSecOps** (terminée le 2026-10-14)
  - [x] gh 2.102, gitleaks 8.30.1, actionlint 1.7.12, shellcheck, semgrep 1.178.0 (venv), Trivy figé en 0.74.0
  - [x] `.github/workflows/ci.yml` (lint/test, gitleaks, semgrep, IaC/SCA, build/scan/push GHCR, update-gitops)
  - [x] `.github/workflows/promote.yml` (promotion manuelle dev → prod)
  - [x] État désiré par environnement : `k8s/environments/{dev,prod}/values.yaml`
  - [x] Contrôles positifs locaux : secret factice et dépendance vulnérable bloqués
  - [x] Dépôt public https://github.com/Ghassen-kahia/plateforme-devsecops (`gh auth login` par l'utilisateur)
  - [x] Pipeline vert (141 s), images GHCR publiques, commit GitOps automatique
  - [x] PR #1 (secret factice) bloquée par Gitleaks, PR #2 (pyyaml 5.3.1) bloquée par Trivy ; fermées sans fusion
  - [x] Correctif : périmètre Gitleaks par événement + scan complet hebdomadaire
  - [ ] Limite : pas de protection de branche (incompatible avec le push GitOps direct) — documentée
- [x] **Phase 6 — GitOps avec Argo CD** (terminée le 2026-10-14)
  - [x] Sealed Secrets 0.40.0 + kubeseal ; mot de passe PostgreSQL existant scellé (portée strict)
  - [x] Argo CD v3.5.4 (exception sécurité à la règle des 2 semaines), app of apps, AppProject restreint
  - [x] Reprise des releases Helm sans coupure (prod) ; métadonnées Helm supprimées
  - [x] Push → dev en 189 s ; config Git → dev en 49 s ; rollback `git revert` en 89 s ; promotion prod en 84 s
  - [x] Self-heal : 3 dérives corrigées en 1,7 à 6,1 s
  - [x] Incident 502 au rolling update corrigé (preStop) : 0 erreur sur 3 337 requêtes
- [x] **Phase 7 — Supervision** (terminée le 2026-10-14)
  - [x] kube-prometheus-stack 91.8.2 (`monitoring/install.sh`), profil réduit, adapté à k3s
  - [x] ServiceMonitor API + PodMonitor Traefik ; 4 alertes par environnement (base, API, 5xx Ingress, p95)
  - [x] Tableau de bord Grafana provisionné depuis Git (12 panneaux vérifiés)
  - [x] Panne contrôlée via Git : alertes dans Alertmanager en 63–94 s ; retour en 166 s ; résolution en 359 s
  - [x] Corrigés : label namespace des alertes, PodMonitor mal placé, node-exporter bridé, probes PostgreSQL
  - [x] Incident documenté : gel de la VM par l'hôte → cascade de redémarrages (charge 52), reprise auto
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
trivy image --config trivy.yaml plateforme-api:dev   # contrôle de vulnérabilités bloquant
trivy config app/                    # Dockerfiles
terraform fmt -recursive -check infra/terraform && terraform -chdir=infra/terraform/aws validate
trivy config --config trivy.yaml infra/
(cd infra/ansible && ansible-lint && ansible-playbook site.yml --check)
helm lint k8s/helm/plateforme -f k8s/environments/prod/values.yaml
trivy config --config trivy.yaml .     # tout le dépôt (une seule cible)
trivy fs --config trivy.yaml --scanners vuln,secret --skip-dirs reports .   # SCA
gitleaks git --redact .                # secrets dans l'historique
~/.local/bin/semgrep scan --metrics=off --error --config p/python --config p/bandit --config p/security-audit --config p/javascript --config p/dockerfile --config p/secrets
actionlint                             # workflows (+ shellcheck)
kubectl get pods -A ; kubectl -n plateforme-dev get pods,svc,ingress,netpol
curl --resolve dev.plateforme.local:80:127.0.0.1 http://dev.plateforme.local/ready
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
| 2026-10-14 | Trivy : HIGH/CRITICAL bloquants, `ignore-unfixed` | Bloquer ce qui est corrigeable ; tracer le reste (docs/securite.md) |
| 2026-10-14 | Debian slim plutôt qu'Alpine (Python) ou distroless | Roues glibc, Python 3.12 conservé, débogage possible ; distroless en perspective |
| 2026-10-14 | Terraform local = socle Kubernetes (namespaces, PSA, quotas) | Terraform pour la plateforme, Helm/Argo pour les applications |
| 2026-10-14 | k3s installé par Ansible (script au tag + SHA-256), pas par `curl \| sh` | Reproductibilité et intégrité |
| 2026-10-14 | k3s durci : secrets-encryption, protect-kernel-defaults, audit log | Guide de durcissement CIS de k3s |
| 2026-10-14 | k3s v1.36.5+k3s1 (canal stable au 2026-10-14) | Version stable figée |
| 2026-10-14 | PostgreSQL en StatefulSet maison (pas de chart Bitnami) | Images Bitnami gratuites restreintes depuis 2025 ; chart simple et maîtrisé |
| 2026-10-14 | Secret de la base créé hors du chart (`existingSecret`) | Aucun secret dans les values ; Sealed Secrets en Phase 6 |
| 2026-10-14 | Frontend relaie /api (une seule route Ingress) | Même topologie qu'en Compose, pas de CORS |
| 2026-10-14 | UID > 10000 pour tous les conteneurs | Pas de collision avec les UID de l'hôte (KSV-0020/21) |
| 2026-10-14 | Pas de label de version dans le modèle de pod PostgreSQL | Une release applicative ne doit pas redémarrer la base |
| 2026-10-14 | Versions d'outils avec ≥ 2 semaines de recul (Trivy 0.74.0, Semgrep 1.178.0, ansible-lint 26.9.0) | Prudence supply chain |
| 2026-10-14 | Actions GitHub épinglées par SHA, permissions `{}` par défaut | Moindre privilège, immuabilité |
| 2026-10-14 | État GitOps dans ce dépôt (`k8s/environments/`), mis à jour par `GITHUB_TOKEN` | Aucun secret supplémentaire ; dépôt séparé = alternative documentée |
| 2026-10-14 | Tag d'image `sha-<12>` | Traçabilité commit ↔ image, rollback sans ambiguïté |
| 2026-10-14 | Argo CD 3.5.4 malgré la règle des 2 semaines | 3.5.3 vulnérable (4 CVE critiques) : un correctif de sécurité prime |
| 2026-10-14 | App of apps + AppProject restreint | GitOps de bout en bout, moindre privilège pour Argo CD |
| 2026-10-14 | Sealed Secrets (portée strict) | Secrets versionnés sans service externe payant |
| 2026-10-14 | preStop sleep 5 s natif | Course SIGTERM / endpoints mesurée et corrigée |
| 2026-10-14 | Toujours chaîner les validations avec `&&` avant commit | Un commit est parti malgré un échec (`;`) |
| 2026-10-14 | Alerte 5xx mesurée à Traefik (Ingress) | L'API hors service ne voit pas les requêtes |
| 2026-10-14 | Supervision de l'application dans son chart (ServiceMonitor, PrometheusRule) | Versionnée et déployée avec l'application |
| 2026-10-14 | Panne contrôlée via Git (`database.replicas`) | Le self-heal annulerait un `kubectl scale` |
| 2026-10-14 | Pandoc et Marp via Docker (versions figées) | Pas de TeX Live ni de navigateur à installer sur la VM |
| 2026-10-14 | Enchaînement des phases sans attendre `continue` | Demande explicite de l'utilisateur ; arrêt uniquement pour token, dépôt, AWS ou coût |
