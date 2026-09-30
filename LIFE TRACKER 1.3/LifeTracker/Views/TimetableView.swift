import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct TimetableView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TimetableCategory.sortIndex) private var categories: [TimetableCategory]
    @Query private var slotsUnsorted: [TimetableSlot]
    @Query private var blocks: [TimetableBlock]
    @Query private var imageAssets: [TimetableImageAsset]

    @State private var blockEditorTarget: BlockEditorTarget?
    @State private var slotEditorTarget: SlotEditorTarget?
    @State private var managingCategories = false
    @State private var showingImporter = false
    @Environment(\.layoutWidth) private var width

    private struct BlockEditorTarget: Identifiable {
        let id = UUID()
        let block: TimetableBlock?
        let slot: TimetableSlot?
        let presetDay: Int?
    }
    private struct SlotEditorTarget: Identifiable {
        let id = UUID()
        let slot: TimetableSlot?
    }

    private let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private var slots: [TimetableSlot] {
        slotsUnsorted.sorted { $0.startTime < $1.startTime }
    }
    private var currentImage: TimetableImageAsset? { imageAssets.first }

    private func category(for id: UUID?) -> TimetableCategory? {
        guard let id else { return nil }
        return categories.first { $0.id == id }
    }
    private func block(day: Int, slot: TimetableSlot) -> TimetableBlock? {
        blocks.first { $0.day == day && $0.startTime == slot.startTime && $0.endTime == slot.endTime }
    }

    var body: some View {
        Group {
            if let image = currentImage {
                imageMode(image)
            } else {
                gridMode
            }
        }
        .navigationTitle("Timetable")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Group {
                    if currentImage == nil {
                        Button { showingImporter = true } label: {
                            Label("Upload Image", systemImage: "photo")
                        }
                        Button { managingCategories = true } label: {
                            Label("Categories", systemImage: "tag")
                        }
                        Button { slotEditorTarget = SlotEditorTarget(slot: nil) } label: {
                            Label("Add Time Slot", systemImage: "calendar.badge.plus")
                        }
                        Button {
                            guard let firstSlot = slots.first else {
                                slotEditorTarget = SlotEditorTarget(slot: nil)
                                return
                            }
                            blockEditorTarget = BlockEditorTarget(block: nil, slot: firstSlot, presetDay: 1)
                        } label: {
                            Label("New Block", systemImage: "plus")
                        }
                        .disabled(categories.isEmpty || slots.isEmpty)
                    }
                }
            }
        }
        .sheet(item: $blockEditorTarget) { target in
            TimetableBlockEditor(block: target.block, slot: target.slot, presetDay: target.presetDay)
        }
        .sheet(item: $slotEditorTarget) { target in
            TimetableSlotEditor(slot: target.slot)
        }
        .sheet(isPresented: $managingCategories) {
            CategoryManager()
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            // Replace any existing image (only one at a time).
            imageAssets.forEach { context.delete($0) }
            let asset = TimetableImageAsset(imageData: data)
            context.insert(asset)
            try? context.save()
            Task { await DriveSync.shared.backup(asset); try? context.save() }
        }
    }

    // MARK: - Image mode

    @ViewBuilder
    private func imageMode(_ asset: TimetableImageAsset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let img = PlatformImage(data: asset.imageData) {
                    Image(platformImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline))
                }
                HStack {
                    Button("Replace Image") { showingImporter = true }
                    Button("Remove & Use Grid") {
                        context.delete(asset)
                        try? context.save()
                    }
                    Spacer()
                }
            }
            .padding(AppLayout.pagePadding(width))
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Grid mode

    @ViewBuilder
    private var gridMode: some View {
        if slots.isEmpty {
            VStack(spacing: 16) {
                EmptyState(icon: "square.grid.3x3",
                           title: "Your timetable is empty",
                           message: "Add a time slot to lay down the grid, add categories to color it, then fill in blocks — all from scratch, your own way.",
                           fillsSpace: false)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { emptyActions }
                    VStack(spacing: 10) { emptyActions }
                }
                .padding(.top, 4)
            }
            .padding(AppLayout.pagePadding(width))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: -40)
        } else {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 20) {
                    if !categories.isEmpty { legend }
                    gridView
                }
                .padding(AppLayout.pagePadding(width))
            }
        }
    }

    @ViewBuilder
    private var emptyActions: some View {
        Button("Manage Categories") { managingCategories = true }
            .buttonStyle(.bordered)
        Button("Add Time Slot") { slotEditorTarget = SlotEditorTarget(slot: nil) }
            .buttonStyle(.borderedProminent)
        Button("Upload Image Instead") { showingImporter = true }
            .buttonStyle(.bordered)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(categories) { c in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: c.colorHex).opacity(0.35))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(hex: c.colorHex), lineWidth: 0.5))
                        .frame(width: 14, height: 14)
                    Text(c.name)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.mutedText)
                }
            }
        }
    }

    private var gridView: some View {
        let columnWidths: [CGFloat] = [80] + Array(repeating: 130, count: 7)

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                cell(text: "Time", width: columnWidths[0], header: true)
                ForEach(Array(dayLabels.enumerated()), id: \.offset) { i, label in
                    cell(text: label, width: columnWidths[i+1], header: true, weekend: i >= 5)
                }
            }
            ForEach(slots) { slot in
                HStack(spacing: 0) {
                    Button {
                        slotEditorTarget = SlotEditorTarget(slot: slot)
                    } label: {
                        VStack(spacing: 2) {
                            Text(slot.startTime).font(.system(size: 11, weight: .medium)).monospacedDigit()
                            Text(slot.endTime).font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.mutedText)
                        }
                        .frame(width: columnWidths[0], height: 62)
                        .overlay(Rectangle().strokeBorder(Palette.hairline, lineWidth: 0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    ForEach(1...7, id: \.self) { day in
                        blockCell(block: block(day: day, slot: slot), day: day, slot: slot,
                                  width: columnWidths[day], weekend: day >= 6)
                    }
                }
            }
        }
        .background(Palette.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))
    }

    private func cell(text: String, width: CGFloat, header: Bool, weekend: Bool = false) -> some View {
        Text(text)
            .font(.system(size: header ? 11 : 12, weight: header ? .semibold : .regular))
            .tracking(header ? 0.5 : 0)
            .foregroundStyle(header ? Palette.mutedText : .primary)
            .frame(width: width, height: 34)
            .background(weekend ? Palette.subtleFill : Color.clear)
            .overlay(Rectangle().strokeBorder(Palette.hairline, lineWidth: 0.5))
    }

    @ViewBuilder
    private func blockCell(block: TimetableBlock?, day: Int, slot: TimetableSlot, width: CGFloat, weekend: Bool) -> some View {
        Button {
            if let block {
                blockEditorTarget = BlockEditorTarget(block: block, slot: slot, presetDay: nil)
            } else if !categories.isEmpty {
                blockEditorTarget = BlockEditorTarget(block: nil, slot: slot, presetDay: day)
            } else {
                managingCategories = true
            }
        } label: {
            ZStack {
                if let block {
                    Rectangle().fill(category(for: block.categoryID).map { Color(hex: $0.colorHex).opacity(0.28) } ?? Palette.subtleFill)
                    Text(block.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 4)
                } else {
                    Rectangle().fill(weekend ? Palette.subtleFill : Color.clear)
                }
            }
            .frame(width: width, height: 62)
            .overlay(Rectangle().strokeBorder(Palette.hairline, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Slot editor (defines a grid row, no content)

struct TimetableSlotEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allSlots: [TimetableSlot]

    let slot: TimetableSlot?

    @State private var start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
    @State private var end = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: .now) ?? .now
    @State private var showDuplicateError = false

    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(slot == nil ? "Add Time Slot" : "Edit Time Slot").font(.headline)
                Spacer()
                if slot != nil {
                    Button("Delete Row", role: .destructive) { delete() }
                }
                Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider().overlay(Palette.hairline)

            VStack(alignment: .leading, spacing: 12) {
                Text("This defines a row in your timetable grid — the time range, nothing else. You'll fill in what happens during it per day.")
                    .font(.caption)
                    .foregroundStyle(Palette.mutedText)
                DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("End", selection: $end, displayedComponents: .hourAndMinute)
                if showDuplicateError {
                    Text("This time slot already exists.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
        .sheetFrame(width: 420, height: 280)
        .onAppear {
            if let slot {
                start = Self.fmt.date(from: slot.startTime) ?? start
                end = Self.fmt.date(from: slot.endTime) ?? end
            }
        }
        .onChange(of: start) { _, _ in showDuplicateError = false }
        .onChange(of: end) { _, _ in showDuplicateError = false }
    }

    private func save() {
        let s = Self.fmt.string(from: start)
        let e = Self.fmt.string(from: end)
        let isDuplicate = allSlots.contains { existing in
            existing.startTime == s && existing.endTime == e && existing.id != slot?.id
        }
        guard !isDuplicate else {
            showDuplicateError = true
            return
        }
        if let slot {
            // Re-point any blocks filed under the old times to the new times.
            let old = (slot.startTime, slot.endTime)
            let descriptor = FetchDescriptor<TimetableBlock>()
            if let allBlocks = try? context.fetch(descriptor) {
                for b in allBlocks where b.startTime == old.0 && b.endTime == old.1 {
                    b.startTime = s; b.endTime = e
                }
            }
            slot.startTime = s
            slot.endTime = e
        } else {
            context.insert(TimetableSlot(startTime: s, endTime: e))
        }
        try? context.save()
        dismiss()
    }
    private func delete() {
        guard let slot else { return }
        let descriptor = FetchDescriptor<TimetableBlock>()
        if let allBlocks = try? context.fetch(descriptor) {
            for b in allBlocks where b.startTime == slot.startTime && b.endTime == slot.endTime {
                context.delete(b)
            }
        }
        context.delete(slot)
        try? context.save()
        dismiss()
    }
}

// MARK: - Block editor (content for one day × one time slot)

struct TimetableBlockEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \TimetableCategory.sortIndex) private var categories: [TimetableCategory]
    @Query private var slotsUnsorted: [TimetableSlot]

    let block: TimetableBlock?
    let slot: TimetableSlot?
    let presetDay: Int?

    @State private var title = ""
    @State private var day = 1
    @State private var selectedSlotID: UUID?
    @State private var categoryID: UUID?

    private let dayLabels = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
    private var slots: [TimetableSlot] { slotsUnsorted.sorted { $0.startTime < $1.startTime } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(block == nil ? "New Block" : "Edit Block").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                if block != nil {
                    Button("Delete", role: .destructive) { delete() }
                }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || categoryID == nil || selectedSlotID == nil)
            }
            .padding()
            Divider().overlay(Palette.hairline)

            if categories.isEmpty {
                centeredMessage("Create a category first.", "Categories are entirely up to you — add whatever fits your week.")
            } else if slots.isEmpty {
                centeredMessage("Add a time slot first.", "Time slots define the rows of your grid before you fill in content.")
            } else {
                Form {
                    FormTextField("Title", text: $title)
                    Picker("Day", selection: $day) {
                        ForEach(1...7, id: \.self) { d in Text(dayLabels[d-1]).tag(d) }
                    }
                    Picker("Time slot", selection: $selectedSlotID) {
                        ForEach(slots) { s in
                            Text("\(s.startTime) – \(s.endTime)").tag(s.id as UUID?)
                        }
                    }
                    Picker("Category", selection: $categoryID) {
                        ForEach(categories) { c in
                            Text(categoryLabel(c))
                                .tag(c.id as UUID?)
                        }
                    }
                }
                .themedForm()
            }
        }
        .sheetFrame(width: 460, height: 420)
        .onAppear {
            if let block {
                title = block.title
                day = block.day
                selectedSlotID = slots.first { $0.startTime == block.startTime && $0.endTime == block.endTime }?.id
                categoryID = block.categoryID
            } else {
                if let presetDay { day = presetDay }
                selectedSlotID = slot?.id ?? slots.first?.id
                categoryID = categories.first?.id
            }
        }
    }

    private func categoryLabel(_ c: TimetableCategory) -> AttributedString {
        var dot = AttributedString("● ")
        dot.foregroundColor = Color(hex: c.colorHex)
        return dot + AttributedString(c.name)
    }

    private func centeredMessage(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title).foregroundStyle(Palette.mutedText)
            Text(subtitle).font(.caption).foregroundStyle(Palette.mutedText).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let categoryID,
              let chosenSlot = slots.first(where: { $0.id == selectedSlotID }) else { return }
        if let block {
            block.title = trimmed
            block.day = day
            block.startTime = chosenSlot.startTime
            block.endTime = chosenSlot.endTime
            block.categoryID = categoryID
        } else {
            context.insert(TimetableBlock(day: day, startTime: chosenSlot.startTime, endTime: chosenSlot.endTime,
                                          title: trimmed, categoryID: categoryID))
        }
        try? context.save()
        dismiss()
    }
    private func delete() {
        if let block { context.delete(block); try? context.save() }
        dismiss()
    }
}

// MARK: - Category manager

struct CategoryManager: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \TimetableCategory.sortIndex) private var categories: [TimetableCategory]

    @State private var newName = ""
    @State private var newColorHex = CategoryColorSwatches.hexValues[0]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Categories").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider().overlay(Palette.hairline)

            List {
                ForEach(categories) { category in
                    CategoryRow(category: category)
                }
                .onDelete { indexSet in
                    for i in indexSet { context.delete(categories[i]) }
                    try? context.save()
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 160, maxHeight: 260)

            Divider().overlay(Palette.hairline)

            VStack(alignment: .leading, spacing: 10) {
                Text("Add category").font(.subheadline).fontWeight(.medium)
                HStack(spacing: 10) {
                    TextField("Name", text: $newName)
                    ColorSwatchButton(selection: $newColorHex)
                    Button("Add") { addCategory() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("\(CategoryColorSwatches.hexValues.count) colors to choose from — pick any, for any category you make.")
                    .font(.caption)
                    .foregroundStyle(Palette.mutedText)
            }
            .padding()
        }
        .sheetFrame(width: 460, height: 500)
    }

    private func addCategory() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let cat = TimetableCategory(name: trimmed, colorHex: newColorHex, sortIndex: categories.count)
        context.insert(cat)
        try? context.save()
        newName = ""
        newColorHex = CategoryColorSwatches.hexValues.randomElement() ?? newColorHex
    }
}

private struct CategoryRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var category: TimetableCategory

    var body: some View {
        HStack(spacing: 12) {
            ColorSwatchButton(selection: Binding(
                get: { category.colorHex },
                set: { category.colorHex = $0; try? context.save() }
            ))
            TextField("Name", text: Binding(
                get: { category.name },
                set: { category.name = $0 }
            ))
            .onSubmit { try? context.save() }
        }
        .padding(.vertical, 4)
    }
}
