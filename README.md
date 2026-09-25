# LifeTracker

**LifeTracker** is a SwiftUI productivity and study-management app designed to bring your daily schedule, habits, study planning, university resources, journaling, and progress tracking into one place.

The project is built as a native Apple-platform application and supports **iPadOS and macOS**, with a shared WidgetKit extension.

## ✨ Features

### 📅 Today Dashboard
- Daily overview of your schedule and tasks
- Habit progress and completion tracking
- Daily progress information
- Rotating motivational quotes
- Quick access to important parts of your routine

### ✅ Habit Tracking
- Create and manage habits
- Mark habits as completed
- Track completion history
- View monthly habit progress
- Visualize habit consistency over time

### 🗓️ Timetable & Schedule
- Build a personal timetable
- Create timetable categories and time blocks
- Add scheduled activities
- Track scheduled items and completion
- Support for timetable images

### 📚 Study Management
- Create study subjects
- Organize syllabus topics
- Add study materials
- Save useful study links
- Manage study-related todos
- Keep academic resources organized in one place

### 🎓 University Section
- Dedicated university-related workspace
- Access university resources and web portals
- Organize information useful for university life

### 📓 Journal
- Store journal entries
- Keep personal notes associated with your daily workflow

### 📊 Progress Tracking
- Track daily and monthly completion
- Monitor active days
- View progress across habits and scheduled activities
- Progress calculations are handled by the app's `ProgressEngine`

### 💻 GitHub Integration
The app contains a GitHub workspace with functionality for:
- GitHub account connection
- Profile information
- Repository browsing
- Repository details
- File browsing
- Text-file editing
- Creating repositories
- Creating releases
- GitHub-related synchronization

> GitHub functionality requires the appropriate authentication/configuration in the project.

### ☁️ Google Drive & Calendar Integration
The project includes synchronization support for:
- Google Drive
- Calendar events

Calendar functionality also integrates with Apple's Calendar/EventKit on supported macOS configurations.

> External-service features require the appropriate credentials, permissions, and configuration.

### 🔔 Notifications
LifeTracker includes a notification/reminder system for scheduled reminders and app activities.

### 🧩 Widgets
The project includes a WidgetKit extension with three widgets:

- **Quote Widget** — displays rotating motivational quotes.
- **Timetable Widget** — provides quick access to timetable information.
- **Habits Month Widget** — shows monthly habit progress.

Widgets communicate with the main app through the shared App Group:

`group.com.pranavpande.LifeTracker`

### 🎨 Appearance
- Light Mode
- Dark Mode
- System appearance
- Warm cream / latte / cocoa visual design
- Shared design system across the main app and widgets

## 🛠️ Technology Stack

- **Swift**
- **SwiftUI**
- **SwiftData**
- **WidgetKit**
- **EventKit / Apple Calendar integration**
- **UserNotifications**
- **Keychain Services**
- **App Groups**
- **GitHub API integration**
- **Google Drive / Calendar integration**
- Native Apple platform frameworks

The project uses Swift language mode **5.0**.

## 📱 Supported Platforms

| Platform | Minimum Version |
|---|---|
| iPadOS / iOS | 17.0 |
| macOS | 14.0 |

The application is implemented with platform-specific SwiftUI support so that the same project can target both iPadOS and macOS.

## 📁 Project Structure

```text
LifeTracker/
├── LifeTrackerApp.swift
│
├── Models/
│   ├── Models.swift
│   ├── Accounts.swift
│   ├── CalendarSync.swift
│   ├── DriveSync.swift
│   ├── GitHubSync.swift
│   ├── Notifications.swift
│   ├── Quotes.swift
│   ├── Transfer.swift
│   └── WidgetBridge.swift
│
├── Views/
│   ├── ContentView.swift
│   ├── TodayView.swift
│   ├── HabitsView.swift
│   ├── TimetableView.swift
│   ├── ScheduleView.swift
│   ├── StudyView.swift
│   ├── UniversityView.swift
│   ├── GitHubView.swift
│   ├── AccountViews.swift
│   ├── LoginView.swift
│   └── OtherViews.swift
│
├── Components/
│   ├── Components.swift
│   └── DesignSystem.swift
│
├── Shared/
│   └── WidgetShared.swift
│
├── Assets.xcassets/
│
└── LifeTrackerWidgets/
    ├── LifeTrackerWidgets.swift
    ├── LifeTrackerWidgets-iOS.entitlements
    ├── LifeTrackerWidgets-macOS.entitlements
    └── Info.plist
```

## 🚀 Getting Started

### Requirements

You need:

- A Mac
- Xcode
- An Apple ID for development/signing
- A compatible iPad/iPhone or Mac for testing
- Required API credentials if you want to use external integrations

### 1. Clone or download the project

```bash
git clone <YOUR_REPOSITORY_URL>
cd LifeTracker
```

Or download the repository ZIP and open the project manually.

### 2. Open the project

Open:

```text
LifeTracker/LifeTracker.xcodeproj
```

in Xcode.

### 3. Select a target

From Xcode's device/scheme selector, choose a supported destination:

- iPad Simulator
- Connected iPad
- My Mac

The shared scheme is:

```text
LifeTracker
```

### 4. Configure signing

In Xcode:

1. Select the **LifeTracker** project.
2. Select the application target.
3. Open **Signing & Capabilities**.
4. Select your Apple Developer team.
5. Make sure the Bundle Identifier is unique for your account if you are using your own signing profile.

The project currently uses:

```text
com.pranavpande.LifeTracker
```

The widget target uses:

```text
com.pranavpande.LifeTracker.Widgets
```

### 5. Configure App Groups

The main app and widget extension use:

```text
group.com.pranavpande.LifeTracker
```

Make sure this App Group is available to your development team when configuring your own signing setup.

It is used to share widget data between the main app and WidgetKit extension.

### 6. Build and run

Press:

```text
⌘ + R
```

in Xcode.

Choose either an iPad destination or **My Mac**.

## 🔐 Permissions & Integrations

Some functionality depends on Apple or third-party services.

### Apple Calendar

macOS uses the Calendar/EventKit permission:

```text
com.apple.security.personal-information.calendars
```

The user may need to grant Calendar access when prompted.

### Notifications

Notification permissions are requested for reminder-related functionality.

### Google Services

Google Drive and Calendar functionality requires appropriate Google authentication/configuration. Credentials should not be committed to a public repository.

### GitHub

GitHub functionality requires appropriate authentication. Do not commit personal access tokens, secrets, or private credentials.

## 🗄️ Data Model

LifeTracker uses **SwiftData** for local application data.

The current model includes entities for:

- Habits
- Habit completions
- Schedule items
- Schedule completions
- Timetable categories
- Timetable slots
- Timetable blocks
- Timetable image assets
- Calendar marks
- Journal entries
- Study subjects
- Syllabus topics
- Study materials
- Study links
- Study todos
- Mood-board images

This allows the app to maintain a structured local productivity and study database.

## 🔄 Widget Data Sharing

The main application communicates with its WidgetKit extension using an App Group container.

The widget bridge stores shared data such as:

- Daily progress
- Monthly habit progress
- Timetable blocks
- User name
- Timetable image availability

Shared files include:

```text
widget-snapshot.json
timetable.jpg
```

## 🧑‍💻 Development Notes

### SwiftUI

The UI is written primarily in SwiftUI, allowing the project to share interface logic across Apple platforms while using platform-specific APIs where necessary.

### SwiftData

SwiftData provides the persistent local data layer.

### Design System

The project has a centralized design system in:

```text
Components/DesignSystem.swift
```

It defines the application's visual palette, typography, appearance modes, and shared UI styling.

### Platform-specific code

The project uses conditional compilation such as:

```swift
#if os(macOS)
    // macOS implementation
#else
    // iPadOS / iOS implementation
#endif
```

This allows platform-specific APIs such as AppKit and UIKit to coexist in the same project.

## 🔒 Security

Never commit the following to a public repository:

- API keys
- GitHub access tokens
- Google OAuth secrets
- Private credentials
- Personal authentication data

If credentials have ever been committed accidentally, revoke and regenerate them before making the repository public.

## 📦 Building for Distribution

For personal testing, you can run the app directly from Xcode.

For distributing the app to other users, the appropriate Apple distribution method is required. Depending on the target and audience, this may include:

- TestFlight
- App Store distribution
- Ad Hoc distribution where applicable
- Direct macOS distribution with appropriate signing/notarization

A user cannot generally install an arbitrary unsigned iPadOS `.app` simply by downloading it from GitHub. iPadOS distribution needs to follow Apple's supported signing/distribution mechanisms.

## 🧪 Testing

Recommended testing destinations:

### iPadOS

Test:

- Touch interaction
- Portrait/landscape layouts
- Widgets
- Notifications
- Calendar/Drive integrations
- Data persistence

### macOS

Test:

- Window resizing
- Sidebar/navigation
- Keyboard and mouse interaction
- Settings window
- Calendar permissions
- Widgets
- External integrations

## 🗺️ Roadmap Ideas

Possible future improvements include:

- iCloud synchronization
- More widget sizes
- Cross-device data synchronization
- More detailed analytics
- Advanced study statistics
- Additional calendar providers
- Improved onboarding
- Cloud backup and restore
- More customization options

## 📄 License

Add your preferred license here before publishing the project publicly.

Example:

```text
Copyright © 2026 Pranav Pande.

All rights reserved.
```

## 👤 Author

**Pranav Pande**

LifeTracker is a personal productivity, study, timetable, and habit-tracking application built with SwiftUI for Apple's ecosystem.
