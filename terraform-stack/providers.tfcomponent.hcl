required_providers {
  kubernetes = {
    source  = "hashicorp/kubernetes"
    version = "~> 2.0" # Use a recent version compatible with your Stack
  }
}

provider "kubernetes" "this" {
  # Configuration is handled via the in-cluster service account
  # No explicit config block is needed if using in-cluster config.
  # This is just to test 2
  config {}
}