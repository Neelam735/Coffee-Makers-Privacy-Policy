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
              bankAccount.accountNumber present? ──no──┐
                               │ yes                   │
                  ┌──── Scope (fault handler → bankAccountStatus=FAILED, email) ──┐
                  │ POST /externalBankAccounts   (owner = SupplierPartyId)        │
                  │ GET  /paymentsExternalPayees?q=PayeePartyIdentifier=..        │
                  │ POST /instrumentAssignments  (bank account → supplier payee)  │
                  └───────────────────────────────────────────────────────────────┘
                               │                       │
        CREATED (or PARTIALLY_CREATED if the bank step failed) with SupplierId, SupplierNumber, bankAccountId
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
* Responses: [`response-created.json`](samples/response-created.json), [`response-partial.json`](samples/response-partial.json), [`response-duplicate.json`](samples/response-duplicate.json), [`response-error.json`](samples/response-error.json)
* Required fields: `supplierName`, `taxRegistrationNumber`, `address.country`

### Bank account (optional)

Send a `bankAccount` object to also create the supplier's bank account. Its fields are `bankName`, `branchName`, `accountNumber`, and optionally `iban`, `accountName`, `currencyCode`, `countryCode` and `accountType`.

* The account is created as an **external bank account** owned by the supplier's party. It is then assigned as the primary payment instrument of the **supplier-level payee** (the payee with no site).
* Spaces are removed from the account number and IBAN. The IBAN, currency and country are upper-cased. `countryCode` defaults to `address.country`, and `accountName` defaults to `supplierName`.
* The bank steps run in their own scope. If they fail, the supplier is **not** rolled back. The response is `PARTIALLY_CREATED` with `bankAccountStatus: FAILED` and the ERP error, and an email is sent to `NotificationEmail`.
* `bankAccountStatus` is `CREATED`, `FAILED` or `NOT_REQUESTED`.
* **Bank details are sensitive.** Keep payload tracing and audit logging off for this integration in production. Don't add `accountNumber` or `iban` as tracking fields.
* The ERP user also needs the privileges to manage external payee bank accounts (e.g. *Supplier Bank Account Management* / `IBY_...` duties).
* The bank and branch must already exist in ERP, or your ERP must be set up to allow creating them from the account. Check that the `externalBankAccounts`, `paymentsExternalPayees` and `instrumentAssignments` field names match your Fusion release's REST docs (see *Payables → Payments* REST API).

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
8. Add a Switch on `bankAccount/accountNumber` with a second Scope. Its invokes are `CreateBankAccount`, `GetSupplierPayee` and `AssignBankAccount`, mapped with `map_create_bank_account.xsl`, `map_get_supplier_payee.xsl` and `map_assign_bank_account.xsl`. At the end of the scope, assign `vBankAccountStatus = 'CREATED'`. In its default fault handler, assign `'FAILED'` and the fault reason, and send the notification.
9. Map the final response with `map_success_response.xsl`, passing `vBankAccountStatus` and `vBankFaultMessage` into its `BankAccountStatus` and `BankFaultMessage` parameters. Set the tracking fields to `supplierName` and `taxRegistrationNumber`.
10. Activate it, then **Export**. The exported file is a `.iar` that your instance is guaranteed to accept.

In each mapper, open the XSLT view and paste in the matching `.xsl` file. OIC uses its own
namespace prefixes, so you may need to re-point the source and target roots.

## Rebuilding the archive

```bash
./build_iar.sh   # zips src/icspackage → SUPPLIER_ONBOARDING_01.00.0000.iar
```
