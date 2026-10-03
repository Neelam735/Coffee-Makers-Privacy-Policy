# Supplier create / update: Apex Analytics → OIC → Oracle ERP Cloud

ATP schema for the two-lane supplier integration.

- **CREATE lane:** the supplier is not yet in `XX_SUP_MASTER`.
- **UPDATE lane:** the supplier is already in `XX_SUP_MASTER`. Each address, site, contact, tax registration and bank account is updated if its reference is in `XX_SUP_XREF`, and created otherwise.

The full step-by-step developer guide (database and OIC, action by action) is the
"Supplier Create & Update Integration – OIC + ATP Developer Guide" document.

## Install

Connect as the owner schema and run:

```sql
@sql/install.sql      -- 10 tables, 9 views, package XX_SUP_PKG (all VALID)
@sql/99_test.sql      -- self-checking test: "64 passed, 0 failed" (rolls back)
@sql/05_purge_job.sql -- optional nightly masking of bank details
```

`sql/uninstall.sql` drops everything. The scripts use only Oracle 19c features and were tested on Oracle Database 23ai Free.

## Files

| File | Contents |
|---|---|
| `sql/01_tables.sql` | Master layer (`XX_SUP_MASTER`, `XX_SUP_XREF`), request layer (`XX_SUP_REQ` + one table per section), `XX_SUP_LOG` |
| `sql/02_pkg_spec.sql`, `sql/03_pkg_body.sql` | `XX_SUP_PKG`: `receive_request(_b64)`, `claim_request`, `line_done`, `mark_failure`, `mark_success`, `mark_callback`, `prepare_work`, `reprocess`, `purge_sensitive` |
| `sql/04_views.sql` | Views OIC reads: `xx_sup_req_v`, one view per section, `xx_sup_result_v`, `xx_sup_work_v` |
| `sql/99_test.sql` | Tests both lanes, partial updates, retry/resume, ordering per supplier, lane rules, reprocess, callbacks, purge |
