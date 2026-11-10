# Update the Website

Run commands from `infrastructure`.

Production operations below are deferred until staging validation and the final
parity audit are complete and production work is explicitly approved.
The deployment command selects and validates the matching inventory and
configuration for the requested environment.

The landing-page container is defined in `shared/runtime/website`. The builder
supplies the sibling `www` directory as a named Docker build context and copies
only the deployable HTML, CSS, crawler files, JavaScript, and assets into the
image. The Flutter app image remains separate.

## 1. Preconditions

Review the landing page locally, then confirm AWS identity and host
connectivity:

```bash
python3 -m http.server 4173 --directory ../www
```

In another terminal, also from `infrastructure`:

```bash
aws sts get-caller-identity
ansible morrowpal_hosts -i environments/staging/inventory.ini \
  -e @environments/staging/vars.yml -m ping
```

The AWS account must be `384078510608`.

The shared deploy playbook requires the sibling frontend checkout to read public
web runtime settings, including for a website-only deployment. Use
`--frontend-directory PATH` if that checkout is elsewhere.

The dispatch email confirmation page also requires the API Compose setting to
allow `https://morrowpal.com` as a CORS origin. Deploy the accompanying Compose
change before enabling emails that link to this page.

## 2. Build and deploy to staging

The builder hashes the deployable website files and creates a local Linux AMD64
Nginx image with a `build-N-SOURCESHA` tag. It exports `WEBSITE_TAG` when sourced.

```bash
source shared/scripts/build-images.sh website
shared/scripts/deploy-images.sh staging website "$WEBSITE_TAG" --dry-run
```

The build reserves the component's next number. Commit its counter file even if
building fails. The dry run validates the AWS account, Region, stack outputs,
instance identity, Elastic IP, inventory, overlay, and available image sources.
It prints the deployment plan using read-only AWS calls.

Deploy and test in staging:

```bash
shared/scripts/deploy-images.sh staging website "$WEBSITE_TAG"
```

The command publishes the local release images, verifies digests and scans, then
runs the shared Ansible playbook with the validated inventory and configuration.
Critical/high findings stop the deployment before any host action. Published
images with the requested immutable tag support retries and rollback. The
playbook checks container and public readiness before completing.

Keep tested local images for the first production publication. Production work
starts after staging validation, the final parity audit and explicit approval.
The production deployment preserves the selected tag and image digest.

## 3. Preview the approved production deployment

```bash
shared/scripts/deploy-images.sh prod website "$WEBSITE_TAG" --confirm-production --dry-run
```

The first website deployment also installs the service definition and changes
the Envoy routes. Recreating the single Envoy container can cause a brief edge
interruption. Later website-only releases replace only the website container.

## 4. Deploy to production

```bash
shared/scripts/deploy-images.sh prod website "$WEBSITE_TAG" --confirm-production
```

The website deployment waits for both the container health check and the public
Envoy route. If either fails during a later release, it restores the previously
recorded website tag.

## 5. Verify production

```bash
ansible morrowpal_hosts -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml -b -m command \
  -a '/usr/local/sbin/morrowpal-service status'
curl --fail --show-error --silent https://morrowpal.com/ready
curl --head https://morrowpal.com/
curl --head https://morrowpal.com/privacy/
curl --head https://morrowpal.com/child-safety/
curl --head https://morrowpal.com/notifications/disable/
curl --head https://morrowpal.com/robots.txt
curl --head https://morrowpal.com/sitemap.xml
curl --head https://www.morrowpal.com/
```

Confirm that the apex site returns HTTP 200 and that `www` returns HTTP 301 with
`Location: https://morrowpal.com/`. Open the landing page in desktop and mobile
browsers and verify both store links.

## Production rollback

Select a retained website tag in production ECR. Deploy it with:

```bash
PREVIOUS_WEBSITE_TAG='build-N-SOURCESHA'

shared/scripts/deploy-images.sh prod website "$PREVIOUS_WEBSITE_TAG" --confirm-production
```

The ECR lifecycle policy retains the five most recent `build-*` images by
default.
