# Publishing build numbers

Each file records the last reserved number, shared by staging and production:

- `backend`: API and job images together.
- `app`: Flutter web image.
- `website`: website image.

The publisher increments its counter automatically before starting the build.
The existing `build-N-SOURCEHASH` tag format is unchanged. Dry runs and local
development builds do not increment these counters. A failed publishing attempt
keeps its reserved number; commit the updated file even when the attempt fails.

From the infrastructure repository:

```bash
source shared/scripts/publish-images.sh staging
source shared/scripts/publish-app-image.sh staging 1.1.0
source shared/scripts/publish-website-image.sh staging
```

Each publisher holds a nonblocking `flock` on its own counter until it exits.
The same component cannot publish concurrently from this checkout; different
components can. Each publisher uses separate temporary Docker authentication
settings so concurrent components do not log each other out.

Across workstations, branches and separate checkouts, serialization is a workflow
rule: use the latest committed counters, coordinate builds of the same component,
and commit/push its counter before handing off. Do not switch branches, restore
counter files, or reset them during a build. Git conflicts must retain the highest
reserved number. A stale counter that is behind existing destination ECR tags is
rejected; sync or raise that counter to the highest already used number.

Promotion copies an existing image with its tag and digest and never increments
a counter. Do not rebuild for production when promoting a staging-tested image.

Initial values were checked against production and staging ECR on 2026-11-09:
backend 32, app 28, website 13. These files track reservations, not the currently
deployed version. Android's existing build helper retains its explicit number.
