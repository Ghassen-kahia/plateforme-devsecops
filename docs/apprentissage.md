# Journal d'apprentissage

Ce que j'ai appris, phase par phase : concepts, commandes, erreurs et questions d'entretien.

---

## Phase 0 — Audit et préparation de l'environnement

### Pourquoi auditer avant d'installer ?

Une plateforme Kubernetes complète (k3s, Argo CD, Prometheus, Grafana) consomme beaucoup de ressources.
Sans audit, on risque des pods `Pending`, des `OOMKilled` ou une VM qui rame, et on perd du temps à
déboguer un problème de capacité plutôt qu'un problème de configuration.
L'audit sert aussi à repérer les **conflits** : un port déjà pris, un pare-feu actif, un service existant.

### Commandes d'audit utiles

| Commande | Ce qu'elle montre |
|---|---|
| `cat /etc/os-release` | Distribution et version |
| `nproc`, `lscpu` | Nombre de CPU, hyperviseur |
| `free -h` | RAM et swap (regarder la colonne `available`, pas `free`) |
| `df -h /` | Espace disque |
| `stat -fc %T /sys/fs/cgroup` | `cgroup2fs` = cgroups v2, requis par les runtimes modernes |
| `ss -tulnp` | Ports en écoute (TCP/UDP) |
| `systemctl list-units --type=service --state=running` | Services actifs |
| `systemctl is-active ufw` | État du pare-feu |
| `sudo -n true` | Teste si sudo est utilisable sans mot de passe |

> `free` vs `available` : Linux utilise la RAM libre comme cache disque (`buff/cache`).
> `available` estime ce qui est réellement récupérable par les applications.

### Constats de l'audit (2026-10-14)

- 2 vCPU : c'est la contrainte principale. 11 GiB de RAM suffisent.
- UFW est **inactif** : `systemctl is-active ufw` répond `active`, mais `sudo ufw status` répond `inactive`.
  Le service systemd ne fait que charger les règles au démarrage ; c'est `ufw status` qui fait foi.
  Ansible l'activera en Phase 3 avec les règles k3s (pods 10.42.0.0/16, services 10.43.0.0/16).
- `sudo` demande un mot de passe : bonne pratique de sécurité, donc les installations système passent
  par un script relu puis exécuté manuellement.

### Concept : Docker contourne UFW

UFW est une surcouche d'iptables. Docker insère ses propres chaînes (`DOCKER`, `DOCKER-USER`) **avant**
celles d'UFW pour le trafic routé vers les conteneurs. Résultat : `docker run -p 8080:80` rend le port
8080 accessible depuis le réseau même si UFW le refuse.

Solutions : publier sur `127.0.0.1:8080:80` (retenu), utiliser la chaîne `DOCKER-USER`, ou ne pas
publier de ports et passer par un reverse proxy.

### Concept : groupe `docker` = root

Tout membre du groupe `docker` peut lancer `docker run -v /:/host ...` et donc lire ou modifier tout le
système. C'est acceptable sur une VM de développement personnelle, pas sur un serveur partagé.
Alternatives : Docker **rootless**, ou Podman, qui est rootless par défaut.

### Concept : pourquoi Docker par APT plutôt que snap ?

Le snap Docker est confiné : l'accès aux répertoires hors de `$HOME` est limité et les mises à jour
automatiques ne sont pas maîtrisées. Le dépôt APT officiel de Docker est la méthode documentée par Docker,
avec une signature GPG vérifiée (`signed-by=`).

### Concept : installation « juste-à-temps »

Chaque outil est installé dans la phase qui l'utilise. On évite ainsi d'installer des outils jamais
utilisés, et chaque installation est immédiatement suivie d'un usage vérifiable.

### Questions d'entretien — Phase 0

1. **Pourquoi k3s plutôt que minikube ou kind ?**
   k3s est une distribution Kubernetes certifiée CNCF, en un seul binaire, conçue pour les ressources
   limitées. Elle inclut Traefik (Ingress), local-path (stockage), CoreDNS et metrics-server.
   kind et minikube servent surtout aux tests éphémères. k3s se rapproche davantage d'un vrai nœud
   (service systemd, utilisable en production edge).
2. **Votre VM n'a que 2 vCPU : comment faites-vous tourner toute la stack ?**
   Je définis des requests/limits sur chaque composant, je limite la rétention de Prometheus, je désactive
   les composants inutiles et je procède par étapes en mesurant la consommation à chaque phase.
3. **Un port Docker est accessible alors qu'UFW le bloque, pourquoi ?**
   Voir « Docker contourne UFW » ci-dessus.

### Erreurs rencontrées

| Erreur | Cause | Solution |
|---|---|---|
| `sudo: a password is required` (exécution non interactive) | sudo protégé par mot de passe, pas de TTY pour l'agent | L'utilisateur a ajouté une règle sudoers NOPASSWD dédiée (à retirer en fin de projet) |
| Diagnostic UFW erroné (« actif ») | `systemctl is-active` teste le service, pas le filtrage | Toujours vérifier avec `sudo ufw status verbose` |
| (Anticipé, non rencontré) accès à `docker.sock` refusé juste après l'installation | L'appartenance au groupe n'est prise en compte qu'à la prochaine connexion | `sg docker -c "..."` ou `newgrp docker` dans la session courante |

### Vérification de l'installation Docker

```bash
docker run --rm hello-world      # le client, le démon, le pull depuis le registre et le runtime fonctionnent
docker compose version           # Docker Compose version v5.6.0
docker info --format '{{.CgroupVersion}} {{.CgroupDriver}}'   # 2 systemd
```

`hello-world` valide toute la chaîne : le CLI parle au démon via `/var/run/docker.sock`, le démon
télécharge l'image depuis Docker Hub, puis containerd/runc créent et exécutent le conteneur.

4. **Quelle différence entre Docker Engine, containerd et runc ?**
   runc est le runtime bas niveau (OCI) qui crée réellement le processus isolé (namespaces, cgroups).
   containerd gère le cycle de vie des conteneurs et des images. Docker Engine (dockerd) ajoute l'API,
   le build, les réseaux, les volumes et Compose. Kubernetes (dont k3s) parle directement à containerd via
   la CRI, sans Docker, ce qui explique pourquoi « Kubernetes a abandonné Docker » (dockershim) sans que
   les images Docker cessent de fonctionner : ce sont des images OCI standard.
5. **Comment avez-vous vérifié l'état du pare-feu, et quel piège avez-vous rencontré ?**
   Voir le tableau des erreurs : `systemctl is-active` ≠ `ufw status`. C'est une leçon de diagnostic :
   vérifier l'effet réel (le filtrage) plutôt que l'indicateur indirect (le service).

---

## Phase 1 — Application de démonstration

### Architecture applicative

```
Navigateur ──► Nginx :8080 ──(/api/*, /ready)──► FastAPI :8000 ──► PostgreSQL :5432
               (fichiers statiques)               (/health, /metrics non exposés par Nginx)
```

- **Nginx relaie `/api`** : le navigateur ne voit qu'une seule origine, donc pas de CORS à configurer.
  `/metrics` n'est pas relayé : les métriques ne sont pas publiques, Prometheus les collectera
  directement sur le Service Kubernetes de l'API.
- **Configuration par variables d'environnement (12-factor)** : la même image tourne en dev, en CI et sur k3s.
  `pydantic-settings` valide les types, et `SecretStr` empêche le mot de passe d'apparaître dans un `repr()` ou un log.

### Concept clé : liveness ≠ readiness

| Sonde | Question posée | Endpoint | Si échec dans Kubernetes |
|---|---|---|---|
| Liveness | « Le processus est-il bloqué ? » | `/health` | Le conteneur est **redémarré** |
| Readiness | « Puis-je recevoir du trafic ? » | `/ready` (teste la base) | Le pod est **retiré du Service**, sans redémarrage |

**Erreur classique** : mettre la vérification de la base dans la liveness. Si PostgreSQL tombe, tous les
pods de l'API redémarrent en boucle (CrashLoopBackOff) alors qu'ils ne sont pas en cause, ce qui
aggrave l'incident. Test réalisé : base arrêtée → `/health` 200, `/ready` 503, `/api/tasks` 503 ;
base redémarrée → retour à 200 en environ 1 s, sans redémarrer l'API.

### Concept clé : cardinalité des métriques

Chaque combinaison de labels Prometheus forme une série temporelle stockée en mémoire. Avec le label
`route="/api/tasks/42"`, chaque identifiant créerait une nouvelle série. On utilise donc le **modèle**
de route (`/api/tasks/{task_id}`). Un test unitaire vérifie ce comportement.

Méthode **RED** pour un service : **R**ate (débit), **E**rrors (taux d'erreurs 5xx), **D**uration
(latence, via un histogramme qui permet de calculer des percentiles avec `histogram_quantile`).

### Concept clé : pattern repository et pyramide de tests

- **Tests unitaires** (16) : dépôt en mémoire, rapides (< 1 s), sans dépendance externe. Ils vérifient
  la logique HTTP : validation, codes de retour, 404, 503, métriques, masquage des secrets.
- **Tests d'intégration** (4) : vrai PostgreSQL. Ils vérifient le SQL, la persistance et la résistance à
  l'injection SQL. Sans base, ils sont marqués **SKIPPED** et jamais comptés comme réussis.

### Sécurité applicative intégrée dès cette phase

| Mesure | Menace couverte |
|---|---|
| Requêtes SQL paramétrées (`%s`) | Injection SQL (testée avec `'); DROP TABLE tasks; --`) |
| `textContent` au lieu de `innerHTML` côté JS | XSS |
| En-têtes CSP, `X-Frame-Options`, `nosniff`, `server_tokens off` | XSS, clickjacking, divulgation de version |
| Message 503 générique, détail uniquement dans les logs | Fuite d'informations internes |
| `${POSTGRES_PASSWORD:?}` dans Compose | Démarrage accidentel avec un mot de passe vide |
| Ports publiés sur 127.0.0.1 | Exposition réseau (Docker contourne UFW) |
| Ruff avec règles `S` (bandit) | Mauvaises pratiques de sécurité dans le code Python |

### Commandes utiles

```bash
cd app
../.venv/bin/ruff check . && ../.venv/bin/ruff format --check .      # lint et format
../.venv/bin/pytest -q                                               # tests unitaires
docker compose --env-file ../.env up -d --build                      # démarrer la stack
set -a; . ../.env; set +a                                            # charger .env sans l'afficher
DB_PASSWORD="$POSTGRES_PASSWORD" RUN_INTEGRATION=1 ../.venv/bin/pytest --cov=api   # tous les tests
curl -s localhost:8000/metrics | grep ^http_requests_total           # métriques
```

### Erreurs rencontrées — Phase 1

| Erreur | Cause | Solution |
|---|---|---|
| Ruff B008 « function call in argument defaults » (×6) | `Depends()` en valeur par défaut, ancien style FastAPI | Alias `Repo = Annotated[TaskRepository, Depends(get_repo)]` (style recommandé) |
| Ruff I001 sur l'ordre des imports | `api` pris pour un paquet tiers | `known-first-party = ["api"]` |
| Ruff S106 dans un test | Mot de passe **factice** dans le test de masquage | Exception documentée limitée à `tests/**` (S105, S106) |
| Avertissement Starlette « use httpx2 » | Starlette 1.x recommande le successeur de httpx | httpx conservé (paquet éprouvé) ; avertissement filtré et documenté dans `pyproject.toml` |
| `required variable POSTGRES_PASSWORD is missing` | `docker compose logs` lancé sans `--env-file ../.env` | Comportement voulu (garde `:?`) ; toujours passer `--env-file` |

### Questions d'entretien — Phase 1

1. **Pourquoi `/health` ne vérifie-t-il pas la base de données ?**
   Kubernetes redémarre un conteneur dont la liveness échoue. Une panne de base ferait redémarrer en
   boucle tous les pods de l'API sans rien réparer. La dépendance à la base relève de la readiness :
   le pod est retiré du load balancing jusqu'au retour de la base. Je l'ai testé en arrêtant PostgreSQL.
2. **Comment évitez-vous l'injection SQL ?**
   Toutes les requêtes passent des paramètres séparés au driver (`cur.execute("... WHERE id = %s", (id,))`).
   PostgreSQL reçoit la requête et les valeurs séparément, et une valeur ne peut jamais devenir du code SQL.
   Un test d'intégration insère une charge d'injection et vérifie qu'elle est stockée comme du texte.
3. **Pourquoi des tests unitaires ET d'intégration ?**
   Les unitaires sont rapides et isolent la logique : ils détectent vite les régressions. Ils ne
   prouvent cependant pas que le SQL fonctionne réellement. Les tests d'intégration contre un vrai
   PostgreSQL couvrent ce point. En CI, la base sera fournie par un conteneur de service GitHub Actions.
4. **Qu'est-ce que la cardinalité dans Prometheus, et comment l'avez-vous maîtrisée ?**
   Voir le concept ci-dessus : label `route` = modèle de route, et routes inconnues regroupées sous `<non_routé>`.
5. **(Compromis)** **Pourquoi créer le schéma au démarrage plutôt qu'avec Alembic ?**
   Pour une table unique, un `CREATE TABLE IF NOT EXISTS` idempotent suffit et évite un outil de plus.
   La limite : il n'y a ni versionnement ni retour arrière du schéma. En production avec plusieurs
   évolutions, j'utiliserais Alembic, lancé par un Job Kubernetes ou un hook Helm `pre-upgrade`.
6. **(Dépannage)** **L'API répond 503 sur `/api/tasks` : votre démarche ?**
   1) `/health` répond-il ? Si oui, le processus est vivant. 2) `/ready` : la base est-elle joignable ?
   3) Logs de l'API : message psycopg (DNS, refus de connexion, authentification). 4) État de la base :
   `docker compose ps`, `pg_isready`. 5) Métrique `app_database_up` dans Prometheus.

---

## Phase 2 — Conteneurisation sécurisée

### Ce qu'est une vulnérabilité « dans une image »

Une image contient un système de fichiers complet : paquets de l'OS (Debian, Alpine), runtime
(Python) et dépendances applicatives (pip). Trivy lit les bases de paquets (`/var/lib/dpkg/status`,
`*.dist-info`) et compare chaque version installée aux bases de CVE (NVD, avis Debian, GitHub Advisories).
**Conséquence directe : chaque paquet inutile est une surface d'attaque et du bruit dans les rapports.**

### Résultats mesurés (détail dans mesures.md)

| | Avant | Après |
|---|---|---|
| API : CRITICAL / HIGH | 16 / 313 | **0 / 44** (toutes sans correctif) |
| API : total | 3 695 | 166 (−95,5 %) |
| API : taille | 1,69 GB | 221 MB (−87 %) |
| Frontend : CRITICAL / HIGH | 1 / 67 | **0 / 0** |
| Frontend : taille | 240 MB | 90,1 MB |
| Utilisateur | root | 10001 / 101 |

**Constat important** : les dépendances de l'application (FastAPI, psycopg…) n'avaient **aucune**
vulnérabilité. Tout le risque venait de l'image de base, d'où l'intérêt du choix de la base.

### Techniques utilisées

- **Multi-stage build** : l'étape `build` crée un venv avec pip ; l'étape `runtime` ne copie que
  `/opt/venv`. Les outils de construction ne partent pas en production.
- **Image slim** : variante Debian sans compilateurs ni documentation.
  Alpine (musl) a été écartée pour Python : les roues binaires `manylinux` (psycopg) visent la glibc,
  les builds sont plus lents et des différences de comportement apparaissent.
- **Suppression de pip** : un attaquant qui obtient une exécution de code ne peut plus faire `pip install`.
- **UID numérique fixe** (`USER 10001:10001`) : Kubernetes peut vérifier `runAsNonRoot` avec un UID
  numérique, mais pas avec un nom d'utilisateur.
- **Code possédé par root, exécuté par 10001** : le processus ne peut pas modifier son propre code.
- **`.dockerignore` en liste blanche** : sans lui, `COPY . .` peut embarquer `.env`, `.git` ou `.venv`.
  La liste blanche est plus sûre qu'une liste noire, car un nouveau fichier sensible est exclu par défaut.
- **HEALTHCHECK** : utile pour Docker/Compose (statut `healthy`). Kubernetes l'ignore et utilise ses probes.

### Concept : défense en profondeur

Aucune mesure n'est suffisante seule. Image minimale (moins de failles) + non-root (moins de
privilèges en cas d'exploitation) + rootfs en lecture seule (pas de persistance d'un malware) +
`cap_drop: ALL` (pas d'opérations noyau privilégiées) + `no-new-privileges` (pas d'élévation via setuid).

### Commandes utiles

```bash
trivy image --config trivy.yaml plateforme-api:dev            # contrôle bloquant (politique du projet)
trivy image --format json -o reports/x.json plateforme-api:dev # rapport complet (toutes sévérités)
trivy config app/                                             # mauvaises configurations des Dockerfiles
docker exec plateforme-api-1 grep CapEff /proc/1/status       # capacités effectives (0 = aucune)
trivy clean --scan-cache                                      # libérer le cache des couches
docker builder prune -f                                       # libérer le cache de build
```

### Erreurs rencontrées — Phase 2

| Problème | Cause | Solution |
|---|---|---|
| `useradd warning: uid 10001 is greater than SYS_UID_MAX` | `--system` attend un UID < 1000 | Retrait de `--system` (l'UID explicite suffit) |
| Avertissement pip « Running as root » | Désinstallation de pip en root pendant le build | `--root-user-action=ignore` (action voulue) |
| +6 Go de disque utilisés | Cache Trivy (base Java 1,5 Go inutile ici) et cache de build Docker 2,2 Go | `trivy clean --java-db --scan-cache`, `docker builder prune` |
| 44 HIGH restantes sur l'API | Paquets Essential de Debian sans correctif publié | Politique `ignore-unfixed` documentée (docs/securite.md) |

### Perspectives

- **Distroless** (`gcr.io/distroless/python3`) : pas de shell ni de gestionnaire de paquets, ce qui
  supprimerait la plupart des 44 HIGH restantes. Compromis : Python fourni par Debian (3.13 et non
  3.12), débogage via conteneurs éphémères (`kubectl debug`) uniquement.
- Images Chainguard/Wolfi : très peu de CVE, mais les tags versionnés gratuits sont limités.
- Signature (cosign) et SBOM (Syft/Trivy) en CI.

### Questions d'entretien — Phase 2

1. **Quelle différence entre une vulnérabilité « fixed » et « unfixed », et comment les traitez-vous ?**
   « Fixed » signifie que l'éditeur de la distribution a publié une version corrigée : on peut et on
   doit mettre à jour, donc le pipeline bloque. « Unfixed » signifie que la CVE est connue mais qu'aucun
   paquet corrigé n'existe (statut Debian `affected`, `fix_deferred`). Les bloquer rendrait le pipeline
   rouge en permanence, sans action possible. Elles sont tracées, leur exposition est évaluée, et elles
   deviennent bloquantes dès qu'un correctif sort et que l'image n'est pas reconstruite.
2. **Pourquoi l'image API a-t-elle perdu 87 % de sa taille ?**
   L'image `python:3.12` complète contient la toolchain de compilation, les en-têtes de développement
   et de nombreuses bibliothèques (ImageMagick, X11…). `slim` n'en garde que le nécessaire, et le
   multi-stage évite le cache pip et pip lui-même.
3. **Un conteneur non-root suffit-il à le sécuriser ?**
   Non, c'est une couche parmi d'autres. Le noyau est partagé avec l'hôte. Il faut aussi supprimer les
   capacités, interdire l'élévation de privilèges, utiliser un rootfs en lecture seule, s'appuyer sur
   les profils seccomp et AppArmor et appliquer des politiques réseau. Il faut enfin maintenir les images à jour.
4. **Pourquoi Debian slim plutôt qu'Alpine pour Python ?**
   Alpine utilise musl, alors que la plupart des roues binaires Python sont compilées pour la glibc
   (`manylinux`). Sur Alpine, pip compile souvent depuis les sources, ce qui donne des builds plus longs,
   un compilateur dans l'image de build et des différences de comportement subtiles. Pour Nginx, qui est
   compilé par l'éditeur, Alpine convient parfaitement.
5. **(Dépannage)** **Votre conteneur durci plante avec « Read-only file system » : que faites-vous ?**
   J'identifie le chemin écrit (log d'erreur). Je monte un volume temporaire (`tmpfs` dans Compose,
   `emptyDir` dans Kubernetes) uniquement sur ce chemin, au lieu de désactiver le read-only. Exemple
   réel : Nginx doit écrire `/tmp`, `/var/cache/nginx` et `/etc/nginx/conf.d` (configuration générée
   par envsubst).
6. **(Compromis)** **Pourquoi ne pas avoir utilisé distroless ?**
   Voir les perspectives : gain de sécurité réel, mais changement de version de Python et débogage plus
   difficile. J'ai préféré une base slim maîtrisée, une politique explicite et des mesures documentées,
   en gardant distroless comme amélioration suivante.

---

## Phase 3 — Terraform et Ansible

### Terraform vs Ansible : complémentaires, pas concurrents

| | Terraform | Ansible |
|---|---|---|
| Modèle | Déclaratif + **état** (`terraform.tfstate`) | Procédural (tâches ordonnées) et idempotent, **sans état** |
| Force | Créer, modifier et détruire des ressources d'API (cloud, Kubernetes) | Configurer l'intérieur d'une machine (paquets, fichiers, services) |
| Connaissance de l'existant | L'état + le `refresh` permettent de calculer un **plan** (diff) | Chaque module vérifie l'état actuel avant d'agir |
| Suppression | Retirer une ressource du code la **détruit** | Retirer une tâche ne défait rien |

Ici : Terraform crée la VM (AWS) ou le socle Kubernetes (local) ; Ansible configure l'OS et installe k3s.
Le provisionnement par `user_data` a été écarté : la même procédure Ansible sert pour la VM locale
et pour EC2, et elle est rejouable.

### Concepts Terraform

- **`.terraform.lock.hcl`** (commité) : fixe la version **et les sommes de contrôle** des providers.
  `~> 6.68` autorise 6.68.x ou 6.x, mais le lock fige la version exacte jusqu'à `terraform init -upgrade`.
- **`terraform init -backend=false`** : télécharge les providers sans configurer l'état distant.
  C'est ce qui permet de valider sans identifiants AWS.
- **`validate` ≠ `plan`** : `validate` vérifie la syntaxe et la cohérence des types, hors ligne.
  `plan` interroge AWS (identifiants requis) pour calculer les changements.
- **État distant (S3 + verrou)** : en équipe, un état local entraîne des conflits et une perte de
  données. Le backend S3 avec `use_lockfile` empêche deux `apply` simultanés. L'état peut contenir des
  secrets : il doit être chiffré et son accès restreint.
- **`default_tags`** : toutes les ressources sont étiquetées, ce qui sert au suivi des coûts et à
  l'identification du propriétaire.
- **Validations de variables** : `admin_cidr = "0.0.0.0/0"` est refusé dès le `plan`. Le code
  empêche ainsi l'erreur humaine la plus courante.

### Concepts Ansible

- **Idempotence** : relancer le playbook ne change rien si l'état est déjà atteint. Chaque tâche est
  donc écrite avec un module déclaratif (`apt: state=present`, `sysctl`, `ufw`), pas avec `shell`.
- **`--check --diff`** : exécution à blanc, qui montre ce qui changerait sans rien modifier.
  Équivalent du `terraform plan`.
- **Handlers** : exécutés une seule fois en fin de play, seulement si une tâche a notifié un
  changement. Pour SSH, la validation (`sshd -t`) précède le redémarrage, ce qui évite de perdre l'accès
  avec une configuration invalide.
- **ansible-lint, profil `production`** : nommage des tâches, modules FQCN (`ansible.builtin.apt`),
  permissions explicites (`mode`), pas de `command` sans `changed_when`.

### Concept : chaîne d'approvisionnement de k3s

`curl -sfL https://get.k3s.io | sh -` exécute un script non vérifié, dont la version peut changer
d'un jour à l'autre. Ici, le script est téléchargé **au tag de version** et sa SHA-256 est vérifiée
par `get_url` avant exécution. Le script vérifie ensuite la SHA-256 du binaire k3s. Limite : la
somme du binaire provient de la même source GitHub. Elle protège contre une corruption, pas contre
une compromission de la source. La vérification des signatures cosign des artefacts serait l'étape
suivante.

### Erreurs rencontrées — Phase 3

| Problème | Cause | Solution |
|---|---|---|
| `--check` : « Could not find the requested service k3s » | En mode check, les tâches `command` sont sautées : `k3s_installed` n'avait pas de `rc`, et le handler s'exécutait à tort | `check_mode: false` sur la commande de lecture et `default(1)` dans la condition du handler |
| Exceptions Trivy inutiles | Trivy 0.76 a renommé ses règles (`AVD-AWS-0104` → `AWS-0104`) ; les règles 0107 et 0009 ne se déclenchaient pas | Scan d'une copie sans exceptions, retrait des exceptions superflues, nouvel identifiant |
| Hash du script k3s différent entre `get.k3s.io` et le tag | `get.k3s.io` sert la branche principale, qui évolue | Téléchargement au tag `v1.36.5+k3s1`, hash figé |

### Questions d'entretien — Phase 3

1. **Pourquoi ne pas avoir appliqué le module AWS ? Comment prouvez-vous qu'il fonctionne ?**
   L'application crée des ressources facturées ; le projet est à coût nul. J'ai validé ce qui est
   vérifiable sans compte : `fmt`, `validate` (cohérence des types et des références), scan Trivy
   (aucun constat HIGH/CRITICAL non justifié) et une procédure documentée. Je suis honnête sur la
   limite : seul un `plan`, puis un `apply`, prouverait le fonctionnement réel (quotas, AMI, disponibilité).
2. **Que contient l'état Terraform, et pourquoi le protéger ?**
   La correspondance entre le code et les identifiants réels des ressources, ainsi que tous leurs
   attributs, y compris d'éventuels secrets (mots de passe de bases RDS, par exemple). Il faut un
   backend chiffré, un accès restreint, un verrouillage, et ne jamais le commiter (`.gitignore`).
3. **Que se passe-t-il si deux personnes lancent `terraform apply` en même temps ?**
   Sans verrou, les deux lisent le même état et le second écrase l'écriture du premier. Résultat :
   des ressources orphelines ou un état incohérent. Le verrou (S3 `use_lockfile`, ou DynamoDB
   auparavant) sérialise les opérations.
4. **Qu'est-ce que l'IMDSv2 et pourquoi l'imposer ?**
   Le service de métadonnées (169.254.169.254) fournit des identifiants IAM temporaires à l'instance.
   En v1, une simple requête GET suffit : une faille SSRF dans une application permet de les voler
   (cas Capital One, 2019). La v2 exige un jeton obtenu par une requête PUT, et un hop limit de 1
   empêche un conteneur de l'atteindre à travers un saut réseau.
5. **(Compromis)** **Votre groupe de sécurité autorise la sortie vers 0.0.0.0/0, qui est un constat CRITICAL. Pourquoi l'accepter ?**
   Le nœud doit télécharger des images (GHCR) et des paquets, depuis des IP qui changent. J'ai limité
   la sortie aux ports 80/443, et le DNS au résolveur du VPC. Le restreindre davantage impose un proxy
   de sortie ou des VPC endpoints, qui coûtent de l'argent et ajoutent de la complexité. L'exception est
   localisée sur la ressource concernée, justifiée en commentaire et documentée, au lieu de
   désactiver la règle globalement.
6. **(Dépannage)** **Après l'activation d'UFW, les pods ne résolvent plus les noms DNS. Pourquoi ?**
   CoreDNS tourne dans un pod. Le trafic des pods vers CoreDNS (réseau 10.42.0.0/16, service
   10.43.0.10) passe par la pile réseau de l'hôte, et UFW le rejette s'il n'est pas autorisé. D'où les
   règles explicites pour 10.42.0.0/16 et 10.43.0.0/16, issues de la documentation k3s.
