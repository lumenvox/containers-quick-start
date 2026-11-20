# Switching from Istio to Linkerd + ingress-nginx

This guide covers moving an existing Capacity Private Cloud (LumenVox) cluster that was installed with
`lumenvox-control-install.sh --mesh-stack istio` over to the Linkerd service mesh and the ingress-nginx
controller. The Kubernetes cluster, external services (PostgreSQL, MongoDB, RabbitMQ, Redis), secrets and
`/data` model files are kept. Only the mesh, the ingress and the LumenVox Helm release are replaced.

> **Expect downtime.** LumenVox is unreachable from the time it is uninstalled until it is reinstalled and
> its pods are running again.

## Prerequisites

- Run everything on the control plane node, as the user that installed the cluster (not root).
- `kubectl` and `helm` work on the node (`kubectl get nodes`).
- `values.yaml` is the file used for the original install.
- The node can reach the internet (Linkerd download, ingress-nginx chart, LumenVox chart).

## Step 1: Uninstall LumenVox

Remove the Helm release first. It owns the Gateway, HTTPRoutes and the `istio-ingress` namespace.

```shell
helm uninstall lumenvox -n lumenvox
```

The `lumenvox` namespace, its secrets (database, RabbitMQ, Redis, `speech-tls-secret`) and the `/data`
model files stay in place.

## Step 2: Uninstall Istio and install Linkerd + ingress-nginx

```shell
chmod +x lumenvox-istio-uninstall.sh
./lumenvox-istio-uninstall.sh --install-linkerd
```

Without the flag, the script asks whether to install Linkerd and ingress-nginx. Answer `y`, then confirm.
You can also pass the location of the downloaded Istio folder if the script cannot find it:

```shell
./lumenvox-istio-uninstall.sh --install-linkerd ~/containers-quick-start/istio-1.30.1
```

The script:

1. Finds `istioctl` (argument, then `PATH`, then the current directory and `$HOME`).
2. Deletes any remaining Gateway and HTTPRoute resources.
3. Removes the `istio-injection` label from the `lumenvox` namespace.
4. Runs `istioctl uninstall --purge`.
5. Deletes the `istio-ingress` and `istio-system` namespaces.
6. Deletes leftover Istio webhooks, cluster roles and CRDs.
7. Deletes the downloaded `istio-<version>` folder.
8. Installs Linkerd (CRDs, control plane, viz) and the ingress-nginx controller (`hostNetwork=true`).

Gateway API CRDs are not part of Istio and are left in place.

Logs are written to `istio-uninstall-main-log.txt` and `istio-uninstall-err-log.txt` in the directory where
the script was run. If the final summary says `Linkerd + ingress-nginx: FAILED`, read the error log, fix the
cause and re-run the script. Re-running is safe: completed removal steps find nothing to do, and an existing
`linkerd` namespace is skipped.

### Verify

```shell
export PATH=$PATH:$HOME/.linkerd2/bin
linkerd check
kubectl get po -n linkerd
kubectl get po -n ingress-nginx
kubectl get crd | grep istio.io        # should return nothing
kubectl get ns | grep istio            # should return nothing
```

To keep `linkerd` on your `PATH` in new shells, add this to `~/.bashrc`:

```shell
export PATH=$PATH:$HOME/.linkerd2/bin
```

## Step 3: Reinstall LumenVox on Linkerd + nginx

`values.yaml` may still contain the Istio settings (`serviceMesh.type: istio`, `ingress.className: istio` and
`gateway.namespace: istio-ingress`). The `--set` flags below override them for this install.

```shell
helm repo update
helm install lumenvox lumenvox/lumenvox -n lumenvox -f values.yaml \
  --set global.serviceMesh.type=linkerd \
  --set global.lumenvox.ingress.className=nginx
```

To install a specific chart version, add `--version`:

```shell
helm install lumenvox lumenvox/lumenvox -n lumenvox -f values.yaml \
  --set global.serviceMesh.type=linkerd \
  --set global.lumenvox.ingress.className=nginx \
  --version 7.1.0
```

### Make the change permanent in values.yaml

So that later `helm upgrade` commands keep the Linkerd/nginx configuration without extra flags, edit
`values.yaml`:

```yaml
global:
  serviceMesh:
    type: linkerd
  lumenvox:
    ingress:
      className: nginx
```

and remove the `gateway:` block (`namespace: istio-ingress`). Future upgrades are then:

```shell
helm upgrade lumenvox lumenvox/lumenvox -n lumenvox -f values.yaml
```

Note: the "Upgrading the LumenVox Helm Chart" section of `README.md` describes the Istio flow (it re-applies
the `istio-injection` label). That label step does not apply on Linkerd.

## Step 4: Verify LumenVox

```shell
watch kubectl get po -A
```

- All pods in the `lumenvox` namespace reach `Running` (Linkerd-injected pods show `2/2`).
- The ingress is served by the ingress-nginx controller on the node's ports 80 and 443:

```shell
kubectl get ingress -n lumenvox
```

The hosts file entries on client machines do not change. The hostnames still point at the control plane IP.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `helm install` fails with `cannot re-use a name that is still in use` | The old release is still present. Run `helm uninstall lumenvox -n lumenvox`, then retry. |
| `helm install` fails because secrets are missing | The `lumenvox` namespace was deleted. Recreate the namespace and the secrets as in Step 11 of `lumenvox-control-install.sh` before installing. |
| `istio.io` CRDs or an `istio-*` namespace remain | Re-run `./lumenvox-istio-uninstall.sh`. If it cannot find `istioctl`, it removes Istio with `kubectl` only. |
| `linkerd check` reports problems | Wait a minute and retry. Check `istio-uninstall-err-log.txt` for the failing step. |
| Ports 80/443 not answering | Confirm the controller is running: `kubectl get po -n ingress-nginx`. It uses `hostNetwork`, so nothing else on the node may be listening on 80/443. |
| Pods not injected with Linkerd | Restart the workloads: `kubectl rollout restart deployment -n lumenvox`. |
