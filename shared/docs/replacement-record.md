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
