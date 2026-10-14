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
