# LifeTracker 1.2 — macOS 26/27 fixes

Everything below is in `LifeTracker/` (open `LifeTracker/LifeTracker.xcodeproj`).
`LifeTracker-Xcode.zip` is the same thing zipped.

## 1. GitHub pushed nothing after the macOS upgrade

**Cause.** LifeTracker runs under the Hardened Runtime and is *not* sandboxed.
On recent macOS that is no longer enough on its own: reading anything in
Desktop, Documents, Downloads, an external disk or a network share is gated by
TCC, and an app with no usage string for that location is refused **without
ever showing a prompt**. `Info.plist` had none.

So a file dragged in from Downloads could not be read, the staging copy failed,
`stage()` threw the error away with `continue`, and the push went up with
nothing in it. Colab notebooks kept working because the app downloads those
into its own temporary folder, which needs no permission at all.

**Fixed.**

- `Info.plist` now declares `NSDesktopFolderUsageDescription`,
  `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`,
  `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription` and
  `NSFileProviderDomainUsageDescription`. macOS now asks once per folder and
  remembers.
- Staging copies bytes with `Data(contentsOf:)` + `write(to:)` instead of
  `copyItem`, which carries ACLs, extended attributes and the quarantine flag
  across and fails on files the app can perfectly well read. This is exactly
  what the Colab path does.
- Every file that still can't be read is listed under the drop zone with the
  reason macOS gave, plus where to switch the permission on. Nothing is
  swallowed any more.
- Drops go through `.onDrop(of: [.fileURL])` and the item provider rather than
  `.dropDestination(for: URL.self)`, which hands back a bare path with none of
  the access the drag carried. The dashed box accepts drops itself now — as a
  `Button` it was eating the drag before the page behind it saw it.
- `GitHubSync.expand` built a child's path by cutting `url.path + "/"` off the
  front, which matches nothing when a dragged folder already ends in a slash;
  every file in it then landed as `Sem5/Users/you/Desktop/Sem5/notes.pdf`. It
  trims path components now.

## 2. Life AI — Gemini is two models

`gemini-2.5-flash` and `gemini-2.5-flash-lite`, and nothing else. Google's
`/models` answers with three dozen entries; every one is now folded onto one of
those two or dropped. A model name an older build remembered
(`gemini-flash-latest`, a dated snapshot) is migrated rather than sent to
Google, which would 404 on a retired one.

Both live in `GeminiModels` in `Models/AIProviders.swift` — change those two
lines to offer a different pair.

> Note: Gemini has no 3.5. 2.5 Flash and 2.5 Flash Lite are the current
> equivalents, so that is the pair I set.

## 3. Progress — the times flashed and vanished

`CompletionLogEntry` had `let id = UUID()`. The log is rebuilt from scratch on
every redraw of the page — on a timer, on any data change, and on every step of
picking a day — so each rebuild handed SwiftUI rows it had never seen and it
animated the old ones out. The id is derived from the entry now, so the same
tick stays the same row.

Also: every day in the range is selectable (a day where you only ticked a
one-off or a schedule task had no bar to click, so its times were unreachable),
the pick survives the pointer leaving the chart, and switching range clears it.

## 4. Portals had to be re-added every time

`context.save()` was called through `try?`, so a refused write lost the portal
silently. Saves now report what went wrong, on the page.

On top of that the portal list is mirrored to `UserDefaults` as plain JSON on
every change, and anything missing from the store is put back when the
University page opens. SwiftData is still the source of truth; the mirror only
ever restores. Removing a portal, resetting all data and restoring a backup all
clear or refresh it, so nothing comes back from the dead.

## 5. "Secret detected in content" — the push GitHub refused

`LifeAI.swift` had a real Google API key written into it:

```swift
static let bundledAPIKey = "AQ.Ab8…"
```

GitHub's push protection refuses any commit carrying one, which is what
*Repository rule violations found · Secret detected in content* meant. The
app then reported it as "GitHub accepted the commit but the branch didn't move
to it", because the rejection lands on the ref update rather than on the file —
so the message blamed the branch and never mentioned the key.

**Fixed.**

- The key is gone from the source. `bundledAPIKey` now reads `GeminiAPIKey`
  from the built Info.plist, or `Secrets.plist` in the bundle, and is empty
  when neither exists — Settings → Life AI then asks for one and keeps it in
  the Keychain. `Secrets.example.xcconfig` shows the setup; `.gitignore`
  covers `Secrets.xcconfig` and `Secrets.plist`.
- A 422 that is push protection now says so in the app: which kind of thing
  GitHub found, that nothing went up, and what to do about it.

**Rotate that key.** It was in the source, so it is in every build made from
it, and anyone with a copy of the app could read it out. New one at
https://aistudio.google.com/apikey — then either put it in `Secrets.xcconfig`
or just type it into Settings → Life AI.

## 6. Colab moved below GitHub

One column at every width now, Colab last: drop zone, repositories, repo
browser, then notebooks. It used to become a 300pt side rail above 1120pt
wide, which put notebooks level with the drop zone and squeezed the
repositories into the remaining 800pt.
