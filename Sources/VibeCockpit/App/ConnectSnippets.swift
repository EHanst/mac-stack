import Foundation

/// Copy-paste setup text for the apps people connect. Pure, so the exact text is tested.
public struct ConnectSnippet: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// Where the text goes, in plain words.
    public let instructions: String
    public let text: String
}

public enum ConnectSnippets {

    /// `key` is a placeholder unless the user just created one.
    public static func all(baseURL: String, socketPath: String, key: String = "YOUR_KEY") -> [ConnectSnippet] {
        let mcpURL = baseURL.replacingOccurrences(of: "/v1", with: "/mcp")
        return [
            ConnectSnippet(
                id: "claude-desktop", title: "Claude Desktop",
                instructions: "Open Claude Desktop → Settings → Developer → Edit Config, add this under \"mcpServers\", then restart it. No key needed: it talks to VibeCockpit over a private file on this Mac.",
                text: """
                {
                  "mcpServers": {
                    "vibecockpit": {
                      "command": "/usr/bin/nc",
                      "args": ["-U", "\(socketPath)"]
                    }
                  }
                }
                """),
            ConnectSnippet(
                id: "cursor", title: "Cursor",
                instructions: "Put this in ~/.cursor/mcp.json (or Settings → MCP → Add). Replace YOUR_KEY with the key you made for Cursor above.",
                text: """
                {
                  "mcpServers": {
                    "vibecockpit": {
                      "url": "\(mcpURL)",
                      "headers": { "Authorization": "Bearer \(key)" }
                    }
                  }
                }
                """),
            ConnectSnippet(
                id: "openai-python", title: "OpenAI SDK (Python)",
                instructions: "Any tool or script that uses the OpenAI library can point at VibeCockpit instead. Replace YOUR_KEY with a key you made above.",
                text: """
                from openai import OpenAI

                client = OpenAI(base_url="\(baseURL)", api_key="\(key)")
                reply = client.chat.completions.create(
                    model="auto",  # or a name from GET /models
                    messages=[{"role": "user", "content": "Hello!"}],
                )
                print(reply.choices[0].message.content)
                """),
            ConnectSnippet(
                id: "curl", title: "curl",
                instructions: "Quick check from Terminal. Replace YOUR_KEY with a key you made above.",
                text: """
                curl \(baseURL)/chat/completions \\
                  -H "Authorization: Bearer \(key)" \\
                  -H "Content-Type: application/json" \\
                  -d '{"messages":[{"role":"user","content":"Hello!"}]}'
                """),
        ]
    }
}
