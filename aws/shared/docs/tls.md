# TLS certificates and renewal

Run commands in Bash from `infrastructure/aws`. Select the environment explicitly:

```bash
ENVIRONMENT=staging
CONFIRMATION=()
case "$ENVIRONMENT" in
  staging) PUBLIC_DOMAIN=staging.morrowpal.com ;;
  prod) PUBLIC_DOMAIN=morrowpal.com; CONFIRMATION=(--confirm-production) ;;
  *) printf 'Select staging or prod.\n' >&2; exit 1 ;;
esac
INVENTORY="environments/$ENVIRONMENT/inventory.ini"
VARS="environments/$ENVIRONMENT/vars.yml"
CERTIFICATE_NAME="$PUBLIC_DOMAIN"
```

Production writes require completed staging validation, the final parity audit,
and explicit approval. Confirm `CERTIFICATE_NAME` matches
`morrowpal_tls_certificate_name` in the selected overlay. Start stopped staging
through its lifecycle wrapper before host checks; finish work before its nightly
1 AM America/Chicago shutdown.

## Certificate scope and architecture

Each environment has one Let's Encrypt certificate covering all six names in
its overlay's `morrowpal_domains`: apex, API, admin, app, www, and back. Every
name must resolve to that environment's dedicated stable IPv4. DNS is managed
manually at IONOS. Do not add AAAA records until the endpoint supports IPv6.

- Certbot runs on EC2 with the HTTP-01 standalone authenticator. The separate
  `http-validation-ingress` stack permits public TCP port 80 for issuance/renewal.
- Certificates, account files, and private keys live under `/etc/letsencrypt`
  on the encrypted root volume. Private key contents must not be printed,
  copied into Git, or transferred through this procedure.
- Envoy reads the certificate through supplementary group ID `1901`
  (`morrowpal-tls`). Docker maps host port 443 to Envoy port 8443.
- Filesystem SDS reloads renewed certificates without restarting Envoy. The
  host-loopback listener at `127.0.0.1:8080` remains the local readiness endpoint.
- API, app, and website routes use the selected overlay's names; www redirects
  to its apex. Reserved certificate names return HTTP 404, and unknown hosts 421.

The persistent renewal timer checks twice daily on the host's clock, with up to
one hour of randomized delay. Certbot renews only when needed. Its deploy hook
applies group read access and atomically replaces the watched symlinks. A stopped
staging host cannot renew certificates; allow it to run for renewal and check
expiry after a long shutdown. Do not assume a short testing session renewed it.

## Initial issuance or replay

For a fresh installation, follow the [shared installation guide](./install-from-scratch.md)
through DNS and HTTP ingress setup. For an existing installation, preview the
validated target before using direct Ansible commands:

```bash
shared/scripts/deploy-images.sh "$ENVIRONMENT" infrastructure \
  "${CONFIRMATION[@]}" --dry-run
```

The wrapper checks AWS identity, stack bindings, inventory/overlay, instance,
and Elastic IP. Direct Ansible below uses the explicit inventory and overlay
but does not independently repeat those AWS checks.

Replace the example email with the environment's certificate registration
address, then run:

```bash
ansible-playbook shared/playbooks/prepare-tls.yml \
  -i "$INVENTORY" -e "@$VARS" \
  -e morrowpal_certbot_email=admin@example.com
```

The playbook validates DNS, obtains the certificate when absent, installs the
permission hook, applies it to the current lineage, refreshes watched symlinks,
and enables renewal. Replaying it does not restart Envoy. A new root volume needs
certificate recovery or issuance; avoid repeated live issuance during testing.

For Envoy configuration changes, use the
[infrastructure update guide](./update-infrastructure.md). Initial application
startup uses the installation guide's guarded `initial` command.

## Verify certificate loading

Compare certificate metadata on the host, Envoy admin, and public endpoint:

```bash
ansible morrowpal_hosts -i "$INVENTORY" -e "@$VARS" -b -m command \
  -a "stat -Lc '%a %U:%G %n' /etc/letsencrypt/live/$CERTIFICATE_NAME/fullchain.pem /etc/letsencrypt/live/$CERTIFICATE_NAME/privkey.pem"
ansible morrowpal_hosts -i "$INVENTORY" -e "@$VARS" -b -m command \
  -a "openssl x509 -in /etc/letsencrypt/live/$CERTIFICATE_NAME/fullchain.pem -noout -serial -dates"
ansible morrowpal_hosts -i "$INVENTORY" -e "@$VARS" -b -m command \
  -a 'curl --fail --silent http://127.0.0.1:9901/certs'
openssl s_client -connect "$PUBLIC_DOMAIN:443" -servername "$PUBLIC_DOMAIN" \
  </dev/null 2>/dev/null | openssl x509 -noout -serial -dates
```

These commands inspect public certificate metadata and file permissions, not
private key contents. Followed certificate/key targets must be
`0640 root:morrowpal-tls`; serial numbers and expiration must agree.

If Envoy still serves the previous certificate, replay the TLS playbook and
repeat these checks. Check group read access before considering an Envoy
restart; unreadable certificate files can prevent the HTTPS listener starting.

## Test renewal and routes

```bash
ansible morrowpal_hosts -i "$INVENTORY" -e "@$VARS" -b -m command \
  -a 'certbot renew --dry-run --run-deploy-hooks'
ansible morrowpal_hosts -i "$INVENTORY" -e "@$VARS" -b -m command \
  -a 'systemctl is-enabled morrowpal-certbot-renew.timer'
ansible morrowpal_hosts -i "$INVENTORY" -e "@$VARS" -b -m command \
  -a 'systemctl is-active morrowpal-certbot-renew.timer'
ansible morrowpal_hosts -i "$INVENTORY" -e "@$VARS" -b -m command \
  -a 'docker logs --since 10m morrowpal-envoy-1'
curl --fail --silent --show-error "https://api.$PUBLIC_DOMAIN/ready"
curl --fail --silent --show-error "https://app.$PUBLIC_DOMAIN/ready"
curl --fail --silent --show-error "https://$PUBLIC_DOMAIN/ready"
curl --head "https://www.$PUBLIC_DOMAIN/"
```

The timer must report `enabled` and `active`. Inspect Envoy logs for certificate
reload/read failures, confirm the apex redirect, and repeat the certificate
metadata checks. Verify Envoy stayed available during the dry run. For a fresh
host, run these route/Envoy checks after initial deployment.
