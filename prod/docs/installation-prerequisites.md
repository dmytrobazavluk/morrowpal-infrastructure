# Production installation prerequisites

Start with the [shared prerequisites](../../shared/docs/installation-prerequisites.md).
Production already exists. Use its update procedures or the
[host-replacement planning checklist](../../shared/docs/replace-host.md) for that environment;
this checklist does not authorize recreation or provider changes.

- Account: `384078510608`; Region: `us-east-2`; Availability Zone: `us-east-2c`.
- Stack prefix: `morrowpal-prod`; resource paths: `morrowpal/prod`.
- Inventory and overlay: `environments/prod/inventory.ini` and `vars.yml`.
- Existing security group: `sg-0103b42f143676fda`; subnet:
  `subnet-098ab1625c79adf3d`; recovery key pair: `01`.
- SSH private key: `../morrowpal-prod-01.pem` from `infrastructure`.
- Stable IPv4: `3.12.65.199`. Preserve the production Elastic IP and retained
  database volume during host replacement.

The existing VPC/subnet, security group, and recovery key are not created by the
staging prerequisites stack. Verify current overlay bindings before planning
any production operation; do not run a new prerequisites stack over them.

Provider setup stays in the production-specific guides:

- [Postmark](./postmark.md): production server, sending identities, stream,
  delivery checks, and token setup in `morrowpal/prod/postmark`.
- [Firebase](./firebase-app-notifications.md): project `morrowpal`, dedicated
  notification service account, and `morrowpal/prod/firebase-service-account`.
- [System alerts](./system-alerts.md): `morrowpal-prod-system-alerts` and explicitly
  selected, confirmed recipients.

Those guides describe production provider configuration. Commands in them
require review for the current inventory/overlay conventions before use.
Public frontend configuration belongs in `frontend/config/firebase/prod/` in
the sibling frontend repository. Do not replace provider values or rotate
credentials merely to follow this checklist.

IONOS serves public DNS for `morrowpal.com`. Its apex, `www`, `api`, `app`,
`admin`, and `back` records must retain production's stable IPv4. There is no
Route 53 hosted zone managed by this repository. Keep staging records isolated.
See the [shared TLS guide](../../shared/docs/tls.md) for certificate names and
renewal with explicit inventory and overlay arguments.
