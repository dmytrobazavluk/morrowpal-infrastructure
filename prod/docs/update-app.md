# Update the App

Run commands from `infrastructure`.

Production operations below are deferred until staging validation and the final
parity audit are complete and production work is explicitly approved.
The deployment command selects and validates the matching inventory and
configuration for the requested environment.

The app image definition is in `shared/runtime/app/Dockerfile`, and its
environment-specific Nginx configuration is rendered from
`shared/runtime/app/nginx.conf.j2` onto the host. Public API and Firebase settings
are supplied separately through the read-only `app/runtime-config.js` mount.
The deployment requires the sibling frontend checkout for its canonical public
configuration; use `--frontend-directory PATH` if necessary.
The builder builds the sibling `frontend` repository and supplies only
`frontend/build/web` to the container build.

## 1. Preconditions

Confirm the app source worktree is clean because the builder refuses dirty
source:

```bash
git -C ../frontend status --short
```

Confirm AWS identity and host connectivity:

```bash
aws sts get-caller-identity
ansible morrowpal_hosts -i environments/staging/inventory.ini \
  -e @environments/staging/vars.yml -m ping
```

The AWS account must be `384078510608`.

The current Flutter test suite has known widget-test failures. The build
script builds the shared web app but does not run that failing suite. Make
the release decision explicitly rather than assuming the release is test-gated.

## 2. Build and deploy to staging

Choose the semantic app version (`1.1.0` in this example). The builder compiles
environment-independent Flutter web, creates a local Linux AMD64 Nginx image,
and exports `APP_TAG` when sourced. The reserved number also becomes Flutter's
build number. Deployment supplies the API and public Firebase settings.

```bash
source shared/scripts/build-images.sh app 1.1.0
shared/scripts/deploy-images.sh staging app "$APP_TAG" --dry-run
```

The build reserves the component's next number. Commit its counter file even if
building fails. The dry run validates the AWS account, Region, stack outputs,
instance identity, Elastic IP, inventory, overlay, and available image sources.
It prints the deployment plan using read-only AWS calls.

Deploy and test in staging:

```bash
shared/scripts/deploy-images.sh staging app "$APP_TAG"
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
shared/scripts/deploy-images.sh prod app "$APP_TAG" --confirm-production --dry-run
```

Non-API infrastructure changes are reconciled in place. An app-only tag change
replaces only the app container, and the backend release task is skipped. If
the Compose file changed, both API slots are rolled one at a time so API
configuration changes cannot recreate them together. An Envoy configuration
change recreates the single Envoy container and can cause a brief edge
interruption. An app Nginx configuration change recreates the app container so
the new read-only host configuration is loaded. Runtime configuration changes
also recreate the app container to refresh its file mount.

## 4. Deploy to production

```bash
shared/scripts/deploy-images.sh prod app "$APP_TAG" --confirm-production
```

The app deployment waits for both the container health check and the public
Envoy route. If either fails, it restores the previously recorded app tag.

## 5. Verify production

```bash
ansible morrowpal_hosts -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml -b -m command \
  -a '/usr/local/sbin/morrowpal-service status'
curl --fail --show-error --silent https://app.morrowpal.com/ready
curl --head https://app.morrowpal.com/
curl --head https://app.morrowpal.com/nonexistent/client/route
```

The client route should return HTTP 200 with `Content-Type: text/html`.

Verify browser CORS:

```bash
curl --include \
  --request OPTIONS \
  --header 'Origin: https://app.morrowpal.com' \
  --header 'Access-Control-Request-Method: GET' \
  --header 'Access-Control-Request-Headers: Authorization' \
  https://api.morrowpal.com/accounts/current/profile
```

Look for:

```text
Access-Control-Allow-Origin: https://app.morrowpal.com
```

Finally, test initial loading, sign-in, an API-backed action, refresh, local
SQLite persistence, and sign-out in a private browser window.

## Production rollback

Select a retained app tag in production ECR. Deploy it with:

```bash
PREVIOUS_APP_TAG='build-N-GITSHA'

shared/scripts/deploy-images.sh prod app "$PREVIOUS_APP_TAG" --confirm-production
```

The ECR lifecycle policy retains the five most recent `build-*` images by
default.
