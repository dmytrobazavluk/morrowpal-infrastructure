# Install Production From Scratch

Run commands from `infrastructure/prod`.

This runbook creates the production resources managed by this repository and
installs the complete runtime on a new EC2 host. It assumes the following
network resources already exist:

- VPC and internet-connected subnet in `us-east-2c`
- Security group `sg-0103b42f143676fda`
- Subnet `subnet-098ab1625c79adf3d`
- EC2 key pair `01`
- Public DNS zone for `morrowpal.com`

For replacing an existing host while retaining its EBS volume and Elastic IP,
use [Replace the production host](./replace-host.md) instead.

## 1. Verify prerequisites and identity

Required local commands:

```bash
aws --version
ansible --version
ansible-playbook --version
cfn-lint --version
docker --version
flutter --version
```

Confirm the AWS account and Region before creating anything:

```bash
aws sts get-caller-identity
aws configure get region
```

The account must be `384078510608`; all AWS resources in this runbook use
`us-east-2`.

## 2. Validate all CloudFormation templates

```bash
cfn-lint --format json --regions us-east-2 \
  -t ./cloudformation/ecr.yml \
  ./cloudformation/ec2-access.yml \
  ./cloudformation/ec2.yml \
  ./cloudformation/public-ip.yml \
  ./cloudformation/http-validation-ingress.yml \
  ./cloudformation/mysql-storage.yml \
  ./cloudformation/runtime-secrets.yml
```

Validate each template with AWS before creating its change set:

```bash
for template in \
  ecr.yml \
  ec2-access.yml \
  ec2.yml \
  public-ip.yml \
  http-validation-ingress.yml \
  mysql-storage.yml \
  runtime-secrets.yml
do
  aws cloudformation validate-template \
    --template-body "file://./cloudformation/$template" \
    --region us-east-2 >/dev/null
done
```

## 3. Create the container repositories

```bash
aws cloudformation create-change-set \
  --stack-name morrowpal-prod-ecr \
  --change-set-name initial-ecr \
  --change-set-type CREATE \
  --template-body file://./cloudformation/ecr.yml \
  --parameters \
    ParameterKey=Environment,ParameterValue=prod \
    ParameterKey=TaggedImageRetentionCount,ParameterValue=5 \
  --region us-east-2

aws cloudformation wait change-set-create-complete \
  --stack-name morrowpal-prod-ecr \
  --change-set-name initial-ecr \
  --region us-east-2

aws cloudformation describe-change-set \
  --stack-name morrowpal-prod-ecr \
  --change-set-name initial-ecr \
  --query 'Changes[*].ResourceChange.{Action:Action,LogicalId:LogicalResourceId,Type:ResourceType,Replacement:Replacement}' \
  --region us-east-2
```

Confirm that the change set creates only the app, backend API, and backend job
ECR repositories. Then execute it:

```bash
aws cloudformation execute-change-set \
  --stack-name morrowpal-prod-ecr \
  --change-set-name initial-ecr \
  --region us-east-2

aws cloudformation wait stack-create-complete \
  --stack-name morrowpal-prod-ecr \
  --region us-east-2
```

## 4. Create the EC2 access role

```bash
aws cloudformation create-change-set \
  --stack-name morrowpal-prod-ec2-access \
  --change-set-name initial-ec2-access \
  --change-set-type CREATE \
  --template-body file://./cloudformation/ec2-access.yml \
  --capabilities CAPABILITY_IAM \
  --region us-east-2

aws cloudformation wait change-set-create-complete \
  --stack-name morrowpal-prod-ec2-access \
  --change-set-name initial-ec2-access \
  --region us-east-2

aws cloudformation describe-change-set \
  --stack-name morrowpal-prod-ec2-access \
  --change-set-name initial-ec2-access \
  --query 'Changes[*].ResourceChange.{Action:Action,LogicalId:LogicalResourceId,Type:ResourceType,Replacement:Replacement}' \
  --region us-east-2
```

Confirm that the role grants pull-only access to the approved ECR repositories,
then execute the change set:

```bash
aws cloudformation execute-change-set \
  --stack-name morrowpal-prod-ec2-access \
  --change-set-name initial-ec2-access \
  --region us-east-2

aws cloudformation wait stack-create-complete \
  --stack-name morrowpal-prod-ec2-access \
  --region us-east-2
```

Read the instance profile name:

```bash
INSTANCE_PROFILE_NAME="$(aws cloudformation describe-stacks \
  --stack-name morrowpal-prod-ec2-access \
  --query 'Stacks[0].Outputs[?OutputKey==`InstanceProfileName`].OutputValue' \
  --output text \
  --region us-east-2)"
```

## 5. Create the EC2 host

The template creates Amazon Linux 2023 on x86_64 with encrypted gp3 storage,
IMDSv2 enforcement, container-compatible metadata hop limit, and standard CPU
credit mode.

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
  --query 'Changes[*].ResourceChange.{Action:Action,LogicalId:LogicalResourceId,Type:ResourceType,Replacement:Replacement}' \
  --region us-east-2
```

Confirm that the change set creates the EC2 host and encrypted root volume,
then execute it:

```bash
aws cloudformation execute-change-set \
  --stack-name morrowpal-prod-ec2 \
  --change-set-name initial-ec2 \
  --region us-east-2

aws cloudformation wait stack-create-complete \
  --stack-name morrowpal-prod-ec2 \
  --region us-east-2
```

Read the instance ID and temporary bootstrap address:

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

## 6. Prepare the host

Use the temporary address until the stable Elastic IP is associated:

```bash
ansible-playbook ./playbooks/install-docker.yml \
  -e "ansible_host=$BOOTSTRAP_PUBLIC_IP"

ansible-playbook ./playbooks/install-docker-compose.yml \
  -e "ansible_host=$BOOTSTRAP_PUBLIC_IP"

ansible-playbook ./playbooks/prepare-host.yml \
  -e "ansible_host=$BOOTSTRAP_PUBLIC_IP"

ansible-playbook ./playbooks/prepare-mysql.yml \
  -e "ansible_host=$BOOTSTRAP_PUBLIC_IP"
```

`prepare-host.yml` creates the protected `/opt/morrowpal` deployment root.
`prepare-mysql.yml` installs the configuration needed for a future RDS
migration.

## 7. Create and prepare encrypted MySQL storage

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
  --query 'Changes[*].ResourceChange.{Action:Action,LogicalId:LogicalResourceId,Type:ResourceType,Replacement:Replacement}' \
  --region us-east-2
```

Confirm that the change set creates only the retained encrypted EBS volume and
its attachment, then execute it:

```bash
aws cloudformation execute-change-set \
  --stack-name morrowpal-prod-mysql-storage \
  --change-set-name initial-mysql-storage \
  --region us-east-2

aws cloudformation wait stack-create-complete \
  --stack-name morrowpal-prod-mysql-storage \
  --region us-east-2
```

Read the volume ID, format and mount it, and create the encrypted swap file:

```bash
MYSQL_VOLUME_ID="$(aws cloudformation describe-stacks \
  --stack-name morrowpal-prod-mysql-storage \
  --query 'Stacks[0].Outputs[?OutputKey==`VolumeId`].OutputValue' \
  --output text \
  --region us-east-2)"

ansible-playbook ./playbooks/prepare-storage.yml \
  -e "ansible_host=$BOOTSTRAP_PUBLIC_IP" \
  -e "morrowpal_mysql_volume_id=$MYSQL_VOLUME_ID"
```

The storage playbook refuses to format a volume that already contains a
filesystem.

## 8. Create runtime secrets

The secrets stack generates the MySQL application password, MySQL root
password, and JWT signing secret inside Secrets Manager. Do not retrieve or
print their values.

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
  --query 'Changes[*].ResourceChange.{Action:Action,LogicalId:LogicalResourceId,Type:ResourceType,Replacement:Replacement}' \
  --region us-east-2
```

Confirm that the change set creates three secrets and the scoped EC2 role
policy, then execute it:

```bash
aws cloudformation execute-change-set \
  --stack-name morrowpal-prod-runtime-secrets \
  --change-set-name initial-runtime-secrets \
  --region us-east-2

aws cloudformation wait stack-create-complete \
  --stack-name morrowpal-prod-runtime-secrets \
  --region us-east-2
```

At runtime, `asm-exec` resolves dynamic references through the instance role
and writes short-lived root-protected files under `/run` for Docker Compose.

## 9. Create the stable public IP

```bash
aws cloudformation create-change-set \
  --stack-name morrowpal-prod-public-ip \
  --change-set-name initial-public-ip \
  --change-set-type CREATE \
  --template-body file://./cloudformation/public-ip.yml \
  --parameters ParameterKey=InstanceId,ParameterValue="$PRODUCTION_INSTANCE_ID" \
  --region us-east-2

aws cloudformation wait change-set-create-complete \
  --stack-name morrowpal-prod-public-ip \
  --change-set-name initial-public-ip \
  --region us-east-2

aws cloudformation describe-change-set \
  --stack-name morrowpal-prod-public-ip \
  --change-set-name initial-public-ip \
  --query 'Changes[*].ResourceChange.{Action:Action,LogicalId:LogicalResourceId,Type:ResourceType,Replacement:Replacement}' \
  --region us-east-2
```

Confirm that it creates and associates only the Elastic IP, then execute it:

```bash
aws cloudformation execute-change-set \
  --stack-name morrowpal-prod-public-ip \
  --change-set-name initial-public-ip \
  --region us-east-2

aws cloudformation wait stack-create-complete \
  --stack-name morrowpal-prod-public-ip \
  --region us-east-2
```

Read the stable address from the stack outputs. Update `inventory.ini` if it
differs from the documented address.

## 10. Configure DNS and public TLS

Point these names to the stable IPv4 address and remove any AAAA records:

- `morrowpal.com`
- `api.morrowpal.com`
- `admin.morrowpal.com`
- `app.morrowpal.com`
- `www.morrowpal.com`
- `back.morrowpal.com`

Create the HTTP validation ingress rule used for initial issuance and renewal:

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
  --query 'Changes[*].ResourceChange.{Action:Action,LogicalId:LogicalResourceId,Type:ResourceType,Replacement:Replacement}' \
  --region us-east-2
```

Confirm that it creates only the Certbot HTTP ingress rule, then execute it:

```bash
aws cloudformation execute-change-set \
  --stack-name morrowpal-prod-http-validation-ingress \
  --change-set-name initial-http-validation-ingress \
  --region us-east-2

aws cloudformation wait stack-create-complete \
  --stack-name morrowpal-prod-http-validation-ingress \
  --region us-east-2
```

Obtain the certificate and enable renewal, replacing the example email:

```bash
ansible-playbook ./playbooks/prepare-tls.yml \
  -e morrowpal_certbot_email=admin@example.com
```

See [Production TLS](./tls.md) for architecture and renewal details.

## 11. Publish the initial images

Follow the publication sections in these component runbooks:

- [Update the backend](./update-backend.md)
- [Update the app](./update-app.md)

Record the resulting immutable tags as `BACKEND_TAG` and `APP_TAG`.

## 12. Deploy the production containers

```bash
ansible-playbook ./playbooks/deploy.yml \
  --check \
  --diff \
  -e morrowpal_image_tag=BACKEND_TAG \
  -e morrowpal_app_image_tag=APP_TAG

ansible-playbook ./playbooks/deploy.yml \
  -e morrowpal_image_tag=BACKEND_TAG \
  -e morrowpal_app_image_tag=APP_TAG
```

The systemd service resolves secrets at runtime, authenticates to ECR with the
instance role, pulls the immutable images, starts MySQL, waits for readiness,
starts the API, app, Envoy, and both job containers, and verifies the public
routes.

## 13. Verify the installation

```bash
ansible 01 -b -m command -a 'systemctl status morrowpal --no-pager'
ansible 01 -b -m command -a '/usr/local/sbin/morrowpal-service status'

curl --fail --show-error --silent https://api.morrowpal.com/ready
curl --fail --show-error --silent https://app.morrowpal.com/ready

ansible 01 -b -m command \
  -a 'systemctl status morrowpal-certbot-renew.timer --no-pager'

ansible 01 -b -m command -a 'certbot renew --dry-run'
```

Open `https://app.morrowpal.com` in a private browser window and test sign-in,
an API-backed action, refresh, local persistence, and sign-out.

After installation, use the component update runbooks for every release rather
than repeating this document.
