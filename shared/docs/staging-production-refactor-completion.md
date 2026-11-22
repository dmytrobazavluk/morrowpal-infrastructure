# Staging/production refactor completion

Completed on 2026-11-22 UTC for the agreed scope. This is a historical record;
environment overlays and read-only live checks establish the current target
and running release for future operations.

## Parity and verification

Both environments use shared CloudFormation templates, host configuration,
playbooks and guarded deployment scripts with explicit environment selection.
Account, Region, network, inventory, overlay, instance identity and cross-stack
bindings are validated by the wrappers. Capacity is configured independently
in each environment's overlay.

The eight common production stacks were updated without resource replacement:
`ec2-access`, `ecr`, `ec2`, `mysql-storage`, `runtime-secrets`, `system-alerts`,
`public-ip` and `http-validation-ingress`. Instance, storage, Elastic IP and
current secret versions were preserved. These template updates did not restart
the containers. Host configuration and image promotion were performed separately.

All eight running container image IDs matched between environments before the
final staging shutdown. These four application manifests were promoted without
rebuilding; all four production vulnerability scans passed:

| Component | Tag | Manifest digest |
| --- | --- | --- |
| Backend API | `build-34-2ae804f` | `sha256:a4151e166cf3d4ab870892bd2d6c7d3d031103094ff23bf0dfb86b510671439c` |
| Backend jobs | `build-34-2ae804f` | `sha256:123ea47dbde5c82c4cbae27f4f10f1a758fda43ecd3288a6461c7069506dead3` |
| App | `build-30-5c22961` | `sha256:05430b8bbe73146dcf70f62c88181226b41d7a9c8dd57d979c13d92b99c4b144` |
| Website | `build-14-4e89de1` | `sha256:da498af7c713b1001a7e40fd62823a3ab528287dcd8f5676b03fe43150873344` |

Staging OS alignment matched the production baseline: Amazon Linux 2023 release
`2023.12.20260803`, kernel `6.1.177-224.371.amzn2023.x86_64`, Docker `25.0.14`
and Compose `v5.4.0`. The staging host handoff, rollback to the original host,
and final return to the aligned host were rehearsed with the retained database
and Elastic IP. The original host has since been retired.

Intentional differences include resource identities, domains, keys/certificates,
environment-specific data and provider credentials/projects, capacity, existing
production network ownership, and staging-only shutdown/budget controls. Both
environments share account `384078510608`; staging uses `us-east-1` and production
uses `us-east-2`. Public DNS is managed manually through IONOS, outside this IaC.

The user verified staging sign-in/out, real email delivery and reply creation.
Browser notification delivery was explicitly deferred to production and remains
unverified and nonblocking for this refactor. Registration alone does not prove
delivery: verification requires receiving a notification through normal dispatch.
This completion record makes no zero-downtime claim.

## Envoy DNS correction

After host rollout, Docker reused app/website addresses. Envoy active health
checks kept removed DNS endpoints healthy, causing intermittent cross-routing
even though readiness checks passed. Restarting Envoy cleared the stale endpoints.

The durable shared fix sets `ignore_health_on_host_removal: true` on all four
Docker DNS clusters. It passed an isolated address-removal/reuse regression,
the full local validation suite, and staging-first then production deployment.
Only Envoy was recreated for this correction; the other seven container IDs
and start times and database mounts were preserved. Live upstreams matched
current Docker addresses and repeated public content checks passed.

For future rollouts, check app content, client version and website content as
well as all three readiness endpoints. See the
[infrastructure update procedure](./update-infrastructure.md).

## Production data and recovery

Production instance `i-0497133c9f94ba261`, public IP `3.12.65.199` and encrypted
database volume `vol-06a3268fb54bccfff` were preserved. The database filesystem
UUID remained `f0b56bcf-5b7e-462d-8ece-a614b36b9307`. MySQL image bytes, version
`8.4.13`, server UUID and migration history were unchanged. All 18 table row
counts matched before/after promotion and all tables passed integrity checks.
No production database restore was performed.

Two private, consistent online SQL dumps were retained on the operator's
workstation under `/home/dmytro/work/morrowpal/production-backups/`. They are
external recovery files, not repository contents; their availability must be
checked before relying on them. Keep directories mode `0700` and dumps `0600`.

| Relative dump path | SHA-256 | Verification |
| --- | --- | --- |
| `20261121T191100Z/morrowpal.sql.gz` | `0fc232f2e8fc9c3cddd84f4dc927c4bcc8cd9ede0b005da8f0f99413b8da4c95` | Restored into local MySQL `8.4.9`; all 18 tables, 536 rows and exported row-content hash matched; all table integrity checks passed. |
| `20261122T025000Z/morrowpal.sql.gz` | `a874ef30967b501830c3e6b969b29b4bdea7df938363a590765cbbefce96e15b` | Newer pre-rollout dump; compression, completion marker and 18 tables/536 rows checked. This copy was not separately restored. |

The restore rehearsal used separate schema `morrowpal_restore_20261121t191100z`
in local container `morrowpal-mysql-1`, preserving the existing local application
schema and leaving production running. Restore results describe that test time;
later live writes are not covered by these dumps. These application-schema dumps
do not include server users/grants and do not provide point-in-time recovery.
This work did not establish automated backups.

Original production host files and image-tag files were retained on the host in
`/root/morrowpal-refactor-rollback-20261121-host-images`. This external rollback
directory is not recreated by checking out the repository. The prior API/job
tag was `build-32-ca183ff`, app `build-28-f7c0354`, website `build-13-4e89de1`.
Confirm those files/images still exist and remain compatible before rollback.
Use the guarded [promotion rollback procedure](./production-promotion-checklist.md#6-roll-back-on-the-agreed-failure-gates);
image rollback does not reverse database migrations. Never restore an old dump
over the live database without separately reviewing loss of subsequent writes.

## Cleanup and retained staging

The separately approved cleanup removed the superseded `morrowpal-staging-ec2`
stack, instance `i-014b5ff0e2a3f3cd8`, its 8 GiB root volume
`vol-0a3ad7b1a645a9a2c`, primary interface `eni-02c31356e4753b969`, and eight
rehearsal snapshots. The old host and its snapshot rollback set are no longer
available. Other staging stacks were preserved. Cleanup made no production
mutations; production passed all three public readiness checks afterward.

At completion, active staging was gracefully stopped with these resources retained:

- Stack: `morrowpal-staging-ec2-os-align-01`.
- Instance: `i-0e55952b505e400cc`.
- Encrypted root volume: `vol-058355522b7bff52a`.
- Retained encrypted database volume: `vol-05652f922861a8725`.
- Database filesystem UUID: `ae2c8d38-698d-4707-add4-92636495566f`.
- Public IP: `98.95.17.0`, allocation `eipalloc-0e838f6f36b5208bf`.
- Enabled nightly shutdown at 1 AM `America/Chicago`, targeting the active host.

Start staging from `infrastructure` with valid AWS credentials:

```bash
shared/scripts/staging-lifecycle.sh start
```

See [staging operations](../../environments/staging/README.md) for lifecycle,
shutdown and cost controls. Future releases use the
[staging checklist](./staging-release-checklist.md) and
[production checklist](./production-promotion-checklist.md). Store lasting release
decisions and verification summaries in tracked `shared/docs/releases/` records;
keep credentials, private user data, SQL dumps and raw diagnostic output out of Git.
