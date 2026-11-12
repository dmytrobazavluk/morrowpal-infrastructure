# Staging operations

Run commands from `infrastructure` with AWS credentials for the account and
Region configured in `environments/staging/vars.yml`.

```bash
shared/scripts/staging-lifecycle.sh status
shared/scripts/staging-lifecycle.sh stop --dry-run
shared/scripts/staging-lifecycle.sh stop
shared/scripts/staging-lifecycle.sh start --dry-run
shared/scripts/staging-lifecycle.sh start
```

The wrapper supports staging only. It resolves the instance from the staging
CloudFormation stack and validates its account, Region, network, recovery key,
instance profile and role, tags, inventory, and Elastic IP association. It
accepts no instance, inventory, overlay, or production overrides. A dry run
validates AWS metadata without changing resources or connecting to the host.

Stopping first acquires the host deployment lock and stops `morrowpal.service`,
which shuts down the containers cleanly. The wrapper verifies that no project
containers remain running, revalidates the target, requests a normal EC2 stop,
and waits for the stopped state. It leaves the instance, retained storage, and
Elastic IP allocated. Staging is unavailable while stopped.

Starting waits for EC2 and SSH, then waits for automatic systemd startup and
service readiness. It does not deploy configuration, build images, or repair
a failed service. Startup requires access to Secrets Manager and ECR. Allow
several minutes for recovery. An already running instance is checked for
readiness; stopping an already stopped instance makes no changes.

Status prints the validated EC2 state. When the instance is running, it also
prints container status and checks API readiness. During an EC2 transition,
wait and retry a start or stop command. Avoid concurrent deployments and
lifecycle operations; the local lifecycle lock covers commands on one machine.

After startup, check the public endpoints:

```bash
curl --fail --silent --show-error https://api.staging.morrowpal.com/ready
curl --fail --silent --show-error https://app.staging.morrowpal.com/ready
curl --fail --silent --show-error https://staging.morrowpal.com/ready
```

For a full read-only configuration preview and shared readiness checks:

```bash
shared/scripts/deploy-images.sh staging infrastructure --check
```
