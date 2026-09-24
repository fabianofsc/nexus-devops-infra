# configuração do provider
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# configurações de rede
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d", "us-east-1f"]
  }
}

# configurações de IAM - roles e polices
resource "aws_iam_role" "eks_cluster" {
  name = "eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "eks_node" {
  name = "eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.eks_node.name
  policy_arn = each.value
}

# configuração do Cluster k8s
resource "aws_eks_cluster" "main" {
  name     = "nexus-k8s-aula"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids = data.aws_subnets.default.ids
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "nexus-nodes"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = data.aws_subnets.default.ids
  instance_types  = ["t3.small"]
  disk_size       = 20

  scaling_config {
    min_size     = 1
    max_size     = 1
    desired_size = 1
  }

  depends_on = [aws_iam_role_policy_attachment.eks_node]
}

data "aws_caller_identity" "current" {}

resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_caller_identity.current.arn
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# Segunda Access Entry — 
# o Console é outro principal:** a entry acima só autoriza quem rodou o `apply` (`data.aws_caller_identity.current`). 
# O Console AWS aberto no navegador é uma sessão separada — se estiver logada com outro usuário/role, as abas **Recursos** e **Computação** do cluster mostram `Erro ao carregar recursos: Unauthorized`.
# resource "aws_eks_access_entry" "console_viewer" {
#   cluster_name  = aws_eks_cluster.main.name
#   principal_arn = "arn:aws:iam::<account-id>:user/<nome-do-usuario-do-console>"
# }

# resource "aws_eks_access_policy_association" "console_viewer" {
#   cluster_name  = aws_eks_cluster.main.name
#   principal_arn = aws_eks_access_entry.console_viewer.principal_arn
#   policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

#   access_scope {
#     type = "cluster"
#   }
# }

# configuração de RDS
resource "aws_security_group" "rds" {
  name_prefix = "nexus-rds-sg-"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_cluster" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_db_subnet_group" "main" {
  name       = "nexus-db-subnets"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "main" {
  identifier             = "nexus-payment-db"
  instance_class         = "db.t4g.micro"
  engine                 = "postgres"
  username               = "payment_app"
  password               = "troque-esta-senha"
  allocated_storage      = 20
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  db_name                = "nexus_payment"
  publicly_accessible    = false
  skip_final_snapshot    = true
}

output "rds_identifier" {
  value = aws_db_instance.main.identifier
}

output "rds_address" {
  value = aws_db_instance.main.address
}