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

## Mesures à réaliser (phases suivantes)

| Indicateur | Phase | Statut |
|---|---|---|
| Résultats des tests automatisés | 1, 5 | Phase 1 mesurée (M2) ; CI à mesurer |
| Vulnérabilités avant/après correction, par sévérité | 2 | à mesurer |
| Temps de déploiement manuel (Helm) | 4 | à mesurer |
| Consommation CPU/RAM du cluster | 4, 6, 7 | à mesurer |
| Durée du pipeline CI | 5 | à mesurer |
| Délai entre le push et la nouvelle version disponible | 6 | à mesurer |
| Temps de rollback (GitOps et Deployment) | 6 | à mesurer |
| Temps de détection d'une panne | 7 | à mesurer |
