/**
 * VoiceRevenue Google Apps Script endpoint.
 * Deploy as a Web App owned by the user. No project-maintainer credentials are used.
 */
const SHEET_NAME = 'Transactions';

function doGet() {
  return json_({ ok: true, service: 'VoiceRevenue Apps Script' });
}

function doPost(e) {
  try {
    const body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    if (body.action === 'ping') return json_({ ok: true, pong: true });

    validate_(body);
    const sheet = getSheet_();
    if (isDuplicate_(sheet, body.transaction_id)) {
      return json_({ ok: true, duplicate: true, transaction_id: body.transaction_id });
    }

    sheet.appendRow([
      body.transaction_id,
      body.payment_at || '',
      body.amount_vnd,
      body.customer_name || '',
      body.product || '',
      body.payment_method || 'unknown',
      body.notes || '',
      body.created_at
    ]);
    return json_({ ok: true, duplicate: false, transaction_id: body.transaction_id });
  } catch (err) {
    return json_({ ok: false, error: String(err && err.message ? err.message : err) });
  }
}

function validate_(body) {
  if (!body.transaction_id || typeof body.transaction_id !== 'string') throw new Error('transaction_id is required');
  if (!Number.isInteger(body.amount_vnd) || body.amount_vnd < 0) throw new Error('amount_vnd must be a non-negative integer');
  if (!body.created_at || typeof body.created_at !== 'string') throw new Error('created_at is required');
}

function getSheet_() {
  const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
  let sheet = spreadsheet.getSheetByName(SHEET_NAME);
  if (!sheet) {
    sheet = spreadsheet.insertSheet(SHEET_NAME);
    sheet.appendRow(['transaction_id','payment_at','amount_vnd','customer_name','product','payment_method','notes','created_at']);
  }
  return sheet;
}

function isDuplicate_(sheet, transactionId) {
  const lastRow = sheet.getLastRow();
  if (lastRow < 2) return false;
  const values = sheet.getRange(2, 1, lastRow - 1, 1).getDisplayValues().flat();
  return values.indexOf(transactionId) !== -1;
}

function json_(object) {
  return ContentService.createTextOutput(JSON.stringify(object)).setMimeType(ContentService.MimeType.JSON);
}
