-- =============================================================================
-- Self-checking test of xx_supplier_stg_pkg. Safe to run: everything is rolled back.
--   SET SERVEROUTPUT ON
--   @99_test.sql
-- Prints PASS/FAIL per check and raises an error at the end if anything failed.
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
DECLARE
   g_fail   PLS_INTEGER := 0;
   g_pass   PLS_INTEGER := 0;

   l_id     NUMBER;  l_id2 NUMBER;  l_id3 NUMBER;
   l_http   NUMBER;
   l_status VARCHAR2(30);
   l_num    VARCHAR2(30);
   l_msg    VARCHAR2(4000);
   l_start  VARCHAR2(1);
   l_flag   VARCHAR2(30);
   l_cb     VARCHAR2(1);
   l_cnt    NUMBER;
   l_v      xx_supplier_stg_v%ROWTYPE;
   l_s      xx_supplier_stg%ROWTYPE;

   c_payload CONSTANT CLOB := '{
      "sourceRef": "TEST-0001",
      "supplierName": "Acme Coffee Beans Ltd",
      "taxRegistrationNumber": "98-7654321",
      "businessUnit": "US1 Business Unit",
      "address": {"addressName": "ACME HQ", "addressLine1": "100 Roast St", "city": "Seattle",
                  "state": "WA", "postalCode": "98101", "country": "us"},
      "site": {"siteName": "ACME-SEA", "paymentTerms": "Net 30"},
      "tax": {"taxRegimeCode": "US SALES TAX", "registrationNumber": "WA-123"},
      "bankAccount": {"bankName": "Chase", "branchName": "Seattle", "accountNumber": "0001 2345 6789",
                      "iban": "de89 3704 0044 0532 0130 00", "currencyCode": "usd"},
      "contacts": [{"firstName": "Jane", "lastName": "Doe", "email": "jane@acme.test"},
                   {"firstName": "John", "lastName": "Roe", "email": "john@acme.test"}]
   }';

   PROCEDURE chk (p_name VARCHAR2, p_ok BOOLEAN) IS
   BEGIN
      IF p_ok THEN
         g_pass := g_pass + 1;
         DBMS_OUTPUT.put_line('PASS  ' || p_name);
      ELSE
         g_fail := g_fail + 1;
         DBMS_OUTPUT.put_line('FAIL  ' || p_name);
      END IF;
   END chk;

   PROCEDURE recv (p CLOB) IS
   BEGIN
      xx_supplier_stg_pkg.receive_supplier(p, l_id, l_http, l_status, l_num, l_msg, l_start);
   END recv;

   FUNCTION row_of (p_id NUMBER) RETURN xx_supplier_stg%ROWTYPE IS
      r xx_supplier_stg%ROWTYPE;
   BEGIN
      SELECT * INTO r FROM xx_supplier_stg WHERE stg_id = p_id;
      RETURN r;
   END row_of;

   FUNCTION view_of (p_id NUMBER) RETURN xx_supplier_stg_v%ROWTYPE IS
      r xx_supplier_stg_v%ROWTYPE;
   BEGIN
      SELECT * INTO r FROM xx_supplier_stg_v WHERE stg_id = p_id;
      RETURN r;
   END view_of;

   FUNCTION in_work (p_id NUMBER, p_action VARCHAR2) RETURN BOOLEAN IS
      n NUMBER;
   BEGIN
      SELECT COUNT(*) INTO n FROM xx_supplier_work_v WHERE stg_id = p_id AND action = p_action;
      RETURN n = 1;
   END in_work;
BEGIN
   DELETE FROM xx_supplier_stg WHERE source_ref LIKE 'TEST-%';

   ---------------------------------------------------------------- validation
   recv('not json');
   chk('invalid JSON -> 400', l_http = 400 AND l_start = 'N');

   recv('{"sourceRef":"TEST-BAD","address":{"country":"USA"},"bankAccount":{"bankName":"X"},"contacts":[{"firstName":"A"}]}');
   chk('missing fields -> 400', l_http = 400);
   chk('400 lists fields', INSTR(l_msg, 'supplierName') > 0 AND INSTR(l_msg, 'site.siteName') > 0
                           AND INSTR(l_msg, 'bankAccount.accountNumber') > 0
                           AND INSTR(l_msg, 'contacts[].lastName') > 0
                           AND INSTR(l_msg, '2-letter') > 0);
   SELECT COUNT(*) INTO l_cnt FROM xx_supplier_stg WHERE source_ref = 'TEST-BAD';
   chk('rejected request not stored', l_cnt = 0);

   ---------------------------------------------------------------- receive
   recv(c_payload);
   chk('valid -> 202, start processing', l_http = 202 AND l_start = 'Y' AND l_status = 'NEW');
   SELECT COUNT(*) INTO l_cnt FROM xx_supplier_stg_contact WHERE stg_id = l_id;
   chk('2 contacts staged', l_cnt = 2);
   l_id2 := l_id;

   recv(c_payload);
   chk('resend while NEW -> 409, same id', l_http = 409 AND l_id = l_id2 AND l_start = 'N');

   ---------------------------------------------------------------- view mapping
   l_v := view_of(l_id2);
   chk('view: country upper-cased', l_v.country = 'US');
   chk('view: account number without spaces', l_v.account_number = '000123456789');
   chk('view: iban normalised', l_v.iban = 'DE89370400440532013000');
   chk('view: account name defaults to supplier', l_v.account_name = 'Acme Coffee Beans Ltd');
   chk('view: bank country defaults to address', l_v.bank_country = 'US' AND l_v.currency_code = 'USD');
   chk('view: all steps to run', l_v.run_supplier || l_v.run_address || l_v.run_site || l_v.run_contacts
                                  || l_v.run_tax || l_v.run_bank || l_v.run_bank_assign = 'YYYYYYY');

   ---------------------------------------------------------------- claim
   xx_supplier_stg_pkg.claim_record(l_id2, 'OIC-1', l_flag);
   chk('claim NEW -> Y', l_flag = 'Y');
   xx_supplier_stg_pkg.claim_record(l_id2, 'OIC-2', l_flag);
   chk('second claim -> N', l_flag = 'N');

   ---------------------------------------------------------------- partial run, temporary failure
   xx_supplier_stg_pkg.record_step(l_id2, 'SUPPLIER', 3001, '1234', 7001, 'OIC-1');
   xx_supplier_stg_pkg.record_step(l_id2, 'ADDRESS', 3002);
   xx_supplier_stg_pkg.record_step(l_id2, 'SITE', 3003);
   xx_supplier_stg_pkg.record_contact(l_id2, 1, 4001);
   xx_supplier_stg_pkg.mark_failure(l_id2, 'CONTACTS', 503, 'SERVICE_UNAVAILABLE', 'ERP down', 'OIC-1', l_flag, l_cb);
   l_s := row_of(l_id2);
   chk('503 -> RETRY, no callback', l_flag = 'RETRY' AND l_cb = 'N' AND l_s.retry_count = 1);
   chk('retry scheduled ~15 min', l_s.next_retry_at BETWEEN SYSTIMESTAMP + INTERVAL '14' MINUTE
                                                       AND SYSTIMESTAMP + INTERVAL '16' MINUTE);
   chk('not yet in work list', NOT in_work(l_id2, 'PROCESS'));
   UPDATE xx_supplier_stg SET next_retry_at = SYSTIMESTAMP - INTERVAL '1' MINUTE WHERE stg_id = l_id2;
   chk('due retry in work list', in_work(l_id2, 'PROCESS'));

   ---------------------------------------------------------------- resume
   xx_supplier_stg_pkg.claim_record(l_id2, 'OIC-3', l_flag);
   chk('claim RETRY -> Y', l_flag = 'Y');
   l_v := view_of(l_id2);
   chk('resume: skip supplier/address/site', l_v.run_supplier || l_v.run_address || l_v.run_site = 'NNN');
   chk('resume: contacts still to run', l_v.run_contacts = 'Y');
   SELECT COUNT(*) INTO l_cnt FROM xx_supplier_stg_contact_v WHERE stg_id = l_id2 AND erp_contact_id IS NULL;
   chk('only 1 contact left', l_cnt = 1);
   chk('ERP ids kept', l_v.erp_supplier_id = 3001 AND l_v.erp_supplier_number = '1234'
                       AND l_v.erp_party_id = 7001 AND l_v.erp_site_id = 3003);

   xx_supplier_stg_pkg.record_contact(l_id2, 2, 4002);
   xx_supplier_stg_pkg.record_step(l_id2, 'CONTACTS');
   xx_supplier_stg_pkg.record_step(l_id2, 'TAX', 5001);
   xx_supplier_stg_pkg.record_step(l_id2, 'BANK', 6001);
   xx_supplier_stg_pkg.record_step(l_id2, 'ADDRESS', NULL);   -- out of order: must not move back
   xx_supplier_stg_pkg.record_step(l_id2, 'BANK_ASSIGN', 6002);
   l_s := row_of(l_id2);
   chk('last_step_done only moves forward', l_s.last_step_done = 'BANK_ASSIGN' AND l_s.erp_address_id = 3002);
   l_v := view_of(l_id2);
   chk('nothing left to run', l_v.run_supplier || l_v.run_address || l_v.run_site || l_v.run_contacts
                              || l_v.run_tax || l_v.run_bank || l_v.run_bank_assign = 'NNNNNNN');

   ---------------------------------------------------------------- success + callback
   xx_supplier_stg_pkg.mark_success(l_id2, 'OIC-3');
   l_s := row_of(l_id2);
   chk('SUCCESS, callback PENDING', l_s.status = 'SUCCESS' AND l_s.callback_status = 'PENDING');
   chk('fresh callback left to Process Supplier', NOT in_work(l_id2, 'CALLBACK'));
   chk('callback type BATCH_UPDATE', view_of(l_id2).callback_type = 'BATCH_UPDATE');

   xx_supplier_stg_pkg.mark_callback(l_id2, 'N', 'Apex 503');
   l_s := row_of(l_id2);
   chk('callback fail -> FAILED, retry in 5 min', l_s.callback_status = 'FAILED' AND l_s.callback_attempts = 1
        AND l_s.next_callback_at > SYSTIMESTAMP + INTERVAL '4' MINUTE);
   UPDATE xx_supplier_stg SET next_callback_at = SYSTIMESTAMP - INTERVAL '1' MINUTE WHERE stg_id = l_id2;
   chk('due callback in work list', in_work(l_id2, 'CALLBACK'));
   xx_supplier_stg_pkg.mark_callback(l_id2, 'Y', 'ok');
   chk('callback ok -> SENT', row_of(l_id2).callback_status = 'SENT' AND NOT in_work(l_id2, 'CALLBACK'));

   recv(c_payload);
   chk('resend after SUCCESS -> 200 with supplier number', l_http = 200 AND l_num = '1234' AND l_start = 'N');

   xx_supplier_stg_pkg.reprocess(l_id2, NULL, l_flag, l_id);
   chk('reprocess SUCCESS row -> NOT_ALLOWED', l_flag = 'NOT_ALLOWED:SUCCESS');

   ---------------------------------------------------------------- data error, corrected resubmission
   recv(REPLACE(c_payload, 'TEST-0001', 'TEST-0002'));
   l_id3 := l_id;
   xx_supplier_stg_pkg.claim_record(l_id3, 'OIC-4', l_flag);
   xx_supplier_stg_pkg.record_step(l_id3, 'SUPPLIER', 3101, '1300', 7101);
   xx_supplier_stg_pkg.record_contact(l_id3, 1, 4101);
   xx_supplier_stg_pkg.mark_failure(l_id3, 'SITE', 400, 'INVALID_BU', 'Business unit not found', 'OIC-4', l_flag, l_cb);
   chk('400 from ERP -> ERROR_FINAL + error callback', l_flag = 'ERROR_FINAL' AND l_cb = 'Y');
   chk('callback type LOG_ERROR', view_of(l_id3).callback_type = 'LOG_ERROR');
   xx_supplier_stg_pkg.mark_callback(l_id3, 'Y', 'logged');

   -- Apex fixes the BU; Jane (already created) is resent, Mary is new, John is dropped
   recv(REPLACE(REPLACE(REPLACE(c_payload, 'TEST-0001', 'TEST-0002'), 'US1 Business Unit', 'US2 BU'),
                '"firstName": "John", "lastName": "Roe", "email": "john@acme.test"',
                '"firstName": "Mary", "lastName": "Poe", "email": "mary@acme.test"'));
   chk('resubmit after ERROR_FINAL -> 202', l_http = 202 AND l_start = 'Y' AND l_id = l_id3);
   l_v := view_of(l_id3);
   chk('resubmit keeps ERP ids and resumes', l_v.erp_supplier_id = 3101 AND l_v.run_supplier = 'N'
                                              AND l_v.run_address = 'Y' AND l_v.business_unit = 'US2 BU');
   chk('resubmit clears error/callback', l_v.error_code IS NULL AND l_v.callback_status IS NULL AND l_v.retry_count = 0);
   SELECT COUNT(*) INTO l_cnt FROM xx_supplier_stg_contact WHERE stg_id = l_id3;
   chk('contacts: Jane kept, Mary added, no duplicate', l_cnt = 2);
   SELECT COUNT(*) INTO l_cnt FROM xx_supplier_stg_contact
    WHERE stg_id = l_id3 AND erp_contact_id IS NULL AND email = 'mary@acme.test';
   chk('only Mary pending', l_cnt = 1);

   ---------------------------------------------------------------- retries exhausted
   recv(REPLACE(c_payload, 'TEST-0001', 'TEST-0003'));
   FOR i IN 1 .. 3 LOOP
      xx_supplier_stg_pkg.claim_record(l_id, 'OIC', l_flag);
      xx_supplier_stg_pkg.mark_failure(l_id, 'SUPPLIER', NULL, 'TIMEOUT', 'timed out', 'OIC', l_flag, l_cb);
   END LOOP;
   chk('3 timeouts -> still RETRY', l_flag = 'RETRY' AND row_of(l_id).retry_count = 3);
   xx_supplier_stg_pkg.claim_record(l_id, 'OIC', l_flag);
   xx_supplier_stg_pkg.mark_failure(l_id, 'SUPPLIER', 502, 'BAD_GATEWAY', 'x', 'OIC', l_flag, l_cb);
   chk('4th failure -> ERROR_FINAL + callback', l_flag = 'ERROR_FINAL' AND l_cb = 'Y');

   xx_supplier_stg_pkg.reprocess(NULL, 'TEST-0003', l_flag, l_id2);
   chk('manual reprocess ERROR_FINAL -> QUEUED', l_flag = 'QUEUED' AND l_id2 = l_id
        AND row_of(l_id).status = 'RETRY' AND row_of(l_id).retry_count = 0);
   xx_supplier_stg_pkg.reprocess(NULL, 'TEST-NOPE', l_flag, l_id2);
   chk('reprocess unknown -> NOT_FOUND', l_flag = 'NOT_FOUND');

   ---------------------------------------------------------------- stuck rows
   xx_supplier_stg_pkg.claim_record(l_id, 'OIC-DEAD', l_flag);
   UPDATE xx_supplier_stg SET claimed_at = SYSTIMESTAMP - INTERVAL '45' MINUTE WHERE stg_id = l_id;
   xx_supplier_stg_pkg.prepare_work(30, l_cnt);
   chk('stuck IN_PROGRESS released', l_cnt >= 1 AND row_of(l_id).status = 'RETRY' AND in_work(l_id, 'PROCESS'));

   ---------------------------------------------------------------- NEW row never handed over
   recv(REPLACE(c_payload, 'TEST-0001', 'TEST-0004'));
   chk('fresh NEW not in work list', NOT in_work(l_id, 'PROCESS'));
   UPDATE xx_supplier_stg SET created_on = SYSTIMESTAMP - INTERVAL '10' MINUTE WHERE stg_id = l_id;
   chk('orphaned NEW picked up', in_work(l_id, 'PROCESS'));

   ---------------------------------------------------------------- purge bank details
   SELECT stg_id INTO l_id FROM xx_supplier_stg WHERE source_ref = 'TEST-0001';
   UPDATE xx_supplier_stg SET updated_on = SYSTIMESTAMP - INTERVAL '8' DAY WHERE stg_id = l_id;
   xx_supplier_stg_pkg.purge_sensitive(7, l_cnt);
   l_s := row_of(l_id);
   chk('purge: bank removed, rest kept', l_cnt >= 1 AND l_s.sensitive_purged = 'Y'
        AND view_of(l_id).account_number IS NULL AND view_of(l_id).supplier_name = 'Acme Coffee Beans Ltd');

   ---------------------------------------------------------------- audit log
   SELECT COUNT(*) INTO l_cnt FROM xx_supplier_stg_log
    WHERE stg_id = (SELECT stg_id FROM xx_supplier_stg WHERE source_ref = 'TEST-0001');
   chk('audit log written', l_cnt >= 10);

   ROLLBACK;
   DBMS_OUTPUT.put_line(CHR(10) || g_pass || ' passed, ' || g_fail || ' failed');
   IF g_fail > 0 THEN
      RAISE_APPLICATION_ERROR(-20999, g_fail || ' test(s) failed');
   END IF;
END;
/
