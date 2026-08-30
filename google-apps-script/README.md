# Google Sheets sync (optional, $0)

VoiceRevenue works without Google Sheets. This setup is only for optional sync.

## Deploy the endpoint

1. Create/open the Google Sheet you want to use.
2. In that Sheet choose **Extensions → Apps Script** so the script is bound to that Sheet.
3. Replace the editor contents with `Code.gs` from this folder and save.
4. In the Apps Script function selector choose **`setup`**, click **Run**, and authorize it. Run `setup()` once. It stores the target spreadsheet ID in Script Properties and creates the `Transactions` tab if needed.
   - This step is required because Google documents that bound-script active-document methods such as `getActiveSpreadsheet()` are not available when the script runs as a Web App. The Web App therefore reopens the saved spreadsheet by ID.
5. Choose **Deploy → New deployment**.
6. Select deployment type **Web app**.
7. Configure the Web App to **execute as the deploying user/owner**.
8. VoiceRevenue does not implement Google OAuth, so the Web App must be accessible without an interactive Google sign-in. In Apps Script/API terminology this is anonymous access (`ANYONE_ANONYMOUS`) when that option is available for your account/domain.
9. Deploy and copy the **versioned Web App URL ending in `/exec`**.
10. In VoiceRevenue open **Settings → Google Sheets**, paste the URL and tap **Kiểm tra kết nối**.

Do **not** use a `/dev` Test deployment URL. Google documents `/dev` URLs as editor-only test URLs; VoiceRevenue deliberately rejects them.

## What connection test verifies

v0.1.1 sends `{"action":"ping"}` and requires a JSON response confirming:

- `ok: true`
- `pong: true`
- `service: "VoiceRevenue"`
- `sheet_access: true`

The ping actually opens the stored spreadsheet and opens/creates the `Transactions` sheet, so a green connection status means the Web App can really access the Sheet.

## Sync behavior

The script creates a `Transactions` tab if needed. Duplicate `transaction_id` values are treated as success and are not appended twice.

Google Apps Script and Google Sheets are Google-hosted services with their own quotas and organizational policies. Some Google Workspace administrators may disable anonymous Web Apps. If your account does not offer an anonymous-access deployment option, this zero-OAuth sync design cannot work with that account; use a Google account that permits it or keep VoiceRevenue local-only.
