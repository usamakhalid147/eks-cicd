terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "4.55.0"
    }
  }
}

provider "aws" {
  region = "us-east-1" # change this to your desired region
}

// Create a VPC
resource "aws_vpc" "my_vpc" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true

  tags = {
    Name = "my-vpc"
  }
}

// Create public and private subnets in the VPC
resource "aws_subnet" "public" {
  count = 2
  cidr_block = "10.0.${count.index}.0/24"
  vpc_id = aws_vpc.my_vpc.id
  availability_zone = "us-west-2a"
  map_public_ip_on_launch = true

  tags = {
    Name = "public-${count.index}"
  }
}

resource "aws_subnet" "private" {
  count = 2
  cidr_block = "10.0.${count.index + 2}.0/24"
  vpc_id = aws_vpc.my_vpc.id
  availability_zone = "us-west-2a"

  tags = {
    Name = "private-${count.index}"
  }
}

// Create a NAT Gateway in a public subnet
resource "aws_eip" "nat" {
  vpc = true
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.my_vpc.id
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id = aws_subnet.public.0.id

  depends_on = [
    aws_internet_gateway.main,
  ]
}

// Create a route table for the private subnets
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.my_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "private"
  }
}

// Associate private subnets with the route table
resource "aws_route_table_association" "private" {
  count = 2
  subnet_id = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_eks_cluster" "my_cluster" {
  name     = "eks-webapp"
  role_arn = aws_iam_role.eks.arn

  vpc_config {
    subnet_ids = aws_subnet.private.*.id
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks,
  ]
}

resource "aws_iam_role" "eks" {
  name = "my-eks-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks.name
}

// Add ECR full access to the EKS worker nodes
resource "aws_iam_role_policy_attachment" "ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
  role       = aws_iam_role.eks.name
}

resource "aws_eks_node_group" "my_node_group" {
  cluster_name    = aws_eks_cluster.my_cluster.name
  node_group_name = "my-node-group"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = aws_subnet.private.*.id
  scaling_config {
    desired_size = 2
    max_size     = 2
    min_size     = 2
  }
  depends_on = [
    aws_iam_role_policy_attachment.eks_node_group,
  ]
}

resource "aws_iam_role" "eks_node_group" {
  name = "my-eks-node-group-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_node_group" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group.name
}
resource "aws_iam_role_policy_attachment" "ecr-node_group" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_instance_profile" "eks_node_group" {
  name = "my-eks-node-group-instance-profile"
  role = aws_iam_role.eks_node_group.name
}

resource "aws_security_group" "eks_node_group" {
  name_prefix = "my-eks-node-group"
  vpc_id      = aws_vpc.my_vpc.id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_launch_template" "eks_node_group" {
  name_prefix = "my-eks-node-group"
  image_id    = "ami-0885b1f6bd170450c"
  instance_type = "t3.medium"
  iam_instance_profile {
    name = aws_iam_instance_profile.eks_node_group.name
  }
  vpc_security_group_ids = [aws_security_group.eks_node_group.id]
}

resource "aws_autoscaling_group" "eks_node_group" {
  name = "my-eks-node-group"
  vpc_zone_identifier = aws_subnet.private.*.id
  launch_template {
    id = aws_launch_template.eks_node_group.id
    version = "$Latest"
  }
  min_size = 2
  max_size = 2
  desired_capacity = 2
}