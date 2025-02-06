# gptd-swift

A Swift package to utilize GPT Driver for executing commands on iOS devices.

## Overview

**gptd-swift** provides a convenient way to execute natural language commands via GPT Driver on your app. GPT Driver leverages Appium for device control. It’s designed for developers who want to integrate these capabilities into their iOS projects.

## Features

- **Session Management:** Automatically starts and manages Appium sessions.
- **Screenshot Capture:** Uses built-in iOS APIs to capture and process screenshots.
- **Command Execution:** Based on natural language instructions and screenshots executes commands on the device.


## Installation

Add this package in Xcode by navigating to **File > Swift Packages > Add Package Dependency** and entering the repository URL

## Usage

Reach out to us at [mobileboost.io](https://mobileboost.io) to get your API key.

```swift
import gptd_swift

// Initialize the driver with your API key and Appium server URL
let driver = GptDriver(apiKey: "YOUR_API_KEY", appiumServerUrl: URL(string: "http://localhost:4723")!)

// Execute a command asynchronously
try await driver.execute("Your command here")

```

## License

This project is licensed under the Business Source License. See the LICENSE file for details.