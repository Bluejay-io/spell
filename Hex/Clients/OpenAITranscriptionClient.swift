import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import WhisperKit

private let openAILogger = HexLog.transcription

@DependencyClient
struct OpenAITranscriptionClient {
	var transcribe: @Sendable (URL, OpenAITranscriptionModel, DecodingOptions) async throws -> String
}

extension OpenAITranscriptionClient: DependencyKey {
	static var liveValue: Self {
		let live = OpenAITranscriptionClientLive()
		return Self(
			transcribe: { url, model, options in
				try await live.transcribe(url: url, model: model, options: options)
			}
		)
	}
}

extension DependencyValues {
	var openAITranscription: OpenAITranscriptionClient {
		get { self[OpenAITranscriptionClient.self] }
		set { self[OpenAITranscriptionClient.self] = newValue }
	}
}

private actor OpenAITranscriptionClientLive {
	@Dependency(\.openAIKeychain) private var keychain

	private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
	private let maxUploadBytes = 25 * 1024 * 1024

	func transcribe(url: URL, model: OpenAITranscriptionModel, options: DecodingOptions) async throws -> String {
		guard let apiKey = try keychain.loadAPIKey(), !apiKey.isEmpty else {
			throw NSError(
				domain: "OpenAITranscription",
				code: 401,
				userInfo: [NSLocalizedDescriptionKey: "Add an OpenAI API key in Settings to use hosted transcription."]
			)
		}

		let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
		guard fileSize <= maxUploadBytes else {
			throw NSError(
				domain: "OpenAITranscription",
				code: 413,
				userInfo: [NSLocalizedDescriptionKey: "Recording is larger than OpenAI's 25 MB transcription upload limit."]
			)
		}

		let boundary = "Boundary-\(UUID().uuidString)"
		var request = URLRequest(url: endpoint)
		request.httpMethod = "POST"
		request.timeoutInterval = 45
		request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

		var fields = [
			"model": model.apiModel,
			"response_format": "json"
		]
		if let language = options.language, !language.isEmpty {
			fields["language"] = language
		}

		let body = try multipartBody(
			audioURL: url,
			fields: fields,
			boundary: boundary
		)

		openAILogger.notice(
			"Transcribing with OpenAI model=\(model.apiModel, privacy: .public) file=\(url.lastPathComponent, privacy: .private) bytes=\(fileSize, privacy: .public)"
		)
		let start = Date()
		let (data, response) = try await URLSession.shared.upload(for: request, from: body)
		let elapsed = String(format: "%.2f", Date().timeIntervalSince(start))

		guard let http = response as? HTTPURLResponse else {
			throw NSError(
				domain: "OpenAITranscription",
				code: -1,
				userInfo: [NSLocalizedDescriptionKey: "OpenAI did not return an HTTP response."]
			)
		}

		guard (200..<300).contains(http.statusCode) else {
			let message = OpenAIErrorResponse.decodeMessage(from: data) ?? "OpenAI transcription failed with status \(http.statusCode)."
			openAILogger.error(
				"OpenAI transcription failed status=\(http.statusCode, privacy: .public) elapsed=\(elapsed, privacy: .public)s message=\(message, privacy: .public)"
			)
			throw NSError(
				domain: "OpenAITranscription",
				code: http.statusCode,
				userInfo: [NSLocalizedDescriptionKey: message]
			)
		}

		let decoded = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
		openAILogger.notice(
			"OpenAI transcription succeeded status=\(http.statusCode, privacy: .public) elapsed=\(elapsed, privacy: .public)s textLength=\(decoded.text.count, privacy: .public)"
		)
		return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private func multipartBody(audioURL: URL, fields: [String: String], boundary: String) throws -> Data {
		var body = Data()
		for (name, value) in fields {
			body.appendMultipartField(name: name, value: value, boundary: boundary)
		}

		let filename = audioURL.lastPathComponent.isEmpty ? "recording.wav" : audioURL.lastPathComponent
		let mimeType = mimeType(for: audioURL)
		let audioData = try Data(contentsOf: audioURL)
		body.append("--\(boundary)\r\n")
		body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
		body.append("Content-Type: \(mimeType)\r\n\r\n")
		body.append(audioData)
		body.append("\r\n")
		body.append("--\(boundary)--\r\n")
		return body
	}

	private func mimeType(for url: URL) -> String {
		switch url.pathExtension.lowercased() {
		case "mp3":
			return "audio/mpeg"
		case "m4a":
			return "audio/m4a"
		case "webm":
			return "audio/webm"
		case "mp4":
			return "audio/mp4"
		default:
			return "audio/wav"
		}
	}
}

private struct OpenAITranscriptionResponse: Decodable {
	let text: String
}

private struct OpenAIErrorResponse: Decodable {
	struct APIError: Decodable {
		let message: String
	}
	let error: APIError

	static func decodeMessage(from data: Data) -> String? {
		(try? JSONDecoder().decode(Self.self, from: data))?.error.message
	}
}

private extension Data {
	mutating func append(_ string: String) {
		append(Data(string.utf8))
	}

	mutating func appendMultipartField(name: String, value: String, boundary: String) {
		append("--\(boundary)\r\n")
		append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
		append("\(value)\r\n")
	}
}
