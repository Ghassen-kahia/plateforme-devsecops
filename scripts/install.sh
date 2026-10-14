#!/usr/bin/env bash
# =============================================================================
# install.sh — Installation progressive des prérequis de la plateforme DevSecOps
# =============================================================================
# Usage :
#   sudo bash scripts/install.sh base      # Phase 0 : Docker Engine + Compose, Python venv
#   sudo bash scripts/install.sh scan      # Phase 2 : Trivy (scan d'images, IaC, secrets)
#   sudo bash scripts/install.sh iac       # Phase 3 : Terraform, Ansible, ansible-lint
#   sudo bash scripts/install.sh k8s       # Phase 4 : kubectl (version alignée sur k3s), Helm
#   sudo bash scripts/install.sh check     # Vérification (sans sudo possible)
#
# Principes :
#   - Idempotent : relancer le script ne casse rien (les paquets déjà présents sont ignorés).
#   - Sources officielles uniquement (dépôt APT de Docker signé par clé GPG).
#   - Chaque phase ajoutera sa propre cible (ex. "k8s", "iac") au moment où elle est nécessaire.
#   - Aucune erreur masquée : `set -euo pipefail` arrête le script à la première erreur.
# =============================================================================
set -euo pipefail

log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[erreur]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || fail "Cette cible nécessite les droits root : relancer avec sudo."
}

# Utilisateur réel ayant lancé sudo (pour l'ajouter au groupe docker)
TARGET_USER="${SUDO_USER:-$USER}"

install_base_packages() {
  log "Mise à jour de l'index APT et installation des paquets de base"
  apt-get update -q
  # python3-venv / python3-pip : environnements virtuels pour FastAPI et pytest (Phase 1)
  # ca-certificates, curl, gnupg : nécessaires pour vérifier la signature du dépôt Docker
  apt-get install -y -q ca-certificates curl gnupg python3-venv python3-pip make
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker déjà présent : $(docker --version) — étape ignorée"
  else
    log "Ajout du dépôt APT officiel de Docker (clé GPG vérifiée)"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # shellcheck disable=SC1091
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update -q
    apt-get install -y -q docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
  fi

  systemctl enable --now docker

  # Le groupe docker donne un accès équivalent à root sur la machine.
  # Choix assumé pour une VM de développement personnelle (voir docs/apprentissage.md).
  if id -nG "$TARGET_USER" | grep -qw docker; then
    log "$TARGET_USER est déjà membre du groupe docker"
  else
    usermod -aG docker "$TARGET_USER"
    log "$TARGET_USER ajouté au groupe docker — se déconnecter/reconnecter (ou 'newgrp docker')"
  fi
}

# Ajoute un dépôt APT signé : $1 = nom, $2 = URL de la clé, $3 = ligne "deb" (sans signed-by)
add_apt_repo() {
  local name=$1 key_url=$2 deb_line=$3
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "$key_url" | gpg --dearmor --yes -o "/etc/apt/keyrings/${name}.gpg"
  chmod a+r "/etc/apt/keyrings/${name}.gpg"
  echo "deb [signed-by=/etc/apt/keyrings/${name}.gpg] ${deb_line}" > "/etc/apt/sources.list.d/${name}.list"
}

install_trivy() {
  if command -v trivy >/dev/null 2>&1; then
    log "Trivy déjà présent : $(trivy --version | head -1) — étape ignorée"
    return
  fi
  log "Installation de Trivy depuis le dépôt APT officiel d'Aqua Security"
  add_apt_repo trivy https://get.trivy.dev/deb/public.key \
    "https://get.trivy.dev/deb generic main"
  apt-get update -q
  apt-get install -y -q trivy
}

install_iac() {
  if command -v terraform >/dev/null 2>&1; then
    log "Terraform déjà présent : $(terraform version | head -1) — étape ignorée"
  else
    log "Installation de Terraform depuis le dépôt APT officiel de HashiCorp"
    # shellcheck disable=SC1091
    . /etc/os-release
    add_apt_repo hashicorp https://apt.releases.hashicorp.com/gpg \
      "https://apt.releases.hashicorp.com ${VERSION_CODENAME} main"
    apt-get update -q
    apt-get install -y -q terraform
  fi
  # Ansible et ansible-lint : versions des dépôts Ubuntu (stables, mises à jour de sécurité Ubuntu)
  log "Installation d'Ansible et d'ansible-lint (dépôts Ubuntu)"
  apt-get install -y -q ansible ansible-lint
}

# Branche mineure de Kubernetes alignée sur k3s (kubectl supporte ±1 version mineure)
KUBE_MINOR="v1.36"

install_k8s_tools() {
  log "Installation de kubectl ${KUBE_MINOR} (dépôt officiel pkgs.k8s.io)"
  add_apt_repo kubernetes "https://pkgs.k8s.io/core:/stable:/${KUBE_MINOR}/deb/Release.key" \
    "https://pkgs.k8s.io/core:/stable:/${KUBE_MINOR}/deb/ /"
  log "Installation de Helm (dépôt APT officiel du projet Helm)"
  add_apt_repo helm https://packages.buildkite.com/helm-linux/helm-debian/gpgkey \
    "https://packages.buildkite.com/helm-linux/helm-debian/any/ any main"
  apt-get update -q
  apt-get install -y -q kubectl helm
}

check() {
  log "Vérification des prérequis"
  local ok=0
  for t in git docker python3 curl jq make; do
    if command -v "$t" >/dev/null 2>&1; then printf '  %-10s OK\n' "$t"
    else printf '  %-10s ABSENT\n' "$t"; ok=1; fi
  done
  docker compose version >/dev/null 2>&1 && echo "  compose    OK" || { echo "  compose    ABSENT"; ok=1; }
  python3 -c 'import venv, ensurepip' 2>/dev/null && echo "  venv       OK" || { echo "  venv       ABSENT"; ok=1; }
  return $ok
}

case "${1:-}" in
  base)
    require_root
    install_base_packages
    install_docker
    check
    ;;
  scan)
    require_root
    install_trivy
    trivy --version | head -1
    ;;
  iac)
    require_root
    install_iac
    terraform version | head -1
    ansible --version | head -1
    ;;
  k8s)
    require_root
    install_k8s_tools
    kubectl version --client | head -1
    helm version --short
    ;;
  check)
    check
    ;;
  *)
    echo "Usage : sudo bash $0 base|scan|iac|k8s  |  bash $0 check"
    exit 2
    ;;
esac
