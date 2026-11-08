# Infrastructure

Infrastructure configuration and operational documentation are separated by
environment:

- [Development](./dev/README.md) contains the local Docker Compose stack,
  service layout, scaling, logs, and health checks.
- [Production](./prod/README.md) contains installation, deployment, TLS,
  host operations, and administration procedures.

Choose the environment before running commands. Development commands operate
only on the local Compose stack; production commands target AWS and the
production EC2 host.

## AWS environment overlays

Production and staging non-secret values live under `environments/`. Select an
inventory explicitly from the repository root; the root `ansible.cfg` does not
default to an environment:

```bash
ansible-inventory -i environments/prod/inventory.ini --list
ansible-inventory -i environments/staging/inventory.ini --list
```

Pass the matching variable overlay when a playbook has been updated to consume
environment variables:

```bash
ansible-playbook \
  -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml \
  PLAYBOOK
```

Private SSH keys remain outside this repository. Staging inventory and public
IP values intentionally remain placeholders until the staging host exists.
