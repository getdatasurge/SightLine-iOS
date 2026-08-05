# Web App Route Inventory (src/app, App Router) — iOS Field PRD Parity Audit

Source: `SightLine/.worktrees/staging-merge/src/app`. `/api/*` excluded entirely. 104 user-facing routes across 5 top-level sections. All rows classified from page.tsx code (metadata titles, JSDoc/inline comments, imports) — **0 unclassifiable**.

## Section: (auth)

| Route | Screen | Purpose | Persona | Data Domains |
|---|---|---|---|---|
| /sign-in | Sign In | Credentials sign-in form; redirects to /dashboard on success (or ?next=) | All (unauthenticated) | Auth |

## Section: world (marketing, top-level, no group)

| Route | Screen | Purpose | Persona | Data Domains |
|---|---|---|---|---|
| /world | World | Scroll-scrubbed cinematic "fly through the world" marketing film (lead→measure→quote→schedule→install→invoice), procedural clay-diorama render; self-contained preview | Prospect/visitor | Marketing |

**Anomaly:** no `src/app/page.tsx` exists — the site has no root `/` page. `/world`'s own comment states it's mounted "so it can be reviewed before any decision about the site's root route." Root landing page is an open/undecided architectural question.

## Section: (public) — token/slug-gated, unauthenticated, customer-facing

| Route | Screen | Purpose | Persona | Data Domains |
|---|---|---|---|---|
| /p/[token] | Shared Document | View a tenant-shared document/proposal via link token | Customer | Documents / Proposals |
| /reviews/[businessId] | Customer Reviews | Public listing of a business's published customer reviews | Customer / Prospect | Reviews |
| /review/[token] | Leave a Review | Token-gated review submission form | Customer | Reviews |
| /lead/[businessId] | Contact Us | Public lead-capture contact form | Prospect / Customer | Leads |
| /f/[businessId] | Request a Quote | Public lead/quote-request form (business-level) | Prospect | Leads / Quotes |
| /f/[businessId]/[formId] | Request a Quote | Public lead form, specific form variant | Prospect | Leads / Quotes |
| /appt/[token] | Cancel Appointment | Token-gated self-service appointment cancellation | Customer | Scheduling |

## Section: marketplace — cross-tenant subcontractor/installer bidding

| Route | Screen | Purpose | Persona | Data Domains |
|---|---|---|---|---|
| /marketplace | Active Postings | Browse currently-active marketplace job postings | Subcontractor / Installer | Marketplace |
| /marketplace/postings | Browse Postings | Filtered posting browse/search | Subcontractor / Installer | Marketplace |
| /marketplace/postings/[id] | Posting Detail | View one posting, place a bid | Subcontractor / Installer | Marketplace / Bids |
| /marketplace/my-postings | My Postings | Tenant's own posted jobs (as poster) | Owner/Office | Marketplace |
| /marketplace/my-bids | My Bids | Bids the current installer/tenant has submitted | Subcontractor / Installer | Marketplace / Bids |
| /marketplace/installers | Installer Directory | Browse installer profiles for hire | Owner/Office | Marketplace |
| /marketplace/installers/[id] | Installer Profile | View one installer's public profile | Owner/Office | Marketplace |
| /marketplace/profile | My Profile | Installer's own marketplace profile editor | Subcontractor / Installer | Marketplace |
| /marketplace/market-rates | Market Rates | Regional install-rate benchmark data | Owner/Office & Installer | Marketplace |
| /marketplace/register | Register (gate) | Session/account bootstrap gate, no visible metadata title | Owner/Office / Installer | Marketplace / Auth |
| /marketplace/onboarding | Onboarding (gate) | Marketplace onboarding gate/flow, no visible metadata title | Owner/Office / Installer | Marketplace / Auth |
| /marketplace/rate/[awardId] | Rate | Post-job rating for a completed marketplace award | Owner/Office & Installer | Marketplace / Reviews |

## Section: (dashboard) — Sales & Proposals

| Route | Screen | Purpose | Persona | Data Domains |
|---|---|---|---|---|
| /proposals | Proposals | Proposal list/pipeline | Owner/Office | Quotes / Proposals |
| /proposals/new | New Proposal | Create-proposal entry flow | Owner/Office | Quotes / Proposals |
| /proposals/templates | Canned Proposals | Manage reusable proposal templates | Owner/Office | Quotes / Proposals |
| /proposals/[id] | Proposal | Proposal detail/workspace | Owner/Office | Quotes / Proposals |
| /proposals/[id]/print | Proposal · Print | Printable proposal document | Office (customer-facing output) | Quotes / Proposals |
| /proposals/[id]/intake/takeoff | PDF Takeoff | PDF-based measurement takeoff during proposal intake | Field Technician / Office | Measurements / Takeoff |
| /proposals/[id]/intake/takeoff/[sheetId] | Takeoff Sheet | Single takeoff sheet annotation view | Field Technician / Office | Measurements / Takeoff |
| /proposals/[id]/intake/capture | Capture | On-site elevation/measurement capture for proposal intake | Field Technician | Measurements |
| /bids | Bid Board | Internal bid/RFP pipeline board | Owner/Office | Quotes / Bids |
| /bids/[id] | Bid | Bid detail | Owner/Office | Quotes / Bids |
| /old-measurements | Old Measurements | See Anomalies — hidden re-surface of a retired proposal-measurement wizard, unlinked from nav | Owner/Office (internal/dev) | Measurements / Proposals |

## Section: (dashboard) — Projects & Field Ops

| Route | Screen | Purpose | Persona | Data Domains |
|---|---|---|---|---|
| /projects | Projects | Project/job list | Owner/Office | Jobs / Projects |
| /projects/[id] | Project | Project detail workspace | Owner/Office | Jobs / Projects |
| /projects/[id]/takeoff | PDF Takeoff | Project-level PDF takeoff | Field Technician / Office | Measurements |
| /projects/[id]/takeoff/[sheetId] | Takeoff Sheet | Single takeoff sheet view | Field Technician / Office | Measurements |
| /projects/[id]/work-order | Work Order · Print | Printable crew work order | Field Technician (consumer) | Jobs / Scheduling |
| /projects/[id]/capture | Capture | On-site elevation/measurement capture for a project (building walk, trace-pad, photo per elevation) | Field Technician | Measurements |
| /projects/[id]/agreement | Service Agreement · Print | Printable signed service agreement | Office (customer-facing output) | Contracts |
| /projects/[id]/summary | Project Summary · Print | Printable project summary | Office (customer-facing output) | Jobs / Projects |
| /projects/[id]/install | Installer View | Field install checklist/reference view | Field Technician | Jobs / Install |
| /appointments/[id] | Job Card | Per-appointment field record: access notes, site contacts, notes, attachments — explicitly built "for a visiting tech" | Field Technician | Scheduling / Jobs |
| /work-logs | Work Logs | Crew check-in/check-out time & work-type tracking | Field Technician (entry) / Office (review) | Scheduling / Labor |
| /glass-readings | Glass Readings | Log/view on-site glass measurement readings per job | Field Technician | Measurements / Jobs |
| /inspections | Inspections | Inspection records | Field Technician / Office | Jobs / QA |
| /caulking | Caulking | Caulking service records | Field Technician / Office | Jobs / Service records |
| /measurements | Measurement Report | Shop-wide measurement rollup report | Owner/Office | Measurements |

## Section: (dashboard) — Inventory & Procurement

| Route | Screen | Purpose | Persona | Data Domains |
|---|---|---|---|---|
| /inventory | Inventory | Roll/stock inventory list | Owner/Office | Inventory |
| /inventory/catalog | Film Catalog | Product catalog management | Owner/Office | Inventory / Products |
| /inventory/catalog/import | Import Film Catalog | Bulk catalog import | Owner/Office | Inventory / Products |
| /inventory/rolls/[id] | Roll | Single inventory roll detail | Owner/Office | Inventory |
| /inventory/labels | Print Roll Labels | Generate/print QR roll labels | Owner/Office / Warehouse | Inventory |
| /optimizer | Cut Optimizer | Nesting/cut-plan optimizer against job surfaces & shelf stock widths | Owner/Office | Inventory / Jobs |
| /procurement | Procurement | Purchasing/reorder dashboard | Owner/Office | Procurement |
| /procurement/po/[id] | Purchase Order | Single PO detail | Owner/Office | Procurement |
| /reservations | Reservations | Film stock holds/reservations | Owner/Office | Inventory |
| /suppliers | Suppliers | Vendor directory | Owner/Office | Procurement |

## Section: (dashboard) — CRM & Contacts

| Route | Screen | Purpose | Persona | Data Domains |
|---|---|---|---|---|
| /contacts | Contacts | Contact list | Owner/Office | CRM |
| /contacts/[id] | Contact | Contact detail | Owner/Office | CRM |
| /contacts/merge | Merge Contacts | Duplicate-contact merge tool | Owner/Office | CRM |
| /contacts/import | Import Contacts | Bulk contact import | Owner/Office | CRM |
| /buildings | Buildings | Building/site directory | Owner/Office | CRM / Sites |
| /buildings/[id] | Building | Building detail | Owner/Office | CRM / Sites |
| /lead-forms | Lead Forms | Inbound lead pipeline | Owner/Office | Leads |
| /lead-forms/manage | Manage Lead Forms | Configure public-facing lead-form fields | Owner/Office | Leads |
| /lead-forms/manage/[id] | Edit Lead Form | Edit one lead-form configuration | Owner/Office | Leads |
| /notes | Notes | Cross-entity note feed | Owner/Office | CRM |
| /subcontractors | Subcontractors | Internal subcontractor directory | Owner/Office | CRM / Labor |
| /subcontractors/[id] | Subcontractor | Subcontractor detail | Owner/Office | CRM / Labor |
| /reviews | Reviews | Internal review feed/moderation | Owner/Office | Reviews |

## Section: (dashboard) — Scheduling

| Route | Screen | Purpose | Persona | Data Domains |
|---|---|---|---|---|
| /calendar | Schedule | Appointment/crew calendar | Owner/Office (dispatch) | Scheduling |
| /tasks | Tasks | Internal task list | Owner/Office | Tasks |

## Section: (dashboard) — Financial

| Route | Screen | Purpose | Persona | Data Domains |
|---|---|---|---|---|
| /invoices | Invoices | Invoice list | Owner/Office | Invoicing |
| /invoices/[id] | Invoice | Invoice detail | Owner/Office | Invoicing |
| /invoices/[id]/print | Invoice · Print | Printable invoice | Office (customer-facing output) | Invoicing |
| /billing | Billing | SightLine subscription/plan billing | Owner/Office | Billing (SaaS) |
| /costing | Job Costing | Job cost accounting view | Owner/Office | Costing |
| /customer-pos | Customer POs | Customer purchase-order tracking | Owner/Office | Invoicing / Sales |
| /contracts | Contracts | Contract list | Owner/Office | Contracts |
| /contracts/[id] | Contract | Contract detail | Owner/Office | Contracts |

## Section: (dashboard) — Admin / Settings

| Route | Screen | Purpose | Persona | Data Domains |
|---|---|---|---|---|
| /settings | Settings | Settings hub | Owner/Office (admin) | Admin |
| /settings/products | Products | Product/pricing config | Owner/Office | Admin / Catalog |
| /settings/business | Business Settings | Business profile config | Owner/Office | Admin |
| /settings/teams | Teams | User/team management | Owner/Office | Admin |
| /settings/pricing | Film Pricing | Pricing rule config | Owner/Office | Admin / Catalog |
| /settings/account | Account Settings | Personal account settings | Owner/Office | Admin |
| /organization | Organization | Multi-business/org rollup | Owner/Office | Admin |
| /integrations | Integrations | Third-party integration config | Owner/Office | Admin / Integrations |
| /developers | API Tokens | Developer API token management | Owner/Office (technical) | Admin / Integrations |
| /services | Services | Service catalog config | Owner/Office | Admin / Catalog |
| /notifications | Notifications | Notification inbox | Owner/Office | Notifications |
| /notifications/settings | Notification Settings | Per-channel notification preferences | Owner/Office | Notifications |
| /automations | Automations | Workflow automation rules | Owner/Office | Admin / Automation |
| /audit | Audit Log | Tenant activity/audit trail | Owner/Office (admin/compliance) | Admin / Audit |
| /data-export | Data & Privacy | Data export/privacy tools | Owner/Office (admin) | Admin |
| /uploads | Uploads | Media/file upload feed | Owner/Office | Documents |

## Section: (dashboard) — Reporting / Support / Misc

| Route | Screen | Purpose | Persona | Data Domains |
|---|---|---|---|---|
| /dashboard | Dashboard | Home metrics overview | Owner/Office | Reporting |
| /analytics | Analytics | Revenue-trend & KPI reports, full-width report panels | Owner/Office | Reporting |
| /search | Search | Global cross-entity search results (PRD §8.1) | Owner/Office | Search (cross-domain) |
| /support | Support | FAQ/support page | Owner/Office | Support |
| /help | Help Center | Help article index/search | Owner/Office | Support |
| /help/[slug] | Help Article | Single help article | Owner/Office | Support |
| /documents | Documents & Warranties | Document/warranty vault | Owner/Office | Documents |
| /documents/warranty/[id] | Warranty Certificate | Printable warranty certificate | Office (customer-facing output) | Documents |

---

## Totals

- **104 rows / routes total.** Unclassifiable: **0**.
- By section: (auth) 1, world 1, (public) 7, marketplace 12, (dashboard) 83.
- (dashboard) sub-breakdown: Sales & Proposals 11, Projects & Field Ops 15, Inventory & Procurement 10, CRM & Contacts 13, Scheduling 2, Financial 8, Admin/Settings 16, Reporting/Support/Misc 8.

## Anomalies (mid-redesign / legacy / unresolved)

1. **`/old-measurements`** — page's own doc comment: "Hidden re-surface of the retired proposal-measurements wizard step (recovered from commit `542fce2`... then the whole wizard deleted in `86c1924`)." Deliberately **not** added to `config/navigation.ts`, `global-create-menu.tsx`, or `topbar.tsx` — reachable only by typed URL. Fully live (writes real data), not read-only. Genuine dead-code-that-isn't-dead risk for parity work.
2. **No root `src/app/page.tsx`.** `/` has no page at all. `/world`'s comment states it exists "as a self-contained preview... so it can be reviewed before any decision about the site's root route" — the marketing entry point is an explicitly open decision, not settled architecture.
3. **`/marketplace/register` and `/marketplace/onboarding`** have no `export const metadata` title and are thin server components that only check session and redirect/gate — likely transitional plumbing rather than full screens; verify against current marketplace onboarding flow before treating as PRD-parity surface.
4. No `_v2` directories, feature-flag-gated routes, or TODO/"coming soon" banners found elsewhere in `src/app`. Scattered "legacy" comments in `projects/[id]`, `measurements`, `optimizer`, and `proposals/[id]/files-data.ts` are **data-model fallback branches inside current pages** (e.g., unscoped-legacy measurement badges, legacy file-bin pairing pre-backfill), not separate/duplicate UI routes — noted for context, not flagged as page-level anomalies.
