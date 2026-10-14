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

---

## Phase 4 — Kubernetes (k3s) et Helm

### Ce qu'installe k3s (et pourquoi c'est pratique ici)

Un binaire unique (~80 Mo) qui embarque l'API server, le scheduler, le controller-manager, le kubelet,
containerd, flannel (CNI), CoreDNS, Traefik (Ingress), ServiceLB (LoadBalancer sans cloud),
local-path-provisioner (volumes), metrics-server (HPA) et un contrôleur de NetworkPolicy (kube-router).
La base de données du cluster est SQLite par défaut (etcd possible en multi-nœuds).

### Architecture déployée

```
          Traefik (kube-system) ──► Service frontend ──► Pods Nginx (UID 10101)
Navigateur ─┘   Ingress host:                               │ /api
           dev.plateforme.local / plateforme.local          ▼
                                     Service api ──► Pods FastAPI (UID 10001) ──► Service db ──► StatefulSet PostgreSQL (UID 10070, PVC local-path)
                                         ▲
                     Prometheus (namespace monitoring, Phase 7) ── /metrics
```

Namespaces (Terraform) : `plateforme-dev` et `plateforme-prod` (PSA restricted, quotas), `argocd`
(baseline) et `monitoring` (privileged, pour node-exporter).

### Concepts clés démontrés

**Pod Security Admission (PSA)** : un contrôleur d'admission intégré à Kubernetes, qui remplace les
PodSecurityPolicy supprimées en 1.25. Le label de namespace `pod-security.kubernetes.io/enforce=restricted`
fait refuser par l'API tout pod qui n'est pas non-root, sans `drop: ALL`, avec escalade de privilèges
possible ou sans profil seccomp. Testé : un `nginx` standard est refusé avec la liste exacte des violations.

**Requests vs limits** :
- `requests` : ce que le scheduler **réserve** pour placer le pod. C'est aussi la base de calcul du % CPU du HPA.
- `limits` : le plafond. Au-delà, le CPU est **bridé** (throttling) et la mémoire provoque un **OOMKill**.
- `ResourceQuota` : plafond par namespace. Testé : 20 répliques demandées, 2 créées, car `limits.cpu`
  est plafonné à 2 cœurs.
- `LimitRange` : des valeurs par défaut pour les conteneurs qui n'en déclarent pas.

**Les trois probes** :
| Probe | Rôle | Testée |
|---|---|---|
| startupProbe | Laisse jusqu'à 60 s au démarrage avant d'activer la liveness | Démarrage nominal |
| livenessProbe `/health` | Redémarre un processus bloqué | Base arrêtée → **0 redémarrage** en 25 s |
| readinessProbe `/ready` | Retire le pod du Service | Base arrêtée → NotReady en 8 s ; reprise 5 s après le retour de la base |

**NetworkPolicy** : modèle « deny-all » puis autorisations explicites. **Une NetworkPolicy n'a
d'effet que si le CNI ou un contrôleur l'applique.** Flannel seul ne le fait pas ; k3s ajoute
kube-router pour cela. Je l'ai prouvé avec un contrôle positif : le même flux (autre namespace →
PostgreSQL) est AUTORISÉ sans policy et BLOQUÉ avec.

**HPA** : il interroge metrics-server toutes les 15 s, puis calcule
`désiré = ceil(actuel × utilisation / cible)`. La fenêtre de stabilisation de 120 s sur la réduction
évite les oscillations. Testé : 2 → 4 répliques en ≈ 34 s sous charge, retour à 2 en 121 s.

**Stratégie RollingUpdate `maxSurge: 1`, `maxUnavailable: 0`** : le nouveau pod doit être Ready
**avant** qu'un ancien soit retiré. Une image cassée (ImagePullBackOff) n'interrompt donc pas le service.

### Rollback : trois mécanismes à ne pas confondre

| Mécanisme | Ce qu'il restaure | Ce qu'il NE restaure PAS | Usage |
|---|---|---|---|
| `kubectl rollout undo` | Le **modèle de pod** du Deployment (ReplicaSet précédent) | ConfigMap, Secret, Service, Ingress, HPA… et l'historique Helm | Urgence ponctuelle, hors outil de déploiement |
| `helm rollback <rév>` | **Tous** les objets de la release, à l'état d'une révision | L'état de Git (si GitOps) ; les données (PVC) | Déploiements gérés par Helm |
| Rollback GitOps (`git revert`, Phase 6) | L'**état désiré** dans Git, réappliqué par Argo CD | Les données | Source de vérité unique, avec historique et revue |

**Démonstration réelle du piège** (LOG_LEVEL DEBUG → WARNING via Helm) :
1. `kubectl rollout undo` : nouveau pod, mais `LOG_LEVEL=WARNING`, car la ConfigMap n'a pas été restaurée.
2. `helm rollback` : la ConfigMap revient à DEBUG, mais **le pod n'est pas redémarré**. Le modèle de pod
   (dont l'annotation de checksum) était déjà identique, à cause du `rollout undo`. On obtient un état incohérent.
3. Correction : `kubectl rollout restart`.
→ **Une modification manuelle d'un objet géré par un outil déclaratif crée une dérive.** C'est la
motivation directe de GitOps et du *self-heal* d'Argo CD.

### Incident analysé : 502 pendant une release défectueuse (méthode de diagnostic)

1. **Symptôme** : 10 réponses 502 sur 99 pendant une release à image inexistante, alors que l'ancien pod
   de l'API restait `Running`.
2. **Corrélation** : les logs Nginx montrent `Connection refused` vers le ClusterIP de l'API pendant 5 s.
   Le Service n'avait donc plus d'endpoint prêt.
3. **Cause** : le label `app.kubernetes.io/version` (qui suit le tag de l'application) figurait dans le
   **modèle de pod du StatefulSet PostgreSQL**. Chaque release modifiait ce modèle, PostgreSQL redémarrait,
   et la readiness de l'API (qui teste la base) échouait. Preuve : l'événement `Killing` sur `db-0`.
4. **Correction** : modèle de pod PostgreSQL sans label de version (`plateforme.dbPodLabels`). Vérifié par
   un `diff` du rendu entre deux tags, qui est identique.
5. **Nouvelle mesure biaisée** : 9 erreurs 502 au second essai. J'ai testé trois hypothèses (création de
   pod, pod NotReady avec les labels de l'API, mise à jour des objets NetworkPolicy), toutes réfutées,
   puis fait une bissection (release avec et sans NetworkPolicy) : 0 erreur dans les deux cas. La mesure
   avait démarré 5 s après le correctif, qui avait lui-même redémarré PostgreSQL une dernière fois.
6. **Résultat** : depuis un état stable, une release défectueuse suivie d'un rollback donne **0 erreur sur
   plus de 360 requêtes**.

### Commandes utiles

```bash
kubectl get pods -A -o wide                    # vue d'ensemble
kubectl -n plateforme-dev describe pod <pod>   # événements : probes, pull d'image, quota
kubectl -n plateforme-dev logs deploy/plateforme-dev-api
kubectl top nodes; kubectl top pods -A         # metrics-server
kubectl get events -n plateforme-dev --sort-by=.lastTimestamp
helm lint k8s/helm/plateforme -f k8s/environments/dev/values.yaml
helm template t k8s/helm/plateforme | less     # rendu sans installer
helm -n plateforme-dev history plateforme-dev
helm -n plateforme-dev rollback plateforme-dev <rév> --wait
docker save img:tag | sudo k3s ctr -n k8s.io images import -   # image locale → containerd de k3s
curl --resolve dev.plateforme.local:80:127.0.0.1 http://dev.plateforme.local/ready
```

### Erreurs rencontrées — Phase 4

| Problème | Cause | Solution |
|---|---|---|
| Ansible non idempotent (`changed=1` sur `log_martians`) | UFW applique `/etc/ufw/sysctl.conf` (log_martians=0) à chaque activation | Rôle firewall : alignement de ce fichier, handler `ufw reload` |
| `kubectl` en utilisateur : avertissements et 253 Mo dans `~/.rancher` | `/usr/local/bin/kubectl` était un lien vers le binaire k3s | kubectl officiel (pkgs.k8s.io), `INSTALL_K3S_SYMLINK=skip`, liens retirés par Ansible |
| `trivy config k8s/ app/ infra/` → « multiple targets » | Trivy n'accepte qu'une seule cible | Scan de `.` avec `skip-dirs` |
| Exception Trivy KSV-01010 sans effet | Chemins relatifs à la cible scannée | Scan depuis la racine du dépôt |
| 61 blocages UFW (ICMPv6 ff02::2, ff02::16) | Multicast IPv6 automatique des interfaces de pods | Sans conséquence (cluster IPv4) ; règles non élargies |
| 502 pendant une release | Label de version dans le modèle de pod PostgreSQL | Voir l'incident ci-dessus |
| État incohérent après `rollout undo` + `helm rollback` | Modification hors de Helm | `rollout restart` ; règle : ne pas modifier à la main |

### Questions d'entretien — Phase 4

1. **Quelle différence entre liveness et readiness ? Donnez un exemple de mauvaise configuration.**
   Voir le tableau des probes. Mauvaise configuration typique : tester la base de données dans la
   liveness. Une panne de base provoque alors des redémarrages en boucle de tous les pods de l'API,
   qui aggravent l'incident (thundering herd au retour de la base). Je l'ai mesuré : avec ma
   configuration, une base arrêtée donne 0 redémarrage et une reprise en 5 s.
2. **Comment vérifiez-vous que vos NetworkPolicy fonctionnent vraiment ?**
   Avec une matrice de tests (flux autorisés ET interdits), puis un **contrôle positif** : désactiver
   les policies et constater que le flux interdit passe. Sans ce contrôle, « bloqué » peut venir d'une
   autre cause (DNS, outil absent, service arrêté). Je vérifie aussi que le CNI les applique : sur k3s,
   c'est kube-router ; avec flannel seul, elles seraient ignorées sans aucun message d'erreur.
3. **`kubectl rollout undo` vs `helm rollback` : lequel utiliser ?**
   Voir le tableau. En environnement géré par Helm (ou par GitOps), il ne faut jamais utiliser
   `rollout undo`. Il ne restaure que le modèle de pod et désynchronise l'outil. Je l'ai démontré :
   on obtient un pod en WARNING face à une ConfigMap en DEBUG.
4. **Pourquoi PostgreSQL dans un StatefulSet et pas un Deployment ?**
   Pour une identité stable (`db-0`), un volume dédié par réplique (`volumeClaimTemplates`) qui suit le
   pod, et un ordre de démarrage et d'arrêt garanti. Limite : sans opérateur, aucune réplication, ni
   sauvegarde, ni basculement. En production : RDS ou CloudNativePG.
5. **(Dépannage)** **Des 502 apparaissent pendant un déploiement alors que vos pods sont Running. Votre démarche ?**
   Voir l'incident ci-dessus : corréler les horodatages (client, logs Nginx, événements Kubernetes),
   vérifier les endpoints du Service, identifier ce qui a redémarré (`kubectl get events`, UID des pods),
   formuler une hypothèse et la tester isolément, puis faire une bissection. **Et se méfier de ses propres
   mesures** : la deuxième série d'erreurs était un artefact de ma méthode.
6. **(Compromis)** **HPA sur 2 vCPU : est-ce utile ?**
   Le HPA a fonctionné (2 → 4 en 34 s), mais le CPU est resté à ≈ 167 % des requests à 4 répliques : le
   nœud était saturé. L'autoscaling horizontal n'a de sens que si des ressources sont disponibles. En
   production, il est couplé au Cluster Autoscaler ou à Karpenter, qui ajoutent des nœuds. Ici, il
   démontre le mécanisme et protège contre les pics modérés.

---

## Phase 5 — Pipeline CI DevSecOps (GitHub Actions)

### Vue d'ensemble du pipeline (`.github/workflows/ci.yml`)

```
push / pull_request
  ├── lint-test      ruff + pytest (unitaires + intégration, PostgreSQL en conteneur de service, couverture ≥ 90 %)
  ├── secrets-scan   Gitleaks sur TOUT l'historique Git
  ├── sast           Semgrep (python, bandit, security-audit, javascript, dockerfile, secrets)
  └── iac            Trivy config + Trivy fs (SCA) + terraform fmt/validate + helm lint + ansible-lint
          │  (les 4 doivent réussir)
          ▼
  build-scan-push (matrice api / frontend)
     build → Trivy image (bloquant) → rapport complet + SBOM CycloneDX → push GHCR (main uniquement)
          ▼
  update-gitops (main uniquement)  → commit du tag sha-<12> dans k8s/environments/dev/values.yaml
promote.yml (manuel)               → recopie le tag de dev vers k8s/environments/prod/values.yaml
```

**« Shift left »** : les contrôles les moins coûteux (lint, secrets, SAST) tournent en premier et en
parallèle. Une image n'est construite et publiée que si tout est vert. Une image non scannée ne peut
donc pas atteindre le registre.

### Sécurité de la chaîne d'approvisionnement (supply chain)

| Mesure | Pourquoi |
|---|---|
| `permissions: {}` global, permissions minimales par job | Le `GITHUB_TOKEN` d'un job compromis ne peut faire que ce que ce job doit faire. Seuls `build-scan-push` (packages:write) et `update-gitops` (contents:write) écrivent |
| Actions épinglées par **SHA de commit** | Un tag (`v4`) est mobile : un mainteneur compromis peut le déplacer vers du code malveillant (cas `tj-actions/changed-files`, mars 2025). Un SHA est immuable |
| Actions limitées à GitHub (`actions/*`) et Docker (`docker/*`), plus 2 actions d'installation (HashiCorp, Azure) | Moins de tiers = moins de risque |
| Outils (Trivy, Gitleaks, Semgrep) installés en CLI avec version figée et SHA-256 vérifiée | Mêmes versions qu'en local, pas d'action tierce supplémentaire |
| Versions choisies avec **au moins 2 semaines de recul** | Une release compromise ou défectueuse est généralement détectée dans les jours qui suivent sa publication. Trivy 0.76.0, publié le jour même, a été remplacé par 0.74.0 (2 mois) |
| `persist-credentials: false` sur les checkouts en lecture | Le jeton n'est pas laissé sur le disque du runner pour les étapes suivantes |
| GHCR via `GITHUB_TOKEN` | Jeton éphémère (durée du run) : aucun secret longue durée à créer ni à faire tourner |
| Push de la CI avec `GITHUB_TOKEN` | Ce type de push ne déclenche pas de nouveau workflow, donc pas de boucle infinie |

### Tag immuable

`sha-<12 premiers caractères du commit>` : chaque image est liée à un commit précis. `latest` est à
proscrire : on ne sait plus ce qui tourne, et un rollback vers `latest` ne veut rien dire.
**Limite** : GHCR n'interdit pas techniquement d'écraser un tag. L'immuabilité repose sur la
convention (un SHA n'est construit qu'une fois). Le niveau supérieur serait de déployer par
**digest** (`image@sha256:…`) et de signer les images (cosign).

### Contrôles positifs (« un scanner silencieux ne prouve rien »)

| Outil | Contrôle positif | Résultat |
|---|---|---|
| Semgrep | Fichier volontairement vulnérable (hors dépôt) | `p/bandit` détecte shell=True, injection SQL, MD5 ; `yaml.load` non détecté (limite documentée) |
| Gitleaks | Commit d'une clé factice (aléatoire) dans un clone jetable | Bloqué (code 1), valeur masquée |
| Gitleaks | Suppression de la clé dans un commit suivant | **Toujours bloqué** : le secret reste dans l'historique |
| Trivy fs | `pyyaml==5.3.1` ajouté aux dépendances | Bloqué : CVE-2020-14343 CRITICAL (corrigée en 5.4) |
| Trivy image | Image `python:3.12.15` (Phase 2) | Bloqué : 12 HIGH corrigeables |

### Concept : que faire si un vrai secret est commité ?

1. **Révoquer immédiatement** le secret chez le fournisseur : c'est la seule action qui supprime le risque.
2. **En générer un nouveau** (rotation) et le déployer par le canal prévu (secret GitHub, Secret K8s).
3. Analyser l'exposition : depuis quand, dépôt public ou non, journaux d'accès du fournisseur.
4. Seulement ensuite, nettoyer l'historique (`git filter-repo`) si nécessaire. Cela réécrit l'historique,
   impose un push forcé coordonné, et **ne supprime pas** les clones, forks ni caches existants.
5. Ajouter une protection en amont : hook pre-commit Gitleaks, push protection de GitHub.

Supprimer le fichier dans un nouveau commit ne sert à rien : le secret reste dans l'historique
(démontré ci-dessus).

### Erreurs rencontrées — Phase 5 (partie locale)

| Problème | Cause | Solution |
|---|---|---|
| ansible-lint 26.9 : « couldn't resolve module ansible.posix.sysctl » | Le paquet Ubuntu fournissait les collections implicitement ; pas pip | `requirements.yml` avec versions figées, `ansible-galaxy collection install` |
| community.general 13.x incompatible avec ansible-core 2.16 (local) | `requires_ansible >= 2.18` | Version 11.4.9 (compatible 2.16 et 2.21) |
| ansible-lint analyse 3 504 fichiers | Collections téléchargées dans `infra/ansible/collections` | `.ansible-lint` : `exclude_paths` |
| Semgrep : 8 erreurs de parsing | Templates Helm (syntaxe Go) analysés comme du YAML | `.semgrepignore` (le chart rendu est couvert par Trivy) |
| actionlint « OK » sans analyser les scripts | shellcheck absent | shellcheck installé ; SC2015 corrigé dans install.sh |
| Trivy local en 0.76.0 (publiée le jour même) | Paquet APT flottant | Binaire 0.74.0 figé, SHA-256 vérifiée ; tous les contrôles revalidés |

### Résultats sur GitHub

- Dépôt public : https://github.com/Ghassen-kahia/plateforme-devsecops
- Premier pipeline : 7 jobs verts en 141 s, images `ghcr.io/ghassen-kahia/plateforme-{api,frontend}:sha-…`
  publiées, commit GitOps automatique `chore(gitops): déployer sha-… en dev`.
- Les images d'un dépôt public sont publiques sur GHCR : k3s les télécharge sans secret (vérifié par
  un accès anonyme au manifeste, HTTP 200).
- PR #1 (secret factice) : bloquée par **Gitleaks seul**, valeur `REDACTED` dans les logs.
- PR #2 (pyyaml 5.3.1) : bloquée par **Trivy fs seul** (CVE-2020-14343).
- Dans les deux cas, les jobs d'image et GitOps sont `skipped` : rien n'est publié.

### Incident : une PR propre bloquée par le secret d'une autre branche

**Symptôme** : la PR #2 (sans secret) échouait aussi sur Gitleaks.
**Cause** : `actions/checkout` avec `fetch-depth: 0` récupère **toutes les branches**, et
`gitleaks git` analyse par défaut `git log --all`. Le secret de la branche de la PR #1 était donc
reproché à la PR #2.
**Correction** : périmètre selon l'événement (`--log-opts`) : `base..head` pour une PR, l'historique
de la branche pour un push, `--all` dans un **scan hebdomadaire planifié**. Ce dernier rattrape aussi
un secret poussé sur une branche sans PR. Vérifié : chaque PR n'est plus bloquée que par son propre contrôle.
**Leçon** : un contrôle qui accuse le mauvais coupable est presque aussi nuisible qu'un contrôle
absent, car l'équipe finit par l'ignorer.

### Limite assumée : la PR reste techniquement fusionnable

Le pipeline échoue et GitHub affiche la croix rouge, mais **sans règle de protection de branche**
exigeant les checks, le bouton de fusion reste disponible. Je ne l'ai pas activée, car la CI pousse
directement le commit GitOps sur `main` : une règle « checks obligatoires » rejetterait ce push.
Solutions en équipe :
1. **Dépôt GitOps séparé**, mis à jour par une deploy key ou une GitHub App. `main` du dépôt applicatif
   peut alors être entièrement protégé (PR obligatoire + checks requis). C'est la cible recommandée.
2. Ruleset avec contournement autorisé pour l'identité de la CI.

### Questions d'entretien — Phase 5

1. **Pourquoi épingler les actions par SHA plutôt que par tag ?**
   Un tag Git est un pointeur mobile. Si le compte d'un mainteneur est compromis, l'attaquant peut
   déplacer `v4` vers un commit malveillant, qui s'exécutera dans tous les pipelines qui l'utilisent,
   avec leurs secrets. C'est arrivé avec `tj-actions/changed-files` en 2025. Un SHA désigne un contenu
   précis et immuable. Le tag reste en commentaire pour la lisibilité, et Dependabot ou Renovate
   peuvent proposer les mises à jour.
2. **Comment avez-vous appliqué le moindre privilège dans GitHub Actions ?**
   `permissions: {}` au niveau du workflow, puis par job : `contents: read` partout, `packages: write`
   uniquement pour la publication, `contents: write` uniquement pour le commit GitOps. Le jeton est
   éphémère et propre au run. Aucun secret longue durée n'est nécessaire pour GHCR.
3. **Un développeur supprime un mot de passe qu'il avait commité. Le problème est-il réglé ?**
   Non, voir la procédure ci-dessus. Je l'ai démontré : Gitleaks échoue toujours après la suppression.
   La seule vraie correction est la révocation et la rotation.
4. **Pourquoi Semgrep plutôt que SonarQube ?**
   Semgrep s'exécute en CLI, sans serveur, en quelques secondes, avec des règles lisibles et
   personnalisables. SonarQube apporte un suivi de la dette et de la qualité dans le temps, mais demande
   un serveur, une base de données et environ 2 Go de RAM : c'est disproportionné pour une VM à 2 vCPU.
   Limite constatée : aucun jeu de règles n'a détecté `yaml.load`. Un SAST ne remplace ni la revue
   de code ni les tests.
5. **(Compromis)** **Pourquoi des vulnérabilités sans correctif ne bloquent-elles pas le pipeline ?**
   Voir la Phase 2 : bloquer ce qui est corrigeable, tracer le reste (rapport JSON et SBOM en artefact),
   et reconstruire régulièrement. Sinon, l'équipe finit par désactiver le contrôle.
7. **(Dépannage)** **Une PR sans secret échoue sur Gitleaks. Que vérifiez-vous ?**
   Le commit et le fichier signalés : s'ils n'appartiennent pas à la PR, c'est le périmètre du scan qui
   est en cause. Cas réel : `fetch-depth: 0` + `gitleaks git` (`--all`) analysaient les autres branches.
   Correction : `--log-opts base..head` sur les PR et scan complet planifié chaque semaine.
8. **Vos PR en échec peuvent-elles quand même être fusionnées ?**
   Oui, tant qu'aucune protection de branche n'exige les checks. C'est une limite que j'assume et
   que je documente (voir ci-dessus). La cible est un dépôt GitOps séparé, avec `main` protégé.
6. **(Dépannage)** **Le job ansible-lint échoue en CI alors qu'il passe en local. Pourquoi ?**
   Cas réel : la version locale (Ubuntu) embarquait implicitement les collections, alors que la
   version pip de la CI ne les avait pas. Il fallait déclarer la dépendance cachée dans
   `requirements.yml`, figer les versions et reproduire l'environnement CI en local (venv) avant de pousser.

---

## Phase 6 — GitOps avec Argo CD et Sealed Secrets

### Le principe GitOps

1. **Déclaratif** : l'état voulu est décrit (chart + valeurs), pas une suite de commandes.
2. **Versionné dans Git** : historique, revue, auteur, possibilité de `git revert`.
3. **Tiré (pull), pas poussé (push)** : c'est un agent DANS le cluster (Argo CD) qui lit Git et applique.
   La CI n'a **aucun accès au cluster** : pas de kubeconfig dans GitHub, surface d'attaque réduite.
4. **Réconcilié en continu** : toute différence entre Git et le cluster est détectée et corrigée.

### Flux complet obtenu

```
git push (code) → CI GitHub (tests, scans, build, GHCR) → commit CI : k8s/environments/dev/values.yaml
                                                              │
                         Argo CD (dans k3s) interroge Git toutes les 60 s ◄┘
                                │ différence détectée → helm template + kubectl apply
                                ▼
                         plateforme-dev mis à jour (RollingUpdate, preStop)
promote.yml (manuel) → commit : k8s/environments/prod/values.yaml → Argo CD → plateforme-prod
```

### Organisation Argo CD

- **Application racine `plateforme-root`** (app of apps) : elle synchronise `k8s/argocd/applications/`.
  Ajouter un environnement revient à ajouter un fichier par PR, sans aucune commande sur le cluster.
- **AppProject `plateforme`** : sources limitées à CE dépôt, destinations limitées à `plateforme-dev`
  et `plateforme-prod`, aucune ressource de niveau cluster, liste blanche des types d'objets.
  Même un manifeste malveillant fusionné ne pourrait pas créer de ClusterRole.
- **Synchronisation automatique** avec `prune` (ce qui est retiré de Git est supprimé) et `selfHeal`
  (ce qui est modifié à la main est rétabli).
- `ignoreDifferences` sur `spec.replicas` de l'API : en prod, le HPA pilote ce champ. Sans cette
  exception, Argo CD et le HPA se battraient en permanence.
- Argo CD lui-même est installé par Helm (`scripts/gitops-bootstrap.sh`) : c'est le **problème de
  l'amorçage** (il faut bien installer l'outil GitOps avant qu'il ne gère quelque chose).

### Sealed Secrets : des secrets dans Git, chiffrés

```
kubeseal (poste) ──chiffre avec la clé PUBLIQUE──► SealedSecret (commité dans Git)
                                                        │ Argo CD l'applique
contrôleur (cluster, clé PRIVÉE) ──déchiffre──► Secret Kubernetes ──► pod PostgreSQL / API
```

- Portée **strict** : le texte chiffré est lié au nom ET au namespace. Testé : rejoué ailleurs, il est
  refusé (« no key could decrypt secret »).
- Migration sans coupure : le mot de passe **existant** a été chiffré (PostgreSQL l'utilisait déjà),
  directement du cluster vers kubeseal par un pipe, sans affichage. Empreinte SHA-256 identique avant et
  après la reprise par le contrôleur.
- **Limites** :
  - la clé privée du contrôleur est le point critique : sans elle (cluster reconstruit), les
    SealedSecret sont indéchiffrables. Il faut la sauvegarder hors du cluster, de façon sécurisée ;
  - la rotation de la clé de scellement n'est pas une rotation des secrets : les anciens chiffrés
    restent valides avec les anciennes clés ;
  - toute personne qui peut lire les Secrets du namespace (RBAC) voit la valeur en clair ;
  - alternatives : External Secrets Operator + Vault ou AWS Secrets Manager (secrets hors de Git,
    rotation centralisée), SOPS (chiffrement de fichiers avec KMS ou age).

### Trois rollbacks, trois niveaux

| Niveau | Commande | Effet | Mesuré |
|---|---|---|---|
| GitOps (retenu) | `git revert <commit gitops>` + push | L'état désiré revient en arrière ; Argo CD applique ; historique conservé | 89 s, 0 erreur sur 1 460 requêtes |
| Helm | `helm rollback` | **Plus utilisé** : Argo CD annulerait le retour arrière (self-heal) | Phase 4 |
| Deployment | `kubectl rollout undo` | **À proscrire** : dérive, annulée par Argo CD | Phase 4 |

Le bouton « Rollback » de l'interface Argo CD est désactivé quand la synchronisation automatique est
active. C'est logique : le seul moyen de revenir en arrière durablement est de changer Git.
**Après un rollback** : le prochain commit sur main redéploiera une nouvelle version ; la correction se
fait par un nouveau commit (« fix forward »), le revert sert à stabiliser en attendant.

### Incident : 502 pendant une mise à jour réussie (course à l'arrêt)

- **Symptôme** : à la reprise par Argo CD (image locale → GHCR), 2 × 502 et 1 timeout sur 163 requêtes.
- **Cause** : quand un pod est arrêté, Kubernetes envoie SIGTERM au conteneur **en parallèle** de son
  retrait des endpoints. kube-proxy, Traefik et Nginx mettent un court instant à le savoir et envoient
  encore quelques requêtes à un processus qui s'arrête. Corrélation : erreurs à l'horodatage exact des
  événements `Killing`, base non redémarrée.
- **Pourquoi la Phase 4 ne l'avait pas vu** : les tests de release défectueuse ne terminaient jamais
  l'ancien pod. Un test ne couvre que ce qu'il exerce.
- **Correction** : `lifecycle.preStop.sleep: 5 s` (action native, aucun binaire requis) et
  `terminationGracePeriodSeconds: 30`.
- **Vérification** : 0 erreur sur 939 requêtes (changement de configuration), 1 460 (rollback
  d'image) et 938 (promotion prod).

### Dérives corrigées (self-heal)

| Modification manuelle | Corrigée en |
|---|---|
| `kubectl scale` frontend 1 → 3 | 1,7 s |
| Suppression de la NetworkPolicy de PostgreSQL | 2,0 s |
| ConfigMap modifiée (LOG_LEVEL) | 6,1 s |

Argo CD surveille les objets via l'API Kubernetes (watch) : une dérive est vue immédiatement, sans
attendre l'intervalle de 60 s, qui ne concerne que la comparaison avec **Git**.

### Erreurs rencontrées — Phase 6

| Problème | Cause | Solution |
|---|---|---|
| **Commit poussé malgré deux validations en échec** | Étapes chaînées avec `;` au lieu de `&&` | Arrêt immédiat, analyse, correctif ; la CI a bloqué le commit (pas d'image publiée). Validations désormais strictement chaînées |
| Gitleaks : `sealedPassword` (chiffré) signalé | Heuristique d'entropie sur une valeur chiffrée publiable | Exception sur le format exact d'un chiffré kubeseal |
| Première exception Gitleaks trop large | Le critère `paths` faisait ignorer tout le fichier | Détecté par contrôle positif ; critère retiré |
| Trivy local : Containerfile de test (HIGH) | Collections Ansible téléchargées scannées | `skip-dirs: infra/ansible/collections` |
| Chart Sealed Secrets introuvable (404) | Projet déplacé vers `bitnami/sealed-secrets` | Nouvelle URL de dépôt Helm |
| Argo CD 3.5.3 (règle des 2 semaines) | 4 CVE critiques corrigées en 3.5.4 | **Exception à la règle** : correctif de sécurité prioritaire → 3.5.4 |
| Contrôleur ApplicationSet actif malgré `enabled: false` | Clé inexistante dans ce chart | `applicationSet.replicas: 0` |
| `git revert` sans argument | `&` en fin de chaîne `&&` : tout s'exécutait dans un sous-shell | Étapes séparées ; dépôt vérifié intact |
| 2 × 502 + 1 timeout pendant une mise à jour | Course SIGTERM / endpoints | preStop sleep (voir l'incident) |

### Questions d'entretien — Phase 6

1. **Push vs pull : pourquoi Argo CD plutôt qu'un `kubectl apply` dans la CI ?**
   En mode push, la CI détient des identifiants d'administration du cluster : une fuite ou une action
   compromise donne accès à la production. En mode pull, seul Argo CD (dans le cluster) agit, et la CI
   ne fait qu'écrire dans Git. On gagne aussi la détection des dérives et un historique complet dans Git.
2. **Comment gérez-vous les secrets en GitOps ?**
   Avec Sealed Secrets : chiffrement asymétrique, texte chiffré commitable et lié à un nom et un namespace.
   Je connais ses limites (clé privée à sauvegarder, pas de rotation automatique). En entreprise, je
   regarderais External Secrets Operator avec Vault ou AWS Secrets Manager.
3. **Quelqu'un fait un `kubectl edit` en production. Que se passe-t-il ?**
   Argo CD détecte la différence et la rétablit en quelques secondes (mesuré : 1,7 à 6,1 s), et
   l'événement est visible. Pour changer quelque chose, il faut passer par Git, avec revue et historique.
   En cas d'urgence, on peut suspendre l'auto-sync, mais c'est une décision tracée.
4. **Argo CD vs Flux ?**
   Les deux sont des projets CNCF diplomés. Argo CD offre une interface web riche, des AppProjects pour
   le multi-équipes et le pattern « app of apps ». Flux est plus modulaire (contrôleurs séparés),
   s'intègre nativement à SOPS et automatise les mises à jour d'images, mais n'a pas d'interface
   officielle. J'ai choisi Argo CD pour sa visibilité pédagogique.
5. **(Compromis)** **Pourquoi l'état GitOps est-il dans le même dépôt que le code ?**
   Pour éviter un secret supplémentaire (deploy key) : la CI écrit avec le `GITHUB_TOKEN`. Le prix : un
   historique mélangé, et l'impossibilité de protéger `main` avec des checks obligatoires (le bot pousse
   directement). En équipe, je séparerais les dépôts.
6. **(Dépannage)** **Des 502 apparaissent à chaque déploiement réussi. Pourquoi, et comment le prouver ?**
   Voir l'incident : corréler les erreurs avec les événements `Killing`, écarter les autres causes
   (base stable), puis corriger avec preStop et **mesurer de nouveau** sous trafic (0 erreur sur plus de
   3 300 requêtes, sur trois déploiements).

---

## Phase 7 — Supervision (Prometheus, Grafana, Alertmanager)

### Architecture de la supervision

```
API FastAPI /metrics ──(ServiceMonitor, 15 s)──┐
Traefik :9100 /metrics ──(PodMonitor, 15 s)────┤
kubelet / cAdvisor, node-exporter,             ├──► Prometheus ──(règles)──► Alertmanager ──► (canal externe à brancher)
kube-state-metrics, apiserver, CoreDNS ────────┘        │
                                                       └──► Grafana (tableau de bord provisionné depuis Git)
```

- **kube-prometheus-stack** : Prometheus Operator + CRD (`ServiceMonitor`, `PodMonitor`,
  `PrometheusRule`). On décrit QUOI superviser par des objets Kubernetes, et l'opérateur génère la
  configuration de Prometheus.
- **La supervision de l'application vit dans son chart** (ServiceMonitor + PrometheusRule), déployée
  par Argo CD. Changer l'application et ses alertes se fait dans la même PR.
- **k3s** : contrôleur, scheduler, etcd et kube-proxy sont intégrés au processus k3s, sans cible
  séparée. Leur supervision est désactivée pour éviter des alertes `TargetDown` permanentes.

### Les 4 alertes et leur logique

| Alerte | Type | Expression (résumé) | `for` | Pourquoi |
|---|---|---|---|---|
| BaseDeDonneesIndisponible | **cause** | `min(app_database_up) == 0` | 30 s | Oriente directement le diagnostic |
| ApiIndisponible | **symptôme** | 0 réplique disponible (kube-state-metrics) | 1 min | Service totalement coupé |
| TauxErreurs5xxEleve | **expérience utilisateur** | 5xx / total > 5 % **mesuré à Traefik** | 1 min | Ce que subit l'utilisateur |
| LatenceP95Elevee | dégradation | p95 > 500 ms sur 5 min | 5 min | Lenteur avant panne |

**Pourquoi mesurer les erreurs à l'Ingress ?** Quand l'API est hors service, elle n'est plus dans le
Service : les requêtes n'arrivent plus jusqu'à elle, et **ses propres métriques ne voient aucune
erreur**. Seul le point d'entrée (Traefik) voit les 502. C'est la différence entre la supervision
« boîte blanche » (métriques internes) et le point de vue utilisateur.

**`for:`** : durée pendant laquelle la condition doit rester vraie avant de passer de `pending` à
`firing`. Elle évite les alertes sur des pics de quelques secondes. C'est un compromis entre rapidité
de détection et bruit.

### Exercice de panne contrôlée (mesures réelles)

Panne déclenchée **par Git** (`database.replicas: 0`) : avec le self-heal d'Argo CD, un `kubectl scale`
aurait été annulé en 2 s. La panne est ainsi tracée, revue et annulée par `git revert`.

| Étape (référence : 1re erreur vue par un utilisateur, 20:27:28) | Délai |
|---|---|
| Alertes `pending` | +34 s |
| `BaseDeDonneesIndisponible` reçue par Alertmanager | **+63 s** |
| Les 3 alertes critiques reçues par Alertmanager | **+94 s** |
| `git revert` poussé → service rétabli (HTTP 200) | 166 s |
| `git revert` poussé → plus aucune alerte active | 359 s |

Décomposition du délai de détection : intervalle de collecte (15 s) + évaluation des règles (30 s) +
`for` (30 s à 1 min) + `group_wait` d'Alertmanager (10 s).

### Ce que l'exercice a révélé (et qui a été corrigé)

1. **Alertes sans label `namespace`.** `min()` et `sum()` suppriment les labels : les alertes de dev
   et de prod étaient **identiques**, donc fusionnées par Alertmanager, et le routage par environnement
   était impossible. Correction : label `namespace` statique dans chaque règle.
2. **Clé YAML mal placée.** Le PodMonitor Traefik se trouvait sous `grafana:`, et était donc ignoré
   **sans aucune erreur**. Correction, plus une vérification de structure (`yaml.safe_load` + assertion).
3. **Effet de fenêtre.** Le `rate(...[2m])` contient encore des erreurs après le retour du service :
   l'alerte 5xx est restée active jusqu'à environ 3 min après la correction, et elle est même passée en
   `firing` **après** la reprise lors du premier exercice. Une fenêtre courte réagit plus vite mais
   génère plus de bruit.
4. **Changer les labels d'une règle remet les alertes à zéro** (nouvelle identité, `for` relancé).
5. **node-exporter bridé 48 % du temps** (alerte `CPUThrottlingHigh`) : limite CPU portée de 100m à 250m.

### Incident réel : gel de la VM puis cascade de redémarrages

- **Faits** : aucune ligne dans le journal système entre 19:39 et 20:04 (25 min de silence total), un
  trou équivalent dans Prometheus, des tâches de fond terminées « en avance » (saut d'horloge), puis au
  réveil `Node became not ready`, des évictions et une charge de 52 sur 2 vCPU.
- **Cause** : la VM a été suspendue par l'hôte (veille du PC ou pause VMware), ce qui est invisible de
  l'intérieur. Au réveil, les heartbeats et toutes les probes ont expiré en même temps, provoquant une
  vague de redémarrages qui a saturé les 2 vCPU (spirale : redémarrage → CPU → probes en échec →
  redémarrage).
- **Rétablissement** : automatique, en environ 8 min, sans intervention.
- **Leçons** :
  - **Une supervision interne ne peut pas signaler que sa propre machine est figée.** C'est le rôle de
    l'alerte `Watchdog`, toujours active : un service **externe** (Healthchecks.io, PagerDuty…)
    s'alarme quand elle cesse d'arriver (« dead man's switch »).
  - La marge CPU était trop faible : au repos, la plateforme complète consommait **≈ 73 % des 2 vCPU**
    (34 % en temps système). Les probes `exec` de PostgreSQL (création d'un processus à chaque essai)
    ont été allégées et l'effet mesuré (voir mesures.md, M9).
  - Recommandation maintenue depuis la Phase 0 : **4 vCPU** pour faire tourner toute la stack sereinement.

### Commandes utiles

```bash
bash monitoring/install.sh                                         # installer / mettre à jour
kubectl -n monitoring port-forward svc/kps-grafana 3000:80         # http://localhost:3000
kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090
# Sans port-forward (plus robuste) : proxy du serveur d'API
kubectl get --raw "/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy/api/v1/alerts" | jq
kubectl get --raw "/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-alertmanager:9093/proxy/api/v2/alerts" | jq
kubectl get servicemonitor,podmonitor,prometheusrule -A
```

PromQL de base :
```promql
sum by (route, status) (rate(http_requests_total{namespace="plateforme-prod"}[5m]))      # débit
histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))  # p95
sum(rate(traefik_service_requests_total{code=~"5.."}[2m])) / sum(rate(traefik_service_requests_total[2m]))
```

### Erreurs rencontrées — Phase 7

| Problème | Cause | Solution |
|---|---|---|
| Aucune métrique Traefik | Bloc `additionalPodMonitors` sous `grafana:` (indentation) | Déplacé sous `prometheus:` + contrôle de structure |
| Mes alertes semblaient absentes | Mon filtre `namespace` ; les agrégations l'avaient supprimé | Label `namespace` ajouté aux règles |
| Port-forward coupé pendant un suivi long | Pod Prometheus recréé / VM gelée | Proxy du serveur d'API (`kubectl get --raw`) |
| `pkill -f motif` a tué mon propre shell | Le motif figurait dans sa ligne de commande | Arrêt des tâches par identifiant |
| `gitleaks dir monitoring k8s` → 125 « fuites » | Un seul chemin accepté : tout le répertoire courant, collections comprises, a été scanné | `gitleaks git --pre-commit --staged` avant commit |
| Script d'exercice menacé par une modification locale | `git pull --rebase` refuse un répertoire modifié | `git stash` avant le pull, réappliqué ensuite |
| CPU au repos ≈ 73 % | Stack complète sur 2 vCPU, probes exec coûteuses | Probes allégées (mesure A/B), 4 vCPU recommandés |

### Questions d'entretien — Phase 7

1. **Quelle différence entre une alerte sur une cause et une alerte sur un symptôme ?**
   Le symptôme (« l'utilisateur reçoit des 5xx », « plus aucune réplique ») dit qu'il y a un impact :
   c'est ce qui doit réveiller quelqu'un. La cause (« la base est injoignable ») accélère le diagnostic.
   Bonne pratique : appeler sur les symptômes, et enrichir avec les causes, en lien avec un runbook.
2. **Pourquoi votre alerte 5xx utilise-t-elle les métriques de Traefik et pas celles de l'API ?**
   Quand l'API est retirée du Service, elle ne reçoit plus les requêtes, et son compteur d'erreurs ne
   bouge pas. Seul le point d'entrée voit les 502. L'exercice l'a confirmé : ce sont les métriques
   Traefik qui ont déclenché l'alerte.
3. **Votre Prometheus tourne dans le cluster. Que se passe-t-il si tout le nœud tombe ?**
   Personne n'est prévenu : Prometheus et Alertmanager tombent avec lui. C'est arrivé (gel de la VM
   pendant 25 min, sans aucune alerte). La réponse est l'alerte `Watchdog`, envoyée en permanence vers
   un service externe qui s'alarme quand elle s'arrête, complétée par une sonde externe (blackbox).
4. **Comment choisissez-vous la durée `for` et la fenêtre `rate()` ?**
   Compromis entre délai de détection et faux positifs. Mesuré : 63 à 94 s entre la première erreur
   et l'alerte. La fenêtre de 2 min a aussi prolongé l'alerte d'environ 3 min après la reprise. Pour un
   service critique, on utilise les alertes multi-fenêtres sur le budget d'erreur (SLO, burn rate).
5. **Qu'est-ce que la cardinalité, et comment l'avez-vous maîtrisée ?**
   Voir la Phase 1 (label `route` = modèle de route). Ici aussi : rétention de 24 h et 2 Go, collecte de
   15 à 30 s, composants inutiles désactivés.
6. **(Dépannage)** **La plateforme est lente et la charge système atteint 52. Votre démarche ?**
   1) Stabiliser d'abord : couper sa propre charge et observer si le système récupère seul.
   2) Mesurer : `top` instantané (et non `ps`, qui donne une moyenne sur la vie du processus), `vmstat`,
   historique Prometheus (CPU par mode, PSI, swap). 3) Chercher les trous : un trou de 25 min dans le
   journal système a révélé un gel de la VM. 4) Corriger la cause de fond (marge CPU), puis remesurer.
