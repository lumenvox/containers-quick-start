# LumenVox Containers Quick Start

## Overview

The preferred orchestration solution for [LumenVox containers](https://github.com/lumenvox/helm-charts) is Kubernetes. To
assist smaller clients or clients wanting to quicky implement a POC/Pilot,
LumenVox has developed the scripts in this repository to smooth out the process
of setting up a full Kubernetes cluster with the relevant software.

> Note: These scripts will set up a Kubernetes cluster. If you would like to
> set up your own cluster or use an already-existing cluster, these scripts are
> not for you. Please refer to the installation instructions in our helm charts
> repository for more information on the installation process.

## Supported Environments

The scripts support the following environments:
* Centos 7
* Centos 8
* Ubuntu 22.04 (Focal and Jammy)
* RHEL 7
* RHEL 8

Additionally, the following conditions must be met:
* swap must be disabled.
* selinux must be disabled.
* If Docker is already installed, it must use the systemd cgroup driver.

> Note: VirtualBox-based VMs are not supported. Testing has shown success with
> VMWare-based VMs and bare-metal machines.

## Prerequisites

Before starting this process, you will need the following:
* A values file with a valid cluster GUID from LumenVox.
* An X509 SSL certificate and key, with a SAN (ex: "speech-api.testmachine.com")
* One or more host machines.

For testing purposes, a certificate/key pair can be generated with the following
steps:
1. `openssl genrsa -out server.key 2048`
2. `openssl req -new -x509 -sha256 -key server.key -out server.crt -days 3650 -addext "subjectAltName = DNS:lumenvox-api.testmachine.com, DNS:biometric-api.testmachine.com, DNS:management-api.testmachine.com, DNS:reporting-api.testmachine.com, DNS:admin-portal.testmachine.com, DNS:deployment-portal.testmachine.com"`

The second command will prompt you for information; outside of production, all
fields may be left empty. Be sure that the subjectAltName/SAN matches the
hostname suffix indicated in your values file.

## Control Plane Node Setup

The control plane is the primary node for Kubernetes; it is the first to be set
up, and it initially hosts the software that manages Kubernetes itself.

To set up the control plane, you will need the following files on the desired
host machine:
* lumenvox-control-install.sh
* Your values file, `values.yaml`
* The SSL certificate, `server.crt`
* The SSL key, `server.key`

Once these files are present, you can run the installation script like so:
```shell
./lumenvox-control-install.sh values.yaml server.key server.crt
```

Don't be concerned if the script takes some time; some steps will take longer
than others. Testing has shown a running time of around 11 minutes, but this
may vary.

After about 10 minutes, you will be prompted for passwords for each of the
various external services: MongoDB, PostgreSQL, RabbitMQ, and Redis. You should
record these passwords in a safe place. You will also be asked for a master
encryption key; this should be the result of base64-encoding a random 32-byte
string. For assistance in generating this, reach out to LumenVox.

After a successful installation, the script will output some information on how
to add a worker node.

## Worker Node Setup

To set up a worker node, you will need the following files on the desired
worker machine:
* lumenvox-worker-install.sh

You will also need the token and hash from the output of the control plane
installation, as well as the IP of the control plane.

You can run the installation script like so:
```shell
./lumenvox-worker-install.sh <CONTROL PLANE IP> <TOKEN> <HASH>
```

Testing has shown a running time of around 2 minutes, but this may vary.

## Post-Install

Once the script has completed, you can watch the pods come up by running
```shell
kubectl get pods -A
```

The ingress should be set up automatically, so once all the pods have all
started, you should be able to make requests to the APIs. Requests should be
sent to the IP of the control plane, and they must request one of the hostnames
found in the output of `kubectl get ingress -A`. The easiest way to do this is
by setting entries in the hosts file of the machine making requests. For Linux,
this is located in `/etc/hosts`, and for Windows,
`C:\Windows\System32\drivers\etc\hosts.ics`.

> Note: Requests to the speech API must use the certificate from the
> installation. The speech API hostname must match the certificate SAN.

## Uninstalling

To uninstall from the control plane or a worker node, run the corresponding
uninstallation script. These scripts require no arguments.

Because the installation script will optionally install Docker, the
uninstallation scripts do not uninstall docker. To remove it from your system,
you should follow the manual process documented on their website.
