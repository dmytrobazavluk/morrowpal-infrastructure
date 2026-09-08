# Correspondences and Participants for an Account

Returns every correspondence containing a specific account and every
participant in each correspondence. The result contains one row per
correspondence and participant, ordered by correspondence creation time and
participant account ID. Each row includes both the correspondence's total
letter count and the number authored by that participant.

## Parameter

Set `@account_id` to the exact account UUID to inspect.

```sql
SET @account_id = '00000000-0000-0000-0000-000000000000';

WITH correspondence_letter_counts AS (
    SELECT
        correspondence_id,
        COUNT(*) AS letter_count
    FROM letter
    GROUP BY correspondence_id
),
     participant_letter_counts AS (
         SELECT
             correspondence_id,
             account_id,
             COUNT(*) AS letter_count
         FROM letter
         GROUP BY correspondence_id, account_id
     )
SELECT
    correspondence.correspondence_id,
    correspondence.created_at AS created_at,
    participant_account.nickname,
    participant_account.account_type as type,
    participant_account.email,
    CONCAT(COALESCE(correspondence_letter_counts.letter_count, 0), ', ', COALESCE(participant_letter_counts.letter_count, 0))
        AS letters_count,
    participant.account_id AS participant_account_id,
    participant.type AS participant_type,
    correspondence.mode
FROM correspondence
         JOIN correspondence_participant AS selected_account
              ON selected_account.correspondence_id = correspondence.correspondence_id
                  AND selected_account.account_id = @account_id
         JOIN correspondence_participant AS participant
              ON participant.correspondence_id = correspondence.correspondence_id
         JOIN account AS participant_account
              ON participant_account.account_id = participant.account_id
         LEFT JOIN correspondence_letter_counts
                   ON correspondence_letter_counts.correspondence_id =
                      correspondence.correspondence_id
         LEFT JOIN participant_letter_counts
                   ON participant_letter_counts.correspondence_id =
                      correspondence.correspondence_id
                       AND participant_letter_counts.account_id = participant.account_id
ORDER BY
    correspondence.created_at,
    correspondence.correspondence_id,
    participant.account_id;
```

`total_letter_count` includes every letter in the correspondence.
`participant_letter_count` includes every letter authored by the participant
described by that row. Both counts include letters regardless of status and
return `0` when no matching letters exist. If the account has no
correspondences, the query returns no rows.
