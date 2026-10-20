deployment "dev" {
  inputs = {
    environment       = "dev"
    frontend_replicas = 1
    backend_replicas  = 1
  }
}

deployment "staging" {
  inputs = {
    environment       = "staging"
    frontend_replicas = 2
    backend_replicas  = 2
  }
}
