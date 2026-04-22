# LumenVox Containers Quick Start

## Overview

The preferred orchestration solution for [Capacity Private Cloud](https://github.com/lumenvox/helm-charts) is Kubernetes. To
assist smaller clients or clients wanting to quickly implement a POC/Pilot,
Capacity has developed the scripts in this repository to smooth out the process
of setting up a full Kubernetes cluster with the relevant software.

> Note: These scripts will set up a Kubernetes cluster. If you would like to
> set up your own cluster or use an already-existing cluster, these scripts are
> not for you. Please refer to the installation instructions in our helm charts
> repository for more information on the installation process.

## Getting Started

After downloading the scripts, make them executable before running any of them:
```shell
sudo chmod +x *.sh
```

## Supported Environments

The scripts support the following environments:
* Ubuntu 22.04 and 24.04 LTS
* CentOS 7, 8, 9
* AlmaLinux 9
* Rocky 7, 8, 9
* RHEL 7, 8, 9

Additionally, the following conditions must be met:
* swap must be disabled (the installer will disable it automatically if needed).
* SELinux must be disabled or set to permissive (the installer will configure this automatically).
* If Docker is already installed, it must use the systemd cgroup driver.

> Note: VirtualBox-based VMs are not supported. Testing has shown success with
> VMWare-based VMs and bare-metal machines.

## Prerequisites

Before starting this process, you will need the following:
* A values file with a valid cluster GUID from LumenVox.
* One or more host machines meeting the minimum hardware requirements (see below).

An X509 SSL certificate and key are also required. These can be provided at
runtime or generated interactively by the installer using the `hostnameSuffix`
from your values file.

### Minimum Hardware Requirements

Each control plane node must meet the following minimums:
* 8 CPU cores
* 15 GB RAM
* 150 GB free disk space

### TLS Certificate

The installer accepts a certificate and key in two ways:

**Option 1 — Pass files directly on the command line (non-interactive):**
```shell
./lumenvox-control-install.sh values.yaml server.key server.crt
```
The certificate must have a SAN matching the `hostnameSuffix` in your values
file (e.g. `lumenvox-api.testmachine.com`, `management-api.testmachine.com`,
etc.).

**Option 2 — Interactive setup (no files passed):**
```shell
./lumenvox-control-install.sh values.yaml
```
The installer will prompt you to either provide paths to existing key/certificate
files or generate a new self-signed pair automatically using the `hostnameSuffix`
from your values file.

For reference, the SANs included in a generated certificate are:
* `lumenvox-api.<hostnameSuffix>`
* `biometric-api.<hostnameSuffix>`
* `management-api.<hostnameSuffix>`
* `reporting-api.<hostnameSuffix>`
* `admin-portal.<hostnameSuffix>`
* `deployment-portal.<hostnameSuffix>`
* `file-store.<hostnameSuffix>`
* `grafana.<hostnameSuffix>`

## Control Plane Node Setup

The control plane is the primary node for Kubernetes; it is the first to be set
up, and it initially hosts the software that manages Kubernetes itself.

To set up the control plane, you will need the following files on the desired
host machine:
* `lumenvox-control-install.sh`
* Your values file, `values.yaml`
* Optionally, your SSL certificate (`server.crt`) and key (`server.key`)

The script must be run as a non-root user with sudo privileges.

Run the installation script with TLS files provided:
```shell
./lumenvox-control-install.sh values.yaml server.key server.crt
```

Or let the installer handle TLS interactively:
```shell
./lumenvox-control-install.sh values.yaml
```

Don't be concerned if the script takes some time; some steps will take longer
than others. Testing has shown a running time of around 7 minutes, but this
may vary.

Early in the installation, you will be prompted for passwords for each of the
various external services: MongoDB, PostgreSQL, RabbitMQ, and Redis. You should
record these passwords in a safe place.

After a successful installation, the script will output:
* Instructions for monitoring pod startup.
* The token and hash needed to join worker nodes.
* A ready-to-paste hosts file block for all API endpoints (see [DNS / Hosts File Configuration](#dns--hosts-file-configuration) below).

## Worker Node Setup

To set up a worker node, you will need the following files on the desired
worker machine:
* `lumenvox-worker-install.sh`

You will also need the token and hash from the output of the control plane
installation, as well as the IP of the control plane.

You can run the installation script like so:
```shell
./lumenvox-worker-install.sh <CONTROL PLANE IP> <TOKEN> <HASH>
```

Testing has shown a running time of around 2 minutes, but this may vary.

## Post-Install

Once the script has completed, you can watch the pods come up by running:
```shell
watch kubectl get po -A
```

The ingress is set up automatically, so once all pods have started, you should
be able to make requests to the APIs.

Linkerd is installed but its binary directory is not permanently added to your
PATH. To persist it, add the following to your `~/.bashrc`:
```shell
export PATH=$PATH:$HOME/.linkerd2/bin
```

The installing user is also added to the `docker` group during installation.
You will need to log out and back in (or run `newgrp docker`) for this to take
effect.

### DNS / Hosts File Configuration

No DNS records are created automatically for the API hostnames. Every client
machine that needs to reach the LumenVox endpoints must add entries to its
hosts file pointing each hostname at the control plane IP. The installer prints
a ready-to-paste block of these entries at the end of the run.

For **Linux** clients, edit `/etc/hosts` as root/sudo.

For **Windows** clients, open Notepad as Administrator and edit:
```
C:\Windows\System32\drivers\etc\hosts
```

> Note: Requests to the speech API must use the certificate from the
> installation. The speech API hostname must match the certificate SAN.

## Uninstalling

Both uninstaller scripts must be run as a non-root user with sudo privileges, the same requirement as the installers.

> **Warning:** Uninstallation is irreversible. Both scripts will prompt you to confirm before making any changes.

### Control Plane

Run the control plane uninstaller with no arguments:
```shell
./lumenvox-control-uninstall.sh
```

This will remove, in order:
* The LumenVox and ingress-nginx Helm releases and their namespaces
* Linkerd (viz dashboard and control plane) and the Gateway API CRDs
* The Kubernetes cluster (kubeadm reset, all state and config)
* Kubernetes packages (kubelet, kubeadm, kubectl) and their repositories
* Helm
* The external-services Docker Compose stack and its data volumes
* Docker and containerd and their repositories
* Kernel module and sysctl configuration written by the installer
* All Capacity Private Cloud model files under `/data`

The firewall and security frameworks (ufw/AppArmor on Ubuntu, firewalld on RHEL-based distros) that were disabled during installation will be re-enabled automatically.

**Manual follow-up required after uninstall:**

* **SELinux** (RHEL/CentOS/Rocky/AlmaLinux only): the installer set SELinux to permissive. To restore enforcing mode, edit `/etc/selinux/config`, set `SELINUX=enforcing`, and reboot.
* **Swap**: the installer commented out swap entries in `/etc/fstab`. To restore swap, uncomment those entries and run `sudo swapon -a`.
* A reboot is recommended to ensure all kernel state is fully cleared.

### Worker Node

The worker uninstaller can optionally drain and delete the node from the cluster automatically if you provide the control plane credentials:
```shell
./lumenvox-worker-uninstall.sh <CONTROL_PLANE_USER> <CONTROL_PLANE_IP>
```

If credentials are omitted, the script will still proceed but you must manually drain and delete the node from the control plane first:
```shell
kubectl drain <NODE_NAME> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <NODE_NAME>
```

The worker uninstaller removes containerd, all Kubernetes components and state, CNI configuration, and the kernel module and sysctl configuration written by the installer. A reboot is recommended after completion.
