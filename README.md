# Stillmine

A private, responsive salary allocation tracker based on `personal_salary_allocation_tracker_prd.docx`. It separates recorded account cash, protected savings, committed funds, unassigned cash, and loan receivables. Amounts are stored as integer paise. Browser code never contains Supabase keys or service-role credentials.

## Connect your Supabase project

1. Create a Supabase project. Set the owner email in `.env.local`. The sign-in screen has an owner-only account creation action. Supabase requires email confirmation in the configured project: follow the link in the email, then sign in. If it does not arrive, use the resend action after the provider cooldown.
2. For a fresh project, apply [`supabase/migrations/001_tracker.sql`](supabase/migrations/001_tracker.sql) once in Supabase SQL Editor. The migration creates owner-scoped tables and transactional RPCs.
3. Copy `.env.example` to `.env.local`. Set `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `TRACKER_OWNER_EMAIL` from **Project Settings → API**, and set the email to the exact Auth user you created. Use the public/anon project key, **never** the service-role key. Both variables are server-only because they lack `NEXT_PUBLIC_`.
4. Run `npm install` and `npm run dev`, then open `http://localhost:3000` and sign in.
5. Confirm the provisional opening amounts and date. Setup records opening cash and purpose classification without creating salary or replaying the historical transfer.

Keep `.env.local` private. The running app needs no database password. It is ignored by Git. Authentication passwords are entered transiently in the browser, sent to this app's server route, then to Supabase Auth. They are not embedded in frontend bundles, stored in tracker profiles, logged by the app, or returned in API responses. Auth tokens live in `HttpOnly`, `SameSite=Lax` cookies; production cookies require HTTPS.

## What is implemented

- Login, owner-scoped database operations, first-run opening confirmation, and a savings-first dashboard.
- Salary drafts, live rebalancing, recurring and one-time rows, atomic approval, version checks, and audited approved-allocation edits.
- Expenses funded by a committed fund or savings, explicit split funding for fund overages, obligation settlement, additional income, partial refunds, transfers, purpose moves, loans, repayments, waivers, and aggregate bank reconciliation.
- History with linked reversals for ordinary spending, cycle close with carryover, full JSON backup, and clean-dataset restore.
- Responsive light and dark UI; accessible labels, keyboard focus, and reduced-motion support.

## Current limits before a production release

The PRD's entire release gate is **not** met yet. In particular, approved salary receipt/date/account corrections, split salary receipts linked to one period, loan funding splits, detailed payable status by obligation, reconciliation replacement, account creation/archiving, historical recertification, and restore preview/replacement still need implementation and hosted Supabase verification. The current reconciliation guard prevents backdated expense entries into a confirmed aggregate adjustment period; a correction workflow for that adjustment is still needed. Use a fresh Supabase project for testing before entering irreplaceable financial data.

## Checks

- `npm test` runs ledger scenarios against an isolated PostgreSQL-compatible PGlite database, including the PRD opening fixture, atomic salary approval, draft isolation, expense and loan effects, transfers, aggregate reconciliation, shortfall, reversals, refund rounding, stale versions, and backup restore.
- `npm run build` verifies the production bundle and TypeScript types.
- The hosted Supabase login and Row Level Security behavior require your project values and an integration test together.
