-- =============================================================================
-- XX_SUPPLIER_STG_PKG - API used by the OIC integrations
--
--  (1) Receive Supplier   -> receive_supplier / receive_supplier_b64
--  (2) Process Supplier   -> claim_record, record_step, record_contact,
--                            mark_success, mark_failure, mark_callback
--  (3) Retry job          -> prepare_work (+ SELECT from xx_supplier_work_v)
--      Reprocess (manual) -> reprocess
--      Housekeeping       -> purge_sensitive
--
-- Procedures do not COMMIT: the OIC database adapter commits each call.
-- No overloads, because the OIC adapter cannot choose between them.
-- =============================================================================
CREATE OR REPLACE PACKAGE xx_supplier_stg_pkg AS

   c_max_retries            CONSTANT PLS_INTEGER := 3;   -- automatic retries for temporary errors
   c_max_callback_attempts  CONSTANT PLS_INTEGER := 6;   -- attempts to reach Apex before GAVE_UP
   c_callback_grace_minutes CONSTANT PLS_INTEGER := 10;  -- retry job leaves fresh callbacks to (2)

   -- Validates and stores one supplier request (JSON text).
   -- p_http_status: 202 accepted | 200 already created | 400 invalid | 409 already queued
   -- p_start_processing = 'Y' means OIC should now call Process Supplier with p_stg_id.
   PROCEDURE receive_supplier (
      p_payload          IN  CLOB,
      p_stg_id           OUT NUMBER,
      p_http_status      OUT NUMBER,
      p_status           OUT VARCHAR2,
      p_supplier_number  OUT VARCHAR2,
      p_message          OUT VARCHAR2,
      p_start_processing OUT VARCHAR2);

   -- Same as receive_supplier, for when OIC passes the raw request body as base64.
   PROCEDURE receive_supplier_b64 (
      p_payload_b64      IN  CLOB,
      p_stg_id           OUT NUMBER,
      p_http_status      OUT NUMBER,
      p_status           OUT VARCHAR2,
      p_supplier_number  OUT VARCHAR2,
      p_message          OUT VARCHAR2,
      p_start_processing OUT VARCHAR2);

   -- Atomically moves a NEW/RETRY row to IN_PROGRESS. p_claimed = 'N' means stop:
   -- another run owns it, or there is nothing to do.
   PROCEDURE claim_record (
      p_stg_id           IN  NUMBER,
      p_oic_instance_id  IN  VARCHAR2,
      p_claimed          OUT VARCHAR2);

   -- Saves the ERP id(s) created by a step and advances last_step_done.
   -- Steps: SUPPLIER (p_erp_id = SupplierId, p_erp_number = SupplierNumber, p_erp_party_id = party),
   --        ADDRESS, SITE, CONTACTS, TAX, BANK, BANK_ASSIGN
   PROCEDURE record_step (
      p_stg_id           IN  NUMBER,
      p_step             IN  VARCHAR2,
      p_erp_id           IN  NUMBER   DEFAULT NULL,
      p_erp_number       IN  VARCHAR2 DEFAULT NULL,
      p_erp_party_id     IN  NUMBER   DEFAULT NULL,
      p_oic_instance_id  IN  VARCHAR2 DEFAULT NULL);

   PROCEDURE record_contact (
      p_stg_id           IN  NUMBER,
      p_contact_seq      IN  NUMBER,
      p_erp_contact_id   IN  NUMBER);

   PROCEDURE mark_success (
      p_stg_id           IN  NUMBER,
      p_oic_instance_id  IN  VARCHAR2 DEFAULT NULL);

   -- Temporary errors (no HTTP status/timeout, 408, 429, 5xx) go to RETRY with back-off until
   -- c_max_retries; everything else is ERROR_FINAL. p_send_error_callback = 'Y' means call the
   -- Apex log error API now.
   PROCEDURE mark_failure (
      p_stg_id              IN  NUMBER,
      p_step                IN  VARCHAR2,
      p_http_status         IN  NUMBER,
      p_error_code          IN  VARCHAR2,
      p_error_message       IN  VARCHAR2,
      p_oic_instance_id     IN  VARCHAR2 DEFAULT NULL,
      p_new_status          OUT VARCHAR2,
      p_send_error_callback OUT VARCHAR2);

   -- Records the outcome of calling Apex (p_success = 'Y' or 'N').
   PROCEDURE mark_callback (
      p_stg_id           IN  NUMBER,
      p_success          IN  VARCHAR2,
      p_message          IN  VARCHAR2 DEFAULT NULL,
      p_oic_instance_id  IN  VARCHAR2 DEFAULT NULL);

   -- Called at the start of the retry job: releases rows stuck IN_PROGRESS longer than
   -- p_stuck_minutes. Afterwards select the work list from xx_supplier_work_v.
   PROCEDURE prepare_work (
      p_stuck_minutes    IN  NUMBER DEFAULT 30,
      p_released         OUT NUMBER);

   -- Manual reprocess by stg_id or source_ref.
   -- p_result: QUEUED (call Process Supplier) | CALLBACK_QUEUED | NOT_FOUND | NOT_ALLOWED:<status>
   PROCEDURE reprocess (
      p_stg_id           IN  NUMBER   DEFAULT NULL,
      p_source_ref       IN  VARCHAR2 DEFAULT NULL,
      p_result           OUT VARCHAR2,
      p_stg_id_out       OUT NUMBER);

   -- Removes bank details from stored payloads of finished rows older than p_older_than_days.
   PROCEDURE purge_sensitive (
      p_older_than_days  IN  NUMBER DEFAULT 7,
      p_purged           OUT NUMBER);

   FUNCTION step_no (p_step IN VARCHAR2) RETURN PLS_INTEGER DETERMINISTIC;

END xx_supplier_stg_pkg;
/
