# Postmark Operations

Postmark delivers verification codes and delayed dispatch activity notifications
in staging and production. Both environments share one Postmark account and
allowance, with separate servers, tokens, sender identities and message activity.

Run local commands from `infrastructure/aws`. Production writes, including secret
refresh and rotation, require completed staging validation, the final parity
audit, and explicit approval. Use the guarded deployment wrapper's production
dry run to validate the target before direct Ansible actions.

For a new environment, follow the
[installation guide](./install-from-scratch.md). For a routine
application release, follow [Update the backend](./update-backend.md).

## Environment selection

Use the server and secret belonging to the selected environment:

| Environment | Postmark server | AWS secret |
| --- | --- | --- |
| `staging` | `MorrowPal Staging` | `morrowpal/staging/postmark` |
| `prod` | `MorrowPal Production` | `morrowpal/prod/postmark` |

The current server, sender addresses, message stream and opt-out URL are defined
in `environments/<environment>/vars.yml`. Review `morrowpal_postmark_server_name`,
`morrowpal_postmark_message_stream`, `morrowpal_email_otp_from_address`,
`morrowpal_email_notification_from_address` and `morrowpal_email_dispatch_opt_out_url`.
Use staging test accounts and inboxes you control; staging has no recipient allowlist.

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
Start stopped staging through its [lifecycle wrapper](../../environments/staging/README.md)
before host operations. Select the matching account and Region from the overlay
when using the AWS console.

## Sender and runtime configuration

Verify the selected sender domain through DKIM and its custom Return-Path in
Postmark, or verify the required sender signatures. When the sending domain is
verified, separate signatures for its addresses are unnecessary. Keep staging
sender identities and opt-out URLs separate from production.

The application uses a Postmark Server API Token belonging to the selected
server, not an Account API Token. Both overlays use the transactional `outbound` stream.
Inbound and broadcast streams are not used for application email.

The non-secret sender and stream settings live in the selected overlay;
the shared runtime templates and `shared/docker-compose.yml` supply them to
containers. The backend owns verification-code and dispatch-notification
content. Dispatch notifications are sent only after their configurable queue
age has elapsed without a successful client synchronization.

## Secret ownership and runtime loading

The selected environment's runtime-secrets CloudFormation stack owns its retained
Postmark secret. Its JSON field `serverToken` contains that server's API token.

The EC2 instance role has narrowly scoped access to that secret. At service
startup, `asm-exec` resolves the selected environment's dynamic reference, either
`{{resolve:secretsmanager:morrowpal/staging/postmark:SecretString:serverToken}}` or
`{{resolve:secretsmanager:morrowpal/prod/postmark:SecretString:serverToken}}`,
and writes a root-protected runtime file under `/run`. Docker mounts that file
into the API containers and the dispatch job container. The cleanup job does
not receive the token.

Create the secret through the CloudFormation procedure in
[installation guide](./install-from-scratch.md). Enter or replace
the `serverToken` value through the AWS Secrets Manager console. Never retrieve
or print the value through the CLI or agent tools, and never place it in a
repository file, shell command, Ansible variable, or deployment log.

## Rotate the server token

Treat rotation as a planned backend deployment because running containers keep
their injected token until they are recreated.

1. Create a replacement Server API Token in the selected environment's server
   while keeping the current token active.
2. Replace `serverToken` in that environment's Postmark secret through the AWS
   Secrets Manager console, using its account and Region.
3. Refresh the host's root-protected runtime secrets without recreating any
   containers:

   ```bash
   ansible morrowpal_hosts -i "environments/$ENVIRONMENT/inventory.ini" \
     -e "@environments/$ENVIRONMENT/vars.yml" -b -m command \
     -a '/usr/local/sbin/morrowpal-service refresh-secrets'
   ```

4. Deploy the reviewed backend release using the
   [backend guide](./update-backend.md), recreating both API slots and the
   dispatch worker. An unchanged-tag deployment can keep existing containers;
   confirm replacement rather than relying on successful reconciliation alone.
5. Complete the verification checks below.
6. Revoke the previous token in Postmark only after both API slots and the
   dispatch job have been recreated and delivery through the replacement token
   is confirmed.

Do not revoke the current token first. Doing so can interrupt email delivery
while existing API or dispatch job containers still use it.

## Verify delivery

After initial installation, token rotation, or a related backend change:

1. Set `PUBLIC_API_URL` to `morrowpal_public_urls.api` from the selected overlay,
   then confirm service and API readiness:

   ```bash
   ansible morrowpal_hosts -i "environments/$ENVIRONMENT/inventory.ini" \
     -e "@environments/$ENVIRONMENT/vars.yml" -b -m command \
     -a '/usr/local/sbin/morrowpal-service status'
   curl --fail --show-error --silent "${PUBLIC_API_URL:?Set PUBLIC_API_URL from the selected overlay}/ready"
   ```

2. Start a sign-up or sign-in request using an inbox you control.
3. Confirm the message arrives from the selected overlay's verification-code
   sender and complete verification with the received code.
4. Check Activity in the selected Postmark server for the accepted message.
5. When the change affects verification workflows, also exercise adding an
   email address and changing an account email address.
6. When the change affects dispatch notifications, allow a dispatch containing
   inbound activity to remain unsynchronized beyond the configured queue age
   and confirm that its notification arrives from the selected overlay's
   notification sender and is accepted by its Postmark server.

If Postmark rejects or cannot accept a message, the API returns `503`. The
verification request has already committed, and a retry creates a fresh request
and code.

## Troubleshooting

For delivery failures, check:

- backend logs for the delivery error and request identifier
- Postmark Activity and suppression records
- the server token type and the `outbound` message stream
- DKIM and custom Return-Path status for the selected sender domain
- that the configured From address belongs to the verified domain

Logs must not contain verification codes, recipient email addresses, or token
values. Diagnose secret access from metadata, IAM permissions, service status,
and error messages without retrieving the secret value.
