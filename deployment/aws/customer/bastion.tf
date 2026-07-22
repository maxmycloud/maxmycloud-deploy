# Optional bastion for one-shot debug ops (mongorestore, ad-hoc DocDB queries).
# DocDB instances cannot be public (AWS limitation), so any developer-laptop
# DB access has to SSH-tunnel through a public EC2 host in the same VPC.
# Off by default (bastion_enabled = false) — customers don't need this in
# normal operation.

resource "tls_private_key" "bastion" {
  count     = var.bastion_enabled ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "bastion" {
  count      = var.bastion_enabled ? 1 : 0
  key_name   = "${local.name}-bastion"
  public_key = tls_private_key.bastion[0].public_key_openssh
}

resource "aws_security_group" "bastion" {
  count       = var.bastion_enabled ? 1 : 0
  name        = "${local.name}-bastion"
  description = "SSH from developer IP only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH from the dev IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.bastion_ingress_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "bastion" {
  count                       = var.bastion_enabled ? 1 : 0
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.nano"
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.bastion[0].id]
  key_name                    = aws_key_pair.bastion[0].key_name
  associate_public_ip_address = true
  tags                        = { Name = "${local.name}-bastion" }
}

# Allow the bastion to reach DocumentDB port 27017 (only when bastion exists)
resource "aws_security_group_rule" "docdb_from_bastion" {
  count                    = var.bastion_enabled ? 1 : 0
  type                     = "ingress"
  from_port                = 27017
  to_port                  = 27017
  protocol                 = "tcp"
  security_group_id        = aws_security_group.docdb.id
  source_security_group_id = aws_security_group.bastion[0].id
  description              = "DocDB from bastion"
}

output "bastion_public_ip" {
  value = try(aws_instance.bastion[0].public_ip, null)
}

output "bastion_private_key" {
  value     = try(tls_private_key.bastion[0].private_key_openssh, null)
  sensitive = true
}
