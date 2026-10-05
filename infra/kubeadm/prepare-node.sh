#!/usr/bin/env bash
# Prépare un nœud Ubuntu 24.04 pour kubeadm. À lancer avec sudo, sur chaque nœud.
set -euo pipefail

K8S_MINOR="v1.37"

echo "==> 1. Swap désactivé (le kubelet le refuse par défaut)"
swapoff -a
sed -i '/\sswap\s/ s/^/#/' /etc/fstab

echo "==> 2. Modules du noyau"
cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo "==> 3. Réglages réseau du noyau"
cat <<EOF >/etc/sysctl.d/99-kubernetes.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo "==> 4. containerd"
apt-get update -q
apt-get install -y -q ca-certificates curl gpg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -y -q containerd.io

# Configuration complète par défaut (le paquet désactive le plugin CRI), puis cgroups systemd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

echo "==> 5. kubelet, kubeadm, kubectl (${K8S_MINOR})"
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -q
apt-get install -y -q kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

# crictl : l'outil pour inspecter containerd du point de vue de Kubernetes
cat <<EOF >/etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
EOF

echo "==> Vérifications"
if grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
  echo "OK : containerd utilise les cgroups systemd"
else
  echo "ATTENTION : SystemdCgroup introuvable dans /etc/containerd/config.toml" >&2
  exit 1
fi
kubeadm version -o short
echo "Nœud prêt."