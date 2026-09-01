# Production Database Administration

Run commands from `infrastructure/prod`.

Agents and automation must never retrieve or print secret values. Automated
database access must use Secrets Manager dynamic references resolved by
`asm-exec`. The DBeaver password-entry procedure below is a human-only GUI
workflow; do not automate it or paste the value into a terminal, chat, log, or
repository.

## Connect DBeaver to the production database

MySQL is not publicly exposed. Connect through the production EC2 instance's
SSH tunnel:

1. From `infrastructure/prod`, get the current MySQL container address:

   ```bash
   ssh -i ../../morrowpal-prod-01.pem ec2-user@3.12.65.199 \
     "sudo docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' morrowpal-mysql-1"
   ```

2. Create a MySQL connection in DBeaver with:
   - Host: the container address returned above
   - Port: `3306`
   - Database: `morrowpal`
   - Username: `morrowpal`
   - Password: the `password` field from the `morrowpal/prod/mysql` secret,
     obtained through the approved secret-access workflow; never place it in
     this repository or a shell command

   For this one-time human GUI setup, sign in to the AWS
   Console, select **us-east-2 (Ohio)**, open **Secrets Manager**, select
   `morrowpal/prod/mysql`, and choose **Retrieve secret value**. Copy only the
   `password` field into DBeaver, then clear the clipboard. Do not use the
   `morrowpal/prod/mysql-root` secret or print secrets with the AWS CLI.

3. In DBeaver's **SSH** settings, enable the tunnel and use:
   - Host: `3.12.65.199`
   - Port: `22`
   - User: `ec2-user`
   - Authentication: public key
   - Private key: `morrowpal-prod-01.pem`
4. Test the tunnel and database connection. Re-read the container address if a
   deployment has recreated the MySQL container.

The current `morrowpal` database user is write-capable. Use this connection for
careful, temporary inspection only and do not edit production data. Provision a
dedicated `SELECT`-only user before making DBeaver access routine.

For command-line access, use a dynamic reference so the password is resolved
only inside the database client process:

```bash
AWS_REGION=us-east-2 asm-exec -- mysql \
  --host=MYSQL_CONTAINER_ADDRESS \
  --port=3306 \
  --user=morrowpal \
  --password='{{resolve:secretsmanager:morrowpal/prod/mysql:SecretString:password}}' \
  morrowpal
```

Run that command only from a network location that can reach the private MySQL
container, such as the production host. Do not place the resolved value in a
shell variable.

## Queries

- [Recently registered users with correspondences](./queries/recent-users-correspondences.md)
- [Remove an account and its related records](./queries/remove-account.md)
