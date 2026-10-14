# Politique de sécurité de la plateforme

Ce document décrit les règles appliquées, ce qu'elles couvrent et leurs limites.
Il est complété au fil des phases.

## 1. Vulnérabilités des images (Trivy)

Configuration unique : [`trivy.yaml`](../trivy.yaml), utilisée en local et dans la CI.

| Règle | Valeur | Justification |
|---|---|---|
| Sévérités bloquantes | HIGH, CRITICAL | Seuil courant ; MEDIUM et LOW sont tracées sans bloquer, pour éviter la fatigue d'alerte |
| Vulnérabilités **avec** correctif | **bloquantes** (`exit-code: 1`) | Une action est possible : mettre à jour la base ou le paquet |
| Vulnérabilités **sans** correctif (`ignore-unfixed`) | non bloquantes, **tracées** | Aucune action possible côté projet ; un blocage permanent rendrait le pipeline inutilisable et pousserait à contourner le contrôle |
| Scanners | vuln, secret, misconfig | Paquets, secrets dans les couches, mauvaises pratiques du Dockerfile |

### Traitement des vulnérabilités sans correctif

1. Elles restent visibles dans le rapport complet (JSON, conservé en artefact CI).
2. Les images sont reconstruites régulièrement : un correctif publié par Debian est alors intégré
   automatiquement, et la vulnérabilité devient bloquante si le correctif n'est pas pris en compte.
3. L'exposition est évaluée : les paquets concernés (util-linux, ncurses, libsystemd, perl-base) ne
   sont pas appelés par l'application. Le conteneur tourne sans root, sans capacités Linux, en lecture
   seule et sans pip, ce qui réduit fortement l'exploitabilité.

### Exceptions

Aucune exception (`.trivyignore`) n'est en vigueur. Toute exception future doit :
- cibler un identifiant CVE précis, jamais une règle entière ;
- comporter une justification et une date d'expiration (`exp:AAAA-MM-JJ` dans `.trivyignore`) ;
- être validée en revue de code.

## 2. Durcissement des conteneurs

| Mesure | API | Frontend | Vérification |
|---|---|---|---|
| Image de base minimale, tag précis | `python:3.12.15-slim-trixie` | `nginx-unprivileged:1.30.5-alpine` | `docker images` |
| Multi-stage | oui | non nécessaire (aucun build) | Dockerfile |
| Utilisateur non-root, UID fixe | 10001 | 101 | `docker exec … id` |
| pip absent à l'exécution | oui | — | `python -m pip` → « No module named pip » |
| `.dockerignore` en liste blanche | oui | oui | fichiers `.dockerignore` |
| Rootfs en lecture seule (Compose) | oui, `/tmp` en tmpfs | oui, 3 tmpfs | `touch /app/x` → « Read-only file system » |
| Capacités Linux supprimées | `cap_drop: ALL` | `cap_drop: ALL` | `CapEff: 0000000000000000` |
| `no-new-privileges` | oui | oui | Compose |
| Pas de bannière de version | `--no-server-header` | `server_tokens off` | `curl -I` |

**Hors périmètre à ce stade** : signature d'images (cosign) et SBOM attesté (envisagés en CI),
image distroless (voir la section Perspectives de `apprentissage.md`), profils seccomp/AppArmor
personnalisés (le profil seccomp par défaut de Docker reste appliqué).

## 3. Secrets

- `.env` ignoré par Git (permissions 600), `.env.example` sans valeur.
- Compose refuse de démarrer sans `POSTGRES_PASSWORD` (`${VAR:?}`).
- `SecretStr` côté Python : le mot de passe n'apparaît ni dans `repr()` ni dans les logs.
- Avant chaque commit : vérification que la valeur réelle du `.env` n'est pas dans l'index Git.
  Gitleaks automatisera ce contrôle en Phase 5.
