# Versions figées : un `terraform init` dans 6 mois produira le même résultat.
# Le fichier .terraform.lock.hcl (commité) fixe en plus les sommes de contrôle des providers.
terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }

  # État local par défaut (projet de démonstration, jamais appliqué sans accord).
  # En équipe : backend S3 avec verrouillage natif (use_lockfile) et chiffrement, par exemple :
  # backend "s3" {
  #   bucket       = "<bucket-etat-terraform>"
  #   key          = "plateforme/aws/terraform.tfstate"
  #   region       = "eu-west-3"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  # Étiquettes appliquées à toutes les ressources : traçabilité des coûts et du propriétaire
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
