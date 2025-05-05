#!/bin/bash

if [ $# -ne 3 ]; then
    printf "Usage: ./lumenvox-control-install.sh values.yaml server.key server.crt\n"
    exit 1
fi

# check if input files exists
currentdir=`pwd`

printf "\t\tactual path is $currentdir ...\n"

# Check if entered parameters are present
input_param_check=($1 $2)
for file in ${input_param_check[@]}; do
  FILE=file
if [ ! -f $file ]; then
    echo "File $file not found!"
	exit 1
fi
done


############################################
# Collect required login passwords
############################################
printf "\tSetting up postgres-existing-secret...\n"

printf "\t\tPlease enter the required PostgreSQL root password: "
read -s POSTGRES_POSTGRES_PASS

printf "\n\t\tPlease enter the required PostgreSQL user password: "
read -s POSTGRES_PASS
printf "\n"
printf "\tSetting up mongodb-existing-secret...\n"
printf "\t\tPlease enter the required MongoDB root password: "
read -s MONGO_ROOT_PASS
printf "\n"

printf "\tSetting up rabbitmq-existing-secret...\n"
printf "\t\tPlease enter the required RabbitMQ password: "
read -s RABBIT_PASS
printf "\n"

printf "\tSetting up redis-existing-secret...\n"
printf "\t\tPlease enter the required Redis password: "
read -s REDIS_PASS
printf "\n"

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
    printf "Error: distribution '$DISTRO' not supported.\n"  | $TEE -a
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

printf "1. Verifying if Docker is installed...\n" | $TEE -a

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
# Step 1: Install containerd.
#############################################
printf "2. Installing containerd...\n" | $TEE

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
##########################################################
# Step 2: Install Docker for external services and mrcp-api
##########################################################

case $DISTRO in

      ubuntu)

        printf "\tInstalling docker components for external services and mrcp-api...\n" | $TEE -a
        sudo apt-get install -y docker-ce docker-ce-cli docker-compose-plugin 1>>$MAIN_LOG 2>>$ERR_LOG
#        if [ $? -ne 0 ]; then
#            printf "\t\tFailed to install docker components.\n" | $TEE -a
#            exit 1
#        fi
        ;;

      centos | rhel | rocky)

        printf "\tInstalling docker components with yum, for external services and mrcp-api...\n" | $TEE -a
        sudo yum install -y docker-ce docker-ce-cli docker-compose-plugin --allowerasing 1>>$MAIN_LOG 2>>$ERR_LOG
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



printf "\tEnabling Docker.\n"  | $TEE -a
sudo systemctl enable docker 1>>$MAIN_LOG 2>>$ERR_LOG
  if [ $? -ne 0 ]; then
      printf "\t\tFailed to enable docker\n" | $TEE -a
      exit 1
  fi

printf "\tAllowing non-root access to Docker.\n"  | $TEE -a
sudo usermod -aG docker $USER 1>>$MAIN_LOG 2>>$ERR_LOG
  if [ $? -ne 0 ]; then
      printf "\t\tFailed to add user to docker group\n" | $TEE -a
      exit 1
  fi

#create directories for external-services docker compose files
mkdir -p /home/$USER/external-services  1>>$MAIN_LOG 2>>$ERR_LOG
cd /home/$USER/external-services 1>>$MAIN_LOG 2>>$ERR_LOG
#download files from github
curl -O https://raw.githubusercontent.com/lumenvox/external-services/master/docker-compose.yaml  1>>$MAIN_LOG 2>>$ERR_LOG
curl -O https://raw.githubusercontent.com/lumenvox/external-services/master/.env  1>>$MAIN_LOG 2>>$ERR_LOG

# Replace passwords in default .env with collected new password
filename=/home/$USER/external-services/.env
key_name=MONGODB__ROOT_PASSWORD
newvalue=$MONGO_ROOT_PASS

if ! grep -R "^[#]*\s*${key_name}=.*" $filename > /dev/null; then
  echo "'${key_name}' not found"
else
  echo "\tSETTING '${key_name}'"
  sed -i "s/^[#]*\s*${key_name}=.*/$key_name=$newvalue/" $filename 1>>$MAIN_LOG 2>>$ERR_LOG
fi

key_name=POSTGRESQL__POSTGRES_PASSWORD
newvalue=$POSTGRES_POSTGRES_PASS

if ! grep -R "^[#]*\s*${key_name}=.*" $filename > /dev/null; then
  echo "'${key_name}' not found"
else
  echo "\tSETTING '${key_name}'"
  sed -i "s/^[#]*\s*${key_name}=.*/$key_name=$newvalue/" $filename 1>>$MAIN_LOG 2>>$ERR_LOG
fi

key_name=POSTGRESQL__PASSWORD
newvalue=$POSTGRES_PASS

if ! grep -R "^[#]*\s*${key_name}=.*" $filename > /dev/null; then
  echo "'${key_name}' not found"
else
  echo "\tSETTING '${key_name}'"
  sed -i "s/^[#]*\s*${key_name}=.*/$key_name=$newvalue/" $filename  1>>$MAIN_LOG 2>>$ERR_LOG
fi

key_name=RABBITMQ__PASSWORD
newvalue=$RABBIT_PASS

if ! grep -R "^[#]*\s*${key_name}=.*" $filename > /dev/null; then
  echo "'${key_name}' not found"
else
  echo "\tSETTING '${key_name}'"
  sed -i "s/^[#]*\s*${key_name}=.*/$key_name=$newvalue/" $filename 1>>$MAIN_LOG 2>>$ERR_LOG
fi

key_name=REDIS__PASSWORD
newvalue=$REDIS_PASS

if ! grep -R "^[#]*\s*${key_name}=.*" $filename > /dev/null; then
  echo "'${key_name}' not found"
else
  echo "SETTING '${key_name}'"
  sed -i "s/^[#]*\s*${key_name}=.*/$key_name=$newvalue/" $filename  1>>$MAIN_LOG 2>>$ERR_LOG
fi


#install external-services
sudo docker compose up -d  1>>$MAIN_LOG 2>>$ERR_LOG
cd /home/$USER/  1>>$MAIN_LOG 2>>$ERR_LOG

#############################################
# Step 3: Install kubernetes components
#############################################
printf "3. Installing kubernetes components...\n" | $TEE -a

case $DISTRO in

  centos | rhel | rocky)
    printf "\tAdding yum repo for kubernetes components...\n" | $TEE -a
    cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo 1>>$MAIN_LOG 2>>$ERR_LOG
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/repodata/repomd.xml.key
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
    sudo yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes 1>>$MAIN_LOG 2>>$
    sudo systemctl enable --now kubelet 1>>$MAIN_LOG 2>>$
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
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list 2>>$ERR_LOG >/dev/null
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to add Kubernetes apt repository\n" | $TEE -a
        exit 1
    fi

    printf "\tUpdating apt repositories...\n" | $TEE -a
	curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg  1>>$MAIN_LOG 2>>$ERR_LOG
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
# Step 4: Initialize control plane
#############################################

# Check if crictl is installed
if ! command -v crictl &> /dev/null
then
    echo "crictl could not found -> installing"
	wget https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.30.0/crictl-v1.30.0-linux-amd64.tar.gz 1>>$MAIN_LOG 2>>$ERR_LOG
	sudo tar zxvf crictl-v1.30.0-linux-amd64.tar.gz -C /usr/local/bin 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to install crictl" | $TEE -a
        exit 1
    fi
fi



printf "4. Initializing control plane...\n" | $TEE -a
sudo kubeadm init 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\tFailed to initialize control plane\n" | $TEE -a
    exit 1
fi

#############################################
# Step 5: Peform first-time setup for the cluster
#############################################
printf "5. Performing first-time setup...\n" | $TEE -a

printf "\tUpdating kubectl to allow non-root usage...\n" | $TEE -a
mkdir -p $HOME/.kube 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to create directory $HOME/.kube\n" | $TEE -a
    exit 1
fi
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to copy /etc/kubernetes/admin.conf to $HOME/.kube/config\n" | $TEE -a
    exit 1
fi
sudo chown $USER:$USER $HOME/.kube/config 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to change ownership of $HOME/.kube/config\n" | $TEE -a
    exit 1
fi

# Allow control plane to schedule pods
printf "\tGetting name of node...\n" | $TEE -a
NODE=$(kubectl get no -o custom-columns=NAME:.metadata.name --no-headers 2>>$ERR_LOG)
if [ $? -ne 0 ]; then
    printf "\t\tFailed to get name of node\n" | $TEE -a
    exit 1
fi

printf "\tRemoving control-plane NoSchedule taint from control plane...\n" | $TEE -a
kubectl taint node $NODE node-role.kubernetes.io/control-plane- 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to remove NoSchedule taint from node $NODE\n" | $TEE -a
    exit 1
fi

# Install pod network addon
printf "\tInstalling calico as pod network addon...\n" | $TEE -a
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to install calico\n" | $TEE -a
    exit 1
fi

#############################################
# Step 6: Install linkerd on the cluster
#############################################
printf "6. Installing linkerd on cluster...\n" | $TEE -a

# Check for ip_tables module, required to start linkerd pods
if ! lsmod | grep ip_tables >/dev/null 2>&1; then
    printf "\tip_tables module not detected, attempting to load...\n" | $TEE -a
    sudo modprobe ip_tables 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tFailed to load ip_tables module. Attempting to proceed...\n" | $TEE -a
    fi
    printf "\t\t\tNOTE: ip_tables was manually loaded. To ensure that the cluster works after a server restart, you should add ip_tables to modules.conf with the following command:\n"
    printf "\t\t\t\techo \"ip_tables\" | sudo tee -a /etc/modules-load.d/modules.conf >/dev/null\n"
fi

# Install linkerd CLI
printf "\tDownloading linkerd install script...\n" | $TEE -a
# curl --proto '=https' --tlsv1.2 -sSfLo linkerd_install https://run.linkerd.io/install 1>>$MAIN_LOG 2>>$ERR_LOG
curl --proto '=https' --tlsv1.2 -sSfLo linkerd_install https://lumenvox-public-assets.s3.us-east-1.amazonaws.com/third-party/linkerd/linkerd_install 1>>$MAIN_LOG 2>>$ERR_LOG

if [ $? -ne 0 ]; then
    printf "\t\tFailed to download linkerd install script\n" | $TEE -a
    exit 1
fi

printf "\tInstalling linkerd CLI...\n" | $TEE -a
chmod +x linkerd_install
./linkerd_install 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to install linkerd CLI\n" | $TEE -a
    rm -f linkerd_install
    if [ $? -ne 0 ]; then
        printf "\t\tCleanup: failed to remove linkerd_install\n" | $TEE -a
    fi
    exit 1
fi

printf "\tRemoving installation script...\n" | $TEE -a
rm -f linkerd_install 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to remove linkerd install script. Attempting to proceed...\n" | $TEE -a
fi

# Add linkerd to path
PATH=$PATH:~/.linkerd2/bin

# Install linkerd on the cluster

printf "\tPerforming linkerd pre-check...\n" | $TEE -a
linkerd check --pre 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\tSystem does not meet requirements for linkerd installation\n" | $TEE -a
    exit 1
fi

printf "\tRendering linkerd CRDs...\n" | $TEE -a
linkerd install --crds 2>&1 1>linkerd_install_crds.yaml | $TEE -a >/dev/null
if [ $? -ne 0 ]; then
    printf "\tLinkerd failed to render CRDs\n" | $TEE -a
    exit 1
fi

printf "\tInstalling linkerd CRDs...\n" | $TEE -a
kubectl apply -f linkerd_install_crds.yaml 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\tFailed to install linkerd CRDs\n" | $TEE -a
    rm -f linkerd_install_crds.yaml 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tCleanup: failed to remove linkerd_install_crds.yaml\n" | $TEE -a
    fi
    exit 1
fi

rm -f linkerd_install_crds.yaml 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tCleanup: failed to remove linkerd_install_crds.yaml. Attempting to proceed...\n" | $TEE -a
fi

printf "\tRendering linkerd installation manifest...\n" | $TEE -a
linkerd install --set proxyInit.runAsRoot=true --set proxyInit.iptablesMode=nft 2>&1 1>linkerd_install_manifest.yaml | $TEE -a >/dev/null
if [ $? -ne 0 ]; then
    printf "\tLinkerd failed to render installation manifest\n" | $TEE -a
    exit 1
fi

printf "\tInstalling linkerd in cluster...\n" | $TEE -a
kubectl apply -f linkerd_install_manifest.yaml 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\tFailed to install linkerd\n" | $TEE -a
    rm -f linkerd_install_manifest.yaml 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tCleanup: failed to remove linkerd_install_manifest.yaml\n" | $TEE -a
		    ll
    fi
    exit 1
fi

rm -f linkerd_install_manifest.yaml 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tCleanup: failed to remove linkerd_install_manifest.yaml. Attempting to proceed...\n" | $TEE -a
fi

printf "\tRendering linkerd dashboard installation manifest...\n" | $TEE -a
linkerd viz install 2>&1 1>linkerd_install_dashboard_manifest.yaml | $TEE -a >/dev/null
if [ $? -ne 0 ]; then
    printf "\tLinkerd failed to render dashboard installation manifest\n" | $TEE -a
    exit 1
fi
printf "\tInstalling linkerd dashboard in cluster...\n" | $TEE -a
kubectl apply -f linkerd_install_dashboard_manifest.yaml 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\tLinkerd failed to install dashboard\n" | $TEE -a
    rm -f linkerd_install_dashboard_manifest.yaml 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tCleanup: failed to remove linkerd_install_dashboard_manifest.yaml\n" | $TEE -a
    fi
    exit 1
fi

rm -f linkerd_install_dashboard_manifest.yaml 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tCleanup: failed to remove linkerd_install_dashboard_manifest.yaml. Attempting to proceed...\n" | $TEE -a
fi
sleep 30s
printf "\tRunning linkerd installation check...\n" | $TEE -a
linkerd check 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tLinkerd failed installation check. Please refer to the log files.\n" | $TEE -a
    exit 1
fi

#############################################
# Step 7: Install helm
#############################################
printf "7. Installing helm...\n" | $TEE -a

printf "\tDownloading installation script...\n" | $TEE -a
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to download helm installation script\n" | $TEE -a
    exit 1
fi

chmod 700 get_helm.sh
printf "\tInstalling helm...\n" | $TEE -a
./get_helm.sh 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to install helm\n" | $TEE -a
    rm -f get_helm.sh 1>>$MAIN_LOG 2>>$ERR_LOG
    if [ $? -ne 0 ]; then
        printf "\t\tCleanup: failed to remove get_helm.sh\n" | $TEE -a
    fi
    exit 1
fi

printf "\tCleaning up from helm installation...\n" | $TEE -a
rm get_helm.sh 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tCleanup: failed to remove get_helm.sh. Attempting to proceed...\n" | $TEE -a
fi

#############################################
# Step 8: Start the lumenvox stack
#############################################
printf "8. Installing lumenvox stack...\n" | $TEE -a

# Set up helm repos
printf "\tAdding lumenvox helm repo...\n" | $TEE -a
helm repo add lumenvox https://lumenvox.github.io/helm-charts 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\tFailed to add lumenvox to helm repos\n" | $TEE -a
    exit 1
fi
printf "\tUpdating lumenvox helm repo...\n" | $TEE -a
helm repo update 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\tFailed to update helm repos\n" | $TEE -a
    exit 1
fi

# Set up kubernetes namespace
printf "\tCreating lumenvox namespace...\n" | $TEE -a
kubectl create ns lumenvox 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\tFailed to create lumenvox namespace\n" | $TEE -a
    exit 1
fi

# Create kubernetes secrets
kubectl create secret generic mongodb-existing-secret --from-literal=mongodb-root-password=$MONGO_ROOT_PASS -n lumenvox 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\tFailed to create secret mongodb-existing-secret\n" | $TEE -a
    exit 1
fi
kubectl create secret generic postgres-existing-secret --from-literal=postgresql-password=$POSTGRES_PASS --from-literal=postgresql-postgres-password=$POSTGRES_POSTGRES_PASS -n lumenvox 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\tFailed to create secret postgres-existing-secret\n" | $TEE -a
    exit 1
fi

kubectl create secret generic rabbitmq-existing-secret --from-literal=rabbitmq-password=$RABBIT_PASS -n lumenvox 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\tFailed to create secret postgres-existing-secret\n" | $TEE -a
    exit 1
fi

kubectl create secret generic redis-existing-secret --from-literal=redis-password=$REDIS_PASS -n lumenvox 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\tFailed to create secret redis-existing-secret\n" | $TEE -a
    exit 1
fi


cd /home/$USER/containers-quick-start
printf "\tSetting up speech-tls-secret using key $2 and cert $3...\n" | $TEE -a
printf "\tCommmand: kubectl create secret tls speech-tls-secret --key ./$2 --cert ./$3 -n lumenvox\n" | $TEE -a
kubectl create secret tls speech-tls-secret --key $2 --cert $3 -n lumenvox 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\tFailed to create secret speech-tls-secret\n" | $TEE -a
    exit 1
fi

# Install stack
printf "\tStarting lumenvox containers...\n" | $TEE -a
helm install lumenvox lumenvox/lumenvox -n lumenvox -f $1 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
   printf "\tFailed to start lumenvox containers\n" | $TEE -a
   exit 1
fi

#############################################
# Step 9: Install nginx ingrss controller
#############################################

printf "9. Installing nginx ingress controller...\n" | $TEE -a
helm upgrade --install ingress-nginx ingress-nginx --repo https://kubernetes.github.io/ingress-nginx -n ingress-nginx --create-namespace --set controller.hostNetwork=true --version 4.12.1 1>>$MAIN_LOG 2>>$ERR_LOG
if [ $? -ne 0 ]; then
    printf "\t\tFailed to install nginx ingress controller\n" | $TEE -a
    exit 1
fi

#############################################
# Step 10: Gather information for join
#############################################
KUBEADM_JOIN_TOKEN=$(kubeadm token list | tail -n 1 | cut -d' ' -f1)
KUBEADM_JOIN_HASH="sha256:$(openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -pubkey | openssl rsa -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"

# Done
printf "\nThe installation script has completed! The pods should now be starting.\n"
printf "\nLinkerd has been installed, but it has not been added to the path. To add the binary to your path, add the following to your .bashrc:\n"
printf "\n\tif ! [[ \"\$PATH\" =~ \"\$HOME/.linkerd2/bin\" ]]; then PATH=\"\$HOME/.linkerd2/bin:\$PATH\"; fi\n"
printf "\nTo add a worker node to the cluster, run the worker install script with the following arguments:\n"
printf "\t./lumenvox-worker-install.sh <control plane IP> $KUBEADM_JOIN_TOKEN $KUBEADM_JOIN_HASH\n"
printf "\n"
