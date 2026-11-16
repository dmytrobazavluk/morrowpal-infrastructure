# Plan a host replacement

**Execution gate:** this is a planning checklist, not an executable replacement
procedure. The guarded replacement path must be implemented and rehearsed in
staging before replacing either environment's host. Production additionally
requires completed staging validation, the final parity audit, and explicit
approval. The [fresh installation guide](./install-from-scratch.md) must not be
used to recreate an existing environment's retained resources.

## Tooling constraints

The infrastructure change-set wrapper resolves the selected active EC2 stack
and preserves its AMI during routine updates. Its `--candidate-suffix` option
prepares CREATE-only change sets for a separate inactive EC2 stack using the
shared image policy. It does not perform a host cutover or rollback.
The deployment wrapper requires the stable Elastic
IP to be associated with the selected instance and accepts no temporary-IP or
inventory overrides. Its `initial` mode supplies all component tags but keeps
those same target checks.

Consequently, the sequence "create a replacement, deploy through its temporary
address, then move the Elastic IP" is not supported by the current wrappers.
Do not bypass the guards with resource-ID parameters or ad hoc inventories.
Before execution, choose and implement a guarded replacement strategy that
accounts for this ordering and CloudFormation's handling of the old instance.

## Prepare a candidate change set

For staging, a reviewed suffix such as `os-align-01` derives the name
`morrowpal-staging-ec2-os-align-01`. Preview its inputs first:

```bash
shared/scripts/morrowpal-infrastructure-change-set.sh staging ec2 candidate-os-align-01 \
  --candidate-suffix os-align-01 --dry-run
```

After reviewing the preview, prepare the unexecuted change set:

```bash
shared/scripts/morrowpal-infrastructure-change-set.sh staging ec2 candidate-os-align-01 \
  --candidate-suffix os-align-01
```

The wrapper validates the active instance and its environment bindings, then
resolves the pinned image for the new host. Candidate names must be well formed,
fit CloudFormation's length limit, differ from the active stack, and not already
exist. Existing candidates require a new reviewed suffix; this option never
updates them. Production requires the usual explicit production confirmation
and approval gates.

Preparing the change set does not launch the host. Executing a reviewed
candidate change set creates the EC2 host and its root storage; it does not
transfer the database or stable IP, update the active-stack setting, change
the shutdown schedule, or deploy applications. Keep those actions gated until
the cutover and rollback path below has been implemented and reviewed.
CloudFormation can reserve the name with a REVIEW_IN_PROGRESS stack when the
CREATE change set is prepared. Review/execute that existing change set rather
than rerunning candidate creation with the same name. The wrapper will not
delete or overwrite that reservation automatically.

## Inputs and preservation requirements

Run local planning commands from `infrastructure`. Select `staging` or `prod`
explicitly; use only its inventory, overlay, account, and Region. Record public
resource metadata and release identifiers, never credentials or secret values.

Prepare a replacement record containing:

- Current and replacement instance identities, stack identities, reviewed AMI,
  instance type, role/profile, security group, subnet, and recovery key.
- Retained MySQL volume ID, filesystem UUID, attachment, backup/recovery point,
  and Availability Zone. The replacement must remain in that volume's AZ.
- Stable Elastic IP allocation and association, all DNS names, and certificate
  recovery/issuance plan. Certificates live on the root volume.
- Backend, app, and website tags/digests and the compatible database schema.
  Use the approved images without rebuilding.
- Environment-specific provider paths, SNS bindings, budget, and, for staging,
  the nightly shutdown target. Replacement must update that target and policy.

Use the [replacement-record schema and local validator](replacement-record.md)
for the machine-readable identities and release metadata. Keep the supporting
review notes above alongside that record. Local validation does not replace
live AWS and filesystem checks before each mutation.

The MySQL volume, Elastic IP allocation, runtime secrets, repository images, and
provider identities must survive. Do not format the retained data volume.
`prepare-storage.yml` requires recovery mode for a retained volume. Supply
`morrowpal_require_existing_mysql_filesystem=true` together with
`morrowpal_expected_mysql_filesystem_uuid` from the verified recovery record.
Recovery mode requires existing XFS, never formats, and checks the UUID before
mounting. A missing filesystem, mismatched UUID or invalid input stops the
playbook. The default fresh-install mode may format an empty device; do not use
it for a retained database.

## Required cutover and rollback design

1. Establish the maintenance window and tested backup/restore plan. The single
   database volume and public IP handoff cause service downtime.
2. Review the replacement change set and old-instance retention/cleanup behavior
   before execution. Confirm that data volume, secrets, and IP allocation are
   preserved; replacement must not silently create substitutes for them.
3. Stop application writers cleanly on the old host, disable swap on the data
   volume, and unmount it. Verify those steps before detaching. Do not force
   detach an actively mounted database volume.
4. Review a `mysql-storage --detach-mysql-volume` change set that removes only
   the attachment. Wait for stack completion and the volume to become available.
5. Bring the reviewed replacement into the supported stack/output bindings,
   prepare the host, and attach the retained volume through a separately reviewed
   change set. Verify the original volume ID, filesystem, UUID, and data.
6. Transfer the stable IP through a reviewed association change that preserves
   its allocation. Align the selected inventory/overlay, recover TLS, and deploy
   the approved tags using a guarded path consistent with its IP checks.
7. Verify storage, API/jobs, app, website, TLS renewal, live notifications, and
   alarms. Reapply metadata tags and refresh staging's shutdown target if needed.
8. Define explicit failure gates and how to return the retained volume/IP to
   the old host or restore a backup. Never run writers on both hosts. Do not
   terminate the old host until verification and the rollback decision are complete.

The supported implementation must make the chosen instance and attachment/IP
transitions reviewable without weakening routine environment guards. Test the
actual sequence, including failure recovery, in staging before adding execution
commands here. No replacement or shutdown is authorized by this checklist alone.
