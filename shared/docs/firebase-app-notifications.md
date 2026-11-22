# Firebase App Notification Operations

The dispatch worker sends privacy-safe app notifications through Firebase
Cloud Messaging. The API containers and cleanup worker do not receive Firebase
credentials.

Run local commands from `infrastructure`. Production writes, including secret
refresh and rotation, require completed staging validation, the final parity
audit, and explicit approval. Use the guarded deployment wrapper's production
dry run to validate the target before direct Ansible actions.

## Environment selection

Use a dedicated notification service account in each environment's Firebase
project. Never use production credentials or device registrations in staging.

| Environment | Firebase project | AWS Region | AWS secret |
| --- | --- | --- | --- |
| `staging` | `morrowpal-staging` | `us-east-1` | `morrowpal/staging/firebase-service-account` |
| `prod` | `morrowpal` | `us-east-2` | `morrowpal/prod/firebase-service-account` |

Confirm the current bindings in `environments/<environment>/vars.yml` before
making changes. Select the environment explicitly and preview the validated
target; this command performs no deployment:

```bash
ENVIRONMENT=staging # Set explicitly to staging or prod.
case "$ENVIRONMENT" in
  staging) CONFIRMATION=() ;;
  prod) CONFIRMATION=(--confirm-production) ;;
  *) printf 'Select staging or prod explicitly.\n' >&2; exit 1 ;;
esac
shared/scripts/deploy-images.sh "$ENVIRONMENT" infrastructure "${CONFIRMATION[@]}" --dry-run
```

Production selection requires the approval described above. Start staging
through its [lifecycle wrapper](../../environments/staging/README.md) before
host operations if it is stopped.

## Runtime configuration

- Provider: `firebase`
- Firebase project: the selected environment's project above
- Credential file inside the dispatch container:
  `/run/secrets/firebase_service_account`
- AWS Secrets Manager secret: the selected environment's secret above

The secret contains the complete Google service account JSON as its raw secret
string. Do not store that JSON in Git, a shell history, an environment file, or
an issue tracker.

The frontend's public Firebase settings are separate from this server credential.
They live in the sibling frontend repository under
`config/firebase/<environment>/`. The shared deployment reads `build.json` and
`web.json` there. Follow the [app update guide](./update-app.md) for deployment
and runtime-configuration checks.

## Initial setup and rotation

1. In Google Cloud, create or select a service account dedicated to MorrowPal
   notification delivery in the selected environment's project.
2. Grant only the permission required to create Firebase Cloud Messaging
   messages for that project.
3. Create a JSON key only if workload identity federation is not yet available.
4. In the AWS console, select the environment's account and Region, then set
   its Firebase secret from the table above to the complete JSON document.
5. Refresh the materialized runtime secrets without printing their values:

   ```bash
   ansible morrowpal_hosts -i "environments/$ENVIRONMENT/inventory.ini" \
     -e "@environments/$ENVIRONMENT/vars.yml" -b -m command \
     -a '/usr/local/sbin/morrowpal-service refresh-secrets'
   ```

6. Recreate the dispatch worker under the reviewed deployment procedure so it
   opens the refreshed credential file. An unchanged-tag deployment can keep
   the existing worker; successful reconciliation alone does not prove it
   loaded the new credential. Confirm the worker was replaced.

During rotation, add the new key first, update the AWS secret, refresh and
restart the dispatch worker, verify delivery, and only then revoke the old key.
Never retrieve the AWS secret value through the CLI.

## Delivery verification

Use a controlled account and client for the selected environment. Confirm its
public API/Firebase settings, enable notifications, and verify registration.
Then observe a notification for eligible new mail through the normal application
dispatch flow. Registration, readiness and a provider-console message alone do
not verify application delivery. Do not change scheduling data merely to speed
up the test. Record delivery as pending until it is observed.

The refactor's browser-delivery check remains explicitly deferred and unverified,
as recorded in the [completion record](./staging-production-refactor-completion.md).
