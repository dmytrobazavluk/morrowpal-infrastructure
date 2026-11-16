# Replacement record

Keep a JSON record of the public resource identities and approved releases for
each host replacement. Do not include credentials or secret values. Store
supporting review notes from [the replacement checklist](replace-host.md)
alongside it, including backup, TLS, database compatibility and rollback plans.

Run from `infrastructure`, selecting the environment explicitly:

```bash
bash shared/scripts/validate-replacement-record.sh staging /path/to/record.json
```

The validator checks the schema, environment overlay, active stack, network,
public IP, key name, shared AMI release name, release tag/digest formats, and
distinct host/root/data identities. It reads local files and uses localhost
Ansible rendering. It does not call AWS or change the record.

Use the following shape. Angle-bracket placeholders deliberately fail validation.
Replace every placeholder with reviewed metadata; use the actual environment,
account, Region and Availability Zone. The candidate must use a distinct suffixed
EC2 stack. The selected active stack can be either recorded host, allowing the
same record to be checked before cutover and rollback.

```json
{
  "schemaVersion": 1,
  "environment": "staging",
  "accountId": "<account ID>",
  "region": "<Region>",
  "availabilityZone": "<AZ>",
  "original": {
    "stackName": "<original stack>",
    "instanceId": "<original instance>",
    "amiId": "<original AMI>",
    "rootVolumeId": "<original root volume>"
  },
  "candidate": {
    "stackName": "<candidate stack>",
    "instanceId": "<candidate instance>",
    "amiId": "<candidate AMI>",
    "imageName": "<shared ec2-image.json name>",
    "rootVolumeId": "<candidate root volume>"
  },
  "data": {
    "volumeId": "<retained data volume>",
    "filesystemUuid": "<retained XFS UUID>",
    "snapshotId": "<completed recovery snapshot>"
  },
  "publicIp": {
    "allocationId": "<retained EIP allocation>",
    "address": "<overlay public IP>"
  },
  "network": {
    "vpcId": "<overlay VPC>",
    "subnetId": "<overlay subnet>",
    "securityGroupId": "<overlay security group>",
    "keyName": "<overlay recovery key name>"
  },
  "releases": {
    "backend": {"tag": "<backend tag>", "apiDigest": "<API digest>", "jobDigest": "<jobs digest>"},
    "app": {"tag": "<app tag>", "digest": "<app digest>"},
    "website": {"tag": "<website tag>", "digest": "<website digest>"}
  },
  "shutdown": {
    "groupName": "morrowpal-staging-auto-stop",
    "scheduleName": "morrowpal-staging-auto-stop-nightly",
    "originalTargetInstanceId": "<original instance>"
  }
}
```

For production, `shutdown` must be `null`. Tags use `build-N-SOURCEHASH` with a
positive build number and seven lowercase hexadecimal source characters. Digests
use `sha256:` followed by 64 lowercase hexadecimal characters. Unknown or missing
fields are rejected. Draft records remain incomplete until the candidate and
recovery snapshot exist.

Passing local validation does not establish that a resource exists, belongs to
the account/environment, uses the recorded AMI, or contains the expected data.
It does not prove snapshot completion, image availability, current attachments,
IAM scope, scheduler state or filesystem UUID. The guarded cutover/rollback path
must revalidate those identities and state against AWS and the host before each
mutation. This validator does not authorize or implement cutover.

## Read-only AWS host checks

With an authenticated AWS CLI session for the selected account, run:

```bash
bash shared/scripts/check-replacement-hosts.sh staging /path/to/record.json
```

This first validates a private temporary copy of the local record. It rejects
conflicting `AWS_REGION` or `AWS_DEFAULT_REGION` settings and checks the caller
account before looking up resources. Then it checks both hosts against AWS:

- Each recorded stack has the expected account/Region/name, a stable successful
  status, and matching instance/AZ outputs.
- Each instance belongs to that account and stack, has the selected environment,
  application and name tags, and matches the recorded AMI, network and key.
  Its profile and single role must match the environment's access stack.
- Each host is running or stopped, with its recorded root disk attached at its
  root device. Each root disk must be encrypted gp3, in the same AZ, and attached
  only to that host at that device.
- The candidate AMI ID resolves to the shared release name, owner and architecture,
  uses EBS/HVM, and is available without an explicit Allowed AMIs rejection.

All AWS calls are reads. This command does not connect to either host, refresh
authentication, stop instances or move resources. A stopped original host is
still required before data handoff; accepting a running host here does not
establish that it is safe to detach storage.

This is one part of the future cutover preflight. Data volume/UUID, stable IP,
snapshot completion, release digests, scheduler target and actual OS/kernel
checks remain separate requirements. Host sizing and runtime parity also remain
part of the broader alignment audit. Successful output is a point-in-time check,
not a lock or permission to mutate; repeat the relevant checks immediately before
each guarded operation.

## Read-only AWS storage checks

Select the expected attachment explicitly; run just the command matching the
reviewed handoff stage:

```bash
bash shared/scripts/check-replacement-storage.sh staging /path/to/record.json original
bash shared/scripts/check-replacement-storage.sh staging /path/to/record.json detached
bash shared/scripts/check-replacement-storage.sh staging /path/to/record.json candidate
```

These commands only inspect metadata; they do not detach or attach the disk.
The checker validates a private record copy, Region settings and caller account
before reading the selected environment's MySQL storage stack, volume and
snapshot. It requires:

- A stable storage stack with the recorded volume/AZ and `/dev/sdf` output.
  Its explicit `AttachVolume` and `InstanceId` parameters must agree with the
  expected attachment. The shared storage template supplies these parameters.
- The same encrypted gp3 data volume, AZ and environment/application/stack tags,
  with multi-attach disabled. Attached states require exactly one completed
  attachment to the selected recorded host at `/dev/sdf`, with deletion on
  instance termination disabled. Detached state requires an available volume
  and no attachments.
- The recorded snapshot owned by the selected account, sourced from that exact
  volume, complete and in the standard storage tier. It must be encrypted with
  the same KMS key, have the same capacity, and carry the selected `Environment`
  and `Application=morrowpal` tags. Apply these tags when creating the recovery
  snapshot; the checker never adds them or creates a snapshot.

The [AWS volume](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-volumes.html)
and [snapshot](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-snapshots.html)
metadata are read through the AWS CLI. No host connection or filesystem operation
runs. UUID matching still belongs to retained-filesystem recovery on the host.
Snapshot freshness relative to a clean application stop, database consistency,
KMS decrypt access and a usable restore must also be verified before relying on
the backup. Snapshot metadata passing these checks does not prove those facts.

Run the separate host checks as well. IP, releases, scheduler, quiescence and
the remaining guarded cutover/rollback workflow still require implementation
and rehearsal. These checks neither lock resources nor authorize a handoff.
