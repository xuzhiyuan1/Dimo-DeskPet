import AppKit
import Combine
import SwiftUI

private enum TodoPeriod: String, Codable, CaseIterable, Identifiable {
    case morning
    case afternoon
    case evening

    var id: String { rawValue }

    var title: String {
        switch self {
        case .morning: return "上午"
        case .afternoon: return "下午"
        case .evening: return "晚上"
        }
    }

    var sortOrder: Int {
        switch self {
        case .morning: return 0
        case .afternoon: return 1
        case .evening: return 2
        }
    }
}

private struct TodoItem: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var done: Bool
    var dueAt: Date
    var period: TodoPeriod?
    var remindAt: Date?

    init(
        id: UUID = UUID(),
        text: String,
        done: Bool = false,
        dueAt: Date,
        period: TodoPeriod? = nil,
        remindAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.done = done
        self.dueAt = dueAt
        self.period = period
        self.remindAt = remindAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, done, dueAt, period, remindAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        done = try container.decode(Bool.self, forKey: .done)
        dueAt = try container.decode(Date.self, forKey: .dueAt)
        period = try container.decodeIfPresent(TodoPeriod.self, forKey: .period)
        remindAt = try container.decodeIfPresent(Date.self, forKey: .remindAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(done, forKey: .done)
        try container.encode(dueAt, forKey: .dueAt)
        try container.encodeIfPresent(period, forKey: .period)
        try container.encodeIfPresent(remindAt, forKey: .remindAt)
    }
}

private struct LegacyTodoItem: Codable {
    let id: UUID
    var text: String
    var done: Bool
}

private struct TodoDayGroup: Identifiable {
    let day: Date
    let items: [TodoItem]
    var id: Date { day }
}

private func dimoImage() -> NSImage {
    guard let url = Bundle.main.url(forResource: "dimo-watercolor", withExtension: "png"),
          let image = NSImage(contentsOf: url) else {
        return NSImage(size: NSSize(width: 180, height: 180))
    }
    return image
}

@MainActor
private final class PetModel: ObservableObject {
    @Published var todos: [TodoItem] = [] {
        didSet { persistIfReady() }
    }
    @Published var panelOpen = false
    @Published private var reminderTick = Date()

    private var ready = false
    private let defaults = UserDefaults.standard
    private let storageKey = "dimo.todos.all"

    init() {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([TodoItem].self, from: data) {
            todos = normalizeStoredTodos(decoded)
        } else {
            todos = migrateLegacyTodos()
            if todos.isEmpty { todos = starterTodos() }
        }

        ready = true
        persistIfReady()
    }

    var completedCount: Int {
        todos.filter(\.done).count
    }

    var todayTodos: [TodoItem] {
        todos.filter { Calendar.current.isDateInToday($0.dueAt) }
    }

    var todayCompletedCount: Int {
        todayTodos.filter(\.done).count
    }

    var progress: Double {
        todayTodos.isEmpty ? 0 : Double(todayCompletedCount) / Double(todayTodos.count)
    }

    var mood: String {
        if todayTodos.isEmpty { return "今天暂时空闲，看看接下来的安排吧" }
        if todayCompletedCount == todayTodos.count { return "今天的你闪闪发光！" }
        if todayCompletedCount > 0 { return "今天已完成 \(todayCompletedCount) 件，继续加油" }
        return "从今天最重要的一件事开始吧"
    }

    var dayGroups: [TodoDayGroup] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let grouped = Dictionary(grouping: todos) { calendar.startOfDay(for: $0.dueAt) }
        let orderedDays = grouped.keys.sorted { lhs, rhs in
            if lhs == today { return true }
            if rhs == today { return false }
            let lhsPast = lhs < today
            let rhsPast = rhs < today
            if lhsPast != rhsPast { return lhsPast }
            return lhsPast ? lhs > rhs : lhs < rhs
        }

        return orderedDays.map { day in
            TodoDayGroup(day: day, items: (grouped[day] ?? []).sorted {
                let lhsOrder = $0.period?.sortOrder ?? 3
                let rhsOrder = $1.period?.sortOrder ?? 3
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return $0.text.localizedStandardCompare($1.text) == .orderedAscending
            })
        }
    }

    var activeReminders: [TodoItem] {
        let now = reminderTick
        return todos
            .filter { !$0.done && ($0.remindAt ?? .distantFuture) <= now }
            .sorted { ($0.remindAt ?? .distantFuture) < ($1.remindAt ?? .distantFuture) }
    }

    func refreshReminderState() {
        reminderTick = Date()
    }

    func add(_ text: String, dueAt: Date, period: TodoPeriod?, remindAt: Date?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        todos.append(TodoItem(
            text: trimmed,
            dueAt: Calendar.current.startOfDay(for: dueAt),
            period: period,
            remindAt: remindAt
        ))
    }

    func update(_ id: UUID, text: String, dueAt: Date, period: TodoPeriod?, remindAt: Date?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].text = trimmed
        todos[index].dueAt = Calendar.current.startOfDay(for: dueAt)
        todos[index].period = period
        todos[index].remindAt = todos[index].done ? nil : remindAt
    }

    func toggle(_ id: UUID) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].done.toggle()
        if todos[index].done {
            todos[index].remindAt = nil
        }
    }

    func complete(_ id: UUID) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].done = true
        todos[index].remindAt = nil
    }

    func postponeReminder(_ id: UUID, until date: Date) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].remindAt = date
    }

    func remove(_ id: UUID) {
        todos.removeAll { $0.id == id }
    }

    func clearCompleted() {
        todos.removeAll { $0.done }
    }

    private func persistIfReady() {
        guard ready else { return }
        if let data = try? JSONEncoder().encode(todos) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func migrateLegacyTodos() -> [TodoItem] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        var migrated: [TodoItem] = []

        for key in defaults.dictionaryRepresentation().keys.sorted() where key.hasPrefix("dimo.todos.") {
            let suffix = String(key.dropFirst("dimo.todos.".count))
            guard let day = formatter.date(from: suffix),
                  let data = defaults.data(forKey: key),
                  let legacy = try? JSONDecoder().decode([LegacyTodoItem].self, from: data) else { continue }

            for (index, item) in legacy.enumerated() {
                let periods: [TodoPeriod] = [.morning, .afternoon, .evening]
                migrated.append(TodoItem(
                    id: item.id,
                    text: item.text,
                    done: item.done,
                    dueAt: calendar.startOfDay(for: day),
                    period: periods[min(index, periods.count - 1)]
                ))
            }
        }
        return migrated
    }

    private func starterTodos() -> [TodoItem] {
        let calendar = Calendar.current
        let today = Date()
        let day = calendar.startOfDay(for: today)
        return [
            TodoItem(text: "写下今天最重要的一件事", dueAt: day, period: .morning),
            TodoItem(text: "起来走走，记得喝水", dueAt: day, period: .afternoon),
            TodoItem(text: "给自己留一点休息时间", dueAt: day, period: .evening),
        ]
    }

    private func normalizeStoredTodos(_ items: [TodoItem]) -> [TodoItem] {
        let calendar = Calendar.current
        return items.map { item in
            var normalized = item
            let start = calendar.startOfDay(for: item.dueAt)
            if normalized.period == nil && item.dueAt.timeIntervalSince(start) >= 60 {
                let hour = calendar.component(.hour, from: item.dueAt)
                normalized.period = hour < 12 ? .morning : (hour < 18 ? .afternoon : .evening)
            }
            normalized.dueAt = start
            return normalized
        }
    }
}

private struct TodoPanelView: View {
    @ObservedObject var model: PetModel
    let close: () -> Void
    @State private var draft = ""
    @State private var draftDueDate = Date()
    @State private var draftPeriod: TodoPeriod?
    @State private var draftReminderEnabled = false
    @State private var draftReminderAt = Date().addingTimeInterval(10 * 60)
    @State private var showingDatePicker = false
    @State private var composerExpanded = false
    @State private var referenceDate = Date()
    @State private var calendarMonth = Calendar.current.date(
        from: Calendar.current.dateComponents([.year, .month], from: Date())
    ) ?? Date()
    @FocusState private var inputFocused: Bool
    private let dayRefreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var allowedDates: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    private var quickDates: [Date] {
        Array(allowedDates.prefix(3))
    }

    private var isOtherDateSelected: Bool {
        !quickDates.contains { Calendar.current.isDate(draftDueDate, inSameDayAs: $0) }
    }

    private var dateParts: (day: String, month: String, weekday: String) {
        let date = referenceDate
        let day = Calendar.current.component(.day, from: date)
        let month = Calendar.current.component(.month, from: date)
        let year = Calendar.current.component(.year, from: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEE"
        return (String(format: "%02d", day), "\(year) · \(month)月", formatter.string(from: date))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Text(dateParts.day)
                    .font(.system(size: 54, weight: .regular, design: .serif))
                    .foregroundStyle(Color(red: 0.20, green: 0.35, blue: 0.67))
                    .tracking(-3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(dateParts.month)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Color(red: 0.48, green: 0.52, blue: 0.62))
                    Text(dateParts.weekday)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color(red: 0.15, green: 0.20, blue: 0.32))
                }

                Spacer()

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.48, green: 0.52, blue: 0.62))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color(red: 0.94, green: 0.95, blue: 0.98)))
                }
                .buttonStyle(.plain)
                .help("收起清单")
            }
            .padding(.bottom, 17)

            Divider().opacity(0.65)

            HStack {
                Text(model.mood)
                Spacer()
                Text("\(Int((model.progress * 100).rounded()))%")
                    .fontWeight(.bold)
                    .foregroundStyle(Color(red: 0.25, green: 0.37, blue: 0.67))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(red: 0.47, green: 0.51, blue: 0.61))
            .padding(.top, 15)
            .padding(.bottom, 7)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(red: 0.91, green: 0.93, blue: 0.96))
                    Capsule()
                        .fill(Color(red: 0.31, green: 0.46, blue: 0.75))
                        .frame(width: max(0, proxy.size.width * model.progress))
                }
            }
            .frame(height: 5)

            VStack(spacing: 6) {
                Button(action: toggleComposer) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(red: 0.31, green: 0.44, blue: 0.72))
                        Text("新增任务")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(red: 0.31, green: 0.35, blue: 0.46))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(red: 0.53, green: 0.57, blue: 0.66))
                            .rotationEffect(.degrees(composerExpanded ? 180 : 0))
                    }
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(composerExpanded ? "收起新增任务" : "展开新增任务")

                if composerExpanded {
                    Divider().opacity(0.45)

                    HStack(spacing: 10) {
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3]))
                            .foregroundStyle(Color(red: 0.57, green: 0.63, blue: 0.75))
                            .frame(width: 20, height: 20)

                        TextField("添加一件近期要做的事…", text: $draft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($inputFocused)
                            .onSubmit(addTodo)

                        Button(action: addTodo) {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.31, green: 0.44, blue: 0.72)))
                        }
                        .buttonStyle(.plain)
                    }

                    Divider().opacity(0.45)

                    HStack(spacing: 7) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.39, green: 0.49, blue: 0.70))
                        .frame(width: 14, height: 14)
                    Text("日期")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.48, green: 0.52, blue: 0.62))
                        .frame(width: 28, alignment: .leading)
                    Spacer(minLength: 6)

                    HStack(spacing: 2) {
                        ForEach(Array(quickDates.enumerated()), id: \.element) { index, date in
                            let selected = Calendar.current.isDate(draftDueDate, inSameDayAs: date)
                            Button {
                                draftDueDate = date
                            } label: {
                                segmentLabel(
                                    ["今", "明·\(weekdayLabel(date))", "后·\(weekdayLabel(date))"][index],
                                    selected: selected
                                )
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(dateAccessibilityLabel(date, isToday: index == 0))
                            .accessibilityValue(selected ? "已选择" : "")
                        }

                        Button {
                            calendarMonth = startOfMonth(draftDueDate)
                            showingDatePicker.toggle()
                        } label: {
                            segmentLabel("更多", selected: isOtherDateSelected, showsChevron: true)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("选择其他日期")
                        .popover(isPresented: $showingDatePicker, arrowEdge: .bottom) {
                            VStack(spacing: 10) {
                                HStack {
                                    Button {
                                        moveCalendarMonth(by: -1)
                                    } label: {
                                        Image(systemName: "chevron.left")
                                            .frame(width: 26, height: 26)
                                    }
                                    .buttonStyle(.plain)

                                    Spacer()

                                    Text(calendarMonthTitle)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(Color(red: 0.25, green: 0.37, blue: 0.67))

                                    Spacer()

                                    Button {
                                        moveCalendarMonth(by: 1)
                                    } label: {
                                        Image(systemName: "chevron.right")
                                            .frame(width: 26, height: 26)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .foregroundStyle(Color(red: 0.43, green: 0.48, blue: 0.59))

                                HStack(spacing: 0) {
                                    ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { weekday in
                                        Text(weekday)
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(Color(red: 0.57, green: 0.60, blue: 0.68))
                                            .frame(maxWidth: .infinity)
                                    }
                                }

                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 4) {
                                    ForEach(Array(calendarGridDates.enumerated()), id: \.offset) { _, date in
                                        if let date {
                                            let selected = Calendar.current.isDate(date, inSameDayAs: draftDueDate)
                                            let today = Calendar.current.isDateInToday(date)
                                            Button {
                                                draftDueDate = date
                                                showingDatePicker = false
                                            } label: {
                                                Text(String(Calendar.current.component(.day, from: date)))
                                                    .font(.system(size: 10, weight: selected ? .bold : .medium))
                                                    .foregroundStyle(selected ? Color.white : Color(red: 0.31, green: 0.35, blue: 0.44))
                                                    .frame(width: 25, height: 25)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 7)
                                                            .fill(
                                                                selected
                                                                    ? Color(red: 0.31, green: 0.44, blue: 0.72)
                                                                    : (today ? Color(red: 0.88, green: 0.91, blue: 0.97) : Color.clear)
                                                            )
                                                    )
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel(calendarDateLabel(date))
                                        } else {
                                            Color.clear.frame(width: 25, height: 25)
                                        }
                                    }
                                }
                            }
                            .padding(13)
                            .frame(width: 236)
                            .background(Color(red: 0.985, green: 0.982, blue: 0.965))
                        }
                    }
                    .frame(width: 220)
                    .padding(3)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.62))
                    )
                }
                    .padding(.leading, 1)
                    .padding(.trailing, 5)

                    HStack(spacing: 7) {
                    Image(systemName: "sun.horizon")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.39, green: 0.49, blue: 0.70))
                        .frame(width: 14, height: 14)
                    Text("时段")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.48, green: 0.52, blue: 0.62))
                        .frame(width: 28, alignment: .leading)
                    Spacer(minLength: 6)

                    HStack(spacing: 2) {
                        Button {
                            draftPeriod = nil
                        } label: {
                            segmentLabel("不选", selected: draftPeriod == nil)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)

                        ForEach(TodoPeriod.allCases) { period in
                            Button {
                                draftPeriod = period
                            } label: {
                                segmentLabel(period.title, selected: draftPeriod == period)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(width: 220)
                    .padding(3)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.62))
                    )
                }
                    .padding(.leading, 1)
                    .padding(.trailing, 5)

                    Divider().opacity(0.45)

                    HStack(spacing: 7) {
                        Image(systemName: "bell")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.39, green: 0.49, blue: 0.70))
                            .frame(width: 14, height: 14)
                        Text("提醒")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(red: 0.48, green: 0.52, blue: 0.62))
                            .frame(width: 28, alignment: .leading)
                        Spacer()
                        Toggle("", isOn: $draftReminderEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 4)

                    if draftReminderEnabled {
                        HStack(spacing: 7) {
                            Image(systemName: "clock")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 0.39, green: 0.49, blue: 0.70))
                                .frame(width: 14, height: 14)
                            Text("时间")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color(red: 0.48, green: 0.52, blue: 0.62))
                                .frame(width: 28, alignment: .leading)
                            Spacer()
                            DimoDateTimePicker(selection: $draftReminderAt)
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
            .padding(.leading, 11)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.95, green: 0.96, blue: 0.98)))
            .padding(.top, 18)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(model.dayGroups) { group in
                        dayHeader(group)
                        ForEach(group.items) { todo in
                            todoRow(todo)
                        }
                    }

                    if model.todos.isEmpty {
                        VStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 22))
                                .foregroundStyle(Color(red: 0.37, green: 0.50, blue: 0.76))
                            Text("近期还没有安排")
                                .font(.system(size: 13, weight: .bold))
                            Text("选好日期和时段，迪莫陪你完成")
                                .font(.system(size: 10))
                                .foregroundStyle(Color(red: 0.52, green: 0.56, blue: 0.65))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 35)
                    }
                }
            }
            .frame(maxHeight: 270)
            .padding(.top, 8)

            HStack {
                Text("今日 \(model.todayCompletedCount) / \(model.todayTodos.count) · 共 \(model.todos.count) 项")
                Spacer()
                Button("清除已完成") { model.clearCompleted() }
                    .buttonStyle(.plain)
                    .disabled(model.completedCount == 0)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color(red: 0.49, green: 0.53, blue: 0.62))
            .padding(.top, 10)

        }
        .padding(.horizontal, 27)
        .padding(.vertical, 24)
        .frame(width: 390, height: 560)
        .background(
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(Color(red: 1.0, green: 0.995, blue: 0.975))
                .overlay(RoundedRectangle(cornerRadius: 25).stroke(Color.black.opacity(0.08), lineWidth: 1))
        )
        .onAppear {
            refreshForCurrentDay(Date())
        }
        .onChange(of: model.panelOpen) { isOpen in
            if !isOpen {
                inputFocused = false
                showingDatePicker = false
                composerExpanded = false
            }
        }
        .onReceive(dayRefreshTimer) { now in
            refreshForCurrentDay(now)
        }
    }

    @ViewBuilder
    private func dayHeader(_ group: TodoDayGroup) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)
        let isToday = group.day == today
        let isPast = group.day < today
        let remaining = group.items.filter { !$0.done }.count

        HStack(spacing: 7) {
            Text(dayTitle(group.day))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isToday ? Color.white : Color(red: 0.29, green: 0.34, blue: 0.46))

            if isToday {
                Text("最重要")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(red: 0.24, green: 0.39, blue: 0.70))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.92)))
            } else if isPast && remaining > 0 {
                Text("已过期")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(red: 0.78, green: 0.29, blue: 0.25))
            }

            Spacer()

            Text("\(remaining) 待办")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isToday ? Color.white.opacity(0.9) : Color(red: 0.54, green: 0.57, blue: 0.65))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isToday ? Color(red: 0.31, green: 0.45, blue: 0.74) : Color(red: 0.94, green: 0.95, blue: 0.97))
        )
        .padding(.top, 8)
    }

    @ViewBuilder
    private func todoRow(_ todo: TodoItem) -> some View {
        TodoRowView(model: model, todo: todo, referenceDate: referenceDate)
    }

    private func addTodo() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            inputFocused = true
            return
        }
        model.add(
            trimmed,
            dueAt: draftDueDate,
            period: draftPeriod,
            remindAt: draftReminderEnabled ? draftReminderAt : nil
        )
        draft = ""
        draftDueDate = referenceDate
        draftPeriod = nil
        draftReminderEnabled = false
        draftReminderAt = Date().addingTimeInterval(10 * 60)
        inputFocused = false
        showingDatePicker = false
        withAnimation(.easeInOut(duration: 0.16)) {
            composerExpanded = false
        }
    }

    private func toggleComposer() {
        let willExpand = !composerExpanded
        withAnimation(.easeInOut(duration: 0.16)) {
            composerExpanded = willExpand
        }
        if willExpand {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                inputFocused = true
            }
        } else {
            inputFocused = false
            showingDatePicker = false
        }
    }

    private func refreshForCurrentDay(_ now: Date) {
        let calendar = Calendar.current
        guard !calendar.isDate(referenceDate, inSameDayAs: now) else { return }
        let draftWasToday = calendar.isDate(draftDueDate, inSameDayAs: referenceDate)
        referenceDate = now
        if draftWasToday {
            draftDueDate = calendar.startOfDay(for: now)
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "今天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 · EEEE"
        return formatter.string(from: day)
    }

    private func weekdayLabel(_ date: Date) -> String {
        let labels = ["日", "一", "二", "三", "四", "五", "六"]
        return labels[Calendar.current.component(.weekday, from: date) - 1]
    }

    private func startOfMonth(_ date: Date) -> Date {
        Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: date)
        ) ?? date
    }

    private var calendarMonthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年 M月"
        return formatter.string(from: calendarMonth)
    }

    private var calendarGridDates: [Date?] {
        let calendar = Calendar.current
        let monthStart = startOfMonth(calendarMonth)
        guard let days = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }

        let leadingBlanks = calendar.component(.weekday, from: monthStart) - 1
        var grid = Array<Date?>(repeating: nil, count: leadingBlanks)
        grid.append(contentsOf: days.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: monthStart)
        })
        let trailingBlanks = (7 - grid.count % 7) % 7
        grid.append(contentsOf: Array<Date?>(repeating: nil, count: trailingBlanks))
        return grid
    }

    private func moveCalendarMonth(by value: Int) {
        calendarMonth = Calendar.current.date(byAdding: .month, value: value, to: calendarMonth) ?? calendarMonth
    }

    private func calendarDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter.string(from: date)
    }

    @ViewBuilder
    private func segmentLabel(_ title: String, selected: Bool, showsChevron: Bool = false) -> some View {
        ZStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            if showsChevron {
                HStack {
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6, weight: .bold))
                        .opacity(0.68)
                        .padding(.trailing, 5)
                }
            }
        }
        .foregroundStyle(selected ? Color.white : Color(red: 0.37, green: 0.42, blue: 0.53))
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color(red: 0.31, green: 0.44, blue: 0.72) : Color.clear)
        )
    }

    private func dateAccessibilityLabel(_ date: Date, isToday: Bool) -> String {
        let month = Calendar.current.component(.month, from: date)
        let day = Calendar.current.component(.day, from: date)
        return isToday ? "今天，\(month)月\(day)日" : "星期\(weekdayLabel(date))，\(month)月\(day)日"
    }

}

private struct TodoRowView: View {
    @ObservedObject var model: PetModel
    let todo: TodoItem
    let referenceDate: Date
    @State private var showingEditor = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.toggle(todo.id)
            } label: {
                ZStack {
                    Circle()
                        .fill(todo.done ? Color(red: 0.31, green: 0.46, blue: 0.75) : Color.clear)
                        .overlay(Circle().stroke(todo.done ? Color.clear : Color(red: 0.56, green: 0.61, blue: 0.72), lineWidth: 1.4))
                    if todo.done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 21, height: 21)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(todo.done ? "标记为未完成" : "标记为已完成")

            Text(todo.text)
                .font(.system(size: 13))
                .foregroundStyle(todo.done ? Color(red: 0.63, green: 0.65, blue: 0.70) : Color(red: 0.20, green: 0.25, blue: 0.36))
                .strikethrough(todo.done, color: Color(red: 0.64, green: 0.66, blue: 0.71))
                .lineLimit(2)

            Spacer(minLength: 8)

            if let period = todo.period {
                Text(period.title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(
                        !todo.done && Calendar.current.startOfDay(for: todo.dueAt) < Calendar.current.startOfDay(for: referenceDate)
                            ? Color(red: 0.79, green: 0.31, blue: 0.27)
                            : Color(red: 0.51, green: 0.55, blue: 0.65)
                    )
            }

            Button {
                showingEditor = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.47, green: 0.54, blue: 0.68))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("修改：\(todo.text)")
            .popover(isPresented: $showingEditor, arrowEdge: .trailing) {
                EditTodoView(model: model, todo: todo) {
                    showingEditor = false
                }
            }

            Button {
                model.remove(todo.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(red: 0.66, green: 0.68, blue: 0.73))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("删除：\(todo.text)")
        }
        .padding(.vertical, 10)
        .overlay(Divider().opacity(0.55), alignment: .bottom)
    }
}

private struct EditTodoView: View {
    @ObservedObject var model: PetModel
    private let todoID: UUID
    private let done: Bool
    private let close: () -> Void
    @State private var text: String
    @State private var dueAt: Date
    @State private var period: TodoPeriod?
    @State private var reminderEnabled: Bool
    @State private var remindAt: Date
    @FocusState private var textFocused: Bool

    init(model: PetModel, todo: TodoItem, close: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        todoID = todo.id
        done = todo.done
        self.close = close
        _text = State(initialValue: todo.text)
        _dueAt = State(initialValue: todo.dueAt)
        _period = State(initialValue: todo.period)
        _reminderEnabled = State(initialValue: todo.remindAt != nil && !todo.done)
        _remindAt = State(initialValue: todo.remindAt ?? Date().addingTimeInterval(10 * 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("修改任务")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(red: 0.19, green: 0.24, blue: 0.37))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 0.52, green: 0.55, blue: 0.63))
                        .frame(width: 25, height: 25)
                        .background(Circle().fill(Color(red: 0.94, green: 0.95, blue: 0.98)))
                }
                .buttonStyle(.plain)
            }

            TextField("任务内容", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.82)))
                .focused($textFocused)
                .onSubmit(save)

            editRow(icon: "calendar", title: "日期") {
                DimoDatePicker(selection: $dueAt)
            }

            editRow(icon: "sun.horizon", title: "时段") {
                HStack(spacing: 2) {
                    periodButton("不选", selected: period == nil) { period = nil }
                    ForEach(TodoPeriod.allCases) { option in
                        periodButton(option.title, selected: period == option) { period = option }
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.72)))
            }

            editRow(icon: "bell", title: "提醒") {
                Toggle("", isOn: $reminderEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(done)
            }

            if reminderEnabled && !done {
                editRow(icon: "clock", title: "时间") {
                    DimoDateTimePicker(selection: $remindAt)
                }
            }

            if done {
                Text("已完成任务不会再设置提醒")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 0.54, green: 0.57, blue: 0.64))
            }

            HStack(spacing: 9) {
                Button("取消", action: close)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.37, green: 0.42, blue: 0.54))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.92, green: 0.94, blue: 0.97)))

                Button("保存修改", action: save)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.31, green: 0.44, blue: 0.72)))
            }
        }
        .padding(17)
        .frame(width: 340)
        .background(Color(red: 0.985, green: 0.982, blue: 0.965))
        .onAppear { textFocused = true }
    }

    @ViewBuilder
    private func editRow<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 0.39, green: 0.49, blue: 0.70))
                .frame(width: 14, height: 14)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 0.48, green: 0.52, blue: 0.62))
                .frame(width: 28, alignment: .leading)
            Spacer()
            content()
        }
    }

    private func periodButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color(red: 0.37, green: 0.42, blue: 0.53))
                .frame(width: 42, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color(red: 0.31, green: 0.44, blue: 0.72) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            textFocused = true
            return
        }
        model.update(todoID, text: trimmed, dueAt: dueAt, period: period, remindAt: reminderEnabled ? remindAt : nil)
        close()
    }
}

private struct DimoDatePicker: View {
    @Binding var selection: Date
    @State private var showingCalendar = false

    var body: some View {
        Button {
            showingCalendar = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 9, weight: .semibold))
                Text(dateTitle)
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
                    .opacity(0.66)
            }
            .foregroundStyle(Color(red: 0.32, green: 0.39, blue: 0.56))
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.82)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
            DimoCalendarPicker(selection: $selection, isPresented: $showingCalendar)
        }
    }

    private var dateTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(selection) { return "今天" }
        if calendar.isDateInTomorrow(selection) { return "明天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: selection)
    }
}

private struct DimoDateTimePicker: View {
    @Binding var selection: Date
    @State private var showingCalendar = false
    @State private var showingTime = false

    var body: some View {
        HStack(spacing: 5) {
            Button {
                showingCalendar = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 9, weight: .semibold))
                    Text(dateTitle)
                        .font(.system(size: 10, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6, weight: .bold))
                        .opacity(0.66)
                }
                .foregroundStyle(Color(red: 0.32, green: 0.39, blue: 0.56))
                .padding(.horizontal, 8)
                .frame(height: 27)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.82)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
                DimoCalendarPicker(selection: $selection, isPresented: $showingCalendar)
            }

            Button {
                showingTime = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9, weight: .semibold))
                    Text(timeTitle)
                        .font(.system(size: 10, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6, weight: .bold))
                        .opacity(0.66)
                }
                .foregroundStyle(Color(red: 0.32, green: 0.39, blue: 0.56))
                .padding(.horizontal, 8)
                .frame(height: 27)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.82)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingTime, arrowEdge: .bottom) {
                DimoTimePicker(selection: $selection, isPresented: $showingTime)
            }
        }
    }

    private var dateTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(selection) { return "今天" }
        if calendar.isDateInTomorrow(selection) { return "明天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: selection)
    }

    private var timeTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: selection)
    }
}

private struct DimoCalendarPicker: View {
    @Binding var selection: Date
    @Binding var isPresented: Bool
    @State private var calendarMonth: Date

    init(selection: Binding<Date>, isPresented: Binding<Bool>) {
        _selection = selection
        _isPresented = isPresented
        _calendarMonth = State(initialValue: Self.startOfMonth(selection.wrappedValue))
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button { moveMonth(by: -1) } label: {
                    Image(systemName: "chevron.left").frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .disabled(calendarMonth <= Self.startOfMonth(Date()))

                Spacer()

                Text(monthTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(red: 0.25, green: 0.37, blue: 0.67))

                Spacer()

                Button { moveMonth(by: 1) } label: {
                    Image(systemName: "chevron.right").frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Color(red: 0.43, green: 0.48, blue: 0.59))

            HStack(spacing: 0) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { weekday in
                    Text(weekday)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(red: 0.57, green: 0.60, blue: 0.68))
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 4) {
                ForEach(Array(gridDates.enumerated()), id: \.offset) { _, date in
                    if let date {
                        let selected = Calendar.current.isDate(date, inSameDayAs: selection)
                        let today = Calendar.current.isDateInToday(date)
                        let available = date >= Calendar.current.startOfDay(for: Date())
                        Button {
                            choose(date)
                        } label: {
                            Text(String(Calendar.current.component(.day, from: date)))
                                .font(.system(size: 10, weight: selected ? .bold : .medium))
                                .foregroundStyle(
                                    selected ? Color.white : (available ? Color(red: 0.31, green: 0.35, blue: 0.44) : Color(red: 0.74, green: 0.76, blue: 0.80))
                                )
                                .frame(width: 25, height: 25)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(
                                            selected
                                                ? Color(red: 0.31, green: 0.44, blue: 0.72)
                                                : (today ? Color(red: 0.88, green: 0.91, blue: 0.97) : Color.clear)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!available)
                    } else {
                        Color.clear.frame(width: 25, height: 25)
                    }
                }
            }
        }
        .padding(13)
        .frame(width: 236)
        .background(Color(red: 0.985, green: 0.982, blue: 0.965))
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年 M月"
        return formatter.string(from: calendarMonth)
    }

    private var gridDates: [Date?] {
        let calendar = Calendar.current
        guard let days = calendar.range(of: .day, in: .month, for: calendarMonth) else { return [] }
        let leadingBlanks = calendar.component(.weekday, from: calendarMonth) - 1
        var dates = Array<Date?>(repeating: nil, count: leadingBlanks)
        dates.append(contentsOf: days.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: calendarMonth) })
        dates.append(contentsOf: Array<Date?>(repeating: nil, count: (7 - dates.count % 7) % 7))
        return dates
    }

    private func choose(_ date: Date) {
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute], from: selection)
        var day = calendar.dateComponents([.year, .month, .day], from: date)
        day.hour = time.hour
        day.minute = time.minute
        selection = calendar.date(from: day) ?? selection
        isPresented = false
    }

    private func moveMonth(by value: Int) {
        calendarMonth = Calendar.current.date(byAdding: .month, value: value, to: calendarMonth) ?? calendarMonth
    }

    private static func startOfMonth(_ date: Date) -> Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: date)) ?? date
    }
}

private struct DimoTimePicker: View {
    @Binding var selection: Date
    @Binding var isPresented: Bool

    private let hourColumns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 6)
    private let minuteColumns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 10)

    var body: some View {
        VStack(spacing: 11) {
            Text("选择提醒时间")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(red: 0.25, green: 0.37, blue: 0.67))

            timeSection(title: "小时", values: Array(0..<24), columns: hourColumns)
            Divider().opacity(0.5)
            timeSection(title: "分钟", values: Array(0..<60), columns: minuteColumns)
        }
        .padding(14)
        .frame(width: 300)
        .background(Color(red: 0.985, green: 0.982, blue: 0.965))
    }

    @ViewBuilder
    private func timeSection(title: String, values: [Int], columns: [GridItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 0.50, green: 0.54, blue: 0.63))
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(values, id: \.self) { value in
                    let selected = title == "小时" ? hour == value : minute == value
                    Button {
                        updateTime(hour: title == "小时" ? value : hour, minute: title == "分钟" ? value : minute)
                    } label: {
                        Text(String(format: "%02d", value))
                            .font(.system(size: 10, weight: selected ? .bold : .medium))
                            .foregroundStyle(selected ? Color.white : Color(red: 0.33, green: 0.38, blue: 0.50))
                            .frame(maxWidth: .infinity)
                            .frame(height: 23)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selected ? Color(red: 0.31, green: 0.44, blue: 0.72) : Color.white.opacity(0.7))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var hour: Int { Calendar.current.component(.hour, from: selection) }
    private var minute: Int { Calendar.current.component(.minute, from: selection) }

    private func updateTime(hour: Int, minute: Int) {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: selection)
        components.hour = hour
        components.minute = minute
        let updated = calendar.date(from: components) ?? selection
        selection = updated < Date() ? Date().addingTimeInterval(60) : updated
        isPresented = false
    }
}

private struct ReminderPanelView: View {
    @ObservedObject var model: PetModel
    @State private var nextReminderAt = Date().addingTimeInterval(15 * 60)

    private var reminder: TodoItem? {
        model.activeReminders.first
    }

    var body: some View {
        Group {
            if let reminder {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color(red: 0.31, green: 0.44, blue: 0.72))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color(red: 0.89, green: 0.92, blue: 0.98)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("迪莫提醒")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color(red: 0.18, green: 0.24, blue: 0.38))
                            Text("完成前会一直留在桌面最上方")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color(red: 0.48, green: 0.52, blue: 0.62))
                        }
                        Spacer()
                        Button {} label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(red: 0.65, green: 0.67, blue: 0.72))
                                .frame(width: 27, height: 27)
                                .background(Circle().fill(Color(red: 0.94, green: 0.95, blue: 0.97)))
                        }
                        .buttonStyle(.plain)
                        .disabled(true)
                        .help("完成任务后提醒会自动关闭")
                    }

                    Text(reminder.text)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(red: 0.16, green: 0.21, blue: 0.33))
                        .lineLimit(3)
                        .padding(.top, 19)

                    if let date = reminder.remindAt {
                        Text("原定提醒：\(reminderDateLabel(date))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(red: 0.50, green: 0.54, blue: 0.64))
                            .padding(.top, 6)
                    }

                    Divider().opacity(0.6).padding(.vertical, 15)

                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(red: 0.38, green: 0.48, blue: 0.70))
                        Text("下次提醒")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.43, green: 0.47, blue: 0.57))
                        Spacer()
                        DimoDateTimePicker(selection: $nextReminderAt)
                    }

                    HStack(spacing: 9) {
                        Button {
                            model.postponeReminder(reminder.id, until: nextReminderAt)
                        } label: {
                            Text("到时再提醒")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(red: 0.30, green: 0.40, blue: 0.67))
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(red: 0.90, green: 0.93, blue: 0.98))
                                )
                        }
                        .buttonStyle(.plain)

                        Button {
                            model.complete(reminder.id)
                        } label: {
                            Text("完成任务")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(red: 0.31, green: 0.44, blue: 0.72))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 14)
                }
                .padding(20)
                .frame(width: 370)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(red: 1.0, green: 0.995, blue: 0.975))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color(red: 0.31, green: 0.44, blue: 0.72).opacity(0.18), lineWidth: 1)
                        )
                )
                .onAppear { resetNextReminderDate() }
                .onChange(of: reminder.id) { _ in resetNextReminderDate() }
            }
        }
    }

    private func resetNextReminderDate() {
        nextReminderAt = Date().addingTimeInterval(15 * 60)
    }

    private func reminderDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DraggablePetView: NSView {
    private let image: NSImage
    private let clickAction: () -> Void
    private let quitAction: () -> Void

    init(image: NSImage, clickAction: @escaping () -> Void, quitAction: @escaping () -> Void) {
        self.image = image
        self.clickAction = clickAction
        self.quitAction = quitAction
        super.init(frame: NSRect(x: 0, y: 0, width: 112, height: 112))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("打开或收起近期计划")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        image.draw(
            in: NSRect(x: 10, y: 10, width: 92, height: 92),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override func accessibilityPerformPress() -> Bool {
        clickAction()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "退出迪莫", action: #selector(quitPet), keyEquivalent: "")
        menu.items.first?.target = self
        return menu
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    @objc private func quitPet() {
        quitAction()
    }
}

private final class TodoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = PetModel()
    private var petWindow: PetPanel!
    private var todoWindow: TodoPanel!
    private var reminderWindow: TodoPanel!
    private var petEventMonitor: Any?
    private var petClickStartOrigin: NSPoint?
    private var reminderTimer: Timer?
    private var todosCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        createPetWindow()
        createTodoWindow()
        createReminderWindow()
        positionPetWindow()
        petWindow.orderFrontRegardless()

        todosCancellable = model.$todos.sink { [weak self] _ in
            self?.updateReminderWindow()
        }
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.model.refreshReminderState()
                self?.updateReminderWindow()
            }
        }
        updateReminderWindow()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(petWindowDidMove),
            name: NSWindow.didMoveNotification,
            object: petWindow
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        installPetClickMonitor()

    }

    func applicationWillTerminate(_ notification: Notification) {
        if let petEventMonitor { NSEvent.removeMonitor(petEventMonitor) }
        reminderTimer?.invalidate()
        todosCancellable?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func createPetWindow() {
        petWindow = PetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 112, height: 112),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        petWindow.level = .floating
        petWindow.titleVisibility = .hidden
        petWindow.titlebarAppearsTransparent = true
        petWindow.standardWindowButton(.closeButton)?.isHidden = true
        petWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        petWindow.standardWindowButton(.zoomButton)?.isHidden = true
        petWindow.backgroundColor = .clear
        petWindow.isOpaque = false
        petWindow.hasShadow = false
        petWindow.hidesOnDeactivate = false
        petWindow.isMovableByWindowBackground = true
        petWindow.isReleasedWhenClosed = false
        petWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        petWindow.contentView = DraggablePetView(
            image: dimoImage(),
            clickAction: { [weak self] in self?.toggleTodoPanel() },
            quitAction: { NSApp.terminate(nil) }
        )
    }

    private func createTodoWindow() {
        todoWindow = TodoPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        todoWindow.level = .floating
        todoWindow.backgroundColor = .clear
        todoWindow.isOpaque = false
        todoWindow.hasShadow = true
        todoWindow.hidesOnDeactivate = false
        todoWindow.isReleasedWhenClosed = false
        todoWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = TodoPanelView(model: model, close: { [weak self] in self?.hideTodoPanel() })
        todoWindow.contentView = FirstMouseHostingView(rootView: root)
    }

    private func createReminderWindow() {
        reminderWindow = TodoPanel(
            contentRect: NSRect(x: 0, y: 0, width: 370, height: 255),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        reminderWindow.level = .screenSaver
        reminderWindow.backgroundColor = .clear
        reminderWindow.isOpaque = false
        reminderWindow.hasShadow = true
        reminderWindow.hidesOnDeactivate = false
        reminderWindow.isReleasedWhenClosed = false
        reminderWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        reminderWindow.contentView = FirstMouseHostingView(rootView: ReminderPanelView(model: model))
    }

    private func positionPetWindow() {
        guard let visibleFrame = NSScreen.main?.visibleFrame else { return }
        let defaults = UserDefaults.standard
        let savedX = defaults.object(forKey: "dimo.pet.x") as? NSNumber
        let savedY = defaults.object(forKey: "dimo.pet.y") as? NSNumber
        let saved = NSPoint(x: savedX?.doubleValue ?? 0, y: savedY?.doubleValue ?? 0)
        let savedIsVisible = savedX != nil && savedY != nil
            && saved.x >= visibleFrame.minX
            && saved.x <= visibleFrame.maxX - petWindow.frame.width
            && saved.y >= visibleFrame.minY
            && saved.y <= visibleFrame.maxY - petWindow.frame.height
        let origin = savedIsVisible ? saved : NSPoint(
            x: visibleFrame.maxX - petWindow.frame.width - 26,
            y: visibleFrame.minY + 24
        )
        petWindow.setFrameOrigin(origin)
    }

    private func positionTodoPanel() {
        guard let screen = petWindow.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var x = petWindow.frame.minX - todoWindow.frame.width + 30
        var y = petWindow.frame.minY + 68

        x = min(max(x, visible.minX + 14), visible.maxX - todoWindow.frame.width - 14)
        y = min(max(y, visible.minY + 14), visible.maxY - todoWindow.frame.height - 14)
        todoWindow.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func positionReminderWindow() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.maxX - reminderWindow.frame.width - 24
        let y = visible.maxY - reminderWindow.frame.height - 24
        reminderWindow.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func updateReminderWindow() {
        guard !model.activeReminders.isEmpty else {
            reminderWindow?.orderOut(nil)
            return
        }
        positionReminderWindow()
        reminderWindow.orderFrontRegardless()
    }

    private func toggleTodoPanel() {
        if model.panelOpen {
            hideTodoPanel()
        } else {
            model.panelOpen = true
            positionTodoPanel()
            NSApp.activate(ignoringOtherApps: true)
            todoWindow.makeKeyAndOrderFront(nil)
        }
    }

    private func installPetClickMonitor() {
        petEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.petWindow else { return event }

            if event.type == .leftMouseDown {
                self.petClickStartOrigin = self.petWindow.frame.origin
            } else if event.type == .leftMouseUp {
                if let start = self.petClickStartOrigin {
                    let end = self.petWindow.frame.origin
                    if hypot(end.x - start.x, end.y - start.y) < 3 {
                        DispatchQueue.main.async { [weak self] in self?.toggleTodoPanel() }
                    }
                }
                self.petClickStartOrigin = nil
            }
            return event
        }
    }

    private func hideTodoPanel() {
        model.panelOpen = false
        todoWindow.orderOut(nil)
        petWindow.orderFrontRegardless()
    }

    @objc private func applicationDidResignActive() {
        if model.panelOpen { hideTodoPanel() }
    }

    @objc private func petWindowDidMove() {
        UserDefaults.standard.set(petWindow.frame.origin.x, forKey: "dimo.pet.x")
        UserDefaults.standard.set(petWindow.frame.origin.y, forKey: "dimo.pet.y")
        if model.panelOpen { positionTodoPanel() }
    }

}

@main
@MainActor
private struct DimoPetApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        _ = delegate
    }
}
