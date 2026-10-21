deployment "production" {
  inputs = {
    environment       = "production"
    frontend_replicas = 3
    backend_replicas  = 3
  }
}
