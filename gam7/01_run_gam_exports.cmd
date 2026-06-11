@echo off
setlocal
set SCRIPT_DIR=%~dp0
set OUTDIR=%SCRIPT_DIR%output
if not exist "%OUTDIR%" mkdir "%OUTDIR%"

echo [1/6] Minimal Google Sites sanity export...
gam config auto_batch_min 1 num_threads 10 redirect csv "%OUTDIR%\01_GSites_Inventory_Min.csv" multiprocess redirect stderr - multiprocess all users print filelist fields id,name,mimetype filepath showmimetype gsite
if errorlevel 1 goto :fail

echo [2/6] Detailed Google Sites inventory...
gam config auto_batch_min 1 num_threads 10 redirect csv "%OUTDIR%\02_GSites_Inventory_Detailed.csv" multiprocess all users print filelist query "mimeType='application/vnd.google-apps.site' and trashed=false" fields id,name,mimetype,webviewlink,createdtime,modifiedtime,description,owners,shared,parents,driveid
if errorlevel 1 goto :fail

echo [3/6] Google Sites permissions...
gam config auto_batch_min 1 num_threads 10 redirect csv "%OUTDIR%\03_GSites_Permissions.csv" multiprocess all users print filelist query "mimeType='application/vnd.google-apps.site' and trashed=false" fields id,name,webviewlink,owners,basicpermissions oneitemperrow
if errorlevel 1 goto :fail

echo [4/6] Broad candidate Google Sheets inventory...
gam config auto_batch_min 1 num_threads 10 redirect csv "%OUTDIR%\04_Candidate_Sheets.csv" multiprocess all users print filelist query "mimeType='application/vnd.google-apps.spreadsheet' and trashed=false" fields id,name,mimetype,webviewlink,createdtime,modifiedtime,owners,shared,parents,driveid
if errorlevel 1 goto :fail

echo [5/6] Broad candidate Google Forms inventory...
gam config auto_batch_min 1 num_threads 10 redirect csv "%OUTDIR%\05_Candidate_Forms.csv" multiprocess all users print filelist query "mimeType='application/vnd.google-apps.form' and trashed=false" fields id,name,mimetype,webviewlink,createdtime,modifiedtime,owners,shared,parents,driveid
if errorlevel 1 goto :fail

echo [6/6] Broad candidate Apps Script inventory...
gam config auto_batch_min 1 num_threads 10 redirect csv "%OUTDIR%\06_Candidate_Scripts.csv" multiprocess all users print filelist query "mimeType='application/vnd.google-apps.script' and trashed=false" fields id,name,mimetype,webviewlink,createdtime,modifiedtime,owners,shared,parents,driveid
if errorlevel 1 goto :fail

echo.
echo GAM exports completed successfully.
echo Output folder: %OUTDIR%
exit /b 0

:fail
echo.
echo GAM export failed. Review the command above and GAM error output.
exit /b 1
