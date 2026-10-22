// Test-only transport for the real Pi CLI. No requests leave this process.
// Exercise OAuth refresh, shared auth-file locking, and Codex SSE parsing.
const fs = require("node:fs");
const assert = require("node:assert/strict");
const { zstdDecompressSync } = require("node:zlib");
const home = "/home/agent/.pi/agent";
const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
const access = [encode({ alg: "none" }), encode({
    "https://api.openai.com/auth": { chatgpt_account_id: "fixture-account" },
}), "fixture-signature"].join(".");

if (process.argv.includes("--mode")) {
    fs.writeFileSync(`${home}/started-${process.env.AGENT_ID}`, "ready");
}

const fixtureFetch = async (input, init = {}) => {
    const url = String(input);
    if (url === "https://auth.openai.com/oauth/token") {
        const body = new URLSearchParams(String(init.body));
        assert.equal(body.get("grant_type"), "refresh_token");
        assert.equal(body.get("refresh_token"), "fixture-refresh");
        fs.appendFileSync(`${home}/refresh-count`, "refresh\n");
        // Wait for both CLIs to start before releasing the first refresh.
        const deadline = Date.now() + 10000;
        while (!fs.existsSync(`${home}/started-codex-1`) ||
                !fs.existsSync(`${home}/started-codex-2`)) {
            if (Date.now() > deadline) {
                throw new Error("Both Codex test CLIs did not start");
            }
            await new Promise((resolve) => setTimeout(resolve, 50));
        }
        return Response.json({
            access_token: access,
            refresh_token: "fixture-refresh-rotated",
            expires_in: 3600,
        });
    }
    assert.equal(url, "https://chatgpt.com/backend-api/codex/responses");
    const headers = new Headers(init.headers);
    assert.equal(headers.get("Authorization"), `Bearer ${access}`);
    assert.equal(headers.get("chatgpt-account-id"), "fixture-account");
    const body = JSON.parse(headers.get("content-encoding") === "zstd"
        ? zstdDecompressSync(init.body).toString() : init.body);
    assert.equal(body.model, "gpt-5.5");
    const item = { type: "message", id: "item_1", role: "assistant",
        status: "completed", content: [{ type: "output_text",
            text: "PI_CODEX_AUTH_OK", annotations: [] }] };
    const events = [
        { type: "response.created", response: { id: "resp_1",
            status: "in_progress", output: [] } },
        { type: "response.output_item.added", output_index: 0,
            item: { ...item, content: [] } },
        { type: "response.content_part.added", item_id: "item_1",
            output_index: 0, content_index: 0,
            part: { type: "output_text", text: "", annotations: [] } },
        { type: "response.output_text.delta", item_id: "item_1",
            output_index: 0, content_index: 0, delta: "PI_CODEX_AUTH_OK" },
        { type: "response.output_item.done", output_index: 0, item },
        { type: "response.completed", response: { id: "resp_1",
            status: "completed", output: [item], usage: {
                input_tokens: 10, output_tokens: 5,
                input_tokens_details: { cached_tokens: 3 },
            } } },
    ];
    return new Response(events.map((e) =>
        `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join(""), {
        headers: { "Content-Type": "text/event-stream" },
    });
};

// Pi installs Undici's globals at startup. Keep this test's transport in
// place through that assignment; Docker also disables network access.
Object.defineProperty(globalThis, "fetch", {
    get: () => fixtureFetch,
    set: () => {},
});
