@echo off
setlocal
rem Build DNSTCPProxy.exe from src\DNSTCPProxy.cs using the compiler that ships with .NET Framework 4.x

set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" (
  echo [x] csc.exe not found - .NET Framework 4.x is required.
  pause
  exit /b 1
)

if not exist "%~dp0..\dist" mkdir "%~dp0..\dist"

"%CSC%" /nologo /codepage:65001 /target:exe /platform:anycpu /r:System.dll /r:System.Core.dll /out:"%~dp0..\dist\DNSTCPProxy.exe" "%~dp0DNSTCPProxy.cs"
if errorlevel 1 (
  echo.
  echo [x] Build failed.
  pause
  exit /b 1
)

echo.
echo Build OK: %~dp0..\dist\DNSTCPProxy.exe
pause
