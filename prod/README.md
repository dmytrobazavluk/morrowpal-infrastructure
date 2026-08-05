# Production EC2 Instances

## Instance 01

The private key is stored outside the infrastructure repository at
`../morrowpal-prod-01.pem`.

Connect to instance 01 over SSH:

```bash
ssh -i ../morrowpal-prod-01.pem ec2-user@3.14.79.64
```

The private key must only be readable by its owner. If needed, set its permissions before connecting:

```bash
chmod 400 ../morrowpal-prod-01.pem
```

From the `infrastructure` directory, verify Ansible connectivity:

```bash
cd /home/dmytro/work/morrowpal/infrastructure
ansible production -m ping
```

## Install Docker

Preview the playbook without changing the instance:

```bash
ansible-playbook prod/playbooks/install-docker.yml --check --diff
```

Apply the playbook:

```bash
ansible-playbook prod/playbooks/install-docker.yml
```
