# Installation prerequisites

Use this checklist before installing a new environment. Existing production
uses the update procedures; do not recreate its stacks, network, or provider
identities. Production writes require completed staging validation, the final
parity audit, and explicit approval.

Run local commands from `infrastructure`. Select the environment explicitly:

```bash
ENVIRONMENT=staging
case "$ENVIRONMENT" in
  staging|prod) ;;
  *) printf 'Select staging or prod.\n' >&2; exit 1 ;;
esac
```

Read the corresponding environment checklist:

- [Staging prerequisites](../../environments/staging/installation-prerequisites.md)
- [Production prerequisites](../../prod/docs/installation-prerequisites.md)

## Local tools and configuration

Have AWS CLI, Ansible, cfn-lint, Docker with Compose, jq, Bash, and the sibling
backend, frontend, and website source directories available. Building the app
also requires Flutter and Dart; backend builds use the Gradle wrapper and its
required Java toolchain. Release images target Linux AMD64.

`environments/ENVIRONMENT/vars.yml` defines the account, Region, Availability
Zone, network, capacity, resource names, provider identities, and domains.
`inventory.ini` in that directory defines SSH access. Keep both files consistent;
the guarded wrappers reject conflicting bindings. Private keys stay outside Git.

Before creating stacks, identify the existing VPC and internet-connected public
subnet in the selected account, Region, and Availability Zone. These resources
are prerequisites, not resources created by the shared templates. Do not assume
a default VPC or subnet exists in a new account or Region.

For a new environment, `prerequisites.yml` creates a dedicated security group
and imports the public half of its recovery SSH key. The change-set wrapper's
`prerequisites` kind requires a public-key file and reviewed SSH ingress CIDR.
After creation, copy its output bindings into the overlay before creating the
other stacks. An existing production security group and key must not be
recreated or imported as part of routine installation documentation changes.

Validate local configuration without contacting the hosts:

```bash
scripts/validate-environments.sh
bash shared/scripts/validate-local.sh
```

Use AWS credentials for the account in the selected overlay. Every AWS command
must specify its configured Region; generic commands must not assume production.
Use the guarded change-set wrapper to resolve cross-stack bindings, then review
each change set before explicit execution. A fresh installation requires CREATE
operations; stop if an existing environment or retained resource needs recovery.

## Provider and DNS preparation

Use the environment checklist for Postmark, Firebase, SNS recipients, public
frontend configuration, DNS, and certificate registration. Both environments
use live email and app notifications. Staging must use its own provider identity
and Firebase project while sharing the Postmark account allowance.

The runtime-secrets template defines six secrets. It generates MySQL and JWT
values, a Postmark placeholder, and a store-review code; the Firebase service
account secret needs its JSON value supplied separately. Populate provider
values using the human-operated AWS console workflow for the selected secret
path and Region. Never put values in this checklist, shell arguments, Git,
Ansible variables, or logs. Runtime resolution uses dynamic references through
`asm-exec`; do not retrieve secret values with CLI or agent tools.

## Installation sequence status

The shared resource/host installation procedure is the next documentation step.
The [old production installation page](../../prod/docs/install-from-scratch.md)
is reference material until that procedure is complete.

The routine `deploy-images.sh` command accepts one component tag per invocation.
A fresh host requires all three component tags together. A supported initial
publication/deployment path must be implemented and tested before documenting
the final bootstrap command. Do not attempt the initial installation by running
three routine component deployments against a host without recorded tags.
