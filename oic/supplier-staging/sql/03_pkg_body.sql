CREATE OR REPLACE PACKAGE BODY xx_supplier_stg_pkg AS

   -- ---------------------------------------------------------------------------
   -- Helpers
   -- ---------------------------------------------------------------------------
   FUNCTION step_no (p_step IN VARCHAR2) RETURN PLS_INTEGER DETERMINISTIC IS
   BEGIN
      RETURN CASE p_step
                WHEN 'SUPPLIER'    THEN 1
                WHEN 'ADDRESS'     THEN 2
                WHEN 'SITE'        THEN 3
                WHEN 'CONTACTS'    THEN 4
                WHEN 'TAX'         THEN 5
                WHEN 'BANK'        THEN 6
                WHEN 'BANK_ASSIGN' THEN 7
                ELSE 0
             END;
   END step_no;

   PROCEDURE log_event (
      p_stg_id          IN NUMBER,
      p_event           IN VARCHAR2,
      p_step            IN VARCHAR2 DEFAULT NULL,
      p_detail          IN VARCHAR2 DEFAULT NULL,
      p_oic_instance_id IN VARCHAR2 DEFAULT NULL) IS
   BEGIN
      INSERT INTO xx_supplier_stg_log (stg_id, event, step, detail, oic_instance_id)
      VALUES (p_stg_id, p_event, p_step, SUBSTR(p_detail, 1, 4000), p_oic_instance_id);
   END log_event;

   -- Minutes to wait before retry n (1-based): 15, 60, 240, 240, ...
   FUNCTION retry_backoff (p_attempt IN PLS_INTEGER) RETURN INTERVAL DAY TO SECOND IS
   BEGIN
      RETURN NUMTODSINTERVAL(CASE p_attempt WHEN 1 THEN 15 WHEN 2 THEN 60 ELSE 240 END, 'MINUTE');
   END retry_backoff;

   -- Minutes to wait before callback attempt n: 5, 15, 60, 240, ...
   FUNCTION callback_backoff (p_attempt IN PLS_INTEGER) RETURN INTERVAL DAY TO SECOND IS
   BEGIN
      RETURN NUMTODSINTERVAL(CASE p_attempt WHEN 1 THEN 5 WHEN 2 THEN 15 WHEN 3 THEN 60 ELSE 240 END,
                             'MINUTE');
   END callback_backoff;

   FUNCTION is_temporary_error (p_http_status IN NUMBER, p_error_code IN VARCHAR2) RETURN BOOLEAN IS
   BEGIN
      RETURN NVL(p_http_status, 0) = 0
          OR p_http_status IN (408, 429)
          OR p_http_status >= 500
          OR UPPER(p_error_code) IN ('TIMEOUT', 'CONNECTION', 'SERVICE_UNAVAILABLE');
   END is_temporary_error;

   FUNCTION jv (p_json IN CLOB, p_path IN VARCHAR2) RETURN VARCHAR2 IS
      l_value VARCHAR2(4000);
   BEGIN
      -- JSON_VALUE needs a literal path in SQL, so use dynamic SQL for the generic helper.
      EXECUTE IMMEDIATE
         'SELECT JSON_VALUE(:j, ''' || REPLACE(p_path, '''', '''''') || ''' RETURNING VARCHAR2(4000) NULL ON ERROR) FROM dual'
         INTO l_value USING p_json;
      RETURN TRIM(l_value);
   END jv;

   -- Returns a comma-separated list of missing required fields (NULL when valid).
   FUNCTION validate_payload (p_payload IN CLOB) RETURN VARCHAR2 IS
      l_missing VARCHAR2(4000);
      l_has_bank NUMBER;
      l_bad_contacts NUMBER;

      PROCEDURE req (p_path IN VARCHAR2, p_name IN VARCHAR2) IS
      BEGIN
         IF jv(p_payload, p_path) IS NULL THEN
            l_missing := l_missing || CASE WHEN l_missing IS NOT NULL THEN ', ' END || p_name;
         END IF;
      END req;
   BEGIN
      req('$.sourceRef',             'sourceRef');
      req('$.supplierName',          'supplierName');
      req('$.taxRegistrationNumber', 'taxRegistrationNumber');
      req('$.address.addressName',   'address.addressName');
      req('$.address.addressLine1',  'address.addressLine1');
      req('$.address.city',          'address.city');
      req('$.address.country',       'address.country');
      req('$.site.siteName',         'site.siteName');

      SELECT CASE WHEN JSON_EXISTS(p_payload, '$.bankAccount') THEN 1 ELSE 0 END
        INTO l_has_bank FROM dual;
      IF l_has_bank = 1 THEN
         req('$.bankAccount.bankName',      'bankAccount.bankName');
         req('$.bankAccount.branchName',    'bankAccount.branchName');
         req('$.bankAccount.accountNumber', 'bankAccount.accountNumber');
      END IF;

      SELECT COUNT(*)
        INTO l_bad_contacts
        FROM JSON_TABLE(p_payload, '$.contacts[*]'
                COLUMNS (last_name VARCHAR2(150) PATH '$.lastName'))
       WHERE TRIM(last_name) IS NULL;
      IF l_bad_contacts > 0 THEN
         l_missing := l_missing || CASE WHEN l_missing IS NOT NULL THEN ', ' END || 'contacts[].lastName';
      END IF;

      IF jv(p_payload, '$.address.country') IS NOT NULL
         AND LENGTH(jv(p_payload, '$.address.country')) <> 2 THEN
         l_missing := l_missing || CASE WHEN l_missing IS NOT NULL THEN ', ' END
                      || 'address.country (2-letter ISO code)';
      END IF;

      IF LENGTH(jv(p_payload, '$.sourceRef')) > 100 THEN
         l_missing := l_missing || CASE WHEN l_missing IS NOT NULL THEN ', ' END || 'sourceRef (max 100 chars)';
      END IF;

      RETURN l_missing;
   END validate_payload;

   -- Adds contacts from the payload that are not already created in ERP.
   PROCEDURE load_contacts (p_stg_id IN NUMBER, p_payload IN CLOB) IS
   BEGIN
      DELETE FROM xx_supplier_stg_contact
       WHERE stg_id = p_stg_id
         AND erp_contact_id IS NULL;

      INSERT INTO xx_supplier_stg_contact (stg_id, contact_seq, first_name, last_name, email, phone)
      SELECT p_stg_id,
             NVL((SELECT MAX(contact_seq) FROM xx_supplier_stg_contact WHERE stg_id = p_stg_id), 0)
                + ROW_NUMBER() OVER (ORDER BY jt.ord),
             TRIM(jt.first_name), TRIM(jt.last_name), TRIM(jt.email), TRIM(jt.phone)
        FROM JSON_TABLE(p_payload, '$.contacts[*]'
                COLUMNS (ord        FOR ORDINALITY,
                         first_name VARCHAR2(150) PATH '$.firstName',
                         last_name  VARCHAR2(150) PATH '$.lastName',
                         email      VARCHAR2(320) PATH '$.email',
                         phone      VARCHAR2(60)  PATH '$.phone')) jt
       WHERE NOT EXISTS (
                SELECT 1
                  FROM xx_supplier_stg_contact c
                 WHERE c.stg_id = p_stg_id
                   AND c.erp_contact_id IS NOT NULL
                   AND (   LOWER(c.email) = LOWER(TRIM(jt.email))
                        OR (c.email IS NULL AND TRIM(jt.email) IS NULL
                            AND UPPER(c.first_name || ' ' || c.last_name)
                              = UPPER(TRIM(jt.first_name) || ' ' || TRIM(jt.last_name)))));
   END load_contacts;

   FUNCTION base64_to_clob (p_b64 IN CLOB) RETURN CLOB IS
      c_chunk   CONSTANT PLS_INTEGER := 24000;         -- multiple of 4
      l_clean   CLOB;
      l_blob    BLOB;
      l_result  CLOB;
      l_len     PLS_INTEGER;
      l_pos     PLS_INTEGER := 1;
      l_dest    INTEGER := 1;
      l_src     INTEGER := 1;
      l_lang    INTEGER := DBMS_LOB.default_lang_ctx;
      l_warn    INTEGER;
   BEGIN
      IF p_b64 IS NULL THEN
         RETURN NULL;
      END IF;
      l_clean := REGEXP_REPLACE(p_b64, '[[:space:]]', '');
      l_len   := DBMS_LOB.getlength(l_clean);
      DBMS_LOB.createtemporary(l_blob, TRUE);
      WHILE l_pos <= l_len LOOP
         DBMS_LOB.append(l_blob, TO_BLOB(UTL_ENCODE.base64_decode(
            UTL_RAW.cast_to_raw(DBMS_LOB.substr(l_clean, c_chunk, l_pos)))));
         l_pos := l_pos + c_chunk;
      END LOOP;
      DBMS_LOB.createtemporary(l_result, TRUE);
      -- Decode as UTF-8 in one pass so multi-byte characters are never split.
      DBMS_LOB.converttoclob(l_result, l_blob, DBMS_LOB.lobmaxsize, l_dest, l_src,
                             NLS_CHARSET_ID('AL32UTF8'), l_lang, l_warn);
      DBMS_LOB.freetemporary(l_blob);
      RETURN l_result;
   END base64_to_clob;

   -- ---------------------------------------------------------------------------
   -- (1) Receive Supplier
   -- ---------------------------------------------------------------------------
   PROCEDURE receive_supplier (
      p_payload          IN  CLOB,
      p_stg_id           OUT NUMBER,
      p_http_status      OUT NUMBER,
      p_status           OUT VARCHAR2,
      p_supplier_number  OUT VARCHAR2,
      p_message          OUT VARCHAR2,
      p_start_processing OUT VARCHAR2)
   IS
      l_is_json    NUMBER;
      l_missing    VARCHAR2(4000);
      l_source_ref xx_supplier_stg.source_ref%TYPE;
      l_name       xx_supplier_stg.supplier_name%TYPE;
      l_tax_id     xx_supplier_stg.tax_id%TYPE;
      l_row        xx_supplier_stg%ROWTYPE;
   BEGIN
      p_start_processing := 'N';

      SELECT CASE WHEN p_payload IS JSON THEN 1 ELSE 0 END INTO l_is_json FROM dual;
      IF p_payload IS NULL OR l_is_json = 0 THEN
         p_http_status := 400;
         p_status      := 'REJECTED';
         p_message     := 'Request body is not valid JSON.';
         log_event(NULL, 'REJECTED', NULL, p_message);
         RETURN;
      END IF;

      l_missing := validate_payload(p_payload);
      IF l_missing IS NOT NULL THEN
         p_http_status := 400;
         p_status      := 'REJECTED';
         p_message     := SUBSTR('Missing or invalid fields: ' || l_missing, 1, 4000);
         log_event(NULL, 'REJECTED', NULL,
                   'sourceRef=' || SUBSTR(jv(p_payload, '$.sourceRef'), 1, 100) || '; ' || p_message);
         RETURN;
      END IF;

      l_source_ref := jv(p_payload, '$.sourceRef');
      l_name       := SUBSTR(jv(p_payload, '$.supplierName'), 1, 360);
      l_tax_id     := SUBSTR(jv(p_payload, '$.taxRegistrationNumber'), 1, 50);

      BEGIN
         INSERT INTO xx_supplier_stg (source_ref, payload_json, supplier_name, tax_id)
         VALUES (l_source_ref, p_payload, l_name, l_tax_id)
         RETURNING stg_id INTO p_stg_id;

         load_contacts(p_stg_id, p_payload);
         log_event(p_stg_id, 'RECEIVED');

         p_http_status      := 202;
         p_status           := 'NEW';
         p_message          := 'Accepted for processing.';
         p_start_processing := 'Y';
         RETURN;
      EXCEPTION
         WHEN DUP_VAL_ON_INDEX THEN
            NULL;   -- this sourceRef was sent before; handled below
      END;

      SELECT * INTO l_row
        FROM xx_supplier_stg
       WHERE source_ref = l_source_ref
         FOR UPDATE;

      p_stg_id := l_row.stg_id;

      IF l_row.status = 'SUCCESS' THEN
         p_http_status     := 200;
         p_status          := 'SUCCESS';
         p_supplier_number := l_row.erp_supplier_number;
         p_message         := 'Supplier was already created.';
         log_event(p_stg_id, 'RESENT_IGNORED', NULL, 'Already SUCCESS');

      ELSIF l_row.status = 'ERROR_FINAL' THEN
         -- Corrected resubmission: take the new data, keep ERP ids so nothing is created twice.
         UPDATE xx_supplier_stg
            SET payload_json      = p_payload,
                supplier_name     = l_name,
                tax_id            = l_tax_id,
                status            = 'NEW',
                retry_count       = 0,
                next_retry_at     = NULL,
                error_step        = NULL,
                error_code        = NULL,
                error_http_status = NULL,
                error_message     = NULL,
                callback_status   = NULL,
                callback_attempts = 0,
                next_callback_at  = NULL,
                callback_message  = NULL,
                sensitive_purged  = 'N',
                updated_on        = SYSTIMESTAMP
          WHERE stg_id = p_stg_id;

         load_contacts(p_stg_id, p_payload);
         log_event(p_stg_id, 'RESUBMITTED');

         p_http_status      := 202;
         p_status           := 'NEW';
         p_message          := 'Resubmission accepted for processing.';
         p_start_processing := 'Y';

      ELSE
         p_http_status := 409;
         p_status      := l_row.status;
         p_message     := 'This sourceRef is already queued or being processed.';
         log_event(p_stg_id, 'RESENT_IGNORED', NULL, 'Status ' || l_row.status);
      END IF;
   END receive_supplier;

   PROCEDURE receive_supplier_b64 (
      p_payload_b64      IN  CLOB,
      p_stg_id           OUT NUMBER,
      p_http_status      OUT NUMBER,
      p_status           OUT VARCHAR2,
      p_supplier_number  OUT VARCHAR2,
      p_message          OUT VARCHAR2,
      p_start_processing OUT VARCHAR2)
   IS
      l_payload CLOB;
   BEGIN
      BEGIN
         l_payload := base64_to_clob(p_payload_b64);
      EXCEPTION
         WHEN OTHERS THEN
            l_payload := NULL;   -- reported as invalid JSON below
      END;
      receive_supplier(l_payload, p_stg_id, p_http_status, p_status,
                       p_supplier_number, p_message, p_start_processing);
   END receive_supplier_b64;

   -- ---------------------------------------------------------------------------
   -- (2) Process Supplier
   -- ---------------------------------------------------------------------------
   PROCEDURE claim_record (
      p_stg_id           IN  NUMBER,
      p_oic_instance_id  IN  VARCHAR2,
      p_claimed          OUT VARCHAR2)
   IS
   BEGIN
      UPDATE xx_supplier_stg
         SET status          = 'IN_PROGRESS',
             claimed_at      = SYSTIMESTAMP,
             oic_instance_id = p_oic_instance_id,
             updated_on      = SYSTIMESTAMP
       WHERE stg_id = p_stg_id
         AND status IN ('NEW', 'RETRY');

      IF SQL%ROWCOUNT = 1 THEN
         p_claimed := 'Y';
         log_event(p_stg_id, 'CLAIMED', NULL, NULL, p_oic_instance_id);
      ELSE
         p_claimed := 'N';
      END IF;
   END claim_record;

   PROCEDURE record_step (
      p_stg_id           IN  NUMBER,
      p_step             IN  VARCHAR2,
      p_erp_id           IN  NUMBER   DEFAULT NULL,
      p_erp_number       IN  VARCHAR2 DEFAULT NULL,
      p_erp_party_id     IN  NUMBER   DEFAULT NULL,
      p_oic_instance_id  IN  VARCHAR2 DEFAULT NULL)
   IS
      l_step VARCHAR2(20) := UPPER(TRIM(p_step));
   BEGIN
      IF step_no(l_step) = 0 THEN
         RAISE_APPLICATION_ERROR(-20001, 'Unknown step: ' || p_step);
      END IF;

      UPDATE xx_supplier_stg
         SET erp_supplier_id     = CASE WHEN l_step = 'SUPPLIER' THEN NVL(p_erp_id, erp_supplier_id) ELSE erp_supplier_id END,
             erp_supplier_number = CASE WHEN l_step = 'SUPPLIER' THEN NVL(p_erp_number, erp_supplier_number) ELSE erp_supplier_number END,
             erp_party_id        = CASE WHEN l_step = 'SUPPLIER' THEN NVL(p_erp_party_id, erp_party_id) ELSE erp_party_id END,
             erp_address_id      = CASE WHEN l_step = 'ADDRESS' THEN NVL(p_erp_id, erp_address_id) ELSE erp_address_id END,
             erp_site_id         = CASE WHEN l_step = 'SITE' THEN NVL(p_erp_id, erp_site_id) ELSE erp_site_id END,
             erp_tax_reg_id      = CASE WHEN l_step = 'TAX' THEN NVL(p_erp_id, erp_tax_reg_id) ELSE erp_tax_reg_id END,
             erp_bank_account_id = CASE WHEN l_step = 'BANK' THEN NVL(p_erp_id, erp_bank_account_id) ELSE erp_bank_account_id END,
             erp_instr_assign_id = CASE WHEN l_step = 'BANK_ASSIGN' THEN NVL(p_erp_id, erp_instr_assign_id) ELSE erp_instr_assign_id END,
             -- only ever move forward
             last_step_done      = CASE WHEN step_no(l_step) > step_no(last_step_done) THEN l_step ELSE last_step_done END,
             updated_on          = SYSTIMESTAMP
       WHERE stg_id = p_stg_id;

      IF SQL%ROWCOUNT = 0 THEN
         RAISE_APPLICATION_ERROR(-20002, 'Staging record not found: ' || p_stg_id);
      END IF;

      log_event(p_stg_id, 'STEP_DONE', l_step, 'erp_id=' || NVL(TO_CHAR(p_erp_id), '-'), p_oic_instance_id);
   END record_step;

   PROCEDURE record_contact (
      p_stg_id           IN  NUMBER,
      p_contact_seq      IN  NUMBER,
      p_erp_contact_id   IN  NUMBER)
   IS
   BEGIN
      UPDATE xx_supplier_stg_contact
         SET erp_contact_id = p_erp_contact_id,
             updated_on     = SYSTIMESTAMP
       WHERE stg_id = p_stg_id
         AND contact_seq = p_contact_seq;

      IF SQL%ROWCOUNT = 0 THEN
         RAISE_APPLICATION_ERROR(-20003, 'Contact not found: ' || p_stg_id || '/' || p_contact_seq);
      END IF;
   END record_contact;

   PROCEDURE mark_success (
      p_stg_id           IN  NUMBER,
      p_oic_instance_id  IN  VARCHAR2 DEFAULT NULL)
   IS
   BEGIN
      UPDATE xx_supplier_stg
         SET status            = 'SUCCESS',
             error_step        = NULL,
             error_code        = NULL,
             error_http_status = NULL,
             error_message     = NULL,
             next_retry_at     = NULL,
             callback_status   = 'PENDING',
             callback_attempts = 0,
             next_callback_at  = SYSTIMESTAMP + NUMTODSINTERVAL(c_callback_grace_minutes, 'MINUTE'),
             updated_on        = SYSTIMESTAMP
       WHERE stg_id = p_stg_id;

      IF SQL%ROWCOUNT = 0 THEN
         RAISE_APPLICATION_ERROR(-20002, 'Staging record not found: ' || p_stg_id);
      END IF;

      log_event(p_stg_id, 'SUCCESS', NULL, NULL, p_oic_instance_id);
   END mark_success;

   PROCEDURE mark_failure (
      p_stg_id              IN  NUMBER,
      p_step                IN  VARCHAR2,
      p_http_status         IN  NUMBER,
      p_error_code          IN  VARCHAR2,
      p_error_message       IN  VARCHAR2,
      p_oic_instance_id     IN  VARCHAR2 DEFAULT NULL,
      p_new_status          OUT VARCHAR2,
      p_send_error_callback OUT VARCHAR2)
   IS
      l_retry_count xx_supplier_stg.retry_count%TYPE;
      l_next_retry  TIMESTAMP;
   BEGIN
      SELECT retry_count INTO l_retry_count
        FROM xx_supplier_stg
       WHERE stg_id = p_stg_id
         FOR UPDATE;

      IF is_temporary_error(p_http_status, p_error_code) AND l_retry_count < c_max_retries THEN
         p_new_status          := 'RETRY';
         p_send_error_callback := 'N';
         l_next_retry          := SYSTIMESTAMP + retry_backoff(l_retry_count + 1);

         UPDATE xx_supplier_stg
            SET status        = 'RETRY',
                retry_count   = retry_count + 1,
                next_retry_at = l_next_retry
          WHERE stg_id = p_stg_id;
      ELSE
         p_new_status          := 'ERROR_FINAL';
         p_send_error_callback := 'Y';

         UPDATE xx_supplier_stg
            SET status            = 'ERROR_FINAL',
                next_retry_at     = NULL,
                callback_status   = 'PENDING',
                callback_attempts = 0,
                next_callback_at  = SYSTIMESTAMP + NUMTODSINTERVAL(c_callback_grace_minutes, 'MINUTE')
          WHERE stg_id = p_stg_id;
      END IF;

      UPDATE xx_supplier_stg
         SET error_step        = SUBSTR(UPPER(p_step), 1, 20),
             error_code        = SUBSTR(p_error_code, 1, 100),
             error_http_status = p_http_status,
             error_message     = SUBSTR(p_error_message, 1, 4000),
             updated_on        = SYSTIMESTAMP
       WHERE stg_id = p_stg_id;

      log_event(p_stg_id, 'FAILED_' || p_new_status, UPPER(p_step),
                'HTTP ' || NVL(TO_CHAR(p_http_status), '-') || ' ' || p_error_code || ': ' || p_error_message,
                p_oic_instance_id);
   END mark_failure;

   PROCEDURE mark_callback (
      p_stg_id           IN  NUMBER,
      p_success          IN  VARCHAR2,
      p_message          IN  VARCHAR2 DEFAULT NULL,
      p_oic_instance_id  IN  VARCHAR2 DEFAULT NULL)
   IS
      l_attempts xx_supplier_stg.callback_attempts%TYPE;
      l_next_cb  TIMESTAMP;
   BEGIN
      SELECT callback_attempts INTO l_attempts
        FROM xx_supplier_stg
       WHERE stg_id = p_stg_id
         FOR UPDATE;

      l_attempts := l_attempts + 1;
      IF p_success <> 'Y' AND l_attempts < c_max_callback_attempts THEN
         l_next_cb := SYSTIMESTAMP + callback_backoff(l_attempts);
      END IF;

      UPDATE xx_supplier_stg
         SET callback_attempts = l_attempts,
             callback_status   = CASE
                                    WHEN p_success = 'Y' THEN 'SENT'
                                    WHEN l_attempts >= c_max_callback_attempts THEN 'GAVE_UP'
                                    ELSE 'FAILED'
                                 END,
             next_callback_at  = l_next_cb,
             callback_message  = SUBSTR(p_message, 1, 4000),
             updated_on        = SYSTIMESTAMP
       WHERE stg_id = p_stg_id;

      log_event(p_stg_id, CASE WHEN p_success = 'Y' THEN 'CALLBACK_SENT' ELSE 'CALLBACK_FAILED' END,
                NULL, p_message, p_oic_instance_id);
   END mark_callback;

   -- ---------------------------------------------------------------------------
   -- (3) Retry job, manual reprocess, housekeeping
   -- ---------------------------------------------------------------------------
   PROCEDURE prepare_work (
      p_stuck_minutes    IN  NUMBER DEFAULT 30,
      p_released         OUT NUMBER)
   IS
   BEGIN
      p_released := 0;
      FOR r IN (SELECT stg_id, retry_count
                  FROM xx_supplier_stg
                 WHERE status = 'IN_PROGRESS'
                   AND claimed_at < SYSTIMESTAMP - NUMTODSINTERVAL(p_stuck_minutes, 'MINUTE')
                   FOR UPDATE SKIP LOCKED)
      LOOP
         IF r.retry_count < c_max_retries THEN
            UPDATE xx_supplier_stg
               SET status        = 'RETRY',
                   retry_count   = retry_count + 1,
                   next_retry_at = SYSTIMESTAMP,
                   updated_on    = SYSTIMESTAMP
             WHERE stg_id = r.stg_id;
            log_event(r.stg_id, 'STUCK_RELEASED');
         ELSE
            UPDATE xx_supplier_stg
               SET status            = 'ERROR_FINAL',
                   error_code        = 'STUCK',
                   error_message     = 'Processing did not finish after ' || (c_max_retries + 1) || ' attempts.',
                   callback_status   = 'PENDING',
                   callback_attempts = 0,
                   next_callback_at  = SYSTIMESTAMP,
                   updated_on        = SYSTIMESTAMP
             WHERE stg_id = r.stg_id;
            log_event(r.stg_id, 'FAILED_ERROR_FINAL', NULL, 'Stuck IN_PROGRESS, retries exhausted');
         END IF;
         p_released := p_released + 1;
      END LOOP;
   END prepare_work;

   PROCEDURE reprocess (
      p_stg_id           IN  NUMBER   DEFAULT NULL,
      p_source_ref       IN  VARCHAR2 DEFAULT NULL,
      p_result           OUT VARCHAR2,
      p_stg_id_out       OUT NUMBER)
   IS
      l_row xx_supplier_stg%ROWTYPE;
   BEGIN
      BEGIN
         SELECT * INTO l_row
           FROM xx_supplier_stg
          WHERE (p_stg_id IS NOT NULL AND stg_id = p_stg_id)
             OR (p_stg_id IS NULL AND source_ref = p_source_ref)
            FOR UPDATE;
      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            p_result := 'NOT_FOUND';
            RETURN;
      END;

      p_stg_id_out := l_row.stg_id;

      IF l_row.status IN ('ERROR_FINAL', 'RETRY') THEN
         IF l_row.sensitive_purged = 'Y' THEN
            -- Bank details were removed from the stored payload; Apex must resend the record.
            p_result := 'NOT_ALLOWED:PAYLOAD_PURGED';
            RETURN;
         END IF;

         UPDATE xx_supplier_stg
            SET status            = 'RETRY',
                retry_count       = 0,
                next_retry_at     = SYSTIMESTAMP,
                error_step        = NULL,
                error_code        = NULL,
                error_http_status = NULL,
                error_message     = NULL,
                callback_status   = NULL,
                callback_attempts = 0,
                next_callback_at  = NULL,
                updated_on        = SYSTIMESTAMP
          WHERE stg_id = l_row.stg_id;
         p_result := 'QUEUED';
         log_event(l_row.stg_id, 'REPROCESS');

      ELSIF l_row.status = 'SUCCESS' AND l_row.callback_status IN ('FAILED', 'GAVE_UP') THEN
         UPDATE xx_supplier_stg
            SET callback_status   = 'PENDING',
                callback_attempts = 0,
                next_callback_at  = SYSTIMESTAMP,
                updated_on        = SYSTIMESTAMP
          WHERE stg_id = l_row.stg_id;
         p_result := 'CALLBACK_QUEUED';
         log_event(l_row.stg_id, 'REPROCESS_CALLBACK');

      ELSE
         p_result := 'NOT_ALLOWED:' || l_row.status;
      END IF;
   END reprocess;

   PROCEDURE purge_sensitive (
      p_older_than_days  IN  NUMBER DEFAULT 7,
      p_purged           OUT NUMBER)
   IS
   BEGIN
      UPDATE xx_supplier_stg
         SET payload_json     = JSON_MERGEPATCH(payload_json, '{"bankAccount":null}' RETURNING CLOB),
             sensitive_purged = 'Y',
             updated_on       = SYSTIMESTAMP
       WHERE sensitive_purged = 'N'
         AND updated_on < SYSTIMESTAMP - NUMTODSINTERVAL(p_older_than_days, 'DAY')
         AND (   (status = 'SUCCESS' AND callback_status IN ('SENT', 'GAVE_UP'))
              OR (status = 'ERROR_FINAL' AND callback_status IN ('SENT', 'GAVE_UP')));
      p_purged := SQL%ROWCOUNT;
      IF p_purged > 0 THEN
         log_event(NULL, 'PURGED', NULL, p_purged || ' payload(s)');
      END IF;
   END purge_sensitive;

END xx_supplier_stg_pkg;
/
