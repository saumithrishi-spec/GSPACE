Non-prod Google Sites Assessment Pack

Files:
1. 01_run_gam_exports.cmd          -> Exports Sites inventory, permissions, and candidate artifacts using GAM.
2. 02_save_playwright_auth.js      -> Saves Playwright browser auth state for a non-prod test user.
3. 03_crawl_sites.js               -> Crawls modern Google Sites pages and captures pages, embeds, and external domains.
4. 04_enrich_artifacts.ps1         -> Calls Sheets, Forms, and Apps Script APIs to enrich discovered artifacts.
5. 05_score_sites.ps1              -> Produces a basic complexity report.

Suggested execution order:
- Run 01_run_gam_exports.cmd
- npm init -y
- npm i playwright csv-parse csv-stringify
- npx playwright install chromium
- node 02_save_playwright_auth.js "https://sites.google.com/"
- node 03_crawl_sites.js
- Set GCP_ACCESS_TOKEN to a valid OAuth access token
- pwsh .\04_enrich_artifacts.ps1
- pwsh .\05_score_sites.ps1 -PrimaryDomain roche.com
