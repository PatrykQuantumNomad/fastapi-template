#!/usr/bin/env bash
# ============================================================
# FastAPI Chassis — Helm Chart Integration Test
#
# Deploys the chart into a local KIND cluster, waits for
# readiness, runs `helm test`, and tears down the cluster.
#
# Prerequisites: kind, kubectl, helm, docker
#
# Environment variables:
#   KIND_CLUSTER_NAME   — cluster name          (default: fastapi-chassis-test)
#   HELM_RELEASE_NAME   — release name          (default: fastapi-chassis)
#   HELM_NAMESPACE      — target namespace      (default: default)
#   HELM_VALUES_FILE    — values override file  (default: chart/ci/test-values-sqlite.yaml)
#   IMAGE_NAME          — Docker image name     (default: fastapi-chassis)
#   IMAGE_TAG           — Docker image tag      (default: test)
#   KEEP_CLUSTER        — set to "true" to skip cluster teardown for debugging
#   TEST_TIMEOUT        — helm test timeout     (default: 120s)
#   WAIT_TIMEOUT        — pod readiness timeout (default: 180s)
# ============================================================
set -euo pipefail

# --- Configuration -----------------------------------------------------------

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-fastapi-chassis-test}"
HELM_RELEASE_NAME="${HELM_RELEASE_NAME:-fastapi-chassis}"
HELM_NAMESPACE="${HELM_NAMESPACE:-default}"
HELM_VALUES_FILE="${HELM_VALUES_FILE:-chart/ci/test-values-sqlite.yaml}"
IMAGE_NAME="${IMAGE_NAME:-fastapi-chassis}"
IMAGE_TAG="${IMAGE_TAG:-test}"
KEEP_CLUSTER="${KEEP_CLUSTER:-false}"
TEST_TIMEOUT="${TEST_TIMEOUT:-120s}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180s}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Helpers ------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[helm-test]${NC} $*"; }
ok()   { echo -e "${GREEN}[helm-test]  ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}[helm-test]  ! $*${NC}"; }
fail() { echo -e "${RED}[helm-test]  ✗ $*${NC}"; }

check_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        fail "Required tool '$1' is not installed."
        exit 1
    fi
}

# --- Cleanup ------------------------------------------------------------------

cleanup() {
    local exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        log "Collecting diagnostics before cleanup..."
        echo ""
        echo "--- Pod status ---"
        kubectl get pods -n "$HELM_NAMESPACE" 2>/dev/null || true
        echo ""
        echo "--- Pod describe ---"
        kubectl describe pods -n "$HELM_NAMESPACE" -l "app.kubernetes.io/instance=$HELM_RELEASE_NAME" 2>/dev/null || true
        echo ""
        echo "--- App logs ---"
        kubectl logs -n "$HELM_NAMESPACE" -l "app.kubernetes.io/instance=$HELM_RELEASE_NAME" --tail=80 2>/dev/null || true
        echo ""
        echo "--- Events ---"
        kubectl get events -n "$HELM_NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null | tail -30 || true
    fi

    if [ "$KEEP_CLUSTER" = "true" ]; then
        warn "KEEP_CLUSTER=true — skipping cluster teardown."
        warn "Clean up manually: kind delete cluster --name $KIND_CLUSTER_NAME"
    else
        log "Deleting KIND cluster..."
        kind delete cluster --name "$KIND_CLUSTER_NAME" 2>/dev/null || true
    fi

    if [ "$exit_code" -eq 0 ]; then
        echo ""
        ok "All Helm integration tests passed."
    else
        echo ""
        fail "Helm integration tests failed (exit $exit_code)."
    fi

    return "$exit_code"
}
trap cleanup EXIT

# --- Preflight ----------------------------------------------------------------

log "Checking prerequisites..."
for tool in kind kubectl helm docker; do
    check_tool "$tool"
done
ok "All required tools are installed."

# --- Build Docker image -------------------------------------------------------

log "Building Docker image ${IMAGE_NAME}:${IMAGE_TAG}..."
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --build-arg VCS_REF="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)" \
    --build-arg VERSION="${IMAGE_TAG}" \
    "$PROJECT_ROOT"
ok "Docker image built."

# --- Create KIND cluster ------------------------------------------------------

# Delete stale cluster if it exists
if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
    warn "Stale cluster '$KIND_CLUSTER_NAME' found — deleting."
    kind delete cluster --name "$KIND_CLUSTER_NAME"
fi

log "Creating KIND cluster '${KIND_CLUSTER_NAME}'..."
kind create cluster --name "$KIND_CLUSTER_NAME" --wait 60s
ok "KIND cluster created."

# --- Load image into KIND -----------------------------------------------------

log "Loading image into KIND..."
kind load docker-image "${IMAGE_NAME}:${IMAGE_TAG}" --name "$KIND_CLUSTER_NAME"
ok "Image loaded."

# --- Deploy with Helm --------------------------------------------------------

log "Installing Helm chart (release=${HELM_RELEASE_NAME}, ns=${HELM_NAMESPACE})..."
helm install "$HELM_RELEASE_NAME" "$PROJECT_ROOT/chart" \
    --namespace "$HELM_NAMESPACE" \
    --create-namespace \
    -f "$PROJECT_ROOT/$HELM_VALUES_FILE" \
    --wait \
    --timeout "$WAIT_TIMEOUT"
ok "Helm release installed."

# --- Verify pod readiness -----------------------------------------------------

log "Verifying pod readiness..."

WORKLOAD_KIND=$(helm get values "$HELM_RELEASE_NAME" -n "$HELM_NAMESPACE" -o json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('statefulset' if d.get('database',{}).get('backend','')=='sqlite' else 'deployment')" 2>/dev/null \
    || echo "deployment")

if [ "$WORKLOAD_KIND" = "statefulset" ]; then
    kubectl rollout status statefulset/"$HELM_RELEASE_NAME-fastapi-chassis" \
        -n "$HELM_NAMESPACE" --timeout="$WAIT_TIMEOUT" 2>/dev/null \
    || kubectl rollout status statefulset/"$HELM_RELEASE_NAME" \
        -n "$HELM_NAMESPACE" --timeout="$WAIT_TIMEOUT" 2>/dev/null \
    || true
else
    kubectl rollout status deployment/"$HELM_RELEASE_NAME-fastapi-chassis" \
        -n "$HELM_NAMESPACE" --timeout="$WAIT_TIMEOUT" 2>/dev/null \
    || kubectl rollout status deployment/"$HELM_RELEASE_NAME" \
        -n "$HELM_NAMESPACE" --timeout="$WAIT_TIMEOUT" 2>/dev/null \
    || true
fi

# Double-check at least one pod is Running
RUNNING_PODS=$(kubectl get pods -n "$HELM_NAMESPACE" \
    -l "app.kubernetes.io/instance=$HELM_RELEASE_NAME" \
    --field-selector=status.phase=Running \
    -o name 2>/dev/null | wc -l | tr -d ' ')

if [ "$RUNNING_PODS" -lt 1 ]; then
    fail "No running pods found after waiting."
    exit 1
fi
ok "${RUNNING_PODS} pod(s) running."

# --- Run Helm tests -----------------------------------------------------------

log "Running helm test..."
helm test "$HELM_RELEASE_NAME" \
    --namespace "$HELM_NAMESPACE" \
    --timeout "$TEST_TIMEOUT" \
    --logs
ok "Helm tests passed."

# --- In-cluster endpoint verification -----------------------------------------

log "Running in-cluster endpoint verification..."

# Pick the first running app pod
APP_POD=$(kubectl get pods -n "$HELM_NAMESPACE" \
    -l "app.kubernetes.io/instance=$HELM_RELEASE_NAME,app.kubernetes.io/name=fastapi-chassis" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$APP_POD" ]; then
    # Port-forward and probe the health/readiness endpoints from localhost
    kubectl port-forward -n "$HELM_NAMESPACE" "pod/$APP_POD" 18090:8000 &
    PF_PID=$!
    sleep 3

    # Healthcheck
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        "http://127.0.0.1:18090/healthcheck" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        ok "Healthcheck returned 200 via port-forward."
    else
        fail "Healthcheck returned $HTTP_CODE via port-forward."
        kill "$PF_PID" 2>/dev/null || true
        exit 1
    fi

    # Readiness
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        "http://127.0.0.1:18090/ready" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        ok "Readiness returned 200 via port-forward."
    else
        fail "Readiness returned $HTTP_CODE via port-forward."
        kill "$PF_PID" 2>/dev/null || true
        exit 1
    fi

    # Root
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        "http://127.0.0.1:18090/" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        ok "Root endpoint returned 200 via port-forward."
    else
        fail "Root endpoint returned $HTTP_CODE via port-forward."
        kill "$PF_PID" 2>/dev/null || true
        exit 1
    fi

    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
else
    warn "Could not find app pod for port-forward verification — skipping."
fi

log "All checks complete."
