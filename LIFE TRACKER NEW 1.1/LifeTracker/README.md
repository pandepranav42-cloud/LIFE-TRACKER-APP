# Life — a minimal life tracker

Two builds of the same app:

- `LifeTracker/` — native macOS SwiftUI app (SwiftData + Swift Charts)
- `life-tracker.html` — standalone web version, identical screens, localStorage persistence

Both use the same minimal aesthetic: near-white/near-black surfaces, hairline borders, one restrained ink accent.

## macOS app setup

1. In Xcode: **File → New → Project → macOS → App**
2. Product Name: `LifeTracker` · Interface: **SwiftUI** · Language: **Swift** · Storage: **SwiftData**
3. Delete the auto-generated `LifeTrackerApp.swift`, `ContentView.swift`, and any sample model files.
4. Drag the entire `LifeTracker/` folder from this bundle into the Xcode project navigator. Choose **Copy items if needed** and **Create groups**.
5. Build target: macOS 14 or later (SwiftData + `NavigationSplitView`).
6. Build & run (⌘R).

### File map

```
LifeTracker/
├── LifeTrackerApp.swift          # @main + ModelContainer (every @Model is registered here)
├── Models/
│   ├── Models.swift              # Habit, ScheduleItem, JournalEntry, Timetable*, CalendarMark, Study*, ProgressEngine
│   ├── Accounts.swift            # Keychain, AppConfig, AuthSession, AccountStore (Apple + two Google connections)
│   ├── CalendarSync.swift        # Apple (EventKit) + Google Calendar, tagged for clean deletion
│   ├── DriveSync.swift           # Google Drive backup of materials, mood board, timetable image
│   ├── ColabSync.swift           # Colab notebooks from the second Google account
│   ├── GitHubSync.swift          # repos, contents, releases, profile, contributions (REST + one GraphQL call)
│   ├── Notifications.swift       # schedule reminders
│   ├── Transfer.swift            # .lifetracker export / import, including secrets when you ask
│   ├── WidgetBridge.swift        # what the widgets read
│   ├── Quotes.swift              # QuoteBank — curated quote list + rotation helpers
│   ├── LifeAI.swift              # the assistant client: streaming, tool rounds, model discovery
│   ├── AIProviders.swift         # who answers — Gemini, OpenAI, Claude, Grok, any OpenAI-compatible endpoint
│   ├── AIWire.swift              # the three request dialects, behind one interface
│   ├── VoiceIO.swift             # microphone → text, text → speech, and the hands-free loop
│   ├── AIContext.swift           # the one gate — everything Life AI may see (Journal excluded)
│   ├── AIIndex.swift             # on-device RAG: extraction, chunking, BM25 + NLEmbedding, minimal ZIP reader
│   ├── LifeAIActions.swift       # the seven things Life AI may add to the app
│   └── LifeAIBridge.swift        # attachments, "ask Life AI" from any page, saving answers into notes
├── Views/
│   ├── ContentView.swift         # NavigationSplitView + Sidebar
│   ├── LoginView.swift           # RootView (where the Life AI overlay is attached) + sign-in
│   ├── TodayView.swift           # dashboard: rotating quote, Now/Next, habits, timeline, 7-day strip
│   ├── HabitsView.swift
│   ├── ScheduleView.swift
│   ├── TimetableView.swift       # blank-grid timetable, category manager, image upload
│   ├── StudyView.swift           # subjects, syllabus, materials, links, reminders
│   ├── UniversityView.swift      # university portals you add: the list, the in-app browser, downloads, per-portal logins
│   ├── GitHubView.swift          # GitHub & Colab console: push, browse, release, profile, notebooks
│   ├── AccountViews.swift        # accounts + transfer sections
│   ├── LifeAIPanel.swift         # Life AI: floating logo, chat panel, Markdown + code blocks, Settings section
│   └── OtherViews.swift          # Calendar, Progress, Journal, Settings
└── Components/
    ├── DesignSystem.swift        # Palette, section headers, card modifier, Color(hex:)
    └── Components.swift          # ProgressRing, CheckCircle, HabitRow, ScheduleRow, StatCard, EmptyState
```

### Habits page

Every habit row now has its own tick checkbox for **today** — no need to go to the Today dashboard just to check something off. Tapping the name/icon still opens the edit sheet; the checkbox and the "⋯" menu are separate tap targets so they don't fight each other.

### Calendar — mark important dates

Any day can now carry your own colored markers — exams, deadlines, anniversaries, whatever. Select a day, type a title, pick from 10 color swatches (same palette as Timetable categories), and add it. Marks show as small colored dots under the date in the grid, and can be renamed, recolored, or deleted from the day's detail panel.

### Timetable, how it works

The grid has two independent layers:

1. **Time slots** — the rows. Add one via "Add Time Slot" (just a start/end time). This is the "border" — it exists with zero content, purely to define the grid's structure.
2. **Categories** — your own labels + colors. No presets. Add/rename/recolor/delete anytime from "Categories". 10 muted color swatches to pick from.
3. **Blocks** — the content. Tap any cell (day × time slot) to fill it in, choosing a title and category.

If you'd rather not build the grid at all, **Upload Image** lets you drop in a photo of a timetable you already made (on paper, in another app, wherever) — it replaces the grid entirely until you remove it.

Nothing is pre-filled. First launch is a blank timetable.

### Journal

Each entry has an optional title plus the usual text/mood/energy. Every entry you've ever saved — not just the last handful — is listed below the editor as "Saved Entries," each showing its date and the exact time it was saved. Tap one to reopen and edit it.

## Web version

Just open `life-tracker.html` in any modern browser. First run seeds a few sample habits and a daily schedule so those screens aren't empty — the Timetable is deliberately left blank. Data lives in `localStorage` under the key `life-tracker-v1`. Settings → Data has Export / Import / Reset.

If you're updating from an earlier version of this file, old saved data is automatically migrated on first load — any previously-seeded demo timetable is cleared out (since categories changed shape), everything else (habits, schedule, journal) is preserved.

## Design notes

- **Palette**: one ink accent (`Color.primary` on Mac, `#111` / `#f5f5f5` in the web version). Everything else is neutral. Both Light and Dark supported via system.
- **Typography**: system font throughout. Section labels are tiny caps with tracking; numbers use `.monospacedDigit`.
- **Spacing**: 32px page padding, 24px between sections, hairline dividers (opacity 0.06–0.08).
- **Progress ring**: single stroke, animated, no gradient.
- **Completed habits**: filled black square with a check — no color coding, no red for misses (per spec).
- **Missed days in history strip**: hairline outline only. Neutral, not accusatory.

### Latest updates (this pass)

- **Today** reflects Calendar marks: events show as colored chips, "habit for this day" marks appear as tickable rows in the habits card — in the color you chose.
- **Habits** has a new "This Month" calendar-shaped grid above "Last 30 days".
- **Schedule** items each get their own color (a small swatch picker in the editor), shown as the row's left accent.
- **Timetable** now rejects an exact duplicate time slot (same start+end as an existing row) with an inline error — adjacent ranges are still fine.
- **Calendar**: "Important Dates" is at the top of the day panel; the grid shows Apple-Calendar-style colored name pills instead of dots; marks are either an **Event** (informational, no tick) or a **Habit for this day** (tickable, counts in Progress).
- **Progress**: the weekly bar chart now shows the raw count of habits completed each day (regular habits + completed calendar habit-marks), not a percentage.
- **Journal** is locked to today only — no picking past or future dates to write in — and each entry can have its own color.
- **Settings**: replaced Export/Import with a single "Reset all data" action; added a Developer section (name, email, Contact link, Copy Email).


### Progress — how the numbers are counted

All progress numbers (Today, Habits, Progress) come from one `ProgressEngine` in `Models.swift`, so they always agree:

- A habit only counts on days it was actually scheduled (frequency, start date and pause periods respected). Pausing no longer wipes past history.
- Ticks on unscheduled days never inflate a percentage.
- Calendar "habit" marks count as one-off items on their day.
- Today is still in progress: open items are not counted as misses until the day is over.
- Future days are never counted.

The Progress page has 7 days / 30 days / This month / 90 days ranges, a comparison with the previous period, perfect days, active days, a daily completion chart, a weekday pattern and per-habit rates. The streak system has been removed.

### Quotes

The quote on Today changes by itself every 30 minutes (`QuoteBank.rotationMinutes`), cycling through the whole list without repeats. There is no manual refresh button.

### Study

A cozy "study space" page (below Timetable in the sidebar):

- Cover banner (click-to-change on hover), avatar and editable title, and an affirmation: a new one each day, or write your own with the pencil button.
- **classes** — subject cards with syllabus progress and file count. Right-click to edit/delete.
- Mini calendar, overview stats, live clock and a reminders checklist.
- **Mood Board** — add your own images.

Open a subject for three tabs:

- **Syllabus** — topics/chapters with ticks and a progress bar. "Paste list" adds one topic per clipboard line.
- **Materials** — add PDF, PowerPoint, Word, Keynote, Pages, images… via **Add Files** or drag-and-drop. Click to Quick Look, double-click to open in its app, right-click to Save a Copy / Rename / Delete. Files are stored inside the app, so moving the originals doesn't break anything.
- **Delete** — every card has its own 🗑: files, links (with a copy button beside it), syllabus topics, reminders and mood-board pictures. Nothing is hidden behind a right-click or a hover any more, so it all works the same on iPad.
- Files specifically: the 🗑 sits next to Share. If that file is backed up to Drive you're asked which copy to remove: *Delete here and in Drive* (the Drive copy goes to Drive's Bin — recoverable there for 30 days) or *Delete here only*. Files that were never uploaded just ask once. Mood-board pictures take their Drive copy with them the same way.
- **Share** — every file card has a ↑ button that opens the system share sheet: AirDrop, WhatsApp, Messages, Mail, Telegram, Save to Files, anything installed. With more than one file in view, **Share All** sends the whole set in one go. The file is written out with its real name and extension at the moment you press share, so the person on the other end gets `Module-3.pdf`, not a copy of the database.
- **Notes** — free-form notes, saved automatically.

### Theme, light/dark and iPad

- The whole app now uses one warm "study space" theme (cream pages, latte cards, cocoa accent, monospaced headings). All colours live in `Palette` in `DesignSystem.swift`; each has a light and a dark value.
- Settings → Appearance: System / Light / Dark. "System" follows the Mac or iPad automatically.
- One target builds for **macOS 14+** and **iPadOS 17+**. In Xcode pick *My Mac* or any iPad simulator/device as the run destination.
- Every page reads the live width of the content area (`layoutWidth`), so layouts adapt to Mac window resizing and iPad full screen, Split View, Slide Over and Stage Manager.
- Mac-only features have iPad equivalents: files open in Quick Look (with Share / Save to Files) instead of an external app, and hover-only buttons are also available from press-and-hold menus.

### Progress: habits vs schedule tasks, with times

- Schedule items can now be ticked off on Today (round check on the right of each timeline row). Each tick stores the exact time.
- Habit ticks also store their time (older ticks from before this update show "—").
- **By weekday** shows, for each day, `habit N` and `schedule N` separately with two bars (cocoa = habits, blue = schedule tasks).
- **Daily completion**: click/tap any bar to see that day's log — every habit and schedule task with the time it was done.

### Calendar sync + accounts

- Calendar page → **Sync**: turn on Apple Calendar (EventKit). Marks you add/edit/delete are mirrored as all-day events into a "LifeTracker" calendar (or one you choose — including Google calendars added to System Settings → Internet Accounts). Your existing Apple Calendar events show on the LifeTracker calendar.
- Settings → **Accounts**: Sign in with Apple, and Sign in with Google (OAuth, Calendar scope). With Google signed in, turn on Google Calendar in the Sync sheet to write straight into your primary Google calendar.
- Setup needed once:
  - **Sign in with Apple**: Xcode → target → Signing & Capabilities → + Capability → Sign in with Apple (paid Apple Developer team required).
  - **Google**: create an OAuth client ID (type iOS, bundle id `com.pranavpande.LifeTracker`) in Google Cloud Console with the Calendar API enabled, then paste it in Settings → Accounts. Steps are shown in the app.
- Tokens are stored in the Keychain.

### Login, Drive backup, Google account

- The app opens on a **login screen** with two choices: **Continue with Google**, or **Continue as guest** right below it. (Apple login is hidden for now; the old developer username/password login is gone.)
- **Guest** opens the app immediately with no account. Everything works and stays on the device; Drive backup and Calendar sync are the only things that need Google, and connecting one later from Settings → Connected services keeps all existing data. Settings shows the session as "Signed in with Guest".
- Sign out from Settings → Account returns to the login screen.
- **Google Drive backup**: with Google connected, every study material, mood-board picture, Study cover and timetable image is uploaded to `LifeTracker/…` in your Drive (scope `drive.file`: the app only sees files it created). A ☁︎✓ badge shows on backed-up materials. Settings → Connected services has "Back up everything now".
- **One-time Google setup (developer)**: Google Cloud Console → new project → enable *Google Calendar API* and *Google Drive API* → OAuth consent screen (External, add your Gmail as test user) → Credentials → OAuth client ID, type **iOS**, bundle id `com.pranavpande.LifeTracker` → paste the client ID into `AppConfig.googleClientID` in `Models/Accounts.swift`.
- **Sign in with Apple**: Xcode → target → Signing & Capabilities → + Capability → Sign in with Apple (paid Apple Developer team).

### Google "G" logo

`GoogleG.png` (transparent, 192×192) is included in the project and shown on the "Continue with Google" button.

### Study → subject → Links

Each subject has a **Links** tab: paste ANY link — YouTube, Google Drive/Docs, Dropbox, GitHub, a PDF URL, a Notion page, mailto:, app links like notion:// or zoom://, intranet hosts, IP addresses or localhost:3000 — or drag one in from the browser. A pasted sentence containing a link works too. Titles are fetched automatically (YouTube via oEmbed, websites from the page title); YouTube links show the video thumbnail. Click to open; right-click / press-and-hold to copy, rename or delete.

### Study files: any type

Study → subject → **Files** accepts any file: PDF, slides, Word, spreadsheets, code (Python, C, C++, Java, JS/TS, Swift, SQL, … ~70 extensions recognised with a language badge and a code preview), images (with thumbnails), videos, audio, archives and anything else. Filter by type from the menu. Every file is backed up to Google Drive under `LifeTracker/Study/<Subject>/` when Google is connected.

### Journal lock
Journal → **Lock** (or Settings → Privacy). Every time you open the Journal it asks for Touch ID / Face ID or your device password; it re-locks when you leave the page or the app goes to the background. Turning the lock on or off also needs authentication. Journal text is hidden on the Calendar page while locked.

### Schedule notifications
Each schedule item has **Notify me** (at start, or 5/10/15/30/60 min before). Notifications repeat daily and are scheduled on each device — Mac and iPad — from the schedule stored there. Settings → Notifications turns them all on/off and shows permission status.

### Widgets (Mac + iPad)
A widget extension (`LifeTrackerWidgets` target) adds three widgets in small/medium/large: **Quote** (rotates every 30 min), **Timetable** (your uploaded timetable picture, or today's grid blocks), **Habits this month** (day-by-day heatmap + today's ring). They follow light/dark and the clear / tinted widget styles. The app feeds them through the App Group `group.com.pranavpande.LifeTracker`:
- Xcode → each target (LifeTracker and LifeTrackerWidgets) → Signing & Capabilities → pick your Team; Xcode registers the App Group automatically.
- Mac: right-click desktop → Edit Widgets. iPad: long-press home screen → Edit → Add Widget → LifeTracker.

### Export / Import (moving everything between Mac and iPad)

Settings → **Backup & transfer**:
- **Include saved logins** (on by default) puts your GitHub token and every saved portal ID/password into the file too, so the other device is usable the moment it finishes importing. The import sheet says when a file carries them. Turn it **off** before sending an export to a classmate — whoever opens that file can sign in as you. Google sign-in is deliberately not included; tap Connect Google on the other device.
- **Export everything** writes one `.lifetracker` file containing habits + ticks, schedule + ticks, timetable (grid *and* the uploaded picture), calendar marks, journal, study subjects with syllabus/notes/links and **every uploaded file** (PDF, slides, Word, code, images, video…), mood board, reminders and settings. Files are streamed one at a time, so large libraries don't blow up memory. On Mac you pick where to save; on iPad use Share / Save to Files (AirDrop, Drive, iCloud Drive…).
- **Import a backup** always **replaces everything**: this device is wiped and rebuilt from the file, so both devices end up identical. There's no merge option and nothing to choose — an export is a snapshot, and importing it restores that snapshot. Calendar events from the marks being replaced are pulled out of Apple/Google Calendar first, so nothing is orphaned there.
- Drive file ids travel with the export, so an imported device recognises files as already backed up and does not upload a second copy.

The two devices remain separate copies: changes made on one do not appear on the other until you export/import again.

### Calendar clean-up

Deleting a calendar mark now removes its event from Apple Calendar even when the stored event identifier has gone stale — every event LifeTracker writes carries a `LifeTracker-ID:` tag in its notes, and the delete falls back to finding it by that tag around the same day.

**Reset all data** and **Import** both sweep the calendars first: every tagged event within a ±3-year window goes, along with anything left in the LifeTracker calendar, and then that calendar itself is deleted if LifeTracker created it.

### Reset all data

Settings → Data → **Reset all data…** opens a full warning sheet rather than a one-line alert. It lists exactly what will go, counted item by item (habits, ticks, schedule, timetable blocks, calendar marks, journal entries, subjects, topics, files, links, mood-board pictures), and points you at Export first if you want a copy. The sheet itself is the confirmation — pressing **Erase everything** does it.

When a Google account is connected it also offers **Also delete the Google Drive backup**, on by default: every file LifeTracker uploaded *and* the whole `LifeTracker` folder are moved to Drive's Bin (restorable there for 30 days), so nothing is left behind — including files another device uploaded that this one never knew about. Drive is cleared first, while the file ids still exist, then the local database is wiped and the widgets refresh.

### GitHub & Colab — push without the commands

Study page → **GitHub & Colab** button, right beside JUNO.

Connect once with a GitHub **personal access token** (the sheet links straight to the pre-filled token page — tick `repo`, plus `delete_repo` if you want the app to delete repositories). The token lives in the device Keychain and never enters an export file.

After that it's three steps, every time:

1. **Drop** files or a whole folder onto the page (or click to pick them). Any file type. A folder keeps its shape — drop `Sem5/` and the repo gets `Sem5/…` exactly as it sits on disk. Dropped bytes are copied to a staging area immediately, because the sandbox permission from a drop expires before you press Push.
2. **Pick a repo** from the grid, or press **New repo** (name, description, private/public, optional README). The last repo you used is remembered.
3. **Choose where it lands.** The folder button lists the folders that already exist in the repo (two levels deep) — pick one, or type a new name beside it. A line under the controls spells out the destination, e.g. *Going to SEM-V-LAB-CODES/CV LAB (SEM V)*. Easiest of all: browse into the folder in the file list below and press **Push here**.
4. **Push.** Optional commit message; leave it blank and each file gets a sensible one of its own.

Uploads go through GitHub's Contents API — one commit per file, exactly like the web "Upload files" button. A file that already exists is updated rather than rejected. GitHub's limit means anything over 50 MB is skipped and named in the result.

**Releases** — publish a version of your app so people can download it. Drop the build (.zip, .dmg, .ipa…), press **New release**, and you get a tag (pre-filled with the next version number), a title, notes, and Draft / Pre-release switches. The staged files are attached as downloads. Release assets go up to 2 GB each, unlike the 50 MB file push, so a whole build is fine. Each release lists its assets with size, download count and a copy-link button, and has its own 🗑 (the git tag stays behind — remove that on GitHub if you want it gone).

**Selecting a repo** (tapping its card) shows its **releases** and **files** right below the grid, as before — New release button, every release with its notes and attached builds, then the browsable file list.

- **README** — the button next to "files in …" says **Add README** when the repo hasn't got one and **Edit README** when it has. It opens a Markdown editor with Write/Preview tabs, quick Heading / List / Code buttons, and a commit message box; a brand-new one starts from a template with the repo's name and description already filled in. Any other small text file (`.md`, `.txt`, `.json`, `.yml`, source files…) has a ✎ in the list that opens the same editor.
- **Files** — tap a folder to open it, ⬇ downloads a file (Mac asks where to save; iPad hands it to the share sheet), 🗑 deletes it with a commit. Private repos work, because downloads go through the API with your token rather than the public URL.
- **Releases** — ⬇ downloads a build, 🔗 copies its direct link, 🗑 deletes the release.

**➔ on a repo card** opens that repository on its own page: the same files and releases, plus the README. Each card also has 🗑 to delete the whole repository — permanent, and it needs the `delete_repo` scope. Right-click a card for "Open on github.com" and "Copy clone URL".


**A brand-new repository works too.** A repo with no commits has no branch, and GitHub's Contents API answers every write to it with `409 Conflict` — which is why pushing into a repo created without a README used to dead-end. The app now checks once per push whether the repository has any commits, and if it doesn't, it writes the first one the low-level way (blob → tree → parentless commit → branch ref) with your file already in it. The rest of the files then push normally. A 409 appearing mid-push triggers the same recovery rather than reporting a failure.

### GitHub profile

Tap your name and avatar at the top of the GitHub page:

- Your avatar, name, bio, company, location and website.
- **The green dots** — a full year of contributions, with the same five-step green scale GitHub uses, the year's total and your current streak. Point at (or tap) any square and a line above the graph reads out "12 contributions on Monday 21 September". This is the one thing the REST API can't do, so it comes from GitHub's GraphQL API and needs `read:user` on the token (included in the `user` scope the token link ticks for you).
- Repositories, followers, following and busiest day as tiles.
- **Edit profile** writes name, bio, company, location and website straight to github.com.
- **The profile picture** has a camera badge on the avatar. The web view puts up a real macOS open panel for GitHub's "Upload a photo…" button — a web view can't open one by itself, so without that the button silently does nothing. The JUNO portal got the same treatment, so assignment uploads there work too.
- **The profile picture** (how it works) GitHub has no API for avatars at all, so LifeTracker opens *their* settings page in a web view inside the app rather than throwing you out to Safari — set the picture, close the sheet, and the app reloads your profile. The web view keeps its own cookies, so you only sign in once.

### University portals — add whichever ones you use

The app assumes no university. Study → **University** opens a page that starts empty, with **Add portal** in the top right. Paste the address of the page you normally sign in on — JUNO, an ERP, Samarth, Moodle, a results page, a library — give it a name, colour and icon, and it becomes a card. Tap the card and the portal opens inside the app. One button in the browser toolbar takes you back to all of them. (There's a one-tap fill for DY Patil's JUNO in the Add sheet, as a convenience — not a default.)

Each portal keeps its own cookies, because the web view separates sessions by host, so two universities never sign each other out. **Sign out** clears only that portal's site. Removing a portal signs it out and deletes the card, but leaves its logins in the Keychain, so adding it back restores them.

**Plain http portals work.** Apple blocks http by default, and a lot of college ERPs are still http-only or start on https and redirect down to http — which is what "the resource could not be loaded because the App Transport Security policy requires the use of a secure connection" means. `LifeTracker/Info.plist` carries one exception, `NSAllowsArbitraryLoadsInWebContent`, which relaxes that rule **for web view content only**. Everything the app itself sends — the AI providers, GitHub, Google Drive and Calendar — is still https-only, because that key doesn't cover URLSession. On top of that, a portal whose https fails gets one automatic retry over http, and the Add sheet warns you when an address isn't https. (For an App Store submission this key needs a one-line justification at review: the app embeds university portals chosen by the user, many of which are http-only.)

One web view is reused as you move between portals rather than one per portal — swapping two web views in and out of the view hierarchy is what used to freeze the page, so the app navigates instead.

Everything the single-portal version did still applies to every portal you add. Toolbar: back / forward / reload / home, **Save page** (turns the current page — attendance, marks, result, fee receipt — into a PDF inside a subject's Files, and into Drive if connected), plus Open in browser, Copy link, All portals, and Sign out.

Downloads inside a portal (the ⤓ buttons — module PPTs, PDFs, zips…) are captured by the app: a progress pill shows in the toolbar and when it finishes you pick the subject to file it into. Files land in that subject's **Files** tab (and Drive, if connected) without ever passing through your Downloads folder.

Many portals open their documents through a pop-up window (`window.open` / `target="_blank"`). A web view with no window handler drops those clicks silently, so the portal view answers them itself and loads the file in place; blob and data URLs the page builds in memory are read out of the page and handed to Swift as bytes. If a file still opens in the viewer rather than downloading — a PDF preview, usually — use **⋯ → Save the file on screen**, which refetches it with the portal's own cookies. **Save page** falls back to that automatically when the page is already a PDF.

**ID & Pass** keeps as many logins as you like **per portal**, in the device Keychain — not in the database, and never written into a `.lifetracker` export unless you tick "include logins". Each one has Fill, copy-ID and copy-password buttons, edit and delete. Logins are keyed by the portal's host, so they follow the site rather than the card.

You don't have to open that sheet to use them: **tap any sign-in box on the portal and a strip appears over the page** with that portal's saved logins. One tap fills both boxes; the small copy button next to each name copies just the password for the odd field a page won't let anything type into. ✕ hides the strip until the next page.

LifeTracker does not read your marks or attendance automatically — these portals have no student API, so numbers are not scraped.

### Life AI — the assistant that floats over every page

A **draggable Life AI logo** sits on top of the whole app. It is not a page: it follows you across Today, Habits, Study, a subject, JUNO, the GitHub console — everywhere. Drag it anywhere on screen and it stays put (position is remembered per window size). Tap it, or press **⌘⇧L**, and the chat opens beside it, floating over whatever you were doing. Tap again to close.

The chat is a normal assistant first: write and debug code in any language, explain things, translate, do maths, answer ordinary questions. Code comes back in proper blocks with a language label and a **Copy** button. Replies stream in as they are written; **Stop** genuinely cancels the request.

On top of that it can see your data and act on it.

**What it can see.** Habits (with 30-day rates and what's due today), Schedule, Timetable for today and tomorrow, Subjects with syllabus progress / material lists / links, open study reminders, Calendar marks for the next 14 days plus anything overdue, Progress figures, and your GitHub summary if connected. All of it is assembled in one file, `Models/AIContext.swift` — that is the complete list of what leaves the device, so there is one place to read if you ever want to check.

**What it cannot see: the Journal.** Entries, moods, energy and the mood board are never read, never summarised, never sent. Ask it about the Journal and it says so rather than guessing.

**RAG over your own material.** Files you upload to a subject are read on the device — PDF via PDFKit, `.docx` and `.pptx` by unzipping the Office XML (`Zip` in `AIIndex.swift` — there is no zip reader in the system frameworks, so it walks the central directory itself and inflates with the Compression framework), plus plain text and code. The text is split into ~900-character passages and scored two ways when you ask something: a BM25 keyword score over tokens, which works in any language including Korean and Chinese, blended with Apple's on-device `NLEmbedding` sentence vectors where a model covers the language. No embedding service is called and no file is uploaded for this. The files an answer drew on are listed underneath it, down to the page or slide number.

**Attach any file to a question.** The paperclip in the composer takes anything — or drop a file straight onto the panel. PDF, Word, PowerPoint, text, code, CSV and JSON are read on the device and sent as text; images, and PDFs with no text in them (a scan, or slides exported as pictures), are sent as bytes for Gemini to look at directly. Each attachment shows a chip saying how it travelled — "3,200 words read on device", "sent as an image to look at", or honestly that it couldn't be read. Attach a file with no question and it summarises it.

**Summarise from Study.** Every file in a subject has a ✦ button, and the same three items in its right-click menu: **Summarise it**, **Explain it to me**, **Quiz me on it**. Any of them opens Life AI in a fresh chat with the file already attached and the question already asked.

**Save an answer into a subject.** Under every answer there is **Save to notes** — pick a subject and the whole answer is appended to its Notes under a dated heading, so saved summaries pile up in order instead of overwriting each other. Code blocks have their own **Save** for just that snippet, fenced and tagged. You can also just ask ("save that to my CV Lab notes") and it uses the same path itself.

**It can change things, but only add.** Seven tools: add a study reminder, a schedule block, a calendar mark (mirrored into Apple / Google Calendar like any other mark), a habit, a syllabus topic, or a note appended to a subject — and search your material. "Plan my week around my deadlines" creates the reminders rather than describing them. Every change shows as a green tick under the answer saying exactly what it did. It cannot delete or overwrite anything; the whole list of what it may do is `Models/LifeAIActions.swift`.

**Any AI you have a key for.** Life AI is not tied to one company. Settings → Life AI → Keys holds a row per provider — paste a key beside whichever you use and pick that row:

| | |
|---|---|
| **Google Gemini** | generous free tier, reads PDFs and images directly |
| **OpenAI** | GPT models |
| **Anthropic Claude** | strong at long documents and code |
| **xAI Grok** | Grok models |
| **Anything OpenAI-compatible** | DeepSeek, Groq, Mistral, OpenRouter, Together — or a local Ollama / LM Studio, where no key is needed at all |

Each provider keeps its own key and its own chosen model, so switching between them loses nothing. Everything else behaves identically whichever one answers: the same tools, the same attachments, the same RAG, the same save-to-notes.

Underneath there are only three shapes of request — Gemini's `parts` / `functionCall`, OpenAI's `messages` / `tool_calls`, and Anthropic's content blocks / `tool_use` — and `Models/AIWire.swift` translates the app's neutral types into each. Adding another provider means naming it in `AIProviders.swift`, not rewriting the client.

The model list is **not hard-coded**. Providers rename and retire models regularly, and a name that has gone produces a flat `404 … is not found`. So the app asks your key which models it can actually use, offers exactly those under ⋯ → Model (and in Settings), and sorts the cheap ones first. If a request still fails that way — the model went away mid-session — it re-reads the list, switches to one that exists and retries the same question once. Errors show the provider's own wording rather than a guess.

Keys live in the Keychain, never in the database, and travel with a `.lifetracker` export only when you tick "include logins".

### Talking to Life AI

The microphone button in the panel turns speech into text; right-click it (long-press on iPad) for **voice chat**, which is the whole loop: it listens, sends as soon as you stop talking, reads the answer back, and starts listening again until you turn it off. A spoken answer is written to be *heard* — short sentences, no headings, no bullet lists, no code read out symbol by symbol.

Every answer also has a **Listen** button, and ⋯ → *Read answers aloud* speaks every reply whether you typed it or said it.

Speech is Apple's, not a service: `SFSpeechRecognizer` for listening and `AVSpeechSynthesizer` for speaking, and recognition stays on the device wherever the language has an on-device model. The voice language is set in Settings → Life AI (English, 한국어, 中文, हिन्दी, मराठी, or whatever the device is set to), and when it's left on automatic the reply is read in whichever script it came back in — so a Korean answer isn't read with an English accent.

Needs the microphone and speech recognition permissions on first use; the Mac build asks for the `audio-input` hardened-runtime entitlement, which is in `LifeTracker.entitlements`.

Chat history is stored in SwiftData (`AIConversation` / `AIMessage`) with earlier chats under the ⋯ menu, and the indexed passages in `AIChunk`. All three are wiped by **Reset all data**, and deleting a file from a subject drops its passages straight away so the assistant can never quote a document you have deleted.
