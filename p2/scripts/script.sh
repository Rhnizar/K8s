#!/bin/bash

apt-get update -y
apt-get install -y curl

# Install K3s in server mode
curl -sfL https://get.k3s.io | sh -

# Wait for node to be ready
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
    sleep 3
done

# Apply all manifests
kubectl apply -f /vagrant/confs/

# Set host entries so app1.com and app2.com resolve to this machine
echo "192.168.56.110 app1.com" >> /etc/hosts
echo "192.168.56.110 app2.com" >> /etc/hosts
