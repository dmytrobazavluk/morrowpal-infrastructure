# Existing Simple-Exchange Partners of an Account

Returns every account that shares a simple-exchange correspondence with a
specific account.

## Parameter

Set `@account_id` to the exact account UUID to inspect.

```sql
SET @account_id = '00000000-0000-0000-0000-000000000000';

SELECT DISTINCT
    partner_account.account_id AS partner_account_id,
    partner_account.account_type,
    partner_account.nickname,
    partner_account.email
FROM correspondence AS existing_correspondence
JOIN correspondence_participant AS selected_account
    ON selected_account.correspondence_id =
       existing_correspondence.correspondence_id
   AND selected_account.account_id = @account_id
JOIN correspondence_participant AS partner_participation
    ON partner_participation.correspondence_id =
       existing_correspondence.correspondence_id
   AND partner_participation.account_id <> @account_id
JOIN account AS partner_account
    ON partner_account.account_id = partner_participation.account_id
WHERE existing_correspondence.mode = 1
ORDER BY partner_account.account_id;
```

This follows the offer-reconciliation definition of an existing
simple-exchange partner: any other participant who shares a mode `1`
correspondence with the selected account.
