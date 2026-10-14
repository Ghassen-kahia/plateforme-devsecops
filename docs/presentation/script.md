# Script oral — soutenance (≈ 10 minutes)

Support : `presentation.pdf` / `presentation.pptx` (14 diapositives).
Rythme visé : environ 130 mots par minute. Le minutage cumulé est indiqué entre crochets.
Durée calculée : 1 079 mots prononcés ≈ 8 min 20, + transitions (≈ 45 s) + démonstration en direct (≈ 30 s) ≈ **10 min**.
Conseil : ne pas lire. Retenir l'**idée forte** de chaque diapositive et les **chiffres en gras**.

---

## 1. Titre — [0:00 → 0:30]

> Bonjour. Je vais vous présenter un projet personnel : une plateforme DevSecOps qui emmène une
> application du `git push` jusqu'à la production sur Kubernetes, de façon automatisée, sécurisée et
> supervisée. Le fil conducteur, c'est le sous-titre : **tout ce que je vais vous montrer a été mesuré**.

*Transition :* « Partons du problème. »

## 2. Contexte et problématique — [0:30 → 1:20]

> Imaginons une équipe qui déploie à la main. Chaque déploiement est une suite de commandes : c'est
> répétitif, donc source d'erreurs. Il n'y a aucun contrôle de sécurité : un mot de passe commité ou
> une bibliothèque vulnérable peuvent arriver en production. Et sans supervision, ce sont les clients
> qui découvrent les pannes.
> D'où ma problématique : comment automatiser ce déploiement de façon reproductible, avec des
> contrôles **qui bloquent vraiment**, un rollback vérifié et des alertes, sans aucun coût ?

*Transition :* « J'ai traduit cela en objectifs vérifiables. »

## 3. Objectifs et contraintes — [1:20 → 2:00]

> Chaque objectif a un critère de réussite. Le plus important à mes yeux : la sécurité doit être
> démontrée par des cas qui **doivent** échouer. Un scanner qui ne remonte rien ne prouve rien.
> Côté contraintes : une VM avec **2 vCPU**, un cluster k3s à un nœud et zéro euro. J'ai aussi écrit
> un module Terraform pour AWS, validé mais **volontairement jamais appliqué**, pour rester à coût nul.

*Transition :* « Voici l'architecture qui en découle. »

## 4. Architecture — [2:00 → 3:00]

> De gauche à droite : un `git push` déclenche la CI GitHub Actions, qui teste, analyse et construit
> l'image, puis la scanne. Si tout passe, l'image est publiée dans GHCR avec un tag immuable, le SHA
> du commit, et la CI écrit la nouvelle version dans Git.
> Le point clé est à droite : c'est **Argo CD, dans le cluster, qui vient lire Git** et appliquer
> l'état désiré. La CI n'a **aucun accès** au cluster. C'est le modèle *pull* de GitOps : même si la
> CI était compromise, elle ne pourrait pas toucher directement à la production.

**Point technique à souligner :** push contre pull, et absence de kubeconfig dans GitHub.

*Transition :* « Pourquoi ces outils-là ? »

## 5. Choix techniques — [3:00 → 3:50]

> Chaque choix répond à une contrainte. k3s plutôt que minikube, parce qu'il est léger et inclut
> l'Ingress et les NetworkPolicy. GitHub Actions plutôt que Jenkins : pas de serveur à maintenir et
> des jetons éphémères. Semgrep plutôt que SonarQube, qui demanderait environ 2 Go de RAM. Argo CD
> pour son interface et ses AppProjects, qui appliquent le moindre privilège à l'outil de déploiement
> lui-même.

*Transition :* « Regardons le pipeline en détail. »

## 6. Pipeline CI DevSecOps — [3:50 → 4:50]

> Quatre contrôles tournent en parallèle : tests avec une vraie base PostgreSQL, Gitleaks pour les
> secrets, Semgrep pour le code, et Trivy pour l'infrastructure et les dépendances. L'image n'est
> construite que si tout est vert, puis Trivy la scanne : une vulnérabilité HIGH ou CRITICAL **qui a
> un correctif** bloque la publication.
> J'ai aussi sécurisé le pipeline lui-même : aucune permission par défaut, et des actions épinglées par
> SHA, parce qu'un tag peut être déplacé par un attaquant. J'ai choisi des versions d'outils ayant au
> moins deux semaines de recul, **sauf** pour Argo CD : la version « mûre » avait quatre CVE critiques.
> Une règle de prudence ne doit jamais l'emporter sur un correctif de sécurité.

*Transition :* « Mais est-ce que ça bloque vraiment ? »

## 7. Les contrôles bloquent vraiment — [4:50 → 5:50]

> Je l'ai prouvé avec des cas réels. La PR numéro 1 contenait une fausse clé d'API : bloquée par
> Gitleaks, et la valeur est masquée dans les logs. La PR numéro 2 ajoutait une version de PyYAML avec
> une CVE critique : bloquée par Trivy. Un pod root est refusé par le cluster. Et pour les NetworkPolicy,
> j'ai fait un contrôle positif : le même flux passe sans la politique et est bloqué avec, ce qui prouve
> que la règle est réellement appliquée.
> Sur l'image de l'API, on passe de **3 695 à 166 vulnérabilités**, avec **zéro critique**, et de
> **1,7 Go à 221 Mo**.

*Transition :* « Une fois l'image validée, comment arrive-t-elle en production ? »

## 8. Déploiement GitOps — [5:50 → 6:50]

> Argo CD compare Git et le cluster en continu. Dev se met à jour automatiquement ; la prod reçoit la
> **même image**, déjà scannée, par une promotion manuelle. Les secrets sont dans Git, mais chiffrés
> avec Sealed Secrets : seul le cluster peut les déchiffrer.
> Résultats : **189 secondes** du push à la nouvelle version, sans intervention ; un rollback par
> `git revert` en **89 secondes**, sans une seule erreur sur 1 460 requêtes ; et si quelqu'un supprime
> une NetworkPolicy à la main, Argo CD la rétablit en **2 secondes**.

**Point technique à souligner :** un rollback GitOps est un `git revert`, et non un `kubectl rollout undo`.
J'ai démontré que ce dernier crée un état incohérent.

*Transition :* « Il reste à savoir quand quelque chose casse. »

## 9. Supervision et panne contrôlée — [6:50 → 7:40]

> Quatre alertes : une sur la cause (la base), une sur le symptôme (l'API), une sur l'expérience
> utilisateur et une sur la latence. Un détail important : les erreurs 5xx sont mesurées **à l'Ingress**.
> Quand l'API tombe, elle ne reçoit plus les requêtes, et ses propres métriques ne voient rien.
> J'ai provoqué une panne de base de données par un commit Git : la première alerte arrive en
> **63 secondes** et les trois alertes critiques en **94 secondes**.

*Transition :* « Je peux vous le montrer en direct. »

## 10. Démonstration — [7:40 → 8:10] (ou démonstration en direct si le temps le permet)

> Le script `demo.sh` rejoue ces scénarios : état de la plateforme, contrôles de sécurité en direct,
> dérive corrigée par Argo CD et panne contrôlée.

*En direct (≈ 30 s) :* lancer `bash scripts/demo.sh derive` : « je modifie le cluster à la main… et
Argo CD le remet en conformité avec Git en quelques secondes. »
*Plan B si pas de réseau ni de VM :* montrer les captures de la diapositive.

## 11. Résultats mesurés — [8:10 → 8:50]

> En résumé : le déploiement automatisé n'est pas plus rapide que les commandes manuelles, et ce
> n'était pas le but. Pour un délai comparable, il exécute 20 tests et 5 analyses de sécurité, sans
> intervention, avec une traçabilité complète. Les pannes sont détectées en une à deux minutes, et les
> mises à jour se font **sans erreur sur plus de 3 300 requêtes**.

*Transition :* « Ces résultats n'ont pas été obtenus du premier coup. »

## 12. Difficultés et solutions — [8:50 → 9:40]

> Trois exemples. Des erreurs 502 apparaissaient pendant les déploiements : en corrélant les logs, j'ai
> trouvé que PostgreSQL redémarrait à chaque release à cause d'un simple label. Ensuite, des 502
> pendant les mises à jour réussies : c'est la course classique entre l'arrêt du pod et sa sortie du
> load balancer, corrigée par un `preStop`.
> Et j'assume une erreur de ma part : j'ai poussé un commit alors qu'une validation avait échoué. La CI
> l'a bloqué ; depuis, mes validations sont strictement chaînées. Enfin, la VM a été gelée par l'hôte,
> ce qui m'a appris qu'une supervision interne ne peut pas signaler la panne de sa propre machine.

## 13. Perspectives — [9:40 → 10:00]

> Les prochaines étapes : appliquer le module AWS et passer sur EKS, utiliser Vault pour les secrets,
> ajouter un service mesh pour le chiffrement entre services, et signer les images pour garantir leur
> provenance.

## 14. Conclusion — [10:00 → 10:15]

> Ce que je retiens : mesurer plutôt que supposer, prouver chaque contrôle par un cas qui doit échouer,
> et documenter les limites, y compris mes propres erreurs. Merci, je suis prêt pour vos questions.

---

## Questions probables et éléments de réponse

| Question | Éléments clés (détails : `docs/apprentissage.md`) |
|---|---|
| Pourquoi ne pas avoir déployé sur AWS ? | Coût ; code validé (fmt, validate, Trivy) ; limite assumée : seul un `apply` prouve tout |
| Que se passe-t-il si un vrai secret fuit ? | Révoquer et faire tourner d'abord ; supprimer le fichier ne suffit pas (démontré) |
| Pourquoi les CVE sans correctif ne bloquent-elles pas ? | Aucune action possible ; tracées, reconstruction régulière, exposition réduite (non-root, read-only) |
| Liveness vs readiness ? | La liveness ne teste pas la base ; démontré : 0 redémarrage quand la base tombe |
| Pourquoi le même dépôt pour le code et GitOps ? | Aucun secret supplémentaire ; limite : `main` non protégeable ; cible : dépôt séparé |
| Votre plateforme tient-elle sur 2 vCPU ? | Oui, mais environ 70 % du CPU est utilisé au repos ; un incident l'a montré ; 4 vCPU recommandés |
| Argo CD ou Flux ? | Les deux sont diplômés CNCF ; Argo CD pour l'interface et les AppProjects |

## Points d'attention

- Dire « **projet personnel** », jamais « en entreprise ».
- Ne citer que des chiffres de `docs/mesures.md`, en précisant si besoin « mesure ponctuelle ».
- Garder la démonstration courte et avoir le plan B (captures) prêt.
