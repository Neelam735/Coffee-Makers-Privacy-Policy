-- =============================================================================
-- XX_SUP_PKG - the only API the OIC integrations call
--
--   XX_SUP_RECEIVE    receive_request / receive_request_b64
--   XX_SUP_PROCESS    claim_request, line_done, mark_failure, mark_success
--   XX_SUP_CALLBACK   mark_callback
--   XX_SUP_RETRY_JOB  prepare_work (+ SELECT from xx_sup_work_v)
--   XX_SUP_REPROCESS  reprocess
--   housekeeping      purge_sensitive
--
-- Procedures do not COMMIT: the OIC ATP adapter commits each call.
-- No overloads, because the OIC adapter cannot choose between them.
-- Entity types: HEADER, ADDRESS, SITE, CONTACT, TAX, BANK
-- =============================================================================
CREATE OR REPLACE PACKAGE xx_sup_pkg AS

   c_max_retries            CONSTANT PLS_INTEGER := 3;   -- automatic retries for temporary errors
   c_max_callback_attempts  CONSTANT PLS_INTEGER := 6;   -- attempts to reach Apex before GAVE_UP
   c_callback_grace_minutes CONSTANT PLS_INTEGER := 10;  -- retry job leaves fresh callbacks to PROCESS

   -- Validates and stores one message (JSON text), one row per section item.
   -- p_http_status: 202 accepted | 200 already done | 400 invalid | 409 already received
   -- p_start_processing = 'Y' -> OIC calls XX_SUP_PROCESS with p_req_id.
   PROCEDURE receive_request (
      p_payload          IN  CLOB,
      p_req_id           OUT NUMBER,
      p_http_status      OUT NUMBER,
      p_status           OUT VARCHAR2,
      p_supplier_number  OUT VARCHAR2,
      p_message          OUT VARCHAR2,
      p_start_processing OUT VARCHAR2);

   -- Same, for when OIC passes the raw request body as base64.
   PROCEDURE receive_request_b64 (
      p_payload_b64      IN  CLOB,
      p_req_id           OUT NUMBER,
      p_http_status      OUT NUMBER,
      p_status           OUT VARCHAR2,
      p_supplier_number  OUT VARCHAR2,
      p_message          OUT VARCHAR2,
      p_start_processing OUT VARCHAR2);

   -- Locks a NEW/RETRY message for processing. The first time, it chooses the lane
   -- (CREATE if the supplier is not in XX_SUP_MASTER, else UPDATE) and the operation of
   -- every item (UPDATE if its reference is in XX_SUP_XREF, else CREATE).
   -- p_result: CLAIMED     -> process it
   --           WAITING     -> an earlier message for the same supplier is unfinished; stop
   --           NOT_AVAILABLE -> already taken or finished; stop
   --           REJECTED    -> fails the lane rules (e.g. CREATE without header); now ERROR_FINAL,
   --                          p_send_error_callback = 'Y'
   PROCEDURE claim_request (
      p_req_id              IN  NUMBER,
      p_oic_instance_id     IN  VARCHAR2,
      p_result              OUT VARCHAR2,
      p_lane                OUT VARCHAR2,
      p_send_error_callback OUT VARCHAR2);

   -- Records what ERP returned for one item and, when p_complete = 'Y', marks it DONE and
   -- updates XX_SUP_MASTER / XX_SUP_XREF.
   --   HEADER : p_erp_id = SupplierId, p_erp_id2 = SupplierPartyId, p_erp_number = SupplierNumber
   --   ADDRESS: SupplierAddressId   SITE: SupplierSiteId   CONTACT: SupplierContactId
   --   TAX    : registration id     BANK: p_erp_id = BankAccountId, p_erp_id2 = assignment id
   -- p_complete = 'N' saves the ids only (bank account created, assignment still to do).
   PROCEDURE line_done (
      p_req_id           IN  NUMBER,
      p_entity_type      IN  VARCHAR2,
      p_entity_ref       IN  VARCHAR2,
      p_erp_id           IN  NUMBER   DEFAULT NULL,
      p_erp_id2          IN  NUMBER   DEFAULT NULL,
      p_erp_number       IN  VARCHAR2 DEFAULT NULL,
      p_complete         IN  VARCHAR2 DEFAULT 'Y',
      p_oic_instance_id  IN  VARCHAR2 DEFAULT NULL);

   -- Temporary errors (no HTTP status/timeout, 408, 429, 5xx) -> RETRY with back-off until
   -- c_max_retries; anything else -> ERROR_FINAL and p_send_error_callback = 'Y'.
   -- p_next_req_id: the next message waiting for this supplier, to process now (or NULL).
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
      p_next_req_id         OUT NUMBER);

   -- All items DONE -> SUCCESS. Raises an error if any item is not DONE.
   PROCEDURE mark_success (
      p_req_id           IN  NUMBER,
      p_oic_instance_id  IN  VARCHAR2 DEFAULT NULL,
      p_next_req_id      OUT NUMBER);

   -- Outcome of calling Apex (p_success = 'Y' or 'N').
   PROCEDURE mark_callback (
      p_req_id           IN  NUMBER,
      p_success          IN  VARCHAR2,
      p_message          IN  VARCHAR2 DEFAULT NULL,
      p_oic_instance_id  IN  VARCHAR2 DEFAULT NULL);

   -- Start of the retry job: releases messages stuck IN_PROGRESS longer than p_stuck_minutes.
   PROCEDURE prepare_work (
      p_stuck_minutes    IN  NUMBER DEFAULT 30,
      p_released         OUT NUMBER);

   -- Manual re-run by req_id or Apex requestId.
   -- p_result: QUEUED (call PROCESS) | CALLBACK_QUEUED (call CALLBACK) | NOT_FOUND | NOT_ALLOWED:<reason>
   PROCEDURE reprocess (
      p_req_id           IN  NUMBER   DEFAULT NULL,
      p_request_id       IN  VARCHAR2 DEFAULT NULL,
      p_result           OUT VARCHAR2,
      p_req_id_out       OUT NUMBER);

   -- Masks bank account numbers and removes bank details from stored payloads of finished
   -- messages older than p_older_than_days.
   PROCEDURE purge_sensitive (
      p_older_than_days  IN  NUMBER DEFAULT 7,
      p_purged           OUT NUMBER);

END xx_sup_pkg;
/
