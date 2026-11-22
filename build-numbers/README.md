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
shared/scripts/deploy-images.sh staging backend "$BACKEND_TAG"

source shared/scripts/build-images.sh app 1.1.0
shared/scripts/deploy-images.sh staging app "$APP_TAG"

source shared/scripts/build-images.sh website
shared/scripts/deploy-images.sh staging website "$WEBSITE_TAG"
```

The builder produces local tags such as `morrowpal/app:build-N-SOURCEHASH`
and exports the tag when sourced. The backend produces `morrowpal/backend-api`
and `morrowpal/backend-job` with one tag. The deployment command selects the matching inventory and overlay, checks the
AWS account, Region, instance, IAM profile and Elastic IP, then publishes images,
verifies digests and vulnerability scans, and runs the shared playbook.
Add `--dry-run` to inspect the plan using read-only AWS calls. Already-published
images support retries and rollback; `--check --diff` previews their Ansible changes.

The builder holds a nonblocking `flock` on its own counter until it exits.
The same component cannot build concurrently from this checkout; different
components can. Deployments use temporary Docker authentication settings. Run deployments to
the same environment sequentially.

Across workstations, branches and separate checkouts, serialization is a workflow
rule: use the latest committed counters, coordinate builds of the same component,
and commit/push its counter before handing off. Do not switch branches, restore
counter files, or reset them during a build. Git conflicts must retain the highest
reserved number. Sync the latest counter before building. ECR's immutable tags
prevent an existing remote tag from being overwritten.

After staging is complete and production work is approved, deploy the tested
release to production:

```bash
shared/scripts/deploy-images.sh prod app "$APP_TAG" --confirm-production
```

The command preserves the tested image's tag and digest and verifies readiness
after deployment. Retain local images for their first production publication.
For a retry or rollback, the command can use the requested immutable tag already
published in the selected repository. Registry-to-registry recovery is planned
in Step 54a.1 for releases missing both locally and in the target repository.

Initial values were checked against production and staging ECR on 2026-11-09:
backend 32, app 28, website 13. These files track release reservations. The
deployed versions are recorded in each host's image-tag files. Android's build
helper takes an explicit build number.
