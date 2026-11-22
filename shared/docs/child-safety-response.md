# Child Safety Incident Response

This runbook is the operating process behind MorrowPal's published
[Child Safety Standards](https://morrowpal.com/child-safety/). It applies to
reports of suspected underage use, grooming, sextortion, child sex trafficking,
child sexual abuse material (CSAM), and other child sexual abuse or exploitation
(CSAE).

This document is an operational baseline, not legal advice. The designated
child safety contact must obtain jurisdiction-specific legal advice when a
report may trigger a preservation or reporting obligation.

## Ownership and readiness

- **Primary owner:** the individual designated as MorrowPal's child safety
  point of contact in Google Play Console.
- **Monitored address:** `support@morrowpal.com`.
- **Backup owner:** a second person with access to the mailbox and this runbook,
  when one is available.
- **Review cadence:** check new in-app reports and the monitored mailbox at
  least twice every day. Review a child-safety notification immediately.
- **Access:** limit report details, correspondence, account records, and
  incident notes to people who need them for safety, legal, or operational
  work.

The primary owner must be able to explain MorrowPal's adults-only rule,
prohibited conduct, in-app reporting and blocking, report review, account and
content restrictions, evidence handling, and authority-reporting process.

Do not certify compliance in a store until the primary owner has accepted this
role, can access production reports, and has completed the pre-publication
checklist at the end of this document.

## Intake channels

Reports can arrive through:

1. The in-app **Block & Report** flow with the reason
   `childSafetyOrExploitation`.
2. Email to `support@morrowpal.com`.
3. A notification from Google Play, a hosting provider, NCMEC, law enforcement,
   or another authorized organization.

The in-app flow stores the report identifier, reporting and reported account
identifiers, interaction identifier, reason, optional details, and creation
time. It also blocks the reported account for the reporting user.

## Safe handling rules

1. Do not ask a user to email, forward, or upload suspected CSAM.
2. Do not download, duplicate, forward, print, or place suspected CSAM in an
   ordinary ticket, document, chat, or email.
3. Do not broadly search user content or personally investigate beyond what is
   necessary to triage the report and follow legal obligations.
4. Record identifiers and metadata rather than copying content whenever
   possible.
5. Keep all incident notes in a restricted location. Do not place sensitive
   content or user-supplied report details in application logs.
6. Preserve potentially relevant server-side records without altering them
   when a legal or authority report may be required. Restrict user access to
   prohibited content without destroying evidence needed for a report.

## Triage

Assign one severity as soon as the report is reviewed:

- **P0 - imminent danger:** credible indication that a child is currently in
  danger, an active assault is occurring, or delay could cause immediate harm.
- **P1 - apparent exploitation:** apparent CSAM, grooming, sextortion, sexual
  solicitation of a minor, child sex trafficking, or an attempt to facilitate
  any of those activities.
- **P2 - suspected underage account:** indication that an account belongs to a
  person under 18 without an accompanying P0 or P1 concern.
- **P3 - other safety issue:** the report does not indicate a child-safety
  matter and should follow the ordinary moderation process.

When information is incomplete, choose the more protective severity until the
designated contact can assess it. Do not promise the reporting user a specific
outcome or disclose another user's account status.

## Response steps

### P0 - imminent danger

1. Contact the emergency service or law-enforcement agency able to respond in
   the relevant location. If the location is unknown, contact the appropriate
   national reporting body for routing guidance.
2. Preserve relevant account, correspondence, report, IP, and timestamp records.
3. Prevent further contact and restrict access to the implicated account or
   content when doing so will not increase danger or conflict with authority
   instructions.
4. Submit any required NCMEC or regional-authority report as soon as reasonably
   possible.
5. Record the authority, time, reference number, and actions taken.

### P1 - apparent exploitation

1. Restrict the reported account from further exchanges while the report is
   assessed.
2. Preserve the original server-side records and relevant metadata. Do not make
   unnecessary copies.
3. Determine which reporting obligation applies with qualified legal guidance.
   For a US-based electronic service provider, use the registered Electronic
   Service Provider path to NCMEC's CyberTipline when required by 18 U.S.C.
   2258A. Use the appropriate regional authority when another jurisdiction
   applies.
4. Submit the report within the legally required period and retain its reference
   number. Follow instructions from NCMEC or law enforcement about preservation
   and disclosure.
5. Close or continue restricting the account, remove access to prohibited
   content, and document the enforcement decision.

### P2 - suspected underage account

1. Restrict matching, invitations, and correspondence for the account while it
   is reviewed.
2. Assess available account and report information without requesting sensitive
   identity documents unless a reviewed age-assurance process has been adopted.
3. Close an account determined to belong to a person under 18 and handle its
   personal information under the Privacy Policy and applicable law.
4. Escalate to P0 or P1 immediately if exploitation or danger is indicated.

### P3 - other safety issue

Apply the ordinary MorrowPal moderation response, which may include warning,
restriction, suspension, or account closure. Record that the report was
reviewed and why it was classified outside the child-safety process.

## Authority reporting

- US reporting resource: [NCMEC CyberTipline](https://report.cybertip.org/).
- NCMEC Electronic Service Provider registration contact:
  `espteam@ncmec.org`.
- Google Play requires a process to report confirmed CSAM to NCMEC or the
  relevant regional authority. Applicable law may require reporting apparent or
  suspected exploitation before MorrowPal can independently confirm it.
- If more than one country may have jurisdiction, obtain legal guidance rather
  than delaying an urgent report.

The designated contact must not treat this runbook as a substitute for advice
about whether MorrowPal is an electronic communication service or remote
computing service, what facts trigger a report, how long records must be
preserved, or what information may lawfully be disclosed.

## Incident record

Create one restricted incident record for every P0, P1, or P2 report. Record:

- internal incident identifier;
- source and received time;
- MorrowPal report, account, correspondence, or offer identifiers;
- severity and the reason for that classification;
- reviewer and review time;
- access restrictions and enforcement actions;
- records preserved and their authorized location;
- legal guidance obtained, if any;
- authority contacted, submission time, and reference number;
- follow-up requests and responses; and
- closure decision, owner, and time.

Do not paste suspected CSAM or unnecessary user content into the incident
record.

## Routine review of in-app reports

Until a restricted moderation dashboard or automatic alert is deployed, the
designated contact must run the following read-only query at least twice daily
through the approved production database administration path. Replace the
timestamp below with the UTC time of the last successfully completed review.
After an interruption, use the last recorded review time rather than an
arbitrary recent window so that no reports are skipped.

```sql
SELECT
    account_report_id,
    reporting_account_id,
    reported_account_id,
    correspondence_id,
    offer_id,
    reason,
    details,
    created_at
FROM account_report
WHERE created_at >= '2026-09-17 00:00:00' -- last successful review time in UTC
ORDER BY
    CASE reason
        WHEN 'childSafetyOrExploitation' THEN 0
        WHEN 'sexualContent' THEN 1
        WHEN 'threatsOrViolence' THEN 2
        ELSE 3
    END,
    created_at ASC,
    account_report_id ASC;
```

Review in a restricted terminal. Do not export results to an unmanaged device.
Record the query completion time, reviewed report identifiers, and next review
owner in the restricted incident log. The incident log is the review record;
the application database currently does not store moderation status.

## Post-incident review

After closing a P0 or P1 incident:

1. Confirm all required reports and follow-ups were completed.
2. Confirm account and content restrictions remain effective.
3. Review whether the report reason, user guidance, monitoring, or retention
   process needs improvement.
4. Update the public standards or this runbook if practices changed.
5. Keep the incident record only as long as required for safety, legal,
   enforcement, and dispute-resolution purposes.

## Pre-publication certification checklist

Complete every item before checking Google Play's child-safety certifications:

- [ ] Publish `https://morrowpal.com/child-safety/` and confirm it loads without authentication.
- [ ] Submit and retrieve a production in-app `Child safety or exploitation` report.
- [ ] Confirm the designated contact can access new production reports.
- [ ] Put twice-daily report reviews on the designated contact's operating schedule.
- [ ] Confirm `support@morrowpal.com` is monitored and protected with strong authentication.
- [ ] Enter a real, prepared individual as the CSAM contact in Play Console.
- [ ] Determine with qualified counsel which national and regional reporting duties apply.
- [ ] If MorrowPal is a US-based covered provider, complete NCMEC Electronic Service Provider registration and test access to the reporting workflow.
- [ ] Create the restricted incident-log location and verify the designated contact can use it.
- [ ] Walk through one tabletop P0 scenario and record the test date and any corrective actions.
