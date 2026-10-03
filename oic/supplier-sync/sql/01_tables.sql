-- =============================================================================
-- Supplier create / update: Apex Analytics -> OIC -> Oracle ERP Cloud
-- Target: Oracle Autonomous Database (ATP) 19c or later
--
-- Two layers:
--   REQUEST layer  (XX_SUP_REQ + one table per section): every message received,
--                  one row per item, with its own status and the ERP id it produced.
--   MASTER layer   (XX_SUP_MASTER + XX_SUP_XREF): what exists in ERP today, keyed
--                  by Apex's references. It decides CREATE vs UPDATE.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- MASTER layer
-- ---------------------------------------------------------------------------

-- One row per supplier that exists in ERP.
CREATE TABLE xx_sup_master (
   supplier_ref          VARCHAR2(100)  CONSTRAINT xx_sup_master_pk PRIMARY KEY,   -- Apex supplier id
   erp_supplier_id       NUMBER         NOT NULL,
   erp_supplier_number   VARCHAR2(30),
   erp_party_id          NUMBER,
   supplier_name         VARCHAR2(360),
   taxpayer_id           VARCHAR2(50),
   created_req_id        NUMBER,
   last_req_id           NUMBER,
   created_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
   updated_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

-- One row per address, site, contact, tax registration and bank account that exists in ERP.
CREATE TABLE xx_sup_xref (
   supplier_ref          VARCHAR2(100)  NOT NULL,
   entity_type           VARCHAR2(10)   NOT NULL
                         CONSTRAINT xx_sup_xref_type_chk
                         CHECK (entity_type IN ('ADDRESS','SITE','CONTACT','TAX','BANK')),
   entity_ref            VARCHAR2(100)  NOT NULL,                 -- Apex reference (addressRef, siteRef, ...)
   erp_id                NUMBER         NOT NULL,                 -- ERP id of the record
   erp_id2               NUMBER,                                  -- BANK: instrument assignment id
   erp_name              VARCHAR2(360),                           -- ADDRESS: address name, SITE: site name
   created_req_id        NUMBER,
   last_req_id           NUMBER,
   created_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
   updated_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
   CONSTRAINT xx_sup_xref_pk PRIMARY KEY (supplier_ref, entity_type, entity_ref),
   CONSTRAINT xx_sup_xref_master_fk FOREIGN KEY (supplier_ref) REFERENCES xx_sup_master (supplier_ref)
);

-- ---------------------------------------------------------------------------
-- REQUEST layer
-- ---------------------------------------------------------------------------

-- One row per message received from Apex Analytics.
CREATE TABLE xx_sup_req (
   req_id                NUMBER GENERATED ALWAYS AS IDENTITY
                         CONSTRAINT xx_sup_req_pk PRIMARY KEY,
   request_id            VARCHAR2(100)  NOT NULL,                 -- Apex message id
   supplier_ref          VARCHAR2(100)  NOT NULL,
   payload_json          CLOB           NOT NULL
                         CONSTRAINT xx_sup_req_json_chk CHECK (payload_json IS JSON),
   lane                  VARCHAR2(10)
                         CONSTRAINT xx_sup_req_lane_chk CHECK (lane IN ('CREATE','UPDATE')),
   status                VARCHAR2(20)   DEFAULT 'NEW' NOT NULL
                         CONSTRAINT xx_sup_req_status_chk
                         CHECK (status IN ('NEW','IN_PROGRESS','RETRY','SUCCESS','ERROR_FINAL')),
   retry_count           NUMBER         DEFAULT 0 NOT NULL,
   next_retry_at         TIMESTAMP,
   claimed_at            TIMESTAMP,
   oic_instance_id       VARCHAR2(100),
   error_entity          VARCHAR2(10),
   error_ref             VARCHAR2(100),
   error_code            VARCHAR2(100),
   error_http_status     NUMBER,
   error_message         VARCHAR2(4000),
   callback_status       VARCHAR2(10)
                         CONSTRAINT xx_sup_req_cb_chk
                         CHECK (callback_status IN ('PENDING','SENT','FAILED','GAVE_UP')),
   callback_attempts     NUMBER         DEFAULT 0 NOT NULL,
   next_callback_at      TIMESTAMP,
   callback_message      VARCHAR2(4000),
   sensitive_purged      VARCHAR2(1)    DEFAULT 'N' NOT NULL,
   created_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
   updated_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
   CONSTRAINT xx_sup_req_uk UNIQUE (request_id)
);

CREATE INDEX xx_sup_req_sup_ix  ON xx_sup_req (supplier_ref, status);
CREATE INDEX xx_sup_req_work_ix ON xx_sup_req (status, next_retry_at);
CREATE INDEX xx_sup_req_cb_ix   ON xx_sup_req (callback_status, next_callback_at);

-- Every section table below has the same control columns:
--   operation       CREATE (POST to ERP) or UPDATE (PATCH), set when the message is claimed
--   process_status  PENDING -> DONE, or ERROR
--   erp_id / erp_id2 / erp_number   what ERP returned
--   error_message   last ERP error for this item

-- Supplier header (0 or 1 per message).
CREATE TABLE xx_sup_req_header (
   req_id                NUMBER         CONSTRAINT xx_sup_req_header_pk PRIMARY KEY
                         CONSTRAINT xx_sup_req_header_fk REFERENCES xx_sup_req (req_id) ON DELETE CASCADE,
   supplier_name         VARCHAR2(360),
   tax_organization_type VARCHAR2(80),
   supplier_type         VARCHAR2(80),
   taxpayer_id           VARCHAR2(50),
   duns_number           VARCHAR2(30),
   operation             VARCHAR2(10),
   process_status        VARCHAR2(10)   DEFAULT 'PENDING' NOT NULL,
   erp_id                NUMBER,                                  -- SupplierId
   erp_id2               NUMBER,                                  -- SupplierPartyId
   erp_number            VARCHAR2(30),                            -- SupplierNumber
   error_message         VARCHAR2(4000),
   updated_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE xx_sup_req_address (
   req_id                NUMBER         NOT NULL
                         CONSTRAINT xx_sup_req_address_fk REFERENCES xx_sup_req (req_id) ON DELETE CASCADE,
   line_no               NUMBER         NOT NULL,
   address_ref           VARCHAR2(100)  NOT NULL,
   address_name          VARCHAR2(240),
   address_line1         VARCHAR2(240),
   address_line2         VARCHAR2(240),
   city                  VARCHAR2(60),
   state                 VARCHAR2(60),
   postal_code           VARCHAR2(60),
   country               VARCHAR2(10),
   operation             VARCHAR2(10),
   process_status        VARCHAR2(10)   DEFAULT 'PENDING' NOT NULL,
   erp_id                NUMBER,                                  -- SupplierAddressId
   erp_id2               NUMBER,
   erp_number            VARCHAR2(30),
   error_message         VARCHAR2(4000),
   updated_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
   CONSTRAINT xx_sup_req_address_pk PRIMARY KEY (req_id, line_no),
   CONSTRAINT xx_sup_req_address_uk UNIQUE (req_id, address_ref)
);

CREATE TABLE xx_sup_req_site (
   req_id                NUMBER         NOT NULL
                         CONSTRAINT xx_sup_req_site_fk REFERENCES xx_sup_req (req_id) ON DELETE CASCADE,
   line_no               NUMBER         NOT NULL,
   site_ref              VARCHAR2(100)  NOT NULL,
   address_ref           VARCHAR2(100),
   site_name             VARCHAR2(240),
   procurement_bu        VARCHAR2(240),
   payment_terms         VARCHAR2(50),
   payment_method        VARCHAR2(30),
   purchasing_flag       VARCHAR2(5),
   pay_flag              VARCHAR2(5),
   operation             VARCHAR2(10),
   process_status        VARCHAR2(10)   DEFAULT 'PENDING' NOT NULL,
   erp_id                NUMBER,                                  -- SupplierSiteId
   erp_id2               NUMBER,
   erp_number            VARCHAR2(30),
   error_message         VARCHAR2(4000),
   updated_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
   CONSTRAINT xx_sup_req_site_pk PRIMARY KEY (req_id, line_no),
   CONSTRAINT xx_sup_req_site_uk UNIQUE (req_id, site_ref)
);

CREATE TABLE xx_sup_req_contact (
   req_id                NUMBER         NOT NULL
                         CONSTRAINT xx_sup_req_contact_fk REFERENCES xx_sup_req (req_id) ON DELETE CASCADE,
   line_no               NUMBER         NOT NULL,
   contact_ref           VARCHAR2(100)  NOT NULL,
   first_name            VARCHAR2(150),
   last_name             VARCHAR2(150),
   email                 VARCHAR2(320),
   phone                 VARCHAR2(60),
   operation             VARCHAR2(10),
   process_status        VARCHAR2(10)   DEFAULT 'PENDING' NOT NULL,
   erp_id                NUMBER,                                  -- SupplierContactId
   erp_id2               NUMBER,
   erp_number            VARCHAR2(30),
   error_message         VARCHAR2(4000),
   updated_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
   CONSTRAINT xx_sup_req_contact_pk PRIMARY KEY (req_id, line_no),
   CONSTRAINT xx_sup_req_contact_uk UNIQUE (req_id, contact_ref)
);

CREATE TABLE xx_sup_req_tax (
   req_id                NUMBER         NOT NULL
                         CONSTRAINT xx_sup_req_tax_fk REFERENCES xx_sup_req (req_id) ON DELETE CASCADE,
   line_no               NUMBER         NOT NULL,
   tax_ref               VARCHAR2(100)  NOT NULL,
   tax_regime_code       VARCHAR2(30),
   registration_number   VARCHAR2(50),
   country               VARCHAR2(10),
   effective_from        VARCHAR2(10),                            -- YYYY-MM-DD as sent
   operation             VARCHAR2(10),
   process_status        VARCHAR2(10)   DEFAULT 'PENDING' NOT NULL,
   erp_id                NUMBER,                                  -- tax registration id
   erp_id2               NUMBER,
   erp_number            VARCHAR2(30),
   error_message         VARCHAR2(4000),
   updated_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
   CONSTRAINT xx_sup_req_tax_pk PRIMARY KEY (req_id, line_no),
   CONSTRAINT xx_sup_req_tax_uk UNIQUE (req_id, tax_ref)
);

CREATE TABLE xx_sup_req_bank (
   req_id                NUMBER         NOT NULL
                         CONSTRAINT xx_sup_req_bank_fk REFERENCES xx_sup_req (req_id) ON DELETE CASCADE,
   line_no               NUMBER         NOT NULL,
   bank_ref              VARCHAR2(100)  NOT NULL,
   bank_name             VARCHAR2(360),
   branch_name           VARCHAR2(360),
   account_number        VARCHAR2(100),
   iban                  VARCHAR2(50),
   account_name          VARCHAR2(360),
   currency_code         VARCHAR2(15),
   country               VARCHAR2(10),
   account_type          VARCHAR2(30),
   operation             VARCHAR2(10),
   process_status        VARCHAR2(10)   DEFAULT 'PENDING' NOT NULL,
   erp_id                NUMBER,                                  -- BankAccountId
   erp_id2               NUMBER,                                  -- instrument assignment id
   erp_number            VARCHAR2(30),
   error_message         VARCHAR2(4000),
   updated_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
   CONSTRAINT xx_sup_req_bank_pk PRIMARY KEY (req_id, line_no),
   CONSTRAINT xx_sup_req_bank_uk UNIQUE (req_id, bank_ref)
);

-- Audit trail of every event.
CREATE TABLE xx_sup_log (
   log_id                NUMBER GENERATED ALWAYS AS IDENTITY
                         CONSTRAINT xx_sup_log_pk PRIMARY KEY,
   req_id                NUMBER,
   event                 VARCHAR2(30)   NOT NULL,
   entity_type           VARCHAR2(10),
   entity_ref            VARCHAR2(100),
   detail                VARCHAR2(4000),
   oic_instance_id       VARCHAR2(100),
   created_on            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE INDEX xx_sup_log_ix ON xx_sup_log (req_id, created_on);
