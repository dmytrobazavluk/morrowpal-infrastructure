# Update the Website

Run commands from `infrastructure/prod`.

The production landing-page container is defined in `../website`. The publisher
supplies the sibling `www` directory as a named Docker build context and copies
only the deployable HTML, CSS, crawler files, and assets into the image. The
Flutter app image remains separate.

## 1. Preconditions

Review the landing page locally, then confirm AWS identity and host
connectivity:

```bash
python3 -m http.server 4173 --directory ../../www
aws sts get-caller-identity
ansible production -m ping
```

The AWS account must be `384078510608`.

## 2. Publish the Website Image

Choose a positive build number greater than the latest published website build:

```bash
./scripts/publish-website-image.sh BUILD_NUMBER
```

For example:

```bash
./scripts/publish-website-image.sh 1
```

The publisher computes a stable seven-character digest from the deployable
website files, builds the pinned non-root Nginx image for Linux AMD64, pushes an
immutable `build-N-SOURCESHA` tag to `morrowpal/prod/website`, waits for the ECR
vulnerability scan, and rejects critical or high findings.

Assign the exact published tag to a shell variable:

```bash
WEBSITE_TAG='build-N-SOURCESHA'
```

## 3. Preview the Deployment

```bash
ansible-playbook ./playbooks/deploy.yml \
  --check \
  --diff \
  -e "morrowpal_website_image_tag=$WEBSITE_TAG"
```

The first website deployment also installs the service definition and changes
the Envoy routes. Recreating the single Envoy container can cause a brief edge
interruption. Later website-only releases replace only the website container.

## 4. Deploy

```bash
ansible-playbook ./playbooks/deploy.yml \
  -e "morrowpal_website_image_tag=$WEBSITE_TAG"
```

The website deployment waits for both the container health check and the public
Envoy route. If either fails during a later release, it restores the previously
recorded website tag.

## 5. Verify

```bash
ansible 01 -b -m command -a '/usr/local/sbin/morrowpal-service status'
curl --fail --show-error --silent https://morrowpal.com/ready
curl --head https://morrowpal.com/
curl --head https://morrowpal.com/robots.txt
curl --head https://morrowpal.com/sitemap.xml
curl --head https://www.morrowpal.com/
```

Confirm that the apex site returns HTTP 200 and that `www` returns HTTP 301 with
`Location: https://morrowpal.com/`. Open the landing page in desktop and mobile
browsers and verify both store links.

## Rollback

Deploy a previously retained website tag:

```bash
PREVIOUS_WEBSITE_TAG='build-N-SOURCESHA'

ansible-playbook ./playbooks/deploy.yml \
  -e "morrowpal_website_image_tag=$PREVIOUS_WEBSITE_TAG"
```

The ECR lifecycle policy retains the five most recent `build-*` images by
default.
