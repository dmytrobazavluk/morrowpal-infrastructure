# Remove a Correspondence and Its Related Records

Permanently removes one correspondence by `correspondence_id`, including all
of its letters, participant rows, its inferred accepted request offer, and
reports that reference either the correspondence or that offer.

This query is destructive and cannot be undone after `COMMIT`. In particular,
deleting an `account_report` removes moderation evidence. Take a database
backup, stop application writes, and review every preview result before
running the deletion statements.

## Parameter

Set `@correspondence_id` to the exact correspondence UUID to remove.

```sql
SET @correspondence_id = '00000000-0000-0000-0000-000000000000';

START TRANSACTION;

-- Lock and preview the correspondence. Stop if this returns no row or the
-- wrong row.
SELECT
    correspondence_id,
    request_id,
    mode,
    created_at
FROM correspondence
WHERE correspondence_id = @correspondence_id
FOR UPDATE;

DROP TEMPORARY TABLE IF EXISTS correspondence_removal_offer;
CREATE TEMPORARY TABLE correspondence_removal_offer (
    offer_id CHAR(36) NOT NULL PRIMARY KEY
);

-- The schema has no direct correspondence-to-offer reference. Infer accepted
-- offers from the request and its non-author correspondence participants.
INSERT INTO correspondence_removal_offer (offer_id)
SELECT DISTINCT offer.offer_id
FROM correspondence
JOIN correspondence_request AS request
    ON request.correspondence_request_id = correspondence.request_id
JOIN correspondence_participant AS recipient
    ON recipient.correspondence_id = correspondence.correspondence_id
   AND recipient.account_id <> request.account_id
JOIN correspondence_request_offer AS offer
   ON offer.request_id = correspondence.request_id
   AND offer.recipient_account_id = recipient.account_id
   AND offer.status = 2 -- ACCEPTED
WHERE correspondence.correspondence_id = @correspondence_id;

-- Preview every participant.
SELECT
    participant.account_id,
    participant.type AS participant_type,
    participant_account.account_type,
    participant_account.nickname,
    participant_account.email
FROM correspondence_participant AS participant
JOIN account AS participant_account
    ON participant_account.account_id = participant.account_id
WHERE participant.correspondence_id = @correspondence_id
ORDER BY participant.account_id;

-- Preview the inferred accepted offers. No row is expected if normal settled
-- offer cleanup has already run; stop if any returned row is unexpected.
SELECT offer.*
FROM correspondence_request_offer AS offer
JOIN correspondence_removal_offer AS removal_offer
    ON removal_offer.offer_id = offer.offer_id
ORDER BY offer.offer_id;

-- Preview the records that will be deleted with the correspondence.
SELECT COUNT(*) AS letters
FROM letter
WHERE correspondence_id = @correspondence_id;

SELECT
    account_report_id,
    reporting_account_id,
    reported_account_id,
    reason,
    created_at
FROM account_report
WHERE correspondence_id = @correspondence_id
   OR offer_id IN (
       SELECT offer_id
       FROM correspondence_removal_offer
   )
ORDER BY created_at, account_report_id;

DELETE FROM account_report
WHERE correspondence_id = @correspondence_id
   OR offer_id IN (
       SELECT offer_id
       FROM correspondence_removal_offer
   );

DELETE FROM correspondence_request_offer
WHERE offer_id IN (
    SELECT offer_id
    FROM correspondence_removal_offer
);

DELETE FROM letter
WHERE correspondence_id = @correspondence_id;

DELETE FROM correspondence_participant
WHERE correspondence_id = @correspondence_id;

DELETE FROM correspondence
WHERE correspondence_id = @correspondence_id;

-- Every count must be 0 before committing. Keep these as separate statements;
-- MySQL cannot reopen a temporary table multiple times in one statement.
SELECT COUNT(*) AS remaining_reports
FROM account_report
WHERE correspondence_id = @correspondence_id
   OR offer_id IN (
       SELECT offer_id
       FROM correspondence_removal_offer
   );

SELECT COUNT(*) AS remaining_offers
FROM correspondence_request_offer
WHERE offer_id IN (
    SELECT offer_id
    FROM correspondence_removal_offer
);

SELECT COUNT(*) AS remaining_letters
FROM letter
WHERE correspondence_id = @correspondence_id;

SELECT COUNT(*) AS remaining_participants
FROM correspondence_participant
WHERE correspondence_id = @correspondence_id;

SELECT COUNT(*) AS remaining_correspondences
FROM correspondence
WHERE correspondence_id = @correspondence_id;

DROP TEMPORARY TABLE correspondence_removal_offer;

COMMIT;
```

If any preview is unexpected, run `ROLLBACK` instead of the deletion
statements or `COMMIT`.

The deletion intentionally retains:

- The originating `correspondence_request`, because a request may own other
  correspondences and remains useful request history.
- `account_block` rows, because blocks are account-level safety state rather
  than correspondence-owned data.
- Participant accounts and their availability, session, and dispatch state.

Because the schema has no direct offer-to-correspondence reference, the script
infers accepted offers from the shared request ID and the non-author
participants. Review the inferred-offer result before deleting anything. The
script intentionally does not remove pending, declined, or expired offers.

Deleting an accepted offer reduces the request's recorded acceptance count. If
the originating request is still pending fulfillment, offer reconciliation can
create replacement offers and may offer the request to the former recipient
again.
