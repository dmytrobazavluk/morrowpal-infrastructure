# Plan a host replacement

**Execution gate:** this is a planning checklist, not an executable replacement
procedure. The guarded replacement path must be implemented and rehearsed in
staging before replacing either environment's host. Production additionally
requires completed staging validation, the final parity audit, and explicit
approval. The [fresh installation guide](./install-from-scratch.md) must not be
used to recreate an existing environment's retained resources.

## Tooling constraints

The infrastructure change-set wrapper resolves the environment's current EC2
stack and preserves its AMI during routine updates. It has no reviewed AMI
upgrade/replacement option. The deployment wrapper requires the stable Elastic
IP to be associated with the selected instance and accepts no temporary-IP or
inventory overrides. Its `initial` mode supplies all component tags but keeps
those same target checks.

Consequently, the sequence "create a replacement, deploy through its temporary
address, then move the Elastic IP" is not supported by the current wrappers.
Do not bypass the guards with resource-ID parameters or ad hoc inventories.
Before execution, choose and implement a guarded replacement strategy that
accounts for this ordering and CloudFormation's handling of the old instance.

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

The MySQL volume, Elastic IP allocation, runtime secrets, repository images, and
provider identities must survive. Do not format the retained data volume.
`prepare-storage.yml` formats an empty device: verify the expected existing XFS
filesystem and UUID before using it for recovery. A missing filesystem is a
stop condition, not permission to initialize a new database.

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
