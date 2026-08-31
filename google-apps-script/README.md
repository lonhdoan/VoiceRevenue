# Google Sheets sync — VoiceRevenue v0.2.0 (optional, $0)

VoiceRevenue works fully without Google Sheets. This setup is only for optional sync.

## Deploy/update the endpoint

1. Create/open the target Google Sheet.
2. Choose **Extensions → Apps Script**.
3. Replace the script with `Code.gs` from this folder and save.
4. Select function **`setup`**, click **Run**, and authorize it once. This stores the spreadsheet ID in Script Properties and creates `Transactions` if needed.
5. Choose **Deploy → New deployment → Web app** (or create a new version of the existing deployment).
6. Execute as the deploying user/owner.
7. Because VoiceRevenue has no Google OAuth client, the endpoint must be callable without interactive sign-in when your account/domain permits it.
8. Copy the production URL ending in `/exec` into VoiceRevenue Settings and run **Kiểm tra kết nối**.

Do not use `/dev`.

## v0.2.0 UPSERT behavior

`transaction_id` is the stable row key.

- New ID: append a row and return `action: "created"`.
- Existing ID: update that row in place and return `action: "updated"`.

This allows History edits on the iPhone to update the same Google Sheets row instead of producing a duplicate. Offline edits remain local/pending until the next successful sync.

## Notes

Google Apps Script/Sheets quotas and Workspace policies still apply. If your organization blocks anonymous Web Apps, keep VoiceRevenue local-only or use an account/domain policy that permits this zero-OAuth design.
