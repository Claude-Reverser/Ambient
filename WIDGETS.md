# Ambient widget packages · v1

In Widgets → Build your own, edit HTML/CSS, set a height (80–600 points), then choose Apply code. The custom-widget toggle controls visibility. Import loads a draft without applying it; Export saves the current draft as JSON. One custom package can be active at a time.

```json
{
  "version": 1,
  "name": "My network",
  "height": 160,
  "html": "<section><h3>NETWORK</h3><p>↓ <b data-ambient=\"download\"></b></p><p>↑ <b data-ambient=\"upload\"></b></p></section>",
  "css": "section {margin:8px;padding:20px;border-radius:22px;background:#211534ee;color:#dbc5ff} h3 {margin:0;font-size:11px;letter-spacing:3px} p {margin:10px 0;font-variant-numeric:tabular-nums}"
}
```

Bindings are text replacements on elements carrying `data-ambient`:

| Value | Display |
| --- | --- |
| `time` | Local time, hours and minutes |
| `date` | Local full date |
| `cpu` | CPU percentage over the sample interval |
| `memory` | Estimated RAM in GiB (displayed as GB) |
| `download` | Combined Ethernet/Wi-Fi receive rate |
| `upload` | Combined Ethernet/Wi-Fi transmit rate |

CSS variables `--cpu` and `--memory` are percentages, suitable for bar widths. HTML/CSS is limited to 256 KB combined; imported JSON to 300 KB; names to 120 characters. The package must declare version 1. Unknown versions are rejected instead of silently misinterpreted.

Rendering uses an ephemeral WebKit view. Network requests, page JavaScript, frames, navigation and local-file access are not supported. Inline CSS and data-URL images/fonts are supported. Ambient updates DOM text in an isolated script world; widget code receives no native command or filesystem bridge. A custom widget costs more memory than the native clock/system monitor. Applying code reloads the view; the 500 ms updates do not reload the HTML.

This is a local exchange format for a future library, not a public registry or compatibility promise for arbitrary Rainmeter/Wallpaper Engine widgets. A public release still needs license/provenance review and packaging/signing decisions.
