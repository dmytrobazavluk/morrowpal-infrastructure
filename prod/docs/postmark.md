# Postmark Operations

Postmark delivers production verification codes and delayed dispatch activity
notifications. This document records the long-lived production configuration
and its operational procedures.

For a new production environment, follow
[Install production from scratch](./install-from-scratch.md). For a routine
application release, follow [Update the backend](./update-backend.md).

## Production configuration

The `MorrowPal Production` Postmark server must have:

- the `morrowpal.com` sending domain verified through DKIM
- a verified custom Return-Path for `morrowpal.com`
- `MorrowPal <verification-code@morrowpal.com>` for verification codes
- `MorrowPal <notifications@morrowpal.com>` for dispatch notifications
- the default transactional message stream id `outbound`

Because the domain is verified, a separate sender signature for
either address is not required. The application uses a
Postmark Server API Token belonging to this server, not an Account API Token.
Inbound and broadcast streams are not used for application email.

The non-secret sender, stream, and timeout settings live in
`docker-compose.yml`. The backend owns verification-code and dispatch-notification
content. Dispatch notifications are sent only after their configurable queue
age has elapsed without a successful client synchronization.

## Secret ownership and runtime loading

The `morrowpal-prod-runtime-secrets` CloudFormation stack owns the retained
Secrets Manager secret `morrowpal/prod/postmark`. Its JSON field `serverToken`
contains the production Postmark Server API Token.

The EC2 instance role has narrowly scoped access to that secret. At service
startup, `asm-exec` resolves the dynamic reference
`{{resolve:secretsmanager:morrowpal/prod/postmark:SecretString:serverToken}}`
and writes a root-protected runtime file under `/run`. Docker mounts that file
into the API containers and the dispatch job container. The cleanup job does
not receive the token.

Create the secret through the CloudFormation procedure in
[Install production from scratch](./install-from-scratch.md). Enter or replace
the `serverToken` value through the AWS Secrets Manager console. Never retrieve
or print the value through the CLI or agent tools, and never place it in a
repository file, shell command, Ansible variable, or deployment log.

## Rotate the server token

Treat rotation as a planned backend deployment because running containers keep
their injected token until they are recreated.

1. Create a replacement Server API Token in the `MorrowPal Production` server
   while keeping the current token active.
2. Replace `serverToken` in `morrowpal/prod/postmark` through the AWS Secrets
   Manager console.
3. Refresh the host's root-protected runtime secrets without recreating any
   containers:

   ```bash
   ansible 01 -b -m command \
     -a '/usr/local/sbin/morrowpal-service refresh-secrets'
   ```

4. Deploy a fresh immutable backend tag using
   [Update the backend](./update-backend.md).
5. Complete the verification checks below.
6. Revoke the previous token in Postmark only after both API slots and the
   dispatch job have been recreated and delivery through the replacement token
   is confirmed.

Do not revoke the current token first. Doing so can interrupt email delivery
while existing API or dispatch job containers still use it.

## Verify delivery

After initial installation, token rotation, or a related backend change:

1. Confirm service and API readiness:

   ```bash
   ansible 01 -b -m command -a '/usr/local/sbin/morrowpal-service status'
   curl --fail --show-error --silent https://api.morrowpal.com/ready
   ```

2. Start a sign-up or sign-in request using an inbox you control.
3. Confirm the message arrives from
   `MorrowPal <verification-code@morrowpal.com>` and complete verification with
   the received code.
4. Check Postmark Activity for the accepted message.
5. When the change affects verification workflows, also exercise adding an
   email address and changing an account email address.
6. When the change affects dispatch notifications, allow a dispatch containing
   inbound activity to remain unsynchronized beyond the configured queue age
   and confirm that its notification arrives from
   `MorrowPal <notifications@morrowpal.com>` and is accepted by Postmark.

If Postmark rejects or cannot accept a message, the API returns `503`. The
verification request has already committed, and a retry creates a fresh request
and code.

## Troubleshooting

For delivery failures, check:

- backend logs for the delivery error and request identifier
- Postmark Activity and suppression records
- the server token type and the `outbound` message stream
- DKIM and custom Return-Path status for `morrowpal.com`
- that the configured From address belongs to the verified domain

Logs must not contain verification codes, recipient email addresses, or token
values. Diagnose secret access from metadata, IAM permissions, service status,
and error messages without retrieving the secret value.
