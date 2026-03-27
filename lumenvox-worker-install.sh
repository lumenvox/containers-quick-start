#!/bin/bash
set -euo pipefail

#############################################
# Usage
#############################################
if [ $# -ne 3 ]; then
    printf "Usage: ./lumenvox-worker-install.sh CONTROL_PLANE_IP TOKEN HASH\n"
    exit 1
fi

CONTROL_PLANE_IP="$1"
JOIN_TOKEN="$2"
JOIN_HASH="$3"

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
# Version configuration
#############################################
K8S_VERSION="1.33"
CRICTL_VERSION="v1.33.0"

#############################################
# Log setup
#############################################
currentdir="`pwd`"
MAIN_LOG="$currentdir/main-log.txt"
ERR_LOG="$currentdir/err-log.txt"
> "$MAIN_LOG"
> "$ERR_LOG"

log() { printf "%s\n" "$*" | tee -a "$MAIN_LOG"; }
err() { printf "%s\n" "$*" | tee -a "$MAIN_LOG" "$ERR_LOG" >&2; }
die() { err "$*"; exit 1; }

#############################################
# Step 0: OS detection & validation
#############################################
log "0. Detecting OS..."

OS="`uname | tr '[:upper:]' '[:lower:]'`"
[ "$OS" = "linux" ] || die "Invalid OS '$OS': must be linux."

DISTRO="`grep ^ID= /etc/*-release -h 2>/dev/null | cut -d'=' -f2 | tr -d '\"' | head -1`"
ARCH="`uname -m`"

case "$DISTRO" in
  ubuntu) ;;
  centos | rhel | rocky) ;;
  almalinux)
    ALMA_VER="`grep ^VERSION_ID= /etc/*-release -h 2>/dev/null \
        | cut -d'=' -f2 | tr -d '\"' | cut -d'.' -f1 | head -1`"
    [ "$ALMA_VER" = "9" ] || die "Error: AlmaLinux version '$ALMA_VER' is not supported. Only AlmaLinux 9 is supported."
    ;;
  *)
    die "Error: distribution '$DISTRO' is not supported."
    ;;
esac

log "	Detected: distro=$DISTRO arch=$ARCH"

#############################################
# Minimum hardware requirements
#############################################
MIN_CPU_CORES=8
MIN_RAM_GB=15
MIN_DISK_GB=150

#############################################
# Pre-flight checks
#############################################
log "0a. Running pre-flight checks..."

CPU_CORES="`nproc --all`"
log "	Checking CPU cores (minimum ${MIN_CPU_CORES} required)..."
[ "$CPU_CORES" -ge "$MIN_CPU_CORES" ] || \
    die "	ERROR: Insufficient CPU cores. Required: ${MIN_CPU_CORES}, Available: ${CPU_CORES}."
log "		CPU OK: ${CPU_CORES} cores available."

RAM_KB="`awk '/^MemTotal:/{print $2}' /proc/meminfo`"
RAM_GB=$(( RAM_KB / 1024 / 1024 ))
log "	Checking RAM (minimum ${MIN_RAM_GB} GB required)..."
[ "$RAM_GB" -ge "$MIN_RAM_GB" ] || \
    die "	ERROR: Insufficient RAM. Required: ${MIN_RAM_GB} GB, Available: ${RAM_GB} GB."
log "		RAM OK: ${RAM_GB} GB available."

DISK_FREE_KB="`df --output=avail / | tail -1`"
DISK_FREE_GB=$(( DISK_FREE_KB / 1024 / 1024 ))
log "	Checking available disk space (minimum ${MIN_DISK_GB} GB required)..."
[ "$DISK_FREE_GB" -ge "$MIN_DISK_GB" ] || \
    die "	ERROR: Insufficient disk space. Required: ${MIN_DISK_GB} GB, Available: ${DISK_FREE_GB} GB."
log "		Disk space OK: ${DISK_FREE_GB} GB available."

log "	Checking network connectivity to Kubernetes package repository..."
curl -fsSL --max-time 10 --silent --output /dev/null "https://pkgs.k8s.io" || \
    die "	ERROR: Cannot reach https://pkgs.k8s.io. Verify network connectivity and DNS before retrying."
log "		Kubernetes repository connectivity OK."

#############################################
# Kernel pre-requisites
#############################################
log "0a. Configuring kernel modules and sysctl..."

sudo tee /etc/modules-load.d/k8s.conf >/dev/null <<'KMOD'
ip_tables
overlay
br_netfilter
KMOD

for mod in ip_tables overlay br_netfilter; do
    sudo modprobe "$mod" 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || log "	WARNING: failed to modprobe $mod -- may already be built-in."
done

sudo tee /etc/sysctl.d/k8s.conf >/dev/null <<'SYSCTL'
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
SYSCTL

sudo sysctl --system 1>>"$MAIN_LOG" 2>>"$ERR_LOG"

#############################################
# Firewall / AppArmor / SELinux
#############################################
log "1. Disabling firewall and MAC frameworks..."

case "$DISTRO" in
  ubuntu)
    for svc in ufw apparmor; do
        sudo systemctl stop    "$svc" 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
        sudo systemctl disable "$svc" 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
    done
    ;;
  centos | rhel | rocky | almalinux)
    sudo systemctl stop    firewalld 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
    sudo systemctl disable firewalld 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
    sudo setenforce 0 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
    if [ -f /etc/selinux/config ]; then
        sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
    fi
    ;;
esac

#############################################
# Swap
#############################################
SWAP_DEVICES="`swapon --show | wc -l`"
if [ "$SWAP_DEVICES" -gt 0 ]; then
    log "	Swap detected -- disabling (required for Kubernetes)..."
    sudo swapoff -a 1>>"$MAIN_LOG" 2>>"$ERR_LOG"
    sudo sed -i '/swap/ s/^\(.*\)$/#\1/g' /etc/fstab 1>>"$MAIN_LOG" 2>>"$ERR_LOG"
    log "	Swap disabled and commented out in /etc/fstab."
else
    log "	Swap is already off."
fi

#############################################
# Helper: pkg_remove / pkg_install
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

pkg_install() {
    case "$DISTRO" in
      ubuntu)
        sudo apt-get install -y "$@" 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            || die "		Failed to install: $*"
        ;;
      centos | rhel | rocky | almalinux)
        sudo yum install -y --allowerasing "$@" 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            || die "		Failed to install: $*"
        ;;
    esac
}

#############################################
# Step 2: Uninstall legacy Docker if present
#############################################
log "2. Checking for existing Docker installation..."

if command -v docker 1>>"$MAIN_LOG" 2>>"$ERR_LOG"; then
    log "	Removing existing Docker packages..."
    case "$DISTRO" in
      ubuntu)
        pkg_remove docker docker-engine docker.io runc
        sudo apt-get purge -y \
            docker-ce docker-ce-cli docker-buildx-plugin \
            docker-compose-plugin docker-ce-rootless-extras \
            1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
        ;;
      centos | rhel | rocky | almalinux)
        pkg_remove \
            docker docker-client docker-client-latest docker-common \
            docker-latest docker-latest-logrotate docker-logrotate docker-engine \
            docker-ce docker-ce-cli docker-buildx-plugin \
            docker-compose-plugin docker-ce-rootless-extras
        ;;
    esac
    sudo rm -rf /var/lib/docker 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || die "		Failed to remove /var/lib/docker."
    log "	Docker removed."
else
    log "	Docker not found, skipping removal."
fi

#############################################
# Step 3: Install containerd
#############################################
log "3. Installing containerd..."

configure_containerd() {
    log "		Writing default containerd config with SystemdCgroup=true..."
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1 \
        || die "		Failed to generate containerd default config."
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml \
        1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || die "		Failed to set SystemdCgroup=true."
    sudo systemctl restart containerd 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || die "		Failed to restart containerd."
    sudo systemctl enable containerd 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || die "		Failed to enable containerd."
}

if command -v containerd 1>>"$MAIN_LOG" 2>>"$ERR_LOG"; then
    CG_VAL="`sudo grep -m1 SystemdCgroup /etc/containerd/config.toml 2>>"$ERR_LOG" \
        | awk '{print $NF}'`"
    if [ "$CG_VAL" != "true" ]; then
        log "	Containerd present but SystemdCgroup!=true -- fixing..."
        sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' \
            /etc/containerd/config.toml 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            || die "		Failed to set SystemdCgroup=true."
        sudo systemctl restart containerd 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            || die "		Failed to restart containerd after config fix."
    else
        log "	Containerd already installed and correctly configured, skipping."
    fi
else
    case "$DISTRO" in
      ubuntu)
        sudo apt-get update -y 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            || die "		Failed to update apt."
        pkg_install ca-certificates curl gnupg
        sudo mkdir -p /etc/apt/keyrings

        log "	Fetching Docker GPG key..."
        curl -fsSLo docker.gpg https://download.docker.com/linux/ubuntu/gpg \
            1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            || die "		Failed to download Docker GPG key."
        sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg docker.gpg \
            1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            && rm -f docker.gpg \
            || { rm -f docker.gpg; die "		Failed to install Docker GPG key."; }

        DPKG_ARCH="`dpkg --print-architecture`"
        UBUNTU_CODENAME="`lsb_release -cs`"
        echo "deb [arch=${DPKG_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null \
            || die "		Failed to add Docker repository."

        sudo apt-get update -y 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            || die "		Failed to update apt after adding Docker repo."
        pkg_install containerd.io
        ;;

      centos | rhel | rocky | almalinux)
        sudo yum install -y yum-utils curl 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            || die "		Failed to install yum-utils and curl."
        sudo yum-config-manager --add-repo \
            https://download.docker.com/linux/centos/docker-ce.repo \
            1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            || die "		Failed to add Docker yum repo."
        pkg_install containerd.io
        ;;
    esac

    configure_containerd
fi

#############################################
# Step 4: Install Kubernetes components
#############################################
log "4. Installing Kubernetes components..."

case "$DISTRO" in
  centos | rhel | rocky | almalinux)
    if [ "$DISTRO" = "almalinux" ]; then
        log "	Verifying iptables-nft is present on AlmaLinux 9..."
        pkg_install iptables-nft
    fi

    sudo tee /etc/yum.repos.d/kubernetes.repo >/dev/null <<KUBErepo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
KUBErepo

    if selinuxenabled 2>/dev/null; then
        log "	Setting SELinux to permissive..."
        sudo setenforce 0 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
        if [ -f /etc/selinux/config ]; then
            sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
        fi
    fi

    sudo yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes \
        1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || die "		Failed to install Kubernetes components."
    sudo systemctl enable --now kubelet 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true

    sudo yum -y install python3-dnf-plugin-versionlock 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
    sudo yum versionlock kubeadm kubelet kubectl       1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
    ;;

  ubuntu)
    pkg_install apt-transport-https ca-certificates curl
    sudo mkdir -p /etc/apt/keyrings

    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
        | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
        1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || die "		Failed to add Kubernetes GPG key."

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
        | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null \
        || die "		Failed to add Kubernetes apt repository."

    sudo apt-get update -y 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || die "		Failed to update apt."
    pkg_install kubelet kubeadm kubectl

    sudo apt-mark hold kubelet kubeadm kubectl \
        || die "		Failed to hold Kubernetes packages."
    ;;
esac

sudo systemctl enable --now kubelet 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "		Failed to enable/start kubelet."

BRIDGE_VAL="`sysctl -n net.bridge.bridge-nf-call-iptables 2>>"$ERR_LOG" || echo 0`"
if [ "$BRIDGE_VAL" -ne 1 ]; then
    log "	Setting net.bridge.bridge-nf-call-iptables=1..."
    sudo sysctl net.bridge.bridge-nf-call-iptables=1 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || die "		Failed to set net.bridge.bridge-nf-call-iptables=1."
fi

#############################################
# Step 5: Install crictl if missing
#############################################
if ! command -v crictl &>/dev/null; then
    log "5. crictl not found -- installing..."
    CRICTL_TAR="crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"
    curl -fsSLO \
        "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${CRICTL_TAR}" \
        1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || die "		Failed to download crictl."
    sudo tar zxvf "$CRICTL_TAR" -C /usr/local/bin 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || die "		Failed to extract crictl."
    rm -f "$CRICTL_TAR"
    log "	crictl installed."
else
    log "5. crictl already installed, skipping."
fi

#############################################
# Step 6: Join the control plane
#############################################
log "6. Joining control plane at ${CONTROL_PLANE_IP}..."

sudo kubeadm join "${CONTROL_PLANE_IP}:6443" \
    --token "${JOIN_TOKEN}" \
    --discovery-token-ca-cert-hash "${JOIN_HASH}" \
    1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "	Failed to join control plane at ${CONTROL_PLANE_IP}."

#############################################
# Done
#############################################
printf "\n"
printf "==========================================================\n"
printf "   Worker node join complete!\n"
printf "==========================================================\n"
printf "\n"
printf "This node is now registered with the cluster.\n"
printf "Verify on the control plane with:\n"
printf "  kubectl get nodes\n"
printf "\n"
printf "Logs: %s\n      %s\n" "$MAIN_LOG" "$ERR_LOG"
