# Supplier onboarding: ATP staging for Apex Analytics → OIC → Oracle ERP Cloud

Apex Analytics sends **one supplier per request**. OIC saves it in ATP and replies right away. It then creates the supplier in ERP: supplier, address, site, contacts, tax and bank. Finally it reports the result back to Apex (batch update API on success, log error API on failure).

Everything that makes retries and reprocessing safe lives in ATP:
- one row per supplier;
- ERP IDs saved after each step, so a retry continues where it stopped instead of creating duplicates;
- a unique key on Apex's record ID, so duplicate submissions are caught;
- a separate status for the reply to Apex.

```
Apex ──POST──▶ ① Receive Supplier ──receive_supplier──▶ ATP ──202 {trackingId}──▶ Apex
                     │ start without waiting
                     ▼
               ② Process Supplier ── claim_record → read xx_supplier_stg_v
                     │  for each step still to do: call ERP → record_step
                     ├─ all done  → mark_success → ④ Callback (batch update API)
                     └─ fault     → mark_failure → RETRY (later) or ERROR_FINAL → ④ Callback (log error API)
                     ▲
               ③ Retry job (every 15 min) ── prepare_work → xx_supplier_work_v
                     ├─ PROCESS  → ②
                     └─ CALLBACK → ④
               ⑤ Reprocess (manual, REST) ── reprocess → ② or ④
```

## Files

| File | What it is |
|---|---|
| `sql/install.sql` | Runs 01–04 in order |
| `sql/01_tables.sql` | `xx_supplier_stg`, `xx_supplier_stg_contact`, `xx_supplier_stg_log` |
| `sql/02_pkg_spec.sql`, `sql/03_pkg_body.sql` | `xx_supplier_stg_pkg`, the API that OIC calls |
| `sql/04_views.sql` | `xx_supplier_stg_v` (payload as columns, plus "steps left to run" flags), `xx_supplier_stg_contact_v`, `xx_supplier_work_v` |
| `sql/05_purge_job.sql` | Optional nightly job that removes bank details from finished records |
| `sql/99_test.sql` | Self-checking test with 50 checks; everything is rolled back |
| `sql/uninstall.sql` | Drops everything |
| `samples/` | Example request from Apex and example responses from ① |

## Install (ATP)

1. Connect as the schema that will own the objects, using Database Actions → SQL, SQL Developer or SQLcl.
2. Run `@install.sql`. It should list 16 objects, all `VALID`.
3. Run `@99_test.sql`. It should end with `50 passed, 0 failed`. It rolls back, so it leaves no data.
4. Optional: run `@05_purge_job.sql`.
5. Recommended: have OIC connect as a separate user with only the rights it needs. Replace `oic_user` with that user:
   ```sql
   GRANT EXECUTE ON xx_supplier_stg_pkg        TO oic_user;
   GRANT SELECT  ON xx_supplier_stg_v          TO oic_user;
   GRANT SELECT  ON xx_supplier_stg_contact_v  TO oic_user;
   GRANT SELECT  ON xx_supplier_work_v         TO oic_user;
   ```
   OIC then refers to objects with the owner prefix (`owner.xx_supplier_stg_pkg`).

The code uses only features available in 19c, so it runs on ATP 19c and 23ai. It was tested on Oracle Database 23ai Free.

**Transactions:** the procedures do not `COMMIT`. The OIC ATP adapter commits each call it makes. When you call them from SQL yourself, commit afterwards.

## Record lifecycle

| `status` | Meaning | Next |
|---|---|---|
| `NEW` | Received, not started | ② claims it (③ picks it up if ① never handed it over within 5 min) |
| `IN_PROGRESS` | ② is working on it | `SUCCESS` / `RETRY` / `ERROR_FINAL`; released by ③ if stuck for more than 30 min |
| `RETRY` | Temporary error, waiting | ③ runs it again at `next_retry_at` (15 min, then 1 h, then 4 h) |
| `SUCCESS` | Everything created in ERP | Reply to Apex through the batch update API |
| `ERROR_FINAL` | Data error, or out of retries | Reply to Apex through the log error API; Apex can send a corrected version |

**Temporary vs. data errors:** a missing HTTP status (timeout or connection error), 408, 429 or 5xx counts as temporary. It is retried automatically up to 3 times. Anything else, such as a 400 from ERP, is a data error and becomes `ERROR_FINAL` straight away.

**Reply to Apex (`callback_status`):** `PENDING` → `SENT`. When a call fails it becomes `FAILED` and is retried after 5 min, 15 min, 1 h and then every 4 h. After 6 failed attempts it becomes `GAVE_UP`. This is tracked separately from the ERP status, so an Apex outage never causes anything to be re-created in ERP.

**When Apex sends the same `sourceRef` again:**

| Current row | Result |
|---|---|
| none | 202, processing starts |
| `SUCCESS` | 200 with the existing supplier number; nothing new is created |
| `NEW`, `IN_PROGRESS`, `RETRY` | 409 |
| `ERROR_FINAL` | 202. The corrected data replaces the old data, and ERP IDs already saved are kept, so processing continues from the step that failed. Contacts that were already created are not created again. |

## OIC integrations

Create one **ATP adapter connection** to this schema. Your ERP REST connection and a REST connection to Apex Analytics are also needed.

### ① Receive Supplier (app-driven, REST trigger, synchronous)
1. **Trigger:** `POST /suppliers`.
2. **ATP invoke:** *Invoke a Stored Procedure* → `XX_SUPPLIER_STG_PKG.RECEIVE_SUPPLIER_B64`.
   - `p_payload_b64` = the request body as base64. Set up the trigger to take the request body as **binary**, then map `oraext:encodeReferenceToBase64(<attachment reference>)`.
   - This keeps Apex's JSON exactly as sent, and all validation happens in ATP.
3. **Switch** on `p_start_processing = 'Y'`: **call ② without waiting for it**, passing `p_stg_id`.
4. **Response:** map `p_stg_id` (as `trackingId`), `p_http_status`, `p_status`, `p_supplier_number` and `p_message`; see `samples/receive_responses.json`.
   - If your OIC version lets the REST trigger return a custom HTTP status, use `p_http_status` as the status.
   - Otherwise, return HTTP 200 and have Apex read `httpStatus` and `status` from the response body.

> **Check first in your OIC instance:** whether the trigger can pass the raw body as binary and turn it into base64 (step 2). If it can't, use `RECEIVE_SUPPLIER`, which takes the JSON text in `p_payload`. If OIC can't give you the JSON as text either, Apex can post directly to ATP through an ORDS REST endpoint on this same procedure, and ③ then picks up the `NEW` rows.

### ② Process Supplier (app-driven, one-way/asynchronous, input `stgId`)
1. **Claim the row:** `CLAIM_RECORD(stgId, <integration instance ID>)`. If `p_claimed = 'N'`, stop.
2. **Read the record:** *Run a SQL statement*: `SELECT * FROM xx_supplier_stg_v WHERE stg_id = #stgId`.
3. **Scope *ErpSteps*.** Keep a variable `vStep`, and set it before each step so the fault handler knows which step failed. Run each step only when its flag is `'Y'`:

| Flag | ERP call (Fusion REST) | Then |
|---|---|---|
| `run_supplier` | Check first: `GET /suppliers?q=TaxpayerId='<tax id>'`. If found **and** `retry_count > 0` **and** the name matches, reuse that supplier (it was created by an earlier attempt). If found otherwise, throw a fault with code `409` and `DUPLICATE_SUPPLIER`. If not found, `POST /suppliers`. | `RECORD_STEP(stgId,'SUPPLIER', SupplierId, SupplierNumber, SupplierPartyId)` |
| `run_address` | `POST /suppliers/{id}/child/addresses` | `RECORD_STEP(stgId,'ADDRESS', SupplierAddressId)` |
| `run_site` | `POST /suppliers/{id}/child/sites` | `RECORD_STEP(stgId,'SITE', SupplierSiteId)` |
| `run_contacts` | `SELECT * FROM xx_supplier_stg_contact_v WHERE stg_id = #stgId AND erp_contact_id IS NULL`. For each contact: `POST /suppliers/{id}/child/contacts`, then `RECORD_CONTACT(stgId, contact_seq, SupplierContactId)` | `RECORD_STEP(stgId,'CONTACTS')` |
| `run_tax` | Tax registration REST resource for your release | `RECORD_STEP(stgId,'TAX', <registration id>)` |
| `run_bank` | `POST /externalBankAccounts`, owner = `erp_party_id` | `RECORD_STEP(stgId,'BANK', BankAccountId)` |
| `run_bank_assign` | `GET /paymentsExternalPayees?q=PayeePartyIdentifier=<party>`, then `POST /instrumentAssignments` | `RECORD_STEP(stgId,'BANK_ASSIGN', <assignment id>)` |

   After the last step, call `MARK_SUCCESS(stgId)`.

   The ERP calls, request mappings and bank logic are the ones in `../supplier-onboarding`. Always use the IDs from the view (`erp_supplier_id`, `erp_party_id`, …), because on a retry the earlier steps are skipped.

4. **Scope fault handler:**
   - Call `MARK_FAILURE(stgId, vStep, <HTTP status from the fault, or empty for a timeout>, <error code>, <fault reason/details>, <instance ID>)`.
   - If `p_send_error_callback = 'Y'`, call ④.
   - Do **not** rethrow the fault; the row now records the error.
5. **After the scope succeeds:** call ④.

### ③ Retry job (scheduled, every 15 minutes)
1. Call `PREPARE_WORK(30)`. This releases rows stuck in `IN_PROGRESS` for more than 30 minutes.
2. *Run a SQL statement*: `SELECT stg_id, action FROM xx_supplier_work_v ORDER BY due_at FETCH FIRST 100 ROWS ONLY`.
3. For each row: if `action = 'PROCESS'`, call ② (without waiting). If `action = 'CALLBACK'`, call ④.

### ④ Supplier Callback (app-driven child, synchronous, input `stgId`)
1. `SELECT * FROM xx_supplier_stg_v WHERE stg_id = #stgId`.
2. Depending on `callback_type`:
   - `BATCH_UPDATE`: call the Apex batch update API with one record: `source_ref`, `erp_supplier_id`, `erp_supplier_number`, `erp_site_id`, `erp_bank_account_id`.
   - `LOG_ERROR`: call the Apex log error API with `source_ref`, `error_step`, `error_code` and `error_message`.
3. `MARK_CALLBACK(stgId, 'Y', <response summary>)`. In the fault handler, call `MARK_CALLBACK(stgId, 'N', <fault reason>)` and don't rethrow.

The field names Apex expects depend on their API, so confirm them with the Apex Analytics team.

### ⑤ Reprocess (optional, REST, for support staff)
1. `POST /suppliers/reprocess` with `{ "trackingId": 101 }` or `{ "sourceRef": "APX-…" }`.
2. Call `REPROCESS(p_stg_id, p_source_ref)`.
3. If the result is `QUEUED`, call ②. If it is `CALLBACK_QUEUED`, call ④.
4. Return `p_result`. Its possible values are `QUEUED`, `CALLBACK_QUEUED`, `NOT_FOUND` and `NOT_ALLOWED:<status>`.

## Useful queries

```sql
-- What is failing right now
SELECT source_ref, supplier_name, status, error_step, error_code, error_message, retry_count, updated_on
  FROM xx_supplier_stg WHERE status IN ('RETRY','ERROR_FINAL') ORDER BY updated_on DESC;

-- Replies to Apex that have not got through
SELECT source_ref, status, callback_status, callback_attempts, callback_message
  FROM xx_supplier_stg WHERE callback_status IN ('FAILED','GAVE_UP');

-- Full history of one record
SELECT created_on, event, step, detail, oic_instance_id
  FROM xx_supplier_stg_log WHERE stg_id = :id ORDER BY log_id;
```

## Notes

- **Different field names from Apex:** change the JSON paths in `xx_supplier_stg_v` (in `04_views.sql`) and the required fields in `validate_payload` (in `03_pkg_body.sql`). Nothing else needs to change.
- **Bank details** are stored in `payload_json` until `purge_sensitive` removes them, 7 days after a record is finished.
  - Restrict access to the tables.
  - Keep OIC payload tracing off in production.
  - A failed record whose bank details have been purged can't be reprocessed from ATP (`NOT_ALLOWED:PAYLOAD_PURGED`); Apex has to send it again.
- **Settings** are constants in the package spec: `c_max_retries` (3), `c_max_callback_attempts` (6) and `c_callback_grace_minutes` (10).
- **Duplicate addresses or sites:** if OIC stops after an ERP call succeeded but before `RECORD_STEP` ran, a retry creates that address or site again. This is rare. To rule it out completely, look up the address or site by name before creating it, in the same way the supplier step does.
