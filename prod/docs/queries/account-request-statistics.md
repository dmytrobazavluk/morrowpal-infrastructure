# Request Statistics for an Account

Returns every correspondence request created by a specific account, its open,
expired, and accepted offer counts, and its correspondence counts grouped by
the number of letters they contain.

The result contains exactly one row per request.

## Parameter

Set `@account_id` to the exact account UUID to inspect.

```sql
SET @account_id = '00000000-0000-0000-0000-000000000000';

WITH selected_requests AS (
    SELECT
        correspondence_request_id,
        CAST(
            JSON_UNQUOTE(JSON_EXTRACT(request_payload, '$.recipientCount'))
            AS UNSIGNED
        ) AS target,
        created_at
    FROM correspondence_request
    WHERE account_id = @account_id
),
offer_counts AS (
    SELECT
        request_id,
        COUNT(CASE WHEN status = 1 THEN 1 END) AS open_offer_count,
        COUNT(CASE WHEN status = 4 THEN 1 END) AS expired_offer_count,
        COUNT(CASE WHEN status = 2 THEN 1 END) AS accepted_offer_count
    FROM correspondence_request_offer
    GROUP BY request_id
),
letter_counts AS (
    SELECT
        correspondence_id,
        COUNT(*) AS letter_count
    FROM letter
    GROUP BY correspondence_id
),
correspondence_statistics AS (
    SELECT
        correspondence.request_id,
        COUNT(CASE
            WHEN COALESCE(letter_counts.letter_count, 0) = 0 THEN 1
        END) AS zero_letter_correspondence_count,
        COUNT(CASE
            WHEN letter_counts.letter_count = 1 THEN 1
        END) AS one_letter_correspondence_count,
        COUNT(CASE
            WHEN letter_counts.letter_count >= 2 THEN 1
        END) AS two_or_more_letter_correspondence_count
    FROM correspondence
    LEFT JOIN letter_counts
        ON letter_counts.correspondence_id = correspondence.correspondence_id
    WHERE correspondence.request_id IS NOT NULL
    GROUP BY correspondence.request_id
)
SELECT
    selected_requests.correspondence_request_id AS request_id,
    selected_requests.created_at AS request_created_at,
    selected_requests.target,
    COALESCE(offer_counts.open_offer_count, 0) AS open_offer_count,
    COALESCE(offer_counts.expired_offer_count, 0) AS expired_offer_count,
    COALESCE(offer_counts.accepted_offer_count, 0) AS accepted_offer_count,
    COALESCE(
        correspondence_statistics.zero_letter_correspondence_count,
        0
    ) AS zero_letter_correspondence_count,
    COALESCE(
        correspondence_statistics.one_letter_correspondence_count,
        0
    ) AS one_letter_correspondence_count,
    COALESCE(
        correspondence_statistics.two_or_more_letter_correspondence_count,
        0
    ) AS two_or_more_letter_correspondence_count
FROM selected_requests
LEFT JOIN offer_counts
    ON offer_counts.request_id =
       selected_requests.correspondence_request_id
LEFT JOIN correspondence_statistics
    ON correspondence_statistics.request_id =
       selected_requests.correspondence_request_id
ORDER BY
    selected_requests.created_at,
    selected_requests.correspondence_request_id;
```

Offer counts describe rows currently present in
`correspondence_request_offer`, not lifetime offer totals. The reconciliation
job deletes unreported settled offers for fulfilled requests and retains
accepted offers only for a limited period. Consequently, an older request can
have correspondences but report zero retained or accepted offers. The database
does not currently retain enough history to reconstruct how many offers were
ever created or accepted.

Rows are ordered by `request_created_at` from oldest to newest, with request ID
as a deterministic tie-breaker. `target` is the request's desired recipient
count from `request_payload.recipientCount`. Offer status `1` means open
(pending), `2` means accepted, and `4` means expired. Declined offers, which
have status `3`, are not included in any offer count. Each correspondence
bucket includes every letter regardless of author or status. A one-letter
correspondence normally represents an accepted offer that has not received a
response. The zero-letter bucket is a sanity check, because accepting an offer
creates the correspondence and its first letter in the same transaction. If
the account has no requests, the query returns no rows.
