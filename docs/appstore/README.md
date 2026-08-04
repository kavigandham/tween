# App Store screenshot pipeline

`compose.swift` turns a raw simulator capture into a finished App Store
screenshot: gradient background, headline, subtitle, rounded device shot.

AppKit only — no Pillow, no ImageMagick, nothing to install.

## Usage

```bash
# 1. Capture raw screens from the simulator into this directory
xcrun simctl io <UDID> screenshot HARNESS_PROPOSAL_DRAFT.png

# 2. Compose
xcrun swiftc -O compose.swift -o composebin && ./composebin

# 3. Downscale to the exact App Store size (AppKit renders at 2x on Retina)
sips -z 2868 1320 01-chat.png --out 01-chat.png
```

Edit the `slides` array in `compose.swift` to change headlines, colours, or
which capture each slide uses.

## Sizes

App Store Connect needs **one** iPhone set; it scales the rest.

| Display | Pixels | Use |
|---|---|---|
| 6.9" | 1320 × 2868 | **Upload this one** |
| 6.5" | 1284 × 2778 | Accepted alternative |

## ⚠️ The current captures are NOT shippable

The slides generated so far use the **harness** (`-HARNESS_*`), which renders:

- a debug title bar (`Proposal With Draft View`)
- placeholder place names (`Spot`, `Spot`, `Spot`)
- a map framed on the continental US rather than a real neighbourhood

They were built to prove the pipeline, not to ship. Real captures need the
actual app with real search results, which needs CoreLocation — unavailable in
this simulator (it returns no fix, so ranking never populates).

**To produce shippable screenshots:** run the app on a physical device with
location enabled, in a city with real results, and capture:

| # | Headline | Screen |
|---|---|---|
| 1 | It lives in your chat | Extension expanded, real spot names + ETAs |
| 2 | Fair means fair | Spot list showing everyone's minutes |
| 3 | Agree in one tap | Proposal panel with the action row |
| 4 | Search like Maps | Host app, committed search with results |
| 5 | Plan it ahead | Plan sheet, scheduled (Pro) |
| 6 | No account. No server. | Map with both pins, clean |

Then drop them in here and re-run the two commands above.

Copy for every slide, plus the full store listing, is in
[`../app-store.md`](../app-store.md).
