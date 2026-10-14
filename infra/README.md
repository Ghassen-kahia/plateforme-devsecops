# Infrastructure as Code

| Répertoire | Outil | Rôle | Appliqué ? |
|---|---|---|---|
| `terraform/local` | Terraform + provider Kubernetes | Socle du cluster k3s local : namespaces, Pod Security, quotas | Oui (Phase 4), gratuit |
| `terraform/aws` | Terraform + provider AWS | VPC, sous-réseau, groupe de sécurité, EC2 pour k3s | **Non : jamais sans accord explicite (coûts)** |
| `ansible` | Ansible | Paquets, sysctl, SSH, UFW, installation de k3s | VM locale (Phase 4) ; EC2 si créée |

## Procédure de provisionnement — VM locale

```bash
sudo bash scripts/install.sh iac                    # Terraform, Ansible, ansible-lint
cd infra/ansible
ansible-lint && ansible-playbook site.yml --syntax-check
ansible-playbook site.yml --check --diff            # exécution à blanc : ce qui changerait
ansible-playbook site.yml                           # application (idempotente)
cd ../terraform/local
terraform init && terraform plan && terraform apply # socle Kubernetes
```

## Procédure de provisionnement — AWS (non exécutée)

> ⚠️ Crée des ressources **facturées** : instance EC2 à l'heure, volume EBS, adresse IPv4 publique,
> ingestion et stockage des Flow Logs dans CloudWatch. Estimer le coût avec l'AWS Pricing Calculator
> avant de lancer quoi que ce soit, et détruire les ressources après usage (`terraform destroy`).

1. Identifiants : un utilisateur ou rôle IAM dédié, avec les seules permissions EC2, VPC, IAM (rôle
   des Flow Logs) et CloudWatch Logs. Fournis par `aws configure sso` ou des variables d'environnement,
   **jamais** dans les fichiers du dépôt.
2. `cd infra/terraform/aws && cp terraform.tfvars.example terraform.tfvars` puis renseigner `admin_cidr`
   (votre IP en /32) et `ssh_public_key`.
3. `terraform init && terraform plan -out=plan.tfplan` : relire le plan.
4. `terraform apply plan.tfplan`.
5. `terraform output ansible_inventory` → `infra/ansible/inventory/aws.yml` (voir `aws.example.yml`).
6. `ansible-playbook -i inventory/aws.yml site.yml`.
7. Après usage : `terraform destroy`.

## Validation statique (sans compte AWS)

```bash
terraform -chdir=infra/terraform/aws init -backend=false
terraform fmt -recursive -check infra/terraform
terraform -chdir=infra/terraform/aws validate
trivy config --config trivy.yaml infra/              # bloquant sur HIGH/CRITICAL
```
