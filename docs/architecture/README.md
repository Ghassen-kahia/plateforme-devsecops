# Architecture

Deux vues : la **chaîne DevSecOps** (du commit au cluster) et l'**exécution dans k3s**.
Sources Mermaid : `*.mmd` (rendues nativement par GitHub ci-dessous). Exports PNG régénérables avec :

```bash
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD/docs/architecture:/data" minlag/mermaid-cli:11.17.1 \
  -i /data/chaine-devsecops.mmd -o /data/chaine-devsecops.png -b white -s 2
```

## 1. Chaîne DevSecOps

![Chaîne DevSecOps](chaine-devsecops.png)

```mermaid
flowchart LR
  dev([Développeur]) -->|git push| gh[(GitHub<br/>plateforme-devsecops)]

  subgraph CI["GitHub Actions — CI DevSecOps"]
    direction TB
    lint[Lint + tests<br/>ruff, pytest, PostgreSQL]
    gl[Gitleaks<br/>secrets]
    sg[Semgrep<br/>SAST]
    iac[Trivy config + SCA<br/>terraform, helm, ansible-lint]
    build[Build image<br/>multi-stage, non-root]
    tri[Trivy image<br/>HIGH/CRITICAL bloquants]
    push[Publication GHCR<br/>tag sha-12]
    gitops[Commit GitOps<br/>k8s/environments/dev]
    lint & gl & sg & iac --> build --> tri --> push --> gitops
  end

  gh --> CI
  push --> ghcr[(GHCR<br/>images publiques)]
  gitops --> gh
  promote[promote.yml<br/>manuel] -->|tag validé| gh

  subgraph K3S["k3s — VM Ubuntu (Ansible, Terraform local)"]
    direction TB
    argo[Argo CD<br/>sync auto + self-heal]
    ss[Sealed Secrets]
    devns[plateforme-dev]
    prodns[plateforme-prod]
    mon[Prometheus + Alertmanager<br/>+ Grafana]
    argo --> devns & prodns
    ss -.secrets déchiffrés.-> devns & prodns
    mon -.collecte /metrics.-> devns & prodns
  end

  gh -->|pull toutes les 60 s| argo
  ghcr -->|pull images| devns & prodns
```

| Étape | Outil | Bloquant | Preuve |
|---|---|---|---|
| Qualité | ruff, pytest (+ PostgreSQL de service) | oui | 20 tests, couverture ≥ 90 % |
| Secrets | Gitleaks (historique) | oui | PR #1 bloquée |
| SAST | Semgrep (python, bandit, security-audit…) | oui | contrôle positif |
| IaC + SCA | Trivy config/fs, terraform validate, helm lint, ansible-lint | oui | PR #2 bloquée (CVE-2020-14343) |
| Image | build multi-stage → Trivy image | oui (HIGH/CRITICAL corrigeables) | image naïve bloquée |
| Publication | GHCR, tag `sha-<12>` | — | images publiques |
| Déploiement | commit GitOps → Argo CD (pull) | — | push → dev en 189 s |

## 2. Exécution dans k3s

![Exécution dans k3s](execution-k3s.png)

```mermaid
flowchart TB
  user([Utilisateur]) -->|HTTP dev.plateforme.local / plateforme.local| traefik

  subgraph KS["kube-system"]
    traefik[Traefik<br/>Ingress]
    sscontroller[Contrôleur Sealed Secrets]
  end

  subgraph NS["plateforme-prod — PSA restricted, ResourceQuota, NetworkPolicy deny-all"]
    fe[Frontend Nginx<br/>2 répliques, UID 10101]
    api[API FastAPI<br/>HPA 2→4, UID 10001]
    db[(PostgreSQL 18<br/>StatefulSet + PVC, UID 10070)]
    sec[[Secret plateforme-db<br/>issu d'un SealedSecret]]
    fe -->|/api| api -->|5432| db
    sec -.-> api & db
  end

  traefik -->|8080| fe

  subgraph MON["monitoring — PSA privileged"]
    prom[Prometheus]
    am[Alertmanager]
    graf[Grafana]
    prom --> am
    graf --> prom
  end

  prom -.ServiceMonitor 15 s.-> api
  prom -.PodMonitor 15 s.-> traefik
  sscontroller -.déchiffre.-> sec

  subgraph AR["argocd — PSA baseline"]
    argocd[Argo CD<br/>AppProject restreint]
  end
  argocd -->|applique l'état désiré| NS
```

## 3. Couches de sécurité (défense en profondeur)

| Couche | Mesures |
|---|---|
| Code | SAST, revue, tests (dont injection SQL), SecretStr |
| Dépendances | versions figées, SCA Trivy, ≥ 2 semaines de recul (sauf correctif de sécurité) |
| Image | slim/distroless-like, non-root UID > 10000, sans pip, scan bloquant, SBOM |
| Chaîne CI | permissions `{}`, actions épinglées par SHA, jetons éphémères, CI sans accès au cluster |
| Cluster | PSA restricted, securityContext, sans jeton SA, NetworkPolicy deny-all, quotas |
| Secrets | Sealed Secrets (portée strict), chiffrement au repos k3s |
| Déploiement | GitOps, AppProject restreint, self-heal (dérive corrigée en 2 s) |
| Hôte | UFW, sysctl CIS, k3s durci (audit, secrets chiffrés, protect-kernel-defaults) |
| Détection | Prometheus + 4 alertes, détection d'une panne en 63–94 s |

## 4. Environnements

| | dev | prod |
|---|---|---|
| Mise à jour | automatique à chaque commit sur main | manuelle (`promote.yml`) |
| API | 1 réplique | HPA 2 → 4 |
| Frontend | 1 | 2 |
| Accès | http://dev.plateforme.local | http://plateforme.local |
| État désiré | `k8s/environments/dev/values.yaml` | `k8s/environments/prod/values.yaml` |

## 5. Limites connues

- Nœud unique : pas de haute disponibilité réelle (perte de la VM = perte du service).
- 2 vCPU : ≈ 70 % du CPU consommé au repos par la plateforme complète ; 4 vCPU recommandés.
- Pas de TLS sur l'Ingress local, pas de canal de notification externe pour les alertes.
- État GitOps dans le dépôt applicatif : `main` ne peut pas exiger les checks (push direct de la CI).
