# Production EC2 Instances

Run all local commands in this document from the directory containing this
README: `infrastructure/prod`.

## Instance 01

The private key is stored outside the infrastructure repository at
`../../morrowpal-prod-01.pem`.

Connect to instance 01 over SSH:

```bash
ssh -i ../../morrowpal-prod-01.pem ec2-user@3.14.79.64
```

The private key must only be readable by its owner. If needed, set its permissions before connecting:

```bash
chmod 400 ../../morrowpal-prod-01.pem
```

Verify Ansible connectivity:

```bash
ansible production -m ping
```

## Install Docker

Preview the playbook without changing the instance:

```bash
ansible-playbook ./playbooks/install-docker.yml --check --diff
```

Apply the playbook:

```bash
ansible-playbook ./playbooks/install-docker.yml
```

## Install Docker Compose

Preview the pinned, checksum-verified Compose plugin installation:

```bash
ansible-playbook ./playbooks/install-docker-compose.yml --check --diff
```

Apply the playbook:

```bash
ansible-playbook ./playbooks/install-docker-compose.yml
```

## Prepare the Production Host

Preview creation of the protected `/opt/morrowpal` deployment directory:

```bash
ansible-playbook ./playbooks/prepare-host.yml --check --diff
```

Apply the playbook:

```bash
ansible-playbook ./playbooks/prepare-host.yml
```

## Prepare MySQL for Future RDS Migration

The production MySQL configuration enables row-based binary logs, full row
images, GTID consistency, durable transaction flushing, and seven-day binary
log retention.

Preview the configuration deployment:

```bash
ansible-playbook ./playbooks/prepare-mysql.yml --check --diff
```

Apply the playbook:

```bash
ansible-playbook ./playbooks/prepare-mysql.yml
```

The production Compose file will mount
`/opt/morrowpal/mysql-migration-ready.cnf` into the MySQL container.

## Container Registries

The `./cloudformation/ecr.yml` template defines immutable, encrypted ECR
repositories for the backend API and the shared job image. Untagged images are
expired after seven days. Tags matching `build-*` retain the most recent 5
images by default; other tagged images remain available for rollback.

Validate the template in the Region that contains instance 01:

```bash
aws cloudformation validate-template \
  --template-body file://./cloudformation/ecr.yml \
  --region us-east-2
```

Deploy the stack after validation:

```bash
aws cloudformation deploy \
  --template-file ./cloudformation/ecr.yml \
  --stack-name morrowpal-prod-ecr \
  --parameter-overrides Environment=prod TaggedImageRetentionCount=5 \
  --region us-east-2 \
  --no-fail-on-empty-changeset
```

## Publish Backend Images

The publishing script tests the backend, builds the API and shared job images
for Linux AMD64, assigns both the same immutable incremental tag, pushes them to
ECR, waits for their vulnerability scans, and removes the temporary Docker
login. It refuses to publish from a dirty backend worktree, to the wrong AWS
account, or with a build number that is not greater than the latest published
build. A completed scan containing critical or high severity findings also
causes the command to fail.

Run it with the next build number:

```bash
./scripts/publish-images.sh 2
```

The resulting tag has the form `build-<number>-<git-sha>`. For example,
backend commit `e19eeb1` and build number `2` produce `build-2-e19eeb1`.
