# Ultron Widgets — Xcode setup guide

All the widget source code lives in `UltronWidgetExtension/` and is ready to drop in. Creating the actual Widget Extension target is the one step Xcode forces you to do via GUI (scripted pbxproj edits for a new target are fragile and this repo uses `PBXFileSystemSynchronizedRootGroup` which plays nicer with the Xcode wizard).

## 1. Create the Widget Extension target

1. Open `Ultron.xcodeproj` in Xcode.
2. **File → New → Target…**
3. Pick **Widget Extension** (macOS, not iOS).
4. Product name: **`UltronWidgetExtension`** (case-sensitive — the code references it).
5. Bundle Identifier: `pavi.Ultron.UltronWidgetExtension`.
6. Team: same as the main Ultron target.
7. Language: Swift.
8. **Uncheck** "Include Configuration Intent" — we want a plain timeline provider.
9. Click **Finish**. Xcode activates the new scheme; click **Cancel** on the activation prompt (we keep the Ultron scheme).

## 2. Replace the generated stubs with ours

Xcode creates a few default files inside the new `UltronWidgetExtension/` group. Delete them (move to trash):
- `UltronWidgetExtension.swift` (the default widget)
- `AppIntent.swift` (if it appeared)
- The generated `UltronWidgetExtensionBundle.swift`

Keep these two Xcode-generated ones:
- `Info.plist` — overwrite with our `UltronWidgetExtension/Info.plist` contents
- `UltronWidgetExtension.entitlements` — overwrite with ours

Now add our source files to the new target:
1. In Finder, the folder `UltronWidgetExtension/` already contains `UltronWidgetsBundle.swift`, `WidgetSnapshotReader.swift`, `CockpitMiniWidget.swift`, `CommuteWidget.swift`, `ClaudeUsageWidget.swift`, `Info.plist`, `UltronWidgetExtension.entitlements`.
2. In Xcode: if Xcode already shows these files (because of `PBXFileSystemSynchronizedRootGroup`), they'll appear under the new target automatically. Otherwise drag the four `.swift` files from Finder into the **UltronWidgetExtension** group in Xcode's Project Navigator, making sure the Target Membership checkbox has only **UltronWidgetExtension** ticked.

## 3. Share the `WidgetSnapshot` model

The widget extension reads the same `WidgetSnapshot` struct the main app writes. In Xcode:

1. Select `Ultron/Services/WidgetSnapshot.swift` in the Project Navigator.
2. Open the File Inspector (right-hand sidebar, Cmd-⌥-1).
3. Under **Target Membership**, check **both** `Ultron` and `UltronWidgetExtension`.

## 4. Create the shared App Group

Both targets need to read/write the same container:

1. Select the **project** (top of Project Navigator) → **Ultron** target → **Signing & Capabilities**.
2. Click **+ Capability** and add **App Groups** if not already present.
3. Click **+** in the App Groups list and add `group.pavi.Ultron` (matches the `appGroupID` constant in `WidgetSnapshotReader.swift`).
4. Repeat for the **UltronWidgetExtension** target — add App Groups capability and tick the same group.

## 5. Wire the writer into the main app's refresh cycle

This step is one-line. In `Ultron/Services/InfoModeService.swift`, after the big refresh `TaskGroup`, add:

```swift
// After `self.state = .loaded`:
WidgetStateWriter.shared.write(snapshot: makeWidgetSnapshot())
```

And add a private helper that maps the internal state to `WidgetSnapshot`:

```swift
private func makeWidgetSnapshot() -> WidgetSnapshot {
    WidgetSnapshot(
        version: WidgetSnapshot.currentVersion,
        generatedAt: Date(),
        weather: weather.map { w in
            WidgetSnapshot.Weather(
                locationLabel: w.locationLabel,
                tempC: w.current.temperature,
                conditionSymbol: WeatherCode.symbol(for: w.current.weatherCode),
                highC: w.daily.first?.tempMax,
                lowC: w.daily.first?.tempMin
            )
        },
        nextEvent: nextEvent.map { e in
            WidgetSnapshot.Event(title: e.title, startAt: e.startDate, location: e.location)
        },
        claude: WidgetSnapshot.Claude(
            todayTokens: claudeStats.todayTokens,
            weeklyTrendPct: claudeStats.weeklyTrendPct,
            topProject: claudeStats.recentProjects.first?.label
        ),
        commute: commute.map { c in
            WidgetSnapshot.Commute(
                destinationLabel: c.toLabel,
                durationMinutes: Int(c.expectedTravelTime / 60),
                trafficDelta: Int((c.trafficDelay ?? 0) / 60),
                arrivalAt: Date().addingTimeInterval(c.expectedTravelTime)
            )
        },
        briefing: nil
    )
}
```

Field names may drift from what's above — grep for the actual properties and adapt. The widgets render `.placeholder` if any field is nil, so incomplete mappings fail gracefully.

## 6. Install + see it

1. Build + run Ultron in Release once so `/Applications/Ultron.app` is current.
2. Open **Notification Center** (click the clock in the menu bar OR trackpad-swipe from the right edge).
3. Scroll to the bottom → **Edit Widgets**.
4. Search for **"Ultron"** — you'll see:
   - **Cockpit mini** (medium) — weather + commute + Claude
   - **Rute** (small + medium) — just the commute
   - **Claude-forbrug** (small + medium) — tokens + weekly trend
5. Drag the one(s) you want into Notification Center or right-click the desktop → **Edit Widgets** to pin them there.

## 7. Verify data flows

- With Ultron running, open Cockpit (⌥⇧I) so refresh fires. Within 2 minutes the widget tile reflects the numbers.
- If a widget stays on "—", inspect `~/Library/Group Containers/group.pavi.Ultron/widget-state.json` — that's the shared file. If it doesn't exist, the main app hasn't written yet (most likely the `WidgetStateWriter.shared.write(...)` call is still missing from `InfoModeService.refresh()`).
