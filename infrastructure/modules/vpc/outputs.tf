# Downstream modules and environments/dev/main.tf consume these.

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

output "public_subnet_id" {
  description = "ID of the public subnet"
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "ID of the private subnet (SageMaker Domain and Glue job workers)"
  value       = aws_subnet.private.id
}

output "security_group_id" {
  description = "ID of the SageMaker security group"
  value       = aws_security_group.this.id
}

output "internet_gateway_id" {
  description = "ID of the internet gateway attached to the VPC"
  value       = aws_internet_gateway.this.id
}

output "public_route_table_id" {
  description = "ID of the public route table associated with the public subnet"
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "ID of the private route table associated with the private subnet"
  value       = aws_route_table.private.id
}

output "nat_gateway_id" {
  description = "ID of the NAT Gateway, or null when enable_nat_gateway is false"
  value       = one(aws_nat_gateway.this[*].id)
}

output "glue_security_group_id" {
  description = "ID of the self-referencing security group Glue jobs attach inside the VPC"
  value       = aws_security_group.glue.id
}
