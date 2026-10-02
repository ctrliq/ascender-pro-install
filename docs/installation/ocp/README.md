# Ascender Installation and Updating on OpenShift Container Platform (OCP)

The Ascender installer is a script that makes it relatively easy to install the Ascender Automation
Platform on Kubernetes platforms of multiple flavors. The installer is being expanded to new
Kubernetes platforms as users/contributors allow. If you have specific needs for a platform not yet
supported, please submit an issue to this Github repository.

## Table of Contents

- [General Prerequisites](#general-prerequisites)
- [OCP-specific Prerequisites](#ocp-specific-prerequisites)
- [Install Instructions](#install-instructions)
- [Namespace-only installs](#namespace-only-installs)

## General Prerequisites

If you have not done so already, be sure to follow the general prerequisites found in the
[Ascender-Install main README](../../README.md#general-prerequisites).

## OCP-specific Prerequisites

- Operating System Requirements:
  - The installer can run from any system with network access to your OCP cluster
  - Operating System
    - If the OS family is Enterprise Linux (Rocky, Fedora, Alma, RHEL, or CentOS) then the major version must be 8 or 9.
    - If the OS family is Ubuntu/Debian then the major version must be 24
- Minimal System Requirements for the OCP cluster:
  - CPUs: 2
  - Memory: 8GB (if installing both Ascender and Ledger)
  - 20GB of free disk (for Ascender and Ledger Volumes)
- These instructions require an existing OCP cluster with proper authentication configured
  - The installer will not set up OCP for you - you must have an existing, accessible cluster
  - Ensure you have administrative access to the cluster via `oc` or `kubectl` commands
- SSL Certificate and TLS Configuration
  - OpenShift Container Platform handles SSL/TLS termination through Routes
  - If you set `k8s_lb_protocol` to `http`, the installer will configure OCP Routes to use edge
    termination, where OpenShift handles the SSL certificate automatically.  Typically, you will need to specify your ASCENDER_HOSTNAME to something like ascender.apps.mycluster.mydomain.com
  - If you set `k8s_lb_protocol` to `https`, you need to provide an SSL
    Certificate file and a Private Key file. While these can be self-signed certificates, it is
    a good practice to use a trusted certificate, issued by a Certificate Authority.
  - Once you have a Certificate and Private Key file, make sure they are present on the Ascender
    installing server, and specify their locations in the config file with the variables
    `tls_crt_path` and `tls_key_path`, respectively. The installer will parse these files for their
    content, and use the content to create a Kubernetes TLS Secret for HTTPS enablement.
- Security Context Constraints (SCC)
  - The installer binds the `anyuid` SCC to the `ascender-app` service account with a
    cluster-scoped `ClusterRoleBinding`. The `privileged` SCC is not requested for Ascender.
    Ledger's install still binds both `privileged` and `anyuid` to its own service account.
  - `anyuid` is needed for jobs, not for the Ascender pods: the job pods that the task pod creates
    take their SCC from that service account, and without `anyuid` they get a random UID that
    cannot write to `/runner` in the execution environment image, so jobs fail with `Failed to
    extract private data directory on worker`.
  - Installs made with an earlier version of the installer also have a
    `privileged-scc-ascender-app-binding` binding, and `redis_capabilities` set in their Ascender
    custom resource. Re-running this installer sets `redis_capabilities: []`, which makes the
    operator restart the web and task pods once. The operator does this after the installer
    returns, so it can take a minute or more: watch `oc -n <namespace> get pods` until the new
    pods are Ready. Then delete the binding to drop `privileged`:

    ```text
    $ oc delete clusterrolebinding privileged-scc-ascender-app-binding
    ```

    Delete the binding only after that restart: while the old `redis_capabilities` is still in the
    custom resource, new pods are rejected without `privileged`.

## Install and Upgrade Instructions

### Obtain the sources

You can use the `git` command to clone the ascender-install repository or you can download the
zipped archive. (Install `git` with `sudo yum -y install git` if it is not already present.)

```text
$ git clone https://github.com/ctrliq/ascender-install.git
```

This will create a directory named `ascender-install` in your present working directory (PWD).

We will refer to this directory as the \<ASCENDER-INSTALL-SOURCE\> in the remainder of these
instructions.

### Set the configuration variables for an OCP Install

Change directories into the newly created `ascender-install` and run the `config_vars.sh` script.

```text
$ cd ascender-install

$ ./config_vars.sh
```

The script will take you through a series of questions, that will populate the variables file
required to install Ascender. This variables file will be located at `./custom.config.yml`.

You can edit this file manually if you want to change variables before (re)installing Ascender.

**Important:** When configuring for OCP:
- Set `k8s_platform` to `ocp`
- Ensure your `kubeconfig` file is properly configured to access your OCP cluster

### Run the setup script

Run `./setup.sh` from top level directory in this repository. The setup must run as a user with
Administrative or `sudo` privileges. To begin the setup process, type:

```text
$ sudo ./setup.sh
```

Once the setup is completed successfully, you should see a final output similar to:

```text
[snip...]
PLAY RECAP *************************************************************************************************************************
localhost                  : ok=72   changed=27   unreachable=0    failed=0    skipped=4    rescued=0    ignored=0

ASCENDER SUCCESSFULLY SETUP
```

### Connecting to Ascender Web UI

In OpenShift Container Platform, Ascender is accessed through OCP Routes using the hostnames you
specified during configuration.

You can access the Ascender web interface by navigating to the `ASCENDER_HOSTNAME` value you
configured in your `custom.config.yml` file. For example, if you set `ASCENDER_HOSTNAME` to
`ascender.example.com`, you would access Ascender at:

[https://ascender.example.com](https://ascender.example.com)

If you also installed Ledger, access it using the `LEDGER_HOSTNAME` value from your configuration.

The default username is "admin" and the corresponding password is stored in
`<ASCENDER-INSTALL-SOURCE>/default.config.yml` under the `ASCENDER_ADMIN_PASSWORD` variable.

### Uninstall

After running `setup.sh`, `tmp_dir` (by default `{{ playbook_dir}}/../ascender_install_artifacts`)
will contain timestamped kubernetes manifests for:

- `ascender-deployment-{{ k8s_platform }}.yml`
- `ledger-{{ k8s_platform }}.yml` (if you installed Ledger)
- `kustomization.yml`

Remove the timestamp from the filename and then run the following
commands from within `tmp_dir`:

```text
$ kubectl delete -f ascender-deployment-{{ k8s_platform }}.yml

$ kubectl delete -f ledger-{{ k8s_platform }}.yml # optional if you have installed ledger

$ kubectl delete -k .
```

Running the Ascender deletion steps will remove all related deployments and stateful sets, however,
persistent volumes and secrets will remain. To enforce secrets also getting removed, you can use
`ascender_garbage_collect_secrets: true` in the `default.config.yml` file.

Alternatively, you can delete the entire installation by removing the namespaces specified in your
configuration:

```text
$ kubectl delete namespace <ASCENDER_NAMESPACE>

$ kubectl delete namespace <LEDGER_NAMESPACE>  # optional if you have installed ledger
```

Replace `<ASCENDER_NAMESPACE>` and `<LEDGER_NAMESPACE>` with the values you configured (default is
typically `ascender` and `ledger`).

## Namespace-only installs

Use this when you only have a namespace on the OpenShift cluster, for example because another team
administers it. Set `ocp_namespace_only: true` in `custom.config.yml`. The installer then skips
everything that needs cluster scope (creating the namespace, installing the operator and its CRDs,
binding the SCC), checks that the steps below were done, and runs the rest: it creates the Ascender
secrets and custom resource in your namespace, waits for the web deployment, and checks the API.

A cluster administrator does the following once. `<namespace>` is your `ASCENDER_NAMESPACE`, and
`<user>` is the person who runs the installer, who also needs the `admin` role on the project.

1. Install the operator, its CRDs and its RBAC into the namespace. `<operator-version>` is the
   installer's `ASCENDER_OPERATOR_VERSION`:

   ```text
   $ cat > kustomization.yml <<EOF
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - github.com/ctrliq/ascender-operator/config/default?ref=<operator-version>
   images:
     - name: ghcr.io/ctrliq/ascender-operator
       newTag: <operator-version>
   namespace: <namespace>
   EOF

   $ oc apply -k .

   $ oc -n <namespace> wait --for=condition=Available deployment \
       -l control-plane=controller-manager --timeout=300s
   ```

   The installer stops if no operator replica is available, so wait for the operator before the
   user runs it. Keep `name` as shown: it is the image that the operator manifests reference, so a different
   `name` matches nothing and the operator is deployed as `ghcr.io/ctrliq/ascender-operator:latest`.
   If the image comes from your own registry, add a `newName` line under `name`, for example
   `newName: registry.example.com/mirror/ascender-operator`.

2. Bind the `anyuid` SCC to the Ascender service account. The binding is cluster-wide, so its name
   includes the namespace: a fixed name would collide with the binding of another Ascender install
   on the same cluster.

   ```text
   $ oc create clusterrolebinding anyuid-scc-<namespace>-ascender-app-binding \
       --clusterrole=system:openshift:scc:anyuid --serviceaccount=<namespace>:ascender-app
   ```

3. Let the user manage the Ascender custom resources in the namespace. The resource names below
   are those of the `awx.ansible.com` group, which operator 25.6.2 serves; if your operator serves
   a different group, use its matching resources:

   ```text
   $ oc -n <namespace> create role ascender-cr-editor --verb=get,list,watch,create,update,patch,delete \
       --resource=awxs.awx.ansible.com,awxbackups.awx.ansible.com,awxrestores.awx.ansible.com

   $ oc -n <namespace> create rolebinding ascender-cr-editor --role=ascender-cr-editor --user=<user>
   ```

Before the instance step the installer checks that the Ascender custom resources can be listed and
that the operator is running in the namespace, and stops with the missing step if not. It cannot
check step 2, because only an administrator can see SCC bindings. If step 2 is missing, Ascender
installs and its web interface and API work, but jobs fail with `Failed to extract private data
directory on worker`, because the job pods run without `anyuid` (see the SCC notes above).

Upgrading the operator (changing `ASCENDER_OPERATOR_VERSION`) and changing the CRDs stay
administrator steps: repeat step 1. The namespace user can still change and re-apply the Ascender
instance. Ledger is not covered by this mode, because its OCP install creates cluster-scoped
objects, and the installer refuses to run with both `ocp_namespace_only` and `LEDGER_INSTALL` set.

In this mode `tmp_dir` has no `kustomization.yml`, so to uninstall run only the
`kubectl delete -f ascender-deployment-ocp.yml` step from the Uninstall section above. An
administrator removes the operator.


