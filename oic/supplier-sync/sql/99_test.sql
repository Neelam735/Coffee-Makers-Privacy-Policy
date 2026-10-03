-- =============================================================================
-- Self-checking test of xx_sup_pkg (CREATE lane, UPDATE lane, retries, ordering,
-- reprocess, callbacks, purge). Safe to run: everything is rolled back.
--   @99_test.sql      -> ends with "N passed, 0 failed"
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
DECLARE
   g_fail   PLS_INTEGER := 0;
   g_pass   PLS_INTEGER := 0;

   l_id     NUMBER;  l_a NUMBER;  l_b NUMBER;  l_next NUMBER;
   l_http   NUMBER;
   l_status VARCHAR2(30);
   l_num    VARCHAR2(30);
   l_msg    VARCHAR2(4000);
   l_start  VARCHAR2(1);
   l_res    VARCHAR2(40);
   l_lane   VARCHAR2(10);
   l_cb     VARCHAR2(1);
   l_cnt    NUMBER;
   l_ok     BOOLEAN;
   l_r      xx_sup_req_v%ROWTYPE;

   c_create CONSTANT CLOB := '{
     "requestId": "T-REQ-1", "supplierRef": "T-SUP-1",
     "header": {"supplierName": "Acme Coffee Beans Ltd", "taxRegistrationNumber": "98-7654321"},
     "addresses": [{"addressRef": "ADDR-1", "addressName": "ACME HQ", "addressLine1": "100 Roast St",
                    "city": "Seattle", "state": "WA", "postalCode": "98101", "country": "us"}],
     "sites": [{"siteRef": "SITE-1", "addressRef": "ADDR-1", "siteName": "ACME-SEA",
                "procurementBU": "US1 Business Unit", "paymentTerms": "Net 30"}],
     "contacts": [{"contactRef": "CON-1", "firstName": "Jane", "lastName": "Doe", "email": "jane@acme.test"}],
     "taxRegistrations": [{"taxRef": "TAX-1", "taxRegimeCode": "US SALES TAX", "registrationNumber": "WA-1",
                           "country": "US", "effectiveFrom": "2026-10-01"}],
     "bankAccounts": [{"bankRef": "BANK-1", "bankName": "Chase", "branchName": "Seattle",
                       "accountNumber": "0001 2345 6789", "iban": "de89 3704", "currencyCode": "usd",
                       "country": "US"}]
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
      xx_sup_pkg.receive_request(p, l_id, l_http, l_status, l_num, l_msg, l_start);
   END recv;

   PROCEDURE claim (p NUMBER) IS
   BEGIN
      xx_sup_pkg.claim_request(p, 'OIC-T', l_res, l_lane, l_cb);
   END claim;

   PROCEDURE done (p NUMBER, t VARCHAR2, r VARCHAR2, id1 NUMBER DEFAULT NULL, id2 NUMBER DEFAULT NULL,
                   num VARCHAR2 DEFAULT NULL, complete VARCHAR2 DEFAULT 'Y') IS
   BEGIN
      xx_sup_pkg.line_done(p, t, r, id1, id2, num, complete, 'OIC-T');
   END done;

   PROCEDURE fail (p NUMBER, t VARCHAR2, r VARCHAR2, http NUMBER, code VARCHAR2) IS
   BEGIN
      xx_sup_pkg.mark_failure(p, t, r, http, code, code || ' happened', 'OIC-T', l_status, l_cb, l_next);
   END fail;

   FUNCTION req (p NUMBER) RETURN xx_sup_req_v%ROWTYPE IS
      r xx_sup_req_v%ROWTYPE;
   BEGIN
      SELECT * INTO r FROM xx_sup_req_v WHERE req_id = p;
      RETURN r;
   END req;

   FUNCTION in_work (p NUMBER, a VARCHAR2) RETURN BOOLEAN IS
      n NUMBER;
   BEGIN
      SELECT COUNT(*) INTO n FROM xx_sup_work_v WHERE req_id = p AND action = a;
      RETURN n = 1;
   END in_work;
BEGIN
   DELETE FROM xx_sup_xref   WHERE supplier_ref LIKE 'T-%';
   DELETE FROM xx_sup_req    WHERE supplier_ref LIKE 'T-%';
   DELETE FROM xx_sup_master WHERE supplier_ref LIKE 'T-%';

   ------------------------------------------------------------------ receive: validation
   recv('not json');
   chk('invalid JSON -> 400', l_http = 400 AND l_start = 'N');

   recv('{"supplierRef": "T-X"}');
   chk('no requestId, no sections -> 400', l_http = 400 AND INSTR(l_msg, 'requestId is required') > 0
       AND INSTR(l_msg, 'no header and no items') > 0);

   recv('{"requestId": "T-BAD", "supplierRef": "T-X",
          "addresses": [{"addressRef": "A1", "addressName": "x", "addressLine1": "y", "city": "z", "country": "USA"},
                        {"addressRef": "A1", "addressName": "x", "addressLine1": "y", "city": "z", "country": "US"}],
          "sites": [{"siteRef": "S1", "siteName": "n"}],
          "bankAccounts": [{"bankRef": "B1", "bankName": "b"}]}');
   chk('item errors listed', l_http = 400
       AND INSTR(l_msg, 'addresses[].country must be a 2-letter') > 0
       AND INSTR(l_msg, 'addresses[].addressRef must be unique') > 0
       AND INSTR(l_msg, 'sites[].addressRef is required') > 0
       AND INSTR(l_msg, 'sites[].procurementBU is required') > 0
       AND INSTR(l_msg, 'bankAccounts[].accountNumber is required') > 0);
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_req WHERE request_id = 'T-BAD';
   chk('rejected message not stored', l_cnt = 0);

   ------------------------------------------------------------------ CREATE lane
   recv(c_create);
   l_a := l_id;
   chk('create message -> 202', l_http = 202 AND l_start = 'Y' AND l_status = 'NEW');
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_result_v WHERE req_id = l_a;
   chk('split into 6 items', l_cnt = 6);
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_req_bank
    WHERE req_id = l_a AND account_number = '000123456789' AND iban = 'DE893704' AND currency_code = 'USD';
   chk('bank values normalised', l_cnt = 1);
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_req_address WHERE req_id = l_a AND country = 'US';
   chk('country upper-cased', l_cnt = 1);

   recv(c_create);
   chk('same requestId again -> 409', l_http = 409 AND l_id = l_a AND l_start = 'N');

   claim(l_a);
   chk('claim -> CLAIMED, lane CREATE', l_res = 'CLAIMED' AND l_lane = 'CREATE');
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_result_v WHERE req_id = l_a AND operation = 'CREATE';
   chk('every item is CREATE', l_cnt = 6);
   l_r := req(l_a);
   chk('todo counts', l_r.header_todo = 1 AND l_r.address_todo = 1 AND l_r.site_todo = 1
       AND l_r.contact_todo = 1 AND l_r.tax_todo = 1 AND l_r.bank_todo = 1);
   claim(l_a);
   chk('second claim -> NOT_AVAILABLE', l_res = 'NOT_AVAILABLE');

   l_ok := FALSE;
   BEGIN
      done(l_a, 'ADDRESS', 'ADDR-1', 3001);
   EXCEPTION WHEN OTHERS THEN l_ok := SQLCODE = -20004;
   END;
   chk('address before header is refused', l_ok);

   done(l_a, 'HEADER', NULL, 1001, 7001, 'S-1001');
   l_r := req(l_a);
   chk('header done -> master row', l_r.erp_supplier_id = 1001 AND l_r.erp_party_id = 7001
       AND l_r.erp_supplier_number = 'S-1001');

   done(l_a, 'ADDRESS', 'ADDR-1', 3001);
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_site_v
    WHERE req_id = l_a AND erp_address_id = 3001 AND address_name = 'ACME HQ' AND erp_site_id IS NULL;
   chk('site view sees the new address', l_cnt = 1);
   done(l_a, 'SITE', 'SITE-1', 4001);
   done(l_a, 'CONTACT', 'CON-1', 5001);
   done(l_a, 'TAX', 'TAX-1', 6001);
   done(l_a, 'BANK', 'BANK-1', 8001, NULL, NULL, 'N');            -- account created, not assigned yet
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_bank_v
    WHERE req_id = l_a AND erp_bank_account_id = 8001 AND erp_assignment_id IS NULL
      AND process_status = 'PENDING' AND erp_party_id = 7001 AND account_name = 'Acme Coffee Beans Ltd';
   chk('bank ids saved, still pending', l_cnt = 1);

   fail(l_a, 'BANK', 'BANK-1', 503, 'SERVICE_UNAVAILABLE');
   chk('503 -> RETRY, no callback', l_status = 'RETRY' AND l_cb = 'N' AND l_next IS NULL);
   chk('retry not due yet', NOT in_work(l_a, 'PROCESS'));
   UPDATE xx_sup_req SET next_retry_at = SYSTIMESTAMP - INTERVAL '1' MINUTE WHERE req_id = l_a;
   chk('due retry in work list', in_work(l_a, 'PROCESS'));

   claim(l_a);
   chk('retry claim keeps lane', l_res = 'CLAIMED' AND l_lane = 'CREATE');
   l_r := req(l_a);
   chk('only the bank is left', l_r.header_todo + l_r.address_todo + l_r.site_todo + l_r.contact_todo
                                + l_r.tax_todo = 0 AND l_r.bank_todo = 1);
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_bank_v
    WHERE req_id = l_a AND erp_bank_account_id = 8001 AND process_status = 'PENDING';
   chk('retry knows the bank account exists', l_cnt = 1);

   l_ok := FALSE;
   BEGIN
      xx_sup_pkg.mark_success(l_a, 'OIC-T', l_next);
   EXCEPTION WHEN OTHERS THEN l_ok := SQLCODE = -20010;
   END;
   chk('success refused while items are open', l_ok);

   done(l_a, 'BANK', 'BANK-1', NULL, 8101);                       -- assignment done
   xx_sup_pkg.mark_success(l_a, 'OIC-T', l_next);
   l_r := req(l_a);
   chk('SUCCESS, callback BATCH_UPDATE pending', l_r.status = 'SUCCESS' AND l_r.callback_status = 'PENDING'
       AND l_r.callback_type = 'BATCH_UPDATE' AND l_next IS NULL);
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_xref WHERE supplier_ref = 'T-SUP-1';
   chk('5 xref rows', l_cnt = 5);
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_xref
    WHERE supplier_ref = 'T-SUP-1' AND entity_type = 'BANK' AND erp_id = 8001 AND erp_id2 = 8101;
   chk('bank xref has account and assignment', l_cnt = 1);

   xx_sup_pkg.mark_callback(l_a, 'N', 'Apex 503');
   l_r := req(l_a);
   chk('callback failed -> FAILED', l_r.callback_status = 'FAILED' AND l_r.callback_attempts = 1);
   UPDATE xx_sup_req SET next_callback_at = SYSTIMESTAMP - INTERVAL '1' MINUTE WHERE req_id = l_a;
   chk('due callback in work list', in_work(l_a, 'CALLBACK'));
   xx_sup_pkg.mark_callback(l_a, 'Y', 'ok');
   chk('callback -> SENT', req(l_a).callback_status = 'SENT' AND NOT in_work(l_a, 'CALLBACK'));

   recv(c_create);
   chk('requestId resent after SUCCESS -> 200 + supplier number', l_http = 200 AND l_num = 'S-1001');

   ------------------------------------------------------------------ UPDATE lane: address changed + new bank
   recv('{"requestId": "T-REQ-2", "supplierRef": "T-SUP-1",
          "addresses": [{"addressRef": "ADDR-1", "addressName": "ACME HQ", "addressLine1": "200 Bean Ave",
                         "city": "Seattle", "country": "US"}],
          "bankAccounts": [{"bankRef": "BANK-2", "bankName": "Wells", "branchName": "Seattle",
                            "accountNumber": "999", "country": "US"}]}');
   l_b := l_id;
   claim(l_b);
   chk('update message -> lane UPDATE', l_res = 'CLAIMED' AND l_lane = 'UPDATE');
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_address_v
    WHERE req_id = l_b AND address_ref = 'ADDR-1' AND operation = 'UPDATE' AND erp_address_id = 3001;
   chk('existing address -> UPDATE with its ERP id', l_cnt = 1);
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_bank_v
    WHERE req_id = l_b AND bank_ref = 'BANK-2' AND operation = 'CREATE' AND erp_bank_account_id IS NULL;
   chk('new bank -> CREATE', l_cnt = 1);
   l_r := req(l_b);
   chk('no header to do, supplier ids known', l_r.header_todo = 0 AND l_r.erp_supplier_id = 1001
       AND l_r.site_todo = 0);
   done(l_b, 'ADDRESS', 'ADDR-1');                                -- PATCH: no new id
   done(l_b, 'BANK', 'BANK-2', 8002, 8102);
   xx_sup_pkg.mark_success(l_b, 'OIC-T', l_next);
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_xref
    WHERE supplier_ref = 'T-SUP-1' AND entity_type = 'ADDRESS' AND erp_id = 3001 AND last_req_id = l_b;
   chk('xref keeps ERP id, records the update', l_cnt = 1);
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_xref WHERE supplier_ref = 'T-SUP-1';
   chk('new bank added to xref', l_cnt = 6);

   ------------------------------------------------------------------ UPDATE lane: header only
   recv('{"requestId": "T-REQ-3", "supplierRef": "T-SUP-1", "header": {"supplierName": "Acme Coffee Ltd"}}');
   claim(l_id);
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_header_v
    WHERE req_id = l_id AND operation = 'UPDATE' AND erp_supplier_id = 1001;
   chk('header-only update -> PATCH with SupplierId', l_cnt = 1 AND l_lane = 'UPDATE');
   done(l_id, 'HEADER', NULL);
   xx_sup_pkg.mark_success(l_id, 'OIC-T', l_next);
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_master
    WHERE supplier_ref = 'T-SUP-1' AND supplier_name = 'Acme Coffee Ltd' AND erp_supplier_id = 1001
      AND taxpayer_id = '98-7654321';
   chk('master name updated, other values kept', l_cnt = 1);

   ------------------------------------------------------------------ ordering: create and update for a new supplier
   recv(REPLACE(REPLACE(c_create, 'T-REQ-1', 'T-REQ-4'), 'T-SUP-1', 'T-SUP-2'));
   l_a := l_id;
   recv('{"requestId": "T-REQ-5", "supplierRef": "T-SUP-2",
          "contacts": [{"contactRef": "CON-9", "lastName": "Late"}]}');
   l_b := l_id;
   claim(l_b);
   chk('later message waits for the earlier one', l_res = 'WAITING');
   UPDATE xx_sup_req SET created_on = SYSTIMESTAMP - INTERVAL '10' MINUTE WHERE req_id = l_b;
   chk('waiting message not in work list', NOT in_work(l_b, 'PROCESS'));
   claim(l_a);
   done(l_a, 'HEADER', NULL, 1002, 7002, 'S-1002');
   done(l_a, 'ADDRESS', 'ADDR-1', 3002);
   done(l_a, 'SITE', 'SITE-1', 4002);
   done(l_a, 'CONTACT', 'CON-1', 5002);
   done(l_a, 'TAX', 'TAX-1', 6002);
   done(l_a, 'BANK', 'BANK-1', 8003, 8103);
   xx_sup_pkg.mark_success(l_a, 'OIC-T', l_next);
   chk('success hands over the waiting message', l_next = l_b);
   claim(l_b);
   chk('waiting message now runs as UPDATE', l_res = 'CLAIMED' AND l_lane = 'UPDATE');

   ------------------------------------------------------------------ lane rules
   recv('{"requestId": "T-REQ-6", "supplierRef": "T-SUP-3",
          "contacts": [{"contactRef": "C1", "lastName": "X"}]}');
   claim(l_id);
   l_r := req(l_id);
   chk('unknown supplier without header -> REJECTED', l_res = 'REJECTED' AND l_cb = 'Y'
       AND l_r.status = 'ERROR_FINAL' AND l_r.error_code = 'VALIDATION'
       AND INSTR(l_r.error_message, 'header is required') > 0
       AND INSTR(l_r.error_message, 'at least one site') > 0);

   recv('{"requestId": "T-REQ-7", "supplierRef": "T-SUP-1",
          "sites": [{"siteRef": "SITE-9", "addressRef": "ADDR-404", "siteName": "x", "procurementBU": "BU"}]}');
   claim(l_id);
   chk('site with unknown addressRef -> REJECTED', l_res = 'REJECTED'
       AND INSTR(req(l_id).error_message, 'SITE-9') > 0);

   recv('{"requestId": "T-REQ-8", "supplierRef": "T-SUP-1",
          "sites": [{"siteRef": "SITE-2", "addressRef": "ADDR-1", "siteName": "ACME-2", "procurementBU": "BU"}]}');
   claim(l_id);
   chk('site on an address created earlier -> accepted', l_res = 'CLAIMED');
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_site_v
    WHERE req_id = l_id AND erp_address_id = 3001 AND address_name = 'ACME HQ' AND operation = 'CREATE';
   chk('site view resolves address from xref', l_cnt = 1);

   ------------------------------------------------------------------ data error, then corrected message
   recv(REPLACE(REPLACE(c_create, 'T-REQ-1', 'T-REQ-9'), 'T-SUP-1', 'T-SUP-4'));
   l_a := l_id;
   claim(l_a);
   done(l_a, 'HEADER', NULL, 1004, 7004, 'S-1004');
   done(l_a, 'ADDRESS', 'ADDR-1', 3004);
   fail(l_a, 'SITE', 'SITE-1', 400, 'INVALID_BU');
   l_r := req(l_a);
   chk('400 -> ERROR_FINAL + LOG_ERROR callback', l_status = 'ERROR_FINAL' AND l_cb = 'Y'
       AND l_r.callback_type = 'LOG_ERROR' AND l_r.error_entity = 'SITE' AND l_r.error_ref = 'SITE-1');
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_result_v
    WHERE req_id = l_a AND entity_type = 'SITE' AND process_status = 'ERROR' AND error_message LIKE 'INVALID_BU%';
   chk('failed item marked ERROR', l_cnt = 1);

   recv(REPLACE(REPLACE(REPLACE(c_create, 'T-REQ-1', 'T-REQ-10'), 'T-SUP-1', 'T-SUP-4'),
                'US1 Business Unit', 'US2 BU'));
   claim(l_id);
   chk('corrected message -> UPDATE lane', l_res = 'CLAIMED' AND l_lane = 'UPDATE');
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_result_v
    WHERE req_id = l_id AND ((entity_type IN ('HEADER', 'ADDRESS') AND operation = 'UPDATE')
                          OR (entity_type IN ('SITE', 'CONTACT', 'TAX', 'BANK') AND operation = 'CREATE'));
   chk('created items update, missing items create', l_cnt = 6);

   ------------------------------------------------------------------ retries exhausted, reprocess
   recv(REPLACE(REPLACE(c_create, 'T-REQ-1', 'T-REQ-11'), 'T-SUP-1', 'T-SUP-5'));
   l_a := l_id;
   FOR i IN 1 .. 3 LOOP
      claim(l_a);
      fail(l_a, 'HEADER', NULL, NULL, 'TIMEOUT');
   END LOOP;
   chk('3 timeouts -> RETRY', l_status = 'RETRY' AND req(l_a).retry_count = 3);
   claim(l_a);
   fail(l_a, 'HEADER', NULL, 502, 'BAD_GATEWAY');
   chk('4th failure -> ERROR_FINAL', l_status = 'ERROR_FINAL' AND l_cb = 'Y');

   xx_sup_pkg.reprocess(NULL, 'T-REQ-11', l_res, l_b);
   l_r := req(l_a);
   chk('reprocess -> QUEUED, lane reset (nothing reached ERP)', l_res = 'QUEUED' AND l_b = l_a
       AND l_r.status = 'RETRY' AND l_r.lane IS NULL AND l_r.retry_count = 0);
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_result_v
    WHERE req_id = l_a AND (operation IS NOT NULL OR process_status <> 'PENDING');
   chk('items back to PENDING, no operation', l_cnt = 0);
   claim(l_a);
   chk('reprocessed message claimed again', l_res = 'CLAIMED' AND l_lane = 'CREATE');

   xx_sup_pkg.reprocess(NULL, 'T-NOPE', l_res, l_b);
   chk('reprocess unknown -> NOT_FOUND', l_res = 'NOT_FOUND');
   xx_sup_pkg.reprocess(NULL, 'T-REQ-2', l_res, l_b);
   chk('reprocess SUCCESS -> NOT_ALLOWED', l_res = 'NOT_ALLOWED:SUCCESS');

   ------------------------------------------------------------------ stuck messages, orphans
   UPDATE xx_sup_req SET claimed_at = SYSTIMESTAMP - INTERVAL '45' MINUTE WHERE req_id = l_a;
   xx_sup_pkg.prepare_work(30, l_cnt);
   chk('stuck message released', l_cnt >= 1 AND req(l_a).status = 'RETRY' AND in_work(l_a, 'PROCESS'));

   recv('{"requestId": "T-REQ-12", "supplierRef": "T-SUP-6", "header": {"supplierName": "N", "taxRegistrationNumber": "1"}}');
   chk('fresh NEW not in work list', NOT in_work(l_id, 'PROCESS'));
   UPDATE xx_sup_req SET created_on = SYSTIMESTAMP - INTERVAL '10' MINUTE WHERE req_id = l_id;
   chk('orphaned NEW picked up', in_work(l_id, 'PROCESS'));

   ------------------------------------------------------------------ purge
   SELECT req_id INTO l_a FROM xx_sup_req WHERE request_id = 'T-REQ-1';
   UPDATE xx_sup_req SET updated_on = SYSTIMESTAMP - INTERVAL '8' DAY WHERE req_id = l_a;
   xx_sup_pkg.purge_sensitive(7, l_cnt);
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_req_bank WHERE req_id = l_a AND account_number = '****6789';
   chk('account number masked', l_cnt = 1);
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_req
    WHERE req_id = l_a AND sensitive_purged = 'Y' AND NOT JSON_EXISTS(payload_json, '$.bankAccounts')
      AND JSON_VALUE(payload_json, '$.supplierRef') = 'T-SUP-1';
   chk('bank details removed from payload', l_cnt = 1);

   ------------------------------------------------------------------ audit
   SELECT COUNT(*) INTO l_cnt FROM xx_sup_log WHERE req_id = (SELECT req_id FROM xx_sup_req WHERE request_id = 'T-REQ-1');
   chk('audit trail written', l_cnt >= 10);

   ROLLBACK;
   DBMS_OUTPUT.put_line(CHR(10) || g_pass || ' passed, ' || g_fail || ' failed');
   IF g_fail > 0 THEN
      RAISE_APPLICATION_ERROR(-20999, g_fail || ' test(s) failed');
   END IF;
END;
/
