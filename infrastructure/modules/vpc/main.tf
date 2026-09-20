# ── modules/vpc ──────────────────────────────────────────────────────────────
# Network boundary for the NorthStar platform (Lab 1 — a single public subnet).
#
#   aws_vpc                      northstar-dev-vpc        10.0.0.0/16
#   aws_subnet                   northstar-dev-public-1   10.0.100.0/24, us-east-1a
#   aws_internet_gateway         northstar-dev-igw
#   aws_route_table              northstar-dev-public-rt  0.0.0.0/0 -> igw
#   aws_route_table_association  attaches the subnet to that route table
#   aws_security_group           northstar-dev-sagemaker-sg
#
# Every name is built from var.project and var.environment — nothing under
# modules/ hardcodes a project-environment literal.

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Studio apps resolve the SageMaker endpoints by DNS name, so both DNS
  # attributes are required (Component Specification).
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project}-${var.environment}-vpc"
  }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidr
  availability_zone = var.availability_zone

  # Studio and anything else launched here gets a public IP so it can reach
  # the internet through the IGW (no NAT Gateway until Lab 2).
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-${var.environment}-public-1"
    Tier = "public"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project}-${var.environment}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.project}-${var.environment}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Inbound is restricted to the VPC CIDR: Studio is reachable from inside the
# VPC only, never from the public internet. Egress is unrestricted so Studio
# can pull container images, reach S3, and serve its UI.
resource "aws_security_group" "this" {
  name        = "${var.project}-${var.environment}-sagemaker-sg"
  description = "SageMaker Studio traffic: inbound from the VPC CIDR only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "All traffic from within the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project}-${var.environment}-sagemaker-sg"
  }
}
