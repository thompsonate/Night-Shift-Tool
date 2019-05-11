//
//  RuleManager.swift
//
//
//  Created by Saagar Jha on 1/14/18.
//

import Cocoa
import SwiftLog
import ScriptingBridge


enum RuleType: String, Codable {
    case domain
    case subdomainDisabled
    case subdomainEnabled
}



enum SubdomainRuleType: String, Codable {
    case none
    case disabled
    case enabled
}



struct AppRule: CustomStringConvertible, Hashable, Codable {
    enum Identifier : CustomStringConvertible, Codable, Hashable {
        init(bundle: BundleIdentifier) {
            self = .Bundle(bundle)
        }
        
        init(executableURL: URL) {
            self = .ExecutableURL(executableURL)
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            do {
                let bundle =  try container.decode(BundleIdentifier.self, forKey: .bundle)
                self = .Bundle(bundle)
            } catch {
                let executableURL =  try container.decode(URL.self, forKey: .executableURL)
                self = .ExecutableURL(executableURL)
            }
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .Bundle(let value):
                try container.encode(value, forKey: .bundle)
            case .ExecutableURL(let value):
                try container.encode(value, forKey: .executableURL)
            }
        }
        
        enum CodingKeys: CodingKey {
            case bundle
            case executableURL
        }
        
        case Bundle(BundleIdentifier)
        case ExecutableURL(URL)
        
        var description: String {
            switch self {
            case .Bundle(let value):
                return value;
            case .ExecutableURL(let value):
                return value.absoluteString;
            }
        }
    }
    
    var identifier: Identifier
    var fullScreenOnly: Bool
    
    var description: String {
        return "Rule for \(identifier); full screen only: \(fullScreenOnly)"
    }
    
    static func == (lhs: AppRule, rhs: AppRule) -> Bool {
        return lhs.identifier == rhs.identifier
            && lhs.fullScreenOnly == rhs.fullScreenOnly
    }
}



struct BrowserRule: CustomStringConvertible, Hashable, Codable {
    var type: RuleType
    var host: String

    var description: String {
        return "Rule type: \(type) for host: \(host)"
    }

    static func == (lhs: BrowserRule, rhs: BrowserRule) -> Bool {
        return lhs.type == rhs.type
            && lhs.host == rhs.host
    }
}





enum RuleManager {
    
    static var disabledApps = Set<AppRule>() {
        didSet {
            UserDefaults.standard.set(try? PropertyListEncoder().encode(disabledApps), forKey: Keys.disabledApps)
        }
    }
    
    
    
    static var browserRules = Set<BrowserRule>() {
        didSet(newValue) {
            UserDefaults.standard.set(try? PropertyListEncoder().encode(browserRules), forKey: Keys.browserRules)
        }
    }
    
    
    
    static var currentApp: NSRunningApplication? {
        return NSWorkspace.shared.menuBarOwningApplication
    }
    
    
    
    static var disabledForApp: Bool {
        get {
            if let bundleIdentifier : BundleIdentifier = currentApp?.bundleIdentifier {
                return disabledApps.filter {
                    $0.identifier == AppRule.Identifier(bundle: bundleIdentifier) }.count > 0
            } else {
                logw("Could not obtain bundle identifier of current application")
                
                guard let executableURL = currentApp?.executableURL else {
                    logw("Could not obtain executable url of current application")
                    return false
                }
                return disabledApps.filter {
                        $0.identifier == AppRule.Identifier(executableURL: executableURL) }.count > 0
            }
        }
        set(newValue) {
            var rule : AppRule
            if let bundleIdentifier = currentApp?.bundleIdentifier {
                rule = AppRule(identifier: AppRule.Identifier(bundle: bundleIdentifier), fullScreenOnly: false)
            } else {
                guard let executableURL = currentApp?.executableURL else {
                    logw("Could not obtain executable url of current application")
                    return
                }
                rule = AppRule(identifier: AppRule.Identifier(executableURL: executableURL), fullScreenOnly: false)
            }

            if newValue {
                disabledApps.insert(rule)
                NightShiftManager.respond(to: .nightShiftDisableRuleActivated)
            } else {
                guard let index = disabledApps.firstIndex(of: rule) else { return }
                disabledApps.remove(at: index)
                NightShiftManager.respond(to: .nightShiftDisableRuleDeactivated)
            }
        }
    }
    
    
    
    static var disabledForDomain: Bool {
        get {
            guard let currentDomain = BrowserManager.currentDomain else { return false }
            let disabledDomain = browserRules.filter {
                $0.type == .domain && $0.host == currentDomain }.count > 0
            return disabledDomain
        }
        set(newValue) {
            guard let currentDomain = BrowserManager.currentDomain else { return }
            let rule = BrowserRule(type: .domain, host: currentDomain)
            if newValue {
                browserRules.insert(rule)
                NightShiftManager.respond(to: .nightShiftDisableRuleActivated)
            } else {
                guard let index = browserRules.firstIndex(of: rule) else { return }
                
                if ruleForSubdomain == .enabled {
                    ruleForSubdomain = .none
                }
                browserRules.remove(at: index)
                NightShiftManager.respond(to: .nightShiftDisableRuleDeactivated)
            }
        }
    }
    
    
    
    static var ruleForSubdomain: SubdomainRuleType {
        get {
            guard let currentSubdomain = BrowserManager.currentSubdomain else { return .none }
            
            if disabledForDomain {
                let isEnabled = (browserRules.filter {
                    $0.type == .subdomainEnabled
                        && $0.host == currentSubdomain
                    }.count > 0)
                if isEnabled {
                    return .enabled
                }
            } else {
                let isDisabled = (browserRules.filter {
                    $0.type == .subdomainDisabled
                        && $0.host == currentSubdomain
                    }.count > 0)
                if isDisabled {
                    return .disabled
                }
            }
            return .none
        }
        set(newValue) {
            guard let currentSubdomain = BrowserManager.currentSubdomain else { return }
            
            switch newValue {
            case .disabled:
                let rule = BrowserRule(type: .subdomainDisabled, host: currentSubdomain)
                browserRules.insert(rule)
                NightShiftManager.respond(to: .nightShiftDisableRuleActivated)
            case .enabled:
                let rule = BrowserRule(type: .subdomainEnabled, host: currentSubdomain)
                browserRules.insert(rule)
                NightShiftManager.respond(to: .nightShiftEnableRuleActivated)
            case .none:
                var rule: BrowserRule
                let prevValue = ruleForSubdomain
                
                //Remove rule from set before triggering NightShiftEvent
                switch prevValue {
                case .disabled:
                    rule = BrowserRule(type: .subdomainDisabled, host: currentSubdomain)
                case .enabled:
                    rule = BrowserRule(type: .subdomainEnabled, host: currentSubdomain)
                case .none:
                    return
                }
                guard let index = browserRules.firstIndex(of: rule) else { return }
                browserRules.remove(at: index)
                
                switch prevValue {
                case .disabled:
                    NightShiftManager.respond(to: .nightShiftDisableRuleDeactivated)
                case .enabled:
                    NightShiftManager.respond(to: .nightShiftEnableRuleDeactivated)
                case .none:
                    break
                }
            }
        }
    }
    
    
    
    static var disableRuleIsActive: Bool {
        return disabledForApp || (disabledForDomain && ruleForSubdomain != .enabled) || ruleForSubdomain == .disabled
    }
    
    
    
    static func removeRulesForCurrentState() {
        disabledForApp = false
        disabledForDomain = false
        ruleForSubdomain = .none
    }
    
    

    public static func initialize() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil,
                                                          queue: nil) {
            RuleManager.appSwitched(notification: $0)
        }
        
        if let appData = UserDefaults.standard.value(forKey: Keys.disabledApps) as? Data {
            do {
                disabledApps = try PropertyListDecoder().decode(Set<AppRule>.self, from: appData)
            } catch let error {
                logw("Error: \(error.localizedDescription)")
            }
        }
        
        if let browserData = UserDefaults.standard.value(forKey: Keys.browserRules) as? Data {
            do {
                browserRules = try PropertyListDecoder().decode(Set<BrowserRule>.self, from: browserData)
            } catch let error {
                logw("Error: \(error.localizedDescription)")
            }
        }
    }
    
    

    private static func appSwitched(notification: Notification) {
        BrowserManager.stopBrowserWatcher()
        if disabledForApp {
            NightShiftManager.respond(to: .nightShiftDisableRuleActivated)
        } else if BrowserManager.currentAppIsSupportedBrowser {
            BrowserManager.updateForSupportedBrowser()
        } else {
            NightShiftManager.respond(to: .nightShiftDisableRuleDeactivated)
        }
    }

    
}
