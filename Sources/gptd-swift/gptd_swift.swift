import Foundation
import XCTest
import UIKit
import os

// MARK: - Models for Appium/GPT Commands

struct GPTCommand: Decodable {
    let url: String?
    let method: String?
    let data: CommandData?
}

struct CommandData: Decodable {
    let actions: [CommandAction]?
}

struct CommandAction: Decodable {
    let type: String
    let duration: Int?
}

struct ExecuteResponse: Decodable {
    let commands: [AppiumCommand]
    let status: String
    let cache_hit: Bool
}

struct AppiumCommand: Decodable {
    let method: String
    let url: String
    let data: [String: Any]?
    
    enum CodingKeys: String, CodingKey {
        case method
        case url
        case data
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.method = try container.decode(String.self, forKey: .method)
        self.url = try container.decode(String.self, forKey: .url)
        
        if let rawData = try? container.decode([String: AnyDecodable].self, forKey: .data) {
            self.data = rawData.mapValues { $0.value }
        } else if let stringData = try? container.decode(String.self, forKey: .data) {
            self.data = ["value": stringData]
        } else {
            self.data = nil
        }
    }
}

struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            value = doubleVal
        } else if let boolVal = try? container.decode(Bool.self) {
            value = boolVal
        } else if let stringVal = try? container.decode(String.self) {
            value = stringVal
        } else if let arrVal = try? container.decode([AnyDecodable].self) {
            value = arrVal.map { $0.value }
        } else if let dictVal = try? container.decode([String: AnyDecodable].self) {
            value = dictVal.mapValues { $0.value }
        } else {
            throw DecodingError.typeMismatch(
                AnyDecodable.self,
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Value cannot be decoded"))
        }
    }
}

enum GPTDriverError: Error {
    case executionFailed(String)
    case invalidResponse
    case missingSessionId
    case creationFailed(String)
}

/// Caching mode for GPT Driver interactions
public enum CachingMode: String {
    case none = "NONE"
    case interactionRegion = "INTERACTION_REGION"
    case fullScreen = "FULL_SCREEN"
}

enum GPTLogLevel {
    case debug
    case info
    case notice
    case warning
    case error
    
    var osLogType: OSLogType {
        switch self {
        case .debug:
            return .debug
        case .info:
            return .info
        case .notice:
            return .default
        case .warning:
            return .error
        case .error:
            return .fault
        }
    }
}

// MARK: - Native Executor Types

struct WebDriverPayload: Codable {
    let actions: [WebDriverActionGroup]
}

struct WebDriverActionGroup: Codable {
    let type: String
    let id: String?
    let parameters: [String: String]?
    let actions: [WebDriverAction]
}

struct WebDriverAction: Codable {
    let type: String
    let duration: Int?
    let x: Double?
    let y: Double?
    let button: Int?
    let value: String?
    
    enum CodingKeys: String, CodingKey {
        case type, duration, x, y, button, value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        
        if let xDouble = try? container.decodeIfPresent(Double.self, forKey: .x) {
            x = xDouble
        } else if let xString = try? container.decodeIfPresent(String.self, forKey: .x),
                  let convertedX = Double(xString) {
            x = convertedX
        } else {
            x = nil
        }
        
        if let yDouble = try? container.decodeIfPresent(Double.self, forKey: .y) {
            y = yDouble
        } else if let yString = try? container.decodeIfPresent(String.self, forKey: .y),
                  let convertedY = Double(yString) {
            y = convertedY
        } else {
            y = nil
        }
        
        button = try container.decodeIfPresent(Int.self, forKey: .button)
        value = try container.decodeIfPresent(String.self, forKey: .value)
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

class NativeActionExecutor {
    let app: XCUIApplication
    private let logger: Logger
    private let sessionIdProvider: () -> String?
    
    init(app: XCUIApplication, logger: Logger, sessionIdProvider: @escaping () -> String?) {
        self.app = app
        self.logger = logger
        self.sessionIdProvider = sessionIdProvider
    }
    
    private func log(_ level: GPTLogLevel, _ message: String, metadata: [String: Any] = [:]) {
        let sessionId = sessionIdProvider() ?? "no-session"
        let metadataString = metadata
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: ", ")
        if metadataString.isEmpty {
            logger.log(level: level.osLogType, "[gptd-session:\(sessionId)] \(message, privacy: .public)")
        } else {
            logger.log(level: level.osLogType, "[gptd-session:\(sessionId)] \(message, privacy: .public) | \(metadataString, privacy: .public)")
        }
    }
    
    func executeCommand(with data: [String: Any], cacheHit: Bool) async {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: []) else {
            log(.error, "NativeActionExecutor failed to convert command data to JSON")
            return
        }
        
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(WebDriverPayload.self, from: jsonData) else {
            log(.error, "NativeActionExecutor failed to decode JSON payload")
            return
        }
        
        for group in payload.actions {
            switch group.type {
            case "pointer":
                await executePointerActions(group.actions, cacheHit: cacheHit)
                do {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                } catch {
                    log(.warning, "Sleep after pointer actions interrupted", metadata: ["error": error.localizedDescription])
                }
            case "key":
                await executeKeyActions(group.actions, cacheHit: cacheHit)
            case "pause":
                await executePauseActions(group.actions, cacheHit: cacheHit)
            default:
                log(.error, "Unsupported action group type", metadata: ["groupType": group.type])
            }
        }
    }
    
    private func executePointerActions(_ actions: [WebDriverAction], cacheHit: Bool) async {
        let cacheLabel = cacheHit ? " [cached]" : ""
        await MainActor.run {
            if actions.count == 4,
               let first = actions.first,
               first.type == "pointerMove",
               let x = first.x,
               let y = first.y {
                
                var pressDuration: TimeInterval = 0.2
                if actions.count > 2 {
                    for action in actions {
                        if action.type == "pause", let duration = action.duration {
                            pressDuration = Double(duration) / 1000.0
                            break
                        }
                    }
                }
                
                let coordinate = self.coordinateFor(x: x, y: y)
                log(.info, "Pointer press", metadata: [
                    "x": x,
                    "y": y,
                    "duration": pressDuration,
                    "cacheHit": cacheHit
                ])
                XCTContext.runActivity(named: "GPTDriver Press for \(pressDuration)s at \(x), \(y)\(cacheLabel)") { _ in }
                coordinate.press(forDuration: pressDuration)
                
            } else if actions.count == 5,
                      let first = actions.first,
                      first.type == "pointerMove",
                      let xStart = first.x, let yStart = first.y,
                      let fourth = actions[safe: 3],
                      fourth.type == "pointerMove",
                      let xEnd = fourth.x, let yEnd = fourth.y {
                
                let startCoordinate = coordinateFor(x: xStart, y: yStart)
                let endCoordinate = coordinateFor(x: xEnd, y: yEnd)
                log(.info, "Pointer drag", metadata: [
                    "startX": xStart,
                    "startY": yStart,
                    "endX": xEnd,
                    "endY": yEnd,
                    "cacheHit": cacheHit
                ])
                XCTContext.runActivity(named: "GPTDriver Drag from \(xStart), \(yStart) to \(xEnd), \(yEnd)\(cacheLabel)") { _ in }
                startCoordinate.press(forDuration: 0.1, thenDragTo: endCoordinate)
            } else {
                log(.error, "Unrecognized pointer actions pattern", metadata: ["actionCount": actions.count])
            }
        }
    }
    
    private func executeKeyActions(_ actions: [WebDriverAction], cacheHit: Bool) async {
        let cacheLabel = cacheHit ? " [cached]" : ""
        await MainActor.run {
            if let first = actions.first,
               first.type == "keyDown",
               let value = first.value,
               value == "\u{e011}" {
                log(.info, "Invoking home button", metadata: ["cacheHit": cacheHit])
                XCTContext.runActivity(named: "GPTDriver Press Home Button\(cacheLabel)") { _ in }
                XCUIDevice.shared.press(.home)
            } else {
                var text = ""
                for action in actions {
                    if action.type == "keyDown", let char = action.value {
                        text.append(char)
                    }
                }
                log(.info, "Typing text", metadata: ["text": text, "cacheHit": cacheHit])
                XCTContext.runActivity(named: "GPTDriver Typing Text: \(text)\(cacheLabel)") { _ in }
                self.app.typeText(text)
            }
        }
    }
    
    private func executePauseActions(_ actions: [WebDriverAction], cacheHit: Bool) async {
        let cacheLabel = cacheHit ? " [cached]" : ""
        for action in actions {
            if action.type == "pause", let duration = action.duration {
                let nanoseconds = UInt64(duration) * 1_000_000
                do {
                    log(.info, "Pausing", metadata: ["durationMs": duration, "cacheHit": cacheHit])
                    XCTContext.runActivity(named: "GPTDriver Wait for \(duration)ms\(cacheLabel)") { _ in }
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    log(.error, "Pause interrupted", metadata: ["error": error.localizedDescription])
                }
            }
        }
    }

    
    private func coordinateFor(x: Double, y: Double) -> XCUICoordinate {
        let scale = UIScreen.main.scale
        let pointX = x / Double(scale)
        let pointY = y / Double(scale)
        
        let base = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        return base.withOffset(CGVector(dx: pointX, dy: pointY))
    }
}

// MARK: - GptDriver Class
public class GptDriver {
    // MARK: - Properties
    private let apiKey: String
    private let appiumServerUrl: URL?
    private let deviceName: String?
    private let platform: String?
    private let platformVersion: String?
    
    private let nativeApp: XCUIApplication?
    
    private var appiumSessionId: String?
    private var appiumSessionStarted = false
    private let gptDriverBaseUrl: URL
    private var gptDriverSessionId: String?
    public private(set) var sessionURL: String?
    
    private let cachingMode: CachingMode
    private let testId: String
    private var stepCounter: Int = 1
    
    /// Optional callback that is invoked when a new session is created.
    /// Use this to capture the session URL for logging, attachments, or custom handling.
    /// - Parameter sessionURL: The live session URL
    public var onSessionCreated: ((String) -> Void)?
    
    private let structuredLogger = Logger(subsystem: "com.gptdriver", category: "GPTD-Client")
    
    private lazy var customURLSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 180
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        delegateQueue.name = "com.gptdriver.network"
        
        return URLSession(configuration: configuration, 
                         delegate: nil, 
                         delegateQueue: delegateQueue)
    }()
    
    private func log(_ level: GPTLogLevel, _ message: String, metadata: [String: Any] = [:]) {
        let sessionId = gptDriverSessionId ?? "no-session"
        let metadataString = metadata
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: ", ")
        if metadataString.isEmpty {
            structuredLogger.log(level: level.osLogType, "[gptdriver][session:\(sessionId)] \(message, privacy: .public)")
        } else {
            structuredLogger.log(level: level.osLogType, "[gptdriver][session:\(sessionId)] \(message, privacy: .public) | \(metadataString, privacy: .public)")
        }
    }
    
    // MARK: - Initializer
    private init(apiKey: String,
                  appiumServerUrl: URL? = nil,
                  deviceName: String? = nil,
                  platform: String? = nil,
                  platformVersion: String? = nil,
                  nativeApp: XCUIApplication? = nil,
                  cachingMode: CachingMode = .none,
                  testId: String = "") {
        self.apiKey = apiKey
        self.appiumServerUrl = appiumServerUrl
        self.deviceName = deviceName
        self.platform = platform
        self.platformVersion = platformVersion
        self.gptDriverBaseUrl = URL(string: "https://api.mobileboost.io")!
        self.cachingMode = cachingMode
        self.testId = testId
        
        if appiumServerUrl == nil {
            self.nativeApp = nativeApp ?? XCUIApplication()
        } else {
            self.nativeApp = nil
        }
    }
    
    /// Initializes GptDriver for native XCUITest execution.
    /// - Parameters:
    ///   - apiKey: Your GPT Driver API key.
    ///   - nativeApp: The XCUIApplication instance representing the app under test. Defaults to `XCUIApplication()`
    ///   - cachingMode: The caching mode to use for interactions. Defaults to `.none`
    ///   - testId: Optional test identifier used for cache matching. Defaults to empty string.
    public convenience init(apiKey: String,
                            nativeApp: XCUIApplication = XCUIApplication(),
                            cachingMode: CachingMode = .none,
                            testId: String = "") {
        self.init(apiKey: apiKey, appiumServerUrl: nil, deviceName: nil, platform: nil, platformVersion: nil, nativeApp: nativeApp, cachingMode: cachingMode, testId: testId)
    }
    
    /// Initializes GptDriver for execution via a remote Appium server.
    /// - Parameters:
    ///   - apiKey: Your GPT Driver API key.
    ///   - appiumServerUrl: The URL of the Appium server.
    ///   - deviceName: The name of the target device (e.g., "iPhone 15 Pro").
    ///   - platform: The target platform (e.g., "iOS").
    ///   - platformVersion: The OS version of the target device (e.g., "18.2").
    ///   - cachingMode: The caching mode to use for interactions. Defaults to `.none`
    ///   - testId: Optional test identifier used for cache matching. Defaults to empty string.
    public convenience init(apiKey: String,
                            appiumServerUrl: URL,
                            deviceName: String,
                            platform: String,
                            platformVersion: String,
                            cachingMode: CachingMode = .none,
                            testId: String = "") {
        self.init(apiKey: apiKey, appiumServerUrl: appiumServerUrl, deviceName: deviceName, platform: platform, platformVersion: platformVersion, nativeApp: nil, cachingMode: cachingMode, testId: testId)
    }
    
    deinit {
        customURLSession.invalidateAndCancel()
    }
    
    // MARK: - Public Methods
    /// Executes a command using GPT Driver.
    /// - Parameters:
    ///   - command: The command to execute
    ///   - cachingMode: Optional caching mode that overrides the global setting for this execution
    public func execute(_ command: String, cachingMode: CachingMode? = nil) async throws {
        if !appiumSessionStarted || gptDriverSessionId == nil {
            try await startSession()
        }
        
        guard let gptDriverSessionId = gptDriverSessionId else {
            throw GPTDriverError.missingSessionId
        }
        
        let effectiveCachingMode = cachingMode ?? self.cachingMode
        
        let currentStep = stepCounter
        stepCounter += 1
        
        XCTContext.runActivity(named: "GPTDriver Execute: \(command)") { _ in }

        var isDone = false
        var iteration = 1
        while !isDone {
            let currentIteration = iteration
            log(.info, "Execute iteration started", metadata: [
                "iteration": currentIteration,
                "command": command,
                "stepCounter": currentStep,
                "caching_mode": effectiveCachingMode.rawValue
            ])
            // Take screenshot once and reuse for both API call and test attachment
            // This prevents race conditions and ensures consistency
            let screenshot = await XCUIScreen.main.screenshot()
            let screenshotBase64 = try await screenshotToBase64(screenshot: screenshot)
            
            XCTContext.runActivity(named: "GPTDriver take screenshot & query API for next action #\(currentIteration)") { activity in
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = "Screenshot"
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
            
            let requestBody: [String: Any] = [
                "api_key": apiKey,
                "command": command,
                "base64_screenshot": screenshotBase64,
                "step_counter": currentStep,
                "caching_mode": effectiveCachingMode.rawValue
            ]
            
            let requestUrl = gptDriverBaseUrl
                .appendingPathComponent("sessions")
                .appendingPathComponent(gptDriverSessionId)
                .appendingPathComponent("execute")
            
            let responseData = try await postJson(to: requestUrl, jsonObject: requestBody)
            
            let executeResponse = try JSONDecoder().decode(ExecuteResponse.self, from: responseData)
            log(.info, "Execute iteration response", metadata: [
                "iteration": currentIteration,
                "status": executeResponse.status,
                "commandCount": executeResponse.commands.count,
                "cache_hit": executeResponse.cache_hit
            ])
            
            switch executeResponse.status {
            case "failed":
                let errorMessages = executeResponse.commands.compactMap { command -> String? in
                    guard let data = command.data, let value = data["value"] as? String else { return nil }
                    return value
                }
                let errorMessage = errorMessages.joined(separator: "; ")
                log(.error, "Execute iteration failed", metadata: [
                    "iteration": currentIteration,
                    "errorMessage": errorMessage,
                    "cache_hit": executeResponse.cache_hit
                ])
                throw GPTDriverError.executionFailed(errorMessage.isEmpty ? "GPT Driver execution failed" : errorMessage)
            case "inProgress":
                try await processCommands(executeResponse.commands, cacheHit: executeResponse.cache_hit)
            default:
                try await processCommands(executeResponse.commands, cacheHit: executeResponse.cache_hit)
                isDone = true
            }
            
            if !isDone {
                log(.info, "Execute waiting before next iteration", metadata: [
                    "currentIteration": currentIteration
                ])
                iteration += 1
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        log(.info, "Execute completed", metadata: ["iterations": iteration])
    }
    
    // MARK: - Session Management
    private func startSession() async throws {
        if !appiumSessionStarted {
            if let _ = appiumServerUrl {
                if appiumSessionId == nil {
                    self.appiumSessionId = try await createAppiumSession()
                }
            } else {
                self.appiumSessionId = "native"
            }
            
            if (appiumSessionId != nil) {
                appiumSessionStarted = true
            } else {
                throw GPTDriverError.creationFailed("Could not obtain an Appium session ID.")
            }
        }
        
        if gptDriverSessionId == nil {
            try await createGptDriverSession()
        }
    }
    
    private func createAppiumSession() async throws -> String {
        guard let appiumUrl = appiumServerUrl else { return "native" }
        
        let url = appiumUrl.appendingPathComponent("session")
        let finalPlatform = platform ?? "iOS"
        let capabilities: [String: Any] = [
            "alwaysMatch": [
                "platformName": finalPlatform,
                "appium:automationName": (finalPlatform.lowercased() == "ios") ? "XCUITest" : "UiAutomator2",
                "appium:deviceName": deviceName ?? "iPhone16",
                "appium:platformVersion": platformVersion ?? "18.0"
            ]
        ]
        
        let requestBody: [String: Any] = [
            "capabilities": capabilities
        ]
        
        let responseData = try await postJson(to: url, jsonObject: requestBody)
        
        guard
            let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let value = json["value"] as? [String: Any],
            let sessionId = value["sessionId"] as? String
        else {
            throw GPTDriverError.invalidResponse
        }
        
        return sessionId
    }
    
    private func createGptDriverSession() async throws {
        guard let appiumSessionId = appiumSessionId else {
            throw GPTDriverError.missingSessionId
        }
        
        let url = gptDriverBaseUrl
            .appendingPathComponent("sessions")
            .appendingPathComponent("create")
        
        let body: [String: Any] = [
            "api_key": apiKey,
            "appium_session_id": appiumSessionId,
            "device_config": [
                "platform": platform ?? "",
                "device": deviceName ?? "",
                "os": platformVersion ?? ""
            ],
            "use_internal_virtual_device": false,
            "build_id": "",
            "test_id": testId,
            "caching_mode": cachingMode.rawValue
        ]
        
        let responseData = try await postJson(to: url, jsonObject: body)
        
        guard
            let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let sessionId = json["sessionId"] as? String
        else {
            throw GPTDriverError.invalidResponse
        }
        let sessionURL = "https://app.mobileboost.io/gpt-driver/sessions/\(sessionId)"
        log(.notice, "Live Session View", metadata: ["sessionURL": sessionURL])
        self.gptDriverSessionId = sessionId
        self.sessionURL = sessionURL

        XCTContext.runActivity(named: "GPTDriver Live Session URL") { activity in
            if let url = URL(string: sessionURL) {
                let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                let fileName = "gptd-session-link.webloc"
                let fileURL = tempDirectory.appendingPathComponent(fileName)
                let weblocPayload = ["URL": url.absoluteString]

                if let data = try? PropertyListSerialization.data(fromPropertyList: weblocPayload,
                                                                  format: .xml,
                                                                  options: 0) {
                    do {
                        try data.write(to: fileURL, options: [.atomic])
                        let linkAttachment = XCTAttachment(contentsOfFile: fileURL)
                        linkAttachment.name = "GPTDriver Session URL Link"
                        linkAttachment.lifetime = .keepAlways
                        linkAttachment.userInfo = ["link": url.absoluteString]
                        activity.add(linkAttachment)
                    } catch {
                        log(.warning, "Failed to persist live session link attachment",
                            metadata: ["error": error.localizedDescription])
                    }

                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
        
        // Notify callback if provided
        onSessionCreated?(sessionURL)
    }
    
    // MARK: - Command Processing
    private func processCommands(_ commands: [AppiumCommand], cacheHit: Bool) async throws {
        let cacheLabel = cacheHit ? " [cached]" : ""
        for command in commands {
            if let data = command.data,
               let actions = data["actions"] as? [[String: Any]],
               let firstAction = actions.first,
               let type = firstAction["type"] as? String,
               type == "pause",
               let duration = firstAction["duration"] as? Int {
                log(.info, "Executing pause", metadata: ["durationSeconds": duration, "cacheHit": cacheHit])
                XCTContext.runActivity(named: "GPTDriver Wait for \(duration)s\(cacheLabel)") { _ in }
                try await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
                continue
            }
            
            if let _ = appiumServerUrl {
                try await executeAppiumRequest(command: command)
            } else {
                guard let nativeApp = self.nativeApp else {
                    throw GPTDriverError.executionFailed("No native XCUIApplication provided in native mode")
                }
                let executor = NativeActionExecutor(app: nativeApp,
                                                    logger: structuredLogger,
                                                    sessionIdProvider: { [weak self] in
                                                        self?.gptDriverSessionId
                                                    })
                if let data = command.data {
                    await executor.executeCommand(with: data, cacheHit: cacheHit)
                } else {
                    log(.error, "processCommands missing command data", metadata: ["endpoint": command.url])
                }
            }
        }
    }
    
    // MARK: - Network Helpers
    private func postJson(to url: URL, jsonObject: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        
        let bodyData = try JSONSerialization.data(withJSONObject: jsonObject)
        request.httpBody = bodyData
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        return try await performRequestWithRetry(request: request)
    }
    
    private func performRequestWithRetry(request: URLRequest, maxRetries: Int = 3) async throws -> Data {
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                let (data, response) = try await customURLSession.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw GPTDriverError.invalidResponse
                }
                
                if 200..<300 ~= httpResponse.statusCode {
                    if attempt > 0 {
                        log(.info, "Request succeeded after retry", metadata: ["attempt": attempt + 1])
                    }
                    return data
                }
                
                if shouldRetry(statusCode: httpResponse.statusCode) && attempt < maxRetries - 1 {
                    let delay = exponentialBackoff(attempt: attempt)
                    log(.info, "Request failed with retryable status", metadata: [
                        "statusCode": httpResponse.statusCode,
                        "retryDelay": delay,
                        "attempt": attempt + 1
                    ])
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                
                throw GPTDriverError.invalidResponse
            } catch let error as URLError {
                lastError = error
                log(.error, "Network error", metadata: [
                    "code": error.code.rawValue,
                    "description": error.localizedDescription,
                    "attempt": attempt + 1
                ])
                
                if shouldRetryURLError(error) && attempt < maxRetries - 1 {
                    let delay = exponentialBackoff(attempt: attempt)
                    log(.info, "Retrying after network error", metadata: [
                        "retryDelay": delay,
                        "description": error.localizedDescription,
                        "attempt": attempt + 1
                    ])
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                
                throw error
            } catch {
                lastError = error
                throw error
            }
        }
        
        throw lastError ?? GPTDriverError.invalidResponse
    }
    
    private func shouldRetry(statusCode: Int) -> Bool {
        // Retry on server errors and rate limiting
        return statusCode >= 500 || statusCode == 429 || statusCode == 408
    }
    
    private func shouldRetryURLError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .networkConnectionLost,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
    
    private func exponentialBackoff(attempt: Int) -> Double {
        return min(pow(2.0, Double(attempt)) * 2.0, 16.0)
    }
    
    private func getJson(from url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 90
        
        let data = try await performRequestWithRetry(request: request)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GPTDriverError.invalidResponse
        }
        return json
    }
    
    private func executeAppiumRequest(command: AppiumCommand) async throws {
        guard let serverUrl = appiumServerUrl,
              let endpoint = URL(string: command.url, relativeTo: serverUrl) else {
            throw GPTDriverError.invalidResponse
        }
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = command.method
        request.timeoutInterval = 90
        
        if let jsonDictionary = command.data {
            let bodyData = try JSONSerialization.data(withJSONObject: jsonDictionary)
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        
        _ = try await performRequestWithRetry(request: request)
    }
    
    // MARK: - Screenshot Helper
    private func takeScreenshotBase64() async throws -> String {
        let screenshot = await XCUIScreen.main.screenshot()
        return try await screenshotToBase64(screenshot: screenshot)
    }
    
    private func screenshotToBase64(screenshot: XCUIScreenshot) async throws -> String {
        if appiumServerUrl == nil {
            return await screenshot.pngRepresentation.base64EncodedString()
        } else {
            let pngData = await screenshot.pngRepresentation
            guard let image = UIImage(data: pngData) else {
                throw GPTDriverError.invalidResponse
            }
            
            let windowSize = try await getAppiumWindowRect()
            let resizedImage = image.resize(to: CGSize(width: windowSize.width, height: windowSize.height))
            
            guard let resizedPngData = resizedImage.pngData() else {
                throw GPTDriverError.invalidResponse
            }
            return resizedPngData.base64EncodedString()
        }
    }

    
    private func getAppiumWindowRect() async throws -> CGSize {
        if let serverUrl = appiumServerUrl, let appiumSessionId = appiumSessionId {
            let url = serverUrl
                .appendingPathComponent("session")
                .appendingPathComponent(appiumSessionId)
                .appendingPathComponent("window")
                .appendingPathComponent("rect")
            
            let responseJson = try await getJson(from: url)
            
            guard let valueDict = responseJson["value"] as? [String: Any],
                  let width = valueDict["width"] as? CGFloat,
                  let height = valueDict["height"] as? CGFloat else {
                throw GPTDriverError.invalidResponse
            }
            
            return CGSize(width: width, height: height)
        } else {
            guard let app = nativeApp else {
                throw GPTDriverError.invalidResponse
            }
            let frame = await app.windows.firstMatch.frame
            return frame.size
        }
    }

    // MARK: - Assertion Methods
    /// Asserts a condition with automatic retries.
    /// 
    /// - Parameters:
    ///   - assertion: The condition to assert
    ///   - maxRetries: Number of retry attempts (default: 2)
    ///   - retryDelay: Delay in seconds between retries (default: 1.0)
    public func assert(_ assertion: String, maxRetries: Int = 2, retryDelay: TimeInterval = 1.0) async throws {
        if !appiumSessionStarted || gptDriverSessionId == nil {
            try await startSession()
        }
        
        log(.info, "Assert start", metadata: [
            "assertion": assertion,
            "maxRetries": maxRetries,
            "retryDelaySeconds": retryDelay
        ])
        
        do {
            let results = try await checkBulk([assertion], maxRetries: maxRetries, retryDelay: retryDelay)
            guard let firstResult = results.values.first, firstResult else {
                let message = "Failed assertion: \(assertion)"
                log(.error, "Assert failed", metadata: ["assertion": assertion])
                try await setSessionStatus(status: "failed")
                throw GPTDriverError.executionFailed(message)
            }
            log(.info, "Assert passed", metadata: ["assertion": assertion])
        } catch {
            log(.error, "Assert threw error", metadata: ["error": error.localizedDescription, "assertion": assertion])
            try await setSessionStatus(status: "failed")
            throw error
        }
    }

    /// Asserts multiple conditions with automatic retries.
    ///
    /// - Parameters:
    ///   - assertions: Array of conditions to assert
    ///   - maxRetries: Number of retry attempts (default: 2)
    ///   - retryDelay: Delay in seconds between retries (default: 1.0)
    public func assertBulk(_ assertions: [String], maxRetries: Int = 2, retryDelay: TimeInterval = 1.0) async throws {
        if !appiumSessionStarted || gptDriverSessionId == nil {
            try await startSession()
        }
        
        log(.info, "AssertBulk start", metadata: [
            "count": assertions.count,
            "maxRetries": maxRetries,
            "retryDelaySeconds": retryDelay
        ])
        
        do {
            let results = try await checkBulk(assertions, maxRetries: maxRetries, retryDelay: retryDelay)
            
            var failedAssertions: [String] = []
            for (index, result) in results.values.enumerated() {
                if !result, index < assertions.count {
                    failedAssertions.append(assertions[index])
                }
            }
            
            if !failedAssertions.isEmpty {
                let message = "Failed assertions: \(failedAssertions.joined(separator: ", "))"
                log(.error, "AssertBulk failed", metadata: [
                    "failedCount": failedAssertions.count
                ])
                try await setSessionStatus(status: "failed")
                throw GPTDriverError.executionFailed(message)
            }
            log(.info, "AssertBulk passed", metadata: ["count": assertions.count])
        } catch {
            log(.error, "AssertBulk threw error", metadata: [
                "error": error.localizedDescription
            ])
            try await setSessionStatus(status: "failed")
            throw error
        }
    }

    /// Checks multiple conditions with automatic retries.
    ///
    /// - Parameters:
    ///   - conditions: Array of conditions to check
    ///   - maxRetries: Number of retry attempts (default: 2)
    ///   - retryDelay: Delay in seconds between retries (default: 1.0)
    /// - Returns: Dictionary mapping conditions to boolean results
    public func checkBulk(_ conditions: [String], maxRetries: Int = 2, retryDelay: TimeInterval = 1.0) async throws -> [String: Bool] {
        if !appiumSessionStarted || gptDriverSessionId == nil {
            try await startSession()
        }
        
        let currentStep = stepCounter
        stepCounter += 1
        
        log(.info, "Checking conditions", metadata: [
            "count": conditions.count,
            "maxRetries": maxRetries,
            "retryDelaySeconds": retryDelay,
            "stepCounter": currentStep,
            "caching_mode": cachingMode.rawValue
        ])
        
        var lastError: Error?
        var lastResults: [String: Bool]?
        
        for attempt in 0...maxRetries {
            do {
                log(.info, "Check attempt started", metadata: ["attempt": attempt + 1])
                // Take a screenshot and reuse for both API call and test attachment
                let screenshot = await XCUIScreen.main.screenshot()
                let screenshotBase64 = try await screenshotToBase64(screenshot: screenshot)
                
                // Build request to GPT Driver API
                let requestUrl = gptDriverBaseUrl
                    .appendingPathComponent("sessions")
                    .appendingPathComponent(gptDriverSessionId!)
                    .appendingPathComponent("assert")
                
                let requestBody: [String: Any] = [
                    "api_key": apiKey,
                    "base64_screenshot": screenshotBase64,
                    "assertions": conditions,
                    "command": "Assert: \(String(describing: try? JSONSerialization.data(withJSONObject: conditions, options: [])))",
                    "step_counter": currentStep,
                    "caching_mode": cachingMode.rawValue
                ]
                
                let responseData = try await postJson(to: requestUrl, jsonObject: requestBody)
                
                // Parse the response to get results
                guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                      let results = json["results"] as? [String: Bool] else {
                    throw GPTDriverError.invalidResponse
                }
                
                let cacheHit = json["cache_hit"] as? Bool ?? false
                let cacheLabel = cacheHit ? " [cached]" : ""
                
                lastResults = results
                
                // Check if all conditions passed
                let allPassed = results.values.allSatisfy { $0 }
                
                if allPassed {
                    log(.info, "Check succeeded", metadata: ["attempt": attempt + 1, "cacheHit": cacheHit])
                    XCTContext.runActivity(named: "GPTDriver Assert passed\(cacheLabel)") { activity in
                        let attachment = XCTAttachment(screenshot: screenshot)
                        attachment.name = "Screenshot"
                        attachment.lifetime = .keepAlways
                        activity.add(attachment)
                    }
                    return results
                }
                
                // Some conditions failed
                if attempt < maxRetries {
                    let failedConditions = results.filter { !$0.value }.keys.joined(separator: ", ")
                    log(.info, "Check failed will retry", metadata: [
                        "attempt": attempt + 1,
                        "failedConditions": failedConditions,
                        "retryDelaySeconds": retryDelay,
                        "cacheHit": cacheHit
                    ])
                    XCTContext.runActivity(named: "GPTDriver Assert failed, retrying\(cacheLabel)") { activity in
                        let attachment = XCTAttachment(screenshot: screenshot)
                        attachment.name = "Screenshot"
                        attachment.lifetime = .keepAlways
                        activity.add(attachment)
                    }
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    continue
                }
                
                // All retries exhausted, return the last results (with failures)
                log(.error, "Check exhausted retries with failures", metadata: [
                    "attempts": attempt + 1,
                    "cacheHit": cacheHit
                ])
                XCTContext.runActivity(named: "GPTDriver Assert failed\(cacheLabel)") { activity in
                    let attachment = XCTAttachment(screenshot: screenshot)
                    attachment.name = "Screenshot"
                    attachment.lifetime = .keepAlways
                    activity.add(attachment)
                }
                return results
                
            } catch {
                lastError = error
                
                if attempt < maxRetries {
                    log(.warning, "Check error will retry", metadata: [
                        "attempt": attempt + 1,
                        "error": error.localizedDescription,
                        "retryDelaySeconds": retryDelay
                    ])
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    continue
                }
                
                log(.error, "CheckBulk exhausted retries with error", metadata: [
                    "attempt": attempt + 1,
                    "error": error.localizedDescription
                ])
                try await setSessionStatus(status: "failed")
                throw error
            }
        }
        
        // Fallback: return last results if available, otherwise throw last error
        if let results = lastResults {
            return results
        }
        throw lastError ?? GPTDriverError.invalidResponse
    }

    public func setSessionStatus(status: String) async throws {
        guard let gptDriverSessionId = gptDriverSessionId else {
            return
        }
        
        log(.info, "Stopping session", metadata: ["status": status])
        
        let requestUrl = gptDriverBaseUrl
            .appendingPathComponent("sessions")
            .appendingPathComponent(gptDriverSessionId)
            .appendingPathComponent("stop")
        
        let requestBody: [String: Any] = [
            "api_key": apiKey,
            "status": status
        ]
        
        _ = try await postJson(to: requestUrl, jsonObject: requestBody)
        
        log(.info, "Session stopped")
        appiumSessionStarted = false
        self.gptDriverSessionId = nil
        self.sessionURL = nil
    }
    
    public func extract(_ extractions: [String]) async throws -> [String: Any] {
        if !appiumSessionStarted || gptDriverSessionId == nil {
            try await startSession()
        }
        
        let currentStep = stepCounter
        stepCounter += 1
        
        log(.info, "Extracting values", metadata: [
            "count": extractions.count,
            "stepCounter": currentStep,
            "caching_mode": cachingMode.rawValue
        ])
        
        // Take a screenshot and reuse for both API call and test attachment
        let screenshot = await XCUIScreen.main.screenshot()
        let screenshotBase64 = try await screenshotToBase64(screenshot: screenshot)
        
        // Build request to GPT Driver API
        let requestUrl = gptDriverBaseUrl
            .appendingPathComponent("sessions")
            .appendingPathComponent(gptDriverSessionId!)
            .appendingPathComponent("extract")
        
        var extractionsJson = ""
        if let data = try? JSONSerialization.data(withJSONObject: extractions, options: []),
           let jsonString = String(data: data, encoding: .utf8) {
            extractionsJson = jsonString
        }
        
        let requestBody: [String: Any] = [
            "api_key": apiKey,
            "base64_screenshot": screenshotBase64,
            "extractions": extractions,
            "command": "Extract: \(extractionsJson)",
            "step_counter": currentStep,
            "caching_mode": cachingMode.rawValue
        ]
        
        let responseData = try await postJson(to: requestUrl, jsonObject: requestBody)
        
        // Parse the response to get results
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let results = json["results"] as? [String: Any] else {
            throw GPTDriverError.invalidResponse
        }
        
        let cacheHit = json["cache_hit"] as? Bool ?? false
        let cacheLabel = cacheHit ? " [cached]" : ""
        
        log(.info, "Extract completed", metadata: [
            "count": results.count,
            "cacheHit": cacheHit
        ])
        XCTContext.runActivity(named: "GPTDriver Extract completed\(cacheLabel)") { activity in
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "Screenshot"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        
        return results
    }
}

// MARK: - UIImage Resize Extension
extension UIImage {
    func resize(to targetSize: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
