# Google Sheets sync (optional, $0)

1. Create a Google Sheet.
2. Open **Extensions → Apps Script**.
3. Replace the editor contents with `Code.gs` from this folder.
4. Save, then choose **Deploy → New deployment → Web app**.
5. Configure the deployment so the script executes as you and choose the access level appropriate for your own use case.
6. Copy the `/exec` Web App URL.
7. In VoiceRevenue: **Settings → Google Sheets → Apps Script Web App URL**.
8. Tap **Test Connection**.

The script creates a `Transactions` tab if it does not already exist. Duplicate `transaction_id` values are ignored.

Google Apps Script is a Google-hosted service with quotas. VoiceRevenue itself does not require Sheets and continues to work locally when sync is unavailable.
