# Runbook: Get-ConnectedAppsReport.ps1

## Overview

`Get-ConnectedAppsReport.ps1` generates a comprehensive **HTML + CSV audit report** for a Google Workspace (GSuite) domain. It covers OAuth-connected third-party apps, Marketplace apps, service accounts with Domain-Wide Delegation (DwD), admin role assignments, and optionally user activity and Chat Spaces — all powered by **GAM / GAMADV-XTD3 / GAM7**.

---

## Purpose & Business Context — Google Workspace to Microsoft 365 Migration

This report is a **pre-migration discovery tool**. Before any tenant cutover from Google Workspace (GSuite) to Microsoft 365 (M365), the migration team must understand exactly what exists in the source environment — who the users are, what apps they rely on, what integrations are in place, and what security risks need to be addressed. Running this script produces all of that inventory in a single pass.

Without this data, migrations commonly hit these failures:
- Business-critical third-party apps stop working because their Google OAuth connections are never replaced with M365 equivalents
- Automations backed by Google service accounts break silently because no one knew they existed
- Users in restricted org units are migrated in the wrong wave or with wrong licensing
- Suspended accounts are migrated unnecessarily, wasting licenses and creating security gaps

---

### Why Each Section Matters for M365 Migration

#### 👥 Section 1 — Domain Users
**Why we extract it:** Produces the complete user inventory that drives every other migration decision.

**How it is used:**
- Determines the **total scope and cost** of the migration (M365 license count)
- Identifies **suspended accounts** — these should be excluded from migration or migrated with no license to avoid unnecessary spend
- `lastLoginTime` drives **wave planning** — inactive users (e.g. no login in 90+ days) are typically migrated last or not at all
- `orgUnitPath` maps to **M365 department/OU structure** and determines which security groups and policies to apply post-migration
- Provides the **source list** for all subsequent GAM commands in this script

---

#### 🔑 Section 2 — OAuth Tokens (Third-Party Connected Apps)
**Why we extract it:** Every app a user has connected to Google Workspace via OAuth will **lose access the moment the Google account is deprovisioned or the domain is cut over**. These connections must be re-established against M365/Azure AD before cutover.

**How it is used:**
- Builds the **application inventory** — the full list of third-party tools (e.g. Slack, Zoom, Salesforce, DocuSign, project tools) connected to the Google tenant
- `scopes` column reveals **what data each app can access** (email, calendar, drive, contacts) — critical for data governance and compliance sign-off before migration
- `CreatedDate` (from the audit log) shows how long an app has been authorised — apps with very old tokens may belong to ex-employees and should be revoked before migration
- **Suspended users with active tokens** are a direct security risk and must be cleaned up before cutover — an ex-employee's connected app can still pull data via an active token even after the account is suspended
- Informs which apps need **re-consent flows or admin pre-authorisation** in the M365/Azure AD tenant post-migration
- Identifies apps that are **Google-specific** (e.g. Google Drive integrations) and need a replacement workflow in M365 (e.g. SharePoint/OneDrive integrations)

---

#### 🏪 Section 3 — Marketplace Apps
**Why we extract it:** Marketplace apps are admin-approved and often domain-wide. They represent sanctioned tooling that the organisation has formally adopted — not just individual user choices.

**How it is used:**
- Creates the **official approved-app register** for the migration project — every app here needs a decision: retain (re-connect to M365), replace (find an M365 equivalent), or retire
- Helps the **licensing team** identify overlapping SaaS tools that may already have M365-native replacements (e.g. a Google Drive file-management app replaced by SharePoint features already included in M365)
- Apps installed domain-wide need **IT-led re-authorisation** against the new M365 tenant, not just user self-service consent
- Supports the **vendor communication plan** — the migration team can proactively contact each vendor to update OAuth credentials before the cutover date

---

#### 🔐 Section 4 — Service Accounts with Domain-Wide Delegation (DwD)
**Why we extract it:** DwD service accounts are the most migration-critical and highest-risk items in the entire Google Workspace environment. Each one can impersonate **any user in the domain** and is typically used by backend automation, ETL pipelines, HR integrations, and custom apps.

**How it is used:**
- Every DwD service account represents an **integration that will break at cutover** unless rebuilt — these must all be individually assessed and re-engineered against Azure AD service principals or managed identities
- The `Scopes` column shows what each service account can do (e.g. read all Gmail, access all Drive files) — this informs the **risk register** and needs security team sign-off
- Provides the input list for the **integration re-build workstream**, which is typically one of the longest lead-time items in a GSuite-to-M365 migration
- Must be reviewed by application owners to confirm which are still active and which are legacy/orphaned before migration begins

---

#### 👑 Section 5 — Admin Roles & Delegated Admins
**Why we extract it:** The admin structure in Google Workspace must be mapped and recreated in M365/Azure AD before the source tenant is decommissioned.

**How it is used:**
- Maps current **Google admin roles** to their equivalent **M365 roles** (e.g. Google Super Admin → M365 Global Administrator, Groups Admin → Groups Administrator)
- Identifies **delegated admins** who may be external partners or vendors — these need separate access decisions in the M365 tenant
- Ensures **no admin access is lost** during cutover, which would leave the tenant unmanageable
- Informs the **M365 RBAC (Role-Based Access Control) design** — a key deliverable of the migration project
- Helps identify admins who should be migrated in an **early wave** so they can assist with post-cutover support

---

#### ⏱️ Section 6 — Last Activity *(optional: `-IncludeLastActivity`)*
**Why we extract it:** Drive last-active timestamps provide a more granular view of user activity than last login alone — a user could log in but not actively use Drive/Google Workspace features.

**How it is used:**
- Refines the **inactive user list** for migration wave planning — users with no Drive activity in 6+ months are strong candidates for a late wave or license downgrade
- Supports **data migration scoping** — users with recent Drive activity have data that must be migrated to OneDrive/SharePoint; truly inactive users may not
- Feeds into the **license optimisation** analysis — if a user is inactive on Drive, they may only need a basic M365 license rather than a full E3/E5
- Provides evidence for the **data migration vendor** on per-user data volume and activity, used to estimate migration time and cost

---

#### 💬 Section 7 — Google Chat Spaces *(optional: `-IncludeChatSpaces`)*
**Why we extract it:** Google Chat Spaces represent team collaboration structures that need to be recreated in Microsoft Teams.

**How it is used:**
- Provides the **Teams migration inventory** — each Chat Space maps to a potential Microsoft Teams channel or team
- Member lists show which users need to be in the same Teams after migration, informing the **Teams provisioning plan**
- Space names and membership sizes help the migration team decide whether to **auto-provision Teams** or ask business owners to recreate their own collaboration spaces
- Identifies large or active Spaces that need special handling (e.g. retaining chat history via a third-party migration tool such as Mover or AvePoint)
- Informs the **communication plan** — users of active Chat Spaces need targeted training on Microsoft Teams before cutover

---

### Migration Decision Matrix — Using the Report Data

| Report Data | Migration Decision |
|---|---|
| Suspended users | Exclude from migration or migrate with no license |
| Users with no login in 90+ days | Assign to final wave; review license type |
| OAuth apps used by 1–2 users only | Notify those users to reconnect manually post-cutover |
| OAuth apps used by 50+ users | IT-led re-authorisation; add to cutover checklist |
| Apps with `mail` or `drive` scopes | Require compliance review before migration |
| DwD service accounts | Raise integration rebuild tickets immediately |
| Marketplace apps | Vendor communication + M365 equivalent assessment |
| Admin roles | M365 RBAC design + early-wave migration |
| Chat Spaces with 20+ members | Teams auto-provisioning + history migration |
| Drive inactive users | OneDrive migration optional; downgrade license tier |

---

## Prerequisites

### 1. PowerShell Version
- **Minimum:** PowerShell 5.1 (Windows PowerShell)
- Verify: `$PSVersionTable.PSVersion`

### 2. GAM Installation
One of the following must be installed and authorised:

| Tool | Download |
|---|---|
| GAM7 / GAMADV-XTD3 *(recommended)* | https://github.com/taers232c/GAMADV-XTD3 |
| Standard GAM | https://github.com/jay0lee/GAM |

GAM is auto-detected from these locations (in order):
1. Path passed via `-GamPath` parameter
2. `.\gam.exe` (current directory — most common)
3. Same folder as the script
4. `%USERPROFILE%\AppData\Local\GAM7\gam.exe`
5. `C:\GAM7\gam.exe`, `C:\GAMADV-XTD3\gam.exe`, `C:\GAM6\gam.exe`, `C:\GAM\gam.exe`
6. `gam` on system PATH

### 3. GAM Authorisation & Required API Scopes
Run `gam oauth create` (first time) or `gam oauth update` to ensure these scopes are granted:

| Scope | Required For |
|---|---|
| Admin SDK - Directory (read) | Users, Admins |
| Admin SDK - Reports | OAuth tokens, audit log |
| Admin SDK - Other | Domain-wide delegation |
| Cloud Identity - Policies | Marketplace app policies |
| Chrome Management API - AppDetails read only | Marketplace app details |
| Google Chat API - Admin *(GAM7/GAMADV only)* | Chat Spaces (`-IncludeChatSpaces`) |

Verify current scopes: `gam oauth info`

---

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-GamPath` | String | *(auto-detect)* | Full path to `gam.exe`. Use if GAM is not auto-found. |
| `-OutputDir` | String | `.\ConnectedAppsReport_<timestamp>` | Folder where all output files are saved. |
| `-IncludeLastActivity` | Switch | Off | Fetches per-user Drive last-active and last-login timestamps via the Reports API. Adds runtime on large domains. |
| `-IncludeChatSpaces` | Switch | Off | Collects Google Chat Spaces + memberships. Requires GAM7/GAMADV-XTD3. |
| `-MaxUsers` | Int | `0` *(all)* | Cap the number of users processed. Use for test runs (e.g. `30`). |
| `-DwdTimeoutSeconds` | Int | `60` | Per-strategy timeout in seconds for Domain-Wide Delegation GAM commands. Increase on slow networks. |

---

## Step-by-Step Execution

### Step 1 — Open PowerShell

Open PowerShell **as Administrator** and navigate to the folder containing the script and `gam.exe`:

```powershell
cd "C:\Users\v-nmahanthi\OneDrive - Microsoft\Documents\gam7"
```

### Step 2 — Verify GAM is Working

Before running the report, confirm GAM is authorised and connected:

```powershell
.\gam.exe version
.\gam.exe oauth info
.\gam.exe print users fields primaryEmail | Select-Object -First 3
```

All three commands must succeed without errors.

### Step 3 — Choose Your Run Mode

#### Basic Run (recommended first run)
```powershell
.\Get-ConnectedAppsReport.ps1
```

#### Test Run (first 30 users only — safe for validation)
```powershell
.\Get-ConnectedAppsReport.ps1 -MaxUsers 30
```

#### Full Run (all optional sections)
```powershell
.\Get-ConnectedAppsReport.ps1 -IncludeLastActivity -IncludeChatSpaces
```

#### Custom GAM Path + Custom Output Folder
```powershell
.\Get-ConnectedAppsReport.ps1 -GamPath "C:\GAM7\gam.exe" -OutputDir "C:\Reports\MyAudit"
```

#### Slow Network (increase DwD timeout)
```powershell
.\Get-ConnectedAppsReport.ps1 -DwdTimeoutSeconds 120
```

---

## What the Script Does — Section by Section

### Section 0 — Locate GAM
- Searches known paths for `gam.exe`
- Detects GAM version (standard vs GAM7/GAMADV-XTD3)
- Disables `-IncludeChatSpaces` automatically if standard GAM is detected
- **Exits immediately** if GAM is not found

### Section 1 — Domain Users
- **GAM Command:** `gam print users fields primaryEmail,name,lastLoginTime,suspended,orgUnitPath`
- Exports all users to `users.csv`
- Applies `MaxUsers` cap if set
- **Exits immediately** if no users are returned (authorisation failure)

### Section 2 — OAuth Tokens (Third-Party Connected Apps)
- **GAM Command:** `gam redirect csv ... multiprocess csv users.csv gam user ~primaryEmail print tokens`
- Fetches all OAuth tokens for every user in parallel → `tokens_all_users.csv`
- Fetches the token authorization audit log (last 365 days) → `token_audit.csv`
- Aggregates tokens by app name → `apps_aggregated.csv`
- Auto-detects column names (`user`/`userEmail`, `displayText`/`appName`) across GAM versions

### Section 3 — Marketplace Apps *(4-strategy fallback)*
Tries the following in order until one succeeds:

| Strategy | GAM Command | Notes |
|---|---|---|
| A | `gam print appdetails type CHROME_EXTENSION` | Best on GAM7/GAMADV; also tries ANDROID, WEB, GOOGLE_WORKSPACE_APP |
| B | `gam print policies type app_access_settings` | Cloud Identity Policies API |
| C | `gam print policies` *(all, then filtered)* | Filters for marketplace/app-related rows |
| D | Built from OAuth token data | Best-effort fallback; not the same as Admin Console list |

Output → `marketplace_apps.csv`

### Section 4 — Service Accounts (Domain-Wide Delegation) *(4-strategy fallback)*
Each strategy has a configurable timeout (`-DwdTimeoutSeconds`):

| Strategy | GAM Command | Notes |
|---|---|---|
| A | `gam print domainwidedelegation` | Preferred on GAM7/GAMADV |
| B | `gam print svcaccts` | Older GAM versions |
| C | `gam show domainwidedelegation` | Parses text output into CSV |
| D | `gam info domain` | Extracts any DwD mentions as partial data |

Output → `service_accounts_dwd.csv`  
⚠️ **Security note:** Each DwD service account can impersonate **any user** in the domain.

### Section 5 — Admin Roles & Delegated Admins
- **GAM Command:** `gam print admins`
- Output → `admins.csv`

### Section 6 — Last Activity *(optional, `-IncludeLastActivity`)*
- **GAM Command:** `gam report user ... parameters drive:timestamp_last_active_usage,accounts:last_login_time`
- Output → `last_activity.csv`
- ⚠️ Reports API data can take up to **48 hours** to populate for recent activity

### Section 7 — Google Chat Spaces *(optional, `-IncludeChatSpaces`)*
- **GAM Commands:** `gam print chatspaces asadmin` then `gam print chatmembers ~name asadmin`
- Output → `chat_spaces.csv`, `chat_members.csv`
- Requires GAM7/GAMADV-XTD3 and Chat Admin API scope

### Section 8 — HTML Report Generation
- Builds an interactive HTML report with tabbed views, summary cards, and colour-coded alerts
- Output → `ConnectedApps_Report.html`

---

## Output Files

All files are saved in the output folder (`.\ConnectedAppsReport_<timestamp>\` by default).

| File | Description |
|---|---|
| `ConnectedApps_Report.html` | **Main interactive HTML report** — open in any browser |
| `users.csv` | All domain users: email, name, last login, suspended status, org unit |
| `tokens_all_users.csv` | Raw OAuth token records (one row per user per app) |
| `token_audit.csv` | Token authorization audit log (last 365 days) |
| `apps_aggregated.csv` | Apps aggregated by name with user count and scopes |
| `app_detail_summary.csv` | Per-app detail: org unit, first-auth date, last login, last activity, member list |
| `marketplace_apps.csv` | Marketplace / Cloud Identity app policies |
| `service_accounts_dwd.csv` | GCP service accounts with Domain-Wide Delegation |
| `admins.csv` | Admin role assignments |
| `last_activity.csv` | Drive last-active + login timestamps *(only with `-IncludeLastActivity`)* |
| `chat_spaces.csv` | Google Chat Spaces *(only with `-IncludeChatSpaces`)* |
| `chat_members.csv` | Chat Space memberships *(only with `-IncludeChatSpaces`)* |

---

## Reading the HTML Report

Open `ConnectedApps_Report.html` in any browser. The report contains:

| Section | What to Look For |
|---|---|
| **Summary Cards** | Quick counts: total users, OAuth apps, tokens, marketplace rows, DwD accounts, Chat Spaces |
| **Connected Apps Detail** | One row per app — Members, Org Unit, First Auth Date, Last Login, Scopes |
| **Detailed Token Data** | Tabs: *Per User* (ranked by app count), *All Raw Tokens*, *Suspended w/ Tokens* ⚠️ |
| **Marketplace Apps** | Apps installed/approved via Admin Console |
| **Service Accounts (DwD)** | 🔴 High-risk — review every entry |
| **Admin Roles** | All admin role assignments including delegated admins |
| **Last Activity** | Drive timestamps *(requires `-IncludeLastActivity`)* |
| **Chat Spaces** | Spaces and memberships *(requires `-IncludeChatSpaces`)* |
| **All Domain Users** | Full user list with status |
| **Output Files** | Record count for every generated file |

---

## Troubleshooting

### GAM Not Found
```
[FAIL] GAM not found.
```
**Fix:** Run from the GAM folder, or pass `-GamPath "C:\GAM7\gam.exe"`.

---

### No Users Retrieved
```
[FAIL] Could not retrieve users. Verify GAM authorisation: gam oauth info
```
**Fix:**
```powershell
.\gam.exe oauth info
.\gam.exe oauth update   # re-authorize if needed
```

---

### Marketplace Section is Empty
**Fix:** Run `gam oauth update` and enable:
- `Chrome Management API - AppDetails read only`
- `Cloud Identity - Policies`

Then re-run the script.

---

### DwD Service Accounts — All 4 Methods Failed
**Fix:** Run `gam oauth update` and enable:
- `Admin SDK - Other`
- `Cloud Identity - Policies`

Verify manually: **Admin Console → Security → API Controls → Domain-wide Delegation**

---

### Token Audit Log — `CreatedDate` Shows N/A
The audit log requires `Admin SDK - Reports` scope and may need up to 48 hours.  
**Fix:** `gam oauth update` → confirm Reports API scope is enabled.

---

### DwD Commands Timing Out
**Fix:** Increase the timeout:
```powershell
.\Get-ConnectedAppsReport.ps1 -DwdTimeoutSeconds 180
```

---

### Chat Spaces Not Collected
**Fix:** Ensure GAM7/GAMADV-XTD3 is installed, then:
```powershell
.\gam.exe oauth update   # enable Google Chat API - Admin scope
.\Get-ConnectedAppsReport.ps1 -IncludeChatSpaces
```

---

## Security Review Checklist

After running the report, review the following in the HTML report:

- [ ] **Suspended users with active OAuth tokens** — revoke with `gam user <email> delete tokens`
- [ ] **Domain-Wide Delegation service accounts** — verify each is still needed; remove unused ones via Admin Console → Security → API Controls → Domain-wide Delegation
- [ ] **Admin role assignments** — confirm no unexpected super-admin or delegated admin accounts
- [ ] **Apps with broad scopes** — check `Scopes` column in Connected Apps Detail for `https://www.googleapis.com/auth/...` entries
- [ ] **Apps authorized by large numbers of users** — high `Members` count warrants review

---

## Example Full Command Reference

```powershell
# Basic
.\Get-ConnectedAppsReport.ps1

# Test mode (30 users)
.\Get-ConnectedAppsReport.ps1 -MaxUsers 30

# Full audit with activity + Chat
.\Get-ConnectedAppsReport.ps1 -IncludeLastActivity -IncludeChatSpaces

# Custom GAM path + output folder
.\Get-ConnectedAppsReport.ps1 -GamPath "C:\GAM7\gam.exe" -OutputDir "C:\Audit\$(Get-Date -f 'yyyyMMdd')"

# Slow network
.\Get-ConnectedAppsReport.ps1 -DwdTimeoutSeconds 180

# Everything
.\Get-ConnectedAppsReport.ps1 -IncludeLastActivity -IncludeChatSpaces -DwdTimeoutSeconds 120 -OutputDir "C:\Reports\FullAudit"
```
