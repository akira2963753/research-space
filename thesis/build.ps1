# Build IEEE conference paper (pdflatex + bibtex)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Invoke-TeX {
    param(
        [string]$Command,
        [string[]]$CommandArgs
    )
    & $Command @CommandArgs
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE"
    }
}

Write-Host "==> pdflatex (pass 1)"
Invoke-TeX pdflatex @("-interaction=nonstopmode", "main.tex")

Write-Host "==> bibtex"
Invoke-TeX bibtex @("main")

Write-Host "==> pdflatex (pass 2)"
Invoke-TeX pdflatex @("-interaction=nonstopmode", "main.tex")

Write-Host "==> pdflatex (pass 3)"
Invoke-TeX pdflatex @("-interaction=nonstopmode", "main.tex")

Write-Host "Done: main.pdf"
