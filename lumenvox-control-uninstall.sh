#!/bin/bash
set -uo pipefail
# Note: set -e is intentionally omitted — uninstall steps should be best-effort
# and continue even if individual steps fail.

#############################################
# Usage & privilege checks
#############################################
if [ "$(id -u)" -eq 0 ]; then
    printf "Error: do not run this script as root. Run as a user with sudo privileges.\n"
    exit 1
fi
if ! sudo -n true 2>/dev/null && ! sudo -v 2>/dev/null; then
    printf "Error: current user '%s' does not have sudo privileges.\n" "$USER"
    exit 1
fi

#############################################
# Confirmation prompt
#############################################
printf "WARNING: This script will completely remove the Capacity Private Cloud stack, Kubernetes,\n"
printf "         Linkerd, Helm, Docker, containerd, all associated data,\n"
printf "         and all Capacity Private Cloud model files under /data.\n"
printf "         This action is IRREVERSIBLE.\n\n"
printf "Type 'yes' to confirm: "
read -r CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    printf "Aborted.\n"
    exit 0
fi

#############################################
# Log setup
#############################################
currentdir="$(pwd)"
MAIN_LOG="$currentdir/uninstall-main-log.txt"
ERR_LOG="$currentdir/uninstall-err-log.txt"
> "$MAIN_LOG"
> "$ERR_LOG"

log()  { printf "%s\n" "$*" | tee -a "$MAIN_LOG"; }
warn() { printf "WARNING: %s\n" "$*" | tee -a "$MAIN_LOG" "$ERR_LOG" >&2; }

# Run a command, log it, warn on failure but do NOT exit
run() {
    log "\t+ $*"
    if ! "$@" 1>>"$MAIN_LOG" 2>>"$ERR_LOG"; then
        warn "Command failed (continuing): $*"
    fi
}

#############################################
# OS detection
#############################################
DISTRO="$(grep ^ID= /etc/*-release -h 2>/dev/null | cut -d'=' -f2 | tr -d '"' | head -1)"

case "$DISTRO" in
  ubuntu | centos | rhel | rocky | almalinux) ;;
  *)
    printf "Error: distribution '$DISTRO' is not supported.\n"
    exit 1
    ;;
esac

log "Detected distro: $DISTRO"
REAL_USER="$USER"

#############################################
# Step 1: Remove LumenVox Helm release & namespace
#############################################
log "1. Removing LumenVox Helm release and namespace..."

if command -v helm &>/dev/null && command -v kubectl &>/dev/null; then
    run helm uninstall lumenvox     -n lumenvox     --ignore-not-found 2>/dev/null || \
        warn "helm uninstall lumenvox failed — may already be removed."
    run helm uninstall ingress-nginx -n ingress-nginx --ignore-not-found 2>/dev/null || \
        warn "helm uninstall ingress-nginx failed — may already be removed."
    run kubectl delete ns lumenvox     --ignore-not-found=true
    run kubectl delete ns ingress-nginx --ignore-not-found=true
else
    warn "helm or kubectl not found — skipping Helm/namespace removal."
fi

#############################################
# Step 2: Remove Linkerd
#############################################
log "2. Removing Linkerd..."

# Add linkerd to PATH in case it was installed but not yet in the shell's PATH
export PATH="$PATH:$HOME/.linkerd2/bin"

if command -v linkerd &>/dev/null && command -v kubectl &>/dev/null; then
    # Pipe directly — do not wrap in run() as these are compound commands
    log "\tUninstalling Linkerd viz..."
    linkerd viz uninstall 2>>"$ERR_LOG" | kubectl delete --ignore-not-found=true -f - \
        1>>"$MAIN_LOG" 2>>"$ERR_LOG" || warn "Failed to uninstall Linkerd viz."
    log "\tUninstalling Linkerd control plane..."
    linkerd uninstall 2>>"$ERR_LOG" | kubectl delete --ignore-not-found=true -f - \
        1>>"$MAIN_LOG" 2>>"$ERR_LOG" || warn "Failed to uninstall Linkerd control plane."
else
    warn "linkerd CLI or kubectl not found — skipping Linkerd uninstall."
fi

# Remove Gateway API CRDs applied during install
if command -v kubectl &>/dev/null; then
    GATEWAY_API_VERSION="v1.2.1"
    run kubectl delete \
        -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
        --ignore-not-found=true
fi

# Remove the linkerd binary and its directory
run rm -rf "$HOME/.linkerd2"

# Remove linkerd PATH entry from .bashrc if it was added
if [ -f "$HOME/.bashrc" ]; then
    sed -i '/\.linkerd2\/bin/d' "$HOME/.bashrc" 2>>"$ERR_LOG" || \
        warn "Failed to remove linkerd PATH entry from .bashrc."
fi

#############################################
# Step 3: Tear down Kubernetes cluster
#############################################
log "3. Tearing down Kubernetes cluster..."

run sudo kubeadm reset --force
run sudo rm -rf /etc/kubernetes
run sudo rm -rf /var/lib/kubelet
run sudo rm -rf /var/lib/etcd
run sudo rm -rf "$HOME/.kube"

# Remove Calico CNI config and plugins
run sudo rm -rf /etc/cni/net.d
run sudo rm -rf /opt/cni/bin

# Flush iptables rules left behind by Kubernetes/Calico
# Only attempt if iptables is available (may not be present post-package-removal)
if command -v iptables &>/dev/null; then
    run sudo iptables  -F
    run sudo iptables  -t nat    -F
    run sudo iptables  -t mangle -F
    run sudo iptables  -X
fi
if command -v ip6tables &>/dev/null; then
    run sudo ip6tables -F
    run sudo ip6tables -t nat    -F
    run sudo ip6tables -t mangle -F
    run sudo ip6tables -X
fi

# Remove virtual network interfaces created by Calico/Kubernetes
# Strip trailing @<parent> suffix that ip link appends (e.g. "cali1234@eth0")
while IFS= read -r iface; do
    iface="${iface%%@*}"   # strip @<parent> suffix
    iface="${iface%:}"     # strip trailing colon if present
    [ -z "$iface" ] && continue
    log "\tRemoving network interface: $iface"
    sudo ip link set "$iface" down   2>>"$ERR_LOG" || true
    sudo ip link delete "$iface"     2>>"$ERR_LOG" || true
done < <(ip link show 2>/dev/null | awk -F': ' '/^[0-9]+: (cali|tunl|vxlan|flannel|cni)/{print $2}')

#############################################
# Step 4: Uninstall Kubernetes packages
#############################################
log "4. Uninstalling Kubernetes packages..."

case "$DISTRO" in
  ubuntu)
    run sudo apt-mark unhold kubelet kubeadm kubectl
    run sudo apt-get remove -y kubelet kubeadm kubectl
    run sudo apt-get purge  -y kubelet kubeadm kubectl
    run sudo rm -f /etc/apt/sources.list.d/kubernetes.list
    run sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    run sudo apt-get autoremove -y
    ;;
  centos | rhel | rocky | almalinux)
    # Remove versionlock before attempting package removal
    run sudo yum versionlock delete kubeadm kubelet kubectl
    run sudo yum -y remove kubelet kubeadm kubectl
    run sudo rm -f /etc/yum.repos.d/kubernetes.repo
    ;;
esac

run sudo rm -f /usr/local/bin/crictl

#############################################
# Step 5: Uninstall Helm
#############################################
log "5. Uninstalling Helm..."

if command -v helm &>/dev/null; then
    HELM_BIN="$(command -v helm)"
    run sudo rm -f "$HELM_BIN"
else
    warn "helm binary not found — skipping."
fi
run rm -rf "$HOME/.config/helm"
run rm -rf "$HOME/.cache/helm"
run rm -rf "$HOME/.local/share/helm"

#############################################
# Step 6: Stop and remove external-services
#############################################
log "6. Stopping external-services (Docker Compose)..."

EXT_SVC_DIR="/home/$REAL_USER/external-services"
if [ -f "$EXT_SVC_DIR/docker-compose.yaml" ]; then
    ( cd "$EXT_SVC_DIR" && sudo docker compose down -v 1>>"$MAIN_LOG" 2>>"$ERR_LOG" ) || \
        warn "docker compose down failed — containers may need manual removal."
    run rm -rf "$EXT_SVC_DIR"
else
    warn "external-services directory not found at $EXT_SVC_DIR — skipping."
fi

#############################################
# Step 7: Remove Docker
#############################################
log "7. Removing Docker..."

# Stop docker.socket first to prevent it from auto-restarting docker.service
sudo systemctl stop   docker.socket 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
sudo systemctl stop   docker        1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
sudo systemctl disable docker       1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true

case "$DISTRO" in
  ubuntu)
    run sudo apt-get remove -y docker-ce docker-ce-cli docker-compose-plugin \
        docker-buildx-plugin docker-ce-rootless-extras
    run sudo apt-get purge  -y docker-ce docker-ce-cli docker-compose-plugin \
        docker-buildx-plugin docker-ce-rootless-extras
    run sudo rm -f /etc/apt/sources.list.d/docker.list
    run sudo rm -f /etc/apt/keyrings/docker.gpg
    run sudo apt-get autoremove -y
    ;;
  centos | rhel | rocky | almalinux)
    run sudo yum -y remove docker-ce docker-ce-cli docker-compose-plugin \
        docker-buildx-plugin docker-ce-rootless-extras
    run sudo yum-config-manager --disable docker-ce-stable
    run sudo rm -f /etc/yum.repos.d/docker-ce.repo
    ;;
esac

run sudo rm -rf /var/lib/docker
run sudo rm -rf /var/lib/containerd
run sudo rm -rf /etc/docker

# Remove current user from the docker group
run sudo gpasswd -d "$REAL_USER" docker

#############################################
# Step 8: Remove containerd
#############################################
log "8. Removing containerd..."

sudo systemctl stop    containerd 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
sudo systemctl disable containerd 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true

case "$DISTRO" in
  ubuntu)
    run sudo apt-get remove -y containerd.io
    run sudo apt-get purge  -y containerd.io
    run sudo apt-get autoremove -y
    ;;
  centos | rhel | rocky | almalinux)
    run sudo yum -y remove containerd.io
    ;;
esac

run sudo rm -rf /etc/containerd

# AlmaLinux 9 note: the installer uses iptables-nft natively and never installs
# iptables-legacy, so no iptables alternative restoration is needed here.

#############################################
# Step 9: Remove kernel configuration
#############################################
log "9. Removing kernel module and sysctl configuration..."

run sudo rm -f /etc/modules-load.d/k8s.conf
run sudo rm -f /etc/sysctl.d/k8s.conf
run sudo sysctl --system 1>>"$MAIN_LOG" 2>>"$ERR_LOG"

# Unload kernel modules (best-effort — may be in use or built-in)
for mod in br_netfilter overlay; do
    sudo modprobe -r "$mod" 2>>"$ERR_LOG" || true
done
# Do not unload ip_tables — it may be required by the base OS firewall

#############################################
# Step 10: Re-enable firewall and security frameworks
#############################################
log "10. Re-enabling firewall and security frameworks..."

case "$DISTRO" in
  ubuntu)
    run sudo systemctl enable ufw
    run sudo systemctl start  ufw
    # AppArmor: only re-enable if the unit file exists on this system
    if systemctl list-unit-files apparmor.service &>/dev/null; then
        run sudo systemctl enable apparmor
        run sudo systemctl start  apparmor
    fi
    ;;
  centos | rhel | rocky | almalinux)
    run sudo systemctl enable firewalld
    run sudo systemctl start  firewalld
    log "\tNOTE: SELinux was set to permissive by the installer. To re-enable enforcing mode,"
    log "\t      edit /etc/selinux/config and set SELINUX=enforcing, then reboot."
    ;;
esac

#############################################
# Step 11: Re-enable swap
#############################################
log "11. Re-enabling swap..."
log "\tNOTE: Swap entries were commented out in /etc/fstab by the installer."
log "\t      To restore swap permanently, edit /etc/fstab and uncomment any swap lines,"
log "\t      then run: sudo swapon -a"
sudo swapon -a 2>>"$ERR_LOG" || true

#############################################
# Step 12: Remove Capacity Private Cloud model files
#############################################
log "12. Removing Capacity Private Cloud model files (/data)..."

if [ -d /data ]; then
    run sudo rm -rf /data
    log "\t/data removed."
else
    warn "/data directory not found — skipping."
fi

#############################################
# Done
#############################################
cat <<EOF

╔══════════════════════════════════════════════════════════════╗
║        Capacity Private Cloud uninstall complete!            ║
╚══════════════════════════════════════════════════════════════╝

Items that require manual follow-up:
  - SELinux: set SELINUX=enforcing in /etc/selinux/config and reboot to restore
             (RHEL/CentOS/Rocky/AlmaLinux only)
  - Swap:    uncomment swap entries in /etc/fstab and run 'sudo swapon -a'
  - Docker group: log out and back in for group membership changes to take effect
  - A reboot is recommended to ensure all kernel state is fully cleared.

Logs: $MAIN_LOG
      $ERR_LOG
EOF
