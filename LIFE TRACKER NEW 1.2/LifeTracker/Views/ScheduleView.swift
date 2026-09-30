import SwiftUI
import SwiftData

struct ScheduleView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ScheduleItem.startTime) private var items: [ScheduleItem]
    @State private var editing: ScheduleItem?
    @State private var showingAdd = false

    var body: some View {
        Group {
            if items.isEmpty {
                EmptyState(icon: "clock",
                           title: "Nothing scheduled",
                           message: "Plan your day with a clean, quiet timeline.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        PageTitle(title: "Schedule", subtitle: "a clean, quiet timeline for your day")
                        SectionHeader(title: "Timeline",
                                      trailing: "\(items.count) items")
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                ScheduleRow(
                                    title: item.title,
                                    startTime: item.startTime,
                                    endTime: item.endTime,
                                    category: item.category,
                                    isCurrent: isCurrent(item),
                                    accentColor: Color(hex: item.colorHex)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { editing = item }
                                if item.id != items.last?.id {
                                    Divider().overlay(Palette.hairline)
                                }
                            }
                        }
                        .hairlineCard()
                    }
                    .pageContainer(maxWidth: 900)
                }
            }
        }
        .navigationTitle("Schedule")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAdd = true } label: {
                    Label("New Item", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) { ScheduleEditor(item: nil) }
        .sheet(item: $editing) { item in ScheduleEditor(item: item) }
    }

    private func isCurrent(_ item: ScheduleItem) -> Bool {
        let cal = Calendar.current
        let now = cal.dateComponents([.hour, .minute], from: .now)
        let s = cal.dateComponents([.hour, .minute], from: item.startTime)
        let e = cal.dateComponents([.hour, .minute], from: item.endTime)
        func m(_ c: DateComponents) -> Int { (c.hour ?? 0) * 60 + (c.minute ?? 0) }
        return m(s) <= m(now) && m(now) < m(e)
    }
}

struct ScheduleEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let item: ScheduleItem?

    @State private var title = ""
    @State private var start: Date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
    @State private var end: Date = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: .now) ?? .now
    @State private var category = "General"
    @State private var notes = ""
    @State private var colorHex = CategoryColorSwatches.hexValues[0]
    @State private var notify = true
    @State private var lead = 0
    @AppStorage("notificationsEnabled") private var notificationsEnabled: Bool = true

    private let categories = ["General", "Work", "Study", "Health", "Personal", "Meals", "Sleep"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item == nil ? "New Item" : "Edit Item").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                if item != nil {
                    Button("Delete", role: .destructive) { delete() }
                }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
            Divider().overlay(Palette.hairline)

            Form {
                FormTextField("Title", text: $title)
                DatePicker("Starts", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("Ends", selection: $end, displayedComponents: .hourAndMinute)
                Picker("Category", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Text("Color")
                    Spacer()
                    ColorSwatchButton(selection: $colorHex)
                }
                FormTextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                Section {
                    Toggle("Notify me", isOn: $notify)
                    if notify {
                        Picker("When", selection: $lead) {
                            Text("At start time").tag(0)
                            Text("5 minutes before").tag(5)
                            Text("10 minutes before").tag(10)
                            Text("15 minutes before").tag(15)
                            Text("30 minutes before").tag(30)
                            Text("1 hour before").tag(60)
                        }
                    }
                } footer: {
                    Text(notificationsEnabled
                         ? "Repeats every day on this Mac / iPad."
                         : "Notifications are turned off in Settings → Notifications.")
                }
            }
            .themedForm()
        }
        .sheetFrame(width: 460, height: 560)
        .onAppear {
            if let item {
                title = item.title
                start = item.startTime
                end = item.endTime
                category = item.category
                notes = item.notes
                colorHex = item.colorHex
                notify = item.reminderEnabled
                lead = item.reminderLeadMinutes ?? 0
            } else {
                colorHex = CategoryColorSwatches.hexValues.randomElement() ?? colorHex
            }
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let item {
            item.title = trimmed
            item.startTime = start
            item.endTime = end
            item.category = category
            item.notes = notes
            item.colorHex = colorHex
            item.reminderEnabled = notify
            item.reminderLeadMinutes = lead
        } else {
            let new = ScheduleItem(title: trimmed, startTime: start, endTime: end,
                                   category: category, notes: notes, reminderEnabled: notify, colorHex: colorHex)
            new.reminderLeadMinutes = lead
            context.insert(new)
        }
        try? context.save()
        if notify && notificationsEnabled {
            Task { await NotificationManager.shared.requestPermission() }
        }
        dismiss()
    }
    private func delete() {
        if let item {
            context.delete(item)
            try? context.save()
        }
        dismiss()
    }
}
