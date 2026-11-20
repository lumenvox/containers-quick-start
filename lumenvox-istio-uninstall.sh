#!/bin/bash
set -uo pipefail
# Note: set -e is intentionally omitted -- uninstall steps are best-effort
# and continue even if individual steps fail.

#############################################
# Usage
#############################################
# Removes the Istio service mesh and Istio Gateway installed by
# lumenvox-control-install.sh (--mesh-stack istio), while leaving the
# Kubernetes cluster and the LumenVox workloads in place.
#
#   ./lumenvox-istio-uninstall.sh [--install-linkerd] [path-to-istio-directory]
#
#   --install-linkerd   After removing Istio, install Linkerd and the
#                       ingress-nginx controller (the --mesh-stack linkerd
#                       setup used by lumenvox-control-install.sh).
#
# The optional path is the istio-<version> directory the installer
# downloaded (it contains bin/istioctl). If omitted, the script looks for
# istioctl on PATH and then searches under the current directory and $HOME.
INSTALL_LINKERD=0
ISTIO_DIR_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --install-linkerd) INSTALL_LINKERD=1; shift ;;
        -*) printf "Error: unknown option '%s'\n" "$1"; exit 1 ;;
        *)  ISTIO_DIR_ARG="$1"; shift ;;
    esac
done

LINKERD_INSTALL_URL="https://assets.lumenvox.com/third-party/linkerd/linkerd_install"
NGINX_INGRESS_VERSION="4.14.5"

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
# Optional: replace Istio with Linkerd + ingress-nginx
#############################################
if [ "$INSTALL_LINKERD" -eq 0 ]; then
    printf "Install Linkerd and the ingress-nginx controller after removing Istio? [y/N]: "
    read -r LINKERD_CHOICE
    case "$LINKERD_CHOICE" in
        [yY][eE][sS]|[yY]) INSTALL_LINKERD=1 ;;
    esac
    printf "\n"
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
if [ "$INSTALL_LINKERD" -eq 1 ]; then
    printf "         Then Linkerd (control plane + viz) and the ingress-nginx controller\n"
    printf "         will be installed. Gateway API CRDs and the cluster itself are kept.\n\n"
else
    printf "         LumenVox will NOT be reachable from outside the cluster until another\n"
    printf "         ingress is configured. Gateway API CRDs and the cluster itself are kept.\n\n"
fi
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

linkerd_apply() {
    local label="$1" outfile="$2"
    shift 2
    log "	Rendering ${label}..."
    "$@" >"$outfile" 2>>"$ERR_LOG" \
        || { rm -f "$outfile"; warn "Failed to render ${label}."; return 1; }
    log "	Applying ${label}..."
    kubectl apply -f "$outfile" 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || { rm -f "$outfile"; warn "Failed to apply ${label}."; return 1; }
    rm -f "$outfile"
}

install_linkerd_stack() {
    export PATH="$PATH:$HOME/.linkerd2/bin"

    if kubectl get ns linkerd 1>/dev/null 2>&1; then
        log "	Linkerd namespace already exists -- skipping Linkerd install."
    else
        if ! command -v linkerd &>/dev/null; then
            log "	Downloading Linkerd CLI..."
            curl --proto '=https' --tlsv1.2 -sSfLo linkerd_install "$LINKERD_INSTALL_URL" \
                1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
                || { warn "Failed to download Linkerd install script."; return 1; }
            chmod +x linkerd_install
            ./linkerd_install 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
                || { rm -f linkerd_install; warn "Failed to install Linkerd CLI."; return 1; }
            rm -f linkerd_install
        fi

        log "	Running Linkerd pre-check..."
        linkerd check --pre 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            || { warn "System does not meet Linkerd requirements."; return 1; }

        linkerd_apply "Linkerd CRDs"          linkerd_crds.yaml linkerd install --crds || return 1
        linkerd_apply "Linkerd control plane" linkerd_cp.yaml \
            linkerd install --set proxyInit.runAsRoot=true --set proxyInit.iptablesMode=nft || return 1
        linkerd_apply "Linkerd viz dashboard" linkerd_viz.yaml linkerd viz install || return 1

        log "	Waiting 30 seconds for Linkerd pods to start..."
        sleep 30

        log "	Running Linkerd post-install check..."
        linkerd check 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            || { warn "Linkerd failed post-install check. Review $ERR_LOG."; return 1; }
    fi

    if ! command -v helm &>/dev/null; then
        warn "helm not found -- cannot install ingress-nginx."
        return 1
    fi

    log "	Installing nginx ingress controller..."
    helm upgrade --install ingress-nginx ingress-nginx \
        --repo https://kubernetes.github.io/ingress-nginx \
        -n ingress-nginx --create-namespace \
        --set controller.hostNetwork=true \
        --version "$NGINX_INGRESS_VERSION" \
        1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || { warn "Failed to install nginx ingress controller."; return 1; }

    log "	Waiting for nginx-ingress controller to become ready..."
    kubectl wait --for=condition=Available deployment/ingress-nginx-controller \
        -n ingress-nginx --timeout=120s \
        1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || { warn "nginx-ingress controller did not become ready in time."; return 1; }
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
# Step 8: Install Linkerd and ingress-nginx (optional)
#############################################
LINKERD_RESULT="not requested"
if [ "$INSTALL_LINKERD" -eq 1 ]; then
    log "8. Installing Linkerd and ingress-nginx..."
    if install_linkerd_stack; then
        LINKERD_RESULT="installed"
    else
        LINKERD_RESULT="FAILED -- review $ERR_LOG"
    fi
fi

#############################################
# Done
#############################################
cat <<EOF

==========================================================
   Istio uninstall complete!
==========================================================

Istio service mesh and gateway have been removed.
Linkerd + ingress-nginx: $LINKERD_RESULT

Notes:
  - Gateway API CRDs were left in place (they are not part of Istio).
  - Verify with:  kubectl get po -A    and    kubectl get crd | grep istio
EOF

if [ "$INSTALL_LINKERD" -eq 1 ] && [ "$LINKERD_RESULT" = "installed" ]; then
    cat <<EOF
  - Linkerd is not permanently on PATH. To persist it, add to ~/.bashrc:
      export PATH=\$PATH:\$HOME/.linkerd2/bin

Reinstall LumenVox on the Linkerd/nginx stack (the --set flags override
the Istio values still present in values.yaml):

  helm install lumenvox lumenvox/lumenvox -n lumenvox -f values.yaml \\
    --set global.serviceMesh.type=linkerd \\
    --set global.lumenvox.ingress.className=nginx
EOF
else
    cat <<EOF
  - values.yaml still sets serviceMesh.type=istio and ingress.className=istio.
    Update these before the next 'helm install/upgrade', or the chart will
    try to recreate the Gateway and HTTPRoutes.
EOF
fi

printf "\nLogs: %s\n      %s\n" "$MAIN_LOG" "$ERR_LOG"
