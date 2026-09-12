#!/usr/bin/env bash
# Provisiona um nó do cluster: pré-requisitos do kernel + containerd + kubeadm/kubelet/kubectl.
# Pode ser executado:
#   - dentro de uma máquina OrbStack já existente (via `apply.sh`)
#   - como user-data/cloud-init em `orb create` (maquinas novas)
set -euo pipefail

# Série do Kubernetes no repo pkgs.k8s.io (ex.: v1.36)
K8S_MINOR="${K8S_MINOR:-v1.36}"

echo ">> [1/6] Swap off"
swapoff -a
sed -i '/ swap /d' /etc/fstab || true

echo ">> [2/6] Modulos do kernel (overlay, br_netfilter)"
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo ">> [3/6] Sysctl (encaminhamento de pacotes e bridge)"
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo ">> [4/6] containerd (cgroup driver = systemd)"
apt-get update -y
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup *= *false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
systemctl restart containerd

echo ">> [5/6] Repositorio oficial do Kubernetes (pkgs.k8s.io)"
apt-get install -y apt-transport-https ca-certificates curl gpg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y

echo ">> [6/6] Instalando kubelet, kubeadm e kubectl"
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

echo ">> DONE. Versoes instaladas:"
kubeadm version
kubelet --version
kubectl version --client