# Infrastructure

Infrastructure configuration and operational documentation are separated by
environment:

- [Development](./dev/README.md) contains the local Docker Compose stack,
  service layout, scaling, logs, and health checks.
- [Production](./environments/prod/README.md) contains installation, deployment, TLS,
  host operations, and administration procedures.
- [Staging](./environments/staging/README.md) contains test-environment operations,
  lifecycle controls, and release verification procedures.

Choose the environment before running commands. Development commands operate
only on the local Compose stack; staging and production commands target their
selected AWS environment.

## AWS environment overlays

Production and staging non-secret values live under `environments/`. Select an
inventory explicitly from the repository root; the root `ansible.cfg` does not
default to an environment:

```bash
ansible-inventory -i environments/prod/inventory.ini --list
ansible-inventory -i environments/staging/inventory.ini --list
```

Pass the matching variable overlay for direct playbook commands:

```bash
ansible-playbook \
  -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml \
  PLAYBOOK
```

For deployments, use the guarded `shared/scripts/deploy-images.sh` wrapper with
an explicit environment, as documented in the environment's operations guide.
Private SSH keys remain outside this repository.
