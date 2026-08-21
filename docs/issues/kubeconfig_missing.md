# Issue: Install Fails Due to Missing Kubeconfig on Target System

## Issue Summary

When running `setup.sh`, the following error is encountered during the `k8s_setup` Ansible role:

```shell
TASK [k8s_setup : Copy kubeconfig file from default location to the ~/.kube directory"]
fatal: [ascender_host]: FAILED! => {"changed": false, "msg": "the remote file does not exist, not transferring, ignored"}
```


### Root Cause

This error occurs because the variable `download_kubeconfig` is set to `true`, which tells the setup process to copy the Kubernetes `kubeconfig` file from the target system. However, the target system does **not** have a Kubernetes installation, so the file does not exist.

This typically happens when:

- The target system is a fresh install and Kubernetes (e.g., k3s) has not been installed yet.

## Resolution Steps

### 1. Ensure Kubernetes Is Installed on the Target System

This installer does not set up Kubernetes for you. If this is a new environment, install
Kubernetes (e.g., k3s) on the target system first, then re-run setup.sh. Once a cluster
is running on the target, the necessary kubeconfig will exist there and can be downloaded.

### 2. Alternatively, Disable Kubeconfig Download

If Kubernetes is installed elsewhere, or you don't need to copy the kubeconfig to the local system, set:

```yaml
download_kubeconfig: false
```

This will skip the step that tries to retrieve the kubeconfig from the target system.

## Notes

* This issue is common when running setup.sh against a brand-new host without any Kubernetes installation.
* Ensure that a valid kubeconfig exists on the target before setting download_kubeconfig: true.
* The installer attempts to copy the config from /etc/rancher/k3s/k3s.yaml. If your config exists elsewhere, you may have to manually copy it over.
* The installer will copy the config to ~/.kube/config

## References

* [Ascender K3S Install Docs](https://github.com/ctrliq/ascender-install/blob/main/docs/k3s/README.md)
