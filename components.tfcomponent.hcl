required_providers {
  kubernetes = {
    source  = "hashicorp/kubernetes"
    version = "~> 2.0" # Use a recent version compatible with your Stack
  }
}

provider "kubernetes" "this" {
  # Configuration is handled via the in-cluster service account
  # No explicit config block is needed if using in-cluster config.
  config {}
}

component "frontend" {
  source = "./modules/frontend"
  inputs = {
    namespace = var.environment
    replicas  = var.frontend_replicas
  }
  providers = { kubernetes = provider.kubernetes.this }
}

component "backend" {
  source = "./modules/backend"
  inputs = {
    namespace = var.environment
    replicas  = var.backend_replicas
  }
  providers = { kubernetes = provider.kubernetes.this }
}

component "database" {
  source    = "./modules/database"
  inputs    = { namespace = var.environment }
  providers = { kubernetes = provider.kubernetes.this }
}

variable "environment" {
  type = string
}

variable "frontend_replicas" {
  type    = number
  default = 1
}

variable "backend_replicas" {
  type    = number
  default = 1
}
