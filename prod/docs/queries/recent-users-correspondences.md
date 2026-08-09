# Recently Registered Users With Correspondences

Returns self-registered users created on or after a given UTC timestamp, their
correspondences, every other participant in each correspondence, and the total
number of letters in that correspondence.

The result contains one row per user, correspondence, and partner. If a
correspondence has multiple partners, its letter count is repeated for each
partner. A user without a correspondence is returned once with `NULL`
correspondence and partner fields and a letter count of `0`.

## Parameters

Set `@registered_after` to the inclusive lower bound for
`account.created_at`. Use `>` instead of `>=` in the final filter if a strict
instant is required. Set `@account_type` to `0` for self-registered accounts,
`1` for admin-managed accounts, or `NULL` to include all account types.

```sql
SET @registered_after = '2026-08-01 00:00:00';
SET @account_type = NULL;
WITH letter_counts AS (
    SELECT
        correspondence_id,
        COUNT(*) AS letter_count
    FROM letter
    GROUP BY correspondence_id
)
SELECT
    user_account.account_id AS user_id,
    CONCAT_WS(' | ', user_account.nickname, user_account.email) AS user_identity,
    CONCAT_WS(
        ' | ',
        CASE user_account.account_type
            WHEN 0 THEN 'self-registered'
            WHEN 1 THEN 'admin-managed'
            ELSE CONCAT('unknown type ', user_account.account_type)
        END,
        CONCAT('gender: ', COALESCE(user_account.gender, 'not set')),
        CONCAT('age: ', COALESCE(user_account.age_range, 'not set'))
    ) AS user_attributes,
    user_account.created_at AS user_registered_at,
    correspondence.correspondence_id,
    correspondence.mode AS correspondence_mode,
    correspondence.created_at AS correspondence_created_at,
    partner_account.account_id AS partner_id,
    partner_account.nickname AS partner_nickname,
    COALESCE(letter_counts.letter_count, 0) AS letter_count
FROM account AS user_account
LEFT JOIN correspondence_participant AS user_participation
    ON user_participation.account_id = user_account.account_id
LEFT JOIN correspondence
    ON correspondence.correspondence_id =
       user_participation.correspondence_id
LEFT JOIN correspondence_participant AS partner_participation
    ON partner_participation.correspondence_id =
       correspondence.correspondence_id
   AND partner_participation.account_id <> user_account.account_id
LEFT JOIN account AS partner_account
    ON partner_account.account_id = partner_participation.account_id
LEFT JOIN letter_counts
    ON letter_counts.correspondence_id =
       correspondence.correspondence_id
WHERE user_account.created_at >= @registered_after
  AND (@account_type IS NULL OR user_account.account_type = @account_type)
ORDER BY
    user_account.created_at,
    user_account.account_id,
    correspondence.created_at,
    partner_account.account_id;
```

`letter_count` includes every letter in the correspondence regardless of its
author or status. `user_identity` combines nickname and email, while
`user_attributes` combines the readable account type, gender, and age range.
