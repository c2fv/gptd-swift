import Foundation
import XCTest
import UIKit

// MARK: - Models
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

// MARK: - GptDriver Class
public class GptDriver {
    // MARK: - Properties
    
    private let apiKey: String
    private let appiumServerUrl: URL
    private let deviceName: String?
    private let platform: String?
    private let platformVersion: String?
    private var appiumSessionId: String?
    private var appiumSessionStarted = false
    private let gptDriverBaseUrl: URL
    private var gptDriverSessionId: String?
    
    // MARK: - Initializers
    public init(apiKey: String,
                appiumServerUrl: URL,
                deviceName: String? = nil,
                platform: String? = nil,
                platformVersion: String? = nil) {
        self.apiKey = apiKey
        self.appiumServerUrl = appiumServerUrl
        self.deviceName = deviceName
        self.platform = platform
        self.platformVersion = platformVersion
        self.gptDriverBaseUrl = URL(string: "https://api.mobileboost.io")!
    }
    
    // MARK: - Public Methods
    public func execute(_ command: String) async throws {

        if !appiumSessionStarted || gptDriverSessionId == nil {
            NSLog("No session started yet. Calling startSession()...")
            try await startSession()
            NSLog("Session started.")
        }
        
        guard let gptDriverSessionId = gptDriverSessionId else {
            throw GPTDriverError.missingSessionId
        }
        
        var isDone = false
        while !isDone {
            let screenshotBase64 = try await takeScreenshotBase64()
            NSLog("Captured screenshot, base64 length: \(screenshotBase64.count)")

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
                    throw GPTDriverError.executionFailed("GPT Driver reported execution failed.")
                    
                case "inProgress":
                    try await processCommands(executeResponse.commands)
                    
                default:
                    isDone = true
            }
            
            if !isDone {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
    
    // MARK: - Session Management (Appium + GPT Driver)
    
    private func startSession() async throws {
        if !appiumSessionStarted {
            if appiumSessionId == nil {
                self.appiumSessionId = try await createAppiumSession()
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
        let url = appiumServerUrl.appendingPathComponent("session")
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
        
        self.gptDriverSessionId = sessionId
    }
    
    // MARK: - Command Processing
    
    private func processCommands(_ commands: [AppiumCommand]) async throws {
        for command in commands {
            try await executeAppiumRequest(command: command)
        }
    }
    
    // MARK: - Network Helpers
    
    private func postJson(to url: URL, jsonObject: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let bodyData = try JSONSerialization.data(withJSONObject: jsonObject)
        request.httpBody = bodyData
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw GPTDriverError.invalidResponse
        }
        
        return data
    }
    
    private func getJson(from url: URL) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GPTDriverError.invalidResponse
        }
        return json
    }
    
    private func executeAppiumRequest(command: AppiumCommand) async throws {
        guard let endpoint = URL(string: command.url, relativeTo: appiumServerUrl) else {
            throw GPTDriverError.invalidResponse
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = command.method

        if let jsonDictionary = command.data {
            let bodyData = try JSONSerialization.data(withJSONObject: jsonDictionary)
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        
        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw GPTDriverError.invalidResponse
        }
    }
    
    // MARK: - Screenshot Helper
    
    private func takeScreenshotBase64() async throws -> String {
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
    
    private func getAppiumWindowRect() async throws -> CGSize {
        guard let appiumSessionId = appiumSessionId else {
            throw GPTDriverError.missingSessionId
        }

        let url = appiumServerUrl
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
    }

}

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
