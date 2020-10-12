import Vapor
import FoundationToolz
import Foundation
import SwiftyToolz

// MARK: - Register Routes

func registerRoutes(on app: Application) throws {
    app.on(.GET) { req in
        "Hello, I'm the Language Service Host.\n\nEndpoints (Vapor Routes):\n\(routeList(for: app))"
    }
    
    registerRoutes(onLanguageService: app.grouped("languageservice"), on: app)
}

func registerRoutes(onLanguageService languageService: RoutesBuilder,
                    on app: Application) {
    languageService.on(.GET) { req in
        "Hello, I'm the Language Service.\n\nEndpoints (Vapor Routes):\n\(routeList(for: app))\n\nAnd all supported languages:\n\(languagesAsString())"
    }
    
    registerRoutes(onDashboard: languageService.grouped("dashboard"), on: app)
    
    registerRoutes(onAPI: languageService.grouped("api"))
}

// MARK: - Dashboard

func registerRoutes(onDashboard dashboard: RoutesBuilder, on app: Application) {
    dashboard.on(.GET) { req in
        "Hello, I'm the Language Service.\n\nEndpoints (Vapor Routes):\n\(routeList(for: app))\nSupported Languages:\n\(languagesAsString())"
    }

    let languageNameParameter = "languageName"

    dashboard.on(.GET, ":\(languageNameParameter)") { req -> String in
        let languageName = req.parameters.get(languageNameParameter)!
        let languageIsSupported = isAvailable(language: languageName)
        return "Hello, I'm the Language Service.\n\nThe language \(languageName.capitalized) is \(languageIsSupported ? "already" : "not yet") supported."
    }
}

func routeList(for app: Application) -> String {
    app.routes.all.map { $0.description }.reduce("") { $0 + $1 + "\n" }
}

// MARK: - Websocket API

func registerRoutes(onAPI api: RoutesBuilder) {
    let languageNameParameter = "languageName"
    
    api.webSocket(":\(languageNameParameter)") { request, ws in
        let languageName = request.parameters.get(languageNameParameter)!
        guard isAvailable(language: languageName) else {
            ws.send("Error accessing Language Service: \(languageName.capitalized) is currently not supported.")
            return
        }
        
        configureAndRunSwiftLanguageServer()
        
        websocket = ws
        
        ws.onBinary { ws, byteBuffer in
            let data = Data(buffer: byteBuffer)
            let dataString = data.utf8String ?? "error decoding data"
            print("received data from socket \(ObjectIdentifier(ws).hashValue) at endpoint for \(languageName):\n\(dataString)")
            swiftLanguageServer.receive(data)
        }
        
        ws.onClose.whenComplete { result in
            switch result {
            case .success:
                print("websocket did close")
            case .failure(let error):
                print("websocket failed to close: \(error.localizedDescription)")
            }
        }
    }
    
    api.on(.GET, "languages") { request -> String in
        if let responseString = languagesLowercased.encode()?.utf8String {
            return responseString
        } else {
            return "Error encoding language list"
        }
    }
}

fileprivate func configureAndRunSwiftLanguageServer() {
    swiftLanguageServer.didSendOutput = { outputData in
        let outputString = outputData.utf8String ?? "error decoding output"
        print("received output from Swift language server:\n" + outputString)

        websocket?.send([UInt8](outputData))
    }
    
    swiftLanguageServer.didSendError = { errorData in
        let errorString = errorData.utf8String ?? "error decoding error"
        print("received error from Swift language server:\n" + errorString)
    }

    swiftLanguageServer.run()
}

fileprivate var websocket: WebSocket?

// MARK: - Supported Languages

func languagesAsString() -> String {
    languagesLowercased.map { $0.capitalized }.reduce("") { $0 + $1 + "\n" }
}

func isAvailable(language: String) -> Bool {
    languagesLowercased.contains(language.lowercased())
}

let languagesLowercased: Set<String> = ["swift", "python", "java", "c++"]

// MARK: - Swift Language Server

let swiftLanguageServer = SwiftLanguageServer()
