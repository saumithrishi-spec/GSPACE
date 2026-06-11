# Complete Runbook: Google Sites Non-Prod Assessment

End-to-end guide for running the `gsites-assessment-toolkit` from first setup through final scoring.

---

## 1. Prerequisites

| Tool | Minimum Version | Purpose | Verify Command |
|---|---|---|---|
| **Windows** | 10 / 11 / Server 2019 | Host OS | `winver` |
| **PowerShell** | 5.1 or 7.x | Orchestrator script | `powershell -Command "$PSVersionTable.PSVersion"` |
| **Node.js** | 18.x+ | Crawler & auth scripts | `node --version` |
| **npm** | 9.x+ | Dependency manager | `npm --version` |
| **GAM** | 7.x+ | Google Workspace exports | `gam --version` |
| **gcloud CLI** | Latest (optional) | OAuth token for enrichment | `gcloud --version` |

> **Google Workspace:** You need **Super Admin** or an admin service-account scoped for Drive / Sites APIs so GAM can enumerate user files.

---

## 2. First-Time Setup

### A. Place the toolkit

Extract the folder so the scripts sit together:

```
gsites-assessment-toolkit/
  01_run_gam_exports.cmd
  02_save_playwright_auth.js
  03_crawl_sites.js
  03a_get_published_urls.js
  04_enrich_artifacts.ps1
  05_score_sites.ps1
  Run-FullAssessment.ps1
  package.json
```

Open PowerShell and `cd` into that folder.

### B. Tell the scripts where GAM lives

Create a file named `gam.cfg` in the same folder with one line:

```ini
GAM_PATH=C:\tools\gam7\gam.exe
```

> Replace the path with the actual location of `gam.exe` on the machine.  
> The batch file `01_run_gam_exports.cmd` reads this file automatically.

### C. Install Node dependencies

```powershell
npm install
npx playwright install chromium
```

You only need to do this **once** per machine.

---

## 3. Run the Full Assessment

### Single command

```powershell
.\Run-FullAssessment.ps1 -PrimaryDomain "rocheua.com"
```

> Replace `rocheua.com` with your actual primary Google Workspace domain.

### What happens (six steps)

| Step | Script | Duration | Interactive? | What it does |
|---|---|---|---|---|
| **1** | `01_run_gam_exports.cmd` | 5–30 min | No | Exports Sites inventory, permissions, Sheets, Forms, Scripts CSVs into `output\` |
| **2** | `npm install` | 1–2 min | No | Verifies Node dependencies and Playwright browser |
| **3** | `02_save_playwright_auth.js` | 1–3 min | **Yes** | Opens Chromium; you sign in with a Google account that can access the target sites, then press **Enter** in the terminal to save `.auth\state.json` |
| **4A** | `03a_get_published_urls.js` | 1–2 min | No | *(Requires gcloud)* Calls Google Sites API to map edit URLs → published URLs |
| **4B** | `03_crawl_sites.js` | 2–20 min | No | Playwright crawls every site listed in the inventory, up to **200 pages per site** |
| **5** | `04_enrich_artifacts.ps1` | 1–5 min | No | *(Requires gcloud/OAuth)* Fetches metadata for Sheets, Forms, Scripts via Google APIs |
| **6** | `05_score_sites.ps1` | < 1 min | No | Generates `14_Complexity_Report.csv` (Low / Medium / High / Very High ratings) |

**Total wall-clock time:** ~10 min – 1 hour depending on domain size.

---

## 4. Interactive Step Details (Browser Auth)

When the orchestrator reaches Step 3:

1. A **Chromium browser window** pops up.
2. Navigate to `https://sites.google.com/` and **sign in** with the non-prod / test Google account.
3. Open one of the target sites to verify you have access.
4. Return to the PowerShell window and **press Enter**.
5. The script saves the session to `.auth\state.json` and continues automatically.

> If the auth file already exists, the script asks whether to reuse it or re-authenticate.

---

## 5. Output Files

All files land in the `output\` folder.

| # | File | Contents |
|---|---|---|
| 1 | `01_GSites_Inventory_Min.csv` | Site ID, name, MIME type (minimal list) |
| 2 | `02_GSites_Inventory_Detailed.csv` | Full inventory with owners, dates, links, parents |
| 2a| `02a_Sites_Published_URLs.csv` | Edit URL → Published URL mapping *(if gcloud available)* |
| 3 | `03_GSites_Permissions.csv` | Permission rows per site (who has access) |
| 4 | `04_Candidate_Sheets.csv` | Google Sheets files found in the domain |
| 5 | `05_Candidate_Forms.csv` | Google Forms files found in the domain |
| 6 | `06_Candidate_Scripts.csv` | Apps Script projects found in the domain |
| 7 | `07_Pages.csv` | Every page crawled per site (title, depth, status) |
| 8 | `08_Embeds.csv` | Discovered embeds: Sheets, Forms, YouTube, Maps, etc. |
| 9 | `09_ExternalDomains.csv` | External domains referenced inside sites |
| 10| `10_NetworkRequests.csv` | All network calls captured during crawling |
| 11| `11_Sheets_Enrichment.csv` | Sheet metadata *(if gcloud available)* |
| 12| `12_Forms_Enrichment.csv` | Form metadata *(if gcloud available)* |
| 13| `13_Scripts_Enrichment.csv` | Script metadata *(if gcloud available)* |
| 14| `14_Complexity_Report.csv` | **Final migration readiness report** with scores & ratings |

HTML snapshots of every crawled page are saved under `output\html\`.

---

## 6. Re-running for Selected Sites Only

See `RUNBOOK-Selected-Sites.md` for the exact filter-and-re-crawl workflow.

Quick summary:

1. Back up `output\02_GSites_Inventory_Detailed.csv`.
2. Trim the CSV to your chosen subset (e.g. first 16 lines = header + 15 sites).
3. Run `node 03_crawl_sites.js` then `.\05_score_sites.ps1 -PrimaryDomain rocheua.com`.
4. Restore the full inventory afterward.

---

## 7. Optional: Enable Enrichment & Published URLs

If Steps 4A and 5 were skipped because no OAuth token was available, authenticate with gcloud and re-run:

```powershell
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
.\Run-FullAssessment.ps1 -PrimaryDomain "rocheua.com" -SkipGAMExport -SkipBrowserAuth
```

Alternatively, pass a token directly:

```powershell
$token = (gcloud auth print-access-token)
.\Run-FullAssessment.ps1 -PrimaryDomain "rocheua.com" -AccessToken $token -SkipGAMExport -SkipBrowserAuth
```

---

## 8. Common Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `GAM not found` error | `gam.cfg` missing or path wrong | Create `gam.cfg` with the correct `GAM_PATH=...` |
| `Auth file not found` | Step 3 was skipped or deleted | Re-run `02_save_playwright_auth.js` or remove `-SkipBrowserAuth` |
| `403 errors` during crawl | Crawling edit URLs instead of published URLs | Run `node 03a_get_published_urls.js` with a valid OAuth token first |
| `gcloud command timed out` | gcloud not installed or not logged in | Install gcloud, run `gcloud auth login`, or skip enrichment with `-SkipEnrichment` |
| Empty `14_Complexity_Report.csv` | No sites in inventory | Verify GAM export succeeded and the target domain actually has Google Sites |
| Crawl runs forever | Very large site with many internal links | Lower the limit: `.\Run-FullAssessment.ps1 -PrimaryDomain "rocheua.com" -MaxPagesPerSite 50` |

---

## 9. Command Reference

| Goal | Command |
|---|---|
| **First full run** | `.\Run-FullAssessment.ps1 -PrimaryDomain "rocheua.com"` |
| **Skip GAM export** (use existing CSVs) | `.\Run-FullAssessment.ps1 -PrimaryDomain "rocheua.com" -SkipGAMExport` |
| **Skip browser auth** (reuse saved session) | `.\Run-FullAssessment.ps1 -PrimaryDomain "rocheua.com" -SkipBrowserAuth` |
| **Skip enrichment** | `.\Run-FullAssessment.ps1 -PrimaryDomain "rocheua.com" -SkipEnrichment` |
| **Limit crawl depth** | `.\Run-FullAssessment.ps1 -PrimaryDomain "rocheua.com" -MaxPagesPerSite 50` |
| **Pass OAuth token** | `.\Run-FullAssessment.ps1 -PrimaryDomain "rocheua.com" -AccessToken "ya29..."` |
| **Combine skips** | `.\Run-FullAssessment.ps1 -PrimaryDomain "rocheua.com" -SkipGAMExport -SkipBrowserAuth` |
