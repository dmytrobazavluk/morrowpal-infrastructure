# Firebase App Notification Operations

The dispatch worker sends privacy-safe app notifications through Firebase
Cloud Messaging. The API containers and cleanup worker do not receive Firebase
credentials.

Run local commands from `infrastructure`. Production writes, including secret
refresh and rotation, require completed staging validation, the final parity
audit, and explicit approval. Use the guarded deployment wrapper's production
dry run to validate the target before direct Ansible actions.

## Runtime configuration

- Provider: `firebase`
- Firebase project: `morrowpal`
- Credential file inside the dispatch container:
  `/run/secrets/firebase_service_account`
- AWS Secrets Manager secret: `morrowpal/prod/firebase-service-account`

The secret contains the complete Google service account JSON as its raw secret
string. Do not store that JSON in Git, a shell history, an environment file, or
an issue tracker.

## Initial setup and rotation

1. In Google Cloud, create or select a service account dedicated to MorrowPal
   notification delivery.
2. Grant only the permission required to create Firebase Cloud Messaging
   messages for the `morrowpal` project.
3. Create a JSON key only if workload identity federation is not yet available.
4. In the AWS console, replace the current value of
   `morrowpal/prod/firebase-service-account` with the complete JSON document.
5. Refresh the materialized runtime secrets without printing their values:

   ```bash
   ansible morrowpal_hosts -i environments/prod/inventory.ini \
     -e @environments/prod/vars.yml -b -m command \
     -a '/usr/local/sbin/morrowpal-service refresh-secrets'
   ```

6. Reconcile or redeploy the dispatch worker so it opens the refreshed
   credential file.

During rotation, add the new key first, update the AWS secret, refresh and
restart the dispatch worker, verify delivery, and only then revoke the old key.
Never retrieve the AWS secret value through the CLI.
