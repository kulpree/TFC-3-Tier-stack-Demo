#!/usr/bin/env bash
# Testing my changes
# setup-3tier-stacks-local.sh
#
# Deploys a three-tier sample app on a local kind Kubernetes cluster using
# Terraform Stacks in HCP Terraform with a self-hosted agent for local execution.
#
# Prerequisites:
#   - Docker
#   - kind  (https://kind.sigs.k8s.io/)
#   - kubectl
#   - Helm
#   - Terraform CLI >= 1.13.0
#   - HCP Terraform account (free tier is sufficient)
#   - An HCP Terraform organization and a user/team API token with permissions
#     to create agent pools and Stacks.
#
# The script will prompt for the HCP Terraform organization name and API token.
# It will also generate a random agent pool token and create the pool via API.
# ------------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# 0. Configuration – adjust if needed
# -----------------------------------------------------------------------------
CLUSTER_NAME="three-tier-stacks"
HCP_ORG="${HCP_ORG:-}"                # set env HCP_ORG or leave blank to prompt
HCP_TOKEN="${HCP_TOKEN:-}"            # set env HCP_TOKEN or leave blank to prompt
STACK_NAME="three-tier-stack"
GITHUB_REPO="${GITHUB_REPO:-}"        # e.g. "my-org/my-three-tier-repo"
AGENT_POOL_NAME="local-kind-agent-pool"

# -----------------------------------------------------------------------------
# 1. Check prerequisites
# -----------------------------------------------------------------------------
check_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "❌ '$1' is required but not installed. Please install it and re-run."
    exit 1
  fi
}

check_cmd docker
check_cmd kind
check_cmd kubectl
check_cmd helm
check_cmd terraform
check_cmd curl
check_cmd jq

# -----------------------------------------------------------------------------
# 2. Prompt for HCP Terraform credentials if not already set
# -----------------------------------------------------------------------------
if [[ -z "${HCP_ORG}" ]]; then
  read -rp "Enter your HCP Terraform organization name: " HCP_ORG
fi

if [[ -z "${HCP_TOKEN}" ]]; then
  read -rsp "Enter your HCP Terraform API token (will not echo): " HCP_TOKEN
  echo
fi

export TF_CLOUD_ORGANIZATION="${HCP_ORG}"
export TF_API_TOKEN="${HCP_TOKEN}"

# -----------------------------------------------------------------------------
# 3. Create the local kind cluster with port mappings for ingress
# -----------------------------------------------------------------------------
echo "🚀 Creating kind cluster '${CLUSTER_NAME}'..."

cat > /tmp/kind-config.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
EOF

kind create cluster \
  --name "${CLUSTER_NAME}" \
  --config /tmp/kind-config.yaml \
  --wait 120s

echo "✅ Kind cluster created."

# Export kubeconfig for later use
export KUBECONFIG="${HOME}/.kube/config"
kubectl cluster-info

# -----------------------------------------------------------------------------
# 4. Create an HCP Terraform agent pool and retrieve its token
# -----------------------------------------------------------------------------
echo "🔐 Creating HCP Terraform agent pool '${AGENT_POOL_NAME}'..."

# Get the organization name from the API (to get its ID if needed)
ORG_RESPONSE=$(curl -s \
  -H "Authorization: Bearer ${TF_API_TOKEN}" \
  -H "Content-Type: application/vnd.api+json" \
  "https://app.terraform.io/api/v2/organizations/${HCP_ORG}")

if echo "${ORG_RESPONSE}" | jq -e '.errors' >/dev/null 2>&1; then
  echo "❌ Failed to access HCP Terraform organization '${HCP_ORG}'."
  echo "${ORG_RESPONSE}" | jq .
  exit 1
fi

# Create an agent pool. The API returns the pool and a token in one call.
POOL_RESPONSE=$(curl -s \
  -X POST \
  -H "Authorization: Bearer ${TF_API_TOKEN}" \
  -H "Content-Type: application/vnd.api+json" \
  "https://app.terraform.io/api/v2/organizations/${HCP_ORG}/agent-pools" \
  -d @- <<EOF
{
  "data": {
    "type": "agent-pools",
    "attributes": {
      "name": "${AGENT_POOL_NAME}"
    }
  }
}
EOF
)

if echo "${POOL_RESPONSE}" | jq -e '.errors' >/dev/null 2>&1; then
  echo "⚠️  Agent pool creation failed (it may already exist). Attempting to reuse existing pool."
  # Try to fetch existing pool by name
  POOL_RESPONSE=$(curl -s \
    -H "Authorization: Bearer ${TF_API_TOKEN}" \
    "https://app.terraform.io/api/v2/organizations/${HCP_ORG}/agent-pools?filter%5Bname%5D=${AGENT_POOL_NAME}")
  POOL_ID=$(echo "${POOL_RESPONSE}" | jq -r '.data[0].id')
  AGENT_POOL_TOKEN=""
else
  POOL_ID=$(echo "${POOL_RESPONSE}" | jq -r '.data.id')
  AGENT_POOL_TOKEN=$(echo "${POOL_RESPONSE}" | jq -r '.data.attributes.token')
fi

if [[ -z "${AGENT_POOL_TOKEN}" || "${AGENT_POOL_TOKEN}" == "null" ]]; then
  echo "❌ Could not obtain an agent pool token. Please create an agent pool manually in HCP Terraform"
  echo "   and provide its token when prompted later, or set the AGENT_POOL_TOKEN environment variable."
  read -rsp "Paste the agent pool token: " AGENT_POOL_TOKEN
  echo
fi

echo "✅ Agent pool '${AGENT_POOL_NAME}' is ready (ID: ${POOL_ID})."

# -----------------------------------------------------------------------------
# 5. Create a kubeconfig secret for the agent (so Terraform can talk to kind)
# -----------------------------------------------------------------------------
echo "📄 Preparing kubeconfig for the agent..."

# Create a minimal kubeconfig that points to the kind cluster's API server
# The agent pod will run inside the cluster, so it can use the in-cluster config,
# but Terraform's Kubernetes provider expects a kubeconfig file.
# We'll create a secret containing the kubeconfig and mount it into the agent pod.

kubectl create namespace tfc-agents --dry-run=client -o yaml | kubectl apply -f -

kubectl -n tfc-agents create secret generic kind-kubeconfig \
  --from-file=kubeconfig="${KUBECONFIG}" \
  --dry-run=client -o yaml | kubectl apply -f -

# -----------------------------------------------------------------------------
# 6. Deploy the HCP Terraform agent into the kind cluster
# -----------------------------------------------------------------------------
echo "🤖 Deploying HCP Terraform agent..."

# Create the agent token secret
kubectl -n tfc-agents create secret generic tfc-agent-token \
  --from-literal=token="${AGENT_POOL_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Agent deployment manifest
cat > /tmp/tfc-agent-deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tfc-agent
  namespace: tfc-agents
  labels:
    app: tfc-agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tfc-agent
  template:
    metadata:
      labels:
        app: tfc-agent
    spec:
      serviceAccountName: default
      containers:
        - name: tfc-agent
          image: hashicorp/tfc-agent:latest
          env:
            - name: TFC_AGENT_TOKEN
              valueFrom:
                secretKeyRef:
                  name: tfc-agent-token
                  key: token
            - name: TFC_AGENT_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: TFC_AGENT_LOG_LEVEL
              value: "info"
            - name: TFC_AGENT_DATA_DIR
              value: "/agent-data"
            - name: KUBE_CONFIG_PATH
              value: "/etc/kind/kubeconfig"
          volumeMounts:
            - name: agent-data
              mountPath: /agent-data
            - name: kind-kubeconfig
              mountPath: /etc/kind
              readOnly: true
          resources:
            requests:
              memory: "512Mi"
              cpu: "500m"
            limits:
              memory: "2Gi"
              cpu: "2000m"
          securityContext:
            runAsNonRoot: true
            runAsUser: 999
            fsGroup: 999
      volumes:
        - name: agent-data
          emptyDir:
            sizeLimit: 5Gi
        - name: kind-kubeconfig
          secret:
            secretName: kind-kubeconfig
EOF

kubectl apply -f /tmp/tfc-agent-deployment.yaml

echo "⏳ Waiting for the agent pod to become ready..."
kubectl -n tfc-agents wait --for=condition=Ready pod \
  -l app=tfc-agent --timeout=180s

echo "✅ HCP Terraform agent is running in the kind cluster."

# -----------------------------------------------------------------------------
# 7. Create the Terraform Stack configuration for the three-tier app
# -----------------------------------------------------------------------------
echo "📦 Generating Terraform Stack files..."

STACK_DIR="./terraform-stack"
mkdir -p "${STACK_DIR}"

# 7.1 providers.tfstack.hcl
cat > "${STACK_DIR}/providers.tfstack.hcl" <<'EOF'
provider "kubernetes" "this" {
  config_path = var.kubeconfig_path
}

variable "kubeconfig_path" {
  type        = string
  description = "Path to the kubeconfig file inside the agent pod"
  default     = "/etc/kind/kubeconfig"
}
EOF

# 7.2 components.tfstack.hcl
cat > "${STACK_DIR}/components.tfstack.hcl" <<'EOF'
component "frontend" {
  source = "./modules/frontend"
  inputs = {
    namespace = var.environment
    replicas  = var.frontend_replicas
  }
  providers = {
    kubernetes = provider.kubernetes.this
  }
}

component "backend" {
  source = "./modules/backend"
  inputs = {
    namespace = var.environment
    replicas  = var.backend_replicas
  }
  providers = {
    kubernetes = provider.kubernetes.this
  }
}

component "database" {
  source = "./modules/database"
  inputs = {
    namespace = var.environment
  }
  providers = {
    kubernetes = provider.kubernetes.this
  }
}

variable "environment" {
  type        = string
  description = "Environment name (dev or staging)"
}

variable "frontend_replicas" {
  type    = number
  default = 1
}

variable "backend_replicas" {
  type    = number
  default = 1
}
EOF

# 7.3 deployments.tfdeploy.hcl
cat > "${STACK_DIR}/deployments.tfdeploy.hcl" <<'EOF'
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
EOF

# 7.4 Module directories (frontend, backend, database)
mkdir -p "${STACK_DIR}/modules/frontend" \
         "${STACK_DIR}/modules/backend" \
         "${STACK_DIR}/modules/database"

# ----- Frontend module (nginx) -----
cat > "${STACK_DIR}/modules/frontend/main.tf" <<'EOF'
variable "namespace" { type = string }
variable "replicas"  { type = number }

resource "kubernetes_namespace" "frontend" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_deployment" "frontend" {
  metadata {
    name      = "frontend"
    namespace = kubernetes_namespace.frontend.metadata[0].name
    labels    = { app = "frontend" }
  }
  spec {
    replicas = var.replicas
    selector {
      match_labels = { app = "frontend" }
    }
    template {
      metadata {
        labels = { app = "frontend" }
      }
      spec {
        container {
          name  = "nginx"
          image = "nginx:alpine"
          port { container_port = 80 }
        }
      }
    }
  }
}

resource "kubernetes_service" "frontend" {
  metadata {
    name      = "frontend"
    namespace = kubernetes_namespace.frontend.metadata[0].name
  }
  spec {
    selector = { app = "frontend" }
    port {
      port        = 80
      target_port = 80
    }
    type = "ClusterIP"
  }
}
EOF

# ----- Backend module (Node.js) -----
cat > "${STACK_DIR}/modules/backend/main.tf" <<'EOF'
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
    selector {
      match_labels = { app = "backend" }
    }
    template {
      metadata {
        labels = { app = "backend" }
      }
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
    port {
      port        = 5678
      target_port = 5678
    }
    type = "ClusterIP"
  }
}
EOF

# ----- Database module (PostgreSQL StatefulSet) -----
cat > "${STACK_DIR}/modules/database/main.tf" <<'EOF'
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
    selector {
      match_labels = { app = "postgres" }
    }
    template {
      metadata {
        labels = { app = "postgres" }
      }
      spec {
        container {
          name  = "postgres"
          image = "postgres:15-alpine"
          port { container_port = 5432 }
          env {
            name  = "POSTGRES_PASSWORD"
            value = "example"
          }
          env {
            name  = "POSTGRES_DB"
            value = "appdb"
          }
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
    port {
      port        = 5432
      target_port = 5432
    }
    cluster_ip = "None"
  }
}
EOF

echo "✅ Terraform Stack files generated in ${STACK_DIR}"

# -----------------------------------------------------------------------------
# 8. Create a GitHub Actions workflow file
# -----------------------------------------------------------------------------
echo "🐙 Generating GitHub Actions workflow..."

GITHUB_WORKFLOW_DIR=".github/workflows"
mkdir -p "${GITHUB_WORKFLOW_DIR}"

cat > "${GITHUB_WORKFLOW_DIR}/terraform-stacks.yml" <<EOF
name: Terraform Stacks – Local 3-Tier App

on:
  push:
    branches:
      - main        # triggers dev deployment
      - staging     # triggers staging deployment
  pull_request:
    branches:
      - main

env:
  TF_API_TOKEN: \${{ secrets.TF_API_TOKEN }}
  TF_CLOUD_ORGANIZATION: "${HCP_ORG}"
  STACK_NAME: "${STACK_NAME}"

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          cli_config_credentials_token: \${{ env.TF_API_TOKEN }}
      - name: Terraform Init
        run: terraform init
      - name: Terraform Plan (Speculative)
        if: github.event_name == 'pull_request'
        run: terraform plan -input=false

  apply-dev:
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    needs: plan
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4
      - name: Apply Dev Deployment
        uses: hashicorp/terraform-cloud-action/apply@v1
        with:
          token: \${{ env.TF_API_TOKEN }}
          organization: \${{ env.TF_CLOUD_ORGANIZATION }}
          stack: \${{ env.STACK_NAME }}
          deployment: dev
          auto_approve: true

  apply-staging:
    if: github.ref == 'refs/heads/staging' && github.event_name == 'push'
    needs: plan
    runs-on: ubuntu-latest
    environment: staging
    steps:
      - uses: actions/checkout@v4
      - name: Apply Staging Deployment
        uses: hashicorp/terraform-cloud-action/apply@v1
        with:
          token: \${{ env.TF_API_TOKEN }}
          organization: \${{ env.TF_CLOUD_ORGANIZATION }}
          stack: \${{ env.STACK_NAME }}
          deployment: staging
          auto_approve: true
EOF

echo "✅ GitHub Actions workflow created at ${GITHUB_WORKFLOW_DIR}/terraform-stacks.yml"

# -----------------------------------------------------------------------------
# 9. Create the Stack in HCP Terraform (via API)
# -----------------------------------------------------------------------------
echo "🧱 Creating Terraform Stack '${STACK_NAME}' in HCP Terraform..."

# Get the default project ID
PROJECT_ID=$(curl -s \
  -H "Authorization: Bearer ${TF_API_TOKEN}" \
  "https://app.terraform.io/api/v2/organizations/${HCP_ORG}/projects?filter%5Bname%5D=Default%20Project" \
  | jq -r '.data[0].id')

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "null" ]]; then
  echo "⚠️  Could not find a default project. The Stack will need to be created manually."
else
  # Create the Stack (linked to the VCS repo if provided)
  if [[ -n "${GITHUB_REPO}" ]]; then
    STACK_PAYLOAD=$(jq -n \
      --arg name "${STACK_NAME}" \
      --arg project_id "${PROJECT_ID}" \
      --arg agent_pool_id "${POOL_ID}" \
      --arg repo "${GITHUB_REPO}" \
      '{
        data: {
          type: "stacks",
          attributes: {
            name: $name,
            "speculative-enabled": true
          },
          relationships: {
            project: { data: { type: "projects", id: $project_id } },
            "agent-pool": { data: { type: "agent-pools", id: $agent_pool_id } },
            "vcs-repo": {
              data: {
                type: "vcs-repos",
                attributes: {
                  identifier: $repo,
                  branch: "main"
                }
              }
            }
          }
        }
      }')
  else
    STACK_PAYLOAD=$(jq -n \
      --arg name "${STACK_NAME}" \
      --arg project_id "${PROJECT_ID}" \
      --arg agent_pool_id "${POOL_ID}" \
      '{
        data: {
          type: "stacks",
          attributes: { name: $name },
          relationships: {
            project: { data: { type: "projects", id: $project_id } },
            "agent-pool": { data: { type: "agent-pools", id: $agent_pool_id } }
          }
        }
      }')
  fi

  STACK_RESPONSE=$(curl -s \
    -X POST \
    -H "Authorization: Bearer ${TF_API_TOKEN}" \
    -H "Content-Type: application/vnd.api+json" \
    "https://app.terraform.io/api/v2/stacks" \
    -d "${STACK_PAYLOAD}")

  if echo "${STACK_RESPONSE}" | jq -e '.errors' >/dev/null 2>&1; then
    echo "⚠️  Stack creation via API failed (it may already exist)."
    echo "${STACK_RESPONSE}" | jq .
  else
    STACK_ID=$(echo "${STACK_RESPONSE}" | jq -r '.data.id')
    echo "✅ Stack '${STACK_NAME}' created (ID: ${STACK_ID})."
  fi
fi

# -----------------------------------------------------------------------------
# 10. Summary and next steps
# -----------------------------------------------------------------------------
cat <<EOF

============================================================================
🎉 Setup complete!

Your local kind cluster '${CLUSTER_NAME}' is running with an HCP Terraform
agent. The Terraform Stack configuration is in '${STACK_DIR}'.

Next steps:

1. Push the Terraform Stack files to your GitHub repository:
   git add .
   git commit -m "Add Terraform Stack for local 3-tier app"
   git push origin main

2. In HCP Terraform:
   - Go to your Stack '${STACK_NAME}' (or create it manually if the API call
     failed).
   - Ensure it is linked to your GitHub repository (VCS connection).
   - Confirm that the agent pool '${AGENT_POOL_NAME}' is selected for the Stack.

3. Set the following secret in your GitHub repository
   (Settings → Secrets and variables → Actions):
   TF_API_TOKEN = <your HCP Terraform API token>

4. Trigger a run:
   - Push a change to the 'main' branch to deploy the 'dev' environment.
   - Push a change to the 'staging' branch to deploy the 'staging' environment.
   - Open a pull request to 'main' to see a speculative plan.

5. To verify resources in the kind cluster:
   kubectl get all -n dev
   kubectl get all -n staging

6. To clean up:
   kind delete cluster --name ${CLUSTER_NAME}

For more details, refer to the HCP Terraform Stacks documentation:
https://developer.hashicorp.com/terraform/cloud-docs/stacks
============================================================================
EOF
