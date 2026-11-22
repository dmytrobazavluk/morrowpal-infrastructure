# AWS infrastructure

Staging and production share CloudFormation templates, runtime configuration,
playbooks and guarded deployment scripts. Environment-specific values live in
`environments/<environment>/vars.yml`; SSH access uses the matching inventory.

- [Staging operations](./environments/staging/README.md)
- [Production operations](./environments/prod/README.md)
- [Environment contract](./ENVIRONMENTS.md)
- [Installation prerequisites](./shared/docs/installation-prerequisites.md)
- [Release build numbers](./build-numbers/README.md)

Run commands in Bash from `infrastructure/aws`. Select an inventory explicitly;
the local `ansible.cfg` does not select an environment:

```bash
ansible-inventory -i environments/staging/inventory.ini --list
ansible-inventory -i environments/prod/inventory.ini --list
```

For direct playbook commands, pass the matching overlay:

```bash
ansible-playbook \
  -i environments/staging/inventory.ini \
  -e @environments/staging/vars.yml \
  PLAYBOOK
```

For deployment, use `shared/scripts/deploy-images.sh` with an explicit environment
and follow its environment's operating guide. Private keys stay outside the
infrastructure repository; their configured paths are relative to this directory.
