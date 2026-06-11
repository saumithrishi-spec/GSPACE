# Runbook: Assess Only Selected Sites (e.g. 15 Sites)

> **Context:** `Run-FullAssessment.ps1` always processes **every** site discovered by GAM.  
> If you want to run the assessment for only a **subset** of sites (for example, the first 15 or a hand-picked list), follow this workaround.

---

## Prerequisites

- You have already run the full assessment **once** (or at least completed **Step 1: GAM Exports**).
- The file `output\02_GSites_Inventory_Detailed.csv` exists and contains all sites.
- Browser authentication (`.auth\state.json`) already exists from a prior run.

---

## Step 1 – Backup the full inventory

Open PowerShell in the script folder and run:

```powershell
Copy-Item output\02_GSites_Inventory_Detailed.csv output\02_GSites_Inventory_Detailed_full.csv
```

---

## Step 2 – Filter the inventory to your selected sites

### Option A: First 15 sites (simple limit)

```powershell
Get-Content output\02_GSites_Inventory_Detailed.csv | Select-Object -First 16 | Set-Content output\02_GSites_Inventory_Detailed.csv
```

> *Why 16?* Row 1 is the CSV header; rows 2–16 are the first 15 sites.

### Option B: Specific sites by name

```powershell
$sites      = Import-Csv output\02_GSites_Inventory_Detailed.csv
$selected   = $sites | Where-Object { $_.name -in @('Site Alpha','Site Beta','Portal','Narendra') }
$selected | Export-Csv output\02_GSites_Inventory_Detailed.csv -NoTypeInformation
```

> Replace the names inside `@('...')` with the exact **Site Name** values from the CSV.

---

## Step 3 – Re-crawl only the selected sites

```powershell
node 03_crawl_sites.js
```

What happens:
- The crawler reads `output\02_GSites_Inventory_Detailed.csv` and only visits the sites still listed there.
- Existing auth (`.auth\state.json`) is reused — no browser sign-in prompt.
- Outputs `07_Pages.csv`, `08_Embeds.csv`, `09_ExternalDomains.csv`, `10_NetworkRequests.csv` are **overwritten** with data for the selected sites only.

---

## Step 4 – Re-score only the selected sites

```powershell
.\05_score_sites.ps1 -PrimaryDomain rocheua.com -OutputDir output
```

What happens:
- Scoring reads the filtered inventory and the freshly-crawled files.
- `14_Complexity_Report.csv` is **overwritten** and now reflects only your selected sites.

---

## Step 5 – (Optional) Restore the full inventory

If you need the complete site list again later:

```powershell
Copy-Item output\02_GSites_Inventory_Detailed_full.csv output\02_GSites_Inventory_Detailed.csv
```

---

## Quick Reference: One-liner for 15 sites

```powershell
# 1. Backup & trim to 15 sites
Copy-Item output\02_GSites_Inventory_Detailed.csv output\02_GSites_Inventory_Detailed_full.csv
Get-Content output\02_GSites_Inventory_Detailed.csv | Select-Object -First 16 | Set-Content output\02_GSites_Inventory_Detailed.csv

# 2. Crawl & score
node 03_crawl_sites.js
.\05_score_sites.ps1 -PrimaryDomain rocheua.com -OutputDir output
```

---

## Important Notes

| Item | Detail |
|---|---|
| **GAM Export** | Do **not** re-run `01_run_gam_exports.cmd` — the CSVs in `output\` already contain the full domain data. |
| **Browser Auth** | Do **not** delete `.auth\state.json`. The crawl reuses the saved session automatically. |
| **Published URLs** | If you previously ran `03a_get_published_urls.js`, the file `02a_Sites_Published_URLs.csv` still contains **all** sites. That is fine — the crawler only uses the rows that match `SiteId`s present in the filtered inventory. |
| **Restore** | Always restore the full inventory (`02_GSites_Inventory_Detailed.csv`) before you hand the data off to migration teams so they have the complete domain view. |

---

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `node 03_crawl_sites.js` throws "Auth file not found" | Run `02_save_playwright_auth.js` first (or use the full orchestrator through Step 3). |
| `14_Complexity_Report.csv` still shows all sites | You forgot to trim `02_GSites_Inventory_Detailed.csv`; repeat Step 2. |
| `07_Pages.csv` is empty | The sites left in the filtered CSV may have **Edit URLs** instead of **Published URLs** and are returning 403. Obtain an OAuth token and run `node 03a_get_published_urls.js <token>` before crawling. |
