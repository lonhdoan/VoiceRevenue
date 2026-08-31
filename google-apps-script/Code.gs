/**
 * VoiceRevenue Google Apps Script endpoint v0.2.0.
 * Deploy as a Web App owned by the user. No project-maintainer credentials are used.
 * Transactions are UPSERTed by transaction_id so local History edits update the same row.
 */
const SHEET_NAME = 'Transactions';
const SERVICE_NAME = 'VoiceRevenue';
const SERVICE_VERSION = '0.2.0';
const SPREADSHEET_ID_KEY = 'VOICE_REVENUE_SPREADSHEET_ID';

function setup() {
  const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
  if (!spreadsheet) {
    throw new Error('No active spreadsheet. Open the target Google Sheet, then Extensions > Apps Script, and run setup() from that editor.');
  }
  PropertiesService.getScriptProperties().setProperty(SPREADSHEET_ID_KEY, spreadsheet.getId());
  const sheet = getSheet_();
  return {
    ok: true,
    service: SERVICE_NAME,
    version: SERVICE_VERSION,
    spreadsheet_name: spreadsheet.getName(),
    sheet_name: sheet.getName()
  };
}

function doGet() {
  try {
    return json_(health_());
  } catch (err) {
    return json_({ ok: false, service: SERVICE_NAME, version: SERVICE_VERSION, error: errorText_(err) });
  }
}

function doPost(e) {
  try {
    const body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    if (body.action === 'ping') return json_(health_({ pong: true }));

    validate_(body);
    const sheet = getSheet_();
    const values = transactionRow_(body);
    const existingRow = findTransactionRow_(sheet, body.transaction_id);
    let action;

    if (existingRow) {
      sheet.getRange(existingRow, 1, 1, values.length).setValues([values]);
      action = 'updated';
    } else {
      sheet.appendRow(values);
      action = 'created';
    }

    return json_({
      ok: true,
      action: action,
      transaction_id: body.transaction_id,
      service: SERVICE_NAME,
      version: SERVICE_VERSION
    });
  } catch (err) {
    return json_({ ok: false, service: SERVICE_NAME, version: SERVICE_VERSION, error: errorText_(err) });
  }
}

function transactionRow_(body) {
  return [
    body.transaction_id,
    body.payment_at || '',
    body.amount_vnd,
    body.customer_name || '',
    body.product || '',
    body.payment_method || 'unknown',
    body.notes || '',
    body.created_at
  ];
}

function findTransactionRow_(sheet, transactionId) {
  const lastRow = sheet.getLastRow();
  if (lastRow < 2) return null;
  const values = sheet.getRange(2, 1, lastRow - 1, 1).getDisplayValues();
  for (let i = 0; i < values.length; i++) {
    if (values[i][0] === transactionId) return i + 2;
  }
  return null;
}

function health_(extra) {
  const spreadsheet = getSpreadsheet_();
  const sheet = getSheet_();
  return Object.assign({
    ok: true,
    pong: false,
    service: SERVICE_NAME,
    version: SERVICE_VERSION,
    sheet_access: true,
    spreadsheet_name: spreadsheet.getName(),
    sheet_name: sheet.getName()
  }, extra || {});
}

function validate_(body) {
  if (!body.transaction_id || typeof body.transaction_id !== 'string') throw new Error('transaction_id is required');
  if (!Number.isInteger(body.amount_vnd) || body.amount_vnd < 0) throw new Error('amount_vnd must be a non-negative integer');
  if (!body.created_at || typeof body.created_at !== 'string') throw new Error('created_at is required');
}

function getSpreadsheet_() {
  const spreadsheetId = PropertiesService.getScriptProperties().getProperty(SPREADSHEET_ID_KEY);
  if (!spreadsheetId) {
    throw new Error('VoiceRevenue is not configured. Run setup() once from the Apps Script editor before deploying/testing the Web App.');
  }
  return SpreadsheetApp.openById(spreadsheetId);
}

function getSheet_() {
  const spreadsheet = getSpreadsheet_();
  let sheet = spreadsheet.getSheetByName(SHEET_NAME);
  if (!sheet) {
    sheet = spreadsheet.insertSheet(SHEET_NAME);
    sheet.appendRow(['transaction_id', 'payment_at', 'amount_vnd', 'customer_name', 'product', 'payment_method', 'notes', 'created_at']);
  }
  return sheet;
}

function errorText_(err) {
  return String(err && err.message ? err.message : err);
}

function json_(object) {
  return ContentService.createTextOutput(JSON.stringify(object)).setMimeType(ContentService.MimeType.JSON);
}
