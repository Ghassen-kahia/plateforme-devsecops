# Plateforme DevSecOps de déploiement continu sur Kubernetes

[![CI DevSecOps](https://github.com/Ghassen-kahia/plateforme-devsecops/actions/workflows/ci.yml/badge.svg)](https://github.com/Ghassen-kahia/plateforme-devsecops/actions/workflows/ci.yml)

Projet personnel de portfolio : une chaîne **DevSecOps complète, locale et reproductible**. Chaque
`git push` est testé, analysé (secrets, code, dépendances, IaC, image), publié dans GHCR puis déployé
sur Kubernetes (k3s) par **GitOps** (Argo CD), sous supervision Prometheus/Grafana avec alertes.

Coût : 0 € (VM Ubuntu locale, GitHub et GHCR gratuits). Le module AWS est écrit et validé, **jamais appliqué**.

![Chaîne DevSecOps](docs/architecture/chaine-devsecops.png)

## Problématique

Une équipe déploie à la main, sans contrôle de sécurité, sans rollback fiable ni supervision : les
erreurs humaines et les vulnérabilités atteignent la production. Ce projet montre comment automatiser,
sécuriser et observer toute la chaîne, et **mesure** le résultat.

## Résultats mesurés

Tous les chiffres proviennent de mesures réelles (méthode et limites : [`docs/mesures.md`](docs/mesures.md)).

| Indicateur | Résultat |
|---|---|
| Image API : vulnérabilités (toutes sévérités) | 3 695 → **166**, 0 CRITICAL ; 1,69 GB → **221 MB** ; non-root |
| Pipeline CI complet (7 jobs) | **≈ 2 min 20** |
| `git push` → nouvelle version servie en dev | **189 s**, sans intervention (contre 84 s de commandes manuelles **sans aucun contrôle**) |
| Rollback GitOps (`git revert`) | **89 s**, 0 erreur sur 1 460 requêtes |
| Dérive manuelle (ex. NetworkPolicy supprimée) | corrigée par Argo CD en **2 s** |
| Panne de la base → alerte reçue par Alertmanager | **63 à 94 s** |
| Contrôles bloquants démontrés | PR #1 (secret factice) bloquée par Gitleaks ; PR #2 (CVE CRITICAL) bloquée par Trivy |
| Mises à jour sous trafic (après correctif `preStop`) | **0 erreur** sur 3 337 requêtes (3 déploiements) |

## Stack

| Domaine | Outils | Rôle |
|---|---|---|
| Application | FastAPI, Nginx, PostgreSQL 18, pytest | API de tâches avec `/health`, `/ready`, `/metrics` |
| Conteneurs | Docker multi-stage, images slim / unprivileged | Non-root, sans pip, `.dockerignore` en liste blanche |
| IaC | Terraform (local + AWS), Ansible | Socle Kubernetes (PSA, quotas) ; durcissement de l'hôte, UFW, k3s |
| Kubernetes | k3s v1.36, Helm, Traefik | Chart unique, dev/prod, HPA, NetworkPolicy, probes |
| CI | GitHub Actions | Lint, tests, Gitleaks, Semgrep, Trivy, SBOM, GHCR |
| GitOps | Argo CD 3.5, Sealed Secrets | Pull, self-heal, app of apps, secrets chiffrés dans Git |
| Observabilité | Prometheus, Grafana, Alertmanager | Méthode RED, 4 alertes, tableau de bord provisionné |

Justification de chaque choix et alternatives : [`CLAUDE.md`](CLAUDE.md) (journal des décisions) et
[`docs/apprentissage.md`](docs/apprentissage.md).

## Architecture

Diagrammes Mermaid et couches de sécurité : [`docs/architecture/`](docs/architecture/README.md).

```
git push → GitHub Actions (tests, Gitleaks, Semgrep, Trivy, build, scan) → GHCR
                    └─ commit k8s/environments/dev ─► Git ◄── Argo CD (dans k3s, toutes les 60 s)
                                                                   │
            Traefik ─► Nginx ─► FastAPI ─► PostgreSQL   ◄──────────┘  (dev auto, prod via promote.yml)
                 └──────────── Prometheus / Alertmanager / Grafana
```

## Prérequis

- Ubuntu 24.04, **4 vCPU recommandés** (2 vCPU fonctionnent, mais ≈ 70 % du CPU est consommé au
  repos), 8 Go de RAM, 40 Go de disque libres, accès sudo.
- Un compte GitHub (dépôt public conseillé : minutes Actions illimitées, images GHCR publiques).

## Installation pas à pas

```bash
git clone https://github.com/Ghassen-kahia/plateforme-devsecops.git && cd plateforme-devsecops

# 1. Outils (dépôts officiels ; binaires vérifiés par SHA-256 ; versions figées)
sudo bash scripts/install.sh base     # Docker, Compose, python3-venv
sudo bash scripts/install.sh scan     # Trivy 0.74.0
sudo bash scripts/install.sh iac      # Terraform, Ansible, ansible-lint
sudo bash scripts/install.sh k8s      # kubectl, Helm
sudo bash scripts/install.sh ci       # gh, Gitleaks, actionlint
sudo bash scripts/install.sh gitops   # kubeseal

# 2. Hôte durci + k3s (idempotent ; ajouter --check pour un essai à blanc)
cd infra/ansible && ansible-galaxy collection install -r requirements.yml -p ./collections
ansible-playbook site.yml && cd ../..

# 3. Socle Kubernetes : namespaces, Pod Security, quotas
terraform -chdir=infra/terraform/local init && terraform -chdir=infra/terraform/local apply

# 4. GitOps : Sealed Secrets + Argo CD + application racine
bash scripts/gitops-bootstrap.sh

# 5. Supervision
bash monitoring/install.sh
```

> **Vous forkez le projet ?** Les URL du dépôt figurent dans `k8s/argocd/`, et les mots de passe
> scellés de `k8s/environments/*/values.yaml` ne sont déchiffrables que par le cluster d'origine :
> il faut les re-sceller avec `kubeseal` (procédure dans [`docs/securite.md`](docs/securite.md)).

### Développement local (sans Kubernetes)

```bash
cp .env.example .env    # puis renseigner POSTGRES_PASSWORD (openssl rand -base64 24)
cd app && docker compose --env-file ../.env up -d --build      # http://127.0.0.1:8080
python3 -m venv ../.venv && ../.venv/bin/pip install -r backend/requirements-dev.txt
../.venv/bin/ruff check . && ../.venv/bin/pytest
```

## Démonstration

```bash
bash scripts/demo.sh etat         # cluster, Argo CD, versions servies, alertes
bash scripts/demo.sh securite     # PSA, non-root, NetworkPolicy, SealedSecret
bash scripts/demo.sh derive       # modification manuelle annulée par Argo CD
bash scripts/demo.sh historique   # historique GitOps et pipelines
bash scripts/demo.sh panne --oui  # panne contrôlée via Git → alertes → git revert
bash scripts/demo.sh acces        # accès Argo CD et Grafana
```

Accès navigateur : ajouter `127.0.0.1 dev.plateforme.local plateforme.local` à `/etc/hosts`.

## Exploitation (règles GitOps)

- On ne modifie **jamais** le cluster à la main : tout changement passe par Git (Argo CD annule le reste).
- Déployer en prod : `gh workflow run promote.yml` (même image, déjà scannée, que celle validée en dev).
- Revenir en arrière : `git revert <commit chore(gitops)…>` puis `git push`.
- Ne pas relancer un ancien pipeline après un déploiement plus récent : son commit GitOps ferait
  revenir dev à une image plus ancienne.

## Structure du dépôt

```
app/                 API FastAPI, frontend Nginx, tests, Dockerfiles, docker-compose
infra/terraform/     local (socle k8s) et aws (VPC, SG, EC2 — non appliqué)
infra/ansible/       rôles common, ssh_hardening, firewall, k3s
k8s/helm/plateforme/ chart de l'application (+ ServiceMonitor, PrometheusRule, SealedSecret)
k8s/environments/    état désiré GitOps par environnement
k8s/argocd/          application racine, AppProject, valeurs Argo CD / Sealed Secrets
monitoring/          kube-prometheus-stack, tableau de bord Grafana
.github/workflows/   ci.yml (pipeline DevSecOps), promote.yml (dev → prod)
scripts/             install.sh, gitops-bootstrap.sh, demo.sh
docs/                apprentissage, mesures, sécurité, architecture, rapport, présentation
```

## Sécurité

Politique, exceptions justifiées et datées, limites : [`docs/securite.md`](docs/securite.md).
Aucun secret en clair dans le dépôt (Gitleaks sur tout l'historique à chaque push et chaque semaine).

## Limites connues

Nœud unique (pas de haute disponibilité réelle), pas de TLS sur l'Ingress local, pas de canal de
notification externe pour les alertes, état GitOps dans le dépôt applicatif (protection de branche
incompatible avec le push de la CI). Pistes : EKS + Karpenter, cert-manager, Vault / External Secrets,
dépôt GitOps séparé, signature d'images (cosign).

## Documentation

| Document | Contenu |
|---|---|
| [`docs/apprentissage.md`](docs/apprentissage.md) | Concepts, incidents analysés, questions d'entretien avec réponses |
| [`docs/mesures.md`](docs/mesures.md) | Toutes les mesures (méthode, environnement, limites) |
| [`docs/securite.md`](docs/securite.md) | Politique de sécurité et exceptions |
| [`docs/architecture/`](docs/architecture/README.md) | Diagrammes et vues d'architecture |
| [`infra/README.md`](infra/README.md) | Procédures Terraform / Ansible (dont AWS) |

---
Projet personnel réalisé par Ghassen KAHIA (élève ingénieur en Cloud Computing).
