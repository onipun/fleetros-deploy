#!/usr/bin/env bash
# 7-point validation suite for local Fleetros stack.
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/fleetros-local}"
export KUBECONFIG

pass() { echo -e "  \033[32m✓\033[0m $1"; }
fail() { echo -e "  \033[31m✗\033[0m $1"; FAILED=1; }

FAILED=0
echo "== Fleetros local validation =="

echo "[1/7] kubectl reachability"
kubectl get nodes -o name >/dev/null && pass "API reachable" || fail "API unreachable"

echo "[2/7] core namespaces present"
for ns in argocd infra app data; do
  kubectl get ns "$ns" >/dev/null 2>&1 && pass "ns/$ns" || fail "ns/$ns missing"
done

echo "[3/7] Argo CD healthy"
kubectl -n argocd rollout status deploy/argocd-server --timeout=60s >/dev/null && pass "argocd-server" || fail "argocd-server"

echo "[4/7] cert-manager healthy"
kubectl -n infra rollout status deploy/cert-manager --timeout=60s >/dev/null && pass "cert-manager" || fail "cert-manager"

echo "[5/7] Application synced"
phase=$(kubectl -n argocd get application fleetros-local -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
[[ "$phase" == "Synced" ]] && pass "Application Synced" || fail "Application not Synced (got: $phase)"

echo "[6/7] postgres running"
kubectl -n data rollout status statefulset/postgres --timeout=120s >/dev/null && pass "postgres" || fail "postgres"

echo "[7/7] ingresses created"
count=$(kubectl -n app get ingress --no-headers 2>/dev/null | wc -l)
(( count > 0 )) && pass "$count ingress(es)" || fail "no ingresses"

if [[ "$FAILED" == "1" ]]; then
  echo -e "\n\033[31mValidation FAILED\033[0m"; exit 1
fi
echo -e "\n\033[32mAll checks passed.\033[0m"
echo "Add to /etc/hosts:"
VM_IP=$(multipass info fleetros-local 2>/dev/null | awk '/IPv4/ {print $2; exit}' || echo "<vm-ip>")
echo "  $VM_IP  app.fleetros.local api.fleetros.local portal.fleetros.local auth.fleetros.local"
