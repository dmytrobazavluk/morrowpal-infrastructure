# Store-review Account Operations

Run local commands from `infrastructure/aws`. Production writes require completed
staging validation, the final parity audit, and explicit approval. Use the
guarded deployment wrapper's production dry run to validate the target before
direct Ansible actions.

## Environment selection

The review identity is configured by `morrowpal_store_review_email` in the
selected overlay. Use only staging test access in staging; store submissions
use the production account.

| Environment | Review email | AWS secret |
| --- | --- | --- |
| `staging` | `store-review@staging.morrowpal.com` | `morrowpal/staging/store-review` |
| `prod` | `store-review@morrowpal.com` | `morrowpal/prod/store-review` |

Select the environment explicitly and preview the guarded target:

```bash
ENVIRONMENT=staging # Set explicitly to staging or prod.
case "$ENVIRONMENT" in
  staging) CONFIRMATION=() ;;
  prod) CONFIRMATION=(--confirm-production) ;;
  *) printf 'Select staging or prod explicitly.\n' >&2; exit 1 ;;
esac
shared/scripts/deploy-images.sh "$ENVIRONMENT" infrastructure "${CONFIRMATION[@]}" --dry-run
```

The preview performs no deployment. Production requires the approval above.
Use the selected overlay's AWS account and Region in the AWS console. Start
staging through its [lifecycle wrapper](../../environments/staging/README.md)
before host operations if it is stopped.

## Sign-in behavior

The production application-store review account uses
`store-review@morrowpal.com`. Flyway migration
`V6__add_store_review_account.sql` creates the account and its dispatch state,
and `V7__correct_store_review_email.sql` corrects the original email typo.
Those migrations seed the production address. Changing the staging overlay
does not rewrite that seeded row; verify that the configured staging review
account exists in the staging database before testing it.

The account follows the normal sign-in API and client flow. Starting sign-in
creates a rate-limited request with the normal 15-minute lifetime, but the
backend hashes the configured fixed code instead of generating and emailing a
new code. The same configured code is therefore reusable across sign-in
requests without creating a permanently valid database request.

## Secret ownership

The selected environment's runtime-secrets CloudFormation stack owns its retained
store-review secret from the table above. Its JSON field `value`
contains the six-character verification code.

At service startup, `asm-exec` resolves
either `{{resolve:secretsmanager:morrowpal/staging/store-review:SecretString:value}}`
or `{{resolve:secretsmanager:morrowpal/prod/store-review:SecretString:value}}` and
writes it to a root-protected runtime file. Docker mounts that file only into
the API containers, where it becomes
`APP_AUTH_STORE_REVIEW_VERIFICATION_CODE`. The value must use the same
six-character alphabet as ordinary verification codes.

Never retrieve or print the code through the CLI or agent tools, and never put
it in a migration, repository file, Ansible variable, or deployment log.

## Provision or verify the selected configuration

1. Check whether the retained store-review secret already exists. If resource
   changes are required, use the guarded infrastructure change-set wrapper's
   `runtime-secrets` kind for the selected environment, adding
   `--confirm-production` for production. It uses
   `shared/cloudformation/runtime-secrets.yml`. Review only the intended secret,
   scoped IAM, and output changes. Do not recreate an existing secret or rotate
   its value merely to follow this guide.
2. In the AWS Secrets Manager console, replace the generated `value` in
   the selected store-review secret with the approved verification code.
3. Deploy the infrastructure changes using
   [infrastructure guide](./update-infrastructure.md). This writes
   the root-protected runtime secret and adds it to both API containers.
4. Publish and deploy the backend using
   [backend guide](./update-backend.md). Confirm the selected review account is
   present before testing sign-in.
5. Start sign-in with the review email, enter the configured code, and confirm
   that the authenticated account opens successfully without an email being
   sent.

Do not deploy the updated service script before the CloudFormation secret and
its approved value exist. Secret refresh deliberately fails closed when any
required runtime secret is unavailable.

## Rotate the code

1. Replace `value` in the selected environment's store-review secret through
   the AWS Secrets Manager console using its account and Region.
2. Refresh the host's root-protected runtime secrets:

   ```bash
   ansible morrowpal_hosts -i "environments/$ENVIRONMENT/inventory.ini" \
     -e "@environments/$ENVIRONMENT/vars.yml" -b -m command \
     -a '/usr/local/sbin/morrowpal-service refresh-secrets'
   ```

3. Recreate both API slots through the normal rolling deployment workflow so
   they receive the replacement value.
4. Verify a new sign-in request with the replacement code. Requests created
   before rotation retain the previous code hash until they expire or are
   replaced by another sign-in request.
