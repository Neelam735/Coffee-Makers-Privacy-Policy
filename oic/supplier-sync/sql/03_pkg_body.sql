CREATE OR REPLACE PACKAGE BODY xx_sup_pkg AS

   -- ---------------------------------------------------------------------------
   -- Helpers
   -- ---------------------------------------------------------------------------
   TYPE t_names IS TABLE OF VARCHAR2(30);
   c_sections CONSTANT t_names := t_names('ADDRESS', 'SITE', 'CONTACT', 'TAX', 'BANK');
   c_arrays   CONSTANT t_names := t_names('addresses', 'sites', 'contacts', 'taxRegistrations', 'bankAccounts');

   -- Section table and its reference / name columns (fixed list, never user input).
   FUNCTION sec_table (p_type IN VARCHAR2) RETURN VARCHAR2 IS
   BEGIN
      RETURN CASE p_type
                WHEN 'ADDRESS' THEN 'XX_SUP_REQ_ADDRESS'
                WHEN 'SITE'    THEN 'XX_SUP_REQ_SITE'
                WHEN 'CONTACT' THEN 'XX_SUP_REQ_CONTACT'
                WHEN 'TAX'     THEN 'XX_SUP_REQ_TAX'
                WHEN 'BANK'    THEN 'XX_SUP_REQ_BANK'
             END;
   END sec_table;

   FUNCTION sec_ref_col (p_type IN VARCHAR2) RETURN VARCHAR2 IS
   BEGIN
      RETURN LOWER(p_type) || '_ref';
   END sec_ref_col;

   FUNCTION sec_name_col (p_type IN VARCHAR2) RETURN VARCHAR2 IS
   BEGIN
      RETURN CASE p_type
                WHEN 'ADDRESS' THEN 'address_name'
                WHEN 'SITE'    THEN 'site_name'
                ELSE 'CAST(NULL AS VARCHAR2(1))'
             END;
   END sec_name_col;

   PROCEDURE log_event (
      p_req_id          IN NUMBER,
      p_event           IN VARCHAR2,
      p_entity_type     IN VARCHAR2 DEFAULT NULL,
      p_entity_ref      IN VARCHAR2 DEFAULT NULL,
      p_detail          IN VARCHAR2 DEFAULT NULL,
      p_oic_instance_id IN VARCHAR2 DEFAULT NULL) IS
   BEGIN
      INSERT INTO xx_sup_log (req_id, event, entity_type, entity_ref, detail, oic_instance_id)
      VALUES (p_req_id, p_event, p_entity_type, SUBSTR(p_entity_ref, 1, 100),
              SUBSTR(p_detail, 1, 4000), p_oic_instance_id);
   END log_event;

   PROCEDURE add_msg (p_list IN OUT VARCHAR2, p_text IN VARCHAR2) IS
   BEGIN
      p_list := SUBSTR(p_list || CASE WHEN p_list IS NOT NULL THEN '; ' END || p_text, 1, 3900);
   END add_msg;

   FUNCTION jv (p_json IN CLOB, p_path IN VARCHAR2) RETURN VARCHAR2 IS
      l_value VARCHAR2(4000);
   BEGIN
      EXECUTE IMMEDIATE
         'SELECT JSON_VALUE(:j, ''' || p_path || ''' RETURNING VARCHAR2(4000) NULL ON ERROR) FROM dual'
         INTO l_value USING p_json;
      RETURN TRIM(l_value);
   END jv;

   -- Number of items in an array, e.g. p_array = 'addresses'.
   FUNCTION item_count (p_json IN CLOB, p_array IN VARCHAR2) RETURN NUMBER IS
      l_n NUMBER;
   BEGIN
      EXECUTE IMMEDIATE
         'SELECT COUNT(*) FROM JSON_TABLE(:j, ''$.' || p_array || '[*]'' COLUMNS (n FOR ORDINALITY))'
         INTO l_n USING p_json;
      RETURN l_n;
   END item_count;

   -- Adds "<array>[].<field>" to p_errors when any item misses that field.
   PROCEDURE require_field (p_json IN CLOB, p_array IN VARCHAR2, p_field IN VARCHAR2,
                            p_errors IN OUT VARCHAR2) IS
      l_n NUMBER;
   BEGIN
      EXECUTE IMMEDIATE
         'SELECT COUNT(*) FROM JSON_TABLE(:j, ''$.' || p_array || '[*]'' COLUMNS (v VARCHAR2(4000) PATH ''$.'
         || p_field || ''')) WHERE TRIM(v) IS NULL'
         INTO l_n USING p_json;
      IF l_n > 0 THEN
         add_msg(p_errors, p_array || '[].' || p_field || ' is required');
      END IF;
   END require_field;

   -- Reference field must be unique inside its array.
   PROCEDURE require_unique (p_json IN CLOB, p_array IN VARCHAR2, p_field IN VARCHAR2,
                             p_errors IN OUT VARCHAR2) IS
      l_n NUMBER;
   BEGIN
      EXECUTE IMMEDIATE
         'SELECT COUNT(TRIM(v)) - COUNT(DISTINCT TRIM(v)) FROM JSON_TABLE(:j, ''$.' || p_array
         || '[*]'' COLUMNS (v VARCHAR2(4000) PATH ''$.' || p_field || '''))'
         INTO l_n USING p_json;
      IF l_n > 0 THEN
         add_msg(p_errors, p_array || '[].' || p_field || ' must be unique');
      END IF;
   END require_unique;

   -- Optional country field: when present it must be a 2-letter ISO code.
   PROCEDURE require_country (p_json IN CLOB, p_array IN VARCHAR2, p_field IN VARCHAR2,
                              p_errors IN OUT VARCHAR2) IS
      l_n NUMBER;
   BEGIN
      EXECUTE IMMEDIATE
         'SELECT COUNT(*) FROM JSON_TABLE(:j, ''$.' || p_array || '[*]'' COLUMNS (v VARCHAR2(4000) PATH ''$.'
         || p_field || ''')) WHERE TRIM(v) IS NOT NULL AND LENGTH(TRIM(v)) <> 2'
         INTO l_n USING p_json;
      IF l_n > 0 THEN
         add_msg(p_errors, p_array || '[].' || p_field || ' must be a 2-letter ISO code');
      END IF;
   END require_country;

   -- Structure checks that do not depend on the lane. Returns NULL when valid.
   FUNCTION validate_payload (p_json IN CLOB) RETURN VARCHAR2 IS
      l_errors   VARCHAR2(4000);
      l_has_hdr  NUMBER;
      l_items    NUMBER := 0;
   BEGIN
      IF jv(p_json, '$.requestId') IS NULL THEN
         add_msg(l_errors, 'requestId is required');
      ELSIF LENGTH(jv(p_json, '$.requestId')) > 100 THEN
         add_msg(l_errors, 'requestId max 100 characters');
      END IF;
      IF jv(p_json, '$.supplierRef') IS NULL THEN
         add_msg(l_errors, 'supplierRef is required');
      ELSIF LENGTH(jv(p_json, '$.supplierRef')) > 100 THEN
         add_msg(l_errors, 'supplierRef max 100 characters');
      END IF;

      SELECT CASE WHEN JSON_EXISTS(p_json, '$.header') THEN 1 ELSE 0 END INTO l_has_hdr FROM dual;

      FOR i IN 1 .. c_arrays.COUNT LOOP
         l_items := l_items + item_count(p_json, c_arrays(i));
      END LOOP;
      IF l_has_hdr = 0 AND l_items = 0 THEN
         add_msg(l_errors, 'the message has no header and no items');
      END IF;

      require_field(p_json, 'addresses', 'addressRef', l_errors);
      require_field(p_json, 'addresses', 'addressName', l_errors);
      require_field(p_json, 'addresses', 'addressLine1', l_errors);
      require_field(p_json, 'addresses', 'city', l_errors);
      require_field(p_json, 'addresses', 'country', l_errors);
      require_country(p_json, 'addresses', 'country', l_errors);
      require_unique(p_json, 'addresses', 'addressRef', l_errors);

      require_field(p_json, 'sites', 'siteRef', l_errors);
      require_field(p_json, 'sites', 'addressRef', l_errors);
      require_field(p_json, 'sites', 'siteName', l_errors);
      require_field(p_json, 'sites', 'procurementBU', l_errors);
      require_unique(p_json, 'sites', 'siteRef', l_errors);

      require_field(p_json, 'contacts', 'contactRef', l_errors);
      require_field(p_json, 'contacts', 'lastName', l_errors);
      require_unique(p_json, 'contacts', 'contactRef', l_errors);

      require_field(p_json, 'taxRegistrations', 'taxRef', l_errors);
      require_field(p_json, 'taxRegistrations', 'taxRegimeCode', l_errors);
      require_field(p_json, 'taxRegistrations', 'registrationNumber', l_errors);
      require_country(p_json, 'taxRegistrations', 'country', l_errors);
      require_unique(p_json, 'taxRegistrations', 'taxRef', l_errors);

      require_field(p_json, 'bankAccounts', 'bankRef', l_errors);
      require_field(p_json, 'bankAccounts', 'bankName', l_errors);
      require_field(p_json, 'bankAccounts', 'branchName', l_errors);
      require_field(p_json, 'bankAccounts', 'accountNumber', l_errors);
      require_field(p_json, 'bankAccounts', 'country', l_errors);
      require_country(p_json, 'bankAccounts', 'country', l_errors);
      require_unique(p_json, 'bankAccounts', 'bankRef', l_errors);

      RETURN l_errors;
   END validate_payload;

   -- Splits the message into the section tables.
   PROCEDURE load_sections (p_req_id IN NUMBER, p_json IN CLOB) IS
   BEGIN
      INSERT INTO xx_sup_req_header (req_id, supplier_name, tax_organization_type, supplier_type,
                                     taxpayer_id, duns_number)
      SELECT p_req_id, TRIM(h.supplier_name), TRIM(h.tax_org_type), TRIM(h.supplier_type),
             TRIM(h.taxpayer_id), TRIM(h.duns_number)
        FROM JSON_TABLE(p_json, '$.header'
                COLUMNS (supplier_name VARCHAR2(360) PATH '$.supplierName',
                         tax_org_type  VARCHAR2(80)  PATH '$.taxOrganizationType',
                         supplier_type VARCHAR2(80)  PATH '$.supplierType',
                         taxpayer_id   VARCHAR2(50)  PATH '$.taxRegistrationNumber',
                         duns_number   VARCHAR2(30)  PATH '$.dunsNumber')) h;

      INSERT INTO xx_sup_req_address (req_id, line_no, address_ref, address_name, address_line1,
                                      address_line2, city, state, postal_code, country)
      SELECT p_req_id, a.line_no, TRIM(a.ref), TRIM(a.name), TRIM(a.line1), TRIM(a.line2),
             TRIM(a.city), TRIM(a.state), TRIM(a.postal), UPPER(TRIM(a.country))
        FROM JSON_TABLE(p_json, '$.addresses[*]'
                COLUMNS (line_no FOR ORDINALITY,
                         ref     VARCHAR2(100) PATH '$.addressRef',
                         name    VARCHAR2(240) PATH '$.addressName',
                         line1   VARCHAR2(240) PATH '$.addressLine1',
                         line2   VARCHAR2(240) PATH '$.addressLine2',
                         city    VARCHAR2(60)  PATH '$.city',
                         state   VARCHAR2(60)  PATH '$.state',
                         postal  VARCHAR2(60)  PATH '$.postalCode',
                         country VARCHAR2(10)  PATH '$.country')) a;

      INSERT INTO xx_sup_req_site (req_id, line_no, site_ref, address_ref, site_name, procurement_bu,
                                   payment_terms, payment_method, purchasing_flag, pay_flag)
      SELECT p_req_id, s.line_no, TRIM(s.ref), TRIM(s.addr), TRIM(s.name), TRIM(s.bu),
             TRIM(s.terms), TRIM(s.method), NVL(LOWER(s.purch), 'true'), NVL(LOWER(s.pay), 'true')
        FROM JSON_TABLE(p_json, '$.sites[*]'
                COLUMNS (line_no FOR ORDINALITY,
                         ref     VARCHAR2(100) PATH '$.siteRef',
                         addr    VARCHAR2(100) PATH '$.addressRef',
                         name    VARCHAR2(240) PATH '$.siteName',
                         bu      VARCHAR2(240) PATH '$.procurementBU',
                         terms   VARCHAR2(50)  PATH '$.paymentTerms',
                         method  VARCHAR2(30)  PATH '$.paymentMethod',
                         purch   VARCHAR2(5)   PATH '$.purchasingFlag',
                         pay     VARCHAR2(5)   PATH '$.payFlag')) s;

      INSERT INTO xx_sup_req_contact (req_id, line_no, contact_ref, first_name, last_name, email, phone)
      SELECT p_req_id, c.line_no, TRIM(c.ref), TRIM(c.first_name), TRIM(c.last_name),
             TRIM(c.email), TRIM(c.phone)
        FROM JSON_TABLE(p_json, '$.contacts[*]'
                COLUMNS (line_no    FOR ORDINALITY,
                         ref        VARCHAR2(100) PATH '$.contactRef',
                         first_name VARCHAR2(150) PATH '$.firstName',
                         last_name  VARCHAR2(150) PATH '$.lastName',
                         email      VARCHAR2(320) PATH '$.email',
                         phone      VARCHAR2(60)  PATH '$.phone')) c;

      INSERT INTO xx_sup_req_tax (req_id, line_no, tax_ref, tax_regime_code, registration_number,
                                  country, effective_from)
      SELECT p_req_id, t.line_no, TRIM(t.ref), TRIM(t.regime), TRIM(t.reg_no),
             UPPER(TRIM(t.country)), TRIM(t.eff)
        FROM JSON_TABLE(p_json, '$.taxRegistrations[*]'
                COLUMNS (line_no FOR ORDINALITY,
                         ref     VARCHAR2(100) PATH '$.taxRef',
                         regime  VARCHAR2(30)  PATH '$.taxRegimeCode',
                         reg_no  VARCHAR2(50)  PATH '$.registrationNumber',
                         country VARCHAR2(10)  PATH '$.country',
                         eff     VARCHAR2(10)  PATH '$.effectiveFrom')) t;

      INSERT INTO xx_sup_req_bank (req_id, line_no, bank_ref, bank_name, branch_name, account_number,
                                   iban, account_name, currency_code, country, account_type)
      SELECT p_req_id, b.line_no, TRIM(b.ref), TRIM(b.bank), TRIM(b.branch),
             REGEXP_REPLACE(b.acct, '[[:space:]]', ''), UPPER(REGEXP_REPLACE(b.iban, '[[:space:]]', '')),
             TRIM(b.acct_name), UPPER(TRIM(b.ccy)), UPPER(TRIM(b.country)), TRIM(b.acct_type)
        FROM JSON_TABLE(p_json, '$.bankAccounts[*]'
                COLUMNS (line_no   FOR ORDINALITY,
                         ref       VARCHAR2(100) PATH '$.bankRef',
                         bank      VARCHAR2(360) PATH '$.bankName',
                         branch    VARCHAR2(360) PATH '$.branchName',
                         acct      VARCHAR2(100) PATH '$.accountNumber',
                         iban      VARCHAR2(50)  PATH '$.iban',
                         acct_name VARCHAR2(360) PATH '$.accountName',
                         ccy       VARCHAR2(15)  PATH '$.currencyCode',
                         country   VARCHAR2(10)  PATH '$.country',
                         acct_type VARCHAR2(30)  PATH '$.accountType')) b;
   END load_sections;

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

   -- An earlier message for the same supplier that is not finished yet.
   FUNCTION earlier_unfinished (p_supplier_ref IN VARCHAR2, p_req_id IN NUMBER) RETURN BOOLEAN IS
      l_n NUMBER;
   BEGIN
      SELECT COUNT(*) INTO l_n
        FROM xx_sup_req
       WHERE supplier_ref = p_supplier_ref
         AND req_id < p_req_id
         AND status IN ('NEW', 'IN_PROGRESS', 'RETRY');
      RETURN l_n > 0;
   END earlier_unfinished;

   -- The next NEW message for the same supplier, to start as soon as this one finishes.
   FUNCTION next_waiting (p_supplier_ref IN VARCHAR2, p_req_id IN NUMBER) RETURN NUMBER IS
      l_next NUMBER;
   BEGIN
      SELECT MIN(req_id) INTO l_next
        FROM xx_sup_req
       WHERE supplier_ref = p_supplier_ref
         AND req_id > p_req_id
         AND status = 'NEW';
      RETURN l_next;
   END next_waiting;

   FUNCTION open_items (p_req_id IN NUMBER) RETURN NUMBER IS
      l_n NUMBER;
   BEGIN
      SELECT (SELECT COUNT(*) FROM xx_sup_req_header  WHERE req_id = p_req_id AND process_status <> 'DONE')
           + (SELECT COUNT(*) FROM xx_sup_req_address WHERE req_id = p_req_id AND process_status <> 'DONE')
           + (SELECT COUNT(*) FROM xx_sup_req_site    WHERE req_id = p_req_id AND process_status <> 'DONE')
           + (SELECT COUNT(*) FROM xx_sup_req_contact WHERE req_id = p_req_id AND process_status <> 'DONE')
           + (SELECT COUNT(*) FROM xx_sup_req_tax     WHERE req_id = p_req_id AND process_status <> 'DONE')
           + (SELECT COUNT(*) FROM xx_sup_req_bank    WHERE req_id = p_req_id AND process_status <> 'DONE')
        INTO l_n FROM dual;
      RETURN l_n;
   END open_items;

   FUNCTION done_items (p_req_id IN NUMBER) RETURN NUMBER IS
      l_n NUMBER;
   BEGIN
      SELECT (SELECT COUNT(*) FROM xx_sup_req_header  WHERE req_id = p_req_id AND process_status = 'DONE')
           + (SELECT COUNT(*) FROM xx_sup_req_address WHERE req_id = p_req_id AND process_status = 'DONE')
           + (SELECT COUNT(*) FROM xx_sup_req_site    WHERE req_id = p_req_id AND process_status = 'DONE')
           + (SELECT COUNT(*) FROM xx_sup_req_contact WHERE req_id = p_req_id AND process_status = 'DONE')
           + (SELECT COUNT(*) FROM xx_sup_req_tax     WHERE req_id = p_req_id AND process_status = 'DONE')
           + (SELECT COUNT(*) FROM xx_sup_req_bank    WHERE req_id = p_req_id AND process_status = 'DONE')
        INTO l_n FROM dual;
      RETURN l_n;
   END done_items;

   -- Moves ERROR items back to PENDING (and optionally clears their operation).
   PROCEDURE reset_items (p_req_id IN NUMBER, p_clear_operation IN BOOLEAN) IS
   BEGIN
      UPDATE xx_sup_req_header
         SET process_status = CASE WHEN process_status = 'ERROR' THEN 'PENDING' ELSE process_status END,
             operation      = CASE WHEN p_clear_operation THEN NULL ELSE operation END
       WHERE req_id = p_req_id;
      FOR i IN 1 .. c_sections.COUNT LOOP
         EXECUTE IMMEDIATE
            'UPDATE ' || sec_table(c_sections(i))
            || ' SET process_status = CASE WHEN process_status = ''ERROR'' THEN ''PENDING'' ELSE process_status END'
            || CASE WHEN p_clear_operation THEN ', operation = NULL' END
            || ' WHERE req_id = :id'
            USING p_req_id;
      END LOOP;
   END reset_items;

   FUNCTION is_temporary_error (p_http_status IN NUMBER, p_error_code IN VARCHAR2) RETURN BOOLEAN IS
   BEGIN
      RETURN NVL(p_http_status, 0) = 0
          OR p_http_status IN (408, 429)
          OR p_http_status >= 500
          OR UPPER(p_error_code) IN ('TIMEOUT', 'CONNECTION', 'SERVICE_UNAVAILABLE');
   END is_temporary_error;

   FUNCTION retry_backoff (p_attempt IN PLS_INTEGER) RETURN INTERVAL DAY TO SECOND IS
   BEGIN
      RETURN NUMTODSINTERVAL(CASE p_attempt WHEN 1 THEN 15 WHEN 2 THEN 60 ELSE 240 END, 'MINUTE');
   END retry_backoff;

   FUNCTION callback_backoff (p_attempt IN PLS_INTEGER) RETURN INTERVAL DAY TO SECOND IS
   BEGIN
      RETURN NUMTODSINTERVAL(CASE p_attempt WHEN 1 THEN 5 WHEN 2 THEN 15 WHEN 3 THEN 60 ELSE 240 END,
                             'MINUTE');
   END callback_backoff;

   -- ---------------------------------------------------------------------------
   -- XX_SUP_RECEIVE
   -- ---------------------------------------------------------------------------
   PROCEDURE receive_request (
      p_payload          IN  CLOB,
      p_req_id           OUT NUMBER,
      p_http_status      OUT NUMBER,
      p_status           OUT VARCHAR2,
      p_supplier_number  OUT VARCHAR2,
      p_message          OUT VARCHAR2,
      p_start_processing OUT VARCHAR2)
   IS
      l_is_json      NUMBER;
      l_errors       VARCHAR2(4000);
      l_request_id   xx_sup_req.request_id%TYPE;
      l_supplier_ref xx_sup_req.supplier_ref%TYPE;
      l_row          xx_sup_req%ROWTYPE;
   BEGIN
      p_start_processing := 'N';

      SELECT CASE WHEN p_payload IS JSON THEN 1 ELSE 0 END INTO l_is_json FROM dual;
      IF p_payload IS NULL OR l_is_json = 0 THEN
         p_http_status := 400;
         p_status      := 'REJECTED';
         p_message     := 'Request body is not valid JSON.';
         log_event(NULL, 'REJECTED', NULL, NULL, p_message);
         RETURN;
      END IF;

      l_errors := validate_payload(p_payload);
      IF l_errors IS NOT NULL THEN
         p_http_status := 400;
         p_status      := 'REJECTED';
         p_message     := SUBSTR('Invalid message: ' || l_errors, 1, 4000);
         log_event(NULL, 'REJECTED', NULL, SUBSTR(jv(p_payload, '$.requestId'), 1, 100), p_message);
         RETURN;
      END IF;

      l_request_id   := jv(p_payload, '$.requestId');
      l_supplier_ref := jv(p_payload, '$.supplierRef');

      BEGIN
         INSERT INTO xx_sup_req (request_id, supplier_ref, payload_json)
         VALUES (l_request_id, l_supplier_ref, p_payload)
         RETURNING req_id INTO p_req_id;
      EXCEPTION
         WHEN DUP_VAL_ON_INDEX THEN
            SELECT * INTO l_row FROM xx_sup_req WHERE request_id = l_request_id;
            p_req_id := l_row.req_id;
            p_status := l_row.status;
            IF l_row.status = 'SUCCESS' THEN
               p_http_status := 200;
               SELECT MAX(erp_supplier_number) INTO p_supplier_number
                 FROM xx_sup_master WHERE supplier_ref = l_row.supplier_ref;
               p_message := 'This requestId was already processed successfully.';
            ELSE
               p_http_status := 409;
               p_message := 'This requestId was already received (status ' || l_row.status
                            || '). Send corrections with a new requestId.';
            END IF;
            log_event(p_req_id, 'DUPLICATE_IGNORED', NULL, NULL, 'Status ' || l_row.status);
            RETURN;
      END;

      load_sections(p_req_id, p_payload);
      log_event(p_req_id, 'RECEIVED');

      p_http_status      := 202;
      p_status           := 'NEW';
      p_message          := 'Accepted for processing.';
      p_start_processing := 'Y';
   END receive_request;

   PROCEDURE receive_request_b64 (
      p_payload_b64      IN  CLOB,
      p_req_id           OUT NUMBER,
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
      receive_request(l_payload, p_req_id, p_http_status, p_status,
                      p_supplier_number, p_message, p_start_processing);
   END receive_request_b64;

   -- ---------------------------------------------------------------------------
   -- XX_SUP_PROCESS
   -- ---------------------------------------------------------------------------
   PROCEDURE claim_request (
      p_req_id              IN  NUMBER,
      p_oic_instance_id     IN  VARCHAR2,
      p_result              OUT VARCHAR2,
      p_lane                OUT VARCHAR2,
      p_send_error_callback OUT VARCHAR2)
   IS
      l_row     xx_sup_req%ROWTYPE;
      l_master  NUMBER;
      l_errors  VARCHAR2(4000);
      l_n       NUMBER;
      l_list    VARCHAR2(4000);
   BEGIN
      p_send_error_callback := 'N';

      BEGIN
         SELECT * INTO l_row FROM xx_sup_req WHERE req_id = p_req_id FOR UPDATE;
      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            p_result := 'NOT_AVAILABLE';
            RETURN;
      END;

      p_lane := l_row.lane;

      IF l_row.status NOT IN ('NEW', 'RETRY') THEN
         p_result := 'NOT_AVAILABLE';
         RETURN;
      END IF;

      IF earlier_unfinished(l_row.supplier_ref, p_req_id) THEN
         p_result := 'WAITING';
         log_event(p_req_id, 'WAITING', NULL, NULL, 'Earlier message for this supplier not finished',
                   p_oic_instance_id);
         RETURN;
      END IF;

      IF l_row.lane IS NULL THEN
         -- First claim: choose the lane and the operation of every item.
         SELECT COUNT(*) INTO l_master FROM xx_sup_master WHERE supplier_ref = l_row.supplier_ref;
         p_lane := CASE WHEN l_master = 0 THEN 'CREATE' ELSE 'UPDATE' END;

         UPDATE xx_sup_req_header
            SET operation = p_lane
          WHERE req_id = p_req_id;

         FOR i IN 1 .. c_sections.COUNT LOOP
            EXECUTE IMMEDIATE
               'UPDATE ' || sec_table(c_sections(i)) || ' s'
               || ' SET operation = CASE WHEN EXISTS (SELECT 1 FROM xx_sup_xref x'
               || ' WHERE x.supplier_ref = :sup AND x.entity_type = :typ'
               || ' AND x.entity_ref = s.' || sec_ref_col(c_sections(i)) || ')'
               || ' THEN ''UPDATE'' ELSE ''CREATE'' END'
               || ' WHERE req_id = :id'
               USING l_row.supplier_ref, c_sections(i), p_req_id;
         END LOOP;

         -- Lane rules
         IF p_lane = 'CREATE' THEN
            SELECT COUNT(*) INTO l_n FROM xx_sup_req_header WHERE req_id = p_req_id;
            IF l_n = 0 THEN
               add_msg(l_errors, 'supplier ' || l_row.supplier_ref
                                 || ' does not exist in ERP yet, so the header is required');
            ELSE
               SELECT COUNT(*) INTO l_n FROM xx_sup_req_header
                WHERE req_id = p_req_id AND (supplier_name IS NULL OR taxpayer_id IS NULL);
               IF l_n > 0 THEN
                  add_msg(l_errors, 'header.supplierName and header.taxRegistrationNumber are required to create a supplier');
               END IF;
            END IF;
            SELECT COUNT(*) INTO l_n FROM xx_sup_req_address WHERE req_id = p_req_id;
            IF l_n = 0 THEN
               add_msg(l_errors, 'at least one address is required to create a supplier');
            END IF;
            SELECT COUNT(*) INTO l_n FROM xx_sup_req_site WHERE req_id = p_req_id;
            IF l_n = 0 THEN
               add_msg(l_errors, 'at least one site is required to create a supplier');
            END IF;
         END IF;

         -- Every site's address must be in this message or already in ERP.
         SELECT LISTAGG(s.site_ref, ', ') WITHIN GROUP (ORDER BY s.line_no)
           INTO l_list
           FROM xx_sup_req_site s
          WHERE s.req_id = p_req_id
            AND NOT EXISTS (SELECT 1 FROM xx_sup_req_address a
                             WHERE a.req_id = p_req_id AND a.address_ref = s.address_ref)
            AND NOT EXISTS (SELECT 1 FROM xx_sup_xref x
                             WHERE x.supplier_ref = l_row.supplier_ref AND x.entity_type = 'ADDRESS'
                               AND x.entity_ref = s.address_ref);
         IF l_list IS NOT NULL THEN
            add_msg(l_errors, 'unknown addressRef on site(s) ' || l_list);
         END IF;

         IF l_errors IS NOT NULL THEN
            UPDATE xx_sup_req
               SET lane              = p_lane,
                   status            = 'ERROR_FINAL',
                   error_entity      = NULL,
                   error_ref         = NULL,
                   error_code        = 'VALIDATION',
                   error_http_status = 400,
                   error_message     = SUBSTR(l_errors, 1, 4000),
                   callback_status   = 'PENDING',
                   callback_attempts = 0,
                   next_callback_at  = SYSTIMESTAMP + NUMTODSINTERVAL(c_callback_grace_minutes, 'MINUTE'),
                   oic_instance_id   = p_oic_instance_id,
                   updated_on        = SYSTIMESTAMP
             WHERE req_id = p_req_id;
            p_result              := 'REJECTED';
            p_send_error_callback := 'Y';
            log_event(p_req_id, 'REJECTED', NULL, NULL, l_errors, p_oic_instance_id);
            RETURN;
         END IF;
      ELSE
         reset_items(p_req_id, FALSE);
      END IF;

      UPDATE xx_sup_req
         SET lane            = p_lane,
             status          = 'IN_PROGRESS',
             claimed_at      = SYSTIMESTAMP,
             oic_instance_id = p_oic_instance_id,
             updated_on      = SYSTIMESTAMP
       WHERE req_id = p_req_id;

      p_result := 'CLAIMED';
      log_event(p_req_id, 'CLAIMED', NULL, NULL, 'Lane ' || p_lane, p_oic_instance_id);
   END claim_request;

   PROCEDURE line_done (
      p_req_id           IN  NUMBER,
      p_entity_type      IN  VARCHAR2,
      p_entity_ref       IN  VARCHAR2,
      p_erp_id           IN  NUMBER   DEFAULT NULL,
      p_erp_id2          IN  NUMBER   DEFAULT NULL,
      p_erp_number       IN  VARCHAR2 DEFAULT NULL,
      p_complete         IN  VARCHAR2 DEFAULT 'Y',
      p_oic_instance_id  IN  VARCHAR2 DEFAULT NULL)
   IS
      l_type     VARCHAR2(10) := UPPER(TRIM(p_entity_type));
      l_complete VARCHAR2(1)  := CASE WHEN UPPER(p_complete) = 'N' THEN 'N' ELSE 'Y' END;
      l_sup      xx_sup_req.supplier_ref%TYPE;
      l_hdr      xx_sup_req_header%ROWTYPE;
      l_erp_id   NUMBER;
      l_erp_id2  NUMBER;
      l_name     VARCHAR2(360);
      l_n        NUMBER;
   BEGIN
      SELECT supplier_ref INTO l_sup FROM xx_sup_req WHERE req_id = p_req_id;

      IF l_type = 'HEADER' THEN
         UPDATE xx_sup_req_header
            SET erp_id         = NVL(p_erp_id, erp_id),
                erp_id2        = NVL(p_erp_id2, erp_id2),
                erp_number     = NVL(p_erp_number, erp_number),
                process_status = CASE WHEN l_complete = 'Y' THEN 'DONE' ELSE process_status END,
                error_message  = CASE WHEN l_complete = 'Y' THEN NULL ELSE error_message END,
                updated_on     = SYSTIMESTAMP
          WHERE req_id = p_req_id
         RETURNING supplier_name, taxpayer_id, erp_id, erp_id2, erp_number
              INTO l_hdr.supplier_name, l_hdr.taxpayer_id, l_hdr.erp_id, l_hdr.erp_id2, l_hdr.erp_number;

         IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'Message ' || p_req_id || ' has no header');
         END IF;

         IF l_complete = 'Y' THEN
            SELECT COUNT(*) INTO l_n FROM xx_sup_master WHERE supplier_ref = l_sup;
            IF l_n = 0 THEN
               IF l_hdr.erp_id IS NULL THEN
                  RAISE_APPLICATION_ERROR(-20003, 'SupplierId (p_erp_id) is required to create the master row');
               END IF;
               INSERT INTO xx_sup_master (supplier_ref, erp_supplier_id, erp_supplier_number, erp_party_id,
                                          supplier_name, taxpayer_id, created_req_id, last_req_id)
               VALUES (l_sup, l_hdr.erp_id, l_hdr.erp_number, l_hdr.erp_id2,
                       l_hdr.supplier_name, l_hdr.taxpayer_id, p_req_id, p_req_id);
            ELSE
               UPDATE xx_sup_master
                  SET erp_supplier_id     = NVL(l_hdr.erp_id, erp_supplier_id),
                      erp_supplier_number = NVL(l_hdr.erp_number, erp_supplier_number),
                      erp_party_id        = NVL(l_hdr.erp_id2, erp_party_id),
                      supplier_name       = NVL(l_hdr.supplier_name, supplier_name),
                      taxpayer_id         = NVL(l_hdr.taxpayer_id, taxpayer_id),
                      last_req_id         = p_req_id,
                      updated_on          = SYSTIMESTAMP
                WHERE supplier_ref = l_sup;
            END IF;
         END IF;

      ELSIF sec_table(l_type) IS NOT NULL THEN
         EXECUTE IMMEDIATE
            'UPDATE ' || sec_table(l_type)
            || ' SET erp_id = NVL(:a, erp_id), erp_id2 = NVL(:b, erp_id2), erp_number = NVL(:c, erp_number),'
            || ' process_status = CASE WHEN :d = ''Y'' THEN ''DONE'' ELSE process_status END,'
            || ' error_message = CASE WHEN :e = ''Y'' THEN NULL ELSE error_message END,'
            || ' updated_on = SYSTIMESTAMP'
            || ' WHERE req_id = :id AND ' || sec_ref_col(l_type) || ' = :ref'
            USING p_erp_id, p_erp_id2, p_erp_number, l_complete, l_complete, p_req_id, p_entity_ref;

         IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20002, l_type || ' ' || p_entity_ref || ' not found in message ' || p_req_id);
         END IF;

         IF l_complete = 'Y' THEN
            EXECUTE IMMEDIATE
               'SELECT erp_id, erp_id2, ' || sec_name_col(l_type) || ' FROM ' || sec_table(l_type)
               || ' WHERE req_id = :id AND ' || sec_ref_col(l_type) || ' = :ref'
               INTO l_erp_id, l_erp_id2, l_name
               USING p_req_id, p_entity_ref;

            SELECT COUNT(*) INTO l_n FROM xx_sup_master WHERE supplier_ref = l_sup;
            IF l_n = 0 THEN
               RAISE_APPLICATION_ERROR(-20004, 'Supplier ' || l_sup || ' is not in XX_SUP_MASTER: complete the HEADER first');
            END IF;

            MERGE INTO xx_sup_xref x
            USING (SELECT l_sup AS supplier_ref, l_type AS entity_type, p_entity_ref AS entity_ref FROM dual) s
               ON (x.supplier_ref = s.supplier_ref AND x.entity_type = s.entity_type AND x.entity_ref = s.entity_ref)
             WHEN MATCHED THEN UPDATE
                  SET x.erp_id      = NVL(l_erp_id, x.erp_id),
                      x.erp_id2     = NVL(l_erp_id2, x.erp_id2),
                      x.erp_name    = NVL(l_name, x.erp_name),
                      x.last_req_id = p_req_id,
                      x.updated_on  = SYSTIMESTAMP
             WHEN NOT MATCHED THEN
                  INSERT (supplier_ref, entity_type, entity_ref, erp_id, erp_id2, erp_name, created_req_id, last_req_id)
                  VALUES (s.supplier_ref, s.entity_type, s.entity_ref, l_erp_id, l_erp_id2, l_name, p_req_id, p_req_id);
         END IF;
      ELSE
         RAISE_APPLICATION_ERROR(-20001, 'Unknown entity type: ' || p_entity_type);
      END IF;

      log_event(p_req_id, CASE WHEN l_complete = 'Y' THEN 'ITEM_DONE' ELSE 'ITEM_IDS_SAVED' END,
                l_type, NVL(p_entity_ref, l_sup),
                'erp_id=' || NVL(TO_CHAR(p_erp_id), '-') || ' erp_id2=' || NVL(TO_CHAR(p_erp_id2), '-'),
                p_oic_instance_id);
   END line_done;

   PROCEDURE mark_failure (
      p_req_id              IN  NUMBER,
      p_entity_type         IN  VARCHAR2,
      p_entity_ref          IN  VARCHAR2,
      p_http_status         IN  NUMBER,
      p_error_code          IN  VARCHAR2,
      p_error_message       IN  VARCHAR2,
      p_oic_instance_id     IN  VARCHAR2 DEFAULT NULL,
      p_new_status          OUT VARCHAR2,
      p_send_error_callback OUT VARCHAR2,
      p_next_req_id         OUT NUMBER)
   IS
      l_type   VARCHAR2(10) := UPPER(TRIM(p_entity_type));
      l_row    xx_sup_req%ROWTYPE;
      l_next   TIMESTAMP;
      l_msg    VARCHAR2(4000) := SUBSTR(p_error_message, 1, 4000);
   BEGIN
      SELECT * INTO l_row FROM xx_sup_req WHERE req_id = p_req_id FOR UPDATE;

      -- Mark the item that failed.
      IF l_type = 'HEADER' THEN
         UPDATE xx_sup_req_header
            SET process_status = 'ERROR', error_message = l_msg, updated_on = SYSTIMESTAMP
          WHERE req_id = p_req_id;
      ELSIF sec_table(l_type) IS NOT NULL THEN
         EXECUTE IMMEDIATE
            'UPDATE ' || sec_table(l_type)
            || ' SET process_status = ''ERROR'', error_message = :m, updated_on = SYSTIMESTAMP'
            || ' WHERE req_id = :id AND ' || sec_ref_col(l_type) || ' = :ref'
            USING l_msg, p_req_id, p_entity_ref;
      END IF;

      IF is_temporary_error(p_http_status, p_error_code) AND l_row.retry_count < c_max_retries THEN
         p_new_status          := 'RETRY';
         p_send_error_callback := 'N';
         l_next                := SYSTIMESTAMP + retry_backoff(l_row.retry_count + 1);
         UPDATE xx_sup_req
            SET status        = 'RETRY',
                retry_count   = retry_count + 1,
                next_retry_at = l_next
          WHERE req_id = p_req_id;
      ELSE
         p_new_status          := 'ERROR_FINAL';
         p_send_error_callback := 'Y';
         p_next_req_id         := next_waiting(l_row.supplier_ref, p_req_id);
         UPDATE xx_sup_req
            SET status            = 'ERROR_FINAL',
                next_retry_at     = NULL,
                callback_status   = 'PENDING',
                callback_attempts = 0,
                next_callback_at  = SYSTIMESTAMP + NUMTODSINTERVAL(c_callback_grace_minutes, 'MINUTE')
          WHERE req_id = p_req_id;
      END IF;

      UPDATE xx_sup_req
         SET error_entity      = l_type,
             error_ref         = SUBSTR(p_entity_ref, 1, 100),
             error_code        = SUBSTR(p_error_code, 1, 100),
             error_http_status = p_http_status,
             error_message     = l_msg,
             updated_on        = SYSTIMESTAMP
       WHERE req_id = p_req_id;

      log_event(p_req_id, 'FAILED_' || p_new_status, l_type, p_entity_ref,
                'HTTP ' || NVL(TO_CHAR(p_http_status), '-') || ' ' || p_error_code || ': ' || l_msg,
                p_oic_instance_id);
   END mark_failure;

   PROCEDURE mark_success (
      p_req_id           IN  NUMBER,
      p_oic_instance_id  IN  VARCHAR2 DEFAULT NULL,
      p_next_req_id      OUT NUMBER)
   IS
      l_open NUMBER := open_items(p_req_id);
      l_sup  xx_sup_req.supplier_ref%TYPE;
   BEGIN
      IF l_open > 0 THEN
         RAISE_APPLICATION_ERROR(-20010, l_open || ' item(s) of message ' || p_req_id || ' are not DONE');
      END IF;

      UPDATE xx_sup_req
         SET status            = 'SUCCESS',
             next_retry_at     = NULL,
             error_entity      = NULL,
             error_ref         = NULL,
             error_code        = NULL,
             error_http_status = NULL,
             error_message     = NULL,
             callback_status   = 'PENDING',
             callback_attempts = 0,
             next_callback_at  = SYSTIMESTAMP + NUMTODSINTERVAL(c_callback_grace_minutes, 'MINUTE'),
             updated_on        = SYSTIMESTAMP
       WHERE req_id = p_req_id
      RETURNING supplier_ref INTO l_sup;

      IF SQL%ROWCOUNT = 0 THEN
         RAISE_APPLICATION_ERROR(-20002, 'Message not found: ' || p_req_id);
      END IF;

      p_next_req_id := next_waiting(l_sup, p_req_id);
      log_event(p_req_id, 'SUCCESS', NULL, NULL, NULL, p_oic_instance_id);
   END mark_success;

   -- ---------------------------------------------------------------------------
   -- XX_SUP_CALLBACK, XX_SUP_RETRY_JOB, XX_SUP_REPROCESS, housekeeping
   -- ---------------------------------------------------------------------------
   PROCEDURE mark_callback (
      p_req_id           IN  NUMBER,
      p_success          IN  VARCHAR2,
      p_message          IN  VARCHAR2 DEFAULT NULL,
      p_oic_instance_id  IN  VARCHAR2 DEFAULT NULL)
   IS
      l_attempts xx_sup_req.callback_attempts%TYPE;
      l_next_cb  TIMESTAMP;
   BEGIN
      SELECT callback_attempts INTO l_attempts FROM xx_sup_req WHERE req_id = p_req_id FOR UPDATE;

      l_attempts := l_attempts + 1;
      IF p_success <> 'Y' AND l_attempts < c_max_callback_attempts THEN
         l_next_cb := SYSTIMESTAMP + callback_backoff(l_attempts);
      END IF;

      UPDATE xx_sup_req
         SET callback_attempts = l_attempts,
             callback_status   = CASE
                                    WHEN p_success = 'Y' THEN 'SENT'
                                    WHEN l_attempts >= c_max_callback_attempts THEN 'GAVE_UP'
                                    ELSE 'FAILED'
                                 END,
             next_callback_at  = l_next_cb,
             callback_message  = SUBSTR(p_message, 1, 4000),
             updated_on        = SYSTIMESTAMP
       WHERE req_id = p_req_id;

      log_event(p_req_id, CASE WHEN p_success = 'Y' THEN 'CALLBACK_SENT' ELSE 'CALLBACK_FAILED' END,
                NULL, NULL, p_message, p_oic_instance_id);
   END mark_callback;

   PROCEDURE prepare_work (
      p_stuck_minutes    IN  NUMBER DEFAULT 30,
      p_released         OUT NUMBER)
   IS
   BEGIN
      p_released := 0;
      FOR r IN (SELECT req_id, retry_count
                  FROM xx_sup_req
                 WHERE status = 'IN_PROGRESS'
                   AND claimed_at < SYSTIMESTAMP - NUMTODSINTERVAL(p_stuck_minutes, 'MINUTE')
                   FOR UPDATE SKIP LOCKED)
      LOOP
         IF r.retry_count < c_max_retries THEN
            UPDATE xx_sup_req
               SET status        = 'RETRY',
                   retry_count   = retry_count + 1,
                   next_retry_at = SYSTIMESTAMP,
                   updated_on    = SYSTIMESTAMP
             WHERE req_id = r.req_id;
            log_event(r.req_id, 'STUCK_RELEASED');
         ELSE
            UPDATE xx_sup_req
               SET status            = 'ERROR_FINAL',
                   error_code        = 'STUCK',
                   error_message     = 'Processing did not finish after ' || (c_max_retries + 1) || ' attempts.',
                   callback_status   = 'PENDING',
                   callback_attempts = 0,
                   next_callback_at  = SYSTIMESTAMP,
                   updated_on        = SYSTIMESTAMP
             WHERE req_id = r.req_id;
            log_event(r.req_id, 'FAILED_ERROR_FINAL', NULL, NULL, 'Stuck IN_PROGRESS, retries exhausted');
         END IF;
         p_released := p_released + 1;
      END LOOP;
   END prepare_work;

   PROCEDURE reprocess (
      p_req_id           IN  NUMBER   DEFAULT NULL,
      p_request_id       IN  VARCHAR2 DEFAULT NULL,
      p_result           OUT VARCHAR2,
      p_req_id_out       OUT NUMBER)
   IS
      l_row xx_sup_req%ROWTYPE;
   BEGIN
      BEGIN
         SELECT * INTO l_row
           FROM xx_sup_req
          WHERE (p_req_id IS NOT NULL AND req_id = p_req_id)
             OR (p_req_id IS NULL AND request_id = p_request_id)
            FOR UPDATE;
      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            p_result := 'NOT_FOUND';
            RETURN;
      END;

      p_req_id_out := l_row.req_id;

      IF l_row.status IN ('ERROR_FINAL', 'RETRY') THEN
         IF l_row.sensitive_purged = 'Y' THEN
            p_result := 'NOT_ALLOWED:PAYLOAD_PURGED';   -- bank details are gone; Apex must resend
            RETURN;
         END IF;

         -- Nothing reached ERP yet -> let the next claim choose the lane again.
         IF done_items(l_row.req_id) = 0 THEN
            reset_items(l_row.req_id, TRUE);
            UPDATE xx_sup_req SET lane = NULL WHERE req_id = l_row.req_id;
         ELSE
            reset_items(l_row.req_id, FALSE);
         END IF;

         UPDATE xx_sup_req
            SET status            = 'RETRY',
                retry_count       = 0,
                next_retry_at     = SYSTIMESTAMP,
                error_entity      = NULL,
                error_ref         = NULL,
                error_code        = NULL,
                error_http_status = NULL,
                error_message     = NULL,
                callback_status   = NULL,
                callback_attempts = 0,
                next_callback_at  = NULL,
                updated_on        = SYSTIMESTAMP
          WHERE req_id = l_row.req_id;
         p_result := 'QUEUED';
         log_event(l_row.req_id, 'REPROCESS');

      ELSIF l_row.status = 'SUCCESS' AND l_row.callback_status IN ('FAILED', 'GAVE_UP') THEN
         UPDATE xx_sup_req
            SET callback_status   = 'PENDING',
                callback_attempts = 0,
                next_callback_at  = SYSTIMESTAMP,
                updated_on        = SYSTIMESTAMP
          WHERE req_id = l_row.req_id;
         p_result := 'CALLBACK_QUEUED';
         log_event(l_row.req_id, 'REPROCESS_CALLBACK');

      ELSE
         p_result := 'NOT_ALLOWED:' || l_row.status;
      END IF;
   END reprocess;

   PROCEDURE purge_sensitive (
      p_older_than_days  IN  NUMBER DEFAULT 7,
      p_purged           OUT NUMBER)
   IS
   BEGIN
      p_purged := 0;
      FOR r IN (SELECT req_id
                  FROM xx_sup_req
                 WHERE sensitive_purged = 'N'
                   AND status IN ('SUCCESS', 'ERROR_FINAL')
                   AND callback_status IN ('SENT', 'GAVE_UP')
                   AND updated_on < SYSTIMESTAMP - NUMTODSINTERVAL(p_older_than_days, 'DAY')
                   FOR UPDATE SKIP LOCKED)
      LOOP
         UPDATE xx_sup_req_bank
            SET account_number = CASE WHEN account_number IS NOT NULL
                                      THEN '****' || SUBSTR(account_number, -4) END,
                iban           = CASE WHEN iban IS NOT NULL THEN '****' || SUBSTR(iban, -4) END
          WHERE req_id = r.req_id;

         UPDATE xx_sup_req
            SET payload_json     = JSON_MERGEPATCH(payload_json, '{"bankAccounts":null}' RETURNING CLOB),
                sensitive_purged = 'Y'
          WHERE req_id = r.req_id;

         p_purged := p_purged + 1;
      END LOOP;
      IF p_purged > 0 THEN
         log_event(NULL, 'PURGED', NULL, NULL, p_purged || ' message(s)');
      END IF;
   END purge_sensitive;

END xx_sup_pkg;
/
