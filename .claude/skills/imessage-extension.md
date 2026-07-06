---
name: imessage-extension
description: iMessage extension hard rules — snapshotter only, retained managers, no first responder in compact, hosting lifecycle
---

# iMessage extension hard rules (Tween)

- `MKMapSnapshotter` only, never live `MKMapView` in the extension. Retain the
  snapshotter until its completion handler fires.
- Retain `CLLocationManager` (owned by `LocationProvider`, never inline).
- Compact view hosts no keyboard and no first responder.
- Hosting-controller lifecycle: `addChild` → `view.addSubview` →
  `didMove(toParent:)`.
- Opaque background on the hosted view to prevent blank render.
- `MSMessage.url` cap 5000 chars, coordinates only.
