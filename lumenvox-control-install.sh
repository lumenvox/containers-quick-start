#!/bin/bash
set -euo pipefail

#############################################
# Usage
#############################################
if [ $# -ne 1 ] && [ $# -ne 3 ]; then
    printf "Usage:\n"
    printf "  ./lumenvox-control-install.sh values.yaml\n"
    printf "  ./lumenvox-control-install.sh values.yaml server.key server.crt\n"
    exit 1
fi

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
# Resolve values.yaml to absolute path
#############################################
currentdir="`pwd`"
printf "\t\tactual path is %s ...\n" "$currentdir"

if [ ! -f "$1" ]; then
    printf "File %s not found!\n" "$1"
    exit 1
fi
VALUES_FILE="`readlink -f "$1"`"

#############################################
# Extract hostnameSuffix from values.yaml
#############################################
HOSTNAME_SUFFIX="`grep -E '^\s*hostnameSuffix\s*:' "$VALUES_FILE" \
    | sed 's/.*hostnameSuffix\s*:\s*//' \
    | sed 's/[\"'"'"']//g' \
    | tr -d '[:space:]'`"

if [ -z "$HOSTNAME_SUFFIX" ]; then
    printf "Error: could not extract 'hostnameSuffix' from %s.\n" "$VALUES_FILE"
    exit 1
fi
printf "\t\tDetected hostnameSuffix: %s\n" "$HOSTNAME_SUFFIX"

#############################################
# TLS: server.key and server.crt
#############################################
build_san() {
    local s="$1"
    local san="DNS:lumenvox-api${s}"
    san="${san}, DNS:biometric-api${s}"
    san="${san}, DNS:management-api${s}"
    san="${san}, DNS:reporting-api${s}"
    san="${san}, DNS:admin-portal${s}"
    san="${san}, DNS:deployment-portal${s}"
    san="${san}, DNS:file-store${s}"
    san="${san}, DNS:grafana${s}"
    printf '%s' "$san"
}

generate_server_key() {
    printf "\tGenerating server.key (RSA 2048-bit)...\n"
    openssl genrsa -out server.key 2048
    if [ $? -ne 0 ]; then
        printf "Error: failed to generate server.key.\n"
        exit 1
    fi
    printf "\t\tserver.key generated.\n"
    KEY_FILE="`readlink -f server.key`"
}

generate_server_crt() {
    local san cn
    san="`build_san "$HOSTNAME_SUFFIX"`"
    cn="${HOSTNAME_SUFFIX#.}"
    printf "\tGenerating self-signed server.crt (valid 10 years)...\n"
    printf "\t\tCN: %s\n" "$cn"
    printf "\t\tSANs: %s\n" "$san"
    openssl req -new -x509 -sha256 \
        -key "$KEY_FILE" \
        -out server.crt \
        -days 3650 \
        -subj "/CN=${cn}" \
        -addext "subjectAltName = ${san}"
    if [ $? -ne 0 ]; then
        printf "Error: failed to generate server.crt.\n"
        exit 1
    fi
    printf "\t\tserver.crt generated.\n"
    CERT_FILE="`readlink -f server.crt`"
}

handle_server_key() {
    printf "\n\tserver.key options:\n"
    printf "\t  1) Provide path to an existing server.key\n"
    printf "\t  2) Generate a new server.key\n"
    printf "\tChoice [1-2]: "
    read -r KEY_CHOICE </dev/tty
    case "$KEY_CHOICE" in
        1)
            printf "\tPath to server.key: "
            read -r KEY_PATH </dev/tty
            if [ ! -f "$KEY_PATH" ]; then
                printf "Error: server.key not found at '%s'.\n" "$KEY_PATH"
                exit 1
            fi
            KEY_FILE="`readlink -f "$KEY_PATH"`"
            printf "\t\tUsing existing server.key: %s\n" "$KEY_FILE"
            ;;
        2)
            generate_server_key
            ;;
        *)
            printf "Error: invalid choice '%s'.\n" "$KEY_CHOICE"
            exit 1
            ;;
    esac
}

handle_server_crt() {
    printf "\n\tserver.crt options:\n"
    printf "\t  1) Provide path to an existing server.crt\n"
    printf "\t  2) Generate a self-signed server.crt using hostnameSuffix from values.yaml\n"
    printf "\tChoice [1-2]: "
    read -r CRT_CHOICE </dev/tty
    case "$CRT_CHOICE" in
        1)
            printf "\tPath to server.crt: "
            read -r CRT_PATH </dev/tty
            if [ ! -f "$CRT_PATH" ]; then
                printf "Error: server.crt not found at '%s'.\n" "$CRT_PATH"
                exit 1
            fi
            CERT_FILE="`readlink -f "$CRT_PATH"`"
            printf "\t\tUsing existing server.crt: %s\n" "$CERT_FILE"
            ;;
        2)
            generate_server_crt
            ;;
        *)
            printf "Error: invalid choice '%s'.\n" "$CRT_CHOICE"
            exit 1
            ;;
    esac
}

if [ $# -eq 3 ]; then
    for f in "$2" "$3"; do
        if [ ! -f "$f" ]; then
            printf "File %s not found!\n" "$f"
            exit 1
        fi
    done
    KEY_FILE="`readlink -f "$2"`"
    CERT_FILE="`readlink -f "$3"`"
    printf "\t\tUsing provided server.key: %s\n" "$KEY_FILE"
    printf "\t\tUsing provided server.crt: %s\n" "$CERT_FILE"
else
    printf "\nNo TLS files provided -- entering interactive certificate setup.\n"
    if ! command -v openssl &>/dev/null; then
        printf "Error: 'openssl' is required but was not found.\n"
        exit 1
    fi
    handle_server_key
    handle_server_crt
fi

#############################################
# Version configuration
#############################################
K8S_VERSION="1.33"
CRICTL_VERSION="v1.33.0"
CALICO_VERSION="v3.29.7"
GATEWAY_API_VERSION="v1.2.1"
NGINX_INGRESS_VERSION="4.14.5"
LINKERD_INSTALL_URL="https://assets.lumenvox.com/third-party/linkerd/linkerd_install"

#############################################
# Minimum hardware requirements
#############################################
MIN_CPU_CORES=8
MIN_RAM_GB=15
MIN_DISK_GB=150

#############################################
# Log setup
#############################################
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
# Collect required passwords
#############################################
log "0b. Collecting service passwords..."

read_password() {
    local prompt="$1" varname="$2" val
    printf "\t\t%s: " "$prompt" >/dev/tty
    read -rs val </dev/tty
    printf "\n" >/dev/tty
    [ -n "$val" ] || die "Error: password for '$prompt' must not be empty."
    printf -v "$varname" '%s' "$val"
}

read_password "PostgreSQL user password"  POSTGRES_PASSWORD
read_password "MongoDB root password"     MONGO_INITDB_ROOT_PASSWORD
read_password "RabbitMQ password"         RABBITMQ_PASSWORD
read_password "Redis password"            REDIS_PASSWORD

#############################################
# Kernel pre-requisites
#############################################
log "0c. Configuring kernel modules and sysctl..."

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
            || die "		Failed to install yum-utils and curl from base OS repos."
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
# Step 4: Install Docker
#############################################
log "4. Installing Docker engine..."

pkg_install docker-ce docker-ce-cli docker-compose-plugin

log "	Starting Docker service..."
DOCKER_START_ATTEMPT_COUNTER=0
DOCKER_START_ATTEMPT_MAX=10
until sudo systemctl start docker 1>>"$MAIN_LOG" 2>>"$ERR_LOG"; do
    DOCKER_START_ATTEMPT_COUNTER=$(( DOCKER_START_ATTEMPT_COUNTER + 1 ))
    log "		systemctl start docker: failed attempt #${DOCKER_START_ATTEMPT_COUNTER}."
    [ "$DOCKER_START_ATTEMPT_COUNTER" -lt "$DOCKER_START_ATTEMPT_MAX" ] \
        || die "		Maximum start attempts reached. Wait a few minutes and try again."
    log "		Sleeping 30 seconds and retrying..."
    sleep 30
done

sudo systemctl enable docker 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "		Failed to enable Docker."

REAL_USER="$USER"
sudo usermod -aG docker "$REAL_USER" 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "		Failed to add $REAL_USER to docker group."

#############################################
# Step 5: Deploy external-services
#############################################
log "5. Deploying external-services..."

EXT_SVC_DIR="/home/$REAL_USER/external-services"
mkdir -p "$EXT_SVC_DIR" 1>>"$MAIN_LOG" 2>>"$ERR_LOG"

BASE_URL="https://raw.githubusercontent.com/lumenvox/external-services/master"
for fname in docker-compose.yaml rabbitmq.conf .env; do
    curl -fsSL -o "$EXT_SVC_DIR/$fname" "$BASE_URL/$fname" \
        1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || die "		Failed to download $fname from $BASE_URL."
done

ENV_FILE="$EXT_SVC_DIR/.env"

set_env_var() {
    local key="$1" val="$2" escaped_val
    if grep -qE "^[#]*\s*${key}=" "$ENV_FILE"; then
        escaped_val="`printf '%s' "$val" | sed 's/[\/&]/\\&/g'`"
        sed -i "s|^[#]*\s*${key}=.*|${key}=${escaped_val}|" "$ENV_FILE" \
            1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
            || die "		Failed to set $key in $ENV_FILE."
        log "		Set '$key' in $ENV_FILE."
    else
        log "		WARNING: key '$key' not found in $ENV_FILE -- skipping."
    fi
}

set_env_var MONGO_INITDB_ROOT_PASSWORD "$MONGO_INITDB_ROOT_PASSWORD"
set_env_var POSTGRES_PASSWORD          "$POSTGRES_PASSWORD"
set_env_var RABBITMQ_PASSWORD          "$RABBITMQ_PASSWORD"
set_env_var REDIS_PASSWORD             "$REDIS_PASSWORD"

( cd "$EXT_SVC_DIR" && sudo docker compose up -d 1>>"$MAIN_LOG" 2>>"$ERR_LOG" ) \
    || die "		Failed to start external-services."

#############################################
# Step 6: Install Kubernetes components
#############################################
log "6. Installing Kubernetes components..."

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
# Step 7: Initialize control plane
#############################################
if ! command -v crictl &>/dev/null; then
    log "	crictl not found -- installing..."
    CRICTL_TAR="crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"
    curl -fsSLO \
        "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${CRICTL_TAR}" \
        1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || die "		Failed to download crictl."
    sudo tar zxvf "$CRICTL_TAR" -C /usr/local/bin 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || die "		Failed to extract crictl."
    rm -f "$CRICTL_TAR"
fi

log "7. Initializing Kubernetes control plane..."

if sudo test -d /etc/kubernetes/pki 2>/dev/null \
        || sudo test -d /etc/kubernetes/manifests 2>/dev/null; then
    log "	Stale Kubernetes state detected -- running kubeadm reset before init..."
    sudo kubeadm reset --force 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
    sudo rm -rf /etc/kubernetes/pki       1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
    sudo rm -rf /etc/kubernetes/manifests 1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
    sudo rm -rf /var/lib/etcd             1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
    sudo rm -rf "$HOME/.kube"             1>>"$MAIN_LOG" 2>>"$ERR_LOG" || true
    log "	Stale state cleared."
fi

sudo kubeadm init 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "	Failed to initialize control plane."

#############################################
# Step 8: First-time cluster setup
#############################################
log "8. Performing first-time cluster setup..."

KUBE_HOME="`getent passwd "$REAL_USER" | cut -d: -f6`/.kube"
mkdir -p "$KUBE_HOME" 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "		Failed to create $KUBE_HOME."
sudo cp /etc/kubernetes/admin.conf "$KUBE_HOME/config" 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "		Failed to copy admin.conf."
sudo chown "$REAL_USER:$REAL_USER" "$KUBE_HOME/config" 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "		Failed to set ownership of $KUBE_HOME/config."
chmod 600 "$KUBE_HOME/config" \
    || die "		Failed to set permissions on $KUBE_HOME/config."
log "		kubectl configured at $KUBE_HOME/config."

log "	Waiting for Kubernetes API server to become ready..."
API_WAIT_ATTEMPTS=0
API_WAIT_MAX=24
until kubectl get nodes 1>>"$MAIN_LOG" 2>>"$ERR_LOG"; do
    API_WAIT_ATTEMPTS=$(( API_WAIT_ATTEMPTS + 1 ))
    [ "$API_WAIT_ATTEMPTS" -lt "$API_WAIT_MAX" ] \
        || die "	API server did not become ready after $(( API_WAIT_MAX * 5 )) seconds."
    log "		API server not ready yet (attempt ${API_WAIT_ATTEMPTS}/${API_WAIT_MAX}) -- retrying in 5 seconds..."
    sleep 5
done
log "	API server is ready."

log "	Waiting for node to register with the cluster..."
NODE=""
NODE_WAIT_ATTEMPTS=0
NODE_WAIT_MAX=24
until [ -n "$NODE" ]; do
    NODE="`kubectl get no -o custom-columns=NAME:.metadata.name --no-headers \
        2>>"$ERR_LOG" | head -1`"
    if [ -z "$NODE" ]; then
        NODE_WAIT_ATTEMPTS=$(( NODE_WAIT_ATTEMPTS + 1 ))
        [ "$NODE_WAIT_ATTEMPTS" -lt "$NODE_WAIT_MAX" ] \
            || die "		Node did not register after $(( NODE_WAIT_MAX * 5 )) seconds."
        log "		Node not registered yet (attempt ${NODE_WAIT_ATTEMPTS}/${NODE_WAIT_MAX}) -- retrying in 5 seconds..."
        sleep 5
    fi
done
log "		Node registered: $NODE"

log "	Removing control-plane NoSchedule taint..."
kubectl taint node "$NODE" node-role.kubernetes.io/control-plane- \
    1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "		Failed to remove NoSchedule taint from $NODE."

log "	Installing Calico CNI..."
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" \
    1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "		Failed to install Calico."

log "	Waiting for node '$NODE' to become Ready (this may take a few minutes)..."
NODE_READY_ATTEMPTS=0
NODE_READY_MAX=36
until kubectl get node "$NODE" --no-headers 2>>"$ERR_LOG" \
        | awk '{print $2}' | grep -q "^Ready$"; do
    NODE_READY_ATTEMPTS=$(( NODE_READY_ATTEMPTS + 1 ))
    [ "$NODE_READY_ATTEMPTS" -lt "$NODE_READY_MAX" ] \
        || die "		Node '$NODE' did not become Ready after $(( NODE_READY_MAX * 10 )) seconds."
    log "		Node not Ready yet (attempt ${NODE_READY_ATTEMPTS}/${NODE_READY_MAX}) -- retrying in 10 seconds..."
    sleep 10
done
log "		Node '$NODE' is Ready."

#############################################
# Step 9: Install Linkerd
#############################################
log "9. Installing Linkerd..."

if ! lsmod | grep -q ip_tables; then
    log "	ip_tables module not loaded -- loading now..."
    sudo modprobe ip_tables 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || log "		WARNING: Could not load ip_tables. Attempting to proceed."
fi

curl --proto '=https' --tlsv1.2 -sSfLo linkerd_install \
    "$LINKERD_INSTALL_URL" \
    1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "		Failed to download Linkerd install script."

chmod +x linkerd_install
./linkerd_install 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || { rm -f linkerd_install; die "		Failed to install Linkerd CLI."; }
rm -f linkerd_install

export PATH="$PATH:$HOME/.linkerd2/bin"

log "	Running Linkerd pre-check..."
linkerd check --pre 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "	System does not meet Linkerd requirements."

log "	Applying Gateway API CRDs..."
kubectl apply \
    -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
    1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "	Failed to apply Gateway API CRDs."

linkerd_apply() {
    local label="$1" outfile="$2"
    shift 2
    log "	Rendering ${label}..."
    "$@" >"$outfile" 2>>"$ERR_LOG" \
        || { rm -f "$outfile"; die "	Failed to render ${label}."; }
    log "	Applying ${label}..."
    kubectl apply -f "$outfile" 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || { rm -f "$outfile"; die "	Failed to apply ${label}."; }
    rm -f "$outfile"
}

linkerd_apply "Linkerd CRDs"          linkerd_crds.yaml  linkerd install --crds
linkerd_apply "Linkerd control plane" linkerd_cp.yaml    \
    linkerd install --set proxyInit.runAsRoot=true --set proxyInit.iptablesMode=nft
linkerd_apply "Linkerd viz dashboard" linkerd_viz.yaml   linkerd viz install

log "	Waiting 30 seconds for Linkerd pods to start..."
sleep 30

log "	Running Linkerd post-install check..."
linkerd check 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "		Linkerd failed post-install check. Review log files."

#############################################
# Step 10: Install Helm
#############################################
log "10. Installing Helm..."

curl -fsSL -o get_helm.sh \
    https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "		Failed to download Helm install script."
chmod 700 get_helm.sh
./get_helm.sh 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || { rm -f get_helm.sh; die "		Failed to install Helm."; }
rm -f get_helm.sh

#############################################
# Step 11: Install Capacity Private Cloud stack
#############################################
log "11. Installing Capacity Private Cloud stack..."

helm repo add lumenvox https://lumenvox.github.io/helm-charts \
    1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "	Failed to add LumenVox Helm repo."
helm repo update 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "	Failed to update Helm repos."

kubectl create ns lumenvox 1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "	Failed to create lumenvox namespace."

create_k8s_secret() {
    local name="$1" key="$2" val="$3"
    kubectl create secret generic "$name" \
        --from-literal="${key}=${val}" \
        -n lumenvox \
        1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
        || die "	Failed to create secret $name."
}

create_k8s_secret mongodb-existing-secret  mongodb-root-password  "$MONGO_INITDB_ROOT_PASSWORD"
create_k8s_secret postgres-existing-secret postgresql-password    "$POSTGRES_PASSWORD"
create_k8s_secret rabbitmq-existing-secret rabbitmq-password      "$RABBITMQ_PASSWORD"
create_k8s_secret redis-existing-secret    redis-password         "$REDIS_PASSWORD"

log "	Creating speech-tls-secret..."
kubectl create secret tls speech-tls-secret \
    --key  "$KEY_FILE" \
    --cert "$CERT_FILE" \
    -n lumenvox \
    1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "	Failed to create speech-tls-secret."

log "	Deploying LumenVox Helm chart..."
helm install lumenvox lumenvox/lumenvox \
    -n lumenvox \
    -f "$VALUES_FILE" \
    1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "	Failed to deploy LumenVox Helm chart."

#############################################
# Step 12: Install nginx ingress controller
#############################################
log "12. Installing nginx ingress controller..."

helm upgrade --install ingress-nginx ingress-nginx \
    --repo https://kubernetes.github.io/ingress-nginx \
    -n ingress-nginx --create-namespace \
    --set controller.hostNetwork=true \
    --version "$NGINX_INGRESS_VERSION" \
    1>>"$MAIN_LOG" 2>>"$ERR_LOG" \
    || die "		Failed to install nginx ingress controller."

#############################################
# Step 13: Gather worker join info
#############################################
KUBEADM_JOIN_TOKEN="`kubeadm token list 2>>"$ERR_LOG" | tail -n 1 | awk '{print $1}'`"
KUBEADM_JOIN_HASH="sha256:`openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -pubkey | openssl rsa -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}'`"

#############################################
# Step 14: Extract SANs for hosts file note
#############################################
# Pull the IP from the default route interface as the likely control-plane IP
CONTROL_PLANE_IP="`ip route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}'`"
[ -n "$CONTROL_PLANE_IP" ] || CONTROL_PLANE_IP="<CONTROL-PLANE-IP>"

# Build the list of FQDNs from the same SAN builder used for the certificate
SANS_LIST="lumenvox-api${HOSTNAME_SUFFIX}
biometric-api${HOSTNAME_SUFFIX}
management-api${HOSTNAME_SUFFIX}
reporting-api${HOSTNAME_SUFFIX}
admin-portal${HOSTNAME_SUFFIX}
deployment-portal${HOSTNAME_SUFFIX}
file-store${HOSTNAME_SUFFIX}
grafana${HOSTNAME_SUFFIX}"

#############################################
# Done
#############################################
printf "\n"
printf "==========================================================\n"
printf "   Capacity Private Cloud installation complete!\n"
printf "==========================================================\n"
printf "\n"
printf "Pods are now starting up. Monitor progress with:\n"
printf "  watch kubectl get po -A\n"
printf "\n"
printf "Linkerd is installed but not permanently on PATH.\n"
printf "Add this to ~/.bashrc to persist it:\n"
printf "  export PATH=\$PATH:\$HOME/.linkerd2/bin\n"
printf "\n"
printf "To join a worker node to this cluster, run on the worker:\n"
printf "  ./lumenvox-worker-install.sh <control-plane-IP> %s %s\n" "$KUBEADM_JOIN_TOKEN" "$KUBEADM_JOIN_HASH"
printf "\n"
printf "NOTE: '%s' was added to the 'docker' group.\n" "$REAL_USER"
printf "      Log out and back in (or run 'newgrp docker') for this to take effect.\n"
printf "\n"
printf "==========================================================\n"
printf "   IMPORTANT: DNS / Hosts File Configuration Required\n"
printf "==========================================================\n"
printf "\n"
printf "No DNS records exist for the certificate SANs. Each client machine\n"
printf "that needs to reach the LumenVox endpoints must add the following\n"
printf "entries to its hosts file:\n"
printf "\n"
printf "  Control-plane IP detected: %s\n" "$CONTROL_PLANE_IP"
printf "  (Replace with the correct IP if this machine sits behind a load\n"
printf "   balancer or has multiple interfaces.)\n"
printf "\n"

# Print the ready-to-paste hosts entries
while IFS= read -r fqdn; do
    printf "  %s %s\n" "$CONTROL_PLANE_IP" "$fqdn"
done <<< "$SANS_LIST"

printf "\n"
printf "  --- Linux clients ---\n"
printf "  Edit (as root/sudo):  /etc/hosts\n"
printf "\n"
printf "  --- Windows clients ---\n"
printf "  Edit (as Administrator):\n"
printf "%s\n" 'C:\Windows\System32\drivers\etc\hosts'
printf "\n"
printf "  Tip: On Windows, open Notepad as Administrator, then\n"
printf "  File > Open the path above to edit and save.\n"
printf "\n"
printf "==========================================================\n"
printf "\n"
printf "Logs: %s\n      %s\n" "$MAIN_LOG" "$ERR_LOG"