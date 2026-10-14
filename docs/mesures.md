# Indicateurs et mesures

Règle : chaque chiffre provient d'une mesure réelle, avec sa méthode, son environnement, sa date et
ses limites. Aucune valeur estimée ne figure dans les tableaux de résultats.

## Environnement de mesure

| Élément | Valeur |
|---|---|
| Hôte | VM VMware, Ubuntu 24.04.5 LTS, noyau 7.0.0-38-generic |
| CPU | 2 vCPU (Intel i5-11400H) |
| RAM | 11 GiB + 3,8 GiB swap |
| Disque | 79 Go (SSD hôte, virtualisé) |

## M0 — Ressources de référence (avant installation)

- **Date** : 2026-10-14
- **Méthode** : `free -h`, `df -h /`, `nproc` après démarrage normal de la VM, avec la session GNOME ouverte.
- **Résultat observé** :

| Mesure | Valeur |
|---|---|
| RAM utilisée | 2,2 GiB |
| RAM disponible | 8,8 GiB |
| Swap utilisé | 0 |
| Disque utilisé / libre | 33 Go / 42 Go |

- **Limites** : mesure ponctuelle. La consommation du bureau GNOME varie selon les applications ouvertes.

## M1 — Installation des prérequis (Phase 0)

- **Date** : 2026-10-14
- **Méthode** : `time` autour de `sudo bash scripts/install.sh base`, puis `free -h` et `df -h /`.
- **Résultat observé** :

| Mesure | Valeur |
|---|---|
| Durée de l'installation (Docker, Compose, venv, make) | 49 s |
| RAM utilisée après installation (démon Docker inactif) | 2,4 GiB (+0,2 GiB) |
| Disque utilisé après installation | 34 Go (+≈1 Go, arrondi de `df`) |
| Versions | Docker 29.9.0, Compose v5.6.0, Buildx 0.38.0, containerd 2.4.2 |

- **Limites** : la durée dépend de la bande passante et du cache APT ; la précision de `df -h` est de l'ordre du Go.

## M2 — Application locale (Phase 1)

- **Date** : 2026-10-14
- **Environnement** : Docker Compose sur la VM (2 vCPU, 11 GiB), images de la version initiale
  (non durcies).
- **Méthodes et résultats observés** :

| Mesure | Méthode | Résultat |
|---|---|---|
| Lint | `ruff check` + `ruff format --check` | 0 erreur (après corrections, voir apprentissage.md) |
| Tests unitaires | `pytest -q` | 16 réussis, 0 échec (intégration : skipped sans base) |
| Tests complets | `RUN_INTEGRATION=1 pytest --cov=api` (avant ajout du test 503) | 19 réussis, 0 échec |
| Couverture | `pytest-cov` | 98 % (5 lignes non couvertes : gestionnaire 503, couvert ensuite par un test dédié) |
| Premier `docker compose up -d --build` (pull des images de base inclus) | `date +%s` avant/après | 122 s |
| Mémoire au repos | `docker stats --no-stream` | API 44 MiB, PostgreSQL 28 MiB, Nginx 3,6 MiB |
| Taille des images (version initiale) | `docker images` | API **1,69 GB**, frontend **240 MB**, postgres 433 MB |
| Utilisateur des conteneurs | `docker exec … id` / `Config.User` | **root** (API et frontend) |
| Retour à la normale après arrêt de PostgreSQL | boucle `curl /ready` toutes les 1 s | ≈ 1 s après `docker compose start db` |

- **Limites** : la durée de build dépend du réseau (téléchargement des images de base) ; la mémoire est
  mesurée au repos, pas sous charge ; les tailles sont celles affichées par Docker 29 (stockage
  containerd), à comparer uniquement entre elles.

## M3 — Vulnérabilités avant/après durcissement (Phase 2)

- **Date** : 2026-10-14
- **Outil** : Trivy 0.76.0, base de vulnérabilités téléchargée le jour même.
- **Méthode** : `trivy image --format json` (toutes sévérités, correctifs ou non), puis comptage avec `jq`
  par sévérité. Le contrôle bloquant utilise `trivy.yaml` (HIGH/CRITICAL, `ignore-unfixed`).

| Image | CRITICAL | HIGH | MEDIUM | LOW | UNKNOWN | Total | HIGH+CRIT sans correctif | Taille | Utilisateur |
|---|---|---|---|---|---|---|---|---|---|
| API avant (`python:3.12.15`) | 16 | 313 | 1 584 | 1 633 | 149 | 3 695 | 317 | 1,69 GB | root |
| API après (slim, multi-stage) | **0** | **44** | 58 | 61 | 3 | **166** | 44 | **221 MB** | 10001 |
| Frontend avant (`nginx:1.30.5`) | 1 | 67 | 108 | 132 | 93 | 401 | 64 | 240 MB | root |
| Frontend après (unprivileged-alpine) | **0** | **0** | 1 | 0 | 0 | **1** | 0 | **90,1 MB** | 101 |

| Contrôle bloquant (`trivy image --config trivy.yaml`) | Code retour |
|---|---|
| `plateforme-api:dev` (durcie) | 0 (réussi) |
| `plateforme-frontend:dev` (durcie) | 0 (réussi) |
| `python:3.12.15` (contrôle négatif) | **1 (bloqué : 12 HIGH corrigeables)** |

| Mauvaises configurations Dockerfile (`trivy config app/`) | Avant | Après |
|---|---|---|
| DS-0002 (HIGH, utilisateur root) | 2 | 0 |
| DS-0026 (LOW, pas de HEALTHCHECK) | 2 | 0 |

| Autre mesure | Résultat |
|---|---|
| Rebuild des 2 images durcies (images de base à télécharger) | 26 s |
| Mémoire au repos après durcissement | API 54 MiB, Nginx 3,5 MiB, PostgreSQL 33 MiB |
| Tests complets contre la stack durcie | 20 réussis, 0 échec |
| Cache Trivy après nettoyage | 1,6 GB (base de vulnérabilités) |

- **Limites** : les chiffres dépendent de la date de la base de vulnérabilités (une même image
  scannée plus tard peut avoir plus ou moins de CVE). Les « 12 HIGH » du contrôle négatif sont
  comptés après le filtre `ignore-unfixed`. La taille est celle affichée par Docker 29.

## M4 — Validation de l'Infrastructure as Code (Phase 3)

- **Date** : 2026-10-14 — Terraform 1.16.6, provider AWS 6.68.0, provider Kubernetes 3.3.0,
  ansible-core 2.16.3, ansible-lint 6.17.2, Trivy 0.76.0.

| Contrôle | Commande | Résultat |
|---|---|---|
| Format Terraform | `terraform fmt -recursive -check` | 0 fichier à reformater |
| Validation AWS | `terraform validate` | Success |
| Validation local | `terraform validate` | Success |
| Scan IaC, toutes sévérités | `trivy config infra/` | 1 LOW (AWS-0017, risque accepté) |
| Scan IaC, contrôle bloquant | `trivy config --config trivy.yaml infra/` | code retour 0 |
| Scan sans exceptions (contrôle) | copie sans `trivy:ignore` | 2 CRITICAL (AWS-0104), toutes deux couvertes par une exception justifiée |
| Syntaxe Ansible | `ansible-playbook --syntax-check` | OK |
| Lint Ansible | `ansible-lint` (profil production) | 0 échec, 0 avertissement, 24 fichiers |
| Exécution à blanc | `ansible-playbook site.yml --check` | ok=18, changed=11, failed=0 (après correction d'un bug du mode check) |

- **Limites** : la validation statique ne prouve pas que `terraform apply` réussirait sur AWS
  (quotas, disponibilité des AMI, permissions IAM). Le mode `--check` d'Ansible ne simule pas les
  tâches `command` (installation de k3s), qui seront validées par l'exécution réelle en Phase 4.

## M5 — Kubernetes : installation, déploiement manuel, résilience (Phase 4)

- **Date** : 2026-10-14 — k3s v1.36.5+k3s1, Helm 4.3.0, VM 2 vCPU / 11 GiB.

### Installation et socle

| Mesure | Méthode | Résultat |
|---|---|---|
| Installation k3s + durcissement hôte (1er passage Ansible) | `date +%s` autour d'`ansible-playbook` | 66 s, ok=21 changed=12 failed=0 |
| Idempotence Ansible (après correctifs) | 3e passage | changed=0 |
| Socle Terraform local | `terraform apply` puis `plan -detailed-exitcode` | 8 ressources créées ; 2e plan : 0 changement |

### Déploiement manuel (protocole : commandes enchaînées, horodatage `date +%s.%N` entre étapes)

| Étape | dev (1er déploiement, image PostgreSQL à télécharger) | prod (images présentes) |
|---|---|---|
| Build des 2 images | 16,0 s | — |
| Import dans containerd de k3s | 4,0 s | — |
| Création du Secret | 0,1 s | < 1 s |
| `helm upgrade --install --wait` | 64,0 s | 13,8 s |
| **Total** | **84,1 s** | **13,8 s** (hors build/import) |

Limite : mesure d'un opérateur qui connaît déjà les commandes, sans compter le temps de saisie ni les
erreurs humaines (qui sont justement le risque du déploiement manuel).

### Résilience et rollback

| Scénario | Résultat observé |
|---|---|
| Arrêt de PostgreSQL : délai avant retrait de l'API du Service (readiness) | 8 s |
| Arrêt de PostgreSQL : redémarrages de l'API pendant 25 s (liveness) | 0 |
| Retour de PostgreSQL → API de nouveau Ready | 5 s (+ < 1 s de propagation des endpoints) |
| Release défectueuse (image inexistante) : détection de l'échec par `helm --wait` | 45–46 s (= timeout configuré) |
| Rollback Helm (`helm rollback --wait`) | 0,6 s à 2,5 s (4 mesures) |
| Erreurs utilisateur pendant release défectueuse + rollback, **avant** correctif du chart | 10 × 502 sur 99 requêtes |
| Idem **après** correctif, depuis un état stable (2 essais) | **0 erreur** sur 365 requêtes |

### Sécurité vérifiée

| Contrôle | Résultat |
|---|---|
| Pod non conforme dans un namespace `restricted` (`--dry-run=server`) | Refusé, 4 violations listées |
| UID des conteneurs | API 10001, frontend 10101, PostgreSQL 10070 |
| Jeton de ServiceAccount monté | Aucun (3/3 pods) |
| Rootfs en lecture seule | 3/3 pods |
| Matrice NetworkPolicy (7 flux) | 7/7 conformes |
| Contrôle positif NetworkPolicy | Autre namespace → db : AUTORISÉ sans policy, BLOQUÉ avec |
| Trivy sur le chart (avant → après) | 3 LOW KSV-0110 + 4 LOW KSV-0020/21 + 1 MEDIUM (faux positif) → 0 (1 exception datée) |

### Autoscaling et quotas

| Mesure | Résultat |
|---|---|
| HPA : charge 24 clients en parallèle pendant 180 s via l'Ingress | 2 → 4 répliques en ≈ 34 s (CPU max 310 % des requests) |
| CPU à 4 répliques (nœud saturé) | ≈ 165–169 % des requests |
| Retour à 2 répliques après la charge | 121 s (fenêtre de stabilisation 120 s) |
| ResourceQuota dev : 20 répliques demandées | 2 créées (limite `limits.cpu` = 2) |

### Consommation (au repos, 2 environnements + système k3s)

| Mesure | Valeur |
|---|---|
| Nœud (`kubectl top node`) | 197m CPU (9 %), 3 838 Mi |
| RAM VM (`free -h`) | 3,9 Gi utilisés, 7,1 Gi disponibles |
| Pod API / frontend / PostgreSQL | ≈ 50 Mi / 3 Mi / 27–70 Mi |

- **Limites** : un seul nœud (pas de test de perte de nœud) ; charge générée depuis la VM elle-même
  (le générateur consomme aussi du CPU) ; mesures ponctuelles, non moyennées sur plusieurs runs.

## M6 — Contrôles de sécurité du pipeline, répétition locale (Phase 5)

- **Date** : 2026-10-14 — Gitleaks 8.30.1, Semgrep 1.178.0, Trivy 0.74.0, actionlint 1.7.12.

| Contrôle | Résultat sur le dépôt | Contrôle positif (doit bloquer) |
|---|---|---|
| Gitleaks (historique, 5 commits) | 0 fuite | Clé factice commitée : **bloqué** (code 1) ; après suppression : **toujours bloqué** |
| Gitleaks (répertoire de travail) | 5 détections, toutes dans des fichiers ignorés par Git : `.env` (vrai positif, protégé par .gitignore), rapports Trivy (faux positifs) | — |
| Semgrep (72 fichiers) | 0 constat, 0 erreur, 4 s | Fichier vulnérable : 4 lignes sur 5 détectées (yaml.load manqué) |
| Trivy fs (SCA) | 0 vulnérabilité | `pyyaml==5.3.1` : **bloqué** (CVE-2020-14343 CRITICAL) |
| actionlint + shellcheck | 2 workflows valides | — |
| ansible-lint 26.9.0 (version CI) | 0 échec (profil production) | — |

- **Limites** : répétition locale ; le comportement réel dans GitHub Actions (durées, blocage effectif
  d'une PR) sera mesuré après la publication du dépôt.

## M7 — Pipeline CI réel sur GitHub Actions (Phase 5)

- **Date** : 2026-10-14 — runners `ubuntu-24.04` hébergés par GitHub, dépôt public.
- **Méthode** : `gh run view --json createdAt,updatedAt,jobs` (durées calculées par GitHub).

| Run | Événement | Résultat | Durée totale |
|---|---|---|---|
| 38599334789 | push main (premier pipeline, cache vide) | succès, 7/7 jobs | **141 s** |
| 38600037068 | push main (correctif Gitleaks) | succès, 7/7 jobs | **143 s** |
| 38599765397 / 38600455805 | PR #1 secret factice | **échec : Gitleaks** ; image et GitOps sautés | — |
| 38600053198 | PR #2 pyyaml 5.3.1 | **échec : Trivy fs** (CVE-2020-14343) ; image et GitOps sautés | — |

Durées des jobs du premier run : Gitleaks 9 s, Semgrep 25 s, lint/tests 40 s, IaC 41 s,
image frontend 56 s, image API 81 s, mise à jour GitOps 6 s.

**Délai push → nouvel état désiré dans Git** : ≈ 141 s (fin du job update-gitops). Le délai jusqu'à
la disponibilité dans le cluster sera mesuré avec Argo CD (Phase 6).

- **Limites** : 2 runs seulement ; les durées varient selon la charge des runners GitHub et l'état du
  cache (pip, couches Docker `type=gha`).

## M8 — GitOps : déploiement, dérive, rollback (Phase 6)

- **Date** : 2026-10-14 — Argo CD v3.5.4 (chart 10.9.7), Sealed Secrets 0.40.0, réconciliation Git 60 s.
- **Méthode** : sonde HTTP horodatée toutes les 0,3 s sur `/api/version` via l'Ingress, pendant toute
  l'opération ; délais mesurés avec `date +%s` entre le `git push` (ou le déclenchement) et la première
  réponse de la nouvelle version.

| Scénario | Délai | Requêtes / erreurs |
|---|---|---|
| Amorçage (Sealed Secrets + Argo CD + app racine) | 54 s, puis applications Synced/Healthy ≈ 30 s | — |
| Reprise des releases Helm par Argo CD — prod (sans changement) | — | 169 / **0** |
| Reprise — dev (passage à l'image GHCR, **avant preStop**) | — | 163 / **3** (2 × 502, 1 timeout) |
| **Push du code → nouvelle version servie en dev** (CI 145 s comprise) | **189 s** | — |
| Push d'une configuration (LOG_LEVEL) → active en dev (sans CI) | **49 s** | 939 / **0** |
| Rollback GitOps (`git revert` du commit d'image) → ancienne version servie | **89 s** | 1 460 / **0** |
| Promotion prod (`promote.yml`) → nouvelle version servie en prod | **84 s** | 938 / **0** |
| Dérive : `kubectl scale` | corrigée en 1,7 s | — |
| Dérive : NetworkPolicy supprimée | corrigée en 2,0 s | — |
| Dérive : ConfigMap modifiée | corrigée en 6,1 s | — |

**Comparaison avec le déploiement manuel (M5)** : 84 s de commandes enchaînées par un opérateur, sans
tests ni scans, contre 189 s de bout en bout **sans intervention**, avec lint, tests, Gitleaks, Semgrep,
Trivy (×3), SBOM, publication et traçabilité Git.

| Consommation avec Argo CD et Sealed Secrets | Valeur |
|---|---|
| Nœud (`kubectl top node`) | 255m CPU (12 %), 4 786 Mi |
| Argo CD (4 pods) | ≈ 241 Mi (contrôleur 168 Mi) |
| Contrôleur Sealed Secrets | 33 Mi |
| RAM VM disponible | 6,3 Gi |
| Disque utilisé | 43 Go / 79 Go |

- **Limites** : le délai de détection par Argo CD dépend de la phase du cycle de 60 s au moment du
  push (une mesure peut varier de 0 à 60 s) ; une seule mesure par scénario ; pas de webhook (VM non
  joignable depuis GitHub).

## Mesures à réaliser (phases suivantes)

| Indicateur | Phase | Statut |
|---|---|---|
| Résultats des tests automatisés | 1, 5 | Phase 1 mesurée (M2) ; CI à mesurer |
| Vulnérabilités avant/après correction, par sévérité | 2 | mesuré (M3) |
| Temps de déploiement manuel (Helm) | 4 | mesuré (M5) |
| Consommation CPU/RAM du cluster | 4, 6, 7 | Phase 4 mesurée (M5) |
| Durée du pipeline CI | 5 | mesuré (M7) |
| Délai entre le push et la nouvelle version disponible | 6 | mesuré (M8) : 189 s |
| Temps de rollback (GitOps et Deployment) | 6 | mesuré (M5, M8) |
| Temps de détection d'une panne | 7 | à mesurer |
