# Release build numbers

Each file records the last reserved number, shared by staging and production:

- `backend`: API and job images together.
- `app`: Flutter web image.
- `website`: website image.

`build-images.sh COMPONENT [APP_VERSION]` reserves the component's next number
before building local images. Each image uses a `build-N-SOURCEHASH` tag. A failed release build
keeps its reserved number; commit the updated file even when the attempt fails.

From the infrastructure repository:

```bash
source shared/scripts/build-images.sh backend
shared/scripts/push-images.sh staging backend "$BACKEND_TAG"

source shared/scripts/build-images.sh app 1.1.0
shared/scripts/push-images.sh staging app "$APP_TAG"

source shared/scripts/build-images.sh website
shared/scripts/push-images.sh staging website "$WEBSITE_TAG"
```

The builder produces local tags such as `morrowpal/app:build-N-SOURCEHASH`
and exports the tag when sourced. The backend produces `morrowpal/backend-api`
and `morrowpal/backend-job` with one tag. The push command takes staging/prod and
a component, checks the AWS account, and resolves all local image IDs before
pushing. It verifies ECR digests and vulnerability scans. Add `--dry-run` to preview the
target image mappings.

The builder holds a nonblocking `flock` on its own counter until it exits.
The same component cannot build concurrently from this checkout; different
components can. Pushes use separate temporary Docker authentication settings so
concurrent components do not log each other out.

Across workstations, branches and separate checkouts, serialization is a workflow
rule: use the latest committed counters, coordinate builds of the same component,
and commit/push its counter before handing off. Do not switch branches, restore
counter files, or reset them during a build. Git conflicts must retain the highest
reserved number. Sync the latest counter before building. ECR's immutable tags
prevent an existing remote tag from being overwritten.

After staging is complete and production work is approved, push the same local
image to production, for example:

```bash
shared/scripts/push-images.sh prod app "$APP_TAG" --confirm-production
```

The production push preserves the tested image's tag and digest. Retain the
local images until promotion, then use the deployment command to run the selected
version on the production host. Registry-to-registry recovery for missing local
images is planned in Step 54a.1.

Initial values were checked against production and staging ECR on 2026-11-09:
backend 32, app 28, website 13. These files track release reservations. The
deployed versions are recorded in each host's image-tag files. Android's build
helper takes an explicit build number.
