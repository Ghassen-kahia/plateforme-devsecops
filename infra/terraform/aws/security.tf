# --- Groupe de sécurité du nœud k3s --------------------------------------------
# Principe : seul le trafic web (80/443) est public ; l'administration (SSH, API Kubernetes)
# est restreinte à l'IP de l'administrateur.

resource "aws_security_group" "k3s" {
  name        = "${var.project}-k3s"
  description = "Noeud k3s : web public, administration restreinte"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-k3s" }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.k3s.id
  description       = "SSH depuis l'administrateur uniquement"
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "kube_api" {
  security_group_id = aws_security_group.k3s.id
  description       = "API Kubernetes depuis l'administrateur uniquement"
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
}

# Le service web doit être accessible publiquement (seuls 80/443 sont ouverts à tous).
resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.k3s.id
  description       = "HTTP public (redirection vers HTTPS par Traefik)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.k3s.id
  description       = "HTTPS public"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# Exception documentée : le nœud doit joindre GHCR, les dépôts APT et get.k3s.io, dont les IP
# ne sont pas fixes. Restreindre davantage nécessiterait un proxy de sortie ou des VPC endpoints.
# trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "https_out" {
  security_group_id = aws_security_group.k3s.id
  description       = "Sortie HTTPS (registres, depots de paquets)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "http_out" {
  security_group_id = aws_security_group.k3s.id
  description       = "Sortie HTTP (depots APT Ubuntu)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "dns_out" {
  security_group_id = aws_security_group.k3s.id
  description       = "DNS vers le resolveur du VPC"
  cidr_ipv4         = "${cidrhost(var.vpc_cidr, 2)}/32"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
}
