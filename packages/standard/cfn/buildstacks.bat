#!/bin/bash

python stack.py > OpenEMR-Standard.json
python stack.py --dev > OpenEMR-Standard-Developer.json
python stack.py --recovery > OpenEMR-Standard-Recovery.json
python stack.py --recovery --dev > OpenEMR-Standard-Recovery-Developer.json
