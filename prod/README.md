# Production EC2 Instances

Run all local commands in this document from the directory containing this
README: `infrastructure/prod`.

The replayable HTTPS design and rollout order are documented in [TLS.md](./TLS.md).

## Instance 01

The private key is stored outside the infrastructure repository at
`../../morrowpal-prod-01.pem`.

Connect to instance 01 over SSH:

```bash
ssh -i ../../morrowpal-prod-01.pem ec2-user@3.12.65.199
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

## Allow Instance 01 to Pull Images

Instance 01 needs an IAM instance profile so it can authenticate to ECR without
credentials stored on the server. The `./cloudformation/ec2-access.yml`
template grants permission to pull images only from the production backend API
and job repositories.

Validate the template:

```bash
cfn-lint --format json --regions us-east-2 -t ./cloudformation/ec2-access.yml

aws cloudformation validate-template \
  --template-body file://./cloudformation/ec2-access.yml \
  --region us-east-2
```

After reviewing a CloudFormation change set, deploy the IAM stack:

```bash
aws cloudformation deploy \
  --template-file ./cloudformation/ec2-access.yml \
  --stack-name morrowpal-prod-ec2-access \
  --capabilities CAPABILITY_IAM \
  --region us-east-2 \
  --no-fail-on-empty-changeset
```

## Create Instance 01

The `./cloudformation/ec2.yml` template creates an Amazon Linux 2023 x86_64
host with a `t3.small` default, encrypted gp3 root volume, IMDSv2 enforcement,
container-compatible metadata hop limit, and standard CPU-credit mode. It uses
the IAM instance profile from the access stack and creates a temporary public
address for bootstrapping before the stable Elastic IP is associated.

Validate the template:

```bash
cfn-lint --format json --regions us-east-2 -t ./cloudformation/ec2.yml

aws cloudformation validate-template \
  --template-body file://./cloudformation/ec2.yml \
  --region us-east-2
```

Read the instance profile owned by the access stack:

```bash
INSTANCE_PROFILE_NAME="$(aws cloudformation describe-stacks \
  --stack-name morrowpal-prod-ec2-access \
  --query 'Stacks[0].Outputs[?OutputKey==`InstanceProfileName`].OutputValue' \
  --output text \
  --region us-east-2)"
```

Create and review a change set. The subnet must remain in `us-east-2c` while
the retained MySQL volume is in that Availability Zone.

```bash
aws cloudformation create-change-set \
  --stack-name morrowpal-prod-ec2 \
  --change-set-name initial-ec2 \
  --change-set-type CREATE \
  --template-body file://./cloudformation/ec2.yml \
  --parameters \
    ParameterKey=KeyName,ParameterValue=01 \
    ParameterKey=SubnetId,ParameterValue=subnet-098ab1625c79adf3d \
    ParameterKey=SecurityGroupId,ParameterValue=sg-0103b42f143676fda \
    ParameterKey=InstanceProfileName,ParameterValue="$INSTANCE_PROFILE_NAME" \
  --region us-east-2

aws cloudformation wait change-set-create-complete \
  --stack-name morrowpal-prod-ec2 \
  --change-set-name initial-ec2 \
  --region us-east-2

aws cloudformation describe-change-set \
  --stack-name morrowpal-prod-ec2 \
  --change-set-name initial-ec2 \
  --query '{Status:Status,ExecutionStatus:ExecutionStatus,Changes:Changes[*].{Action:ResourceChange.Action,LogicalResourceId:ResourceChange.LogicalResourceId,ResourceType:ResourceChange.ResourceType,Replacement:ResourceChange.Replacement}}' \
  --region us-east-2
```

After confirming the change set only creates the EC2 instance and its encrypted
root volume, execute it and wait for completion:

```bash
aws cloudformation execute-change-set \
  --stack-name morrowpal-prod-ec2 \
  --change-set-name initial-ec2 \
  --region us-east-2

aws cloudformation wait stack-create-complete \
  --stack-name morrowpal-prod-ec2 \
  --region us-east-2
```

Read the new instance ID and temporary bootstrap address:

```bash
PRODUCTION_INSTANCE_ID="$(aws cloudformation describe-stacks \
  --stack-name morrowpal-prod-ec2 \
  --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
  --output text \
  --region us-east-2)"

BOOTSTRAP_PUBLIC_IP="$(aws cloudformation describe-stacks \
  --stack-name morrowpal-prod-ec2 \
  --query 'Stacks[0].Outputs[?OutputKey==`BootstrapPublicIp`].OutputValue' \
  --output text \
  --region us-east-2)"
```

Run the host preparation playbooks against the temporary address by passing
`-e "ansible_host=$BOOTSTRAP_PUBLIC_IP"`. Do not move the MySQL volume or stable
Elastic IP until these playbooks succeed.

## Create or Move the Stable Public IP

The `./cloudformation/public-ip.yml` stack owns the Elastic IP. Its
`InstanceId` parameter controls which production instance receives the address.
Changing this parameter moves traffic without replacing or releasing the IP.

```bash
cfn-lint --format json --regions us-east-2 -t ./cloudformation/public-ip.yml

aws cloudformation validate-template \
  --template-body file://./cloudformation/public-ip.yml \
  --region us-east-2
```

To move the existing address to a replacement instance, create and inspect an
update change set:

```bash
aws cloudformation create-change-set \
  --stack-name morrowpal-prod-public-ip \
  --change-set-name move-production-public-ip \
  --change-set-type UPDATE \
  --template-body file://./cloudformation/public-ip.yml \
  --parameters ParameterKey=InstanceId,ParameterValue="$PRODUCTION_INSTANCE_ID" \
  --region us-east-2

aws cloudformation wait change-set-create-complete \
  --stack-name morrowpal-prod-public-ip \
  --change-set-name move-production-public-ip \
  --region us-east-2

aws cloudformation describe-change-set \
  --stack-name morrowpal-prod-public-ip \
  --change-set-name move-production-public-ip \
  --query '{Status:Status,ExecutionStatus:ExecutionStatus,Changes:Changes[*].{Action:ResourceChange.Action,LogicalResourceId:ResourceChange.LogicalResourceId,ResourceType:ResourceChange.ResourceType,Replacement:ResourceChange.Replacement}}' \
  --region us-east-2
```

After confirming that only the Elastic IP association changes, execute it:

```bash
aws cloudformation execute-change-set \
  --stack-name morrowpal-prod-public-ip \
  --change-set-name move-production-public-ip \
  --region us-east-2

aws cloudformation wait stack-update-complete \
  --stack-name morrowpal-prod-public-ip \
  --region us-east-2
```

Update `./inventory.ini` and the SSH command at the start of this document only
if a new Elastic IP was created. Moving the existing association preserves the
address.

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

## Prepare Public TLS

The production certificate explicitly covers `morrowpal.com` plus the
`api`, `admin`, `app`, `www`, and `back` subdomains. Certbot validates every
name through public port 80 and Envoy serves HTTPS on port 443. The private key
is generated only on the encrypted EC2 root volume and is never copied to this
repository or the Ansible controller.

Validate the CloudFormation-managed HTTP validation rule:

```bash
cfn-lint --format json --regions us-east-2 \
  -t ./cloudformation/http-validation-ingress.yml

aws cloudformation validate-template \
  --template-body file://./cloudformation/http-validation-ingress.yml \
  --region us-east-2
```

Create and inspect a change set before opening port 80:

```bash
aws cloudformation create-change-set \
  --stack-name morrowpal-prod-http-validation-ingress \
  --change-set-name initial-http-validation-ingress \
  --change-set-type CREATE \
  --template-body file://./cloudformation/http-validation-ingress.yml \
  --parameters ParameterKey=SecurityGroupId,ParameterValue=sg-0103b42f143676fda \
  --region us-east-2

aws cloudformation wait change-set-create-complete \
  --stack-name morrowpal-prod-http-validation-ingress \
  --change-set-name initial-http-validation-ingress \
  --region us-east-2

aws cloudformation describe-change-set \
  --stack-name morrowpal-prod-http-validation-ingress \
  --change-set-name initial-http-validation-ingress \
  --query '{Status:Status,ExecutionStatus:ExecutionStatus,Changes:Changes[*].{Action:ResourceChange.Action,LogicalResourceId:ResourceChange.LogicalResourceId,ResourceType:ResourceChange.ResourceType,Replacement:ResourceChange.Replacement}}' \
  --region us-east-2
```

After confirming that the change set adds only `CertbotHttpIngress`, execute it
and wait for completion:

```bash
aws cloudformation execute-change-set \
  --stack-name morrowpal-prod-http-validation-ingress \
  --change-set-name initial-http-validation-ingress \
  --region us-east-2

aws cloudformation wait stack-create-complete \
  --stack-name morrowpal-prod-http-validation-ingress \
  --region us-east-2
```

After all six DNS names resolve to `3.12.65.199` without AAAA answers, install
Certbot and obtain the initial certificate. Replace the example email with the
address that should receive certificate-expiration notices:

```bash
ansible-playbook ./playbooks/prepare-tls.yml \
  -e morrowpal_certbot_email=admin@example.com
```

The playbook enables `morrowpal-certbot-renew.timer`. Inspect it without
exposing certificate private-key contents:

```bash
ansible 01 -b -m command \
  -a 'systemctl status morrowpal-certbot-renew.timer --no-pager'
```

## Create Encrypted MySQL Storage

MySQL data is stored on a separate encrypted gp3 volume so it can move between
EC2 hosts independently of their root volumes. CloudFormation retains this
volume if the stack is deleted or a replacement is required. The default 10
GiB volume costs about `$0.80` per month in `us-east-2` before credits.

Validate the template:

```bash
cfn-lint --format json --regions us-east-2 -t ./cloudformation/mysql-storage.yml

aws cloudformation validate-template \
  --template-body file://./cloudformation/mysql-storage.yml \
  --region us-east-2
```

Create and review a change set before creating the volume:

```bash
aws cloudformation create-change-set \
  --stack-name morrowpal-prod-mysql-storage \
  --change-set-name initial-mysql-storage \
  --change-set-type CREATE \
  --template-body file://./cloudformation/mysql-storage.yml \
  --parameters ParameterKey=InstanceId,ParameterValue="$PRODUCTION_INSTANCE_ID" \
  --region us-east-2

aws cloudformation wait change-set-create-complete \
  --stack-name morrowpal-prod-mysql-storage \
  --change-set-name initial-mysql-storage \
  --region us-east-2

aws cloudformation describe-change-set \
  --stack-name morrowpal-prod-mysql-storage \
  --change-set-name initial-mysql-storage \
  --query '{Status:Status,ExecutionStatus:ExecutionStatus,Changes:Changes[*].{Action:ResourceChange.Action,LogicalResourceId:ResourceChange.LogicalResourceId,ResourceType:ResourceChange.ResourceType,Replacement:ResourceChange.Replacement}}' \
  --region us-east-2
```

After confirming that the change set only adds the EBS volume and attachment,
execute it and wait for completion:

```bash
aws cloudformation execute-change-set \
  --stack-name morrowpal-prod-mysql-storage \
  --change-set-name initial-mysql-storage \
  --region us-east-2

aws cloudformation wait stack-create-complete \
  --stack-name morrowpal-prod-mysql-storage \
  --region us-east-2
```

Format and mount the new volume. This playbook refuses to format a volume that
already contains a filesystem. It also creates a 1 GiB encrypted swap file on
the data volume to give the small production instance additional memory
headroom:

```bash
MYSQL_VOLUME_ID="$(aws cloudformation describe-stacks \
  --stack-name morrowpal-prod-mysql-storage \
  --query 'Stacks[0].Outputs[?OutputKey==`VolumeId`].OutputValue' \
  --output text \
  --region us-east-2)"

ansible-playbook ./playbooks/prepare-storage.yml \
  -e "morrowpal_mysql_volume_id=$MYSQL_VOLUME_ID"
```

### Move the Retained MySQL Volume to a Replacement Instance

Stop the application on the old host and confirm that `/var/lib/morrowpal` is
unmounted before moving the data volume. EBS volumes can be attached to only
one instance at a time in this setup.

CloudFormation cannot directly replace this attachment because it attempts to
attach the volume to the new instance before detaching it from the old one.
Use two reviewed updates. The first update removes only the attachment while
retaining the encrypted volume and sets the new target instance ID:

```bash
aws cloudformation create-change-set \
  --stack-name morrowpal-prod-mysql-storage \
  --change-set-name detach-mysql-volume \
  --change-set-type UPDATE \
  --template-body file://./cloudformation/mysql-storage.yml \
  --parameters \
    ParameterKey=InstanceId,ParameterValue="$PRODUCTION_INSTANCE_ID" \
    ParameterKey=AttachVolume,ParameterValue=false \
    ParameterKey=AvailabilityZone,UsePreviousValue=true \
    ParameterKey=VolumeSizeGiB,UsePreviousValue=true \
  --region us-east-2

aws cloudformation wait change-set-create-complete \
  --stack-name morrowpal-prod-mysql-storage \
  --change-set-name detach-mysql-volume \
  --region us-east-2

aws cloudformation describe-change-set \
  --stack-name morrowpal-prod-mysql-storage \
  --change-set-name detach-mysql-volume \
  --query '{Status:Status,ExecutionStatus:ExecutionStatus,Changes:Changes[*].{Action:ResourceChange.Action,LogicalResourceId:ResourceChange.LogicalResourceId,ResourceType:ResourceChange.ResourceType,Replacement:ResourceChange.Replacement}}' \
  --region us-east-2
```

Confirm that the change set removes only `MysqlDataVolumeAttachment`, then
execute it and wait for the volume to become available:

```bash
aws cloudformation execute-change-set \
  --stack-name morrowpal-prod-mysql-storage \
  --change-set-name detach-mysql-volume \
  --region us-east-2

aws cloudformation wait stack-update-complete \
  --stack-name morrowpal-prod-mysql-storage \
  --region us-east-2

aws ec2 wait volume-available \
  --volume-ids "$MYSQL_VOLUME_ID" \
  --region us-east-2
```

The second update creates only the attachment to the replacement instance:

```bash
aws cloudformation create-change-set \
  --stack-name morrowpal-prod-mysql-storage \
  --change-set-name attach-mysql-volume \
  --change-set-type UPDATE \
  --template-body file://./cloudformation/mysql-storage.yml \
  --parameters \
    ParameterKey=InstanceId,ParameterValue="$PRODUCTION_INSTANCE_ID" \
    ParameterKey=AttachVolume,ParameterValue=true \
    ParameterKey=AvailabilityZone,UsePreviousValue=true \
    ParameterKey=VolumeSizeGiB,UsePreviousValue=true \
  --region us-east-2

aws cloudformation wait change-set-create-complete \
  --stack-name morrowpal-prod-mysql-storage \
  --change-set-name attach-mysql-volume \
  --region us-east-2

aws cloudformation describe-change-set \
  --stack-name morrowpal-prod-mysql-storage \
  --change-set-name attach-mysql-volume \
  --query '{Status:Status,ExecutionStatus:ExecutionStatus,Changes:Changes[*].{Action:ResourceChange.Action,LogicalResourceId:ResourceChange.LogicalResourceId,ResourceType:ResourceChange.ResourceType,Replacement:ResourceChange.Replacement}}' \
  --region us-east-2
```

Confirm that the change set adds only `MysqlDataVolumeAttachment`, then execute
it:

```bash
aws cloudformation execute-change-set \
  --stack-name morrowpal-prod-mysql-storage \
  --change-set-name attach-mysql-volume \
  --region us-east-2

aws cloudformation wait stack-update-complete \
  --stack-name morrowpal-prod-mysql-storage \
  --region us-east-2
```

Run `./playbooks/prepare-storage.yml` on the new host, then deploy and verify
the application before moving the stable public IP.

## Create Runtime Secrets

The secrets stack generates the MySQL application password, MySQL root
password, and JWT signing secret inside AWS Secrets Manager. It also grants the
existing EC2 role permission to read only those three secrets. Three secrets
cost about `$1.20` per month, plus negligible API request charges, before
credits.

The secret values must not be retrieved into the terminal. At service startup,
`asm-exec` resolves CloudFormation-style dynamic references using the instance
role, and writes short-lived root-protected files under `/run` for Docker
Compose.

Validate the template:

```bash
cfn-lint --format json --regions us-east-2 -t ./cloudformation/runtime-secrets.yml

aws cloudformation validate-template \
  --template-body file://./cloudformation/runtime-secrets.yml \
  --region us-east-2
```

Create and review the IAM-capable change set:

```bash
PRODUCTION_EC2_ROLE_ARN="$(aws cloudformation describe-stacks \
  --stack-name morrowpal-prod-ec2-access \
  --query 'Stacks[0].Outputs[?OutputKey==`RoleArn`].OutputValue' \
  --output text \
  --region us-east-2)"
PRODUCTION_EC2_ROLE_NAME="${PRODUCTION_EC2_ROLE_ARN##*/}"

aws cloudformation create-change-set \
  --stack-name morrowpal-prod-runtime-secrets \
  --change-set-name initial-runtime-secrets \
  --change-set-type CREATE \
  --template-body file://./cloudformation/runtime-secrets.yml \
  --parameters "ParameterKey=ProductionEc2RoleName,ParameterValue=$PRODUCTION_EC2_ROLE_NAME" \
  --capabilities CAPABILITY_IAM \
  --region us-east-2

aws cloudformation wait change-set-create-complete \
  --stack-name morrowpal-prod-runtime-secrets \
  --change-set-name initial-runtime-secrets \
  --region us-east-2

aws cloudformation describe-change-set \
  --stack-name morrowpal-prod-runtime-secrets \
  --change-set-name initial-runtime-secrets \
  --query '{Status:Status,ExecutionStatus:ExecutionStatus,Changes:Changes[*].{Action:ResourceChange.Action,LogicalResourceId:ResourceChange.LogicalResourceId,ResourceType:ResourceChange.ResourceType,Replacement:ResourceChange.Replacement}}' \
  --region us-east-2
```

After confirming that the change set only adds three secrets and the scoped IAM
policy, execute it and wait for completion:

```bash
aws cloudformation execute-change-set \
  --stack-name morrowpal-prod-runtime-secrets \
  --change-set-name initial-runtime-secrets \
  --region us-east-2

aws cloudformation wait stack-create-complete \
  --stack-name morrowpal-prod-runtime-secrets \
  --region us-east-2
```

## Deploy the Production Containers

The first deployment converts the single API container to two independently
tagged API containers behind Envoy. This one-time infrastructure conversion
restarts the service. Envoy listens on host loopback port 8080, while its admin
endpoint is restricted to host loopback port 9901.

Deploy an already-published immutable image tag after the encrypted storage and
runtime secrets stacks are ready:

```bash
ansible-playbook ./playbooks/deploy.yml \
  -e morrowpal_image_tag=build-2-e19eeb1
```

The systemd service resolves secrets at runtime, logs Docker into ECR with the
instance role, pulls the pinned API, job, and Envoy images, starts MySQL, waits
for its health check, starts both API containers and Envoy, verifies readiness,
and then starts both job containers. The API remains accessible only through
Envoy. Local readiness uses `127.0.0.1:8080`, while public HTTPS maps port 443
to Envoy's unprivileged container listener on port 8443.

For later releases, the same playbook performs a rolling blue-green update when
the infrastructure files are unchanged. It sets one Envoy cluster to zero
traffic, waits for active requests to drain, replaces that API container, waits
for `/ready`, restores balanced traffic, and repeats for the other container.
If a new container fails readiness, the script restores its prior immutable tag
while the other API continues serving requests. The two job containers are
updated after both API containers are healthy.

Envoy uses active `/ready` health checks and mirrored priority fallback: each
API is primary in one cluster and fallback in the other. Unexpected loss of one
API therefore directs traffic to the surviving container. Envoy 1.39.0 is
pinned by its multi-platform image digest rather than a mutable `latest` tag.

Inspect service and container status without exposing secrets:

```bash
ansible 01 -b -m command -a 'systemctl status morrowpal --no-pager'
ansible 01 -b -m command -a '/usr/local/sbin/morrowpal-service status'
```

Verify the public API after TLS deployment:

```bash
curl --fail --show-error --silent https://api.morrowpal.com/ready
```

Test the complete renewal path against the certificate authority's staging
environment after the production certificate is active:

```bash
ansible 01 -b -m command -a 'certbot renew --dry-run'
```

The rolling release command can also be run directly on the instance by root:

```bash
sudo /usr/local/sbin/morrowpal-deploy-release build-3-abcdef0
```

Prefer the Ansible playbook because it also verifies that the deployed
infrastructure files and systemd unit are current.
