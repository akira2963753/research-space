# IEEE Conference Paper Template

IEEEtran `conference` format for top-tier IEEE/architecture venues (ISCA, MICRO, HPCA, ASPLOS, DAC, etc.).

## Structure

```
thesis/
├── main.tex              # Document class, packages, metadata
├── sections/             # One file per section
├── references.bib        # BibTeX database
├── figures/              # PDF/PNG figures
├── build.ps1             # Windows build script
└── Makefile              # Unix-like build target
```

## Build

**Windows (PowerShell):**

```powershell
cd thesis
.\build.ps1
```

**Manual:**

```powershell
pdflatex main.tex
bibtex main
pdflatex main.tex
pdflatex main.tex
```

Output: `main.pdf`

## Notes

- Uses `\documentclass[conference]{IEEEtran}` (two-column IEEE conference style).
- Replace title, authors, abstract, and section content in `sections/`.
- Add figures under `figures/` and uncomment `\includegraphics` in `sections/03_design.tex`.
- Cite papers via `\cite{key}` and add entries to `references.bib`.
- Before camera-ready submission: balance last-page columns (see IEEEtran footer reminder).

## LaTeX Environment

MiKTeX 25.12 is installed on this machine. First compile may auto-download packages.
If `pdflatex` is not found in a new terminal, restart the terminal or IDE.

Optional MiKTeX maintenance:

```powershell
mpm --update
initexmf --update-fndb
```
