import Foundation

/// Where notes are generated. Local by default (Ollama, fully offline); cloud
/// only when the user opts in with their own key.
enum NotesBackend {
    case localOllama(model: String)
    case cloudOpenAICompatible(baseURL: String, apiKey: String, model: String)
}

/// Turns a transcript (and the user's rough notes) into structured meeting
/// notes. Builds one prompt and sends it to whichever backend is selected.
///
/// NOTE: Ollama is the local dev-time engine. To ship we'll swap it for an
/// embedded engine (MLX / llama.cpp) that auto-downloads its model — this file
/// is the seam where that swap happens.
final class NotesGenerator {
    struct GenerationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func generate(transcript: String,
                  userNotes: String,
                  template: NotesTemplate,
                  languageHint: String,
                  backend: NotesBackend) async throws -> String {
        let prompt = buildPrompt(transcript: transcript, userNotes: userNotes,
                                 template: template, languageHint: languageHint)
        switch backend {
        case let .localOllama(model):
            return try await sendOllama(model: model, system: prompt.system, user: prompt.user)
        case let .cloudOpenAICompatible(baseURL, apiKey, model):
            return try await sendOpenAICompatible(baseURL: baseURL, apiKey: apiKey, model: model,
                                                  system: prompt.system, user: prompt.user)
        }
    }

    /// Proposes a short, specific title saying what the conversation was about.
    func suggestTitle(transcript: String, languageHint: String, backend: NotesBackend) async throws -> String {
        let system = """
        You name conversations. Given a meeting transcript, reply with ONLY a short title \
        (3–6 words) saying concretely what was discussed — specific topics, names, decisions. \
        Never generic ("Meeting", "Discussion", "Conversation"), no quotes, no trailing period, \
        no explanation — just the title. Write it in \(languageHint).
        """
        let raw = try await dispatch(system: system, user: clippedForTitle(transcript), backend: backend)
        let title = Self.cleanedTitle(raw)
        guard !title.isEmpty else {
            throw GenerationError(message: "The model returned no usable title.")
        }
        return title
    }

    /// A title needs the gist, not the whole meeting: keep the opening (topic
    /// setup) and the ending (conclusions) of long transcripts.
    private func clippedForTitle(_ transcript: String) -> String {
        let maxHead = 2500, maxTail = 1500
        guard transcript.count > maxHead + maxTail else { return transcript }
        return transcript.prefix(maxHead) + "\n…\n" + transcript.suffix(maxTail)
    }

    /// First non-empty line of the reply, stripped of quotes/markdown/period.
    private static func cleanedTitle(_ raw: String) -> String {
        var line = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        line = line.replacingOccurrences(of: "**", with: "")
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”«»#–- "))
        while line.hasSuffix(".") { line.removeLast() }
        line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if line.count > 60 {
            line = String(line.prefix(60)).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    /// Reads the transcript for the participants' real names (self-intros,
    /// how people address each other) and returns what it found, keyed by the
    /// raw speaker label. Names it can't establish are simply absent — the
    /// caller shows a suggestion only when there is one.
    func suggestSpeakerNames(transcript: String, backend: NotesBackend) async throws -> [String: String] {
        let system = """
        Identify the real names of the conversation participants from the transcript. \
        Lines labeled "You" are the app's user; lines labeled "Others" are everyone else on the call. \
        Use only self-introductions and how people address each other — never invent a name. \
        Reply with EXACTLY two lines and nothing else:
        You: <name or UNKNOWN>
        Others: <name(s), comma-separated, or UNKNOWN>
        Keep names spelled exactly as in the transcript.
        """
        let raw = try await dispatch(system: system, user: clippedForTitle(transcript), backend: backend)
        var result: [String: String] = [:]
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for key in ["You", "Others"] where trimmed.lowercased().hasPrefix(key.lowercased() + ":") {
                var name = String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”«»*"))
                guard !name.isEmpty, name.uppercased() != "UNKNOWN", name.count <= 60 else { continue }
                result[key] = name
            }
        }
        return result
    }

    /// Answers a question about the meeting using only the transcript.
    func answer(question: String, transcript: String, languageHint: String, backend: NotesBackend) async throws -> String {
        let system = """
        You answer questions about a meeting using ONLY the transcript provided. \
        Lines labeled "You" are the app's user; "Others" are the other participants. \
        If the transcript doesn't contain the answer, say you don't see it in this meeting. \
        Be concise and factual. Answer in \(languageHint).
        """
        let user = "TRANSCRIPT:\n\(transcript)\n\nQUESTION: \(question)"
        return try await dispatch(system: system, user: user, backend: backend)
    }

    /// Rewrites existing notes per an instruction, staying faithful to the transcript.
    func reshape(currentNotes: String, transcript: String, instruction: String,
                 languageHint: String, backend: NotesBackend) async throws -> String {
        let system = """
        You rewrite meeting notes according to an instruction, staying faithful to the transcript \
        and inventing nothing. Keep clear Markdown formatting. Write in \(languageHint).
        """
        let user = "TRANSCRIPT:\n\(transcript)\n\nCURRENT NOTES:\n\(currentNotes)\n\nINSTRUCTION: \(instruction)"
        return try await dispatch(system: system, user: user, backend: backend)
    }

    /// Drafts a ready-to-send follow-up message from the meeting.
    func draftFollowUp(transcript: String, notes: String, languageHint: String, backend: NotesBackend) async throws -> String {
        let system = """
        You draft a concise, professional follow-up email after a meeting, based only on the \
        transcript (and notes if given). Include: a short greeting, a one-line recap, the key \
        decisions, and clear next steps / action items (with owners if the transcript names them), \
        then a brief sign-off. Make it ready to send — avoid placeholder brackets like [Name] unless \
        the transcript genuinely doesn't provide the detail. Write in \(languageHint).
        """
        var user = "TRANSCRIPT:\n\(transcript)"
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            user += "\n\nNOTES:\n\(notes)"
        }
        return try await dispatch(system: system, user: user, backend: backend)
    }

    /// Extracts concrete action items from the meeting as a list of strings.
    func extractActionItems(transcript: String, notes: String, languageHint: String, backend: NotesBackend) async throws -> [String] {
        let system = """
        Extract the concrete action items / tasks agreed in this meeting. \
        Output ONLY the tasks, one per line, with no numbering, bullets, or extra commentary. \
        Name the owner if the transcript does. If there are none, output exactly: NONE. \
        Write in \(languageHint).
        """
        var user = "TRANSCRIPT:\n\(transcript)"
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            user += "\n\nNOTES:\n\(notes)"
        }
        let raw = try await dispatch(system: system, user: user, backend: backend)
        return raw
            .components(separatedBy: .newlines)
            .map { stripBullet($0) }
            .filter { !$0.isEmpty && $0.uppercased() != "NONE" }
    }

    private func stripBullet(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        while let first = s.first, "-*•".contains(first) {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        if let r = s.range(of: "^[0-9]+[.)]\\s*", options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func dispatch(system: String, user: String, backend: NotesBackend) async throws -> String {
        switch backend {
        case let .localOllama(model):
            return try await sendOllama(model: model, system: system, user: user)
        case let .cloudOpenAICompatible(baseURL, apiKey, model):
            return try await sendOpenAICompatible(baseURL: baseURL, apiKey: apiKey, model: model, system: system, user: user)
        }
    }

    // MARK: - Prompt

    private func buildPrompt(transcript: String, userNotes: String,
                             template: NotesTemplate, languageHint: String) -> (system: String, user: String) {
        let sectionList = template.sections.map { "## \($0)" }.joined(separator: "\n")

        var system = """
        You are a meeting-notes assistant. You will receive a transcript of a spoken conversation. \
        Lines labeled "You" are the app's user; lines labeled "Others" are the other participants.
        """
        if !template.guidance.isEmpty {
            system += "\nContext: \(template.guidance)"
        }
        system += """


        Produce clear, faithful notes using exactly these Markdown sections:
        \(sectionList)
        """
        if !userNotes.isEmpty {
            system += """


            The user also jotted their own rough notes during the meeting (provided after "USER NOTES"). \
            Treat those as the priority: expand, organize, and complete them using the transcript. \
            Where the transcript adds relevant detail the user didn't capture, include it — but never contradict the user's notes.
            """
        }
        system += """


        Rules: be concise and never invent anything not supported by the transcript. If a section \
        would have nothing to report, omit that section entirely — heading and all — rather than \
        writing a placeholder like "—" or "None". Write the notes in \(languageHint).
        """

        let user = userNotes.isEmpty
            ? transcript
            : "TRANSCRIPT:\n\(transcript)\n\nUSER NOTES:\n\(userNotes)"
        return (system, user)
    }

    // MARK: - Local (Ollama)

    private func sendOllama(model: String, system: String, user: String) async throws -> String {
        let endpoint = URL(string: "http://localhost:11434/api/chat")!
        let payload: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 300

        let (data, response) = try await send(request,
            unreachable: "Couldn't reach the local AI (Ollama) at localhost:11434. Make sure Ollama is running.")
        try checkStatus(response, data, context: "Ollama")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw GenerationError(message: "Couldn't read Ollama's reply. Is the model \"\(model)\" installed? (run: ollama pull \(model))")
        }
        return try nonEmpty(content)
    }

    // MARK: - Cloud (OpenAI-compatible)

    private func sendOpenAICompatible(baseURL: String, apiKey: String, model: String,
                                      system: String, user: String) async throws -> String {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        if base.hasSuffix("/") { base.removeLast() }
        guard let endpoint = URL(string: base + "/chat/completions") else {
            throw GenerationError(message: "The cloud base URL in Settings isn't valid.")
        }
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 120

        let (data, response) = try await send(request,
            unreachable: "Couldn't reach the cloud model. Check the base URL in Settings and your connection.")
        try checkStatus(response, data, context: "The cloud API")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw GenerationError(message: "Couldn't read the cloud model's reply. Check the model name in Settings.")
        }
        return try nonEmpty(content)
    }

    // MARK: - Helpers

    private func send(_ request: URLRequest, unreachable: String) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw GenerationError(message: "\(unreachable) (\(error.localizedDescription))")
        }
    }

    private func checkStatus(_ response: URLResponse, _ data: Data, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GenerationError(message: "Unexpected response from \(context).")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GenerationError(message: "\(context) returned status \(http.statusCode). \(body.prefix(300))")
        }
    }

    private func nonEmpty(_ content: String) throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw GenerationError(message: "The model returned an empty response. Try again, or switch the notes model.")
        }
        return trimmed
    }
}
