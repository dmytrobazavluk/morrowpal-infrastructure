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
renews when the certificate reaches its renewal window. A deploy hook reapplies
the private-key permissions after successful renewal; Envoy filesystem SDS
then loads the replacement certificate without restarting.

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
7. Run `certbot renew --dry-run` and confirm Envoy stays available.

CloudFormation change sets are reviewed before execution. The TLS deployment
does not retrieve, print, or transfer the certificate private key.
