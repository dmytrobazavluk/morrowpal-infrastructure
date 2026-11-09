# Internal System Alerts

The backend publishes plain-text operational alerts to the SNS standard topic
`morrowpal-prod-system-alerts`. SNS emails confirmed team subscribers. Alerts
contain a timestamp and record/account IDs only; they contain no letter text,
report details, or user email addresses. Postmark remains the provider for user
email.

Publishing happens after the database transaction commits. The publish call has
a 3-second total timeout. A failure or timeout is logged by the backend and does
not change the committed action. There is no outbox or retry after the process
loses an alert. SNS handles delivery attempts after it accepts a publish.
Publishing is synchronous after commit, so each event can add up to 3 seconds
to the API response or dispatch job if SNS is unavailable. A report that also
creates a block makes two publish calls.

`APP_SYSTEM_ALERTS_PROVIDER` selects the alert publisher. Local development
defaults to `stub`, which writes alert details to the application log without
requiring AWS access. Production sets the provider to `sns`; the SNS publisher
uses `APP_SYSTEM_ALERTS_TOPIC_ARN` and the AWS default credential and region
provider chains.

## Create the topic and subscriptions

Run from `infrastructure/prod`. Confirm the AWS identity is production account
`384078510608` before any change. Provide one to three team email addresses as
CloudFormation parameters. Do not put recipient addresses into the template or
Docker Compose file.

```bash
cfn-lint --regions us-east-2 -t ../shared/cloudformation/system-alerts.yml
aws cloudformation validate-template \
  --template-body file://../shared/cloudformation/system-alerts.yml \
  --region us-east-2

MORROWPAL_PRIMARY_ALERT_EMAIL="$PRIMARY_ALERT_EMAIL" \
MORROWPAL_SECONDARY_ALERT_EMAIL="$SECONDARY_ALERT_EMAIL" \
MORROWPAL_TERTIARY_ALERT_EMAIL="$TERTIARY_ALERT_EMAIL" \
  ../shared/scripts/morrowpal-infrastructure-change-set.sh \
    prod system-alerts initial-system-alerts --confirm-production
```

Set `PRIMARY_ALERT_EMAIL` before running the change set. Set
`SECONDARY_ALERT_EMAIL` and `TERTIARY_ALERT_EMAIL` to empty strings when unused.
Review the change set before executing it. After it completes, compare the
`SystemAlertsTopicArn` stack output with `APP_SYSTEM_ALERTS_TOPIC_ARN` in
`../shared/docker-compose.yml`. Each recipient must confirm the SNS email subscription.
Check that each subscription is confirmed before enabling the backend image.
The stack also grants the EC2 role KMS data-key and decrypt permissions scoped
to this topic and the AWS-managed SNS key; encrypted-topic publishing requires
both those permissions and `sns:Publish`.

For updates, run the same guarded wrapper with a new change-set name. It detects
that the stack exists and creates an `UPDATE` change set. Review its replacement
and deletion actions and confirm any newly added email subscriptions.

## Verify

In a test environment, exercise each event once and confirm that the team inbox
receives the expected subject and IDs: account created, request created,
request dispatched, request accepted, request denied, reply created, reply
dispatched, report created, block created, and account deleted. A report that
creates a block generates both report and block alerts. Updating a draft or
retrying an already applied action generates no new alert.

If an expected alert is absent, inspect the API or job container logs for
`Failed to publish system alert`. A publish timeout or error can leave the
committed action without an alert. Also confirm that subscriptions are not
pending confirmation. SNS acceptance is not proof that email reached an inbox.
SNS email subscriptions can be suspended if a burst exceeds 10 messages per
second to an endpoint, so check subscription status if dispatch volume grows.
