# Production TLS

This document describes the replayable TLS configuration for the production
Envoy edge proxy. Run commands from `infrastructure/prod`.

## Certificate Scope

One Let's Encrypt certificate contains these explicit DNS names:

- `morrowpal.com`
- `api.morrowpal.com`
- `admin.morrowpal.com`
- `app.morrowpal.com`
- `www.morrowpal.com`
- `back.morrowpal.com`

Every name must resolve to the stable production IPv4 address `3.12.65.199`.
None of these names may have an AAAA record until the production endpoint
supports IPv6.

## Architecture

- Certbot runs on the EC2 host and uses the HTTP-01 standalone authenticator.
- CloudFormation permits public TCP port 80 for initial validation and renewal.
- Certbot stores its account, certificate, and private key under
  `/etc/letsencrypt` on the encrypted EC2 root volume.
- Envoy receives read-only access to the certificate through a dedicated
  supplementary group. Private keys are never stored in this repository.
- Docker maps public host port 443 to unprivileged Envoy container port 8443.
- Envoy obtains the certificate through filesystem SDS and reloads renewed
  files without a container restart.
- The existing host-loopback listener at `127.0.0.1:8080` remains the local
  readiness endpoint.
- `api.morrowpal.com` routes to the backend API, `app.morrowpal.com` routes to
  the Flutter web app container, `morrowpal.com` routes to the landing page,
  and `www.morrowpal.com` redirects to the apex name. Reserved certificate
  names return HTTP 404 until their applications are configured, and unknown
  hostnames return HTTP 421.

## Replay and Renewal

`playbooks/prepare-tls.yml` installs Certbot, validates DNS, obtains the initial
certificate when absent, applies least-privilege file permissions, and enables
the `morrowpal-certbot-renew.timer` systemd timer. Running the playbook again is
idempotent.

The timer checks for renewal twice daily with a randomized delay. Certbot only
renews when the certificate reaches its renewal window. A deploy hook grants
the dedicated Envoy TLS group read access to the renewed certificate chain and
private key, then atomically replaces the watched symlinks. Envoy filesystem
SDS loads the replacement certificate without restarting.

## Recover a Renewed Certificate That Envoy Did Not Load

If Certbot has a valid renewed certificate on the host but Envoy still serves
the previous certificate, deploy the current permission hook by replaying the
TLS playbook:

```bash
cd infrastructure/prod
ansible-playbook ./playbooks/prepare-tls.yml \
  -e morrowpal_certbot_email=admin@example.com
```

The playbook installs the hook, applies it to the current certificate lineage,
and re-creates the watched certificate symlinks. It does not restart Envoy.
Replace the example address with the existing Let's Encrypt registration
address.

Confirm that the host, Envoy, and public endpoint all report the same current
certificate serial number and expiration time:

```bash
ansible 01 -b -m shell -a \
  'stat -Lc "%a %U:%G %n" /etc/letsencrypt/live/morrowpal.com/fullchain.pem /etc/letsencrypt/live/morrowpal.com/privkey.pem'

ansible 01 -b -m shell -a \
  'openssl x509 -in /etc/letsencrypt/live/morrowpal.com/fullchain.pem -noout -serial -dates'

ansible 01 -b -m shell -a \
  'curl --fail --silent http://127.0.0.1:9901/certs'

openssl s_client -connect morrowpal.com:443 -servername morrowpal.com \
  </dev/null 2>/dev/null \
  | openssl x509 -noout -serial -dates
```

Finally, exercise a simulated renewal and run the same serial-number checks
again:

```bash
ansible 01 -b -m command -a \
  'certbot renew --dry-run --run-deploy-hooks'

ansible 01 -b -m shell -a \
  'systemctl is-enabled morrowpal-certbot-renew.timer && systemctl is-active morrowpal-certbot-renew.timer'

ansible 01 -b -m shell -a \
  'docker logs --since 10m morrowpal-envoy-1 2>&1 | grep -Ei "failed to reload certificates|unable to read file" || true'
```

The followed certificate targets must be `0640 root:morrowpal-tls`, the timer
commands must print `enabled` and `active`, and the Envoy warning search must
produce no output. Repeat the host, Envoy admin, and public serial-number checks
after the dry run.

Do not restart Envoy as a workaround. First ensure the renewed certificate
chain and private key are readable by group ID `1901`; otherwise a restart can
make the HTTPS listener unavailable.

If the EC2 root volume is replaced, rerunning the playbook obtains a new
certificate. Avoid repeated live issuance during testing because the
certificate authority enforces rate limits.

## Rollout Sequence

1. Wait until all six public DNS names pass the IPv4 and IPv6 preflight.
2. Validate and deploy `cloudformation/http-validation-ingress.yml` through a
   reviewed CloudFormation change set.
3. Run `playbooks/prepare-tls.yml` with the Certbot registration email.
4. Validate the exact Envoy configuration using the pinned container image.
5. Run `playbooks/deploy.yml` to enable public HTTPS.
6. Verify the certificate names, API and website readiness, the website
   redirect, reserved hostname behavior, container health, and local readiness.
7. Run `certbot renew --dry-run --run-deploy-hooks`, confirm Envoy stays
   available, and verify that Envoy serves the same certificate serial number
   as the host certificate.

CloudFormation change sets are reviewed before execution. The TLS deployment
does not retrieve, print, or transfer the certificate private key.
