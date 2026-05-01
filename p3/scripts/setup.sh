#!/bin/bash

set -euo pipefail

ensure_k3d_installed() {
	if command -v k3d >/dev/null 2>&1; then
		return 0
	fi

	echo "k3d is not installed. Installing k3d..."

	if ! command -v curl >/dev/null 2>&1; then
		echo "curl is required to install k3d automatically."
		exit 1
	fi

	if [ "$(id -u)" -eq 0 ]; then
		curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
	elif command -v sudo >/dev/null 2>&1; then
		curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | sudo bash
	else
		echo "k3d installation requires root privileges."
		exit 1
	fi

	if ! command -v k3d >/dev/null 2>&1; then
		echo "k3d installation failed."
		exit 1
	fi
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

ensure_k3d_installed

echo "Cleaning up old sample cluster..."
k3d cluster delete mycluster >/dev/null 2>&1 || true

echo "Creating cluster with app on http://localhost:8888 and Argo CD on https://localhost:9090..."
k3d cluster create mycluster -p "8888:80@loadbalancer" -p "9090:443@loadbalancer"

echo "Creating namespaces..."
kubectl create namespace argocd >/dev/null 2>&1 || true
kubectl create namespace dev >/dev/null 2>&1 || true

echo "Installing Argo CD..."
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Configuring Argo CD server for ingress TLS termination..."
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd

echo "Waiting for Argo CD deployments..."
kubectl wait --for=condition=available deployment --all -n argocd --timeout=300s

echo "Applying Argo CD Application..."
kubectl apply -f "$script_dir/../confs/app-argo.yaml"

echo "Applying access ingresses..."
kubectl apply -f "$script_dir/../confs/ingress-argocd.yaml"
kubectl apply -f "$script_dir/../confs/ingress-dev.yaml"

echo "Argo CD application is configured."
echo "Argo CD will deploy resources from the repository/path defined in confs/app-argo.yaml."
echo "Expected app service name in dev namespace for ingress-dev.yaml: app1-service on port 8888."
echo "Access app with: http://localhost:8888"
echo "Access Argo CD with: https://localhost:9090"
echo "Do not use http://localhost:9090; the Argo CD ingress is exposed on Traefik's TLS entrypoint."

ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
echo "Argo CD username: admin"
if [ -n "${ARGOCD_PASSWORD:-}" ]; then
	echo "Argo CD password: $ARGOCD_PASSWORD"
else
	echo "Argo CD password not available yet. Retry: kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
fi

kubectl get application rrhnizar-app-sample -n argocd