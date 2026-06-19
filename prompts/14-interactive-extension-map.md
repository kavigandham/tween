# Feature: Interactive Map in Extension with Spot Browsing

Read CLAUDE.md before making changes. Do NOT run any build tools.
Read TweenMessages/MessagesViewController.swift and Shared/TweenViews.swift thoroughly first.

## Context
CLAUDE.md says "MKMapSnapshotter only, no MKMapView in the extension." We are INTENTIONALLY relaxing this constraint for ExpandedView ONLY, using SwiftUI's `Map` view (iOS 17+) which is lighter weight than MKMapView. Keep MKMapSnapshotter for CompactView (it's tiny and doesn't need interactivity) and for BubbleImageRenderer (which renders offline images).

Add a comment at the top of the ExpandedView explaining this decision:
```swift
// NOTE: Using SwiftUI Map instead of MKMapSnapshotter in expanded view
// for interactive browsing. SwiftUI Map is lighter than MKMapView.
// If memory issues arise on older devices, revert to snapshotter.
// CompactView and BubbleImageRenderer still use MKMapSnapshotter.
```

## What the ExpandedView Should Look Like (Both Locations Available)

```
┌──────────────────────────────────────┐
│  [Interactive Map — pan/zoom/tap]    │
│                                      │
│   🔵 You                             │
│              📍 Spot 1               │
│                  A 8 min · B 12 min  │
│        📍 Spot 2                     │
│            A 6 min · B 14 min        │
│   🟠 Friend                          │
│              ⭐ Midpoint             │
│        📍 Spot 3                     │
│            A 11 min · B 9 min        │
│                                      │
├──────────────────────────────────────┤
│ ☕ Blue Bottle    A 8m · B 12m   ▸   │
│ 🍽 Hangry Joes   A 6m · B 14m   ▸   │
│ 🌳 Fair Park     A 11m · B 9m   ▸   │
├──────────────────────────────────────┤
│     [ Send Blue Bottle ☕ ]          │
└──────────────────────────────────────┘
```

## Implementation

### 1. Replace MKMapSnapshotter with SwiftUI Map in ExpandedView

Remove the `TweenMapSnapshotView` from ExpandedView. Replace with a real SwiftUI `Map`:

```swift
@State private var mapPosition: MapCameraPosition = .automatic

Map(position: $mapPosition) {
    // Your location pin
    if let selfCoord = selfCoord {
        Annotation("You", coordinate: selfCoord) {
            TweenPin(role: isUserIn ? .selfActive : .selfDot)
        }
    }
    
    // Friend's location pin
    if let peerCoord = peerCoord {
        Annotation("Friend", coordinate: peerCoord) {
            TweenPin(role: .friend)
        }
    }
    
    // Midpoint pin
    if let selfCoord = selfCoord, let peerCoord = peerCoord {
        let mid = CLLocationCoordinate2D(
            latitude: (selfCoord.latitude + peerCoord.latitude) / 2,
            longitude: (selfCoord.longitude + peerCoord.longitude) / 2
        )
        Annotation("Midpoint", coordinate: mid) {
            TweenPin(role: .midpoint)
        }
    }
    
    // All ranked spot pins with A/B distance labels
    ForEach(rankedSpots) { spot in
        Annotation(spot.item.name ?? "Spot", coordinate: spot.item.placemark.coordinate) {
            VStack(spacing: 2) {
                // A/B distance chip
                HStack(spacing: 2) {
                    Text("A \(formatETA(spot.etaFromA))")
                    Text("·")
                    Text("B \(formatETA(spot.etaFromB))")
                }
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                
                // Pin icon
                Image(systemName: "fork.knife")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(selectedSpot?.id == spot.id ? Tokens.Palette.brand : .red)
                    .clipShape(Circle())
                    .shadow(radius: 2)
            }
            .onTapGesture {
                selectedSpot = spot
            }
        }
    }
}
.mapStyle(.standard(elevation: .realistic))
.mapControls {
    MapCompass()
    MapScaleView()
}
```

### 2. The map must be fully interactive
- User can pan and zoom freely
- Pinch to zoom works
- All pins are visible and tappable
- When the map first loads, frame all pins (self, peer, spots) with padding

### 3. A/B distance labels on EVERY spot pin
Every ranked spot pin on the map shows a small chip with both distances:
- `A 8 min · B 12 min` (using drive time from FairnessRanker)
- The chip sits directly above the pin icon
- The currently selected spot's pin should be visually distinct (brand color instead of red, slightly larger)

### 4. Scrollable spot list below the map
Below the map (taking about 35-40% of the screen), show a vertically scrollable list of ranked spots:

```swift
ScrollView {
    LazyVStack(spacing: 8) {
        ForEach(rankedSpots) { spot in
            HStack {
                // Category icon
                Image(systemName: "fork.knife")
                    .foregroundStyle(Tokens.Palette.brand)
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(spot.item.name ?? "Unknown")
                        .font(Tokens.Typography.headline)
                    Text(spot.item.placemark.title ?? "")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // A/B distances
                VStack(alignment: .trailing, spacing: 2) {
                    Text("A \(formatETA(spot.etaFromA))")
                        .font(Tokens.Typography.captionBold)
                    Text("B \(formatETA(spot.etaFromB))")
                        .font(Tokens.Typography.captionBold)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
            }
            .padding(Tokens.Spacing.s3)
            .background(
                selectedSpot?.id == spot.id 
                    ? Tokens.Palette.brand.opacity(0.1) 
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.chip))
            .onTapGesture {
                selectedSpot = spot
                // Animate map to this spot
                withAnimation(Tokens.Motion.spring) {
                    mapPosition = .region(MKCoordinateRegion(
                        center: spot.item.placemark.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                    ))
                }
            }
        }
    }
    .padding(.horizontal, Tokens.Spacing.s4)
}
```

### 5. Tapping a spot — bidirectional sync
- Tap a pin on the map → highlights the row in the list (scroll to it)
- Tap a row in the list → map animates to that pin, highlights it
- Both update `selectedSpot`

### 6. Send button
At the bottom, a persistent "Send" button:
- If a spot is selected: "Send [Spot Name]" in brand color
- If no spot selected: "Pick a spot to send" (disabled state)
- Tapping sends the MSMessage with the chosen spot

### 7. ETA formatting helper
Make sure this exists in TweenViews.swift or a shared location:
```swift
func formatETA(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 1 { return "<1 min" }
    if minutes < 60 { return "\(minutes) min" }
    return "\(minutes / 60)h \(minutes % 60)m"
}
```

### 8. Keep CompactView using MKMapSnapshotter
CompactView stays unchanged — it's small (keyboard height) and doesn't need interactivity. Keep using TweenMapSnapshotView there.

### 9. Keep BubbleImageRenderer using MKMapSnapshotter
The bubble image is a static PNG sent in the message. No change needed.

### 10. Memory management
- Cancel all map-related tasks in `willResignActive`
- When transitioning from expanded back to compact, the SwiftUI Map will be removed from the hierarchy, freeing its resources
- Keep the ranking cap at 5 in the extension

## After fixing
Commit with message: "feat: interactive map in extension with spot browsing and A/B distances"
