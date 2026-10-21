variable "namespace" { type = string }
variable "replicas"  { type = number }

resource "kubernetes_deployment" "backend" {
  metadata {
    name      = "backend"
    namespace = var.namespace
    labels    = { app = "backend" }
  }
  spec {
    replicas = var.replicas
    selector { match_labels = { app = "backend" } }
    template {
      metadata { labels = { app = "backend" } }
      spec {
        container {
          name  = "backend"
          image = "hashicorp/http-echo:0.2.3"
          args  = ["-text=Hello from backend"]
          port { container_port = 5678 }
        }
      }
    }
  }
}

resource "kubernetes_service" "backend" {
  metadata {
    name      = "backend"
    namespace = var.namespace
  }
  spec {
    selector = { app = "backend" }
    port { port = 5678, target_port = 5678 }
    type = "ClusterIP"
  }
}
