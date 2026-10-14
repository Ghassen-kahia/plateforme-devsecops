variable "project" {
  description = "Nom du projet, utilisé comme préfixe des ressources."
  type        = string
  default     = "plateforme-devsecops"
}

variable "environment" {
  description = "Nom de l'environnement (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "region" {
  description = "Région AWS (eu-west-3 = Paris)."
  type        = string
  default     = "eu-west-3"
}

variable "vpc_cidr" {
  description = "Plage d'adresses du VPC."
  type        = string
  default     = "10.10.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr doit être un bloc CIDR valide."
  }
}

variable "public_subnet_cidr" {
  description = "Plage du sous-réseau public hébergeant le nœud k3s."
  type        = string
  default     = "10.10.1.0/24"
}

variable "admin_cidr" {
  description = "Adresse IP de l'administrateur (ex. 203.0.113.10/32), seule autorisée en SSH et sur l'API Kubernetes."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr doit être un CIDR valide et ne peut pas être 0.0.0.0/0."
  }
}

variable "instance_type" {
  description = "Type d'instance EC2. k3s + supervision nécessitent au moins 4 GiB de RAM."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size_gb" {
  description = "Taille du disque racine (Go)."
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_size_gb >= 20
    error_message = "Au moins 20 Go sont nécessaires pour k3s et les images."
  }
}

variable "ssh_public_key" {
  description = "Clé publique SSH (contenu de ~/.ssh/id_ed25519.pub). Une clé PUBLIQUE n'est pas un secret."
  type        = string
}

variable "enable_flow_logs" {
  description = "Active les VPC Flow Logs vers CloudWatch (traçabilité réseau ; coût d'ingestion des logs)."
  type        = bool
  default     = true
}

variable "flow_logs_retention_days" {
  description = "Durée de conservation des Flow Logs (jours)."
  type        = number
  default     = 30
}
