-- =============================================================================
-- Views read by OIC with the ATP adapter "Run a SQL statement".
-- Every section view returns all items of a message; OIC selects the ones to do with
--    WHERE req_id = #reqId AND process_status <> 'DONE' ORDER BY line_no
-- and uses OPERATION to choose POST (CREATE) or PATCH (UPDATE).
-- =============================================================================

-- One row per message: lane, status, the supplier's ERP ids and how many items are left.
CREATE OR REPLACE VIEW xx_sup_req_v AS
SELECT r.req_id,
       r.request_id,
       r.supplier_ref,
       r.lane,
       r.status,
       r.retry_count,
       m.erp_supplier_id,
       m.erp_supplier_number,
       m.erp_party_id,
       NVL(m.supplier_name, h.supplier_name)                                       AS supplier_name,
       (SELECT COUNT(*) FROM xx_sup_req_header  x WHERE x.req_id = r.req_id AND x.process_status <> 'DONE') AS header_todo,
       (SELECT COUNT(*) FROM xx_sup_req_address x WHERE x.req_id = r.req_id AND x.process_status <> 'DONE') AS address_todo,
       (SELECT COUNT(*) FROM xx_sup_req_site    x WHERE x.req_id = r.req_id AND x.process_status <> 'DONE') AS site_todo,
       (SELECT COUNT(*) FROM xx_sup_req_contact x WHERE x.req_id = r.req_id AND x.process_status <> 'DONE') AS contact_todo,
       (SELECT COUNT(*) FROM xx_sup_req_tax     x WHERE x.req_id = r.req_id AND x.process_status <> 'DONE') AS tax_todo,
       (SELECT COUNT(*) FROM xx_sup_req_bank    x WHERE x.req_id = r.req_id AND x.process_status <> 'DONE') AS bank_todo,
       r.error_entity, r.error_ref, r.error_code, r.error_http_status, r.error_message,
       r.callback_status, r.callback_attempts,
       CASE r.status WHEN 'SUCCESS' THEN 'BATCH_UPDATE' WHEN 'ERROR_FINAL' THEN 'LOG_ERROR' END AS callback_type,
       r.oic_instance_id, r.created_on, r.updated_on
  FROM xx_sup_req r
  LEFT JOIN xx_sup_master     m ON m.supplier_ref = r.supplier_ref
  LEFT JOIN xx_sup_req_header h ON h.req_id = r.req_id;

-- Supplier header. erp_supplier_id is set for UPDATE (PATCH /suppliers/{id}).
CREATE OR REPLACE VIEW xx_sup_header_v AS
SELECT h.req_id, r.supplier_ref, h.operation, h.process_status,
       h.supplier_name,
       NVL(h.tax_organization_type, 'Corporation')  AS tax_organization_type,
       NVL(h.supplier_type, 'Supplier')             AS supplier_type,
       h.taxpayer_id, h.duns_number,
       NVL(h.erp_id, m.erp_supplier_id)             AS erp_supplier_id,
       NVL(h.erp_number, m.erp_supplier_number)     AS erp_supplier_number,
       NVL(h.erp_id2, m.erp_party_id)               AS erp_party_id,
       h.error_message
  FROM xx_sup_req_header h
  JOIN xx_sup_req r         ON r.req_id = h.req_id
  LEFT JOIN xx_sup_master m ON m.supplier_ref = r.supplier_ref;

-- Addresses. erp_address_id is set for UPDATE.
CREATE OR REPLACE VIEW xx_sup_address_v AS
SELECT a.req_id, a.line_no, r.supplier_ref, a.address_ref, a.operation, a.process_status,
       a.address_name, a.address_line1, a.address_line2, a.city, a.state, a.postal_code, a.country,
       NVL(a.erp_id, x.erp_id) AS erp_address_id,
       a.error_message
  FROM xx_sup_req_address a
  JOIN xx_sup_req r       ON r.req_id = a.req_id
  LEFT JOIN xx_sup_xref x ON x.supplier_ref = r.supplier_ref AND x.entity_type = 'ADDRESS'
                         AND x.entity_ref = a.address_ref;

-- Sites, with the ERP address they belong to (created earlier in the same run, or before).
CREATE OR REPLACE VIEW xx_sup_site_v AS
SELECT s.req_id, s.line_no, r.supplier_ref, s.site_ref, s.operation, s.process_status,
       s.site_name, s.procurement_bu, s.payment_terms, s.payment_method,
       s.purchasing_flag, s.pay_flag,
       s.address_ref,
       xa.erp_id                                  AS erp_address_id,
       NVL(xa.erp_name, a.address_name)           AS address_name,
       NVL(s.erp_id, xs.erp_id)                   AS erp_site_id,
       s.error_message
  FROM xx_sup_req_site s
  JOIN xx_sup_req r              ON r.req_id = s.req_id
  LEFT JOIN xx_sup_req_address a ON a.req_id = s.req_id AND a.address_ref = s.address_ref
  LEFT JOIN xx_sup_xref xa       ON xa.supplier_ref = r.supplier_ref AND xa.entity_type = 'ADDRESS'
                                AND xa.entity_ref = s.address_ref
  LEFT JOIN xx_sup_xref xs       ON xs.supplier_ref = r.supplier_ref AND xs.entity_type = 'SITE'
                                AND xs.entity_ref = s.site_ref;

CREATE OR REPLACE VIEW xx_sup_contact_v AS
SELECT c.req_id, c.line_no, r.supplier_ref, c.contact_ref, c.operation, c.process_status,
       c.first_name, c.last_name, c.email, c.phone,
       NVL(c.erp_id, x.erp_id) AS erp_contact_id,
       c.error_message
  FROM xx_sup_req_contact c
  JOIN xx_sup_req r       ON r.req_id = c.req_id
  LEFT JOIN xx_sup_xref x ON x.supplier_ref = r.supplier_ref AND x.entity_type = 'CONTACT'
                         AND x.entity_ref = c.contact_ref;

CREATE OR REPLACE VIEW xx_sup_tax_v AS
SELECT t.req_id, t.line_no, r.supplier_ref, t.tax_ref, t.operation, t.process_status,
       t.tax_regime_code, t.registration_number, t.country, t.effective_from,
       m.erp_party_id,
       NVL(t.erp_id, x.erp_id) AS erp_tax_reg_id,
       t.error_message
  FROM xx_sup_req_tax t
  JOIN xx_sup_req r         ON r.req_id = t.req_id
  LEFT JOIN xx_sup_master m ON m.supplier_ref = r.supplier_ref
  LEFT JOIN xx_sup_xref x   ON x.supplier_ref = r.supplier_ref AND x.entity_type = 'TAX'
                           AND x.entity_ref = t.tax_ref;

-- Bank accounts. erp_bank_account_id is set when the account exists (UPDATE, or created in an
-- earlier attempt); erp_assignment_id is set when it is already assigned to the supplier.
CREATE OR REPLACE VIEW xx_sup_bank_v AS
SELECT b.req_id, b.line_no, r.supplier_ref, b.bank_ref, b.operation, b.process_status,
       b.bank_name, b.branch_name, b.account_number, b.iban,
       NVL(b.account_name, m.supplier_name)       AS account_name,
       b.currency_code, b.country, b.account_type,
       m.erp_party_id,
       NVL(b.erp_id, x.erp_id)                    AS erp_bank_account_id,
       NVL(b.erp_id2, x.erp_id2)                  AS erp_assignment_id,
       b.error_message
  FROM xx_sup_req_bank b
  JOIN xx_sup_req r         ON r.req_id = b.req_id
  LEFT JOIN xx_sup_master m ON m.supplier_ref = r.supplier_ref
  LEFT JOIN xx_sup_xref x   ON x.supplier_ref = r.supplier_ref AND x.entity_type = 'BANK'
                           AND x.entity_ref = b.bank_ref;

-- Every item of a message with its result: what XX_SUP_CALLBACK sends back to Apex.
CREATE OR REPLACE VIEW xx_sup_result_v AS
SELECT h.req_id, 0 AS sort_order, 'HEADER' AS entity_type, r.supplier_ref AS entity_ref,
       h.operation, h.process_status, h.erp_id, h.erp_number, h.error_message
  FROM xx_sup_req_header h JOIN xx_sup_req r ON r.req_id = h.req_id
UNION ALL
SELECT req_id, 1, 'ADDRESS', address_ref, operation, process_status, erp_id, erp_number, error_message FROM xx_sup_req_address
UNION ALL
SELECT req_id, 2, 'SITE',    site_ref,    operation, process_status, erp_id, erp_number, error_message FROM xx_sup_req_site
UNION ALL
SELECT req_id, 3, 'CONTACT', contact_ref, operation, process_status, erp_id, erp_number, error_message FROM xx_sup_req_contact
UNION ALL
SELECT req_id, 4, 'TAX',     tax_ref,     operation, process_status, erp_id, erp_number, error_message FROM xx_sup_req_tax
UNION ALL
SELECT req_id, 5, 'BANK',    bank_ref,    operation, process_status, erp_id, erp_number, error_message FROM xx_sup_req_bank;

-- Work list for XX_SUP_RETRY_JOB.
--   PROCESS  : retries that are due, and NEW messages older than 5 minutes
--              (never handed over, or waiting for an earlier message that has now finished)
--   CALLBACK : finished messages whose result has not reached Apex yet
CREATE OR REPLACE VIEW xx_sup_work_v AS
SELECT r.req_id, r.request_id, 'PROCESS' AS action, NVL(r.next_retry_at, r.created_on) AS due_at
  FROM xx_sup_req r
 WHERE (   (r.status = 'RETRY' AND r.next_retry_at <= SYSTIMESTAMP)
        OR (r.status = 'NEW'   AND r.created_on < SYSTIMESTAMP - INTERVAL '5' MINUTE))
   AND NOT EXISTS (SELECT 1 FROM xx_sup_req e
                    WHERE e.supplier_ref = r.supplier_ref
                      AND e.req_id < r.req_id
                      AND e.status IN ('NEW', 'IN_PROGRESS', 'RETRY'))
UNION ALL
SELECT req_id, request_id, 'CALLBACK', next_callback_at
  FROM xx_sup_req
 WHERE status IN ('SUCCESS', 'ERROR_FINAL')
   AND callback_status IN ('PENDING', 'FAILED')
   AND next_callback_at <= SYSTIMESTAMP;
