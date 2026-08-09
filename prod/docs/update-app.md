# Update the App

Run commands from `infrastructure/prod`.

The production app image definition is in `../app/Dockerfile`, and its Nginx
configuration is in `../app/nginx.conf`. The publisher builds the sibling
`frontend` repository and supplies only `frontend/build/web` to the production
container build.

## 1. Preconditions

Confirm the app source worktree is clean because the publisher refuses dirty
source:

```bash
git -C ../../frontend status --short
```

Confirm AWS identity and host connectivity:

```bash
aws sts get-caller-identity
ansible production -m ping
```

The AWS account must be `384078510608`.

The current Flutter test suite has known widget-test failures. The publishing
script builds the production web app but does not run that failing suite. Make
the release decision explicitly rather than assuming the release is test-gated.

## 2. Publish the app image

Choose a positive build number greater than the latest published app build:

```bash
./scripts/publish-app-image.sh BUILD_NUMBER
```

The publisher:

- Compiles Flutter web with `API_BASE_URL=https://api.morrowpal.com`.
- Builds the pinned, non-root Nginx image for Linux AMD64.
- Pushes an immutable `build-N-GITSHA` tag to `morrowpal/prod/app`.
- Waits for the ECR vulnerability scan.
- Rejects critical or high findings.

Record the published tag as `APP_TAG`.

## 3. Preview the deployment

```bash
ansible-playbook ./playbooks/deploy.yml \
  --check \
  --diff \
  -e morrowpal_app_image_tag=APP_TAG
```

Infrastructure file changes can cause a full service restart. An app-only tag
change replaces only the app container; the backend release task is skipped.

## 4. Deploy

```bash
ansible-playbook ./playbooks/deploy.yml \
  -e morrowpal_app_image_tag=APP_TAG
```

The app deployment waits for both the container health check and the public
Envoy route. If either fails, it restores the previously recorded app tag.

## 5. Verify

```bash
ansible 01 -b -m command -a '/usr/local/sbin/morrowpal-service status'
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

## Rollback

Deploy a previously retained app tag:

```bash
ansible-playbook ./playbooks/deploy.yml \
  -e morrowpal_app_image_tag=PREVIOUS_APP_TAG
```

The ECR lifecycle policy retains the five most recent `build-*` images by
default.
