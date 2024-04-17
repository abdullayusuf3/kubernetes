#!/bin/bash
# This Script is configured to be used with Red-Hat Distributions.
# Helper Function
print_message() {
    case "$1" in
        success) echo -e "\e[32m$2\e[0m";;
        info) echo -e "\e[33m$2\e[0m";;
        error) echo -e "\e[31m$2\e[0m";;
        line) echo -e "\e[90m$2\e[0m";;
        *) echo "$2";;
    esac
}

# Prompt for user input
read -p "Enter the desired hostname (e.g., worker-node-1 - make sure it unique from other worker nodes): " hostname

# Validate input (optional)
if [[ -z "$hostname" ]]; then
  echo "Error: Please enter a hostname."
  exit 1
fi

# Check CPU and RAM Requirements
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
CPU_COUNT=$(nproc)
print_message line '***************************************************************************************'
print_message info 'Checking System Requirements ..'
print_message info "System Architecture is: $ARCH_SUFFIX"
print_message info "System Type is: $DISTRO_NAME"
print_message info "Package Manager: $PKG_MANAGER"
print_message info "Total RAM: ${TOTAL_RAM}MB"
print_message info "CPU Count: ${CPU_COUNT}"
print_message line '***************************************************************************************'
print_message info 'Updating Hostname'
print_message line '***************************************************************************************'
# Set hostname with sudo
sudo hostnamectl set-hostname "$hostname"
echo ''
print_message line '***************************************************************************************'
print_message info 'Updating the System ..'
print_message line '***************************************************************************************'
# Update CentOS System
yum update -y

if ! command -v lsb_release &> /dev/null
then
    yum install redhat-lsb-core -y
fi

# Get the distribution ID
distro=$(lsb_release -is)

# Initialize the base URL
base_url="https://download.docker.com/linux/"

# Determine the appropriate repository based on the distribution
case "$distro" in
    CentOS)
        repo_url="${base_url}centos/docker-ce.repo"
        ;;
    Fedora)
        repo_url="${base_url}fedora/docker-ce.repo"
        ;;
    RedHatEnterpriseServer)
        repo_url="${base_url}centos/docker-ce.repo"
        ;;
    *)
        echo "Unsupported distribution: $distro"
        exit 1
        ;;
esac

# Prepare for containerd installation
sudo yum install -y yum-utils

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

export DEFAULT_GATEWAY_IP=$(hostname -I | awk '{print $1}')
print_message line '***************************************************************************************'
print_message info 'Updating Hostfile'
print_message line '***************************************************************************************'

# Modify /etc/hosts file
sudo bash -c "echo \"$DEFAULT_GATEWAY_IP $hostname\" >> /etc/hosts"
print_message line '***************************************************************************************'
print_message success "Hostname Changed into: $hostname | Default IP Detected: $DEFAULT_GATEWAY_IP"
print_message line '***************************************************************************************'
echo ''

# Disable Swap
sudo sed -i '/swap/d' /etc/fstab
sudo swapoff -a
if [[ "$distro" == *Fedora* ]]; then
    sudo swapoff /dev/zram0
    sudo systemctl mask systemd-zram-setup@zram0.service
fi
echo 'Swap is Disabled..'
print_message line '***************************************************************************************'
print_message success 'Swap is Disabled..'
print_message line '***************************************************************************************'
sudo sysctl --system
print_message line '***************************************************************************************'
print_message info 'Removing podman..'
print_message line '***************************************************************************************'
sudo yum-config-manager --add-repo $repo_url
sudo yum remove -y podman # podman might cause issues/conflicts with containerd
print_message line '***************************************************************************************'
print_message success 'podman removed..'
print_message line '***************************************************************************************'
echo ''
print_message line '***************************************************************************************'
print_message info 'Installing Container D..'
print_message line '***************************************************************************************'
# Install and configure containerd
sudo yum install -y containerd.io

sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable --now containerd
echo ''
print_message line '***************************************************************************************'
print_message success 'Container D is now enabled and working'
print_message line '***************************************************************************************'
# Make SELinux permissive
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
print_message line '***************************************************************************************'
print_message info 'Installing kubeadm, kubelet and kubectl ..'
print_message line '***************************************************************************************'
echo ''
# Install kubeadm, kubelet and kubectl
sudo tee /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
EOF
sudo yum install -y kubelet kubeadm kubectl \
--disableexcludes=kubernetes

sudo systemctl enable --now kubelet
print_message line '***************************************************************************************'
print_message success 'kubelet is now enabled and working.. '
print_message line '***************************************************************************************'
echo ''
# Install crictl
echo ''
print_message line '***************************************************************************************'
print_message info 'Installing CRICTL (Command Line for Container Runtimes)'
VERSION="v1.29.0"
DOWNLOAD_URL="https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-$ARCH_SUFFIX.tar.gz"
print_message info "Version: $VERSION | Architecture: $ARCH_SUFFIX"
print_message info "Downloading CRICTL From: $DOWNLOAD_URL"
print_message line '***************************************************************************************'
curl -L "$DOWNLOAD_URL" --output crictl-${VERSION}-linux-${ARCH_SUFFIX}.tar.gz
sudo tar zxvf crictl-$VERSION-linux-$ARCH_SUFFIX.tar.gz -C /usr/local/bin
rm -f crictl-$VERSION-linux-$ARCH_SUFFIX.tar.gz
echo ''
# Enable Ports

if ! command -v firewalld >/dev/null 2>&1; then
    print_message line '***************************************************************************************'
    print_message info 'Installing Firewall..'
    print_message line '***************************************************************************************'
    yum install firewalld -y 
    sudo systemctl enable firewalld
    sudo systemctl start firewalld
fi
echo ''
print_message line '***************************************************************************************'
print_message info 'Enabling the Following Ports for Worker Node'
print_message info '10251 | 10255 | 10250'
print_message line '***************************************************************************************'

sudo firewall-cmd --permanent --add-port=10251/tcp
sudo firewall-cmd --permanent --add-port=10255/tcp
sudo firewall-cmd --permanent --add-port=10250/tcp
sudo firewall-cmd --reload
print_message line '***************************************************************************************'
echo ''
print_message line '***************************************************************************************'
print_message success 'Worker Node is now ready to join a Master Node'
print_message line '***************************************************************************************'
echo ''
print_message line '***************************************************************************************'
print_message info 'Run the following command on the Master Node to get the command to join it'
print_message info 'sudo kubeadm token create --print-join-command'
print_message line '***************************************************************************************'