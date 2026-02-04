# K3s with CRI-O Setup Guide

This guide describes how to set up K3s with CRI-O as the container runtime on Ubuntu 22.04.

## Prerequisites

- Ubuntu 22.04 (tested on multipass VM)
- At least 4GB RAM, 2 CPUs, 20GB disk
- Root or sudo access

## Step 1: Install CRI-O

Add the CRI-O repository and install packages:

```bash
# Set versions
OS="xUbuntu_22.04"
CRIO_VERSION="1.28"

# Add repositories
echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/ /" | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_VERSION/$OS/ /" | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION.list

# Add GPG keys
curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/Release.key | sudo apt-key add -
curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_VERSION/$OS/Release.key | sudo apt-key add -

# Install
sudo apt-get update
sudo apt-get install -y cri-o cri-o-runc
```

## Step 2: Install CNI Plugins

CRI-O requires CNI plugins to be installed separately:

```bash
CNI_VERSION="v1.4.0"
sudo mkdir -p /opt/cni/bin
curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" | sudo tar -C /opt/cni/bin -xz
```

## Step 3: Configure System Prerequisites

Load required kernel modules and configure sysctl:

```bash
# Load kernel modules
sudo modprobe overlay
sudo modprobe br_netfilter

# Make modules load on boot
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# Configure sysctl for Kubernetes networking
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system
```

## Step 4: Start CRI-O

```bash
sudo systemctl enable crio
sudo systemctl start crio

# Verify CRI-O is running
sudo systemctl status crio
```

## Step 5: Install K3s with CRI-O

```bash
export K3S_KUBECONFIG_MODE="644"
export INSTALL_K3S_EXEC="--container-runtime-endpoint unix:///var/run/crio/crio.sock"

curl -sfL https://get.k3s.io | sh -
```

## Step 6: Verify Installation

Check that K3s is using CRI-O:

```bash
# Check node status and container runtime
sudo kubectl get nodes -o wide
# Should show: CONTAINER-RUNTIME = cri-o://1.28.4

# Check all pods are running
sudo kubectl get pods -A

# Verify CRI-O version
sudo crictl version
```

## Testing

Deploy a test pod:

```bash
cat <<EOF | sudo kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nginx-test
spec:
  containers:
  - name: nginx
    image: nginx:alpine
EOF

# Verify pod is running via CRI-O
sudo kubectl get pod nginx-test -o yaml | grep containerID
# Should show: containerID: cri-o://...

# List containers via CRI-O
sudo crictl ps
```

## Tested Versions

| Component | Version |
|-----------|---------|
| K3s | v1.34.3+k3s1 |
| CRI-O | 1.28.4 |
| CNI Plugins | v1.4.0 |
| Ubuntu | 22.04.5 LTS |

## Troubleshooting

### Node stays NotReady

Check if CNI plugins are installed:

```bash
ls /opt/cni/bin/
```

If empty, install CNI plugins (Step 2).

### Image pull errors

CRI-O may have issues with certain registries. Check the registry configuration:

```bash
cat /etc/containers/registries.conf
```

Ensure `unqualified-search-registries` includes `docker.io`.

### CRI-O service fails to start

Check logs:

```bash
sudo journalctl -u crio -f
```

Common issues:
- Missing CNI plugins
- Incorrect permissions on `/var/run/crio/`

## Quick Setup Script

For convenience, here's a one-shot setup script:

```bash
#!/bin/bash
set -e

# Variables
OS="xUbuntu_22.04"
CRIO_VERSION="1.28"
CNI_VERSION="v1.4.0"

# Install CRI-O
echo "Installing CRI-O..."
echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/ /" | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_VERSION/$OS/ /" | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION.list
curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/Release.key | sudo apt-key add -
curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_VERSION/$OS/Release.key | sudo apt-key add -
sudo apt-get update
sudo apt-get install -y cri-o cri-o-runc

# Install CNI plugins
echo "Installing CNI plugins..."
sudo mkdir -p /opt/cni/bin
curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" | sudo tar -C /opt/cni/bin -xz

# Configure system
echo "Configuring system..."
sudo modprobe overlay
sudo modprobe br_netfilter
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system

# Start CRI-O
echo "Starting CRI-O..."
sudo systemctl enable --now crio

# Install K3s
echo "Installing K3s..."
export K3S_KUBECONFIG_MODE="644"
export INSTALL_K3S_EXEC="--container-runtime-endpoint unix:///var/run/crio/crio.sock"
curl -sfL https://get.k3s.io | sh -

echo "Setup complete! Waiting for cluster to be ready..."
sleep 30
sudo kubectl get nodes -o wide
sudo kubectl get pods -A
```

## References

- [K3s Documentation](https://docs.k3s.io/)
- [CRI-O Installation](https://cri-o.io/)
- [CNI Plugins](https://github.com/containernetworking/plugins)
- [K3s with CRI-O Discussion](https://github.com/k3s-io/k3s/discussions/12213)
