# Plateforme DevSecOps de déploiement continu sur Kubernetes

Projet personnel de portfolio : une chaîne DevSecOps complète, locale et reproductible.
GitHub Actions → scans de sécurité → GHCR → Argo CD → k3s, avec une supervision Prometheus/Grafana.

> 🚧 Projet en cours de construction. Phases 0 à 3 terminées.
> Le détail des phases et l'état réel sont dans [`CLAUDE.md`](CLAUDE.md).

## Prérequis (Phase 0)

- Ubuntu 24.04, 2 vCPU minimum (4 recommandés), 8 GiB de RAM, 40 Go de disque libre.

```bash
sudo bash scripts/install.sh base   # Docker Engine, Compose, python3-venv, make
bash scripts/install.sh check       # vérification
```

## Documentation

- [Journal d'apprentissage](docs/apprentissage.md)
- [Indicateurs mesurés](docs/mesures.md)
- [Politique de sécurité](docs/securite.md)
