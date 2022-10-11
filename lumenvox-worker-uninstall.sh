#!/bin/bash

DISTRO=$(grep ^ID= /etc/*-release -h | cut -d '=' -f 2 | tr -d '"')



# Step 1: Reset kubeadm
KUBEADM_RESET_COUNTER=0
KUBEADM_RESET_MAX=5
while [ $KUBEADM_RESET_COUNTER -lt $KUBEADM_RESET_MAX ]; do
    sudo kubeadm reset --cri-socket unix:///var/run/cri-dockerd.sock --v=5 -f
    if [ $? -ne 0 ]; then
        KUBEADM_RESET_COUNTER=$(( $KUBEADM_RESET_COUNTER + 1 ))
        printf "\t\tkubeadm reset: failed attempt #$KUBEADM_RESET_COUNTER."
        if [ $KUBEADM_RESET_COUNTER -eq $KUBEADM_RESET_MAX ]; then
            printf " Maximum number of attempts reached. Wait a few minutes and try again.\n"
            exit 1
        else
            printf " Retrying...\n"
        fi
    else
        break
    fi
done

# Clean up what kubeadm reset won't
sudo rm -rf /etc/cni/net.d



# Step 2: Stop kubelet and remove kubernetes components
sudo systemctl stop kubelet
case $DISTRO in
  centos | rhel)
    sudo yum remove -y kubelet kubeadm kubectl
    sudo rm -f  /etc/yum.repos.d/kubernetes.repo
    sudo rm -rf /var/lib/yum/repos/x86_64/7/kubernetes
    ;;
  ubuntu)
    sudo apt-get purge -y kubelet kubeadm kubectl --allow-change-held-packages
    sudo rm -f /etc/apt/sources.list.d/kubernetes.list
    sudo rm -f /usr/share/keyrings/kubernetes-archive-keyring.gpg
    ;;
  *)
    printf "WARNING: Unexpected distribution '$DISTRO'\n"
    ;;
esac
sudo rm -f  /etc/systemd/system/multi-user.target.wants/kubelet.service
sudo rm -rf /etc/kubernetes
sudo rm -rf /var/lib/kubelet
sudo rm -f  /etc/sysctl.d/kubernetes.conf
sudo rm -rf /usr/lib/systemd/system/kubelet.service.d
sudo rm -rf /usr/libexec/kubernetes



# Step 3: Uninstall crictl
sudo rm -f /usr/bin/crictl /usr/local/bin/crictl



# Step 4: Uninstall cri-dockerd
sudo systemctl stop cri-docker.socket
sudo systemctl stop cri-docker.service
case $DISTRO in
  centos | rhel)
    sudo rpm -e cri-dockerd
    ;;
  ubuntu)
    sudo apt-get purge -y cri-dockerd
    ;;
  *)
    printf "WARNING: Unexpected distribution '$DISTRO'\n"
    ;;
esac



# Step 5: reload systemctl daemons
sudo systemctl daemon-reload



# Step 6: misc cleanup

# Causes issues if left over
sudo rm -rf /var/lib/etcd

# Cleared based on suggestion during kubeadm reset
sudo iptables -F

