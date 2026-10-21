#!/usr/bin/env bash
#
# add-production-stack.sh (v2)
#
# - Detects .tfcomponent.hcl or .tfstack.hcl naming in terraform-stack/
# - Generates modules/ from scratch if missing (no longer depends on dev-stack layout)
# - Creates a separate "production-stack" Stack in HCP Terraform
#   with VCS triggering DISABLED (manual GitHub Actions trigger only)
# ------------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# 0. Load persisted credentials
# -----------------------------------------------------------------------------
ENV_FILE="${HOME}/.config/three-tier-stacks/env"
if [[ -f "${ENV_FILE}" ]]; then
  echo "🔑 Loading credentials from ${ENV_FILE}"
  set +u
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set -u
else
  echo "❌ ${ENV_FILE} not found. Run setup-3tier-stacks-local.sh first."
  exit 1
fi

: "${HCP_ORG:?HCP_ORG is not set}"
: "${HCP_TOKEN:?HCP_TOKEN is not set}"
: "${AGENT_POOL_ID:?AGENT_POOL_ID is not set}"

export TF_API_TOKEN="${HCP_TOKEN}"
export TF_CLOUD_ORGANIZATION="${HCP_ORG}"

# -----------------------------------------------------------------------------
# 1. Config
# -----------------------------------------------------------------------------
PROD_STACK_NAME="production-stack"
PROD_DIR="./production-stack"
GITHUB_REPO="${GITHUB_REPO:-}"   # optional: "owner/repo"

# -----------------------------------------------------------------------------
# 2. Create directory
# -----------------------------------------------------------------------------
echo "📁 Creating ${PROD_DIR}..."
mkdir -p "${PROD_DIR}"

# -----------------------------------------------------------------------------
# 3. Detect component file naming in terraform-stack/ and copy / generate
# -----------------------------------------------------------------------------
DEV_DIR="./terraform-stack"

# Determine which extension the dev stack uses
COMPONENT_EXT=""
if [[ -f "${DEV_DIR}/components.tfcomponent.hcl" ]]; then
  COMPONENT_EXT="tfcomponent"
elif [[ -f "${DEV_DIR}/components.tfstack.hcl" ]]; then
  COMPONENT_EXT="tfstack"
fi

if [[ -n "${COMPONENT_EXT}" ]]; then
  echo "🔍 Detected dev-stack component extension: .${COMPONENT_EXT}.hcl"
  cp "${DEV_DIR}/providers.${COMPONENT_EXT}.hcl"  "${PROD_DIR}/" 2>/dev/null || true
  cp "${DEV_DIR}/components.${COMPONENT_EXT}.hcl" "${PROD_DIR}/" 2>/dev/null || true
  echo "✅ Copied providers.${COMPONENT_EXT}.hcl + components.${COMPONENT_EXT}.hcl"
else
  echo "⚠️  No component files found in ${DEV_DIR}; generating defaults (.tfcomponent.hcl)."
  COMPONENT_EXT="tfcomponent"
fi

# Always (re)generate the component files for production if they're missing
if [[ ! -f "${PROD_DIR}/providers.${COMPONENT_EXT}.hcl" ]]; then
  cat > "${PROD_DIR}/providers.${COMPONENT_EXT}.hcl" <<'EOF'
provider "kubernetes" "this" {}
EOF
  echo "✅ Generated providers.${COMPONENT_EXT}.hcl"
fi

if [[ ! -f "${PROD_DIR}/components.${COMPONENT_EXT}.hcl" ]]; then
  cat > "${PROD_DIR}/components.${COMPONENT_EXT}.hcl" <<'EOF'
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

variable "environment"       { type = string }
variable "frontend_replicas" { type = number, default = 1 }
variable "backend_replicas"  { type = number, default = 1 }
EOF
  echo "✅ Generated components.${COMPONENT_EXT}.hcl"
fi

# -----------------------------------------------------------------------------
# 4. Copy modules if present, otherwise generate them from scratch
# -----------------------------------------------------------------------------
if [[ -d "${DEV_DIR}/modules" ]]; then
  echo "📦 Copying modules/ from dev stack..."
  cp -r "${DEV_DIR}/modules" "${PROD_DIR}/"
else
  echo "📦 modules/ not found in dev stack; generating them from scratch..."
  mkdir -p "${PROD_DIR}/modules/frontend" \
           "${PROD_DIR}/modules/backend"  \
           "${PROD_DIR}/modules/database"

  cat > "${PROD_DIR}/modules/frontend/main.tf" <<'EOF'
variable "namespace" { type = string }
variable "replicas"  { type = number }

resource "kubernetes_namespace" "frontend" {
  metadata { name = var.namespace }
}

resource "kubernetes_deployment" "frontend" {
  metadata {
    name      = "frontend"
    namespace = kubernetes_namespace.frontend.metadata[0].name
    labels    = { app = "frontend" }
  }
  spec {
    replicas = var.replicas
    selector { match_labels = { app = "frontend" } }
    template {
      metadata { labels = { app = "frontend" } }
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

  cat > "${PROD_DIR}/modules/backend/main.tf" <<'EOF'
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
    port {
      port        = 5678
      target_port = 5678
    }
    type = "ClusterIP"
  }
}
EOF

  cat > "${PROD_DIR}/modules/database/main.tf" <<'EOF'
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
    port {
      port        = 5432
      target_port = 5432
    }
    cluster_ip = "None"
  }
}
EOF

  echo "✅ Generated modules/ (frontend, backend, database)"
fi

# -----------------------------------------------------------------------------
# 5. Generate deployments.tfdeploy.hcl with a single production deployment
# -----------------------------------------------------------------------------
cat > "${PROD_DIR}/deployments.tfdeploy.hcl" <<'EOF'
deployment "production" {
  inputs = {
    environment       = "production"
    frontend_replicas = 3
    backend_replicas  = 3
  }
}
EOF
echo "✅ Created deployments.tfdeploy.hcl"

# -----------------------------------------------------------------------------
# 6. Generate GitHub Actions workflow (manual trigger only)
# -----------------------------------------------------------------------------
echo "🐙 Creating GitHub Actions workflow for production..."
mkdir -p .github/workflows

cat > .github/workflows/deploy-production.yml <<EOF
name: Deploy Production Stack

on:
  workflow_dispatch:

env:
  TF_API_TOKEN: \${{ secrets.TF_API_TOKEN }}
  PROD_STACK_ID: \${{ secrets.PROD_STACK_ID }}

jobs:
  trigger-production:
    runs-on: ubuntu-latest
    steps:
      - name: Fetch latest configuration from VCS
        run: |
          curl -sS -X POST \\
            -H "Authorization: Bearer \${TF_API_TOKEN}" \\
            -H "Content-Type: application/vnd.api+json" \\
            "https://app.terraform.io/api/v2/stacks/\${PROD_STACK_ID}/fetch-latest-from-vcs" \\
            -d '{}' | jq .
EOF

echo "✅ Created .github/workflows/deploy-production.yml"

# -----------------------------------------------------------------------------
# 7. Create the Stack in HCP Terraform (VCS triggers disabled)
# -----------------------------------------------------------------------------
echo "🧱 Creating Stack '${PROD_STACK_NAME}' in HCP Terraform..."

PROJECT_ID=$(curl -s \
  -H "Authorization: Bearer ${TF_API_TOKEN}" \
  "https://app.terraform.io/api/v2/organizations/${HCP_ORG}/projects?filter%5Bname%5D=Default%20Project" \
  | jq -r '.data[0].id')

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "null" ]]; then
  echo "⚠️  No Default Project found. Create the Stack manually in the UI."
  exit 0
fi

if [[ -n "${GITHUB_REPO}" ]]; then
  STACK_PAYLOAD=$(jq -n \
    --arg name "${PROD_STACK_NAME}" \
    --arg project_id "${PROJECT_ID}" \
    --arg agent_pool_id "${AGENT_POOL_ID}" \
    --arg repo "${GITHUB_REPO}" \
    '{
      data: {
        type: "stacks",
        attributes: {
          name: $name,
          "speculative-enabled": false,
          "vcs-trigger-enabled": false
        },
        relationships: {
          project:      { data: { type: "projects",    id: $project_id } },
          "agent-pool": { data: { type: "agent-pools", id: $agent_pool_id } },
          "vcs-repo":   { data: { type: "vcs-repos", attributes: { identifier: $repo, branch: "main" } } }
        }
      }
    }')
else
  STACK_PAYLOAD=$(jq -n \
    --arg name "${PROD_STACK_NAME}" \
    --arg project_id "${PROJECT_ID}" \
    --arg agent_pool_id "${AGENT_POOL_ID}" \
    '{
      data: {
        type: "stacks",
        attributes: { name: $name },
        relationships: {
          project:      { data: { type: "projects",    id: $project_id } },
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
  echo "⚠️  Stack creation failed (likely already exists)."
  echo "${STACK_RESPONSE}" | jq .
  echo ""
  echo "If the Stack already exists, get its ID from the HCP UI and set the PROD_STACK_ID secret."
else
  STACK_ID=$(echo "${STACK_RESPONSE}" | jq -r '.data.id')
  echo "✅ Stack '${PROD_STACK_NAME}' created (ID: ${STACK_ID})."
  echo ""
  echo "👉 Set this as the PROD_STACK_ID secret in GitHub:"
  echo "   ${STACK_ID}"
fi

# -----------------------------------------------------------------------------
# 8. Summary
# -----------------------------------------------------------------------------
cat <<EOF

============================================================================
🎉 Production Stack setup complete!

Files created:
  - ${PROD_DIR}/providers.${COMPONENT_EXT}.hcl
  - ${PROD_DIR}/components.${COMPONENT_EXT}.hcl
  - ${PROD_DIR}/deployments.tfdeploy.hcl
  - ${PROD_DIR}/modules/{frontend,backend,database}/
  - .github/workflows/deploy-production.yml

Next steps:
  1. Commit and push:
       git add ${PROD_DIR} .github/workflows/deploy-production.yml
       git commit -m "Add production Stack with manual trigger"
       git push origin main

  2. Add GitHub Actions secret (Settings → Secrets → Actions):
       PROD_STACK_ID = the Stack ID printed above

  3. Confirm TF_API_TOKEN secret still exists.

  4. Run the workflow:
       Actions → "Deploy Production Stack" → Run workflow

  5. Verify:
       kubectl --context kind-three-tier-stacks get all -n production
============================================================================
EOF