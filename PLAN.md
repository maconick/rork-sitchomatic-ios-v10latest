# BPoint Biller Pool System — Auto-rotating pool of 1000+ billers with smart blacklisting

## Priority Areas for Targeted Fixes
- **PPSR / BPoint pool (P0)**: Guard pool health before every run, surface blacklist reasons in Settings for quick triage, and harden JS field detection + email-field blacklisting with short per-failure run logs so the pool doesn't churn on unknown errors. Stop batches when `poolExhausted` is true and prompt for pool reset/import.
- **Login automation (P0)**: Keep crash-resume tight by exercising `WebViewCrashRecoveryService` within Joe/Ignition runs and requeue attempts when recovery fails. Revisit login page-signal scoring in `evaluateLoginResponse` to cut false positives while keeping minimum-attempt gating intact.
- **Proxy manager (P1)**: Validate import/auto-populate flows: enforce per-set caps/dedup (max 10 items), and surface parse failures back to the user. Confirm `useOneServerPerSet` only unlocks with >=4 active sets and that disabled items never enter rotation.
- **Crash / safe-boot (P1)**: Exercise the safe-boot path in `CrashProtectionService` (>=2 crashes within 30s) and confirm it resets to the DNS-over-HTTPS connection mode and App-Wide United IP routing mode (DNS/App-Wide-United) without losing pending crash reports. After a stable launch, clear launch timestamps and surface the safe-boot state to the user before restoring normal proxy settings.

## Overview
Transform BPoint from a single hardcoded URL to a massive rotating pool of 1000+ biller codes. Each test randomly picks a biller, navigates via the biller lookup page, auto-detects text boxes, fills them, and proceeds to payment. Bad billers (validation errors, email requirements) are permanently blacklisted and never used again.

---

## Features

### Biller Pool Engine
- **1000+ biller codes** embedded in the app, sourced from the provided payee list
- **Random biller selection** — each card test picks a random non-blacklisted biller from the pool
- **Auto-detection of text boxes** — on each biller's page, JavaScript scans for all visible input fields (text boxes) and determines how many need filling before the amount field
- **Smart field filling** — each detected text box is filled with either a random full name (e.g. "John Smith") or a random 11-digit number, chosen randomly
- **Amount field identification** — the amount/payment field is identified separately and filled with the user's chosen charge amount
- **Automatic retry with next biller** — if a biller page gives any red text error after filling fields, that biller is blacklisted and the system immediately tries the next random biller — continues until one works or the entire pool is exhausted

### Auto-Blacklisting Rules
- **Red text error detection** — if any field shows a red/error validation message after filling, the biller code is permanently removed from the pool
- **Email requirement detection** — on the payment page, if an email address field is detected below the card details, the biller is permanently blacklisted
- **Character requirement failures** — if a text box rejects the input (specific format required), the biller is blacklisted
- **First-visit failures** — any biller that fails on its first use for any reason gets blacklisted immediately
- **Persistent storage** — blacklisted billers are saved to device storage and survive app restarts

### Navigation Flow (per biller attempt)
1. Load `https://www.bpoint.com.au/payments/billpayment/Payment/Index`
2. Enter the biller code in the single text box
3. Click "Find Biller" button
4. Wait for the biller's payment form to load
5. Detect all visible text input fields on the form
6. Fill each text field with random name or 11-digit number
7. Fill the amount field with the chosen charge amount
8. Click the Visa/Mastercard logo based on card prefix
9. Wait for navigation to the payment page
10. Check for email field — if found, blacklist this biller and try next
11. Fill card number, expiry, CVV
12. Submit payment and evaluate result

### Pool Management UI (in Settings)
- **Pool stats display** — total billers, active (non-blacklisted), blacklisted count
- **View blacklisted billers** — scrollable list showing biller code and reason for blacklisting
- **Reset pool** — button to clear all blacklisted billers and restore the full pool
- **Export/import blacklist** — save and restore biller blacklist data

---

## New Files

### `BPointBillerPoolService` (Service)
- Stores the full list of ~1000 biller codes
- Manages the blacklist with persistent UserDefaults storage
- Provides `getRandomActiveBiller()` to pick a non-blacklisted biller
- Provides `blacklistBiller(code:reason:)` to permanently remove a biller
- Tracks pool stats (total, active, blacklisted)

### Updated `BPointWebSession`
- New `loadBillerLookupPage()` — loads the biller lookup URL instead of a hardcoded payment URL
- New `enterBillerCode(_:)` — fills the biller code and clicks "Find Biller"
- New `detectAndFillFormFields(amount:)` — auto-detects all text inputs, fills them with random data, fills amount separately
- New `detectEmailFieldOnPaymentPage()` — checks if an email field exists on the payment page
- New `checkForValidationErrors()` — scans for red text / error messages after field filling

### Updated `BPointAutomationEngine`
- Rewritten `performBPointCheck` to use the biller pool rotation flow
- Loops through random billers until one succeeds past the form stage or pool is exhausted
- Integrates blacklisting callbacks for each failure type

### Updated `BPointPoolManagementView` (New View)
- Shows pool health stats (active/blacklisted/total)
- Lists blacklisted billers with reason and date
- Reset pool button with confirmation
- Accessible from the existing settings/more menu

---

## Design
- Pool management UI follows the existing settings section style — grouped lists with section headers
- Stats shown as a compact horizontal row (Active: X | Blacklisted: X | Total: X)
- Blacklisted billers list uses swipe-to-delete for individual restoration
- Reset button styled as a destructive action with confirmation alert
