@echo off

rem So here's a great thing to know. Python output to PowerShell ends up in UTF-16.
rem Which CloudFormation can't process. So that's nice.

rem Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
echo Exporting templates...
python stack.py > OpenEMR-Express-Plus.json
python stack.py --dev > OpenEMR-Express-Plus-Developer.json
python stack.py --recovery > OpenEMR-Express-Plus-Recovery.json
python stack.py --recovery --dev > OpenEMR-Express-Plus-Recovery-Dev.json
rem ..\build-utilities\bomstripper.ps1
echo Done.