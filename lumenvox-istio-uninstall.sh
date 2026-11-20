#!/bin/bash
set -uo pipefail
# Note: set -e is intentionally omitted -- uninstall steps are best-effort
# and continue even if individual steps fail.

#############################################
# Usage
#############################################
# Removes the Istio service mesh and Istio Gateway installed by
# lumenvox-control-install.sh, while leaving the
# Kubernetes cluster and the LumenVox workloads in place.
#
#   ./lumenvox-istio-uninstall.sh [path-to-istio-directory]
#
# The optional path is the istio-<version> directory the installer
# downloaded (it contains bin/istioctl). If omitted, the script looks for
# istioctl on PATH and then searches under the current directory and $HOME.
ISTIO_DIR_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        -*) printf "Error: unknown option '%s'\n" "$1"; exit 1 ;;
        *)  ISTIO_DIR_ARG="$1"; shift ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    printf "Error: do not run this script as root. Run as the user that owns the kubectl config.\n"
    exit 1
fi

if ! command -v kubectl &>/dev/null; then
    printf "Error: kubectl not found.\n"
    exit 1
fi
if ! kubectl get ns 1>/dev/null 2>&1; then
    printf "Error: kubectl cannot reach the cluster. Check ~/.kube/config.\n"
    exit 1
fi

#############################################
# Confirmation prompt
#############################################
printf "WARNING: This will remove the Istio service mesh and Istio Gateway from this cluster:\n"
printf "           - Gateway and HTTPRoute resources\n"
printf "           - Istio sidecars from the lumenvox namespace (pods will be restarted)\n"
printf "           - istiod, the Istio ingress gateway, and the istio-system / istio-ingress namespaces\n"
printf "           - Istio CRDs\n"
printf "\n"
printf "         LumenVox will NOT be reachable from outside the cluster until Istio is\n"
printf "         installed again. Gateway API CRDs and the cluster itself are kept.\n\n"
printf "Proceed? [y/N]: "
read -r CONFIRM
case "$CONFIRM" in
    [yY][eE][sS]|[yY]) ;;
    *) printf "Aborted.\n"; exit 0 ;;
esac

#############################################
# Log setup
#############################################
currentdir="$(pwd)"
MAIN_LOG="$currentdir/istio-uninstall-main-log.txt"
ERR_LOG="$currentdir/istio-uninstall-err-log.txt"
true > "$MAIN_LOG"
true > "$ERR_LOG"

log()  { printf "%s\n" "$*" | tee -a "$MAIN_LOG"; }
warn() { printf "WARNING: %s\n" "$*" | tee -a "$MAIN_LOG" "$ERR_LOG" >&2; }

run() {
    log "	+ $*"
    if ! "$@" 1>>"$MAIN_LOG" 2>>"$ERR_LOG"; then
        warn "Command failed (continuing): $*"
    fi
}

#############################################
# Step 1: Locate istioctl
#############################################
log "1. Locating istioctl..."

ISTIOCTL=""
if [ -n "$ISTIO_DIR_ARG" ]; then
    if [ -x "$ISTIO_DIR_ARG/bin/istioctl" ]; then
        ISTIOCTL="$(readlink -f "$ISTIO_DIR_ARG/bin/istioctl")"
    else
        warn "No istioctl found at '$ISTIO_DIR_ARG/bin/istioctl'."
    fi
fi
if [ -z "$ISTIOCTL" ] && command -v istioctl &>/dev/null; then
    ISTIOCTL="$(command -v istioctl)"
fi
if [ -z "$ISTIOCTL" ]; then
    ISTIOCTL="$(find "$currentdir" "$HOME" -maxdepth 4 -type f -name istioctl -path '*/istio-*/bin/istioctl' 2>/dev/null | head -1)"
fi

if [ -n "$ISTIOCTL" ]; then
    log "	Using $ISTIOCTL"
else
    warn "istioctl not found -- Istio will be removed with kubectl only."
fi

#############################################
# Step 2: Remove Gateway and HTTPRoute resources
#############################################
log "2. Removing Gateway and HTTPRoute resources..."

run kubectl delete httproutes.gateway.networking.k8s.io --all -n lumenvox      --ignore-not-found=true
run kubectl delete httproutes.gateway.networking.k8s.io --all -n istio-ingress --ignore-not-found=true
run kubectl delete gateways.gateway.networking.k8s.io   --all -n istio-ingress --ignore-not-found=true

#############################################
# Step 3: Remove sidecar injection from lumenvox
#############################################
log "3. Removing Istio sidecar injection from the lumenvox namespace..."

if kubectl get ns lumenvox 1>/dev/null 2>&1; then
    run kubectl label namespace lumenvox istio-injection-
    if [ -n "$(kubectl get deployment,statefulset -n lumenvox -o name 2>/dev/null)" ]; then
        run kubectl rollout restart deployment -n lumenvox
        run kubectl rollout restart statefulset -n lumenvox
    else
        log "	No workloads in lumenvox namespace (already uninstalled?) -- nothing to restart."
    fi
else
    log "	lumenvox namespace not found, skipping."
fi

#############################################
# Step 4: Uninstall the Istio control plane
#############################################
log "4. Uninstalling Istio control plane and ingress gateway..."

if [ -n "$ISTIOCTL" ]; then
    run "$ISTIOCTL" uninstall --purge -y
else
    log "	Skipping istioctl uninstall (istioctl not found)."
fi

#############################################
# Step 5: Remove Istio namespaces
#############################################
log "5. Removing Istio namespaces..."

run kubectl delete namespace istio-ingress --ignore-not-found=true
run kubectl delete namespace istio-system  --ignore-not-found=true

#############################################
# Step 6: Remove leftover cluster-scoped Istio resources
#############################################
log "6. Removing leftover cluster-scoped Istio resources..."

for kind in mutatingwebhookconfiguration validatingwebhookconfiguration clusterrole clusterrolebinding; do
    for res in $(kubectl get "$kind" -o name 2>/dev/null | grep -i 'istio'); do
        run kubectl delete "$res" --ignore-not-found=true
    done
done

for crd in $(kubectl get crd -o name 2>/dev/null | grep -E '\.istio\.io$'); do
    run kubectl delete "$crd" --ignore-not-found=true
done

#############################################
# Step 7: Remove downloaded Istio files
#############################################
log "7. Removing downloaded Istio files..."

ISTIO_HOME=""
if [ -n "$ISTIOCTL" ]; then
    ISTIO_HOME="$(dirname "$(dirname "$ISTIOCTL")")"
fi
case "$ISTIO_HOME" in
    */istio-[0-9]*)
        run rm -rf "$ISTIO_HOME"
        ;;
    *)
        log "	No istio-<version> directory to remove."
        ;;
esac

#############################################
# Done
#############################################
cat <<EOF

==========================================================
   Istio uninstall complete!
==========================================================

Istio service mesh and gateway have been removed.

Notes:
  - Gateway API CRDs were left in place (they are not part of Istio).
  - Verify with:  kubectl get po -A    and    kubectl get crd | grep istio
EOF

cat <<EOF
  - values.yaml still sets serviceMesh.type=istio and ingress.className=istio.
    Install Istio again before the next 'helm install/upgrade': the chart
    recreates the Gateway and HTTPRoutes from these values.
EOF

printf "\nLogs: %s\n      %s\n" "$MAIN_LOG" "$ERR_LOG"
