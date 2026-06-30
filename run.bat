@echo off
setlocal

rem PowerShell's param binder only recognizes single-dash switches
rem (-Help, -h, -?), not the Unix-style "--help". Translate it here so
rem "run --help" works the same as "run -Help".
set ARGS=%*
if /I "%ARGS%"=="--help" set ARGS=-Help

powershell -NoProfile -ExecutionPolicy Bypass ^
-File "%~dp0hpen.ps1" ^
%ARGS%

pause
