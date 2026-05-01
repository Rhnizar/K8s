# p3_sample

This folder is a simpler version of part 3, but it still keeps the Argo CD flow:

- Argo CD installs into the cluster
- the application is created with an `Application` manifest
- `dev` namespace is reserved for the app deployed by Argo CD
- no local workload manifest is stored in this folder
- Argo CD watches the external repository configured in `confs/app-argo.yaml`
- extra local access ingresses are applied from `confs/ingress-argocd.yaml` and `confs/ingress-dev.yaml`
- no cloud-specific setup in this bootstrap

## Run

From `p3_sample/scripts`:

```bash
bash setup.sh
```

## Notes

If your repository URL is different, update `p3_sample/confs/app-argo.yaml` before running the setup script.
For the defense, change image tags in the tracked application repository (not in this folder), commit, and push. Argo CD should auto-sync the new version.

## Access

App:

```bash
curl http://localhost:8888
```

Argo CD UI:

```bash
curl -k https://localhost:9090
```

Use HTTPS for Argo CD. `http://localhost:9090` will not match the TLS ingress and can return a 404.

Argo CD login defaults:

- username: `admin`
- password: printed by the setup script (or read from `argocd-initial-admin-secret`)