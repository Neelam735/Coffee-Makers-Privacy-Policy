-- =============================================================================
-- Views read by OIC ("Run a SQL statement" in the ATP adapter)
-- =============================================================================

-- One row per staging record with the payload flattened into columns.
-- run_* = 'Y' tells Process Supplier which ERP steps are still to do.
-- Adjust the JSON paths here if Apex Analytics uses different field names.
CREATE OR REPLACE VIEW xx_supplier_stg_v AS
SELECT s.stg_id,
       s.source_ref,
       s.status,
       s.last_step_done,
       s.retry_count,
       s.oic_instance_id,
       -- supplier
       j.supplier_name,
       NVL(j.tax_org_type, 'Corporation')                          AS tax_organization_type,
       NVL(j.supplier_type, 'Supplier')                            AS supplier_type,
       j.tax_registration_number,
       j.duns_number,
       j.business_unit,
       -- address
       j.address_name, j.address_line1, j.address_line2, j.city, j.state, j.postal_code,
       UPPER(j.country)                                            AS country,
       -- site
       j.site_name, j.payment_terms, j.payment_method,
       NVL(j.purchasing_flag, 'true')                              AS purchasing_flag,
       NVL(j.pay_flag, 'true')                                     AS pay_flag,
       -- tax registration
       j.tax_regime_code,
       j.tax_reg_number,
       UPPER(NVL(j.tax_country, j.country))                        AS tax_country,
       j.tax_effective_from,
       -- bank account
       j.bank_name, j.branch_name,
       REGEXP_REPLACE(j.account_number, '[[:space:]]', '')         AS account_number,
       UPPER(REGEXP_REPLACE(j.iban, '[[:space:]]', ''))            AS iban,
       NVL(j.account_name, j.supplier_name)                        AS account_name,
       UPPER(j.currency_code)                                      AS currency_code,
       UPPER(NVL(j.bank_country, j.country))                       AS bank_country,
       j.account_type,
       -- ERP ids created so far
       s.erp_supplier_id, s.erp_supplier_number, s.erp_party_id, s.erp_address_id,
       s.erp_site_id, s.erp_tax_reg_id, s.erp_bank_account_id, s.erp_instr_assign_id,
       -- what is left to do
       CASE WHEN xx_supplier_stg_pkg.step_no(s.last_step_done) < 1 THEN 'Y' ELSE 'N' END AS run_supplier,
       CASE WHEN xx_supplier_stg_pkg.step_no(s.last_step_done) < 2 THEN 'Y' ELSE 'N' END AS run_address,
       CASE WHEN xx_supplier_stg_pkg.step_no(s.last_step_done) < 3 THEN 'Y' ELSE 'N' END AS run_site,
       CASE WHEN xx_supplier_stg_pkg.step_no(s.last_step_done) < 4
             AND EXISTS (SELECT 1 FROM xx_supplier_stg_contact c
                          WHERE c.stg_id = s.stg_id AND c.erp_contact_id IS NULL)
            THEN 'Y' ELSE 'N' END                                  AS run_contacts,
       CASE WHEN xx_supplier_stg_pkg.step_no(s.last_step_done) < 5
             AND j.tax_regime_code IS NOT NULL THEN 'Y' ELSE 'N' END AS run_tax,
       CASE WHEN xx_supplier_stg_pkg.step_no(s.last_step_done) < 6
             AND j.account_number IS NOT NULL THEN 'Y' ELSE 'N' END  AS run_bank,
       CASE WHEN xx_supplier_stg_pkg.step_no(s.last_step_done) < 7
             AND j.account_number IS NOT NULL THEN 'Y' ELSE 'N' END  AS run_bank_assign,
       -- error and callback details
       s.error_step, s.error_code, s.error_http_status, s.error_message,
       s.callback_status, s.callback_attempts,
       CASE s.status WHEN 'SUCCESS' THEN 'BATCH_UPDATE'
                     WHEN 'ERROR_FINAL' THEN 'LOG_ERROR' END       AS callback_type,
       s.created_on, s.updated_on
  FROM xx_supplier_stg s,
       JSON_TABLE(s.payload_json, '$'
          COLUMNS (
             supplier_name           VARCHAR2(360) PATH '$.supplierName',
             tax_org_type            VARCHAR2(80)  PATH '$.taxOrganizationType',
             supplier_type           VARCHAR2(80)  PATH '$.supplierType',
             tax_registration_number VARCHAR2(50)  PATH '$.taxRegistrationNumber',
             duns_number             VARCHAR2(30)  PATH '$.dunsNumber',
             business_unit           VARCHAR2(240) PATH '$.businessUnit',
             address_name            VARCHAR2(240) PATH '$.address.addressName',
             address_line1           VARCHAR2(240) PATH '$.address.addressLine1',
             address_line2           VARCHAR2(240) PATH '$.address.addressLine2',
             city                    VARCHAR2(60)  PATH '$.address.city',
             state                   VARCHAR2(60)  PATH '$.address.state',
             postal_code             VARCHAR2(60)  PATH '$.address.postalCode',
             country                 VARCHAR2(10)  PATH '$.address.country',
             site_name               VARCHAR2(240) PATH '$.site.siteName',
             payment_terms           VARCHAR2(50)  PATH '$.site.paymentTerms',
             payment_method          VARCHAR2(30)  PATH '$.site.paymentMethod',
             purchasing_flag         VARCHAR2(5)   PATH '$.site.purchasingFlag',
             pay_flag                VARCHAR2(5)   PATH '$.site.payFlag',
             tax_regime_code         VARCHAR2(30)  PATH '$.tax.taxRegimeCode',
             tax_reg_number          VARCHAR2(50)  PATH '$.tax.registrationNumber',
             tax_country             VARCHAR2(10)  PATH '$.tax.country',
             tax_effective_from      VARCHAR2(10)  PATH '$.tax.effectiveFrom',
             bank_name               VARCHAR2(360) PATH '$.bankAccount.bankName',
             branch_name             VARCHAR2(360) PATH '$.bankAccount.branchName',
             account_number          VARCHAR2(100) PATH '$.bankAccount.accountNumber',
             iban                    VARCHAR2(50)  PATH '$.bankAccount.iban',
             account_name            VARCHAR2(360) PATH '$.bankAccount.accountName',
             currency_code           VARCHAR2(15)  PATH '$.bankAccount.currencyCode',
             bank_country            VARCHAR2(10)  PATH '$.bankAccount.countryCode',
             account_type            VARCHAR2(30)  PATH '$.bankAccount.accountType'
          )) j;

-- Contacts per record. Process Supplier selects WHERE erp_contact_id IS NULL (not yet created).
CREATE OR REPLACE VIEW xx_supplier_stg_contact_v AS
SELECT stg_id, contact_seq, first_name, last_name, email, phone, erp_contact_id
  FROM xx_supplier_stg_contact;

-- Work list for the retry job.
--   PROCESS  : due retries, and NEW rows that Receive never handed to Process Supplier
--   CALLBACK : finished rows whose result has not reached Apex yet
CREATE OR REPLACE VIEW xx_supplier_work_v AS
SELECT stg_id, source_ref, 'PROCESS' AS action, NVL(next_retry_at, created_on) AS due_at
  FROM xx_supplier_stg
 WHERE (status = 'RETRY' AND next_retry_at <= SYSTIMESTAMP)
    OR (status = 'NEW'   AND created_on < SYSTIMESTAMP - INTERVAL '5' MINUTE)
UNION ALL
SELECT stg_id, source_ref, 'CALLBACK' AS action, next_callback_at AS due_at
  FROM xx_supplier_stg
 WHERE status IN ('SUCCESS', 'ERROR_FINAL')
   AND callback_status IN ('PENDING', 'FAILED')
   AND next_callback_at <= SYSTIMESTAMP;
