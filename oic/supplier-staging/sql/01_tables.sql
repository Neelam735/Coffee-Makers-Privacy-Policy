-- =============================================================================
-- Supplier onboarding staging (Apex Analytics -> OIC -> Oracle ERP Cloud)
-- Target: Oracle Autonomous Database (ATP) 19c or later
-- =============================================================================

-- One row per supplier request received from Apex Analytics.
CREATE TABLE xx_supplier_stg (
   stg_id                NUMBER GENERATED ALWAYS AS IDENTITY
                         CONSTRAINT xx_supplier_stg_pk PRIMARY KEY,
   source_ref            VARCHAR2(100)  NOT NULL,          -- Apex Analytics record id
   payload_json          CLOB           NOT NULL
                         CONSTRAINT xx_supplier_stg_json_chk CHECK (payload_json IS JSON),
   supplier_name         VARCHAR2(360),
   tax_id                VARCHAR2(50),
   -- Processing state
   status                VARCHAR2(20)   DEFAULT 'NEW' NOT NULL
                         CONSTRAINT xx_supplier_stg_status_chk
                         CHECK (status IN ('NEW','IN_PROGRESS','SUCCESS','RETRY','ERROR_FINAL')),
   last_step_done        VARCHAR2(20)
                         CONSTRAINT xx_supplier_stg_step_chk
                         CHECK (last_step_done IN ('SUPPLIER','ADDRESS','SITE','CONTACTS','TAX','BANK','BANK_ASSIGN')),
   retry_count           NUMBER         DEFAULT 0 NOT NULL,
   next_retry_at         TIMESTAMP,
   claimed_at            TIMESTAMP,
   oic_instance_id       VARCHAR2(100),
   -- ERP identifiers, saved after each step so a retry resumes instead of duplicating
   erp_supplier_id       NUMBER,
   erp_supplier_number   VARCHAR2(30),
   erp_party_id          NUMBER,
   erp_address_id        NUMBER,
   erp_site_id           NUMBER,
   erp_tax_reg_id        NUMBER,
   erp_bank_account_id   NUMBER,
   erp_instr_assign_id   NUMBER,
   -- Last error
   error_step            VARCHAR2(20),
   error_code            VARCHAR2(100),
   error_http_status     NUMBER,
   error_message         VARCHAR2(4000),
   -- Result callback to Apex Analytics (batch update API / log error API)
   callback_status       VARCHAR2(20)
                         CONSTRAINT xx_supplier_stg_cb_chk
                         CHECK (callback_status IN ('PENDING','SENT','FAILED','GAVE_UP')),
   callback_attempts     NUMBER         DEFAULT 0 NOT NULL,
   next_callback_at      TIMESTAMP,
   callback_message      VARCHAR2(4000),
   sensitive_purged      VARCHAR2(1)    DEFAULT 'N' NOT NULL,
   created_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
   updated_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
   CONSTRAINT xx_supplier_stg_src_uk UNIQUE (source_ref)
);

CREATE INDEX xx_supplier_stg_work_ix ON xx_supplier_stg (status, next_retry_at);
CREATE INDEX xx_supplier_stg_cb_ix   ON xx_supplier_stg (callback_status, next_callback_at);
CREATE INDEX xx_supplier_stg_tax_ix  ON xx_supplier_stg (tax_id);

-- Contacts are tracked individually so a retry only creates the ones still missing.
CREATE TABLE xx_supplier_stg_contact (
   stg_id                NUMBER         NOT NULL
                         CONSTRAINT xx_supplier_stg_contact_fk
                         REFERENCES xx_supplier_stg (stg_id) ON DELETE CASCADE,
   contact_seq           NUMBER         NOT NULL,
   first_name            VARCHAR2(150),
   last_name             VARCHAR2(150),
   email                 VARCHAR2(320),
   phone                 VARCHAR2(60),
   erp_contact_id        NUMBER,
   created_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
   updated_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
   CONSTRAINT xx_supplier_stg_contact_pk PRIMARY KEY (stg_id, contact_seq)
);

-- Audit trail of every event for a record (received, claimed, step done, failures, callbacks).
CREATE TABLE xx_supplier_stg_log (
   log_id                NUMBER GENERATED ALWAYS AS IDENTITY
                         CONSTRAINT xx_supplier_stg_log_pk PRIMARY KEY,
   stg_id                NUMBER,
   event                 VARCHAR2(30)   NOT NULL,
   step                  VARCHAR2(20),
   detail                VARCHAR2(4000),
   oic_instance_id       VARCHAR2(100),
   created_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE INDEX xx_supplier_stg_log_ix ON xx_supplier_stg_log (stg_id, created_on);
