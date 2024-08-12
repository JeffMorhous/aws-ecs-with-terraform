terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.56"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0.2"
    }
  }
}

# Configure AWS Provider
provider "aws" {
  region = "us-west-2"
}

# Data source for availability zones
data "aws_availability_zones" "available" { state = "available" }

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "~> 3.19.0"

  azs = slice(data.aws_availability_zones.available.names, 0, 2) # Span subnetworks across 2 avalibility zones
  cidr = "10.0.0.0/16"
  create_igw = true # Expose public subnetworks to the Internet
  enable_nat_gateway = true # Hide private subnetworks behind NAT Gateway
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets = ["10.0.101.0/24", "10.0.102.0/24"]
  single_nat_gateway = true
}

module "alb" {
 source  = "terraform-aws-modules/alb/aws"
 version = "~> 8.4.0"

 load_balancer_type = "application"
 security_groups = [module.vpc.default_security_group_id]
 subnets = module.vpc.public_subnets
 vpc_id = module.vpc.vpc_id

 security_group_rules = {
  ingress_all_http = {
   type        = "ingress"
   from_port   = 80
   to_port     = 80
   protocol    = "TCP"
   description = "Permit incoming HTTP requests"
   cidr_blocks = ["0.0.0.0/0"]
  }
  egress_all = {
   type        = "egress"
   from_port   = 0
   to_port     = 0
   protocol    = "-1"
   description = "Permit outgoing requests"
   cidr_blocks = ["0.0.0.0/0"]
  }
 }

 http_tcp_listeners = [
  {
   port               = 80
   protocol           = "HTTP"
   target_group_index = 0
  }
 ]

 target_groups = [
  {
   backend_port         = 80
   backend_protocol     = "HTTP"
   target_type          = "ip"
  }
 ]
}

module "ecs" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 4.1.3"

  cluster_name = "judoscale-example"

  fargate_capacity_providers = {
    FARGATE = {
      default_capacity_provider_strategy = {
      base   = 20
      weight = 50
      }
    }
    FARGATE_SPOT = {
      default_capacity_provider_strategy = {
      weight = 50
      }
    }
  }
}

data "aws_caller_identity" "this" {}
data "aws_ecr_authorization_token" "this" {}
data "aws_region" "this" {}
locals { ecr_address = format("%v.dkr.ecr.%v.amazonaws.com", data.aws_caller_identity.this.account_id, data.aws_region.this.name) }
provider "docker" {
  registry_auth {
    address  = local.ecr_address
    password = data.aws_ecr_authorization_token.this.password
    username = data.aws_ecr_authorization_token.this.user_name
  }
}

module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 1.6.0"

  repository_force_delete = true
  repository_name = "judoscale-example"
  repository_lifecycle_policy = jsonencode({
    rules = [{
      action = { type = "expire" }
      description = "Delete old images"
      rulePriority = 1
      selection = {
        countNumber = 3
        countType = "imageCountMoreThan"
        tagStatus = "any"
      }
    }]
  })
}

resource "docker_image" "exampleimage" {
  name = format("%v:%v", module.ecr.repository_url, formatdate("YYYY-MM-DD'T'hh-mm-ss", timestamp()))
  build { context = "." } # Path
}

resource "docker_registry_image" "exampleimage" {
  keep_remotely = false
  name = resource.docker_image.exampleimage.name
}

resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "ecsTaskExecutionRole"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role_policy.json}"
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = "${aws_iam_role.ecsTaskExecutionRole.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "this" {
  container_definitions = jsonencode([
    {
      essential = true,
      image = resource.docker_registry_image.exampleimage.name,
      name = "example-container",
      portMappings = [{ containerPort = 3000, hostPort = 3000 }],
    },
    {
      essential = true,
      image = "public.ecr.aws/b1e6w9f4/nginx-sidecar-start-header:latest",
      name = "nginx-sidecar",
      portMappings = [{ containerPort = 80, hostPort = 80 }],
    }
  ])
  cpu = 256
  execution_role_arn = "${aws_iam_role.ecsTaskExecutionRole.arn}"
  family = "family-of-judoscale-example-tasks"
  memory = 512
  network_mode = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  # Only set the below if building on an ARM64 computer like an Apple Silicon Mac
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }
}

resource "aws_ecs_service" "this" {
  cluster = module.ecs.cluster_id
  desired_count = 1
  launch_type = "FARGATE"
  name = "judoscale-example-service"
  task_definition = resource.aws_ecs_task_definition.this.arn

  lifecycle {
    ignore_changes = [desired_count]
  }

  load_balancer {
    container_name = "nginx-sidecar"
    container_port = 80
    target_group_arn = module.alb.target_group_arns[0]
  }

  network_configuration {
    security_groups = [module.vpc.default_security_group_id]
    subnets = module.vpc.private_subnets
  }
}

output "public-url" { value = "http://${module.alb.lb_dns_name}" }