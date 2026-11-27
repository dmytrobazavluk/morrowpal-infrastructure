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

Integration exchange/API audiences are nonsecret runtime identifiers rendered in
`shared/runtime/compose.env.j2`: `urn:morrowpal:<environment>:integration-exchange`
and `urn:morrowpal:<environment>:api`, using `staging` or `prod`. API Compose
forwards these with empty fallbacks for older rendered runtime files, which keep
integration exchange unavailable. The maximum token lifetime defaults to 900
seconds and the exchange quota to 60 requests per minute per API instance. Public
keys and explicit grants must be provisioned separately in the backend registry;
rendering audiences does not register or enable a key. Roll out backend support to
all serving instances before allowing restricted integration access.
