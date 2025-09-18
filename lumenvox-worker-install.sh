#!/bin/bash

if [ $# -ne 3 ]; then
    printf "Usage: ./lumenvox-worker-install.sh CONTROL_PLANE_IP TOKEN HASH\n"
    exit 1
fi


# Program definitions:
MAIN_LOG="main-log.txt"
ERR_LOG="err-log.txt"
TEE="tee $MAIN_LOG $ERR_LOG"

############################################
# Kernel pre-requisites
############################################

sudo tee /etc/modules-load.d/k8s.conf <<EOF
ip_tables
overlay
br_netfilter
EOF

sudo modprobe ip_tables
sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system

#############################################
# Step 0: OS and swap detection
#############################################

# Get OS details
OS=$(echo `uname`|tr '[:upper:]' '[:lower:]')
if [ $OS != "linux" ]; then printf "Invalid OS $OS: should be linux.\n"; exit 1; fi
DISTRO=$(grep ^ID= /etc/*-release -h | cut -d '=' -f 2 | tr -d '"')
ARCH=$(uname -m)

# Exit if unsupported OS
case $DISTRO in
  ubuntu)
    ;;
  centos | rhel | rocky)
    ;;
  *)
    printf "Error: distribution '$DISTRO' not supported.\n"
    exit 1
    ;;
esac



######################################
# firewall, apparmor, selinux, etc...
######################################

case $DISTRO in
  ubuntu)
    sudo systemctl stop ufw  1>>$MAIN_LOG 2>>$ERR_LOG
    sudo systemctl disable ufw  1>>$MAIN_LOG 2>>$ERR_LOG
    sudo systemctl stop apparmor  1>>$MAIN_LOG 2>>$ERR_LOG
    sudo systemctl disable apparmor  1>>$MAIN_LOG 2>>$ERR_LOG
    ;;
  centos | rhel | rocky)
    sudo systemctl stop firewalld
    sudo systemctl disable firewalld
    sudo setenforce 0
    sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
    ;;
  *)
    printf "Error: distribution '$DISTRO' not supported.\n"  | $TEE -a
    exit 1
    ;;
esac

# Get swap info, disable it if enabled
SWAP_DEVICES=$(swapon --show | wc -l)
if [ $SWAP_DEVICES -gt 0 ]; then
  printf "Swap must be disabled for Kubernetes to work. It will be disabled by running \`sudo swapoff -a\`. This will work for the installation. \n" | $TEE -a
  sudo swapoff -a 1>>$MAIN_LOG 2>>$ERR_LOG
  printf "\nAs a permanent solution, the file /etc/fstab has also been edited to disable swap.\n" | $TEE -a
  sudo sed -i '/swap/ s/^\(.*\)$/#\1/g' /etc/fstab 1>>$MAIN_LOG 2>>$ERR_LOG
  printf "\nFirst requirements validated\n" | $TEE -a

else
printf "\nSwap is off\n" | $TEE -a
fi

#############################################
# Uninstall Docker if exists
#############################################

printf "Verifying if Docker is installed...\n" | $TEE -a

if command -v docker 1>>$MAIN_LOG 2>>$ERR_LOG; then
    # docker is already installed - needs to be removed
  case $DISTRO in

          ubuntu)
            printf "\t\tUninstalling docker...\n" | $TEE -a
            sudo apt-get remove docker docker-engine docker.io runc -y 1>>$MAIN_LOG 2>>$ERR_LOG
            if [ $? -ne 0 ]; then
                printf "\t\tFailed to uninstall docker\n" | $TEE -a
                exit 1
            fi
            sudo apt-get purge docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras -y 1>>$MAIN_LOG 2>>$ERR_LOG
            if [ $? -ne 0 ]; then
                printf "\t\tFailed to uninstall docker\n" | $TEE -a
                exit 1
            fi
            sudo rm -rf /var/lib/docker 1>>$MAIN_LOG 2>>$ERR_LOG
            if [ $? -ne 0 ]; then
                printf "\t\tFailed to remove docker directories\n" | $TEE -a
                exit 1
            fi
            ;;

        centos | rhel | rocky)
            printf "\t\tUninstalling docker...\n" | $TEE -a
            sudo yum -y remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 1>>$MAIN_LOG 2>>$ERR_LOG
            if [ $? -ne 0 ]; then
                printf "\t\tFailed to uninstall docker\n" | $TEE -a
                exit 1
            fi
            sudo yum -y remove docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
            if [ $? -ne 0 ]; then
                printf "\t\tFailed to uninstall docker\n" | $TEE -a
                exit 1
            fi
            sudo rm -rf /var/lib/docker
            if [ $? -ne 0 ]; then
                printf "\t\tFailed to remove docker directories\n" | $TEE -a
                exit 1
            fi
            ;;
          *)
            printf "Error: distribution '$DISTRO' not supported.\n"
            exit 1
            ;;
  esac
fi


#############################################
# Step 1: Install containerd
#############################################
printf "1. Installing containerd...\n" | $TEE -a

if command -v containerd 1>>$MAIN_LOG 2>>$ERR_LOG; then
    # containerd is already installed - check configuration
    if ! [[ $(sudo cat /etc/containerd/config.toml 2>>$ERR_LOG | grep SystemdCgroup | cut -d' ' -f15) = "true" ]]; then
        printf "\tContainerd is installed, but it is misconfigured. It should use the SystemdCgroup driver.\n" | $TEE -a
        printf "\tAttempting to change it...\n" | $TEE -a
        sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
           printf "\t\tFailed to configure SystemdCgroup driver in /etc/containerd/config.toml\n" | $TEE -a
           exit 1
        fi

    else
        printf "\tContainerd detected, skipping re-installation. Installing other necessary utilities...\n"
        case $DISTRO in

       ubuntu)
            printf "\t\tUpdating apt repositories...\n" | $TEE -a
            sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://dl.k8s.io/apt/doc/apt-key.gpg 1>>$MAIN_LOG 2>>$ERR_LOG
            sudo apt-get update -y 1>>$MAIN_LOG 2>>$ERR_LOG
            if [ $? -ne 0 ]; then
                printf "\t\tFailed to update apt repositories\n" | $TEE -a
                exit 1
            fi

            printf "\t\tInstalling prerequisites: ca-certificates, curl and gnupg...\n" | $TEE -a
            sudo apt-get install -y ca-certificates curl gnupg 1>>$MAIN_LOG 2>>$ERR_LOG
            if [ $? -ne 0 ]; then
                printf "\t\tFailed to install prerequisites\n" | $TEE -a
                exit 1
            fi
            ;;

          centos | rhel | rocky)
            printf "\t\tInstalling prerequisites: yum-utils and curl...\n" | $TEE -a
            sudo yum install -y yum-utils curl 1>>$MAIN_LOG 2>>$ERR_LOG
            if [ $? -ne 0 ]; then
                printf "\t\tFailed to install yum-utils and/or curl\n" | $TEE -a
                exit 1
            fi
            ;;

          *)
            printf "Error: distribution '$DISTRO' not supported.\n"
            exit 1
            ;;
        esac
    fi
else
    case $DISTRO in

      ubuntu)
        printf "\tUpdating apt repositories...\n" | $TEE -a
        sudo apt-get update -y 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to update apt repositories\n" | $TEE -a
            exit 1
        fi

        printf "\tInstalling prerequisites: ca-certificates, curl, and gnupg...\n" | $TEE -a
        sudo apt-get install -y ca-certificates curl gnupg 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to install prerequisites\n" | $TEE -a
            exit 1
        fi

        sudo mkdir -p /etc/apt/keyrings

        printf "\tDownloading official Docker GPG key...\n" | $TEE -a
        curl -fsSLo docker.gpg https://download.docker.com/linux/ubuntu/gpg 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to download official Docker GPG key.\n" | $TEE -a
            exit 1
        fi

        printf "\tInstalling official Docker GPG key...\n" | $TEE -a
        sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg docker.gpg 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to install official Docker GPG key.\n" | $TEE -a
            rm -f docker.gpg 1>>$MAIN_LOG 2>>$ERR_LOG
            if [ $? -ne 0 ]; then
                printf "\t\tCleanup: failed to remove Docker GPG key.\n" | $TEE -a
            fi
            exit 1
        fi

        printf "\tCleaning up GPG key...\n" | $TEE -a
        rm -f docker.gpg 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tCleanup: failed to remove leftover docker.gpg. Attempting to proceed...\n" | $TEE -a
        fi

        # Get architecture and distribution codename
        printf "\tAdding Docker repository...\n" | $TEE -a
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list 2>&1 1>/dev/null | $TEE -a >/dev/null
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to add docker repository\n" | $TEE -a
            exit 1
        fi

        printf "\tUpdating apt repositories...\n" | $TEE -a
        sudo apt-get update -y 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to update apt repositories\n" | $TEE -a
            exit 1
        fi

        printf "\tInstalling containerd...\n" | $TEE -a
        sudo apt-get install -y containerd.io 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to install containerd.\n" | $TEE -a
            exit 1
        fi
        ;;

      centos | rhel | rocky)
        printf "\tInstalling yum-utils and curl...\n" | $TEE -a
        sudo yum install -y yum-utils curl 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to install yum-utils and/or curl\n" | $TEE -a
            exit 1
        fi

        printf "\tAdding yum repo for docker...\n" | $TEE -a
        sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to add yum repo for docker\n" | $TEE -a
            exit 1
        fi

        printf "\tInstalling containerd with yum...\n" | $TEE -a
        sudo yum install -y containerd.io --allowerasing 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to install containerd.io\n" | $TEE -a
            exit 1
        fi
        ;;


      *)
        printf "Error: distribution '$DISTRO' not supported.\n"
        exit 1
        ;;
    esac

    printf "\t\tGetting containerd default configuration...\n" | $TEE -a
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1
    if [ $? -ne 0 ]; then
       printf "\t\tFailed to obtain containerd default configuration\n" | $TEE -a
       exit 1
    fi

    printf "\t\tSetting SystemdCgroup as true...\n" | $TEE -a
    sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to set SystemdCgroup\n" | $TEE -a
        exit 1
    fi

    printf "\tRestarting containerd service...\n" | $TEE -a
    sudo systemctl restart containerd 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to restart containerd service.\n" | $TEE -a
        exit 1
    fi

    printf "\tEnabling containerd service...\n" | $TEE -a
    sudo systemctl enable containerd 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to enable containerd service.\n" | $TEE -a
        exit 1
    fi
fi


#############################################
# Step 2: Install kubernetes components
#############################################
printf "2. Installing kubernetes components...\n" | $TEE -a

case $DISTRO in

  centos | rhel | rocky)
    printf "\tAdding yum repo for kubernetes components...\n" | $TEE -a
    cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo 1>>$MAIN_LOG 2>>$ERR_LOG
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to add yum repo at /etc/yum.repos.d/kubernetes.repo\n" | $TEE -a
        exit 1
    fi

    if selinuxenabled; then
        printf "\tSetting SELinux to permissive mode...\n" | $TEE -a
        sudo setenforce 0 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to set SELinux to permissive mode\n" | $TEE -a
            exit 1
        fi
        printf "\tUpdating SELinux configuration files...\n" | $TEE -a
        sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to update SELinux configuration files\n" | $TEE -a
            exit 1
        fi
    fi

    printf "\tInstalling kubernetes components: kubelet, kubeadm, kubectl...\n" | $TEE -a
    sudo yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes 1>>$MAIN_LOG 2>>$ERR_LOG
    sudo systemctl enable --now kubelet 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to install kubernetes components\n" | $TEE -a
        exit 1
    fi
    sudo yum -y install python3-dnf-plugin-versionlock  1>>$MAIN_LOG 2>>$ERR_LOG
    sudo yum versionlock kubeadm kubelet kubectl  1>>$MAIN_LOG 2>>$ERR_LOG
    ;;

  ubuntu)
    printf "\tInstalling prerequisites...\n" | $TEE -a
    sudo apt-get install -y apt-transport-https ca-certificates curl 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to install prerequisites: apt-transport-https, ca-certificates, curl\n" | $TEE -a
        exit 1
    fi

    printf "\tAdding Google Cloud public signing key...\n" | $TEE -a
    sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to add Google Cloud public signing key.\n" | $TEE -a
        exit 1
    fi

    printf "\tAdding Kubernetes apt repository...\n" | $TEE -a
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list 2>>$ERR_LOG >/dev/null
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to add Kubernetes apt repository\n" | $TEE -a
        exit 1
    fi

    printf "\tUpdating apt repositories...\n" | $TEE -a
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg  1>>$MAIN_LOG 2>>$ERR_LOG
    sudo apt-get update -y 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to update apt repositories\n" | $TEE -a
        exit 1
    fi

    printf "\tInstalling kubernetes components: kubelet, kubeadm, kubectl...\n" | $TEE -a
    sudo apt install -y kubelet kubeadm kubectl 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to install kubernetes components\n" | $TEE -a
        exit 1
    fi

    printf "\tMarking kubernetes components with hold to prevent automatic update/removal.\n" | $TEE -a
    sudo apt-mark hold kubelet kubeadm kubectl

    ;;
esac

# This may belong in the ubuntu case; for now, it will run in both cases.
printf "\tStarting kubelet...\n" | $TEE -a
sudo systemctl enable --now kubelet 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to start kubelet\n" | $TEE -a
    exit 1
fi

NET__BRIDGE__BRIDGE_NF_CALL_IPTABLES=$(sysctl net.bridge.bridge-nf-call-iptables 2>>$ERR_LOG)
if [ $? -ne 0 ]; then
    printf "\t\tFailed to get value of net.bridge.bridge-nf-call-iptables from sysctl\n" | $TEE -a
    exit 1
fi
BRIDGE_NF_CALL_IPTABLES_VAL=$(echo $NET__BRIDGE__BRIDGE_NF_CALL_IPTABLES | cut -d ' ' -f 3)
if [ $BRIDGE_NF_CALL_IPTABLES_VAL -ne 1 ]; then
    printf "\tDetected net.bridge.bridge-nf-call-iptables != 1. Setting to 1...\n" | $TEE -a
    sudo sysctl net.bridge.bridge-nf-call-iptables=1 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to set net.bridge.bridge-nf-call-iptables = 1\n" | $TEE -a
        exit 1
    fi
fi


#############################################
# Step 3: Initialize control plane
#############################################
# Check if crictl is installed
if ! command -v crictl &> /dev/null
then
    echo "crictl could not found -> installing"
    wget https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.31.0/crictl-v1.31.0-linux-amd64.tar.gz 1>>$MAIN_LOG 2>>$ERR_LOG
    sudo tar zxvf crictl-v1.31.0-linux-amd64.tar.gz -C /usr/local/bin 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to install crictl" | $TEE -a
        exit 1
    fi
fi


printf "3. Joining control plane...\n" | $TEE -a
sudo kubeadm join $1:6443 --token $2 --discovery-token-ca-cert-hash $3 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\tFailed to join control plane\n" | $TEE -a
    exit 1
fi



# Done
printf "\nThe installation script has completed! This should now be a registered worker node.\n"
