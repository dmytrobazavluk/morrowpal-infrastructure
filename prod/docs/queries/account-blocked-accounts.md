# Accounts Blocked in Either Direction

Returns every account blocked by a specific account or blocking that account.

## Parameter

Set `@account_id` to the exact account UUID to inspect.

```sql
SET @account_id = '00000000-0000-0000-0000-000000000000';

SELECT DISTINCT
    blocked_account.account_id AS blocked_account_id,
    blocked_account.account_type,
    blocked_account.nickname,
    blocked_account.email
FROM account_block AS relationship
JOIN account AS blocked_account
    ON blocked_account.account_id = CASE
        WHEN relationship.blocker_account_id = @account_id
            THEN relationship.blocked_account_id
        ELSE relationship.blocker_account_id
    END
WHERE relationship.blocker_account_id = @account_id
   OR relationship.blocked_account_id = @account_id
ORDER BY blocked_account.account_id;
```

The account IDs are deduplicated, matching the set used during offer
reconciliation.
