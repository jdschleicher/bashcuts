# Daily Viewer — WPF prototype

A Windows-native (WPF) twin of the HTML mock in `../index.html`. Same four-tile
layout, same cache-first / refresh-on-demand model — rendered with native WPF
controls instead of a browser.

## Run it

```powershell
# From this folder, on Windows:
powershell.exe -ExecutionPolicy Bypass -File .\Start-DailyViewer.ps1
```

`pwsh` (PowerShell 7) also works — the script detects its MTA thread and
relaunches itself under Windows PowerShell (which WPF needs for STA).

## What maps to what

| HTML mock | WPF equivalent |
|---|---|
| `<details>` collapsible tile | native `Expander` (built-in chevron + collapse) |
| Nested `<details>` groups | nested `Expander` |
| `<a target="_blank">` | `Hyperlink` + `RequestNavigate` → `Start-Process` (default browser) |
| Per-tile "cached … / refresh" | header `Button` + `DispatcherTimer` |
| CSS custom-property tokens | keyed `SolidColorBrush` resources, mutated for the theme toggle |
| `prefers-color-scheme` | manual light/dark toggle (`◐` button) |
| Summary stat strip | `UniformGrid` of `Button` cards that expand + scroll to their tile |

## Files

- `DailyViewer.xaml` — layout, styles, and placeholder content
- `Start-DailyViewer.ps1` — loads the XAML with `XamlReader` and wires interactions

## Wiring real data

Content is placeholder. In the live build each tile reads from a local cache
file, and its refresh button runs that tile's `az boards query` (or the Outlook
calendar pull), rewrites the cache, and re-renders — identical to the HTML plan.
