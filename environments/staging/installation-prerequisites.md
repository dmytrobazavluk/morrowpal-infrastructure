# Staging installation prerequisites

Start with the [shared prerequisites](../../shared/docs/installation-prerequisites.md).
The current staging environment already exists; these values describe its
bindings, not instructions to recreate resources.

- Account: `384078510608`; Region: `us-east-1`; Availability Zone: `us-east-1a`.
- Stack prefix: `morrowpal-staging`; resource paths: `morrowpal/staging`.
- Inventory and overlay: `environments/staging/inventory.ini` and `vars.yml`.
- Network, security group, and recovery key: use the IDs and names in the
  overlay and verify them against their stack outputs. The prerequisites stack
  owns the staging security group and imported public key; the VPC/subnet exist
  outside that stack.
- SSH private key: `../morrowpal-staging-01.pem` from `infrastructure`.
- Stable IP: use the staging public-IP stack output and update the inventory,
  public IPv4, and TLS expected IPv4 together if it changes.

## Live providers

Postmark uses the shared account with the dedicated **MorrowPal Staging** server
and its own Server API Token in `morrowpal/staging/postmark` (`serverToken`).
Use the overlay's staging sender addresses and `outbound` stream. Verify the
staging sender domain or signatures in Postmark and keep its opt-out link on
`https://staging.morrowpal.com/notifications/disable/`. Do not use the production
server token. The [Postmark guide](../../prod/docs/postmark.md) describes provider
concepts; its production commands and identities are not staging instructions.

Firebase project: **morrowpal-staging**. Use a dedicated service account with
FCM message-sending permission in this project. Its complete JSON goes into
`morrowpal/staging/firebase-service-account` as the raw secret string through the
human-operated AWS console workflow. Do not paste it into terminal commands.
Public frontend settings belong in the sibling frontend repository under
`config/firebase/staging/`; verify the web and native app registrations match
this project. The shared deployment reads `build.json` and `web.json` there.

Use `morrowpal-staging-system-alerts` for SNS and confirm every recipient's
subscription. Choose recipients explicitly; do not infer them from production.
Use only staging test accounts and the staging store-review secret.

## DNS, certificates, and cost controls

Public DNS is managed manually at IONOS. Point `staging.morrowpal.com` and its
`www`, `api`, `app`, `admin`, and `back` names to staging's dedicated Elastic IP.
These are DNS records in the existing domain, not a Route 53 hosted zone.
All certificate names must resolve to the staging IPv4; omit AAAA records until
IPv6 is supported. Choose a certificate registration email explicitly.

Keep the staging budget and nightly 1 AM America/Chicago shutdown described in
the [staging operations guide](./README.md). Start staging manually for testing.
Storage, Elastic IP, secrets, and retained images remain allocated while stopped.
