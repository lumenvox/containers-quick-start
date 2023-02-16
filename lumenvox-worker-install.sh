#!/bin/bash

if [ $# -ne 3 ]; then
    printf "Usage: ./lumenvox-worker-install.sh CONTROL_PLANE_IP TOKEN HASH\n"
    exit 1
fi


# Program definitions:
MAIN_LOG="main-log.txt"
ERR_LOG="err-log.txt"
TEE="tee $MAIN_LOG $ERR_LOG"

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
  centos | rhel)
    ;;
  *)
    printf "Error: distribution '$DISTRO' not supported.\n"
    exit 1
    ;;
esac

# Get swap info, exit if swap is enabled
SWAP_DEVICES=$(swapon --show | wc -l)
if [ $SWAP_DEVICES -gt 0 ]; then
  printf "Swap must be disabled for Kubernetes for work. Please disable swap and try again.\n"
  printf "\nYou may temporarily disable swap by running \`sudo swapoff -a\`. This will work for the installation, but after a restart, you will need to repeat this step before the kubelet runs again.\n"
  printf "\nFor a permanent solution, you should edit your /etc/fstab file.\n"
  exit 1
fi

#############################################
# Step 1: Install docker.
#############################################
printf "1. Installing docker...\n" | $TEE

if command -v docker 1>>$MAIN_LOG 2>>$ERR_LOG; then
    # docker is already installed - check configuration
    if ! [[ $(sudo docker info 2>>$ERR_LOG | grep "Cgroup Driver" | cut -d' ' -f4) = "systemd" ]]; then
        printf "\tDocker is installed, but it is misconfigured. It should use the systemd group driver.\n" | $TEE -a
        printf "\tTo configure this, write the following to /etc/docker/daemon.json and then restart docker.\n" | $TEE -a
        printf '{\n  "exec-opts": ["native.cgroupdriver=systemd"]\n}\n\n' | $TEE -a
        exit 1
    else
        printf "\tDocker detected, skipping re-installation. Installing other necessary utilities...\n"
        case $DISTRO in

          ubuntu)
            printf "\t\tUpdating apt repositories...\n" | $TEE -a
            sudo apt-get update -y 1>>$MAIN_LOG 2>>$ERR_LOG
            if [ $? -ne 0 ]; then
                printf "\t\tFailed to update apt repositories\n" | $TEE -a
                exit 1
            fi

            printf "\t\tInstalling prerequisites: ca-certificates, curl, gnupg, and lsb-release...\n" | $TEE -a
            sudo apt-get install -y ca-certificates curl gnupg lsb-release 1>>$MAIN_LOG 2>>$ERR_LOG
            if [ $? -ne 0 ]; then
                printf "\t\tFailed to install prerequisites\n" | $TEE -a
                exit 1
            fi
            ;;

          centos | rhel)
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

        printf "\tInstalling prerequisites: ca-certificates, curl, gnupg, and lsb-release...\n" | $TEE -a
        sudo apt-get install -y ca-certificates curl gnupg lsb-release 1>>$MAIN_LOG 2>>$ERR_LOG
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

        printf "\tInstalling docker components...\n" | $TEE -a
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to install docker components.\n" | $TEE -a
            exit 1
        fi
        ;;


      centos | rhel)
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

        printf "\tInstalling docker components with yum...\n" | $TEE -a
        sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to install docker components\n" | $TEE -a
            exit 1
        fi
        ;;


      *)
        printf "Error: distribution '$DISTRO' not supported.\n"
        exit 1
        ;;
    esac


    printf "\tConfiguring docker daemon to use systemd cgroup driver...\n" | $TEE -a
    sudo mkdir -p /etc/docker
    printf '{\n  "exec-opts": ["native.cgroupdriver=systemd"]\n}' | sudo tee /etc/docker/daemon.json 1>/dev/null 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to write docker daemon configuration file\n" | $TEE -a
        exit 1
    fi

    printf "\tEnabling docker service...\n" | $TEE -a
    sudo systemctl enable docker 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to enable docker service.\n" | $TEE -a
        exit 1
    fi

    printf "\tStarting docker service...\n" | $TEE -a
    DOCKER_START_ATTEMPT_COUNTER=0
    DOCKER_START_ATTEMPT_MAX=10
    while [ $DOCKER_START_ATTEMPT_COUNTER -lt $DOCKER_START_ATTEMPT_MAX ]; do
        sudo systemctl start docker 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            DOCKER_START_ATTEMPT_COUNTER=$(( $DOCKER_START_ATTEMPT_COUNTER + 1 ))
            printf "\t\tsystemctl start docker: failed attempt #$DOCKER_START_ATTEMPT_COUNTER." | $TEE -a
        if [ $DOCKER_START_ATTEMPT_COUNTER -eq $DOCKER_START_ATTEMPT_MAX ]; then
                printf " Maximum numbers of attempts reached. Wait a few minutes and try again.\n" | $TEE -a
            exit 1
        else
                printf " Sleeping 30 seconds and retrying...\n" | $TEE -a
            sleep 30s
        fi
        else
            break
        fi
    done
fi



#############################################
# Step 2: Install cri-dockerd
#############################################
printf "2. Installing cri-dockerd...\n" | $TEE -a

CRI_DOCKERD_PACKAGE_PREFIX="https://github.com/Mirantis/cri-dockerd/releases/download/v0.2.5/"

case $DISTRO in
  ubuntu)
    UBUNTU_CODENAME=$(lsb_release -cs)
    case $UBUNTU_CODENAME in
      bionic|focal|jammy)
        CRI_DOCKERD_PACKAGE_NAME="cri-dockerd_0.2.5.3-0.ubuntu-${UBUNTU_CODENAME}_amd64.deb"

        printf "\tDownloading cri-dockerd package...\n" | $TEE -a
        curl -fsSLo $CRI_DOCKERD_PACKAGE_NAME $CRI_DOCKERD_PACKAGE_PREFIX$CRI_DOCKERD_PACKAGE_NAME 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to download cri-dockerd package\n" | $TEE -a
            exit 1
        fi

        printf "\tInstalling cri-dockerd package...\n" | $TEE -a
        sudo apt install -y ./$CRI_DOCKERD_PACKAGE_NAME 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to install cri-dockerd\n" | $TEE -a
            rm -f $CRI_DOCKERD_PACKAGE_NAME 1>>$MAIN_LOG 2>>$ERR_LOG
            if [ $? -ne 0 ]; then
                printf "\t\tCleanup: failed to remove $CRI_DOCKERD_PACKAGE_NAME\n" | $TEE -a
            fi
            exit 1
        fi

        printf "\tCleaning up leftover .deb...\n" | $TEE -a
        rm -f $CRI_DOCKERD_PACKAGE_NAME 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tFailed to remove cri-dockerd rpm file. Attempting to proceed...\n" | $TEE -a
        fi
        ;;

      *)
        printf "\t\tFailure installing cri-dockerd: distribution codename '$UBUNTU_CODENAME' not supported.\n"
        exit 1
        ;;
    esac
    ;;

  centos | rhel)
    CENTOS_VERSION=$(rpm --eval "%dist")
    CRI_DOCKERD_PACKAGE_NAME="cri-dockerd-0.2.5-3$CENTOS_VERSION.$ARCH.rpm"

    printf "\tDownloading cri-dockerd package...\n" | $TEE -a
    curl -fsSLo $CRI_DOCKERD_PACKAGE_NAME $CRI_DOCKERD_PACKAGE_PREFIX$CRI_DOCKERD_PACKAGE_NAME 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to download cri-dockerd package\n" | $TEE -a
        exit 1
    fi

    printf "\tInstalling cri-dockerd package...\n" | $TEE -a
    sudo rpm -i $CRI_DOCKERD_PACKAGE_NAME 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to install cri-dockerd\n" | $TEE -a
        rm -f $CRI_DOCKERD_PACKAGE_NAME 1>>$MAIN_LOG 2>>$ERR_LOG
        if [ $? -ne 0 ]; then
            printf "\t\tCleanup: failed to remove $CRI_DOCKERD_PACKAGE_NAME\n" | $TEE -a
        fi
        exit 1
    fi

    printf "\tCleaning up leftover .rpm...\n" | $TEE -a
    rm -f $CRI_DOCKERD_PACKAGE_NAME 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to remove cri-dockerd rpm file. Attempting to proceed...\n" | $TEE -a
    fi
    ;;
esac

printf "\tReloading systemctl daemons...\n" | $TEE -a
sudo systemctl daemon-reload 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to reload systemctl daemons\n" | $TEE -a
    exit 1
fi

printf "\tEnabling cri-docker.service...\n" | $TEE -a
sudo systemctl enable cri-docker.service 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to enable cri-docker.service\n" | $TEE -a
    exit 1
fi

printf "\tEnabling cri-docker.socket...\n" | $TEE -a
sudo systemctl enable --now cri-docker.socket 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to enable cri-docker.socket\n" | $TEE -a
    exit 1
fi



#############################################
# Step 3: Install crictl
#############################################
printf "3. Installing crictl...\n" | $TEE -a

VERSION="v1.25.0"

printf "\tDownloading crictl package...\n" | $TEE -a
curl -fsSLo crictl-$VERSION-linux-amd64.tar.gz https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-amd64.tar.gz 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to download crictl package\n" | $TEE -a
    exit 1
fi

printf "\tUnpacking crictl package into /usr/local/bin...\n" | $TEE -a
sudo tar zxvf crictl-$VERSION-linux-amd64.tar.gz -C /usr/local/bin 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed unpack crictl package\n" | $TEE -a
    rm -f crictl-$VERSION-linux-amd64.tar.gz 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tCleanup: failed to remove crictl-$VERSION-linux-amd64.tar.gz\n" | $TEE -a
    fi
    exit 1
fi

printf "\tLinking crictl binary from /usr/local/bin to /usr/bin...\n" | $TEE -a
sudo ln -s /usr/local/bin/crictl /usr/bin/ 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to create link /usr/bin/crictl -> /usr/local/bin/crictl\n" | $TEE -a
    rm -f crictl-$VERSION-linux-amd64.tar.gz 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tCleanup: failed to remove crictl-$VERSION-linux-amd64.tar.gz\n" | $TEE -a
    fi
    sudo rm -f /usr/local/bin/crictl 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tCleanup: failed to remove /usr/local/bin/crictl\n" | $TEE -a
    fi
    exit 1
fi

printf "\tCleaning up...\n" | $TEE -a
rm -f crictl-$VERSION-linux-amd64.tar.gz 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to remove crictl-$VERSION-linux-amd64.tar.gz. Attempting to ignore.\n" | $TEE -a
fi



#############################################
# Step 4: Install kubernetes components
#############################################
printf "4. Installing kubernetes components...\n" | $TEE -a

case $DISTRO in

  centos | rhel)
    printf "\tAdding yum repo for kubernetes components...\n" | $TEE -a
    cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo 1>>$MAIN_LOG 2>>$ERR_LOG
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-\$basearch
enabled=1
gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
exclude=kubelet kubeadm kubectl
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
    sudo yum install -y kubelet-1.25.4 kubeadm-1.25.4 kubectl-1.25.4 cri-tools-1.25.0 --disableexcludes=kubernetes 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to install kubernetes components\n" | $TEE -a
        exit 1
    fi
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
    echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list 2>>$ERR_LOG >/dev/null
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to add Kubernetes apt repository\n" | $TEE -a
        exit 1
    fi

    printf "\tUpdating apt repositories...\n" | $TEE -a
    sudo apt-get update -y 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to update apt repositories\n" | $TEE -a
        exit 1
    fi

    printf "\tInstalling kubernetes components: kubelet, kubeadm, kubectl...\n" | $TEE -a
    sudo apt-get install -y kubelet=1.25.4-00 kubeadm=1.25.4-00 kubectl=1.25.4-00 1>>$MAIN_LOG 2>>$ERR_LOG
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
# Step 5: Initialize control plane
#############################################
printf "5. Joining control plane...\n" | $TEE -a
sudo kubeadm join $1:6443 --token $2 --discovery-token-ca-cert-hash $3 --cri-socket unix:///var/run/cri-dockerd.sock 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\tFailed to join control plane\n" | $TEE -a
    exit 1
fi



# Done
printf "\nThe installation script has completed! This should now be a registered worker node.\n"
