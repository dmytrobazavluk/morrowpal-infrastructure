# Replace the staging host and rehearse rollback

This workflow is staging-only. Keep the original EC2 stack/root disk, retained
database volume, stable IP, provider identities and tested images. The candidate
has a separate EC2 stack. Production promotion and original-host cleanup require
their own later review.

Run commands from `infrastructure`, with an authenticated AWS CLI session for
the staging account. Review the shared AMI policy, staging overlay, public DNS,
release metadata and maintenance window first. Do not run another staging
operator or automation during the handoff. Local lifecycle/release/handoff
commands share a lock; external AWS operators must honor the maintenance window.

## Create the candidate and record the baseline

1. Create the candidate change set with the infrastructure wrapper:

   ```bash
   bash shared/scripts/morrowpal-infrastructure-change-set.sh staging ec2 os-align-create --candidate-suffix os-align-01
   bash shared/scripts/execute-staging-replacement-change-set.sh candidate morrowpal-staging-ec2-os-align-01 os-align-create
   ```

   The executor inspects the prepared change set and permits only an added EC2
   instance for this operation. It rejects production stack names, unexpected
   resources and changes to the retained database or IP allocation.

2. Start the original staging host through `staging-lifecycle.sh start` if it is
   stopped. Capture its public OS, filesystem and running-image metadata over
   verified SSH; the capture script prints no container environment or secrets:

   ```bash
   ssh -i ../morrowpal-staging-01.pem -o UserKnownHostsFile=environments/staging/known_hosts -o StrictHostKeyChecking=yes ec2-user@98.95.17.0 'sudo bash -s' < shared/scripts/capture-host-metadata.sh > /path/to/original-host-baseline.json
   bash shared/scripts/staging-lifecycle.sh stop
   ```

   The example IP is the staging overlay's stable address. Verify that binding
   before connecting. Confirm the eight running project containers and review
   their tags/digests and the retained XFS UUID. Never capture full Docker inspect
   output, container environments, secret files or private keys.

3. Capture a new replacement record after the original is cleanly stopped:

   ```bash
   bash shared/scripts/capture-staging-replacement-record.sh morrowpal-staging-ec2-os-align-01 /path/to/original-host-baseline.json /path/to/replacement-record.json
   ```

   This validates the staging stacks, stops the fresh candidate only if it has
   just its root disk, creates a completed encrypted snapshot of the original
   staging data volume, and constructs the record from AWS and the captured
   running-image metadata. It then runs all metadata checks, including schedule
   trust/permission scope. Both instances remain stopped. Existing records are
   not overwritten. A record is preserved if a later metadata check fails, so
   investigate that failure rather than bypassing it.

## Handoff, prepare and verify

```bash
bash shared/scripts/staging-host-handoff.sh /path/to/replacement-record.json candidate
bash shared/scripts/staging-host-handoff.sh /path/to/replacement-record.json candidate --execute
bash shared/scripts/prepare-staging-replacement.sh /path/to/replacement-record.json candidate YOUR_CERTBOT_EMAIL
```

The first command is read-only. Execution requires both recorded hosts stopped,
pauses nightly shutdown through CloudFormation, creates another fresh recovery
snapshot, removes only the database attachment, selects the candidate stack,
moves the same IP, attaches the same volume and retargets the still-paused
shutdown role/schedule. Every resource mutation rechecks the relevant live
bindings. It leaves both instances stopped, and writes a public operation log
beside the record. Snapshots remain available for recovery.

Preparation waits until the recorded scheduler retry window has elapsed. If it
reports that the window is still open, wait until `startNotBeforeEpoch` in
`replacement-record.json.handoff.json`, then repeat the command. It verifies
that the other instance remains stopped before starting the selected host.
Candidate SSH keys must match a trusted AWS source. Cloud-init's host-public-key
block can supply that source when present in the console output. If it is absent,
use an authenticated Systems Manager channel to the validated candidate:

```bash
bash shared/scripts/trust-staging-host-via-ssm.sh /path/to/replacement-record.json candidate
```

That command reads only the public Ed25519 host key, verifies the SSM invocation's
instance identity/success, and matches it against the SSH endpoint before caching
trust. SSM must already be online with registration/channel permissions. Any
temporary staging-only registration policy must be reviewed as IaC and removed
after public-key retrieval. Do not add permissions to production or read private
host keys as a workaround. Repeat preparation after trust is cached.
The original trust file is preserved for rollback. Unmatched keys
stop preparation; strict host checking is never disabled.

The wrapper runs the shared Docker/Compose, host, MySQL, retained-XFS recovery
and TLS playbooks, then deploys the recorded tags through `deploy-images.sh
staging initial`. Existing-filesystem mode and the recorded UUID are mandatory;
formatting cannot be used for this path. Images are verified in ECR before
deployment. The deployment scan gate still applies; no rebuild is requested.

Verify OS release/kernel and engine versions, database volume/UUID and state,
running image digests, service readiness, HTTPS routing, web runtime config and
the affected application behavior. Verify recovery snapshot freshness and
restore usability separately. Public DNS remains at IONOS and is not moved by
the wrapper. Then re-enable the validated nightly stop:

```bash
bash shared/scripts/staging-host-handoff.sh /path/to/replacement-record.json candidate --enable-shutdown
```

`capture-host-metadata.sh` includes the Nitro instance ID from
[DMI metadata](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/identify_ec2_instances.html).
The runtime verifier compares the candidate's OS/kernel/engines with the supplied
read-only production baseline. It compares the original host with the archived
`replacement-record.json.original-host-baseline.json`, preserved beside the record.
MySQL and Envoy are compared by immutable Docker image IDs; application releases
are compared by their recorded ECR manifest digests.

The snapshot diagnostic creates a separate encrypted volume, mounts it read-only
without replaying the log or conflicting with the mounted source UUID, verifies
XFS UUID and MySQL identity, then unmounts/detaches/deletes only that diagnostic
volume:

```bash
bash shared/scripts/verify-staging-snapshot-restore.sh /path/to/replacement-record.json candidate
```

This tests filesystem restoration and identity. It does not start a separate
restored MySQL server or prove a logical database restore.

## Rehearse rollback and restore the candidate

```bash
bash shared/scripts/staging-lifecycle.sh stop
bash shared/scripts/staging-host-handoff.sh /path/to/replacement-record.json original --execute
bash shared/scripts/prepare-staging-replacement.sh /path/to/replacement-record.json original YOUR_CERTBOT_EMAIL
```

Verify the same storage, data identity, IP, image digests and readiness on the
original. This returns the retained volume to that host; it does not restore old
database contents from a snapshot. A schema-changing release needs a separate
compatibility/restore plan. This rehearsal uses the same recorded application
release on both hosts.

Stop the original through the lifecycle wrapper, repeat handoff/preparation
toward `candidate`, verify it again, re-enable nightly shutdown for the candidate
and stop staging. Retain the original stack/root and snapshots until an explicit
cleanup review. Controlled-client notification delivery remains a separate gate.

## Run the remaining rehearsal as one batch

After the first candidate infrastructure handoff and trusted-access setup, this
runner prepares/verifies the candidate, performs the snapshot diagnostic,
rehearses original-host rollback, restores/verifies the candidate, enables nightly
shutdown and stops both hosts:

```bash
bash shared/scripts/finish-staging-os-alignment.sh /path/to/replacement-record.json /path/to/production-readonly-baseline.json YOUR_CERTBOT_EMAIL
```

For an already prepared candidate stopped after a verification failure,
`--resume-candidate` rechecks bindings and starts it through the lifecycle wrapper
before repeating verification. `--resume-rollback` resumes a partially completed stopped-host handoff toward
the original before continuing the remaining rehearsal. Both modes revalidate
live bindings; neither assumes an interrupted operation completed. The runner
retains evidence beside the record and attempts normal stops of both validated
staging hosts on failure.
It waits for the recorded paused-scheduler retry window before starting or
preparing a host; direct preparation still rejects startup before that deadline.
Handoff/preparation/batch scripts freeze their own source at launch so later
source-file edits cannot change a running shell's text.

## Partial failures

The handoff stops on the first failed check or operation and reports its phase.
It never starts either host or automatically deletes resources during recovery.
Keep both hosts stopped after an incomplete infrastructure handoff. Correct the
reported problem, then rerun `staging-host-handoff.sh` toward either recorded
target. It re-reads AWS attachment/IP/scheduler state, accepts only identities
from the validated record and converges toward that target. Do not edit resource
IDs, format the volume, force-detach it, disable host-key checking or start a
second writer to bypass a failed guard. The stateful offline suite exercises
returning to the original after IP and attachment execution failures.
