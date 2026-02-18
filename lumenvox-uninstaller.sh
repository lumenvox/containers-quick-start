
#!/bin/bash

# Prefer os-release; fallback to any *-release for ID
if [ -f /etc/os-release ]; then
    DISTRO=$(grep ^ID= /etc/os-release | cut -d '=' -f 2 | tr -d '"' | head -1)
else
    DISTRO=$(grep ^ID= /etc/*-release -h 2>/dev/null | cut -d '=' -f 2 | tr -d '"' | head -1)
fi



# Step 1: Reset kubeadm (skip if kubeadm not installed)
if ! command -v kubeadm &>/dev/null; then
    printf "kubeadm not found, skipping kubeadm reset.\n"
else
KUBEADM_RESET_COUNTER=0
KUBEADM_RESET_MAX=5
while [ "$KUBEADM_RESET_COUNTER" -lt "$KUBEADM_RESET_MAX" ]; do
    sudo kubeadm reset --v=5 -f
    if [ $? -ne 0 ]; then
        KUBEADM_RESET_COUNTER=$(( $KUBEADM_RESET_COUNTER + 1 ))
        printf "\t\tkubeadm reset: failed attempt #$KUBEADM_RESET_COUNTER."
        if [ "$KUBEADM_RESET_COUNTER" -eq "$KUBEADM_RESET_MAX" ]; then
            printf " Maximum number of attempts reached. Wait a few minutes and try again.\n"
            exit 1
        else
            printf " Retrying...\n"
        fi
    else
        break
    fi
done
fi

# Clean up what kubeadm reset won't
sudo rm -rf /etc/cni/net.d



# Step 2: Uninstall helm
if command -v helm &>/dev/null; then
    # First, delete all the helm data directories...
    HELM_DATA_DIRECTORIES=( 'HELM_CACHE_HOME'
                            'HELM_CONFIG_HOME'
                            'HELM_DATA_HOME')
    for dir in "${HELM_DATA_DIRECTORIES[@]}"
    do
        dirpath=$(helm env 2>/dev/null | grep "$dir" | cut -d '=' -f 2 | tr -d '"')
        if [ -n "$dirpath" ] && [ -d "$dirpath" ]; then
            rm -rf "$dirpath"
        fi
    done
fi
# Next, delete the binaries
sudo rm -rf /usr/local/bin/helm /usr/bin/helm



# Step 3: Uninstall linkerd
rm -rf $HOME/.linkerd2



# Step 4: Delete $HOME/.kube
rm -rf $HOME/.kube



# Step 5: Stop kubelet and remove kubernetes components
sudo systemctl stop kubelet
case "$DISTRO" in
  centos | rhel | rocky)
    sudo yum remove -y kubelet kubeadm kubectl 2>/dev/null || true
    sudo dnf remove -y kubelet kubeadm kubectl 2>/dev/null || true
    sudo rm -f /etc/yum.repos.d/kubernetes.repo
    sudo rm -rf /var/lib/yum/repos/x86_64/7/kubernetes /var/lib/yum/repos/x86_64/8/kubernetes 2>/dev/null || true
    ;;
  ubuntu)
    sudo apt-get purge -y kubelet kubeadm kubectl --allow-change-held-packages
    sudo rm -f /etc/apt/sources.list.d/kubernetes.list
    sudo rm -f /usr/share/keyrings/kubernetes-archive-keyring.gpg /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    ;;
  *)
    printf "WARNING: Unexpected distribution '%s'\n" "$DISTRO"
    ;;
esac
sudo rm -f /etc/systemd/system/multi-user.target.wants/kubelet.service
sudo rm -rf /etc/kubernetes
sudo rm -rf /var/lib/kubelet
sudo rm -f /etc/sysctl.d/kubernetes.conf /etc/sysctl.d/k8s.conf
sudo rm -rf /usr/lib/systemd/system/kubelet.service.d
sudo rm -rf /usr/libexec/kubernetes


# Step 6: reload systemctl daemons
sudo systemctl restart containerd

# Step 7: misc cleanup

# Causes issues if left over
sudo rm -rf /var/lib/etcd

# Cleared based on suggestion during kubeadm reset
sudo iptables -F

# Remove pre-requisite files
sudo rm /etc/modules-load.d/k8s.conf
sudo rm /etc/sysctl.d/k8s.conf
sudo sysctl --system

# Remove external-services (only if directory exists and docker is available)
EXTERNAL_SERVICES_DIR="${HOME:-/home/$USER}/external-services"
if [ -d "$EXTERNAL_SERVICES_DIR" ] && command -v docker &>/dev/null; then
    (cd "$EXTERNAL_SERVICES_DIR" && sudo docker compose down 2>/dev/null) || true
    sudo rm -rf "$EXTERNAL_SERVICES_DIR"
fi
if command -v docker &>/dev/null; then
    sudo docker system prune -a --volumes --force 2>/dev/null || true
    vols=$(sudo docker volume ls -q 2>/dev/null)
    if [ -n "$vols" ]; then
        echo "$vols" | xargs sudo docker volume rm 2>/dev/null || true
    fi
    sudo systemctl daemon-reload 2>/dev/null || true
    sudo systemctl restart docker 2>/dev/null || true
fi




