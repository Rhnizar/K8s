#!/bin/bash

set -euo pipefail

ensure_k3d_installed() {
	if command -v k3d >/dev/null 2>&1; then
		return 0
	fi

	echo "k3d is not installed. Installing k3d..."

	if ! command -v curl >/dev/null 2>&1; then
		echo "curl is required to install k3d automatically. Please install curl first."
		exit 1
	fi

	if [ "$(id -u)" -eq 0 ]; then
		curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
	elif command -v sudo >/dev/null 2>&1; then
		curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | sudo bash
	else
		echo "k3d installation requires root privileges. Run as root or install sudo."
		exit 1
	fi

	if ! command -v k3d >/dev/null 2>&1; then
		echo "k3d installation failed."
		exit 1
	fi

	echo "k3d installed successfully."
}

ensure_helm_installed() {
	if command -v helm >/dev/null 2>&1; then
		return 0
	fi

	echo "helm is not installed. Installing helm..."

	if ! command -v curl >/dev/null 2>&1; then
		echo "curl is required to install helm automatically. Please install curl first."
		exit 1
	fi

	if [ "$(id -u)" -eq 0 ]; then
		curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
	elif command -v sudo >/dev/null 2>&1; then
		curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
	else
		echo "helm installation requires root privileges. Run as root or install sudo."
		exit 1
	fi

	if ! command -v helm >/dev/null 2>&1; then
		echo "helm installation failed."
		exit 1
	fi

	echo "helm installed successfully."
}

resolve_host_ip() {
	getent ahostsv4 "$1" | awk 'NR==1{print $1}'
}

patch_cluster_dns() {
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        hosts /etc/coredns/NodeHosts {
          ttl 60
          reload 15s
          fallthrough
        }
        prometheus :9153
        forward . 1.1.1.1 8.8.8.8
        cache 30
        loop
        reload
        loadbalance
        import /etc/coredns/custom/*.override
    }
    import /etc/coredns/custom/*.server
  NodeHosts: |
    172.25.0.1 host.k3d.internal
    172.25.0.3 k3d-mycluster-serverlb
    172.25.0.2 k3d-mycluster-server-0
EOF

kubectl rollout restart deployment/coredns -n kube-system >/dev/null 2>&1 || true
kubectl rollout status deployment/coredns -n kube-system --timeout=120s >/dev/null 2>&1 || true
}

fail_with_argocd_diagnostics() {
	echo "Argo CD did not become ready. Diagnostics:"
	kubectl get pods -n argocd
	echo "-------------------------------------------------------"
	kubectl get events -n argocd --sort-by=.metadata.creationTimestamp | tail -n 30
	echo "-------------------------------------------------------"
	echo "Most common cause here is temporary registry/network failures while pulling images from quay.io."
	exit 1
}

argocd_pods_ready() {
	if kubectl get pods -n argocd --no-headers 2>/dev/null | awk '{print $2}' | grep -qv '^1/1$'; then
		return 1
	fi
	return 0
}

argocd_has_pull_errors() {
	kubectl get pods -n argocd --no-headers 2>/dev/null | awk '{print $3}' | grep -Eq 'ImagePullBackOff|ErrImagePull|CrashLoopBackOff'
}

# -------------------------------------------------------------------------
# 1. CLEANUP
# We delete the cluster if it already exists to ensure a fresh start.
# -------------------------------------------------------------------------
ensure_k3d_installed
ensure_helm_installed

echo "Cleaning up old cluster..."
k3d cluster delete mycluster > /dev/null 2>&1

# -------------------------------------------------------------------------
# 2. CREATE CLUSTER
# We map Host Port 8888 to Cluster NodePort 30080.
# This allows 'curl localhost:8888' to reach our app later.
# -------------------------------------------------------------------------
echo "Creating k3d cluster 'mycluster'..."
REQUIRED_HOSTS=(
	"quay.io"
	"cdn01.quay.io"
	"ghcr.io"
	"pkg-containers.githubusercontent.com"
	"public.ecr.aws"
	"d2glxqk2uabbnd.cloudfront.net"
	"github.com"
	"registry-1.docker.io"
	"registry.docker.io"
	"auth.docker.io"
	"production.cloudflare.docker.com"
)

K3D_HOST_ALIAS_ARGS=()
for host in "${REQUIRED_HOSTS[@]}"; do
	ip=$(resolve_host_ip "$host" || true)
	if [ -n "${ip:-}" ]; then
		K3D_HOST_ALIAS_ARGS+=(--host-alias "$ip:$host")
	fi
done

k3d cluster create mycluster -p "8888:30080@loadbalancer" "${K3D_HOST_ALIAS_ARGS[@]}"

# -------------------------------------------------------------------------
# 3. NAMESPACES
# 'argocd' for the manager, 'dev' for our application.
# -------------------------------------------------------------------------
kubectl create namespace argocd >/dev/null 2>&1 || true
kubectl create namespace dev >/dev/null 2>&1 || true

echo "Patching CoreDNS upstream resolvers..."
patch_cluster_dns

# -------------------------------------------------------------------------
# 4. INSTALL ARGO CD
# --server-side: bypasses the metadata size limit for large CRDs.
# --force-conflicts: ensures we take ownership of all components.
# -------------------------------------------------------------------------
echo "Installing Argo CD (this might take a moment)..."
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# -------------------------------------------------------------------------
# 5. THE "WAIT" LOOP
# Because we saw 'ImagePullBackOff', we need to make sure images pull.
# If this takes too long, check your internet connection.
# -------------------------------------------------------------------------
echo "Waiting for Argo CD pods to be RUNNING..."
for _ in $(seq 1 60); do
	pod_count=$(kubectl get pods -n argocd --no-headers 2>/dev/null | wc -l)
	if [ "$pod_count" -gt 0 ]; then
		break
	fi
	sleep 2
done

pull_error_notice_sent=0
for _ in $(seq 1 180); do
	if argocd_pods_ready; then
		echo "Argo CD pods are ready."
		break
	fi

	if argocd_has_pull_errors; then
		if [ "$pull_error_notice_sent" -eq 0 ]; then
			echo "Argo CD image pull errors detected. Retrying pulls for up to 6 minutes..."
			pull_error_notice_sent=1
		fi
	fi

	sleep 2
done

if ! argocd_pods_ready; then
	fail_with_argocd_diagnostics
fi

# -------------------------------------------------------------------------
# 6. INSTALL GITEA
# -------------------------------------------------------------------------
kubectl create namespace gitea >/dev/null 2>&1 || true

echo "Installing Gitea (this might take a moment)..."
helm repo add gitea-charts https://dl.gitea.com/charts/ >/dev/null
helm repo update >/dev/null

helm upgrade --install gitea gitea-charts/gitea \
	--namespace gitea \
	--set service.http.type=ClusterIP \
	--set gitea.admin.username=root \
	--set gitea.admin.password=admin1234

echo "Waiting for Gitea pods to be READY..."
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=gitea -n gitea --timeout=300s

# -------------------------------------------------------------------------
# 7. FINAL VERIFICATION
# -------------------------------------------------------------------------
echo "Argo CD and Gitea are installed."
kubectl get pods -n argocd
kubectl get pods -n gitea

echo "-------------------------------------------------------"
echo "Bonus infrastructure is ready!"
echo "Next steps (manual Git content flow):"
echo "1) Port-forward Gitea: kubectl port-forward svc/gitea-http -n gitea 3000:3000"
echo "2) In browser, create a repository in Gitea and push your manifests folder."
echo "3) Update ../confs/app-argo.yaml repoURL/path to your Gitea repo/path."
echo "4) Apply Argo Application: kubectl apply -f ../confs/app-argo.yaml"
echo "5) Watch rollout: kubectl get pods -n dev"
echo "6) Test app: curl http://localhost:8888"
echo "-------------------------------------------------------"