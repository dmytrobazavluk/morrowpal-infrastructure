# MorrowPal Environment Contract

## Purpose

MorrowPal operates two application environments from one shared infrastructure
implementation:

- `prod` serves users.
- `staging` validates infrastructure changes, host preparation, application
  rollout, rollback, restart, and recovery before the same change reaches prod.

Staging matches prod structurally. It does not share prod data, credentials,
public endpoints, or external delivery destinations.

## Shared web app image

The Flutter web app is built once with its version and build number. Its API
URL and public Firebase client settings are provided at deployment through
`app/runtime-config.js`, mounted read-only outside the image. Flutter loads it
before startup and the Firebase messaging worker imports the same file. Both
consumers require valid deployment settings. Nginx serves the configuration and
worker with `Cache-Control: no-store`; the generated Flutter offline worker is
disabled.

`deploy.yml` reads `frontend/config/firebase/<environment>/{build,web}.json`
from the sibling frontend checkout, validates its API and project against the
selected overlay, and renders the runtime file. Set
`morrowpal_frontend_directory` if the checkout is elsewhere. Configuration
changes recreate the app container to refresh its file mount. Firebase
service-account credentials remain separate server-only runtime secrets.

`build-images.sh COMPONENT [APP_VERSION]` packages the selected component into
local Docker images.
`push-images.sh` uploads those images to the selected environment's ECR
repositories. Keep the tested local image for the production push, which
preserves its digest and tag across the environment repositories.

## Publishing build numbers

The local release builder reserves the selected component's next number under
[`build-numbers/`](build-numbers/README.md), shared by both environments.
Backend API and job images share one counter; app and website each have their
own. Initial counters were seeded from the highest existing production/staging
tags checked on 2026-11-09: backend 32, app 28 and website 13.

A component lock prevents concurrent builds from the same checkout;
different components can build concurrently. Other checkouts and workstations
must coordinate and use the latest committed counter. Commit reservations even
after failed builds. Each release build reserves its number before compilation.
Production push requires explicit confirmation and preserves the build's number
and image digest. The deployment command selects the version to run on the host.

## Initial placement decision

Both environments use AWS account `384078510608`, but use separate Regions and
the existing default network in each Region:

| Setting | Prod | Staging |
|---|---|---|
| AWS Region | `us-east-2` | `us-east-1` |
| Availability Zone | `us-east-2c` | `us-east-1a` |
| Default VPC | `vpc-07f1d3ea5b12e44b2` | `vpc-0d3057f78521c530d` |
| Default public subnet | `subnet-098ab1625c79adf3d` | `subnet-06f9d6d89b1c17eeb` |

Public DNS for `morrowpal.com` is hosted by IONOS on its `ui-dns` name servers.
AWS account `384078510608` has no Route 53 hosted zones. DNS records are managed
manually in IONOS and are outside the current CloudFormation implementation.

Using one account keeps the first staging implementation small. Regional
placement prevents staging from sharing production's VPC, subnet, route table,
or internet gateway. Further isolation is provided by distinct stacks, IAM
resources, security groups, instances, volumes, public addresses, repository
paths, secrets, topics, and DNS records. A separate staging account remains a
possible later improvement, not part of this refactor.

Each Region's default VPC and public subnet are external AWS platform
prerequisites. Both environments pass those externally managed network IDs to
the shared CloudFormation templates. The external IONOS zone is a shared DNS prerequisite and
also remains outside CloudFormation. The shared prerequisites template manages
each environment's dedicated host security group and imports only the public
half of its recovery key. Private key material remains local and untracked.

The production apex, `www`, `api`, `app`, `admin`, and `back` A records point
to production Elastic IP `3.12.65.199`. The user added the six configured staging
A records in IONOS, pointing to staging Elastic IP `98.95.17.0`. Checks on
2026-11-09 verified all four IONOS authoritative servers return that address
for every staging name, no staging AAAA answers, and unchanged production A
records. Every DNS change requires a separate human
review confirming that only staging names are affected and that no unexpected
AAAA record exists.

## Environment identities

| Setting | Prod | Staging |
|---|---|---|
| Environment value | `prod` | `staging` |
| Stack prefix | `morrowpal-prod` | `morrowpal-staging` |
| AWS Region | `us-east-2` | `us-east-1` |
| Availability Zone | `us-east-2c` | `us-east-1a` |
| ECR repository prefix | `morrowpal/prod` | `morrowpal/staging` |
| Secrets Manager prefix | `morrowpal/prod` | `morrowpal/staging` |
| EC2 Name tag | `morrowpal-prod-01` | `morrowpal-staging-01` |
| Initial instance type | `t3.small` | `t3.small` |
| Deployment root | `/opt/morrowpal` | `/opt/morrowpal` |
| MySQL data mount | `/var/lib/morrowpal` | `/var/lib/morrowpal` |
| Initial root EBS size | 8 GiB gp3 | 8 GiB gp3 |
| Initial MySQL EBS size | 10 GiB gp3 | 10 GiB gp3 |

Environment selection must be explicit in generic scripts and runbooks. A
generic command must never silently default to prod.

## Capacity policy

Topology parity is mandatory; permanent capacity parity is not. Prod and
staging may use different environment-specific values for:

- EC2 instance type
- root EBS capacity
- MySQL EBS capacity
- future replica, task, or host counts
- future throughput or IOPS settings

Staging must always remain large enough to run the complete production
topology and exercise the same rollout and recovery behavior. A documented
capacity difference is not configuration drift.

Before a capacity-related production change, staging temporarily uses the
candidate production setting when that is required to validate the change.
An EC2 instance type can normally be reduced again after the test. An EBS
volume cannot be shrunk in place, so an EBS expansion is tested either by
retaining the larger staging volume or by using a disposable test volume or
clean-room environment.

Load and performance tests may temporarily use a prod-sized staging capacity
profile. Routine functional and rollout testing uses the smaller staging
profile to control cost.

Capacity may differ, but the properties that determine behavior remain shared
unless the proposed production change explicitly changes them. These include
AMI selection, processor architecture, CPU-credit mode, metadata settings, EBS
volume type, encryption, attachment layout, and persistence policy.

## Public names

Prod retains its current names:

- `morrowpal.com`
- `www.morrowpal.com`
- `api.morrowpal.com`
- `app.morrowpal.com`
- `admin.morrowpal.com`
- `back.morrowpal.com`

Staging uses:

- `staging.morrowpal.com`
- `www.staging.morrowpal.com`
- `api.staging.morrowpal.com`
- `app.staging.morrowpal.com`
- `admin.staging.morrowpal.com`
- `back.staging.morrowpal.com`

Each environment has its own Elastic IP and TLS certificate lineage. All names
on an environment's certificate resolve only to that environment's public
address. Neither environment publishes AAAA records until its edge supports
IPv6. Unknown hostnames continue to receive HTTP 421. The `admin` and `back`
names remain reserved and return HTTP 404.

## Required structural parity

Prod and staging use the same implementation and equivalent configuration for:

- CloudFormation resource types and properties
- EC2 provisioning behavior and Amazon Linux AMI selection
- CPU credit mode and instance metadata settings
- encrypted root and retained MySQL EBS volume layout
- Elastic IP association
- IAM policy structure, scoped to the selected environment
- ECR immutability, scanning, encryption, and lifecycle rules
- all Docker Compose services and resource limits
- MySQL configuration and persistent mount
- both backend API slots
- dispatch and cleanup jobs
- Envoy listeners, routes, clusters, health checks, and rate limits
- systemd startup, shutdown, and certificate-renewal behavior
- Ansible host preparation and deployment tasks
- TLS issuance and renewal mechanism
- immutable image tagging and publication behavior
- blue-green rollout, health gates, traffic switching, and rollback
- smoke, reboot, stop/start, and host-replacement procedures

Intentional differences are limited to environment identity, isolation, safe
external integrations, and documented capacity settings.

## Isolation boundaries

Staging owns distinct versions of every application resource:

- CloudFormation stacks
- EC2 instance and instance profile
- security group and recovery key pair
- root and MySQL EBS volumes
- Elastic IP
- ECR repositories
- Secrets Manager secrets
- SNS topic and subscriptions
- logically separate IONOS DNS records and TLS certificate
- MySQL database contents
- Ansible inventory and SSH host-key record

IAM policies reference only the selected environment's ECR repositories,
secrets, and SNS topic. Staging must never receive permission to read prod
secrets or publish to the prod alert topic.

Prod database contents are not copied into staging. Staging uses synthetic test
data. Any future production-derived dataset requires a separately reviewed
sanitization process.

## External service safety

The current application delivery providers are:

- Postmark for verification-code and dispatch-notification email
- Firebase Cloud Messaging for app push notifications

Prod and staging share one Postmark account and its monthly message allowance.
They use separate live Postmark servers:

- `MorrowPal Production`
- `MorrowPal Staging`

Each server has its own Server API token, message activity, and statistics.
Staging uses separate sender identities and the same transactional `outbound`
message stream name as prod so application behavior remains equivalent.

The staging server uses staging-specific sender identities:

- `verification-code@staging.morrowpal.com`
- `notifications@staging.morrowpal.com`

Its Server API token is stored only in the
`morrowpal/staging/postmark` Secrets Manager secret. The staging EC2 role can
read that secret and cannot read `morrowpal/prod/postmark`. The prod role has
the inverse restriction. Token values are resolved only at service startup
through `asm-exec`.

Staging email remains enabled and does not add an application-level recipient
restriction. Staging data and accounts must therefore use controlled test
addresses. Isolation from production is provided by the dedicated Postmark
server, Server API token, sender identities, and environment-specific secret.

AWS SNS is an environment-specific AWS integration for internal system alerts.
It is not a third-party provider, but its topic, IAM permissions, and
subscribers must remain isolated between environments.

The infrastructure also depends operationally on Let's Encrypt for TLS
certificates and public container registries for the pinned MySQL and Envoy
images. These dependencies do not use the application's Postmark or Firebase
credentials, but staging must still test certificate issuance and image pulls.

Google Play and Apple App Store URLs are client update destinations. The
backend does not currently authenticate to either store or call a store API.

Staging email uses the dedicated live Postmark server described above. Push
delivery is disabled or backed by staging-only Firebase credentials until its
separate project is approved. Staging must not use the prod Postmark token,
Firebase service account, sender identities, store-review account, or alert
subscribers.

Enabling a real external provider in staging requires a separate review that
confirms:

- distinct staging credentials
- non-user recipient restrictions
- staging-specific sender or project identity
- a safe alert destination
- no path to production customer delivery

The application topology remains identical while a provider is stubbed. Tests
that specifically cover a real provider are enabled only after those controls
exist.

## Shared source and environment overlays

The target repository structure has one shared implementation and two small
non-secret overlays:

```text
infrastructure/
├── shared/
│   ├── cloudformation/
│   ├── playbooks/
│   ├── scripts/
│   ├── runtime/
│   └── docker-compose.yml
├── environments/
│   ├── prod/
│   │   ├── inventory.ini
│   │   ├── vars.yml
│   │   └── known_hosts
│   └── staging/
│       ├── inventory.ini
│       ├── vars.yml
│       └── known_hosts
└── ansible.cfg
```

Environment variable files contain non-secret values and secret identifiers
only. Secret values remain in Secrets Manager and are resolved at service
startup with `asm-exec`.

Separate copies of templates, playbooks, Compose files, or rollout scripts are
not allowed. This prevents staging and prod behavior from drifting.

## CloudFormation change rules

- Existing prod logical IDs remain unchanged during parameterization.
- A refactor change must not replace a prod resource unless replacement is the
  explicit purpose of a separately reviewed test and rollout.
- Every stack update uses a change set.
- Local linting and rendering happen before an AWS change set is created.
- The production change set is reviewed for every resource action and
  replacement flag before execution.
- Stateful resources retain explicit `DeletionPolicy: Retain` and
  `UpdateReplacePolicy: Retain` behavior.
- Secret values are never accepted as plain CloudFormation parameters.
- Resource names, descriptions, and tags use the selected environment and do
  not contain copied prod wording in staging.

## Staging lifecycle

Staging resources remain provisioned so they preserve deployment history,
database state, public identity, and realistic update behavior. Its EC2
instance is stopped when staging is not in use.

A normal staging session is:

1. Start the staging instance explicitly.
2. Wait for systemd, MySQL, and every container to become healthy.
3. Apply and review the proposed infrastructure change.
4. Publish the proposed immutable application revision.
5. Exercise rollout, smoke tests, and rollback where applicable.
6. Record the tested revision and result.
7. Gracefully stop the staging instance.

Stopping EC2 does not delete its EBS volumes, Elastic IP, secrets, repositories,
manually managed IONOS DNS records, or other persistent resources.

## Promotion rule

A production infrastructure or rollout change is eligible for promotion only
after the same shared templates, scripts, and immutable application revision
have passed in staging. Differences in resolved output must be limited to the
documented environment-specific values in this contract.

Production remains the topology reference until the shared implementation has
completed its first staging parity audit and controlled production rollout.
