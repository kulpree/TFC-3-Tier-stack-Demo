# 🚀 Three-Tier App on Local Kubernetes with HCP Terraform Stacks

A complete, hands-on demo that deploys a **three-tier application** (frontend / backend / database) to a **local kind Kubernetes cluster** using:

- **HCP Terraform Stacks** — multi-deployment (dev + staging) infrastructure orchestration
- **HCP Terraform VCS connection** — push-driven runs from GitHub
- **Self-hosted HCP Terraform agent** — executes Terraform *inside* the local kind cluster
- **GitHub Actions** — custom CI/CD pipeline for programmatic environment promotion

Everything you need — the setup script, all Terraform Stack files, the CI workflow, and the demo walkthrough — is in this single README.

---

## 📑 Table of Contents

1. [Architecture](#-architecture)
2. [Prerequisites](#-prerequisites)
3. [Quick Start](#-quick-start)
4. [Files Created by the Script](#-files-created-by-the-script)
5. [The Setup Script (full listing)](#-the-setup-script-full-listing)
6. [Demo Walkthrough](#-demo-walkthrough)
7. [Verifying the Whole Setup](#-verifying-the-whole-setup)
8. [Troubleshooting](#-troubleshooting)
9. [Cleanup](#-cleanup)
10. [Reference](#-reference)

---

## 📐 Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│                        GitHub Repository                           │
│  terraform-stack/   .github/workflows/terraform-stacks.yml         │
└──────────┬──────────────────────────────┬──────────────────────────┘
           │ push (main)                  │ push (staging)
           │ VCS trigger                  │ GitHub Actions
           ▼                              ▼
┌────────────────────────────────────────────────────────────────────┐
│                     HCP Terraform (SaaS)                           │
│   Stack: three-tier-stack                                          │
│   ├── deployment "dev"      ──► agent pool "local-kind-agent-pool" │
│   └── deployment "staging"  ──► agent pool "local-kind-agent-pool" │
└────────────────────────────┬───────────────────────────────────────┘
                             │ agent polls for jobs
                             ▼
┌────────────────────────────────────────────────────────────────────┐
│                 Local Laptop — kind cluster                        │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  namespace: tfc-agents                                       │  │
│  │  └── pod tfc-agent (hashicorp/tfc-agent, SA=cluster-admin)   │  │
│  └──────────────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  namespace: dev                                              │  │
│  │  ├── frontend (nginx)      Deployment + Service              │  │
│  │  ├── backend  (http-echo)  Deployment + Service              │  │
│  │  └── postgres              StatefulSet + headless Service    │  │
│  └──────────────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  namespace: staging                                          │  │
│  │  └── (same three tiers, replicated x2)                       │  │
│  └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

**Why a self‑hosted agent?** Terraform Stacks do **not** support a fully offline local mode — they must be orchestrated by HCP Terraform. By deploying an agent into your kind cluster, the actual `terraform plan`/`apply` executes on your laptop against your local cluster, while HCP Terraform manages runs, state, and VCS integration.

---

## 📋 Prerequisites

| Tool | Minimum Version | Check |
|------|-----------------|-------|
| Docker | 20+ | `docker --version` |
| kind | 0.20+ | `kind --version` |
| kubectl | 1.27+ | `kubectl version --client` |
| Helm | 3.x | `helm version` |
| Terraform CLI | **≥ 1.13.0** (required for Stacks) | `terraform version` |
| jq | 1.6+ | `jq --version` |

Accounts you'll need:

- **HCP Terraform organization** → https://app.terraform.io/app/organizations/new
- **HCP Terraform user/team API token** → https://app.terraform.io/app/settings/tokens (scope: `Manage agent pools`, `Manage stacks`)
- **GitHub repository** (empty is fine; you'll push to it)

---

## ⚡ Quick Start

```bash
# 1. Create your repo directory
mkdir three-tier-stacks-demo && cd three-tier-stacks-demo
git init

# 2. Copy the setup script (see "The Setup Script" section below) into a file:
nano setup-3tier-stacks-local.sh
chmod +x setup-3tier-stacks-local.sh

# 3. Run it — it will prompt once for your HCP Terraform org + token
./setup-3tier-stacks-local.sh

# 4. Push to GitHub
git add .
git commit -m "Add 3-tier Terraform Stack demo"
git remote add origin git@github.com:<you>/three-tier-stacks-demo.git
git push -u origin main
```

Then finish the one‑time UI wiring:

1. **HCP Terraform → Stacks → `three-tier-stack`**
   - *Settings → Version control* → link GitHub repo, branch `main`, subdirectory `terraform-stack`
   - *Settings → Agents* → confirm `local-kind-agent-pool` is selected
   - *Deployments* → both `dev` and `staging` should be visible
2. **GitHub → Settings → Secrets and variables → Actions**
   - Add `TF_API_TOKEN` = your HCP Terraform API token

You're ready for the [Demo Walkthrough](#-demo-walkthrough).

---

## 🗂️ Files Created by the Script

```
.
├── README.md                                # this file
├── setup-3tier-stacks-local.sh              # one-shot setup script
├── .github/
│   └── workflows/
│       └── terraform-stacks.yml             # GitHub Actions pipeline
└── terraform-stack/
    ├── providers.tfstack.hcl                # provider config (in-cluster K8s)
    ├── components.tfstack.hcl               # frontend/backend/database components
    ├── deployments.tfdeploy.hcl             # dev + staging deployments
    └── modules/
        ├── frontend/main.tf                 # nginx Deployment + Service
        ├── backend/main.tf                  # http-echo Deployment + Service
        └── database/main.tf                 # Postgres StatefulSet + headless Service
```

It also writes:

- `~/.config/three-tier-stacks/env` — persisted credentials (mode `600`): `HCP_ORG`, `HCP_TOKEN`, `AGENT_POOL_ID`, `AGENT_POOL_TOKEN`. Delete this file to force re-prompting.

---

## 📜 The Setup Script (full listing)

Save the following as `setup-3tier-stacks-local.sh`, then `chmod +x setup-3tier-stacks-local.sh`.

```bash
#!/usr/bin/env bash
#
# setup-3tier-stacks-local.sh  (v3)
#
# - Persists HCP creds + agent pool token in ~/.config/three-tier-stacks/env
# - Verifies / restarts the kind cluster if it exists but is stopped
# - Deploys HCP Terraform agent with in-cluster ServiceAccount auth (RBAC)
# - Generates Terraform Stacks + GitHub Actions workflow
# ------------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# 0. Config
# -----------------------------------------------------------------------------
CLUSTER_NAME="three-tier-stacks"
STACK_NAME="three-tier-stack"
GITHUB_REPO="${GITHUB_REPO:-}"
AGENT_POOL_NAME="local-kind-agent-pool"

ENV_DIR="${HOME}/.config/three-tier-stacks"
ENV_FILE="${ENV_DIR}/env"
mkdir -p "${ENV_DIR}"
chmod 700 "${ENV_DIR}"

# -----------------------------------------------------------------------------
# 1. Load persisted credentials (if any)
# -----------------------------------------------------------------------------
if [[ -f "${ENV_FILE}" ]]; then
  echo "🔑 Loading saved credentials from ${ENV_FILE}"
  set +u
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set -u
fi

HCP_ORG="${HCP_ORG:-}"
HCP_TOKEN="${HCP_TOKEN:-}"
AGENT_POOL_ID="${AGENT_POOL_ID:-}"
AGENT_POOL_TOKEN="${AGENT_POOL_TOKEN:-}"

save_env() {
  umask 077
  cat > "${ENV_FILE}" <<EOF
# Auto-generated by setup-3tier-stacks-local.sh
# $(date -u +"%Y-%m-%dT%H:%M:%SZ")
HCP_ORG=${HCP_ORG}
HCP_TOKEN=${HCP_TOKEN}
AGENT_POOL_ID=${AGENT_POOL_ID:-}
AGENT_POOL_TOKEN=${AGENT_POOL_TOKEN:-}
EOF
  chmod 600 "${ENV_FILE}"
  echo "💾 Saved credentials to ${ENV_FILE} (mode 600)"
}

# -----------------------------------------------------------------------------
# 2. Prerequisite checks
# -----------------------------------------------------------------------------
check_cmd() {
  command -v "$1" &>/dev/null || { echo "❌ '$1' is required but not installed."; exit 1; }
}
for c in docker kind kubectl helm terraform curl jq; do check_cmd "$c"; done

# -----------------------------------------------------------------------------
# 3. Prompt for HCP Terraform creds only if missing
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

save_env

ORG_RESPONSE=$(curl -s \
  -H "Authorization: Bearer ${TF_API_TOKEN}" \
  -H "Content-Type: application/vnd.api+json" \
  "https://app.terraform.io/api/v2/organizations/${HCP_ORG}")

if echo "${ORG_RESPONSE}" | jq -e '.errors' >/dev/null 2>&1; then
  echo "❌ Failed to access HCP Terraform organization '${HCP_ORG}'."
  echo "${ORG_RESPONSE}" | jq .
  exit 1
fi
echo "✅ HCP Terraform org '${HCP_ORG}' accessible."

# -----------------------------------------------------------------------------
# 4. Verify (and start if stopped) the kind cluster
# -----------------------------------------------------------------------------
verify_cluster() {
  if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    echo "ℹ️  Kind cluster '${CLUSTER_NAME}' does not exist."
    return 1
  fi

  local node="${CLUSTER_NAME}-control-plane"
  local status
  status=$(docker inspect -f '{{.State.Status}}' "${node}" 2>/dev/null || echo "missing")

  echo "🔎 Cluster '${CLUSTER_NAME}' node state: ${status}"

  if [[ "${status}" == "missing" ]]; then
    echo "⚠️  Node container is missing; will recreate the cluster."
    kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
    return 1
  fi

  if [[ "${status}" != "running" ]]; then
    echo "▶️  Starting node container '${node}'..."
    docker start "${node}" >/dev/null
  fi

  local attempts=0
  while (( attempts < 30 )); do
    if kubectl --context "kind-${CLUSTER_NAME}" get --raw=/readyz &>/dev/null; then
      echo "✅ Cluster '${CLUSTER_NAME}' is running."
      return 0
    fi
    sleep 2
    ((attempts++))
  done

  echo "❌ Cluster '${CLUSTER_NAME}' exists but API server is not reachable."
  return 1
}

if verify_cluster; then
  echo "ℹ️  Reusing existing cluster."
else
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
  kind create cluster --name "${CLUSTER_NAME}" --config /tmp/kind-config.yaml --wait 120s
  echo "✅ Kind cluster created."
fi

export KUBECONFIG="${HOME}/.kube/config"
KUBECTL=(kubectl --context "kind-${CLUSTER_NAME}")
"${KUBECTL[@]}" cluster-info

# -----------------------------------------------------------------------------
# 5. Agent pool (reuse saved token if pool already exists)
# -----------------------------------------------------------------------------
echo "🔐 Ensuring HCP Terraform agent pool '${AGENT_POOL_NAME}' exists..."

POOL_RESPONSE=$(curl -s \
  -X POST \
  -H "Authorization: Bearer ${TF_API_TOKEN}" \
  -H "Content-Type: application/vnd.api+json" \
  "https://app.terraform.io/api/v2/organizations/${HCP_ORG}/agent-pools" \
  -d @- <<EOF
{ "data": { "type": "agent-pools", "attributes": { "name": "${AGENT_POOL_NAME}" } } }
EOF
)

if echo "${POOL_RESPONSE}" | jq -e '.errors' >/dev/null 2>&1; then
  echo "⚠️  Pool creation failed (likely already exists). Fetching existing pool..."
  POOL_RESPONSE=$(curl -s \
    -H "Authorization: Bearer ${TF_API_TOKEN}" \
    "https://app.terraform.io/api/v2/organizations/${HCP_ORG}/agent-pools?filter%5Bname%5D=${AGENT_POOL_NAME}")
  FOUND_POOL_ID=$(echo "${POOL_RESPONSE}" | jq -r '.data[0].id')

  if [[ -z "${FOUND_POOL_ID}" || "${FOUND_POOL_ID}" == "null" ]]; then
    echo "❌ Unable to locate agent pool '${AGENT_POOL_NAME}'."
    exit 1
  fi
  AGENT_POOL_ID="${FOUND_POOL_ID}"

  if [[ -n "${AGENT_POOL_TOKEN}" && "${AGENT_POOL_TOKEN}" != "null" ]]; then
    echo "✅ Reusing saved agent pool token for pool ${AGENT_POOL_ID}."
  else
    echo "🔐 HCP Terraform does not re-issue existing pool tokens."
    echo "   Create a new token for this pool at:"
    echo "   https://app.terraform.io/app/${HCP_ORG}/settings/agents/pools"
    read -rsp "Paste a token for agent pool '${AGENT_POOL_NAME}': " AGENT_POOL_TOKEN
    echo
  fi
else
  AGENT_POOL_ID=$(echo "${POOL_RESPONSE}" | jq -r '.data.id')
  AGENT_POOL_TOKEN=$(echo "${POOL_RESPONSE}" | jq -r '.data.attributes.token')
  echo "✅ Agent pool created (ID: ${AGENT_POOL_ID})."
fi

if [[ -z "${AGENT_POOL_TOKEN}" || "${AGENT_POOL_TOKEN}" == "null" ]]; then
  echo "❌ No agent pool token available; aborting."
  exit 1
fi

save_env

# -----------------------------------------------------------------------------
# 6. In-cluster RBAC for the agent
# -----------------------------------------------------------------------------
echo "🛡️  Creating ServiceAccount + RBAC for the agent..."

"${KUBECTL[@]}" create namespace tfc-agents --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

"${KUBECTL[@]}" apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tfc-agent
  namespace: tfc-agents
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tfc-agent-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: tfc-agent
    namespace: tfc-agents
EOF

# -----------------------------------------------------------------------------
# 7. Agent deployment (in-cluster auth; no kubeconfig mount)
# -----------------------------------------------------------------------------
echo "🤖 Deploying HCP Terraform agent..."

"${KUBECTL[@]}" -n tfc-agents create secret generic tfc-agent-token \
  --from-literal=token="${AGENT_POOL_TOKEN}" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

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
      serviceAccountName: tfc-agent
      securityContext:
        fsGroup: 999
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
          volumeMounts:
            - name: agent-data
              mountPath: /agent-data
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
      volumes:
        - name: agent-data
          emptyDir:
            sizeLimit: 5Gi
EOF

"${KUBECTL[@]}" -n tfc-agents delete deployment tfc-agent --ignore-not-found
"${KUBECTL[@]}" apply -f /tmp/tfc-agent-deployment.yaml

echo "⏳ Waiting for the agent pod to become ready..."
"${KUBECTL[@]}" -n tfc-agents rollout status deployment/tfc-agent --timeout=180s
"${KUBECTL[@]}" -n tfc-agents wait --for=condition=Ready pod \
  -l app=tfc-agent --timeout=180s

echo "✅ HCP Terraform agent is running in the kind cluster."

# -----------------------------------------------------------------------------
# 8. Terraform Stack files
# -----------------------------------------------------------------------------
echo "📦 Generating Terraform Stack files..."
STACK_DIR="./terraform-stack"
mkdir -p "${STACK_DIR}"

cat > "${STACK_DIR}/providers.tfstack.hcl" <<'EOF'
# The agent pod carries a ServiceAccount with cluster-admin; the Kubernetes
# provider auto-detects in-cluster configuration, so no config_path is needed.
provider "kubernetes" "this" {}
EOF

cat > "${STACK_DIR}/components.tfstack.hcl" <<'EOF'
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
EOF

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

mkdir -p "${STACK_DIR}/modules/frontend" \
         "${STACK_DIR}/modules/backend"  \
         "${STACK_DIR}/modules/database"

cat > "${STACK_DIR}/modules/frontend/main.tf" <<'EOF'
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
    port { port = 80, target_port = 80 }
    type = "ClusterIP"
  }
}
EOF

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
EOF

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
EOF

echo "✅ Terraform Stack files generated in ${STACK_DIR}"

# -----------------------------------------------------------------------------
# 9. GitHub Actions workflow
# -----------------------------------------------------------------------------
echo "🐙 Generating GitHub Actions workflow..."
mkdir -p .github/workflows
cat > .github/workflows/terraform-stacks.yml <<EOF
name: Terraform Stacks – Local 3-Tier App

on:
  push:
    branches: [main, staging]
  pull_request:
    branches: [main]

env:
  TF_API_TOKEN: \${{ secrets.TF_API_TOKEN }}
  TF_CLOUD_ORGANIZATION: "${HCP_ORG}"
  STACK_NAME: "${STACK_NAME}"

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          cli_config_credentials_token: \${{ env.TF_API_TOKEN }}
      - run: terraform init
      - if: github.event_name == 'pull_request'
        run: terraform plan -input=false

  apply-dev:
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    needs: plan
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/terraform-cloud-action/apply@v1
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
      - uses: hashicorp/terraform-cloud-action/apply@v1
        with:
          token: \${{ env.TF_API_TOKEN }}
          organization: \${{ env.TF_CLOUD_ORGANIZATION }}
          stack: \${{ env.TF_STACK_NAME }}
          deployment: staging
          auto_approve: true
EOF

echo "✅ GitHub Actions workflow created."

# -----------------------------------------------------------------------------
# 10. Create the Stack in HCP Terraform
# -----------------------------------------------------------------------------
echo "🧱 Ensuring Terraform Stack '${STACK_NAME}' exists..."

PROJECT_ID=$(curl -s \
  -H "Authorization: Bearer ${TF_API_TOKEN}" \
  "https://app.terraform.io/api/v2/organizations/${HCP_ORG}/projects?filter%5Bname%5D=Default%20Project" \
  | jq -r '.data[0].id')

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "null" ]]; then
  echo "⚠️  No default project found; create the Stack manually in the UI."
else
  if [[ -n "${GITHUB_REPO}" ]]; then
    STACK_PAYLOAD=$(jq -n \
      --arg name "${STACK_NAME}" --arg project_id "${PROJECT_ID}" \
      --arg agent_pool_id "${AGENT_POOL_ID}" --arg repo "${GITHUB_REPO}" \
      '{
        data: {
          type: "stacks",
          attributes: { name: $name, "speculative-enabled": true },
          relationships: {
            project:      { data: { type: "projects",    id: $project_id } },
            "agent-pool": { data: { type: "agent-pools", id: $agent_pool_id } },
            "vcs-repo":   { data: { type: "vcs-repos", attributes: { identifier: $repo, branch: "main" } } }
          }
        }
      }')
  else
    STACK_PAYLOAD=$(jq -n \
      --arg name "${STACK_NAME}" --arg project_id "${PROJECT_ID}" \
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
    echo "⚠️  Stack create failed (likely exists)."
    echo "${STACK_RESPONSE}" | jq .
  else
    echo "✅ Stack '${STACK_NAME}' created (ID: $(echo "${STACK_RESPONSE}" | jq -r '.data.id'))."
  fi
fi

# -----------------------------------------------------------------------------
# 11. Summary
# -----------------------------------------------------------------------------
cat <<EOF

============================================================================
🎉 Setup complete!

Cluster : kind-${CLUSTER_NAME}
Agent   : tfc-agents/tfc-agent   (ClusterRoleBinding: cluster-admin)
Creds   : ${ENV_FILE} (mode 600; reused automatically on next run)

Next steps:
  1. git add . && git commit -m "Add 3-tier Terraform Stack" && git push origin main
  2. In HCP Terraform → Stack '${STACK_NAME}':
       • Link your GitHub repo (VCS connection)
       • Select agent pool '${AGENT_POOL_NAME}'
  3. Add secret TF_API_TOKEN to your GitHub repo
  4. Push to 'main' → dev deployment;  push to 'staging' → staging deployment
  5. Verify: ${KUBECTL[*]} get all -n dev   (and -n staging)
  6. Clean up:  kind delete cluster --name ${CLUSTER_NAME}
       (delete ${ENV_FILE} if you want to forget saved creds)

============================================================================
EOF
```

---

## 🎬 Demo Walkthrough

Two "acts" — one **VCS-driven**, one **GitHub Actions-driven** — proving both trigger paths work with Stacks.

### 🎭 Act 1 — VCS-driven deployment (dev)

**Goal:** A push to `main` triggers a Stack deployment in HCP Terraform, executed by the local agent, creating resources in the kind cluster.

```bash
# Baseline: nothing deployed yet
kubectl get ns dev staging 2>/dev/null
# → "Error from server (NotFound)" — expected

# Trigger the VCS-driven run
echo "# demo $(date +%s)" >> terraform-stack/README-demo.txt
git add terraform-stack/README-demo.txt
git commit -m "demo: trigger VCS-driven dev deployment"
git push origin main
```

**In HCP Terraform UI:**

1. Navigate to **Stacks → three-tier-stack → dev**.
2. A new run is queued → **Plan** → **Apply** (auto-approve if enabled, else click **Confirm & Apply**).
3. In the run logs, note the agent name (e.g. `tfc-agent-xxxxxxxxxx`) in the "Agent" column — that's your local kind pod.

**Verify locally:**

```bash
kubectl --context kind-three-tier-stacks get all -n dev
```

Expected (names/values vary):

```
NAME                            READY   UP-TO-DATE   AVAILABLE
deployment.apps/frontend        1/1     1            1
deployment.apps/backend         1/1     1            1

NAME                 READY
statefulset.apps/postgres   1/1

NAME               TYPE        CLUSTER-IP      PORT(S)
service/backend    ClusterIP   10.96.x.x       5678/TCP
service/frontend   ClusterIP   10.96.x.x       80/TCP
service/postgres   ClusterIP   None            5432/TCP
```

**Smoke test (in-cluster port-forward):**

```bash
kubectl -n dev port-forward svc/frontend 8080:80 &
curl -s http://localhost:8080 | head -n 5     # nginx welcome page
kill %1

kubectl -n dev port-forward svc/backend 8081:5678 &
curl -s http://localhost:8081                  # "Hello from backend"
kill %1
```

> ✅ **Proved:** VCS trigger → HCP Terraform Stack run → agent execution in kind → real Kubernetes resources.

---

### 🎭 Act 2 — GitHub Actions-driven deployment (staging)

**Goal:** GitHub Actions invokes a *specific* Stack deployment via the HCP Terraform API — a common promotion pipeline pattern.

```bash
# Create the staging branch
git checkout -b staging
git push -u origin staging

# Trigger the workflow
echo "# staging demo $(date +%s)" >> terraform-stack/README-demo.txt
git add terraform-stack/README-demo.txt
git commit -m "demo: trigger staging deployment via GitHub Actions"
git push origin staging
```

**In GitHub:**

1. **Actions → Terraform Stacks – Local 3-Tier App**.
2. Watch `plan` → `apply-staging` jobs run.
3. Click `apply-staging` to see the `terraform-cloud-action/apply` step calling the HCP API.

**In HCP Terraform:**

- Navigate to **Stacks → three-tier-stack → staging**.
- The run was triggered programmatically → same agent pool → same kind cluster.

**Verify locally:**

```bash
kubectl --context kind-three-tier-stacks get all -n staging

# staging runs 2 replicas of frontend and backend
kubectl --context kind-three-tier-stacks -n staging \
  get deploy frontend backend -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.replicas} replicas{"\n"}{end}'
```

Expected:

```
frontend: 2 replicas
backend: 2 replicas
```

> ✅ **Proved:** GitHub Actions → HCP API → Stack deployment `staging` → agent → Kubernetes. This is how you'd gate promotions with approvals, tests, or policy checks.

---

### 🎭 Act 3 — Speculative Plan on PR (optional)

```bash
git checkout -b feature/demo
echo "# pr demo $(date +%s)" >> terraform-stack/README-demo.txt
git add terraform-stack/README-demo.txt
git commit -m "demo: PR speculative plan"
git push -u origin feature/demo
```

- Open a PR against `main` in GitHub.
- The `plan` job in GitHub Actions runs `terraform plan -input=false`.
- The HCP Stack also posts a **speculative plan** check on the PR (green check / red x).

---

## 🔍 Verifying the Whole Setup

Run these to convince yourself everything is wired up:

```bash
# 1. Cluster is up
kind get clusters
kubectl --context kind-three-tier-stacks cluster-info

# 2. Agent is running and polling
kubectl -n tfc-agents get pods
kubectl -n tfc-agents logs -l app=tfc-agent --tail=50
# → look for "agent has connected" / "waiting for work"

# 3. Agent SA has permissions
kubectl auth can-i '*' '*' \
  --as=system:serviceaccount:tfc-agents:tfc-agent

# 4. Deployments exist (after Act 1 & Act 2)
kubectl get ns dev staging

# 5. Saved credentials
cat ~/.config/three-tier-stacks/env   # HCP_ORG, HCP_TOKEN, AGENT_POOL_ID, AGENT_POOL_TOKEN
```

---

## 🧯 Troubleshooting

| Symptom | Fix |
|---------|-----|
| `"fsGroup" unknown field` on `kubectl apply` | Fixed in v3 — `fsGroup` is under `spec.template.spec.securityContext` (pod‑level), **not** container `securityContext`. |
| Agent pod `CrashLoopBackOff` — token invalid | Delete `~/.config/three-tier-stacks/env` and re‑run; you'll be prompted for a fresh pool token. |
| Runs queue in HCP but never pick up | Check `kubectl -n tfc-agents logs -l app=tfc-agent`. If it says "agent pool doesn't match", confirm the Stack's agent pool is `local-kind-agent-pool` in the HCP UI. |
| `terraform apply` in agent can't reach Kubernetes | Shouldn't happen with v3 (in‑cluster config + `cluster-admin`), but if it does: `kubectl -n tfc-agents exec deploy/tfc-agent -- env \| grep KUBERNETES`. |
| Kind cluster won't start — ports 80/443 in use | Stop whatever is on those ports (e.g. a local nginx), or edit `CLUSTER_NAME` / port mappings and re‑run. |
| GitHub Actions `apply-staging` fails with `401` | `TF_API_TOKEN` secret is not set, or the token lacks org permissions. |
| `apply-staging` fails with "deployment not found" | The `STACK_NAME` env in the workflow must match exactly (`three-tier-stack`). |
| `kind get clusters` shows the cluster but `kubectl` errors with "connection refused" | Node container stopped — re‑run the script; `verify_cluster` will `docker start` it. |
| Script re‑runs but doesn't use saved credentials | Verify `~/.config/three-tier-stacks/env` exists and is readable; `source` it manually to inspect. |
| Stack API create returns `422` | Default project missing; create the Stack manually in the HCP UI, or set `project_id` in the script. |

---

## 🧹 Cleanup

```bash
# Remove the Kubernetes cluster
kind delete cluster --name three-tier-stacks

# Remove saved credentials
rm -rf ~/.config/three-tier-stacks

# Optional: delete Stack + agent pool in HCP Terraform UI
#   https://app.terraform.io/app/<your-org>/stacks
#   https://app.terraform.io/app/<your-org>/settings/agents/pools
```

---

## 📚 Reference

- [Terraform Stacks docs](https://developer.hashicorp.com/terraform/cloud-docs/stacks)
- [HCP Terraform agents docs](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/dynamic-provider-credentials/agent-pools)
- [hashicorp/tfc-agent Docker image](https://hub.docker.com/r/hashicorp/tfc-agent)
- [kind quick start](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [hashicorp/terraform-cloud-action](https://github.com/hashicorp/terraform-cloud-action)
- [GitHub Actions `hashicorp/setup-terraform`](https://github.com/hashicorp/setup-terraform)
- [Kubernetes Pod security context (fsGroup)](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)

---

## 🎯 The One-Slide Takeaway

> **HCP VCS** gives you push-to-deploy for the primary branch.
> **GitHub Actions** gives you programmatic control to promote to other environments.
> **Terraform Stacks** gives you one component definition + N environment deployments with consistent state.
> **A local agent** makes it all run on your laptop's cluster — proving the whole flow end-to-end without touching AWS.
