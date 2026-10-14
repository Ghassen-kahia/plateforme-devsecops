# --- Nœud k3s (EC2) ------------------------------------------------------------

# Dernière AMI Ubuntu 24.04 LTS officielle (compte Canonical)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "admin" {
  key_name   = "${var.project}-admin"
  public_key = var.ssh_public_key
}

# Un nœud k3s unique exposé sans load balancer a besoin d'une IP publique.
# Alternative de production : sous-réseau privé + ALB/NLB + bastion ou SSM Session Manager.
resource "aws_instance" "k3s" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.k3s.id]
  key_name                    = aws_key_pair.admin.key_name
  associate_public_ip_address = true

  # IMDSv2 obligatoire : protège les identifiants de l'instance contre les attaques SSRF
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  # La configuration (durcissement, UFW, k3s) est faite par Ansible, pas par user_data :
  # même procédure pour la VM locale et pour EC2, et exécution idempotente et rejouable.

  tags = { Name = "${var.project}-k3s" }

  lifecycle {
    # Une nouvelle AMI publiée ne doit pas recréer l'instance à chaque plan
    ignore_changes = [ami]
  }
}
