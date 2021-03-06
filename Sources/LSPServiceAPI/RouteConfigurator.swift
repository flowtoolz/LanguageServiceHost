import Vapor
import Foundation
import SwiftyToolz

struct RouteConfigurator {

    func registerRoutes(on app: Application) throws {
        app.on(.GET) { req in
            "Hello, I'm the Language Service Host.\n\nEndpoints (Vapor Routes):\n\(routeList(for: app))"
        }
        
        registerRoutes(onLSPService: app.grouped("lspservice"), on: app)
    }

    private func registerRoutes(onLSPService lspService: RoutesBuilder, on app: Application) {
        lspService.on(.GET) { _ in
            "👋🏻 Hello, I'm the Language Service.\n\nEndpoints (Vapor Routes):\n\(routeList(for: app))\n\nAvailable languages:\n\(languagesJoined(by: "\n"))"
        }

        let languageNameParameter = "languageName"

        lspService.on(.GET, ":\(languageNameParameter)") { req -> String in
            let language = req.parameters.get(languageNameParameter)!
            let executablePath = LanguageServer.Config.all[language.lowercased()]?.executablePath
            return "Hello, I'm the Language Service.\n\nThe language \(language.capitalized) has this associated language server:\n\(executablePath ?? "None")"
        }
        
        registerRoutes(onAPI: lspService.grouped("api"))
    }

    private func routeList(for app: Application) -> String {
        app.routes.all.map { $0.description }.joined(separator: "\n")
    }

    // MARK: - API

    private func registerRoutes(onAPI api: RoutesBuilder) {
        api.on(.GET, "languages") { _ in
            Array(LanguageServer.Config.all.keys)
        }
        
        api.on(.GET, "processID") { _ in
            Int(ProcessInfo.processInfo.processIdentifier)
        }
        
        registerRoutes(onLanguage: api.grouped("language"))
    }

    private func registerRoutes(onLanguage language: RoutesBuilder) {
        let languageNameParameter = "languageName"
        
        language.webSocket(":\(languageNameParameter)", "websocket") { request, newWebsocket in
            newWebsocket.onClose.whenComplete { result in
                switch result {
                case .success:
                    request.logger.info("websocket did close")
                case .failure(let error):
                    request.logger.error("websocket failed to close: \(error.localizedDescription)")
                }
            }
            
            let languageName = request.parameters.get(languageNameParameter)!
            
            do
            {
                try configureAndRunLanguageServer(forLanguage: languageName)
            }
            catch
            {
                let errorFeedbackWasSent = request.eventLoop.makePromise(of: Void.self)
                errorFeedbackWasSent.futureResult.whenComplete { _ in
                    newWebsocket.close(promise: nil)
                }
                
                let errorMessage = "\(languageName.capitalized) language server couldn't be initialized: \(error.readable.message)"
                newWebsocket.send(errorMessage, promise: errorFeedbackWasSent)
                
                return
            }
            
            newWebsocket.onBinary { ws, lspPacketBytes in
                let lspPacket = Data(buffer: lspPacketBytes)
                LanguageServer.active?.receive(lspPacket: lspPacket)
            }
            
            websocket?.close(promise: nil)
            websocket = newWebsocket
        }

        language.on(.GET, ":\(languageNameParameter)") { request -> String in
            let language = request.parameters.get(languageNameParameter)!
            guard let executablePath = LanguageServer.Config.all[language.lowercased()]?.executablePath else {
                throw Abort(.noContent,
                            reason: "No LSP server path has been set for \(language.capitalized)")
            }
            return executablePath
        }
        
        language.on(.POST, ":\(languageNameParameter)") { request -> HTTPStatus in
            let executablePath = request.body.string ?? ""
            guard URL(fromFilePath: executablePath) != nil else {
                throw Abort(.badRequest,
                            reason: "Request body contains no valid file path")
            }
            let language = request.parameters.get(languageNameParameter)!
            
            var config = LanguageServer.Config.all[language.lowercased()]
            config?.executablePath = executablePath
            LanguageServer.Config.all[language.lowercased()] = config
            
            return .ok
        }
    }
    
    // MARK: - Language Server

    private func configureAndRunLanguageServer(forLanguage lang: String) throws {
        let newLanguageServer = try LanguageServer(languageKey: lang)
        
        LanguageServer.active?.stop()
        LanguageServer.active = newLanguageServer
        
        newLanguageServer.didSend = { lspPacket in
            websocket?.send([UInt8](lspPacket.data))
        }
        
        newLanguageServer.didSendError = { errorData in
            guard errorData.count > 0 else { return }
            var errorString = errorData.utf8String!
            if errorString.last == "\n" { errorString.removeLast() }
            log(error: "\(lang.capitalized) language server: \(errorString)")
            websocket?.send(errorString)
        }
        
        newLanguageServer.didTerminate = {
            guard let websocket = websocket, !websocket.isClosed else { return }
            let errorFeedbackWasSent = websocket.eventLoop.makePromise(of: Void.self)
            errorFeedbackWasSent.futureResult.whenComplete { _ in
                websocket.close(promise: nil)
            }
            websocket.send("\(lang.capitalized) language server did terminate",
                           promise: errorFeedbackWasSent)
        }

        newLanguageServer.run()
    }
}

// MARK: - Websocket

fileprivate var websocket: Vapor.WebSocket?
