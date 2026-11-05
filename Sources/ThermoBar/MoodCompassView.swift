import AppKit

final class MoodCompassView: NSView {
    static let preferredSize = NSSize(width: 360, height: 630)
    var onEnable: ((Bool) -> Void)?
    var onSource: ((String, Bool) -> Void)?
    var onContext: ((String) -> Void)?
    var onCheckIn: (([String: Double]) -> Void)?
    var onBeginFocus: (() -> Void)?
    var onFinishFocus: ((Double) -> Void)?
    var onDelete: (() -> Void)?
    var onOpenPermissions: (() -> Void)?
    private(set) var presentation = CompassPresentation()
    private let title = NSTextField(labelWithString: "Mood Compass")
    private let subtitle = NSTextField(labelWithString: "Estimates, not your actual emotions")
    private let toggle = NSButton(title: "Start", target: nil, action: nil)
    private let pages = HoverSegmentedControl(labels: ["Overview", "Check-in", "Privacy", "Learning"], trackingMode: .selectOne, target: nil, action: nil)
    private var pageViews: [NSView] = []
    private var valueLabels: [CompassMetric: NSTextField] = [:]
    private var meters: [CompassMetric: NSLevelIndicator] = [:]
    private let confidence = NSTextField(wrappingLabelWithString: "Monitoring off")
    private let recommendation = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let chart = CompassTrendView()
    private let trendLegend = NSTextField(labelWithString: "")
    private let range = HoverSegmentedControl(labels: ["24H", "7D", "30D", "180D"], trackingMode: .selectOne, target: nil, action: nil)
    private var ratingSliders: [CompassMetric: NSSlider] = [:]
    private var ratingLabels: [CompassMetric: NSTextField] = [:]
    private let saveCheckIn = NSButton(title: "Save check-in", target: nil, action: nil)
    private let startFocus = NSButton(title: "Start focus session", target: nil, action: nil)
    private let focusRating = NSPopUpButton(frame: .zero, pullsDown: false)
    private var sourceButtons: [String: NSButton] = [:]
    private var sourceDetails: [String: NSTextField] = [:]
    private let context = NSPopUpButton(frame: .zero, pullsDown: false)
    private let learningText = NSTextField(wrappingLabelWithString: "")
    private let reviewText = NSTextField(wrappingLabelWithString: "")
    private let latestCheckIn = NSTextField(wrappingLabelWithString: "")
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); configure() }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }

    private func label(_ text: String, in parent: NSView, frame: NSRect, size: CGFloat = 11, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        field.textColor = bold ? .labelColor : .secondaryLabelColor
        field.frame = frame
        parent.addSubview(field)
        return field
    }
    private func button(_ button: NSButton, in parent: NSView, frame: NSRect, action: Selector) {
        button.frame = frame; button.target = self; button.action = action
        button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 11)
        parent.addSubview(button)
    }
    private func card(in parent: NSView, frame: NSRect) -> NSView {
        let view = CompassCardView(frame: frame)
        parent.addSubview(view)
        return view
    }
    private func configure() {
        setAccessibilityElement(false)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.frame = NSRect(x: 14, y: 10, width: 240, height: 24); addSubview(title)
        subtitle.font = .systemFont(ofSize: 10); subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 14, y: 37, width: 325, height: 16); addSubview(subtitle)
        button(toggle, in: self, frame: NSRect(x: 274, y: 10, width: 72, height: 25), action: #selector(toggleEnabled))
        toggle.setAccessibilityLabel("Start or pause Mood Compass")
        pages.frame = NSRect(x: 12, y: 62, width: 336, height: 25)
        pages.font = .systemFont(ofSize: 10); pages.selectedSegment = 0
        pages.target = self; pages.action = #selector(changePage)
        pages.setAccessibilityLabel("Mood Compass sections"); addSubview(pages)
        for index in 0..<4 {
            let page = CompassFlippedView(frame: NSRect(x: 0, y: 96, width: 360, height: 530))
            page.isHidden = index != 0; pageViews.append(page); addSubview(page)
        }
        configureOverview(pageViews[0])
        configureCheckIn(pageViews[1])
        configurePrivacy(pageViews[2])
        configureLearning(pageViews[3])
        update(presentation)
    }

    private func configureOverview(_ page: NSView) {
        for (index, metric) in CompassMetric.allCases.enumerated() {
            let x: CGFloat = index % 2 == 0 ? 12 : 186
            let y: CGFloat = index < 2 ? 0 : 78
            let box = card(in: page, frame: NSRect(x: x, y: y, width: 162, height: 68))
            _ = label(metric.title.uppercased(), in: box, frame: NSRect(x: 10, y: 8, width: 142, height: 14), size: 9, bold: true)
            valueLabels[metric] = label("—", in: box, frame: NSRect(x: 10, y: 25, width: 142, height: 23), size: 17, bold: true)
            let meter = NSLevelIndicator(frame: NSRect(x: 10, y: 52, width: 142, height: 6))
            meter.levelIndicatorStyle = .continuousCapacity; meter.minValue = 0; meter.maxValue = 100
            meter.warningValue = 101; meter.criticalValue = 102; meter.isEditable = false
            meter.fillColor = metric == .stress ? .systemOrange : metric == .energy ? .systemTeal : metric == .mood ? .systemPurple : .systemBlue
            meter.setAccessibilityLabel(metric.title + " estimate")
            box.addSubview(meter); meters[metric] = meter
        }
        confidence.frame = NSRect(x: 14, y: 156, width: 332, height: 32)
        confidence.font = .systemFont(ofSize: 10); confidence.textColor = .secondaryLabelColor; page.addSubview(confidence)
        range.frame = NSRect(x: 158, y: 196, width: 188, height: 23)
        range.font = .systemFont(ofSize: 9); range.selectedSegment = 0
        range.target = self; range.action = #selector(changeRange); page.addSubview(range)
        _ = label("ESTIMATED TRENDS", in: page, frame: NSRect(x: 14, y: 201, width: 140, height: 15), size: 9, bold: true)
        chart.frame = NSRect(x: 14, y: 229, width: 332, height: 106); page.addSubview(chart)
        trendLegend.frame = NSRect(x: 14, y: 340, width: 330, height: 17)
        let legend = NSMutableAttributedString()
        for (text, color) in [("Energy  ", NSColor.systemTeal), ("Stress  ", .systemOrange), ("Focus  ", .systemBlue), ("• Self-reported mood", .systemPurple)] {
            legend.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: color]))
        }
        trendLegend.attributedStringValue = legend; page.addSubview(trendLegend)
        let box = card(in: page, frame: NSRect(x: 12, y: 366, width: 336, height: 74))
        recommendation.frame = NSRect(x: 10, y: 9, width: 316, height: 58)
        recommendation.font = .systemFont(ofSize: 11); recommendation.textColor = .labelColor; box.addSubview(recommendation)
        message.frame = NSRect(x: 14, y: 450, width: 332, height: 45)
        message.font = .systemFont(ofSize: 10); message.textColor = .secondaryLabelColor; page.addSubview(message)
    }

    private func configureCheckIn(_ page: NSView) {
        _ = label("How do you actually feel?", in: page, frame: NSRect(x: 14, y: 0, width: 330, height: 20), size: 14, bold: true)
        _ = label("Optional self-report · 1 = low, 5 = high. These are your reports, not sensor measurements.", in: page,
                  frame: NSRect(x: 14, y: 27, width: 330, height: 34), size: 10)
        for (index, metric) in CompassMetric.allCases.enumerated() {
            let y = CGFloat(70 + index * 56)
            _ = label(metric.title, in: page, frame: NSRect(x: 14, y: y, width: 240, height: 17), bold: true)
            ratingLabels[metric] = label("3 / 5", in: page, frame: NSRect(x: 300, y: y, width: 46, height: 17))
            let slider = NSSlider(value: 3, minValue: 1, maxValue: 5, target: self, action: #selector(ratingChanged))
            slider.frame = NSRect(x: 12, y: y + 23, width: 334, height: 20)
            slider.numberOfTickMarks = 5; slider.allowsTickMarkValuesOnly = true
            slider.tag = index; slider.setAccessibilityLabel("Self-reported " + metric.title)
            page.addSubview(slider); ratingSliders[metric] = slider
        }
        button(saveCheckIn, in: page, frame: NSRect(x: 12, y: 305, width: 336, height: 27), action: #selector(saveRatings))
        latestCheckIn.frame = NSRect(x: 14, y: 342, width: 332, height: 42)
        latestCheckIn.font = .systemFont(ofSize: 10); latestCheckIn.textColor = .secondaryLabelColor; page.addSubview(latestCheckIn)
        _ = label("Teach focus readiness using a real outcome", in: page, frame: NSRect(x: 14, y: 389, width: 332, height: 20), bold: true)
        button(startFocus, in: page, frame: NSRect(x: 12, y: 419, width: 163, height: 27), action: #selector(beginFocus))
        focusRating.addItems(withTitles: ["Rate session…", "Good focus", "Mixed", "Difficult"])
        focusRating.frame = NSRect(x: 186, y: 419, width: 162, height: 27)
        focusRating.font = .systemFont(ofSize: 11); focusRating.target = self; focusRating.action = #selector(finishFocus)
        page.addSubview(focusRating)
        _ = label("Rate after 5 minutes, within 2 hours. Feedback is matched to the prediction at session start—not to a later estimate.",
                  in: page, frame: NSRect(x: 14, y: 456, width: 332, height: 43), size: 10)
    }

    private func configurePrivacy(_ page: NSView) {
        _ = label("You control every signal", in: page, frame: NSRect(x: 14, y: 0, width: 223, height: 20), size: 14, bold: true)
        let permissions = NSButton(title: "Permissions…", target: nil, action: nil)
        button(permissions, in: page, frame: NSRect(x: 242, y: 0, width: 106, height: 23), action: #selector(openPermissions))
        _ = label("All processing stays on this Mac. Turning a source off stops future collection; Delete removes stored history and models.", in: page,
                  frame: NSRect(x: 14, y: 27, width: 332, height: 43), size: 10)
        let sources = [("activity", "Activity & breaks"), ("typing", "Typing counts & rhythm"), ("music", "Music playback activity"),
                       ("calendar", "Upcoming calendar load"), ("reminders", "Reminders completion"), ("daylight", "Local daylight context")]
        for (index, entry) in sources.enumerated() {
            let y = CGFloat(78 + index * 46)
            let checkbox = NSButton(checkboxWithTitle: entry.1, target: self, action: #selector(sourceChanged))
            checkbox.font = .systemFont(ofSize: 11); checkbox.identifier = NSUserInterfaceItemIdentifier(entry.0)
            checkbox.frame = NSRect(x: 12, y: y, width: 334, height: 20)
            checkbox.setAccessibilityLabel("Mood source: " + entry.1)
            page.addSubview(checkbox); sourceButtons[entry.0] = checkbox
            sourceDetails[entry.0] = label("Off", in: page, frame: NSRect(x: 31, y: y + 23, width: 315, height: 16), size: 9)
        }
        _ = label("Optional context (you choose, not inferred)", in: page, frame: NSRect(x: 14, y: 366, width: 332, height: 18), size: 10)
        context.addItems(withTitles: ["Unspecified", "Home", "Work / study", "Travelling", "Resting"])
        context.frame = NSRect(x: 12, y: 392, width: 336, height: 26)
        context.target = self; context.action = #selector(contextChanged); page.addSubview(context)
        let delete = NSButton(title: "Delete all Mood Compass data…", target: nil, action: nil)
        button(delete, in: page, frame: NSRect(x: 12, y: 438, width: 336, height: 27), action: #selector(deleteData))
        delete.contentTintColor = .systemRed
        delete.setAccessibilityLabel("Delete Mood Compass history and learned models")
        _ = label("No typed text, window titles, event/task text, song titles, coordinates, screenshots or audio are saved.", in: page,
                  frame: NSRect(x: 14, y: 478, width: 332, height: 42), size: 10)
    }

    private func configureLearning(_ page: NSView) {
        _ = label("Personal, not presumptive", in: page, frame: NSRect(x: 14, y: 0, width: 332, height: 22), size: 14, bold: true)
        learningText.frame = NSRect(x: 14, y: 34, width: 332, height: 155)
        learningText.font = .systemFont(ofSize: 11); learningText.textColor = .secondaryLabelColor; page.addSubview(learningText)
        _ = label("MODEL REVIEW HISTORY", in: page, frame: NSRect(x: 14, y: 202, width: 330, height: 18), size: 10, bold: true)
        reviewText.frame = NSRect(x: 14, y: 231, width: 332, height: 280)
        reviewText.font = .systemFont(ofSize: 10); reviewText.textColor = .secondaryLabelColor; page.addSubview(reviewText)
    }

    func update(_ value: CompassPresentation) {
        presentation = value
        let menuReadiness = CompassMenuReadiness(value)
        let fresh = value.settings.enabled && value.state.latestDate.map { Date().timeIntervalSince($0) < 600 } == true
        toggle.title = value.settings.enabled ? "Pause" : "Start"
        confidence.stringValue = value.confidenceText
        recommendation.stringValue = value.recommendation
        message.stringValue = value.message
        for metric in CompassMetric.allCases {
            let score = value.state.latestEstimate[metric.rawValue]
            let known = fresh && value.state.latestQuality >= 0.4 && score != nil
                && (metric != .mood || value.moodIsCalibrated)
                && (metric != .readiness || menuReadiness.percentage(at: Date()) != nil)
            valueLabels[metric]?.stringValue = known ? "≈ \(Int((score! / 5).rounded()) * 5) / 100" : metric == .mood && fresh ? "Uncalibrated" : "—"
            valueLabels[metric]?.font = .systemFont(ofSize: known ? 17 : 13, weight: .semibold)
            meters[metric]?.doubleValue = known ? score! : 0
            meters[metric]?.isHidden = !known
            meters[metric]?.alphaValue = known ? 0.8 : 0.2
            if metric == .readiness { valueLabels[metric]?.toolTip = menuReadiness.explanation(at: Date()) }
            ratingSliders[metric]?.isEnabled = value.settings.enabled
        }
        saveCheckIn.isEnabled = fresh
        startFocus.isEnabled = fresh
        let session = value.state.focusSession
        startFocus.title = session == nil ? "Start focus session" : "Restart focus session"
        focusRating.isEnabled = value.settings.enabled && session.map { (300...7_200).contains(Date().timeIntervalSince($0.startedAt)) } == true
        latestCheckIn.stringValue = value.state.labels.last.map { label in
            let scores = CompassMetric.allCases.compactMap { metric in
                label.actual[metric.rawValue].map { "\(metric == .readiness ? "Focus" : metric.rawValue.capitalized) \(Int(($0 / 25).rounded()) + 1)/5" }
            }.joined(separator: " · ")
            return "Your last \(label.kind): \(Self.dateString(label.timestamp))\n\(scores)"
        } ?? "No check-ins yet. You can skip them, but emotional personalization needs your feedback."
        if ["Check-in saved", "Wait for", "Focus session", "Focus outcome", "Rate a focus"].contains(where: value.message.hasPrefix) {
            latestCheckIn.stringValue = value.message
        }
        let selected: [String: Bool] = ["activity": value.settings.activity, "typing": value.settings.typing, "music": value.settings.music,
            "calendar": value.settings.calendar, "reminders": value.settings.reminders, "daylight": value.settings.daylight]
        for (key, checkbox) in sourceButtons {
            checkbox.state = selected[key] == true ? .on : .off
            checkbox.isEnabled = value.settings.enabled
            sourceDetails[key]?.stringValue = !value.settings.enabled ? "Paused · no collection" : selected[key] == true ? value.permissions[key] ?? "Waiting" : "Off · no collection"
        }
        context.selectItem(withTitle: value.settings.context)
        context.isEnabled = value.settings.enabled
        let errors = value.state.labels.suffix(50).flatMap { label in label.actual.compactMap { key, actual in label.predicted[key].map { abs($0 - actual) } } }
        let errorText = errors.isEmpty ? "Not yet measurable" : String(format: "%.1f / 100 points (not accuracy %%)", errors.reduce(0, +) / Double(errors.count))
        learningText.stringValue = "Model v\(value.state.model.version) · \(value.state.baseline.values.map(\.count).max() ?? 0) sampled minutes\n\(value.state.labels.count) optional check-ins / outcomes\nObserved feedback error: \(errorText)\n\nWeekly review: \(min(7, value.state.observedDays.count))/7 observed days; at least 7 elapsed days.\n32 reliable outcomes across 4 days are needed to adjust weights. No feedback: baseline learning only."
        reviewText.stringValue = value.state.reviews.suffix(4).reversed().map {
            "\(Self.dateString($0.timestamp)) · v\($0.version) · \($0.outcome)\n\($0.detail)"
        }.joined(separator: "\n\n")
        if reviewText.stringValue.isEmpty { reviewText.stringValue = "No reviews yet.\n\nCandidates are tested on later, held-out check-ins. Small changes only. Fresh outcomes can automatically trigger rollback. Previous models are kept.\n\nNot a medical or mental-health assessment. Behaviour cannot reliably reveal how you feel." }
        chart.presentation = value; chart.rangeIndex = range.selectedSegment; chart.needsDisplay = true
    }

    static func dateString(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
    func selectPage(_ index: Int) {
        guard pageViews.indices.contains(index) else { return }
        pages.selectedSegment = index
        for (i, page) in pageViews.enumerated() { page.isHidden = i != index }
    }
    @objc private func changePage() { selectPage(pages.selectedSegment) }
    @objc private func toggleEnabled() { onEnable?(!presentation.settings.enabled) }
    @objc private func ratingChanged(_ sender: NSSlider) {
        guard CompassMetric.allCases.indices.contains(sender.tag) else { return }
        ratingLabels[CompassMetric.allCases[sender.tag]]?.stringValue = "\(Int(sender.doubleValue.rounded())) / 5"
    }
    @objc private func saveRatings() {
        onCheckIn?(Dictionary(uniqueKeysWithValues: ratingSliders.map { ($0.key.rawValue, ($0.value.doubleValue.rounded() - 1) * 25) }))
    }
    @objc private func beginFocus() { onBeginFocus?() }
    @objc private func finishFocus() {
        let scores = [75.0, 50, 25]
        let index = focusRating.indexOfSelectedItem - 1
        if scores.indices.contains(index) { onFinishFocus?(scores[index]) }
        focusRating.selectItem(at: 0)
    }
    @objc private func sourceChanged(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        onSource?(key, sender.state == .on)
    }
    @objc private func contextChanged() { if let value = context.titleOfSelectedItem { onContext?(value) } }
    @objc private func deleteData() { onDelete?() }
    @objc private func openPermissions() { onOpenPermissions?() }
    @objc private func changeRange() { chart.rangeIndex = range.selectedSegment; chart.needsDisplay = true }
}

private class CompassFlippedView: NSView { override var isFlipped: Bool { true } }
private final class CompassCardView: CompassFlippedView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        NSColor.controlBackgroundColor.withAlphaComponent(0.55).setFill(); path.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke(); path.lineWidth = 0.6; path.stroke()
    }
}

final class CompassTrendView: NSView {
    var presentation = CompassPresentation()
    var rangeIndex = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 12)
        let durations = [1.0, 7, 30, 180]
        let days = durations[min(3, max(0, rangeIndex))]
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.tertiaryLabelColor]
        NSAttributedString(string: rangeIndex == 0 ? "24h ago" : "\(Int(days))d ago", attributes: attrs).draw(at: NSPoint(x: 1, y: bounds.height - 10))
        NSAttributedString(string: "Now", attributes: attrs).draw(at: NSPoint(x: bounds.width - 21, y: bounds.height - 10))
        NSColor.separatorColor.withAlphaComponent(0.25).setStroke()
        for fraction in [0.0, 0.5, 1.0] {
            let path = NSBezierPath(); path.move(to: NSPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY + rect.height * fraction)); path.lineWidth = 0.5; path.stroke()
        }
        let duration = days * 86_400
        let now = Date(), start = now.addingTimeInterval(-duration)
        let source = rangeIndex < 2 ? presentation.state.points : presentation.state.days
        let points = source.filter { $0.timestamp >= start && $0.timestamp <= now }
        let hasReports = presentation.state.labels.contains { $0.timestamp >= start && $0.timestamp <= now && $0.actual["mood"] != nil }
        guard points.count >= 2 || hasReports else {
            NSAttributedString(string: "Trends appear as you collect data—no invented history.", attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor
            ]).draw(in: NSRect(x: 8, y: 38, width: bounds.width - 16, height: 35)); return
        }
        let colors: [(CompassMetric, NSColor)] = [(.energy, .systemTeal), (.stress, .systemOrange), (.readiness, .systemBlue), (.mood, .systemPurple)]
        for (metric, color) in colors {
            if metric == .mood && !presentation.moodIsCalibrated { continue }
            let path = NSBezierPath(); var previous: Date?
            for index in stride(from: 0, to: points.count, by: max(1, points.count / 180)) {
                let point = points[index]
                guard let value = point.values[metric.rawValue], value.isFinite else { previous = nil; continue }
                let p = NSPoint(x: rect.minX + point.timestamp.timeIntervalSince(start) / duration * rect.width,
                                y: rect.maxY - max(0, min(100, value)) / 100 * rect.height)
                if let last = previous, point.timestamp.timeIntervalSince(last) <= (rangeIndex < 2 ? 1_200 : 2 * 86_400) { path.line(to: p) }
                else { path.move(to: p) }
                previous = point.timestamp
            }
            color.withAlphaComponent(0.85).setStroke(); path.lineWidth = 1.5; path.lineJoinStyle = .round; path.stroke()
        }
        // Manual mood reports are dots, intentionally distinct from estimates.
        for label in presentation.state.labels where label.timestamp >= start && label.timestamp <= now {
            guard let actual = label.actual["mood"] else { continue }
            let p = NSPoint(x: rect.minX + label.timestamp.timeIntervalSince(start) / duration * rect.width,
                            y: rect.maxY - actual / 100 * rect.height)
            NSColor.systemPurple.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)).fill()
        }
    }
}
