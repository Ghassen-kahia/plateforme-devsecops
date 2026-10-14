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

## 4. Infrastructure as Code (Terraform AWS)

| Mesure | Implémentation |
|---|---|
| Administration restreinte | SSH et 6443 ouverts uniquement depuis `admin_cidr` (validation : `0.0.0.0/0` refusé) |
| IMDSv2 obligatoire | `http_tokens = "required"`, hop limit 1 : vol d'identifiants via SSRF bloqué |
| Disque chiffré | `encrypted = true` (gp3) |
| Groupe de sécurité par défaut verrouillé | `aws_default_security_group` sans règle (CIS AWS 5.4) |
| Pas d'IP publique automatique | `map_public_ip_on_launch = false`, IP publique explicite pour le seul nœud |
| Traçabilité réseau | VPC Flow Logs → CloudWatch, rôle IAM limité au groupe de logs |
| Étiquettes | `default_tags` (projet, environnement, ManagedBy) |

### Exceptions IaC en vigueur

| Règle Trivy | Ressource | Justification | Alternative de production |
|---|---|---|---|
| AWS-0104 (CRITICAL) — sortie vers 0.0.0.0/0 | Règles de sortie 80/443 | Le nœud doit joindre GHCR, les dépôts APT et GitHub, dont les IP changent ; seuls les ports 80/443 sont ouverts, DNS limité au résolveur du VPC | Proxy de sortie filtrant, VPC endpoints, NAT avec inspection |

**Risque accepté (LOW, non bloquant, non masqué)** : AWS-0017, groupe de logs non chiffré par une clé
KMS gérée par le client. CloudWatch Logs chiffre déjà au repos avec une clé gérée par AWS. Une clé
KMS dédiée ajoute un coût mensuel, injustifié pour une démonstration.

**Vérification de l'efficacité des exceptions** : le module a été scanné sans aucun commentaire
`trivy:ignore`. Seule AWS-0104 se déclenchait. Les exceptions initialement prévues pour AWS-0107 et
AWS-0009 ont été retirées, car elles ne correspondaient à aucun constat réel.

## 5. Durcissement de l'hôte (Ansible) — périmètre « inspiré CIS »

| Domaine | Appliqué | Référence |
|---|---|---|
| Mises à jour de sécurité automatiques | `unattended-upgrades` | CIS Ubuntu 1.9 |
| Paramètres réseau (redirections ICMP, source routing, martians, syncookies) | sysctl | CIS Ubuntu 3.3.x |
| ASLR, `dmesg_restrict`, pas de core dump setuid | sysctl | CIS Ubuntu 1.5.x |
| Pare-feu : refus par défaut en entrée | UFW | CIS Ubuntu 3.5.1.x |
| SSH : root interdit, clés uniquement, 3 essais, pas de redirections | drop-in sshd (si serveur SSH présent) | CIS Ubuntu 5.2.x |
| k3s : Secrets chiffrés au repos | `secrets-encryption: true` | CIS Kubernetes 1.2.x (guide k3s) |
| k3s : kubelet protégeant les paramètres noyau | `protect-kernel-defaults: true` | CIS Kubernetes 4.2.6 |
| k3s : journal d'audit de l'API | politique Metadata, rotation | CIS Kubernetes 1.2.16–1.2.19 / 3.2.1 |
| kubeconfig non lisible par les autres utilisateurs | mode 0600 | CIS Kubernetes 4.1.x |
| Installation de k3s vérifiée | script figé au tag + SHA-256, binaire vérifié par le script | Chaîne d'approvisionnement |

**Hors périmètre** (documenté, non appliqué) : partitionnement séparé (`/tmp`, `/var`), auditd et
AIDE, AppArmor personnalisé, politique de mots de passe PAM, désactivation des modules noyau
inutilisés, benchmark CIS complet avec un outil de conformité (kube-bench, Lynis, OpenSCAP). Ces
mesures sont pertinentes pour un serveur de production, mais disproportionnées ou risquées pour une
VM de bureau partagée avec l'environnement graphique.

## 6. Kubernetes

| Mesure | Implémentation | Vérification |
|---|---|---|
| Pod Security Admission | `restricted` sur les namespaces applicatifs (Terraform) | Pod non conforme refusé |
| securityContext | non-root, UID > 10000, `drop: ALL`, `allowPrivilegeEscalation: false`, seccomp RuntimeDefault, rootfs en lecture seule | `id`, `touch /` |
| Jeton d'API | `automountServiceAccountToken: false`, ServiceAccount dédié | `/var/run/secrets/kubernetes.io` absent |
| Réseau | NetworkPolicy deny-all + flux explicites (DNS, Traefik→frontend, frontend→api, monitoring→api, api→db) | Matrice de 7 flux + contrôle positif |
| Ressources | requests/limits sur chaque conteneur, ResourceQuota et LimitRange par namespace | Quota : 20 répliques demandées, 2 créées |
| Secrets | Secret créé hors du chart (`existingSecret`), mot de passe généré, jamais affiché ; chiffré au repos par k3s (`secrets-encryption`) | `helm get values` ne contient aucun secret |
| Secrets dans Git | SealedSecret (portée strict), Phase 6 | Chiffré rejoué ailleurs : refusé |

**Limites** : un Secret Kubernetes n'est qu'encodé en Base64 dans les manifestes, ce qui **n'est pas un chiffrement**.
Le chiffrement au repos de k3s protège la base de données du cluster, pas l'accès via l'API : toute
personne autorisée à lire les Secrets du namespace (RBAC) voit le mot de passe en clair.
Pas de TLS sur l'Ingress local (perspective : cert-manager).

### Exceptions Kubernetes

| Règle | Fichier | Justification | Expiration |
|---|---|---|---|
| KSV-01010 (MEDIUM) | `templates/configmap.yaml` | Faux positif sur les noms de clés `DB_PORT`, `LOG_LEVEL` ; aucune donnée sensible | 2027-04-14 |

Mécanisme : `.trivyignore.yaml`, exception limitée à **une règle et un fichier**, avec justification et
expiration. Après la date, la règle redevient active et doit être réévaluée.

## 7. Pipeline CI et chaîne d'approvisionnement

| Contrôle | Outil | Bloquant | Périmètre |
|---|---|---|---|
| Secrets | Gitleaks 8.30.1 | Oui (tout constat) | Tout l'historique Git |
| SAST | Semgrep 1.178.0 | Oui (tout constat) | Python, JS, Dockerfile, secrets |
| SCA (dépendances) | Trivy fs | Oui (HIGH/CRITICAL corrigeables) | `requirements.txt` |
| IaC | Trivy config, terraform validate, helm lint, ansible-lint | Oui | Terraform, chart rendu, Dockerfiles, rôles |
| Image | Trivy image | Oui (HIGH/CRITICAL corrigeables) | Paquets OS et Python de l'image |
| SBOM | Trivy (CycloneDX) | Non (artefact) | Inventaire des composants de l'image |

- Permissions GitHub : `{}` par défaut ; écriture uniquement pour la publication GHCR et le commit GitOps.
- Actions épinglées par SHA ; outils installés avec SHA-256 vérifiée ; versions avec ≥ 2 semaines de recul.
- Aucun secret GitHub nécessaire pour le pipeline (GHCR et commit GitOps via `GITHUB_TOKEN` éphémère).
- Base PostgreSQL de test : authentification `trust`, conteneur éphémère interne au runner (aucun
  mot de passe factice dans le dépôt).

## 8. GitOps (Argo CD, Sealed Secrets)

| Mesure | Implémentation |
|---|---|
| CI sans accès au cluster | Modèle pull : la CI écrit dans Git, seul Argo CD (dans le cluster) applique |
| Périmètre Argo CD | AppProject : 1 dépôt source, 2 namespaces, aucune ressource cluster, liste blanche de types |
| Dérives | self-heal (corrigées en 1,7 à 6,1 s), prune |
| Secrets | Sealed Secrets, portée strict ; clé publique seule nécessaire pour chiffrer |
| Interface Argo CD | Pas d'Ingress : `kubectl port-forward` (TLS auto-signé) ; terminal web désactivé (`exec.enabled: false`) ; SSO (Dex) désactivé |
| Versions | Argo CD 3.5.4 : **exception à la règle des 2 semaines**, car 3.5.3 est affectée par 4 CVE critiques (GHSA-fmxq…, -m3vr…, -fw5c…, -9v9p…) |

**Compte admin Argo CD** : mot de passe initial aléatoire dans le Secret `argocd-initial-admin-secret`
(à récupérer soi-même, à changer, puis supprimer le Secret initial). Amélioration : SSO + RBAC.

**Sauvegarde de la clé Sealed Secrets** (indispensable, hors Git, stockage chiffré) :
`kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > cle-sealed-secrets.yaml`

### Exception Gitleaks

| Exception | Portée | Justification | Contrôles |
|---|---|---|---|
| Ligne `sealedPassword: "Ag…"` (≥ 300 caractères base64) | Toute ligne au format exact d'un chiffré kubeseal | Valeur chiffrée, conçue pour être publiée | Un `password:` en clair dans le même fichier → détecté ; `sealedPassword` court en clair → détecté |

### Re-chiffrer un secret (rotation)

```bash
openssl rand -base64 24 | tr -d '/+=\n' | kubeseal --raw --scope strict \
  --namespace plateforme-dev --name plateforme-db --from-file=/dev/stdin
# Coller le résultat dans k8s/environments/dev/values.yaml (database.sealedPassword), commit, push.
# Attention : changer le mot de passe exige aussi de le changer DANS PostgreSQL (ALTER ROLE),
# sinon l'API ne pourra plus se connecter.
```
