# Runbook: Get-ChatBots (1).ps1

## Overview

`Get-ChatBots (1).ps1` is a **Google Chat Bot Activity Audit** script. It pulls bot interaction data directly from the **Google Workspace Admin Reports API** (the same source as Admin Console → Reports → Chat), enriches each event with live Chat Space details, and outputs structured CSV reports covering every bot that was active in the domain over a configurable date range.

The script runs in **three sequential phases**:
1. Pull the raw Chat activity report from the Admin Reports API
2. Fetch all Chat Spaces and build a lookup table for name enrichment
3. Filter bot-related events, enrich them with Space context, and produce per-bot and per-space summaries

---

## Purpose & Business Context — Google Workspace to Microsoft 365 Migration

### Why This Script Exists in a Migration Project

When migrating from Google Workspace (GSuite) to Microsoft 365 (M365), **Google Chat bots are among the most overlooked and highest-risk items** in the entire migration. Unlike user mailboxes or Drive files — which have well-understood migration tooling — bots represent active, often business-critical automations that:

- Send notifications into Chat Spaces (e.g. CI/CD alerts, HR workflows, ticketing updates)
- Respond to user commands and queries inside Spaces
- Connect backend systems (e.g. Jira, PagerDuty, Salesforce) to the collaboration layer
- Perform scheduled or event-driven tasks on behalf of users

**None of these bots will function after migration.** The moment the Google Workspace tenant is deprovisioned or the domain is cut over to M365, every Google Chat bot loses its platform. There is no automatic migration path — each bot must be individually assessed, re-built or replaced, and re-connected to Microsoft Teams before or after cutover.

This script generates the **complete bot inventory and activity baseline** that the migration team needs to make those decisions.

---

### What Happens Without This Data

| Risk | Impact |
|---|---|
| Unknown bots not catalogued | Bot breaks silently at cutover; business process stops with no warning |
| Bot owner not identified | No one to contact about re-building in Teams; delays post-migration |
| Spaces not mapped to Teams | Bot re-build targeting the wrong channels in Teams |
| Activity level not assessed | Active bots treated same as abandoned ones; wasted re-build effort |
| GCP resource IDs not captured | No link back to the Google Cloud Project hosting the bot; re-build team has no starting point |

---

### Why We Extract Each Data Point — M365 Migration Value

#### 📋 Raw Chat Activity Report (`BOTS_RAW_ACTIVITY`)
**Why we extract it:** This is the unmodified output from the Google Admin Reports API — the ground truth of everything that happened in Google Chat over the selected date range. It captures bot additions, removals, and all message events.

**How it is used in migration:**
- Provides **evidence of actual bot usage** — not just what was configured, but what was genuinely active in the period
- Feeds the enrichment pipeline in Steps 2 and 3; all downstream reports derive from this file
- Retained as the **audit trail** for compliance and security sign-off during migration — answers the question "what was running in our Google Chat environment?"
- Used by the **migration project manager** to scope the bot remediation workstream and estimate effort

---

#### 🤖 Per-Bot Summary (`BOTS_PER_BOT`)
**Why we extract it:** Aggregates all activity for each unique bot into a single row, giving a complete profile of every bot in the domain.

**Key fields and their migration value:**

| Field | Why It Matters for M365 Migration |
|---|---|
| `AppName` | Human-readable bot name — the primary identifier for vendor conversations and Teams app store lookup |
| `AppId` / `GcpResourceId` | Google Cloud Project resource ID — links the bot back to its GCP project so the engineering team can find the source code, service account, and API credentials |
| `AddedOn` | When the bot was first introduced — bots added years ago and still active are deeply embedded; those added recently may be easier to replace |
| `AddedBy` | The admin or user who added the bot — this person is the **bot owner** and the first point of contact for the migration re-build conversation |
| `AddedToSpaces` | Which Space(s) the bot was originally installed into — maps directly to the Teams channels that need the replacement bot |
| `LastActivityDate` | Most recent event — bots with no activity in 90+ days may be abandoned and can be retired instead of rebuilt |
| `FirstSeen` | Earliest activity — combined with LastActivityDate, reveals the bot's operational history |
| `TotalEvents` | Volume of usage — high-event bots are business-critical and need early-wave remediation planning |
| `UniqueSpaces` | Number of distinct Spaces the bot is active in — bots in many spaces have broad reach and a higher migration impact |
| `ActiveInSpaces` | Names of all Spaces the bot is active in — used to build the Teams channel provisioning plan |
| `SpaceDetails` | Space type (GROUP_CHAT / SPACE) and member count — helps prioritise which spaces need Teams equivalents with matching membership |
| `EventTypes` | Types of events (app_added, app_removed, message events) — reveals whether the bot is read-only (notifications) or interactive (command-response), which determines the re-build complexity |

**How the per-bot summary drives migration decisions:**
- **Active bots with high TotalEvents** → Raise integration rebuild ticket immediately; assign to a developer
- **Bots last active > 90 days** → Mark as "candidate for retirement"; confirm with bot owner before decommissioning
- **Bots active in many Spaces** → Coordinate Teams channel provisioning before re-deploying the bot
- **Bot owner identified via AddedBy** → Send migration communication directly to that person

---

#### 🏠 Per-Space Summary (`BOTS_PER_SPACE`)
**Why we extract it:** Shows which Chat Spaces have bot activity, how many bots each Space uses, and what those bots are — from the Space's perspective rather than the bot's.

**Key fields and their migration value:**

| Field | Why It Matters for M365 Migration |
|---|---|
| `SpaceName` | Name of the Chat Space — maps to the Microsoft Teams team or channel that needs to be created |
| `SpaceID` | Google resource ID — cross-references against the full Spaces export for membership data |
| `SpaceType` | Whether the Space is a formal SPACE or GROUP_CHAT — determines if it maps to a Teams **channel** (formal space) or **group chat** |
| `MemberCount` | Number of human members — Spaces with many members + active bots need careful Teams provisioning and user communication |
| `TotalEvents` | How many bot events happened in this Space — measures how bot-dependent the Space is |
| `UniqueBots` | Number of distinct bots in this Space — spaces with many bots need more re-build effort |
| `BotNames` | List of all bots active in this Space — the complete re-build checklist for the Teams equivalent of this Space |

**How the per-space summary drives migration decisions:**
- Spaces with `UniqueBots > 3` are **bot-heavy workspaces** and need dedicated Teams channel setup and bot re-deployment planning
- `SpaceType = SPACE` with high `MemberCount` → Create a Teams **team** (not just a channel)
- `SpaceType = GROUP_CHAT` → Recreate as a Teams **group chat** or a private channel
- Used directly by the **Teams provisioning team** to ensure bot-dependent channels are created before cutover

---

#### 🔬 Enriched Full Detail (`BOTS_ENRICHED`)
**Why we extract it:** Contains every Chat event (not just bot events) enriched with Space name and type. Includes a `IsBotEvent` flag to distinguish bot events from regular user messages.

**How it is used in migration:**
- Provides the **complete activity picture** of each Space — the migration team can see how much of a Space's activity is bot-driven vs. human conversation
- Spaces where the majority of events are bot-driven (e.g. `#alerts` or `#monitoring` channels) may not need chat history migration at all — the history is bot-generated noise rather than human knowledge
- Used by the **data migration vendor** to scope whether a Space's chat history is worth migrating to Teams
- The `ActorEmail` field combined with `IsBotEvent=False` shows which human users are most active in bot-heavy Spaces — these users need priority Teams training and bot re-deployment communication

---

#### 🕐 Last Activity Per Bot (`BOTS_LAST_MODIFIED`)
**Why we extract it:** A focused view of when each bot was last seen active, when it was first added, and how many spaces it touches — the core triage data for migration planning.

**How it is used in migration:**
- The **primary input to the bot triage register** — the migration PM reviews this file to classify each bot as: Active (rebuild), Dormant (confirm before retire), or Abandoned (retire)
- `LastActivityDate` is the single most important field for prioritisation: bots active in the last 30 days must be in the migration plan; bots silent for 6+ months should be confirmed retired
- `AddedBy` provides the **owner contact** for every bot in a single export — used to bulk-generate the migration communication emails to bot owners

---

### Migration Decision Matrix

| Data Point | Migration Action |
|---|---|
| Bot with `TotalEvents > 100` in last 30 days | **Critical** — raise rebuild ticket; block cutover until Teams equivalent is confirmed live |
| Bot `LastActivityDate` > 90 days ago | Confirm with owner — likely candidate for retirement; do not rebuild unless confirmed needed |
| Bot `AddedBy` is a user (not admin) | User-installed bot — contact that user directly; they may need to self-service reconfigure in Teams |
| Bot `AddedBy` is admin | Admin-installed domain-wide bot — IT team owns the re-build |
| Space `UniqueBots > 3` | High-dependency Space — needs dedicated migration workstream and early Teams provisioning |
| Space `SpaceType = SPACE` with `MemberCount > 20` | Create full Microsoft Teams **team** with equivalent channels; do not use group chat |
| Space `SpaceType = GROUP_CHAT` | Recreate as Teams group chat or private channel |
| Bot event types include only `app_added` / `app_removed` | Bot was installed but may never have been actively used — confirm before rebuilding |
| Bot event types include message events | Bot is interactive (responds to users) — requires developer re-build, not just app reconfiguration |
| `GcpResourceId` present | Engineering team can find the GCP project and service account to start the Teams bot rebuild |
| `IsBotEvent = False` rows dominate a Space | Space has active human conversation — chat history migration may be worth the effort |
| `IsBotEvent = True` rows dominate a Space | Space is mostly bot-generated (alerts/notifications) — skip chat history migration |

---

## Prerequisites

### 1. PowerShell Version
- **Minimum:** PowerShell 5.1
- Verify: `$PSVersionTable.PSVersion`

### 2. GAM Installation
GAM7 / GAMADV-XTD3 is **required** for the `print chatspaces asadmin` command used in Step 2. Standard GAM does not support Chat Space admin enumeration.

| Tool | Download |
|---|---|
| GAM7 / GAMADV-XTD3 *(required)* | https://github.com/taers232c/GAMADV-XTD3 |

Verify GAM is working: `.\gam.exe version`

### 3. Required GAM API Scopes
Run `gam oauth update` and confirm these scopes are authorised:

| Scope | Required For |
|---|---|
| Admin SDK - Reports | `gam report chat` — the core Chat activity data (Step 1) |
| Google Chat API - Admin | `gam print chatspaces asadmin` — Space name enrichment (Step 2) |

Verify current scopes: `gam oauth info`

### 4. Google Workspace Edition
Chat activity reporting requires **Google Workspace Business Standard or higher** (or legacy G Suite Business/Enterprise). The Reports API Chat data is not available on free or Starter tiers.

### 5. Admin Account
The `$AdminEmail` in the script configuration must be a **Google Workspace Super Admin** account that has authorised GAM.

---

## Configuration

Before running, open `Get-ChatBots (1).ps1` in a text editor and update the following variables at the top of the script:

```powershell
# Line 21 — Update to your domain's Super Admin email
$AdminEmail = "admin-narendra@rocheua.com"

# Line 22 — Path to gam.exe (default: same folder as the script)
$GamPath = Join-Path $PSScriptRoot "gam.exe"

# Lines 28-29 — Date range for the activity report
$StartDate = "-30d"    # "-30d" = last 30 days (relative)
$EndDate   = "today"
```

### Date Range Options

| Format | Example | Use Case |
|---|---|---|
| Relative days | `-30d` | Last N days from today — best for routine audits |
| Relative days | `-90d` | Last 90 days — recommended for migration discovery |
| Absolute date | `2026-01-01` | Fixed start — use when you want a specific historical window |
| `today` | `today` | Always today's date |

> **Recommendation for migration:** Set `$StartDate = "-90d"` to capture a full quarter of bot activity. This gives a reliable picture of which bots are genuinely active vs. dormant.

---

## Step-by-Step Execution

### Step 1 — Open PowerShell and Navigate to the Script Folder

```powershell
cd "C:\Users\v-nmahanthi\OneDrive - Microsoft\Documents\gam7"
```

### Step 2 — Verify GAM and API Access

Run these checks before executing the script:

```powershell
# Confirm GAM version (must be GAM7 / GAMADV-XTD3)
.\gam.exe version

# Confirm OAuth scopes include Reports and Chat Admin
.\gam.exe oauth info

# Quick connectivity test — fetch a sample chat report (last 1 day)
.\gam.exe report chat start -1d end today | Select-Object -First 5

# Confirm Chat Spaces admin access
.\gam.exe user admin-narendra@rocheua.com print chatspaces asadmin | Select-Object -First 3
```

All commands must return data without `ERROR` or `403` messages.

### Step 3 — Update Configuration

Edit `Get-ChatBots (1).ps1`:
- Set `$AdminEmail` to your Super Admin account
- Set `$StartDate = "-90d"` for a full migration discovery run
- Confirm `$GamPath` points to the correct `gam.exe`

### Step 4 — Run the Script

```powershell
# Standard execution
.\Get-ChatBots` (1).ps1

# If execution policy blocks the script
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Get-ChatBots` (1).ps1
```

> **Note:** PowerShell requires backtick-escaping the space and parentheses in the filename when calling directly. Alternatively, rename the file to `Get-ChatBots.ps1` for simpler execution.

### Step 5 — Monitor Progress

The script prints live progress with three numbered phases:

```
[1/3] Pulling Chat Activity report from Admin Reports API...
      (covers bot invocations, messages, space events)
   Waiting for GAM output... Done.
   Total activity records pulled: 4821

[2/3] Fetching all Chat Spaces for name enrichment...
   Waiting for GAM output... Done.
   Spaces loaded: 47

[3/3] Processing bot-related events and enriching...
   Total events processed   : 4821
   Bot-related Events found : 312
```

### Step 6 — Review Console Output

After processing, the script prints a **BOT ACTIVITY DETAIL** table to the console — one block per bot showing name, added date, added by, last active date, active spaces, event count, and event types. Review this immediately after the run.

### Step 7 — Collect Output Files

All CSV files are written to the **same folder as the script** with a timestamp suffix. Collect these files:

```
BOTS_RAW_ACTIVITY_<timestamp>.csv
BOTS_ENRICHED_<timestamp>.csv
BOTS_PER_BOT_<timestamp>.csv
BOTS_PER_SPACE_<timestamp>.csv
BOTS_LAST_MODIFIED_<timestamp>.csv
```

---

## What the Script Does — Phase by Phase

### Phase 1 — Pull Chat Activity Report (GAM Reports API)

**GAM Command executed:**
```
gam redirect csv raw_chat_report.csv report chat start <StartDate> end <EndDate>
```

This calls the **Google Admin SDK Reports API** — the same data source shown in Admin Console → Reports → Chat. It returns every Chat event in the domain for the specified date range, including:

| Event Type | Description |
|---|---|
| `app_added` | A bot was added to a Space by a user or admin |
| `app_removed` | A bot was removed from a Space |
| `message_posted` | A message was posted (by a user or bot) |
| Other events | Space creation, membership changes, etc. |

After pulling the data, the script performs **auto-detection of GAM column names**. Because GAM column names vary between versions (e.g. `app_name` vs `appname` vs `app.name`), the script scans the actual column headers returned and maps them dynamically. This makes the script resilient across GAM7 and older GAM versions.

The raw report is saved immediately as `BOTS_RAW_ACTIVITY_<timestamp>.csv` before any filtering, so the complete audit trail is always preserved.

---

### Phase 2 — Fetch Chat Spaces for Enrichment

**GAM Command executed:**
```
gam user <AdminEmail> print chatspaces asadmin fields name,displayname,spacetype,membershipcount
```

This fetches **every Chat Space in the domain** including:
- `name` — the Space's internal resource ID (used for cross-referencing with activity data)
- `displayName` — the human-readable Space name
- `spaceType` — `SPACE` (formal team space) or `GROUP_CHAT`
- `membershipCount.joinedDirectHumanUserCount` — number of active human members

Two lookup tables are built in memory:
- **SpaceID → details** (for exact ID matching)
- **SpaceName → SpaceID** (fallback for name-based matching when ID is unavailable)

The raw spaces file is deleted after the lookups are built (it is not needed in the final output).

---

### Phase 3 — Filter, Enrich, and Summarise

The script iterates every row in the raw Chat report and for each row:

1. **Extracts** event metadata: event name, time, actor email, actor type, IP address
2. **Extracts** Space context: Space ID, Space name, conversation type, message ID
3. **Identifies** bot identity: checks if `resourceDetails.1.type = APPLICATION` — if so, the bot's name (`resourceDetails.1.title`) and GCP resource ID (`resourceDetails.1.id`) are captured
4. **Classifies** the event: marks as `IsBotEvent = True` if the event name contains "app" or "bot", or if `resourceDetails.1.type = APPLICATION`
5. **Enriches** with Space details from the lookup tables built in Phase 2
6. **Adds** to two parallel lists: `$botEvents` (bot-only) and `$enriched` (all events)

After iteration, two aggregations are computed:

**Per-Bot Summary** — groups `$botEvents` by `AppId`, computing:
- When the bot was first added and by whom
- All spaces it was added to and is currently active in
- Last activity date and total event count
- All distinct event types it has generated

**Per-Space Summary** — groups `$botEvents` by `SpaceName`, computing:
- How many total bot events occurred in the Space
- How many unique bots are active in the Space
- The names of all bots in the Space

---

## Output Files

All files are saved in the script's working directory with a `yyyyMMdd_HHmmss` timestamp suffix.

| File | Contents | Primary Use |
|---|---|---|
| `BOTS_RAW_ACTIVITY_<ts>.csv` | Complete unfiltered Chat activity report from GAM (all event types, all actors) | Audit trail; source of truth; input to security review |
| `BOTS_ENRICHED_<ts>.csv` | All events enriched with Space name/type and `IsBotEvent` flag | Full event picture; used to assess human vs. bot activity ratio per Space |
| `BOTS_PER_BOT_<ts>.csv` | One row per unique bot: name, GCP ID, added by/when, last active, spaces, event count, event types | **Primary migration planning file** — bot owner contact, rebuild prioritisation |
| `BOTS_PER_SPACE_<ts>.csv` | One row per Space: name, type, member count, bot count, bot names | Teams provisioning planning; identifies bot-heavy Spaces |
| `BOTS_LAST_MODIFIED_<ts>.csv` | Focused last-activity view per bot: name, GCP ID, added info, last seen, first seen, spaces | **Bot triage register** — classify each bot as Active / Dormant / Abandoned |

---

## Reading the Output

### BOTS_PER_BOT — Migration Triage Guide

Open `BOTS_PER_BOT_<ts>.csv` and apply this classification:

| Condition | Classification | Migration Action |
|---|---|---|
| `LastActivityDate` within last 30 days AND `TotalEvents > 50` | 🔴 **Critical / Active** | Raise rebuild ticket immediately; block cutover until Teams bot is live |
| `LastActivityDate` within last 30–90 days | 🟡 **Moderate / Active** | Add to rebuild backlog; contact bot owner |
| `LastActivityDate` older than 90 days | ⚪ **Dormant** | Contact `AddedBy` owner to confirm — likely retirement candidate |
| `LastActivityDate` older than 180 days or blank | 🟢 **Abandoned** | Recommend retirement; remove from rebuild plan |

### BOTS_PER_SPACE — Teams Channel Planning Guide

Open `BOTS_PER_SPACE_<ts>.csv` and for each Space:
- Match `SpaceName` to the corresponding Teams team/channel being created
- Use `BotNames` as the checklist of bots to re-deploy into that Teams channel
- Prioritise Spaces with the highest `TotalEvents` for early Teams provisioning

### BOTS_ENRICHED — Activity Ratio Analysis

In `BOTS_ENRICHED_<ts>.csv`, filter by `SpaceName` and calculate:
```
Bot event % = (rows where IsBotEvent=True) / (total rows for that Space) × 100
```
- **> 80% bot events** → Space is a notification/alert channel. Chat history migration is low value — skip.
- **< 40% bot events** → Space has meaningful human conversation. Migrate chat history to Teams.

---

## Troubleshooting

### No Chat Activity Data Returned
```
ERROR: No chat activity data returned.
       Check that Reports API is enabled for your domain.
```
**Causes and fixes:**

1. **Reports API not authorised:**
   ```powershell
   .\gam.exe oauth update
   # Enable: Admin SDK - Reports
   ```

2. **Date range has no data** — the Admin Reports API has a data lag of up to 48 hours:
   ```powershell
   # Change StartDate in the script to -7d and retry
   $StartDate = "-7d"
   ```

3. **Wrong GAM path** — verify:
   ```powershell
   Test-Path "C:\Users\v-nmahanthi\OneDrive - Microsoft\Documents\gam7\gam.exe"
   ```

---

### Chat Spaces Step Fails or Returns Zero Spaces
```
Spaces loaded: 0
```
**Causes and fixes:**

1. **GAM version is not GAM7/GAMADV-XTD3:**
   ```powershell
   .\gam.exe version   # Must show GAM7 or GAMADV
   ```

2. **Chat Admin scope not authorised:**
   ```powershell
   .\gam.exe oauth update
   # Enable: Google Chat API - Admin
   ```

3. **Admin account does not have Chat Admin privileges:**
   Verify at Admin Console → Apps → Google Workspace → Google Chat → Settings

---

### Zero Bot Events Found
```
Bot-Related Events found : 0
```
**Causes and fixes:**

1. **No bots were active in the selected date range** — extend the window:
   ```powershell
   $StartDate = "-90d"
   ```

2. **Column name mismatch** — open `BOTS_RAW_ACTIVITY_<ts>.csv` and check the actual column names. The auto-detection uses regex patterns; if GAM returns an unexpected column name, the bot fields will be empty. Look for any column containing "app", "bot", or "resource" in its name.

3. **Domain has no Chat bots deployed** — if the organisation genuinely has no bots, `TotalEvents = 0` is correct. The raw report will still show human chat events.

---

### Script Blocked by PowerShell Execution Policy
```
File cannot be loaded because running scripts is disabled on this system.
```
**Fix:**
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```
> Note: The script includes a self-unblock routine that removes the Windows Zone Identifier (internet download tag) automatically on first run — but the execution policy must still be set.

---

### Timeout Waiting for GAM Output
```
ERROR: Timed out after 180 seconds.
```
**Causes and fixes:**
- Large domain with many users and many Chat events can take longer than 3 minutes
- The `Wait-ForFile` helper has a default timeout of 180 seconds
- For large domains, temporarily increase the timeout in the function: `Wait-ForFile $RawChatReportCSV 300`

---

### File Name with Space and Parentheses Causes Run Error
**Fix:** Either escape the filename in PowerShell:
```powershell
& ".\Get-ChatBots (1).ps1"
```
Or rename the file before running:
```powershell
Rename-Item ".\Get-ChatBots (1).ps1" ".\Get-ChatBots.ps1"
.\Get-ChatBots.ps1
```

---

## Security Review Checklist

After running the script, complete this checklist as part of the migration security review:

- [ ] **Every bot in `BOTS_PER_BOT` has an identified owner** (`AddedBy` field) — if `AddedBy` is blank or an ex-employee, escalate to IT Security
- [ ] **Bots with broad Google API scopes** — cross-reference `AppId` / `GcpResourceId` against the Connected Apps OAuth report to check what data the bot can access
- [ ] **Bots added by non-admin users** — users can add bots to their personal Spaces; ensure IT is aware of all user-installed bots, not just admin-installed ones
- [ ] **Dormant bots (no activity 90+ days)** — confirm with owner then remove from Google Workspace before cutover; do not let unused bots linger with active API access
- [ ] **Bot GCP service accounts** — each `GcpResourceId` maps to a GCP service account; review these in Google Cloud Console to confirm they are scoped appropriately and have no excess permissions
- [ ] **Bots in Spaces with sensitive data** — if a Space contains HR, Legal, or Finance conversations, any bot in that Space has read access to those messages; document and review before migration

---

## Example Command Reference

```powershell
# Navigate to script folder
cd "C:\Users\v-nmahanthi\OneDrive - Microsoft\Documents\gam7"

# Run with default settings (last 30 days)
& ".\Get-ChatBots (1).ps1"

# Run after renaming (simpler)
Rename-Item ".\Get-ChatBots (1).ps1" ".\Get-ChatBots.ps1"
.\Get-ChatBots.ps1

# Bypass execution policy if needed
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
& ".\Get-ChatBots (1).ps1"

# Verify GAM before running
.\gam.exe version
.\gam.exe oauth info
.\gam.exe report chat start -1d end today | Select-Object -First 3
```
