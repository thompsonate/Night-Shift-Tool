//
//  NightShiftManager.swift
//  Shifty
//
//  Created by Saagar Jha on 1/13/18.
//

import Cocoa
import SwiftLog


extension Time: Equatable, Comparable {
    init(_ date: Date) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour,
            let minute = components.minute else {
                fatalError("Could not instantiate Time object")
        }
        self.init()
        self.hour = Int32(hour)
        self.minute = Int32(minute)
    }
    
    static var now: Time {
        return Time(Date())
    }
    
    public static func ==(lhs: Time, rhs: Time) -> Bool {
        return lhs.hour == rhs.hour && lhs.minute == rhs.minute
    }
    
    public static func < (lhs: Time, rhs: Time) -> Bool {
        if lhs.hour == rhs.hour {
            return lhs.minute < rhs.minute
        } else {
            return lhs.hour < rhs.hour
        }
    }
}

extension Date {
    init(_ time: Time) {
        var components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        components.hour = Int(time.hour)
        components.minute = Int(time.minute)
        if let date = Calendar.current.date(from: components) {
            self = date
        } else {
            fatalError("Could not instantiate Date object")
        }
    }
}

enum NightShiftEvent {
    case enteredScheduledNightShift
    case exitedScheduledNightShift
    case userEnabledNightShift
    case userDisabledNightShift
    case nightShiftDisableTimerStarted
    case nightShiftDisableTimerEnded
    case nightShiftDisableRuleActivated
    case nightShiftDisableRuleDeactivated
    case nightShiftEnableRuleActivated
    case nightShiftEnableRuleDeactivated
    case scheduleChanged
}

enum DisableTimer: Equatable {
    case off
    case hour(timer: Timer, endDate: Date)
    case custom(timer: Timer, endDate: Date)
    
    static func == (lhs: DisableTimer, rhs: DisableTimer) -> Bool {
        switch (lhs, rhs) {
        case (.off, .off):
            return true
        case (let .hour(leftTimer, leftDate), let .hour(rightTimer, rightDate)),
             (let .custom(leftTimer, leftDate), let .custom(rightTimer, rightDate)):
            return leftTimer == rightTimer && leftDate == rightDate
        default:
            return false
        }
    }
}

enum ScheduleType: Equatable {
    case off
    case solar
    case custom(start: Time, end: Time)
    
    static func == (lhs: ScheduleType, rhs: ScheduleType) -> Bool {
        switch (lhs, rhs) {
        case (.off, .off), (.solar, .solar):
            return true
        case (let .custom(leftStart, leftEnd), let custom(rightStart, rightEnd)):
            return leftStart == rightStart && leftEnd == rightEnd
        default:
            return false
        }
    }
}





enum NightShiftManager {
    private static let client = CBBlueLightClient()

    /// Nil if not set; true or false for the state the user has set it to
    static var userSet: Bool?
    static var userInitiatedShift = false
 
    private static var blueLightStatus: Status {
        var status: Status = Status()
        client.getBlueLightStatus(&status)
        return status
    }

    static var blueLightReductionAmount: Float {
        get {
            var strength: Float = 0
            client.getStrength(&strength)
            return strength
        }
        set {
            client.setStrength(newValue, commit: true)
        }
    }
    
    static func previewBlueLightReductionAmount(_ value: Float) {
        client.setStrength(value, commit: false)
    }

    static var isNightShiftEnabled: Bool {
        get {
            return blueLightStatus.enabled.boolValue
        }
        set {
            client.setEnabled(newValue)
            
            // Set to appropriate strength when in schedule transition by resetting schedule
            if newValue && scheduledState {
                let savedSchedule = schedule
                schedule = .off
                schedule = savedSchedule
            }
        }
    }

    static var supportsNightShift: Bool {
        get {
            return CBBlueLightClient.supportsBlueLightReduction()
        }
    }

    static var schedule: ScheduleType {
        get {
            switch blueLightStatus.mode {
            case 0:
                return .off
            case 1:
                return .solar
            case 2:
                return .custom(start: blueLightStatus.schedule.fromTime, end: blueLightStatus.schedule.toTime)
            default:
                assertionFailure("Unknown mode")
                return .off
            }
        }
        set {
            switch newValue {
            case .off:
                client.setMode(0)
            case .solar:
                client.setMode(1)
            case .custom(start: let start, end: let end):
                client.setMode(2)
                var schedule = Schedule(fromTime: start, toTime: end)
                client.setSchedule(&schedule)
            }
        }
    }
    
    static var scheduledState: Bool {
        switch schedule {
        case .off:
            return false
        case .custom(start: let startTime, end: let endTime):
            let now = Time(Date())
            if endTime > startTime {
                //startTime and endTime are on the same day
                let scheduledState = now >= startTime && now < endTime
                logw("scheduled state: \(scheduledState)")
                return scheduledState
            } else {
                //endTime is on the day following startTime
                let scheduledState = now >= startTime || now < endTime
                logw("scheduled state: \(scheduledState)")
                return scheduledState
            }
        case .solar:
            guard let sunrise = BrightnessSystemClient.shared?.sunrise,
                let sunset = BrightnessSystemClient.shared?.sunset else {
                logw("Found nil for object BrightnessSystemClient. Returning false for scheduledState.")
                return false
            }
            let now = Date()
            logw("sunset: \(sunset)")
            logw("sunrise: \(sunrise)")
            
            // For some reason, BrightnessSystemClient.isDaylight doesn't track perfectly with sunrise and sunset
            // Should return true when not daylight
            let scheduledState : Bool
            let order = NSCalendar.current.compare(sunrise, to: sunset, toGranularity: .day)
            switch order {
                case .orderedSame, .orderedAscending:
                    scheduledState = now >= sunset || now <= sunrise
                case .orderedDescending:
                    scheduledState = now >= sunset && now <= sunrise
            }
            logw("scheduled state: \(scheduledState)")
            return scheduledState
        }
    }
    
    public static func setToSchedule() {
        if isNightShiftEnabled != scheduledState {
            isNightShiftEnabled = scheduledState
        }
    }
    
    static var nightShiftDisableTimer = DisableTimer.off {
        willSet {
            switch nightShiftDisableTimer {
            case .hour(let timer, _), .custom(let timer, _):
                timer.invalidate()
            default: break
            }
        }
    }
    
    static var disabledTimer: Bool {
        return NightShiftManager.nightShiftDisableTimer != .off
    }
    
    ///When true, app or website rule has disabled Night Shift
    static var disableRuleIsActive: Bool {
        return RuleManager.disableRuleIsActive
    }

    public static func initialize() {
        var prevSchedule = schedule
        
        updateDarkMode()
        
        // @convention block called by CoreBrightness
        client.setStatusNotificationBlock {
            if schedule == prevSchedule {
                respond(to: isNightShiftEnabled ? .enteredScheduledNightShift : .exitedScheduledNightShift)
            } else {
                respond(to: .scheduleChanged)
                prevSchedule = schedule
            }
            
            DispatchQueue.main.async {
                let appDelegate = NSApplication.shared.delegate as! AppDelegate
                appDelegate.updateMenuBarIcon()
                
                let prefWindow = (NSApplication.shared.delegate as? AppDelegate)?.preferenceWindowController
                let prefGeneral = prefWindow?.viewControllers.compactMap { childViewController in
                    return childViewController as? PrefGeneralViewController
                    }.first
                
                prefGeneral?.updateSchedule?()
            }
            
            updateDarkMode()
        }
        
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            logw("Wake from sleep notification posted")
            
            if scheduledState != isNightShiftEnabled {
                respond(to: scheduledState ? .enteredScheduledNightShift : .exitedScheduledNightShift)
            }
            
            updateDarkMode()
        }
    }
    
    static func updateDarkMode() {
        if UserDefaults.standard.bool(forKey: Keys.isDarkModeSyncEnabled) {
            switch schedule {
            case .off:
                let darkModeState = isNightShiftEnabled || disableRuleIsActive || disabledTimer || userSet == true
                SLSSetAppearanceThemeLegacy(darkModeState)
                logw("Dark mode set to \(darkModeState)")
            case .solar:
                SLSSetAppearanceThemeLegacy(scheduledState)
                logw("Dark mode set to \(scheduledState)")
            case .custom(start: _, end: _):
                SLSSetAppearanceThemeLegacy(scheduledState)
                logw("Dark mode set to \(scheduledState)")
            }
        }
    }

    static func respond(to event: NightShiftEvent) {
        //Prevent BlueLightNotification from triggering one of these two events after every event
        if event == .enteredScheduledNightShift || event == .exitedScheduledNightShift {
            if userInitiatedShift {
                userInitiatedShift = false
                return
            } else {
                userInitiatedShift = false
            }
        } else {
            userInitiatedShift = true
        }
        
        switch event {
        case .enteredScheduledNightShift:
            userSet = nil
            if disabledTimer || disableRuleIsActive {
                isNightShiftEnabled = false
            }
        case .exitedScheduledNightShift:
            userSet = nil
        case .userEnabledNightShift:
            userSet = true
            nightShiftDisableTimer = .off
            
            if disableRuleIsActive {
                RuleManager.removeRulesForCurrentState()
            }
            isNightShiftEnabled = true
        case .userDisabledNightShift:
            isNightShiftEnabled = false
            userSet = false
        case .nightShiftDisableRuleActivated:
            isNightShiftEnabled = false
            if UserDefaults.standard.bool(forKey: Keys.trueToneControl) {
                if #available(macOS 10.14, *) {
                    CBTrueToneClient.shared.isTrueToneEnabled = false
                }
            }
        case .nightShiftDisableRuleDeactivated:
            if !disabledTimer && !disableRuleIsActive {
                if userSet != nil {
                    isNightShiftEnabled = userSet!
                } else {
                    setToSchedule()
                }
            }
            
            if !disableRuleIsActive && UserDefaults.standard.bool(forKey: Keys.trueToneControl) {
                if #available(macOS 10.14, *) {
                    CBTrueToneClient.shared.isTrueToneEnabled = true
                }
            }
        case .nightShiftEnableRuleActivated:
            isNightShiftEnabled = userSet ?? true
        case .nightShiftEnableRuleDeactivated:
            if disabledTimer || disableRuleIsActive {
                isNightShiftEnabled = false
            } else {
                setToSchedule()
            }
        case .nightShiftDisableTimerStarted:
            isNightShiftEnabled = false
        case .nightShiftDisableTimerEnded:
            if !disableRuleIsActive {
                if userSet != nil {
                    isNightShiftEnabled = userSet!
                } else {
                    setToSchedule()
                }
            }
        case .scheduleChanged:
            userSet = nil
            setToSchedule()
        }
        logw("Responded to event: \(event)")
    }
}
