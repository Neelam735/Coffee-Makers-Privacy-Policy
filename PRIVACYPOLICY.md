# Privacy Policy



**Last updated:** [17-08-2026]

## Who we are

This ordering service is operated by Coffee Makers
 ("we", "us").



## What we collect

When you place an order we collect:

| What | Why | How it is stored |
|---|---|---|
| **Your name** | So we can call out your order and print it on your slip | Stored as you enter it |
| **Your mobile number** (optional) |  **Stored only as an irreversible one-way hash.** We cannot read it back, display it, or export it |
| **Your order** — items, options, notes, amount, time | To prepare your order, print your bill, and keep our sales records | Stored with the order |
| **Payment method** — cash  and whether payment was taken | To reconcile our takings | Stored with the order |

**We do not collect** your address, date of birth, email, location, or any
identity document. We do not use advertising or analytics trackers.

Giving your mobile number is **optional** — you can order without it.

### About your mobile number

Your number is not kept in readable form.
It is converted to a one-way hash, so neither our staff nor our software
provider can recover it. This means we cannot use it to contact you for
anything other than the confirmation, and it does not appear in any report.

## Why we are allowed to use it

We use your data on the basis of the **consent** you give when you enter your
details to place an order, and to perform the order you asked for. You may
withdraw consent at any time (see *Your rights*).

## Who else sees it

We use these providers to run the service. They process data on our
instructions only, and do not use it for their own purposes:

| Provider | Purpose | Where |
|---|---|---|
| **Railway** | Application hosting and database | US West |
| **Vercel** | Hosting the ordering website | Global CDN |
| **[Neelam Srivastava]** | Builds and maintains the software | India |


We do not sell your data, and we do not share it for marketing.

## How long we keep it

Order records — including your name and the hashed mobile number — are kept for
**[1 year]** to meet our tax and GST record-keeping
obligations, then deleted.

## How we protect it

- Traffic between your device and our systems is encrypted (HTTPS).
- Mobile numbers are stored only as one-way hashes.
- Access to the counter and admin systems requires a password.
- Our database is hosted by Railway with access restricted to authorised staff
  and our software provider.



## Children

This service is not directed at children under 18. We do not knowingly collect
data from children.

## Changes

We may update this policy. The revised version will be posted here with a new
date, and material changes will be notified on the ordering page.

---

### For the developer — what still needs doing

The policy above claims things the system must actually do. Check each:

- [ ] **Backups enabled**, so records are not lost — otherwise the retention
      commitment cannot be met
- [ ] **Retention actually enforced** — nothing currently deletes old orders,
      so the stated period is a promise the system does not yet keep
- [ ] **A deletion route exists** for erasure requests, even if it is a manual
      SQL statement with a documented procedure
- [ ] **Railway region confirmed** and named above
- [ ] **Linked from the screen where name and mobile are entered** — notice has
      to be given at the point of collection, not buried
