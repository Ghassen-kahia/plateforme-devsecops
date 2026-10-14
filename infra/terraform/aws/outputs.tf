output "instance_public_ip" {
  description = "IP publique du nœud k3s."
  value       = aws_instance.k3s.public_ip
}

output "vpc_id" {
  description = "Identifiant du VPC."
  value       = aws_vpc.main.id
}

output "ansible_inventory" {
  description = "Ligne d'inventaire Ansible à placer dans infra/ansible/inventory/aws.ini."
  value       = "k3s-aws ansible_host=${aws_instance.k3s.public_ip} ansible_user=ubuntu"
}
