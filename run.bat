@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass ^
-File "%~dp0hpen.ps1" ^
%*

pause