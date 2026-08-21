# Replace the Production Host

Run commands from `infrastructure/prod`.

This procedure replaces EC2 while retaining the encrypted MySQL EBS volume and
stable Elastic IP. It causes downtime while MySQL storage is detached and the
public IP is moved.

Review [Install production from scratch](./install-from-scratch.md) for host
creation and preparation commands. Do not format the retained MySQL volume.

## 1. Create and prepare the replacement host

Create the replacement through `cloudformation/ec2.yml` with the same subnet,
security group, key pair, and EC2 instance profile. The subnet must remain in
`us-east-2c`, the Availability Zone of the retained volume.

Read the replacement instance ID and temporary address:

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

Install Docker, Docker Compose, the host directory, and MySQL configuration
against the temporary address. Do not run `prepare-storage.yml` yet.

## 2. Stop the old host

```bash
ansible 01 -b -m command -a 'systemctl stop morrowpal'
```

Confirm that `/var/lib/morrowpal` is unmounted on the old host before changing
the EBS attachment.

## 3. Detach the retained MySQL volume

Read the retained volume ID:

```bash
MYSQL_VOLUME_ID="$(aws cloudformation describe-stacks \
  --stack-name morrowpal-prod-mysql-storage \
  --query 'Stacks[0].Outputs[?OutputKey==`VolumeId`].OutputValue' \
  --output text \
  --region us-east-2)"
```

Create an update that removes only the attachment and records the replacement
instance as the next target:

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
  --query 'Changes[*].ResourceChange.{Action:Action,LogicalId:LogicalResourceId,Type:ResourceType,Replacement:Replacement}' \
  --region us-east-2
```

Confirm that it removes only `MysqlDataVolumeAttachment`, then execute it:

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

## 4. Attach the volume to the replacement

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
  --query 'Changes[*].ResourceChange.{Action:Action,LogicalId:LogicalResourceId,Type:ResourceType,Replacement:Replacement}' \
  --region us-east-2
```

Confirm that it creates only `MysqlDataVolumeAttachment`, then execute it:

```bash
aws cloudformation execute-change-set \
  --stack-name morrowpal-prod-mysql-storage \
  --change-set-name attach-mysql-volume \
  --region us-east-2

aws cloudformation wait stack-update-complete \
  --stack-name morrowpal-prod-mysql-storage \
  --region us-east-2
```

Mount the existing filesystem on the replacement host:

```bash
ansible-playbook ./playbooks/prepare-storage.yml \
  -e "ansible_host=$BOOTSTRAP_PUBLIC_IP" \
  -e "morrowpal_mysql_volume_id=$MYSQL_VOLUME_ID"
```

The playbook must detect the existing filesystem and must not format it.

## 5. Deploy and verify through the temporary address

Deploy the currently approved backend, app, and website tags to the replacement
host. Verify local service readiness before moving public traffic.

## 6. Move the stable Elastic IP

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
  --query 'Changes[*].ResourceChange.{Action:Action,LogicalId:LogicalResourceId,Type:ResourceType,Replacement:Replacement}' \
  --region us-east-2
```

Confirm that only the Elastic IP association changes, then execute it:

```bash
aws cloudformation execute-change-set \
  --stack-name morrowpal-prod-public-ip \
  --change-set-name move-production-public-ip \
  --region us-east-2

aws cloudformation wait stack-update-complete \
  --stack-name morrowpal-prod-public-ip \
  --region us-east-2
```

Update `inventory.ini` only if the stable address itself changed.

## 7. Final verification

```bash
ansible production -m ping
ansible 01 -b -m command -a '/usr/local/sbin/morrowpal-service status'
curl --fail --show-error --silent https://api.morrowpal.com/ready
curl --fail --show-error --silent https://app.morrowpal.com/ready
curl --fail --show-error --silent https://morrowpal.com/ready
```

Do not terminate the old host until the retained database, public routes, TLS
renewal timer, and application flows have been verified on the replacement.
