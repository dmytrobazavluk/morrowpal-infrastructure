# Remove an Account and Its Related Records

Permanently removes one account by `account_id`, including its sessions,
requests, safety records, availability and dispatch state, and every
correspondence in which it participates. Deleting a correspondence also
deletes its letters, reports, and all of its participant rows, including
records belonging to the other participants in that correspondence.

This query is destructive and cannot be undone after `COMMIT`. Take a database
backup, stop application writes, and review the preview result before running
the deletion statements.

## Parameter

Set `@account_id` to the exact account UUID to remove.

```sql
SET @account_id = '00000000-0000-0000-0000-000000000000';

START TRANSACTION;

-- Lock and preview the account. Stop if this returns no row or the wrong row.
SELECT
    account_id,
    nickname,
    email,
    account_type,
    created_at
FROM account
WHERE account_id = @account_id
FOR UPDATE;

DROP TEMPORARY TABLE IF EXISTS account_removal_correspondence;
CREATE TEMPORARY TABLE account_removal_correspondence (
    correspondence_id CHAR(36) NOT NULL PRIMARY KEY
);

INSERT INTO account_removal_correspondence (correspondence_id)
SELECT correspondence_id
FROM correspondence_participant
WHERE account_id = @account_id
UNION
SELECT correspondence.correspondence_id
FROM correspondence
JOIN correspondence_request
    ON correspondence_request.correspondence_request_id =
       correspondence.request_id
WHERE correspondence_request.account_id = @account_id;

-- Preview the destructive scope before continuing.
-- Keep these as separate statements. MySQL cannot reopen a temporary table
-- multiple times within one statement.
SELECT COUNT(*) AS correspondences
FROM account_removal_correspondence;

SELECT COUNT(*) AS letters
FROM letter
WHERE correspondence_id IN (
    SELECT correspondence_id
    FROM account_removal_correspondence
);

SELECT COUNT(*) AS participants
FROM correspondence_participant
WHERE correspondence_id IN (
    SELECT correspondence_id
    FROM account_removal_correspondence
);

SELECT COUNT(*) AS reports
FROM account_report
WHERE reporting_account_id = @account_id
   OR reported_account_id = @account_id
   OR correspondence_id IN (
       SELECT correspondence_id
       FROM account_removal_correspondence
   );

SELECT COUNT(*) AS blocks
FROM account_block
WHERE blocker_account_id = @account_id
   OR blocked_account_id = @account_id;

DELETE FROM account_report
WHERE reporting_account_id = @account_id
   OR reported_account_id = @account_id
   OR correspondence_id IN (
       SELECT correspondence_id
       FROM account_removal_correspondence
   );

DELETE FROM letter
WHERE correspondence_id IN (
    SELECT correspondence_id
    FROM account_removal_correspondence
);

DELETE FROM correspondence_participant
WHERE correspondence_id IN (
    SELECT correspondence_id
    FROM account_removal_correspondence
);

DELETE FROM correspondence
WHERE correspondence_id IN (
    SELECT correspondence_id
    FROM account_removal_correspondence
);

DELETE FROM correspondence_request
WHERE account_id = @account_id;

DELETE FROM account_block
WHERE blocker_account_id = @account_id
   OR blocked_account_id = @account_id;

DELETE FROM account_availability_rule
WHERE account_id = @account_id;

DELETE FROM account_email_request
WHERE account_id = @account_id;

DELETE FROM session_request
WHERE account_id = @account_id;

DELETE FROM device_session
WHERE account_id = @account_id;

DELETE FROM account_dispatch_state
WHERE account_id = @account_id;

DELETE FROM account
WHERE account_id = @account_id;

-- This must return 0 before committing.
SELECT COUNT(*) AS remaining_accounts
FROM account
WHERE account_id = @account_id;

DROP TEMPORARY TABLE account_removal_correspondence;

COMMIT;
```

If either preview is unexpected, run `ROLLBACK` instead of the deletion
statements or `COMMIT`.

The query intentionally retains `email_otp_rate_limit` rows. That table is
email-scoped anti-abuse state and has no account relationship. It also does not
delete `account_request` rows, which represent unverified registration
attempts and have no `account_id`.
