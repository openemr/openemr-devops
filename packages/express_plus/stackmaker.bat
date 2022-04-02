@echo off


echo Exporting templates...
python stack.py > OpenEMR-Express-Plus.json
python stack.py --dev > OpenEMR-Express-Plus-Developer.json
python stack.py --recovery > OpenEMR-Express-Plus-Recovery.json
python stack.py --recovery --dev > OpenEMR-Express-Plus-Recovery-Dev.json
echo Done.