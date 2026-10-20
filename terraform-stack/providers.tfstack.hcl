# The agent pod carries a ServiceAccount with cluster-admin; the Kubernetes
# provider auto-detects in-cluster configuration, so no config_path is needed.
provider "kubernetes" "this" {}
