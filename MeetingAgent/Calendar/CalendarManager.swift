#if os(macOS)
import EventKit
import Combine

@MainActor
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    private let store = EKEventStore()

    @Published var authorizationStatus: PermissionStatus = .notDetermined
    @Published var todayEvents: [EKEvent] = []
    @Published var selectedEvent: EKEvent? = nil
    @Published var armedEventID: String? = nil
    @Published var autoStartCountdown: Int? = nil
    @Published var shouldAutoStart: Bool = false

    private var pollingTimer: Timer?

    private init() {
        authorizationStatus = checkStatus()
        if authorizationStatus == .granted {
            refreshEvents()
            startIdleTimer()
        }
    }

    // MARK: - Authorization

    func checkStatus() -> PermissionStatus {
        if #available(macOS 14.0, *) {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .granted
            case .denied, .restricted: return .denied
            default: return .notDetermined
            }
        } else {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .notDetermined
            }
        }
    }

    func requestAccess() async -> Bool {
        do {
            if #available(macOS 14.0, *) {
                let granted = try await store.requestFullAccessToEvents()
                authorizationStatus = granted ? .granted : .denied
                if granted {
                    refreshEvents()
                    startIdleTimer()
                }
                return granted
            } else {
                let granted = try await store.requestAccess(to: .event)
                authorizationStatus = granted ? .granted : .denied
                if granted {
                    refreshEvents()
                    startIdleTimer()
                }
                return granted
            }
        } catch {
            authorizationStatus = .denied
            return false
        }
    }

    // MARK: - Events

    func refreshEvents() {
        guard authorizationStatus == .granted else { return }

        let now = Date()
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.hour = 23
        components.minute = 59
        components.second = 59
        let endOfDay = Calendar.current.date(from: components) ?? now.addingTimeInterval(86400)

        let predicate = store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }

        todayEvents = events
    }

    func attendeeNames(for event: EKEvent) -> [String] {
        guard let attendees = event.attendees else { return [] }
        let organizer = event.organizer?.name
        return attendees
            .compactMap { $0.name }
            .filter { !$0.isEmpty && $0 != organizer }
    }

    // MARK: - Auto-start

    func armAutoStart(eventID: String) {
        armedEventID = eventID
        autoStartCountdown = nil
        startArmedTimer()
    }

    func disarmAutoStart() {
        armedEventID = nil
        autoStartCountdown = nil
        shouldAutoStart = false
        startIdleTimer()
    }

    // MARK: - Timers

    private func startIdleTimer() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshEvents()
            }
        }
    }

    private func startArmedTimer() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickArmedTimer()
            }
        }
    }

    private func tickArmedTimer() {
        guard let eventID = armedEventID,
              let event = todayEvents.first(where: { $0.eventIdentifier == eventID }) else {
            disarmAutoStart()
            return
        }

        let remaining = event.startDate.timeIntervalSinceNow
        if remaining <= 0 {
            autoStartCountdown = nil
            armedEventID = nil
            shouldAutoStart = true
            startIdleTimer()
        } else if remaining <= 60 {
            autoStartCountdown = Int(remaining)
        }
    }
}
#endif
