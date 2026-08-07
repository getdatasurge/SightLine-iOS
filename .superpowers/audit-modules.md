# Web app domain-module audit — `src/modules/*` (staging-merge worktree)

Source: `src/modules/README.md` (module shape doc, purpose one-liners — stale: claims "57 modules",
repo actually has **62**; missing from its table: `mobile-auth`, `intake`, `markup`, `marketplace`,
`installer-profile`), each module's `index.ts` barrel, `src/lib/db.ts` `TENANT_MODELS` set, and
`src/app/api/v1/**/route.ts` imports (grep-verified, not inferred).

`Models owned` = tenant models this module's `services/` write/read as primary owner (per
`TENANT_MODELS` in `src/lib/db.ts`) or platform-global models it owns (noted `(global)`).
`v1 exposure` = concrete `/api/v1/**/route.ts` file(s) importing that module's service, verified by
grep of `from '@/modules/...'` across every v1 route.

## Table

| Module | Domain purpose | Key public services/methods (index.ts) | Models owned | v1 exposure |
|---|---|---|---|---|
| account | Signed-in account identity, credentials & business switching | `accountService` | Account, Organization, OrgMembership (global) | No |
| activity | Unified notes/tasks/activity feed engine (mentions, task state machine, feed merge) | pure domain only — `extractMentions`, `mergeFeed`, `buildThread` (no service export) | Activity | No |
| analytics | KPI & reporting read-model engine | `loadAnalyticsRecords`, segment/funnel/period domain fns | none (read-model over other modules) | No |
| api-tokens | REST API bearer-token auth & scopes | `apiTokenService` | ApiToken | Indirect — backs bearer auth (`withApiToken`) for every `/v1/*` route via `_lib/auth.ts`; no route of its own |
| automation | Scheduled cron jobs (reminders, digests, follow-ups) | `automationService`, `runAppointmentReminders`, `dispatchPlannedActions` | AutomationRule, AutomationRun | No (driven by non-v1 `/api/jobs/*` crons) |
| bids | Commercial RFP bid board pre-pipeline | `bidService`, `bidEmailIntakeService`, `runBidReminders` | Bid, BidTask, BidDocument | Yes — `/v1/bids`, `/v1/bids/[id]` |
| caulking | Linear-foot caulking measurement stream | `caulkingService` | Caulking | No |
| catalog | Film brands & product spec sheets | `catalogService`, `productService`, `catalogImportService` | FilmBrand, FilmProduct (global), Product (nullable-tenant), BusinessProductPricing | Yes — `/v1/products`, `/v1/products/[id]`, `/v1/products/[id]/pricing` |
| compliance | GDPR/CCPA data export & deletion | `complianceService`, `deletionRequestService`, `auditLogService` | AuditLog | No (non-v1 `/api/data-export`, `/api/jobs/business-purge`) |
| customer-po | Customer purchase-order authorization & billing tracking | `customerPOService` | CustomerPO | Yes — `/v1/customer-pos`, `/v1/customer-pos/[id]` |
| customers | Customer record, contacts, addresses, activity timeline | `customerService`, `contactImportService`, `contactMergeService` | Customer, Contact, Address, Property, Vehicle | Yes — `/v1/customers`, `/v1/customers/[id]` |
| cut-optimizer | Optimal pane-cutting math & roll counts | pure domain — `optimize`, `nest`, `planCut` | none | No |
| dashboard | Live KPI dashboard aggregation engine | `metricsService` + pure KPI domain | none | No |
| documents | Template merge-field engine + document persistence | `documentsService` | Document, DocumentSignature | No |
| esign | Manual + pluggable e-signature capture | `esignService` | EsignRequest | No |
| film-pricing | Per-location film price book & margins | `filmPricingService` | BusinessFilmPricing, FilmCostTier | Yes — `/v1/price-book`, `/v1/price-book/[filmProductId]`, `.../cost-tiers`, `.../offered` |
| glass-readings | VLT/solar meter observations against projects | `glassReadingService` | GlassReading | No |
| help | In-app help center & release notes | pure content catalog — `HELP_ARTICLES` etc | none | No |
| inspections | QA review pass over installed glass | `inspectionService` | Inspection | No |
| installer-profile | Cross-tenant installer identity for marketplace | `installerProfileService`, `priceListService`, `availabilityService`, `ratingService` | InstallerProfile, InstallerPriceListItem, InstallerAvailability, InstallerBlackoutDate (all platform-scoped) | No |
| integrations | OAuth connections catalog (QBO/Stripe/Zapier/RentCast) | `integrationService`, `syncInvoiceToQbo`, `connectRentcast` | IntegrationConnection, IntegrationExternalRef | No (non-v1 `/api/integrations/[provider]/connect,callback`) |
| intake | First-visit measurement/vehicle triage flow | `intakeService`, `intakePricingService` | none owned (writes Property/Vehicle via customers, Quote via quotes) | No |
| inventory | Film rolls, stock levels, consumption ledger | `inventoryService` | FilmRoll, RollEvent | Yes — `/v1/inventory/rolls`, `/v1/inventory/rolls/[id]` |
| invoicing | Invoices, payments, derived invoice status | `invoicingService`, payment-provider port | Invoice, Payment, InvoiceLine, TaxRate | Yes — `/v1/invoices`, `[id]`; `/v1/payments`, `[id]` |
| job-costing | Per-job cost entries & margin variance | `jobCostingService` | CostEntry | No |
| jobs | Jobs, job lines, install status workflow | `jobService` | Job, JobLine | Yes — `/v1/jobs`, `/v1/jobs/[id]` |
| leads | Lead capture & sales pipeline stages | `leadService` | Lead, LeadForm | Yes — `/v1/lead-form-submissions`, `[id]` |
| marketing | Public-site demo/contact request capture (platform-global) | `contactService` | ContactRequest (global) | No (non-v1 `/api/public/contact`) |
| marketplace | Cross-tenant installer marketplace postings/bids/awards | `postingService`, `bidService`, `awardService`, `marketRateService`, `matchingService` | MarketplacePosting, MarketplaceBid, MarketplaceAward (tenant); MarketplaceRating, MarketRateAggregate (platform) | No |
| markup | Annotation layer over documents/PDF/takeoff surfaces | `annotationService` | Annotation | No |
| measurements | Area-math domain & surface CRUD | `measurementsService`, `captureService`, `roomsService` | Surface, Room | **No** — field-app gap |
| mobile-auth | Device login/session tokens for mobile clients | `mobileAuthService` | DeviceSession | Yes — `/v1/device-auth/login`, `/refresh`, `/sessions`, `/sessions/[id]` |
| notes | Cross-entity notes feed | `noteService` | Note | No |
| notifications | In-app tenant-scoped notifications | `notificationService`, `preferenceService`, `suppressionService` | Notification, NotificationPreference, Suppression | No |
| onboarding | First-run setup checklist & progress | `onboardingService` | none (reads Business.config) | No |
| organization | Multi-location operational rollup | `organizationService` | Location | No |
| pdf | Streamable PDF generation for proposals/invoices | `renderProposalPdf`, `renderInvoicePdf`, `renderPurchaseOrderPdf` | none | No |
| pipeline | Pure lead-pipeline stage-transition state machine | pure domain — `canTransitionBid`-style stage fns (acts on Lead, owned by `leads`) | none | No |
| projects | Project hub status & section-completeness engine | pure domain (section/status derivation over Job, owned by `jobs`) | none | No |
| proposals | Multi-solution proposals with approval write-back | `proposalTemplateService`, `proposalComparisonService`, `optimizerSetupService`, `buildProposal` (pure) | Solution, SolutionLine (shared w/ quotes) | **No direct route** — `/v1/proposals` exists but is backed by `quoteService` from `quotes`, not this module (anomaly) |
| purchasing | Purchase orders through the buy lifecycle | `purchaseOrderService` | PurchaseOrder, PurchaseOrderLine | No |
| quotes | Quoting, pricing engine, quote lines/surfaces | `quoteService`, `solutionService`, `runProposalFollowups` | Quote, QuoteLine, Solution, SolutionLine | Yes — `/v1/quotes`,`[id]` **and** `/v1/proposals`,`[id]` (both backed by `quoteService`) |
| reservations | Inventory holds on film stock for jobs | `reservationService` | InventoryReservation | No |
| reviews | Review-request cadence & reputation aggregation | `reviewService`, `reviewSettingService`, `reviewCadenceService` | Review, ReviewSetting, ReviewRequestStep | Yes — `/v1/reviews`, `[id]` |
| scheduling | Appointments, technician/team assignment, locations/bays | `schedulingService`, `teamService`, `selfCancelService`, `runRemindersDispatch` | Appointment, Technician, Team, TeamMember, AppointmentReminder | Yes — `/v1/appointments`, `/v1/appointments/[id]` |
| search | Global search across contacts, jobs, quotes, invoices | `searchService` | none (read-only composer) | No |
| services | Canned service catalog sold to customers | `serviceService` | Service | Yes — `/v1/services`, `[id]` |
| settings | Business config (branding, hours, tax, units) | `settingsService` | Business (self, not in TENANT_MODELS), Membership, Role (global) | Yes — `/v1/pricing-config` only |
| sharing | Public share-token links for customer resources | `shareLinkService` | ShareToken | No |
| subcontractors | External labor assignment & insurance gating | `subcontractorService`, `runCoiReminders` | Subcontractor, SubcontractorAssignment, SubcontractorInsuranceCert | No |
| subscriptions | SaaS plan tiers & billing status | `subscriptionService` | Subscription, SubscriptionEntitlement | No |
| suppliers | Procurement vendor directory & lead times | `supplierService` | Supplier | No |
| survey | Building/elevation measurement hierarchy (WinTracker port) | `surveyService` | Building, Elevation | No |
| tags | Reusable tags & conversion analytics | `tagService` | Tag, Taggable | Yes — `/v1/tags`, `[id]` |
| takeoff | PDF/on-screen takeoff — calibrate, measure, stamp, commit-to-rooms | `takeoffService`, `takeoffExportService` | OpeningType, TakeoffSheet, TakeoffShape, TakeoffPageText | No (non-v1 `/api/takeoff/sheets`, `/api/proposals/[id]/files/.../takeoff`) |
| tasks | Assignable work items tracked open→done | `tasksService` | Task | Yes — `/v1/tasks`, `[id]` |
| uploads | File attachment validation rules | `uploadService` | Upload | No (non-v1 `/api/uploads`) |
| units | Imperial ↔ metric conversion engine | pure domain — `makeConverter`, `convertLength/Area/Weight` | none | No |
| warranties | Warranty registration & claims workflow | `warrantyService`, `registrationService`, `registrationAssembler` | Warranty, WarrantyClaim, ManufacturerRegistration | Yes — `/v1/warranties`, `[id]` |
| warranty | Warranty term parsing & expiry rules engine (pure rules consumed by `warranties`) | pure domain — `parseTerm`, `computeExpiresAt`, `validateRegistration` | none | No |
| webhooks | Outbound signed webhook delivery (Zapier) | `registerWebhook`, `listWebhooks`, `signWebhookPayload` | Webhook | No (non-v1 inbound `/api/webhooks/esign`, `/stripe` are unrelated inbound receivers) |
| worklogs | Installer check-in/out field work sessions | `workLogService` | WorkType, WorkLog | **No** — field-app gap |

**Module count: 62.**

## Field-app v1 coverage check (the 5 capability areas the iOS PRD assumes)

| PRD capability | Backing module | v1 route(s) | Status |
|---|---|---|---|
| device-auth | `mobile-auth` | `/v1/device-auth/login`, `/refresh`, `/sessions`, `/sessions/[id]` | **Covered** |
| work-logs | `worklogs` (`WorkLog` model) | none | **NOT covered** — no `/v1/work-logs` route exists anywhere in `src/app/api/v1` |
| work-types | `worklogs` (`WorkType` model) | none | **NOT covered** — no `/v1/work-types` route exists |
| scheduling | `scheduling` | `/v1/appointments`, `/v1/appointments/[id]` | **Covered** |
| measurements/jobs | `measurements` (Surface/Room) + `jobs` (Job/JobLine) | `jobs` → `/v1/jobs`, `[id]`; `measurements` → none | **Half covered** — `jobs` is exposed, `measurements` has zero v1 routes |

## Anomalies for the iOS PRD audit

1. **`worklogs` and `measurements` have full service layers (`workLogService`, `measurementsService`, `captureService`, `roomsService`) but zero `/v1` routes.** These are two of the five capability areas the field app needs (work-logs, work-types, measurements) — this is the primary gap the iOS backend work must close, not a pre-existing surface to mirror.
2. **`/v1/proposals` does not use the `proposals` module.** Both `/v1/proposals/route.ts` and `/v1/quotes/route.ts` import `quoteService` from `@/modules/quotes`; the real `proposals` module (multi-solution engine, `buildProposal`, comparison/template services) is entirely absent from v1. "Proposals" in the v1 API is really "Quotes marked as proposals," not the richer domain module.
3. **`src/modules/README.md` is stale** — it enumerates 57 modules and omits `mobile-auth`, `intake`, `markup`, `marketplace`, `installer-profile` from its grouped tables (all 5 exist on disk with working `index.ts` barrels).
4. **`api-tokens` has no route of its own** but is the auth backbone every `/v1/*` route depends on (`withApiToken` in `_lib/auth.ts`) — worth noting as infrastructure, not a domain surface.
5. **`settings` module's only v1 exposure is `/v1/pricing-config`** (via `getPricingConfig`/`savePricingConfig`) — the module's larger staff/roles/business-profile surface is web-app-only.
