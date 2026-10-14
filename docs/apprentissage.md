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
