// SPDX-License-Identifier: MIT
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

private struct BridgeRequest: Codable, Sendable {
    let version: Int
    let requestID: String
    let command: String
    let instructions: String?
    let prompt: String?
}

private struct BridgeResponse: Codable, Sendable {
    let version: Int
    let requestID: String
    let status: String
    let content: String?
    let detail: String?
}

private enum BridgeFailure: Error {
    case invalidRequest(String)
    case modelUnavailable(String)
}

@main
private struct HobFoundationBridge {
    static func main() async {
        var responseRequestID = UUID().uuidString
        do {
            let input = try FileHandle.standardInput.read(upToCount: 200_001) ?? Data()
            guard !input.isEmpty else {
                throw BridgeFailure.invalidRequest("empty request")
            }
            guard input.count <= 200_000 else {
                throw BridgeFailure.invalidRequest("request exceeds 200000 bytes")
            }
            let request = try JSONDecoder().decode(BridgeRequest.self, from: input)
            responseRequestID = request.requestID
            let response = try await handle(request)
            emit(response)
        } catch let failure as BridgeFailure {
            let detail: String
            switch failure {
            case .invalidRequest(let message), .modelUnavailable(let message):
                detail = message
            }
            emit(BridgeResponse(
                version: 1,
                requestID: responseRequestID,
                status: "unavailable",
                content: nil,
                detail: detail
            ))
        } catch {
            emit(BridgeResponse(
                version: 1,
                requestID: responseRequestID,
                status: "error",
                content: nil,
                detail: "request could not be processed"
            ))
        }
    }

    private static func handle(_ request: BridgeRequest) async throws -> BridgeResponse {
        guard request.version == 1 else {
            throw BridgeFailure.invalidRequest("unsupported protocol version")
        }
        guard !request.requestID.isEmpty && request.requestID.count <= 128 else {
            throw BridgeFailure.invalidRequest("invalid request id")
        }

        if request.command == "status" {
            let reported = modelStatus()
            return BridgeResponse(
                version: 1,
                requestID: request.requestID,
                status: reported == "available" ? "reported_available" : reported,
                content: nil,
                detail: modelDetail()
            )
        }
        if request.command == "probe" {
            _ = try await generate(
                instructions: "Return only the word READY.",
                prompt: "Confirm model generation readiness."
            )
            return BridgeResponse(
                version: 1,
                requestID: request.requestID,
                status: "available",
                content: nil,
                detail: "generation_verified"
            )
        }
        guard request.command == "generate", let prompt = request.prompt else {
            throw BridgeFailure.invalidRequest("unknown command or missing prompt")
        }
        let instructions = request.instructions ?? ""
        guard prompt.utf8.count + instructions.utf8.count <= 100_000 else {
            throw BridgeFailure.invalidRequest("model input exceeds 100000 bytes")
        }
        let content = try await generate(
            instructions: instructions,
            prompt: prompt
        )
        return BridgeResponse(
            version: 1,
            requestID: request.requestID,
            status: "available",
            content: content,
            detail: nil
        )
    }

    private static func modelStatus() -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return "available"
            }
            return "unavailable"
        }
        #endif
        return "unsupported"
    }

    private static func modelDetail() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return String(describing: SystemLanguageModel.default.availability)
        }
        #endif
        return "Foundation Models is not present in this macOS SDK"
    }

    private static func generate(instructions: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                throw BridgeFailure.modelUnavailable(modelDetail() ?? "model unavailable")
            }
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: prompt)
                return response.content
            } catch let error as LanguageModelSession.GenerationError {
                throw BridgeFailure.modelUnavailable(generationFailureCode(error))
            } catch {
                throw BridgeFailure.modelUnavailable("model_service_unavailable")
            }
        }
        #endif
        throw BridgeFailure.modelUnavailable("Foundation Models requires a supported macOS SDK")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func generationFailureCode(
        _ error: LanguageModelSession.GenerationError
    ) -> String {
        switch error {
        case .exceededContextWindowSize: return "context_window_exceeded"
        case .assetsUnavailable: return "model_assets_unavailable"
        case .guardrailViolation: return "guardrail_violation"
        case .unsupportedGuide: return "unsupported_generation_guide"
        case .unsupportedLanguageOrLocale: return "unsupported_language_or_locale"
        case .decodingFailure: return "model_decoding_failure"
        case .rateLimited: return "model_rate_limited"
        case .concurrentRequests: return "model_request_in_progress"
        case .refusal: return "model_refusal"
        @unknown default: return "model_generation_failed"
        }
    }
    #endif

    private static func emit(_ response: BridgeResponse) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(response))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Hob bridge encoding failed\n".utf8))
        }
    }
}
