# Supplier Onboarding – Oracle Integration Cloud (OIC)

Integration archive: **`SUPPLIER_ONBOARDING_01.00.0000.iar`**
(Identifier `SUPPLIER_ONBOARDING`, version `01.00.0000`, app-driven orchestration)

## What it does

```
Client ──POST /suppliers──▶ [REST Trigger]
                               │
                        Validate request ──invalid──▶ 400-style VALIDATION_ERROR response
                               │
               GET ERP /suppliers?q=Supplier='..' or TaxpayerId='..'
                               │
                   count > 0 ──yes──▶ DUPLICATE response (existing SupplierId/Number)
                               │ no
                  ┌──── Scope (fault handler → FAILED response) ────┐
                  │ POST /suppliers                  (create header) │
                  │ POST /suppliers/{id}/child/addresses             │
                  │ POST /suppliers/{id}/child/sites                 │
                  │ for-each contact: POST /suppliers/{id}/child/contacts │
                  └──────────────────────────────────────────────────┘
                               │
                        CREATED response (SupplierId, SupplierNumber)
Global fault handler: email notification to $NotificationEmail, then rethrow.
```

## Connections (configure after import)

| Code | Adapter | Role | What to set |
|---|---|---|---|
| `SUPPLIER_ONB_REST_TRIGGER` | REST | Trigger | Security: OAuth 2.0 or Basic Auth |
| `ORACLE_ERP_CLOUD_REST` | REST | Invoke | Base URL `https://<pod>.fa.<dc>.oraclecloud.com`, Basic Auth user with the *Supplier Administrator* role (or `POZ_SUPPLIER_...` privileges) |

> You can swap `ORACLE_ERP_CLOUD_REST` for the native **Oracle ERP Cloud adapter** and choose the *Suppliers* business object. The maps stay the same.

## Integration properties

| Property | Default |
|---|---|
| `NotificationEmail` | `procurement-integrations@example.com` |
| `DefaultProcurementBU` | `US1 Business Unit` (used when the request omits `businessUnit`) |

## API contract

* Request: [`samples/request.json`](samples/request.json)
* Responses: [`response-created.json`](samples/response-created.json), [`response-duplicate.json`](samples/response-duplicate.json), [`response-error.json`](samples/response-error.json)
* Required fields: `supplierName`, `taxRegistrationNumber`, `address.country`

## Import

1. OIC console → **Integrations** → **Import** → select `SUPPLIER_ONBOARDING_01.00.0000.iar`.
2. Open **Connections**, edit both connections above, **Test** and **Save**.
3. Activate the integration and call it with `samples/request.json`.

## ⚠️ Important: hand-authored archive

This `.iar` was authored by hand, not exported from an OIC instance. Oracle does not publish the
internal `.iar` schema, and it changes between OIC versions (Gen2 / Gen3). The archive has the standard
layout (`icspackage/project/<CODE>_<VERSION>/PROJECT-INF/project.xml`, `resources/`, `appinstances/`),
and the XSLT maps were tested with Saxon, but **OIC may reject the import or need you to regenerate
the adapter endpoints.**

If the import fails, you can rebuild the integration in the designer in about 20–30 minutes with the pieces in `src/`:

1. Create the two REST connections from the table above.
2. Create an **App Driven Orchestration** named *Supplier Onboarding*.
3. **Trigger**: REST, `POST /suppliers`, request/response JSON = the files in `samples/`.
4. **Switch** *ValidateRequest*: use the condition from `project.xml` (`router_1`), then map with `map_validation_error.xsl` and **Return**.
5. **Invoke** *CheckExistingSupplier*: `GET /fscmRestApi/resources/11.13.18.05/suppliers` with query params `q`, `fields`, `onlyData`, mapped with `map_check_supplier.xsl`.
6. **Switch** *SupplierExists* (`count > 0`): map with `map_duplicate_response.xsl`, then **Return**.
7. **Scope**: add invokes for the supplier, address, site, and contacts (inside a For-Each on `contacts`). The request mappings are `map_create_*.xsl`. Map `map_fault_response.xsl` in the scope's default fault handler.
8. Map the final response with `map_success_response.xsl`. Set the tracking fields to `supplierName` and `taxRegistrationNumber`.
9. Activate it, then **Export**. The exported file is a `.iar` that your instance is guaranteed to accept.

In each mapper, open the XSLT view and paste in the matching `.xsl` file. OIC uses its own
namespace prefixes, so you may need to re-point the source and target roots.

## Rebuilding the archive

```bash
./build_iar.sh   # zips src/icspackage → SUPPLIER_ONBOARDING_01.00.0000.iar
```
