# Update the Website

Run commands from `infrastructure`.

Production operations below are deferred until staging validation and the final
parity audit are complete and production work is explicitly approved.
Select the deployment target with the matching Ansible inventory and
environment variable file.

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
web runtime settings, including for a website-only deployment. Set
`morrowpal_frontend_directory` if that checkout is elsewhere.

The dispatch email confirmation page also requires the API Compose setting to
allow `https://morrowpal.com` as a CORS origin. Deploy the accompanying Compose
change before enabling emails that link to this page.

## 2. Build locally, push to staging, and test

The builder hashes the deployable website files and creates a local Linux AMD64
Nginx image with a `build-N-SOURCESHA` tag. It exports `WEBSITE_TAG` when sourced.

```bash
source shared/scripts/build-images.sh website
shared/scripts/push-images.sh staging website "$WEBSITE_TAG"
```

The build command reserves the next number in `build-numbers/website` and
creates local images. Commit that counter even if building fails. The push
command uploads the images to staging's ECR repositories, verifies their digests
and waits for vulnerability scans. Critical/high findings fail this step.
See [build number coordination](../../build-numbers/README.md).

Deploy and test in staging:

```bash
ansible-playbook shared/playbooks/deploy.yml \
  -i environments/staging/inventory.ini \
  -e @environments/staging/vars.yml \
  -e "morrowpal_website_image_tag=$WEBSITE_TAG"
```

After staging validation, the final parity audit, and explicit production
approval, push the same local image to production:

```bash
shared/scripts/push-images.sh prod website "$WEBSITE_TAG" --confirm-production
```

Keep the tested local release image until promotion. The production push
preserves the tag and verifies the digest against the staging push.
`WEBSITE_TAG` identifies the website build. Proceed with deployment below
after the push succeeds and deployment is approved.

Registry-to-registry recovery for missing local images is planned in Step 54a.1.
If the local release images are missing, stop until they can be recovered from
staging with their verified digests.

## 3. Preview the production deployment (after approval and promotion)

```bash
ansible-playbook shared/playbooks/deploy.yml \
  -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml \
  --check \
  --diff \
  -e "morrowpal_website_image_tag=$WEBSITE_TAG"
```

The first website deployment also installs the service definition and changes
the Envoy routes. Recreating the single Envoy container can cause a brief edge
interruption. Later website-only releases replace only the website container.

## 4. Deploy to production

```bash
ansible-playbook shared/playbooks/deploy.yml \
  -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml \
  -e "morrowpal_website_image_tag=$WEBSITE_TAG"
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

Deploy a previously retained website tag:

```bash
PREVIOUS_WEBSITE_TAG='build-N-SOURCESHA'

ansible-playbook shared/playbooks/deploy.yml \
  -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml \
  -e "morrowpal_website_image_tag=$PREVIOUS_WEBSITE_TAG"
```

The ECR lifecycle policy retains the five most recent `build-*` images by
default.
