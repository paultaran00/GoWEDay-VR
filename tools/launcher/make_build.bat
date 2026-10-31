@echo off
rem Builds <repo>\build: the launcher exe plus fresh copies of the mod files it needs.
rem Needs <repo>\UEVR (UEVR runtime with the patched UEVRBackend.dll) and tools\gameinput_vr\gameinput_vr.dll.
rem Run again after changing the scripts, UEVR or gameinput_vr.
setlocal
set "ROOT=%~dp0..\.."
set "OUT=%ROOT%\build"
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

if not exist "%OUT%" mkdir "%OUT%"
"%CSC%" /nologo /target:winexe /optimize /out:"%OUT%\GoWEDay_VR.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Xml.dll /win32icon:"%~dp0icon.ico" "%~dp0Launcher.cs" || exit /b 1

if not exist "%OUT%\UEVR" mkdir "%OUT%\UEVR"
for %%F in (UEVRInjector.exe UEVRInjector.dll.config UEVRBackend.dll LuaVR.dll UEVRPluginNullifier.dll openvr_api.dll openxr_loader.dll revision.txt) do (
    copy /y "%ROOT%\UEVR\%%F" "%OUT%\UEVR\" >nul || exit /b 1
)
if not exist "%OUT%\gameinput_vr" mkdir "%OUT%\gameinput_vr"
copy /y "%ROOT%\tools\gameinput_vr\gameinput_vr.dll" "%OUT%\gameinput_vr\" >nul || exit /b 1
robocopy "%ROOT%\profile" "%OUT%\profile" /mir /njh /njs /nfl /ndl >nul
if errorlevel 8 exit /b 1
copy /y "%~dp0README.txt" "%OUT%\" >nul
echo Build OK: %OUT%
