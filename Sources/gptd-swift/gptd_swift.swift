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
    
    init(app: XCUIApplication) {
        self.app = app
    }
    
    func executeCommand(with data: [String: Any]) async {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: []) else {
            os_log("NativeActionExecutor: Failed to convert command data to JSON", log: OSLog.default, type: .error)
            return
        }
        
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(WebDriverPayload.self, from: jsonData) else {
            os_log("NativeActionExecutor: Failed to decode JSON payload", log: OSLog.default, type: .error)
            return
        }
        
        for group in payload.actions {
            switch group.type {
            case "pointer":
                await executePointerActions(group.actions)
            case "key":
                await executeKeyActions(group.actions)
            case "pause":
                await executePauseActions(group.actions)
            default:
                os_log("NativeActionExecutor: Unsupported action group type: %{public}@", log: OSLog.default, type: .error, group.type)
            }
        }
    }
    
    private func executePointerActions(_ actions: [WebDriverAction]) async {
        await MainActor.run {
            if actions.count == 4,
               let first = actions.first,
               first.type == "pointerMove",
               let x = first.x,
               let y = first.y {
                
                let coordinate = self.coordinateFor(x: x, y: y)
                coordinate.tap()
                
            } else if actions.count == 5,
                      let first = actions.first,
                      first.type == "pointerMove",
                      let xStart = first.x, let yStart = first.y,
                      let fourth = actions[safe: 3],
                      fourth.type == "pointerMove",
                      let xEnd = fourth.x, let yEnd = fourth.y {
                
                let startCoordinate = coordinateFor(x: xStart, y: yStart)
                let endCoordinate = coordinateFor(x: xEnd, y: yEnd)
                startCoordinate.press(forDuration: 0.1, thenDragTo: endCoordinate)
            } else {
                os_log("NativeActionExecutor: Unrecognized pointer actions pattern", log: OSLog.default, type: .error)
            }
        }
    }
    
    private func executeKeyActions(_ actions: [WebDriverAction]) async {
        await MainActor.run {
            if let first = actions.first,
               first.type == "keyDown",
               let value = first.value,
               value == "\u{e011}" {
                XCUIDevice.shared.press(.home)
            } else {
                var text = ""
                for action in actions {
                    if action.type == "keyDown", let char = action.value {
                        text.append(char)
                    }
                }
                self.app.typeText(text)
            }
        }
    }
    
    private func executePauseActions(_ actions: [WebDriverAction]) async {
        for action in actions {
            if action.type == "pause", let duration = action.duration {
                let nanoseconds = UInt64(duration) * 1_000_000
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    os_log("NativeActionExecutor: Pause interrupted with error: %{public}@", log: OSLog.default, type: .error, error.localizedDescription)
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
    
    /// Optional callback that is invoked when a new session is created.
    /// Use this to capture the session URL for logging, attachments, or custom handling.
    /// - Parameter sessionURL: The live session URL
    public var onSessionCreated: ((String) -> Void)?
    
    var logger = OSLog(subsystem: "com.gptdriver", category: "GPTD-Client")
    
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
    
    // MARK: - Initializer
    private init(apiKey: String,
                  appiumServerUrl: URL? = nil,
                  deviceName: String? = nil,
                  platform: String? = nil,
                  platformVersion: String? = nil,
                  nativeApp: XCUIApplication? = nil) {
        self.apiKey = apiKey
        self.appiumServerUrl = appiumServerUrl
        self.deviceName = deviceName
        self.platform = platform
        self.platformVersion = platformVersion
        self.gptDriverBaseUrl = URL(string: "https://api.mobileboost.io")!
        
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
    public convenience init(apiKey: String,
                            nativeApp: XCUIApplication = XCUIApplication()) {
        self.init(apiKey: apiKey, appiumServerUrl: nil, deviceName: nil, platform: nil, platformVersion: nil, nativeApp: nativeApp)
    }
    
    /// Initializes GptDriver for execution via a remote Appium server.
    /// - Parameters:
    ///   - apiKey: Your GPT Driver API key.
    ///   - appiumServerUrl: The URL of the Appium server.
    ///   - deviceName: The name of the target device (e.g., "iPhone 15 Pro").
    ///   - platform: The target platform (e.g., "iOS").
    ///   - platformVersion: The OS version of the target device (e.g., "18.2").
    public convenience init(apiKey: String,
                            appiumServerUrl: URL,
                            deviceName: String,
                            platform: String,
                            platformVersion: String) {
        self.init(apiKey: apiKey, appiumServerUrl: appiumServerUrl, deviceName: deviceName, platform: platform, platformVersion: platformVersion, nativeApp: nil)
    }
    
    deinit {
        customURLSession.invalidateAndCancel()
    }
    
    // MARK: - Public Methods
    public func execute(_ command: String) async throws {
        if !appiumSessionStarted || gptDriverSessionId == nil {
            try await startSession()
        }
        
        guard let gptDriverSessionId = gptDriverSessionId else {
            throw GPTDriverError.missingSessionId
        }
        
        var isDone = false
        while !isDone {
            let screenshotBase64 = try await takeScreenshotBase64()
            
            let requestBody: [String: Any] = [
                "api_key": apiKey,
                "command": command,
                "base64_screenshot": screenshotBase64
            ]
            
            let requestUrl = gptDriverBaseUrl
                .appendingPathComponent("sessions")
                .appendingPathComponent(gptDriverSessionId)
                .appendingPathComponent("execute")
            
            let responseData = try await postJson(to: requestUrl, jsonObject: requestBody)
            
            let executeResponse = try JSONDecoder().decode(ExecuteResponse.self, from: responseData)
            
            switch executeResponse.status {
            case "failed":
                let details = "\(String(describing: executeResponse.commands))"
                throw GPTDriverError.executionFailed("GPT Driver reported execution failed. " + details)
            case "inProgress":
                try await processCommands(executeResponse.commands)
            default:
                try await processCommands(executeResponse.commands)
                isDone = true
            }
            
            if !isDone {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
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
            "build_id": ""
        ]
        
        let responseData = try await postJson(to: url, jsonObject: body)
        
        guard
            let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let sessionId = json["sessionId"] as? String
        else {
            throw GPTDriverError.invalidResponse
        }
        let sessionURL = "https://app.mobileboost.io/gpt-driver/sessions/\(sessionId)"
        os_log("Live Session View: %@", log: OSLog.default, type: .info, sessionURL)
        self.gptDriverSessionId = sessionId
        self.sessionURL = sessionURL
        
        // Notify callback if provided
        onSessionCreated?(sessionURL)
    }
    
    // MARK: - Command Processing
    private func processCommands(_ commands: [AppiumCommand]) async throws {
        for command in commands {
            if let data = command.data,
               let actions = data["actions"] as? [[String: Any]],
               let firstAction = actions.first,
               let type = firstAction["type"] as? String,
               type == "pause",
               let duration = firstAction["duration"] as? Int {
                os_log("Executing pause for %{public}d seconds", log: logger, type: .info, duration)
                try await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
                continue
            }
            
            if let _ = appiumServerUrl {
                try await executeAppiumRequest(command: command)
            } else {
                guard let nativeApp = self.nativeApp else {
                    throw GPTDriverError.executionFailed("No native XCUIApplication provided in native mode")
                }
                let executor = NativeActionExecutor(app: nativeApp)
                if let data = command.data {
                    await executor.executeCommand(with: data)
                } else {
                    os_log("processCommands: Missing command data for command: %@", log: OSLog.default, type: .error, command.url)
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
                        os_log("Request succeeded on attempt %d", log: logger, type: .info, attempt + 1)
                    }
                    return data
                }
                
                if shouldRetry(statusCode: httpResponse.statusCode) && attempt < maxRetries - 1 {
                    let delay = exponentialBackoff(attempt: attempt)
                    os_log("Request failed with status %d, retrying after %f seconds", log: logger, type: .info, httpResponse.statusCode, delay)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                
                throw GPTDriverError.invalidResponse
            } catch let error as URLError {
                lastError = error
                os_log("Network error: %@ (code: %d)", log: logger, type: .error, error.localizedDescription, error.code.rawValue)
                
                if shouldRetryURLError(error) && attempt < maxRetries - 1 {
                    let delay = exponentialBackoff(attempt: attempt)
                    os_log("Retrying after %f seconds due to: %@", log: logger, type: .info, delay, error.localizedDescription)
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
        if appiumServerUrl == nil {
            guard let app = nativeApp else {
                throw GPTDriverError.invalidResponse
            }
            let screenshot = await app.windows.firstMatch.screenshot()
            return await screenshot.pngRepresentation.base64EncodedString()
        } else {
            let screenshot = await XCUIScreen.main.screenshot()
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
        
        do {
            let results = try await checkBulk([assertion], maxRetries: maxRetries, retryDelay: retryDelay)
            guard let firstResult = results.values.first, firstResult else {
                try await setSessionStatus(status: "failed")
                throw GPTDriverError.executionFailed("Failed assertion: \(assertion)")
            }
        } catch {
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
        
        do {
            let results = try await checkBulk(assertions, maxRetries: maxRetries, retryDelay: retryDelay)
            
            var failedAssertions: [String] = []
            for (index, result) in results.values.enumerated() {
                if !result, index < assertions.count {
                    failedAssertions.append(assertions[index])
                }
            }
            
            if !failedAssertions.isEmpty {
                try await setSessionStatus(status: "failed")
                throw GPTDriverError.executionFailed("Failed assertions: \(failedAssertions.joined(separator: ", "))")
            }
        } catch {
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
        
        os_log("Checking: %{public}@", log: logger, type: .info, conditions)
        
        var lastError: Error?
        var lastResults: [String: Bool]?
        
        for attempt in 0...maxRetries {
            do {
                // Take a screenshot using XCUI instead of Appium
                let screenshotBase64 = try await takeScreenshotBase64()
                
                // Build request to GPT Driver API
                let requestUrl = gptDriverBaseUrl
                    .appendingPathComponent("sessions")
                    .appendingPathComponent(gptDriverSessionId!)
                    .appendingPathComponent("assert")
                
                let requestBody: [String: Any] = [
                    "api_key": apiKey,
                    "base64_screenshot": screenshotBase64,
                    "assertions": conditions,
                    "command": "Assert: \(String(describing: try? JSONSerialization.data(withJSONObject: conditions, options: [])))"
                ]
                
                let responseData = try await postJson(to: requestUrl, jsonObject: requestBody)
                
                // Parse the response to get results
                guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                      let results = json["results"] as? [String: Bool] else {
                    throw GPTDriverError.invalidResponse
                }
                
                lastResults = results
                
                // Check if all conditions passed
                let allPassed = results.values.allSatisfy { $0 }
                
                if allPassed {
                    if attempt > 0 {
                        os_log("Check succeeded on attempt %d", log: logger, type: .info, attempt + 1)
                    }
                    return results
                }
                
                // Some conditions failed
                if attempt < maxRetries {
                    let failedConditions = results.filter { !$0.value }.keys.joined(separator: ", ")
                    os_log("Check failed on attempt %d (failed: %{public}@), retrying after %.1f seconds...", log: logger, type: .info, attempt + 1, failedConditions, retryDelay)
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    continue
                }
                
                // All retries exhausted, return the last results (with failures)
                return results
                
            } catch {
                lastError = error
                
                if attempt < maxRetries {
                    os_log("Check error on attempt %d: %@, retrying after %.1f seconds...", log: logger, type: .info, attempt + 1, error.localizedDescription, retryDelay)
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    continue
                }
                
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
        
        os_log("Stopping session...", log: logger, type: .info)
        
        let requestUrl = gptDriverBaseUrl
            .appendingPathComponent("sessions")
            .appendingPathComponent(gptDriverSessionId)
            .appendingPathComponent("stop")
        
        let requestBody: [String: Any] = [
            "api_key": apiKey,
            "status": status
        ]
        
        _ = try await postJson(to: requestUrl, jsonObject: requestBody)
        
        os_log("Session stopped", log: logger, type: .info)
        appiumSessionStarted = false
        self.gptDriverSessionId = nil
        self.sessionURL = nil
    }
    
    public func extract(_ extractions: [String]) async throws -> [String: Any] {
        if !appiumSessionStarted || gptDriverSessionId == nil {
            try await startSession()
        }
        
        os_log("Extracting: %{public}@", log: logger, type: .info, extractions.description)
        
        // Take a screenshot using XCUI
        let screenshotBase64 = try await takeScreenshotBase64()
        
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
            "command": "Extract: \(extractionsJson)"
        ]
        
        let responseData = try await postJson(to: requestUrl, jsonObject: requestBody)
        
        // Parse the response to get results
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let results = json["results"] as? [String: Any] else {
            throw GPTDriverError.invalidResponse
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
