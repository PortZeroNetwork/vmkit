# A .ps1 with one em dash in a string — fatal under PowerShell 5.1, which reads
# UTF-8 without a BOM as CP1252.
Write-Output "RESULT=PASS this string ends early — and the rest parses as code"
