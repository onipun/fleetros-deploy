#!/usr/bin/env bash
# 10-point validation suite for local Fleetros stack.
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/fleetros-local}"
export KUBECONFIG

pass() { echo -e "  \033[32m✓\033[0m $1"; }
fail() { echo -e "  \033[31m✗\033[0m $1"; FAILED=1; }

FAILED=0
echo "== Fleetros local validation =="

echo "[1/10] kubectl reachability"
kubectl get nodes -o name >/dev/null && pass "API reachable" || fail "API unreachable"

echo "[2/10] core namespaces present"
for ns in argocd infra app data monitoring; do
  kubectl get ns "$ns" >/dev/null 2>&1 && pass "ns/$ns" || fail "ns/$ns missing"
done

echo "[3/10] Argo CD healthy"
kubectl -n argocd rollout status deploy/argocd-server --timeout=60s >/dev/null && pass "argocd-server" || fail "argocd-server"

echo "[4/10] cert-manager healthy"
kubectl -n infra rollout status deploy/cert-manager --timeout=60s >/dev/null && pass "cert-manager" || fail "cert-manager"

echo "[5/10] Application synced"
phase=$(kubectl -n argocd get application fleetros-local -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
[[ "$phase" == "Synced" ]] && pass "Application Synced" || fail "Application not Synced (got: $phase)"

echo "[6/10] postgres running"
# StackGres uses an OnDelete update strategy on its primary StatefulSet
# (Patroni manages restarts), so `kubectl rollout status` doesn't work —
# fall back to readyReplicas == replicas.
for i in $(seq 1 30); do
  ready=$(kubectl -n data get sts postgres -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  desired=$(kubectl -n data get sts postgres -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
  [[ -n "$ready" && "$ready" -ge 1 && "$ready" == "$desired" ]] && break
  sleep 10
done
[[ "$ready" -ge 1 && "$ready" == "$desired" ]] && pass "postgres (stackgres) ($ready/$desired)" || fail "postgres ($ready/$desired)"

echo "[7/10] ingresses created"
count=$(kubectl -n app get ingress --no-headers 2>/dev/null | wc -l)
(( count > 0 )) && pass "$count ingress(es)" || fail "no ingresses"

echo "[8/10] Prometheus + Grafana healthy"
kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana --timeout=120s >/dev/null \
  && pass "grafana" || fail "grafana"
kubectl -n monitoring rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=120s >/dev/null \
  && pass "prometheus" || fail "prometheus"

echo "[9/10] Loki + Promtail running"
kubectl -n monitoring rollout status statefulset/loki --timeout=120s >/dev/null \
  && pass "loki" || fail "loki"
ready=$(kubectl -n monitoring get ds promtail -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
desired=$(kubectl -n monitoring get ds promtail -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
[[ "$ready" -gt 0 && "$ready" == "$desired" ]] && pass "promtail ds ($ready/$desired)" || fail "promtail not ready ($ready/$desired)"

echo "[10/10] Traefik metrics + Grafana dashboard wiring"
kubectl -n kube-system get svc traefik-metrics >/dev/null 2>&1 \
  && pass "traefik-metrics service exists" || fail "traefik-metrics service missing (HelmChartConfig not applied?)"
kubectl -n monitoring get servicemonitor traefik >/dev/null 2>&1 \
  && pass "ServiceMonitor traefik" || fail "ServiceMonitor traefik missing"
kubectl -n monitoring get cm fleetros-observability-dashboard \
  -o jsonpath='{.metadata.labels.grafana_dashboard}' 2>/dev/null | grep -q '^1$' \
  && pass "Grafana dashboard ConfigMap labelled" || fail "dashboard ConfigMap missing/unlabelled"
# Sanity-check that Prometheus is actually scraping Traefik (active target).
# Prometheus Operator names the job after the Service ("traefik-metrics"),
# but the scrape pool path uses the ServiceMonitor name ("traefik"); we look
# for either so a future Service rename doesn't break the assertion.
if kubectl -n monitoring exec sts/prometheus-kube-prometheus-stack-prometheus -c prometheus -- \
    wget -q -O- http://localhost:9090/api/v1/targets 2>/dev/null \
    | grep -qE '"scrapePool":"serviceMonitor/monitoring/traefik/'; then
  pass "Prometheus is scraping the traefik ServiceMonitor"
else
  fail "Prometheus is not scraping traefik (check ServiceMonitor selector)"
fi

if [[ "$FAILED" == "1" ]]; then
  echo -e "\n\033[31mValidation FAILED\033[0m"; exit 1
fi
echo -e "\n\033[32mAll checks passed.\033[0m"
echo "Add to /etc/hosts:"
VM_IP=$(multipass info fleetros-local 2>/dev/null | awk '/IPv4/ {print $2; exit}' || echo "<vm-ip>")
echo "  $VM_IP  app.fleetros.local api.fleetros.local portal.fleetros.local auth.fleetros.local grafana.fleetros.local"
