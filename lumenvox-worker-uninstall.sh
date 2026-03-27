#!/bin/bash
set -euo pipefail

#############################################
# Usage
#############################################
# Optional args: CONTROL_PLANE_USER CONTROL_PLANE_IP
#   If provided, the script will SSH to the control plane to drain
#   and delete this node. If omitted, kubectl must already be
#   configured on this node.
CONTROL_PLANE_USER="${1:-}"
CONTROL_PLANE_IP="${2:-}"

# Must NOT be run directly as root; must be a sudo-capable user
if [ "`id -u`" -eq 0 ]; then
    printf "Error: do not run this script as root. Run as a user with sudo privileges.\n"
    exit 1
fi
if ! sudo -n true 2>/dev/null && ! sudo -v 2>/dev/null; then
    printf "Error: current user '%s' does not have sudo privileges.\n" "$USER"
    exit 1
fi

#############################################
# Log setup
#############################################
currentdir="`pwd`"
MAIN_LOG="$currentdir/uninstall-main-log.txt"
ERR_LOG="$currentdir/uninstall-err-log.txt"
> "$MAIN_LOG"
> "$ERR_LOG"

log() { printf "%s\n" "$*" | tee -a "$MAIN_LOG"; }
err() { printf "%s\n" "$*" | tee -a "$MAIN_LOG" "$ERR_LOG" >&2; }
die() { err "$*"; exit 1; }

#############################################
# OS detection
#############################################
log "0. Detecting OS..."

OS="`uname | tr '[:upper:]' '[:lower:]'`"
[ "$OS" = "linux" ] || die "Invalid OS '$OS': must be linux."

DISTRO="`grep ^ID= /etc/*-release -h 2>/dev/null | cut -d'=' -f2 | tr -d '\"' | head -1`"

case "$DISTRO" in
  ubuntu) ;;
  centos | rhel | rocky) ;;
  almalinux) ;;
  *) die "Error: distribution '$DISTRO' is not supported." ;;
esac

log "	Detected: distro=$DISTRO"

#############################################
# Helper: pkg_remove
#############################################
pkg_remove() {
    case "$DISTRO" in
      ubuntu)
        sudo apt-get remove -y "$@" 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
        ;;
      centos | rhel | rocky | almalinux)
        sudo yum -y remove "$@" 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
        ;;
    esac
}

#############################################
# Confirm before proceeding
#############################################
printf "\n"
printf "WARNING: This will drain and delete this node from the Kubernetes\n"
printf "cluster, then uninstall containerd and all Kubernetes components.\n"
printf "This action cannot be undone.\n"
printf "\n"
if [ -n "$CONTROL_PLANE_USER" ] && [ -n "$CONTROL_PLANE_IP" ]; then
    printf "Control plane: %s@%s\n" "$CONTROL_PLANE_USER" "$CONTROL_PLANE_IP"
else
    printf "No control plane credentials provided. Run as:\n"
    printf "  ./lumenvox-worker-uninstall.sh <user> <control-plane-IP>\n"
    printf "to drain/delete the node automatically, or ensure kubectl is\n"
    printf "already configured on this node.\n"
fi
printf "\n"
printf "Proceed? [yes/N]: "
read -r CONFIRM </dev/tty
if [ "$CONFIRM" != "yes" ]; then
    printf "Aborted.\n"
    exit 1
fi

#############################################
# Step 1: Drain and delete node from cluster
#############################################
log "1. Draining and deleting node from cluster..."

NODE_NAME="`hostname`"
KUBECONFIG_TMP=""

if [ -n "$CONTROL_PLANE_USER" ] && [ -n "$CONTROL_PLANE_IP" ]; then
    # Run drain and delete directly on the control plane via SSH
    log "	Draining node '$NODE_NAME' via ${CONTROL_PLANE_USER}@${CONTROL_PLANE_IP}..."
    ssh -o StrictHostKeyChecking=no \
        "${CONTROL_PLANE_USER}@${CONTROL_PLANE_IP}" \
        "kubectl drain ${NODE_NAME} --ignore-daemonsets --delete-emptydir-data --force --timeout=120s" \
        1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || log "	WARNING: drain returned non-zero -- continuing with delete."

    log "	Deleting node '$NODE_NAME' via ${CONTROL_PLANE_USER}@${CONTROL_PLANE_IP}..."
    ssh -o StrictHostKeyChecking=no \
        "${CONTROL_PLANE_USER}@${CONTROL_PLANE_IP}" \
        "kubectl delete node ${NODE_NAME}" \
        1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || log "	WARNING: node delete returned non-zero -- continuing."

    log "	Node '$NODE_NAME' drained and deleted."

elif command -v kubectl &>/dev/null; then
    # kubectl is available and configured locally
    if kubectl get node "$NODE_NAME" 1>>"$MAIN_LOG" 2>>"$ERR_LOG"; then
        log "	Draining node '$NODE_NAME'..."
        kubectl drain "$NODE_NAME" \
            --ignore-daemonsets \
            --delete-emptydir-data \
            --force \
            --timeout=120s \
            1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            || log "	WARNING: drain returned non-zero -- continuing with delete."

        log "	Deleting node '$NODE_NAME'..."
        kubectl delete node "$NODE_NAME" \
            1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            || log "	WARNING: node delete returned non-zero -- continuing."

        log "	Node '$NODE_NAME' drained and deleted."
    else
        log "	Node '$NODE_NAME' not found in cluster -- may already be removed, continuing."
    fi
else
    log "	kubectl not available and no control plane credentials provided."
    log "	Re-run with control plane credentials to drain/delete automatically:"
    log "	  ./lumenvox-worker-uninstall.sh <user> <control-plane-IP>"
    log "	Or drain/delete manually from the control plane before continuing:"
    log "	  kubectl drain $NODE_NAME --ignore-daemonsets --delete-emptydir-data"
    log "	  kubectl delete node $NODE_NAME"
    printf "\n"
    printf "kubectl is not available on this node and no control plane credentials\n"
    printf "were provided. Continue without draining? [yes/N]: "
    read -r CONFIRM2 </dev/tty
    if [ "$CONFIRM2" != "yes" ]; then
        printf "Aborted.\n"
        exit 1
    fi
fi

#############################################
# Step 2: kubeadm reset
#############################################
log "2. Resetting kubeadm..."

if command -v kubeadm &>/dev/null; then
    sudo kubeadm reset --force 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || log "	WARNING: kubeadm reset returned non-zero -- continuing."
    log "	kubeadm reset complete."
else
    log "	kubeadm not found, skipping reset."
fi

#############################################
# Step 2: Remove Kubernetes components
#############################################
log "3. Removing Kubernetes components..."

case "$DISTRO" in
  ubuntu)
    sudo apt-mark unhold kubelet kubeadm kubectl 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
    pkg_remove kubelet kubeadm kubectl
    sudo apt-get autoremove -y 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
    sudo rm -f /etc/apt/sources.list.d/kubernetes.list
    sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    ;;
  centos | rhel | rocky | almalinux)
    sudo yum versionlock delete kubeadm kubelet kubectl 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
    pkg_remove kubelet kubeadm kubectl
    sudo rm -f /etc/yum.repos.d/kubernetes.repo
    ;;
esac

log "	Kubernetes components removed."

#############################################
# Step 3: Remove Kubernetes state and config
#############################################
log "4. Removing Kubernetes state and config..."

for path in \
    /etc/kubernetes \
    /var/lib/kubelet \
    /var/lib/etcd \
    "$HOME/.kube"
do
    if sudo test -e "$path" 2>/dev/null; then
        sudo rm -rf "$path" 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            && log "	Removed: $path" \
            || log "	WARNING: could not remove $path -- continuing."
    else
        log "	Not found, skipping: $path"
    fi
done

# Clean up CNI state
for path in /etc/cni /opt/cni /var/lib/cni; do
    if sudo test -e "$path" 2>/dev/null; then
        sudo rm -rf "$path" 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            && log "	Removed: $path" \
            || log "	WARNING: could not remove $path -- continuing."
    else
        log "	Not found, skipping: $path"
    fi
done

# Flush CNI-created iptables rules
log "	Flushing iptables rules..."
sudo iptables -F 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
sudo iptables -t nat -F 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
sudo iptables -t mangle -F 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
sudo iptables -X 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true

# Remove virtual network interfaces left by CNI
for iface in cni0 flannel.1 calico tunl0; do
    if ip link show "$iface" &>/dev/null; then
        sudo ip link delete "$iface" 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            && log "	Removed network interface: $iface" \
            || log "	WARNING: could not remove interface $iface -- continuing."
    fi
done

log "	Kubernetes state cleaned up."

#############################################
# Step 4: Remove containerd
#############################################
log "4. Removing containerd..."

if command -v containerd &>/dev/null; then
    sudo systemctl stop    containerd 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
    sudo systemctl disable containerd 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
    pkg_remove containerd.io
    sudo rm -rf /etc/containerd /var/lib/containerd 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true

    case "$DISTRO" in
      ubuntu)
        sudo rm -f /etc/apt/sources.list.d/docker.list
        sudo rm -f /etc/apt/keyrings/docker.gpg
        sudo apt-get autoremove -y 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
        ;;
      centos | rhel | rocky | almalinux)
        sudo rm -f /etc/yum.repos.d/docker-ce.repo 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
        ;;
    esac
    log "	containerd removed."
else
    log "	containerd not found, skipping."
fi

#############################################
# Step 5: Remove crictl
#############################################
log "5. Removing crictl..."

if command -v crictl &>/dev/null; then
    sudo rm -f /usr/local/bin/crictl 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || log "	WARNING: could not remove crictl -- continuing."
    log "	crictl removed."
else
    log "	crictl not found, skipping."
fi

#############################################
# Step 6: Remove kernel config files
#############################################
log "6. Removing kernel module and sysctl config files..."

sudo rm -f /etc/modules-load.d/k8s.conf 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
sudo rm -f /etc/sysctl.d/k8s.conf       1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
sudo sysctl --system 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
log "	Kernel config files removed and sysctl reloaded."

#############################################
# Done
#############################################
printf "\n"
printf "==========================================================\n"
printf "   Worker node uninstall complete!\n"
printf "==========================================================\n"
printf "\n"
printf "containerd, Kubernetes components, and all related state\n"
printf "have been removed from this node.\n"
printf "\n"
printf "A reboot is recommended to ensure all kernel modules and\n"
printf "network changes take full effect:\n"
printf "  sudo reboot\n"
printf "\n"
printf "Logs: %s\n      %s\n" "$MAIN_LOG" "$ERR_LOG"
