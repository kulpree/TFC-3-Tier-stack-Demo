variable "namespace" { type = string }

resource "kubernetes_stateful_set" "db" {
  metadata {
    name      = "postgres"
    namespace = var.namespace
    labels    = { app = "postgres" }
  }
  spec {
    service_name = "postgres"
    replicas     = 1
    selector { match_labels = { app = "postgres" } }
    template {
      metadata { labels = { app = "postgres" } }
      spec {
        container {
          name  = "postgres"
          image = "postgres:15-alpine"
          port { container_port = 5432 }
          env { name = "POSTGRES_PASSWORD", value = "example" }
          env { name = "POSTGRES_DB",       value = "appdb"   }
        }
      }
    }
  }
}

resource "kubernetes_service" "db" {
  metadata {
    name      = "postgres"
    namespace = var.namespace
  }
  spec {
    selector = { app = "postgres" }
    port { port = 5432, target_port = 5432 }
    cluster_ip = "None"
  }
}
