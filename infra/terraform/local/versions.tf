terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.3"
    }
  }
  # État local : environnement de démonstration mono-utilisateur sur la VM.
}

# Connexion au cluster k3s local via le kubeconfig de l'utilisateur (créé par Ansible, rôle k3s).
provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}
