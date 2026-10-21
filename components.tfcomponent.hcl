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
  source  = "./modules/database"
  inputs  = { namespace = var.environment }
  providers = { kubernetes = provider.kubernetes.this }
}

variable "environment"       { type = string }
variable "frontend_replicas" { type = number, default = 1 }
variable "backend_replicas"  { type = number, default = 1 }
