# ── modules/vpc ──────────────────────────────────────────────────────────────
# Network boundary for the NorthStar platform.
#
#   aws_vpc                      northstar-dev-vpc          10.0.0.0/16
#   aws_subnet                   northstar-dev-public-1     10.0.100.0/24, us-east-1a
#   aws_subnet                   northstar-dev-private-1    10.0.1.0/24, us-east-1a  (Lab 2)
#   aws_internet_gateway         northstar-dev-igw
#   aws_eip                      northstar-dev-eip                                      (Lab 2)
#   aws_nat_gateway              northstar-dev-nat          in the public subnet       (Lab 2)
#   aws_route_table              northstar-dev-public-rt    0.0.0.0/0 -> igw
#   aws_route_table              northstar-dev-private-rt   0.0.0.0/0 -> nat           (Lab 2)
#   aws_route_table_association  attaches each subnet to its own route table
#   aws_security_group           northstar-dev-sagemaker-sg
#   aws_security_group           northstar-dev-glue-sg      self-referencing           (Lab 2)
#
# Every name is built from var.project and var.environment — nothing under
# modules/ hardcodes a project-environment literal.
#
# Lab 2 moves Studio and the Glue workers into the private subnet. That subnet
# has no inbound route from the internet; its outbound traffic goes
# public subnet -> NAT Gateway -> Internet Gateway. Setting
# var.enable_nat_gateway = false (environments/local, where LocalStack creates
# no NAT Gateway) leaves the private subnet with no default route at all, which
# is what an isolated subnet should look like.

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

  # The public subnet now exists mainly to anchor the NAT Gateway: Studio and
  # the Glue workers moved to the private subnet in Lab 2. Public IPs stay
  # enabled so anything launched here reaches the internet through the IGW.
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-${var.environment}-public-1"
    Tier = "public"
  }
}

# New in Lab 2. No public IP on launch: nothing here is reachable from the
# internet, and Glue workers plus the SageMaker Domain only need outbound
# access, which they get through the NAT Gateway in the public subnet.
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.availability_zone

  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project}-${var.environment}-private-1"
    Tier = "private"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project}-${var.environment}-igw"
  }
}

# ── NAT Gateway (Lab 2) ──────────────────────────────────────────────────────
# The Elastic IP is the public address the NAT Gateway translates private
# subnet traffic into. Both resources are gated on var.enable_nat_gateway so
# LocalStack (which does not emulate a usable NAT path) can skip them entirely.
resource "aws_eip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  # Required for a VPC-attached Elastic IP.
  domain = "vpc"

  tags = {
    Name = "${var.project}-${var.environment}-eip"
  }
}

resource "aws_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public.id

  # A NAT Gateway is useless until the IGW exists, and AWS rejects the create
  # otherwise. The explicit dependency is what guarantees that ordering.
  depends_on = [aws_internet_gateway.this]

  tags = {
    Name = "${var.project}-${var.environment}-nat"
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

# ── Private route table (Lab 2) ──────────────────────────────────────────────
# The route table itself always exists so the private subnet is explicitly
# associated and inspectable. The default route is added only when a NAT
# Gateway exists: with enable_nat_gateway = false there is nothing to point at,
# and the subnet is simply isolated from the internet.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []

    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[0].id
    }
  }

  tags = {
    Name = "${var.project}-${var.environment}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
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

# New in Lab 2. AWS Glue refuses to place a job's ENIs unless one of the
# attached security groups opens all ports and all protocols TO ITSELF. A rule
# whose source is the VPC CIDR does not satisfy that check -- the source has to
# literally be this security group, which is what `self = true` writes. Glue
# attaches this SG when the modules/glue/ jobs run inside the private subnet.
resource "aws_security_group" "glue" {
  name        = "${var.project}-${var.environment}-glue-sg"
  description = "Glue job ENIs: self-referencing all-ports ingress required inside a VPC"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "Glue worker-to-worker traffic (self-reference, all ports)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # Declared explicitly so Terraform does not revoke AWS's default egress
  # rule. Glue needs it to reach S3, the Glue API, and CloudWatch Logs through
  # the NAT Gateway.
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project}-${var.environment}-glue-sg"
  }
}
