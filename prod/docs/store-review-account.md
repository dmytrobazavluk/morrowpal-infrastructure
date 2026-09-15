# Store-review Account Operations

The application-store review account uses
`store-revirew@morrowpal.com`. Flyway migration
`V6__add_store_review_account.sql` creates the account and its dispatch state.

The account follows the normal sign-in API and client flow. Starting sign-in
creates a rate-limited request with the normal 15-minute lifetime, but the
backend hashes the configured fixed code instead of generating and emailing a
new code. The same configured code is therefore reusable across sign-in
requests without creating a permanently valid database request.

## Secret ownership

The `morrowpal-prod-runtime-secrets` CloudFormation stack owns the retained
Secrets Manager secret `morrowpal/prod/store-review`. Its JSON field `value`
contains the six-character verification code.

At service startup, `asm-exec` resolves
`{{resolve:secretsmanager:morrowpal/prod/store-review:SecretString:value}}` and
writes it to a root-protected runtime file. Docker mounts that file only into
the API containers, where it becomes
`APP_AUTH_STORE_REVIEW_VERIFICATION_CODE`. The value must use the same
six-character alphabet as ordinary verification codes.

Never retrieve or print the code through the CLI or agent tools, and never put
it in a migration, repository file, Ansible variable, or deployment log.

## First production rollout

1. Validate and update `morrowpal-prod-runtime-secrets` from
   `cloudformation/runtime-secrets.yml`. Review the change set and confirm that
   it adds only the retained store-review secret, its IAM policy reference,
   and its output.
2. In the AWS Secrets Manager console, replace the generated `value` in
   `morrowpal/prod/store-review` with the approved verification code.
3. Deploy the infrastructure changes using
   [Update production infrastructure](./update-infrastructure.md). This writes
   the root-protected runtime secret and adds it to both API containers.
4. Publish and deploy the backend using
   [Update the backend](./update-backend.md). Flyway creates the account before
   the new API begins serving traffic.
5. Start sign-in with the review email, enter the configured code, and confirm
   that the authenticated account opens successfully without an email being
   sent.

Do not deploy the updated service script before the CloudFormation secret and
its approved value exist. Secret refresh deliberately fails closed when any
required runtime secret is unavailable.

## Rotate the code

1. Replace `value` in `morrowpal/prod/store-review` through the AWS Secrets
   Manager console.
2. Refresh the host's root-protected runtime secrets:

   ```bash
   ansible 01 -b -m command \
     -a '/usr/local/sbin/morrowpal-service refresh-secrets'
   ```

3. Recreate both API slots through the normal rolling deployment workflow so
   they receive the replacement value.
4. Verify a new sign-in request with the replacement code. Requests created
   before rotation retain the previous code hash until they expire or are
   replaced by another sign-in request.
