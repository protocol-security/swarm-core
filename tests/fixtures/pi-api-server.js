// Deterministic Anthropic-compatible test API, not a real model.
// Exercise the installed Pi CLI's streaming and all four default tools.
const http = require("node:http");

function reply(res, name, args) {
    const content = name
        ? { type: "tool_use", id: `call_${Date.now()}`, name, input: {} }
        : { type: "text", text: "" };
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    const event = (type, body) => {
        const json = JSON.stringify({ type, ...body });
        res.write(`event: ${type}\ndata: ${json}\n\n`);
    };
    event("message_start", {
        message: {
            id: `msg_${Date.now()}`,
            type: "message",
            role: "assistant",
            model: "claude-sonnet-4-6",
            content: [],
            stop_reason: null,
            stop_sequence: null,
            usage: {
                input_tokens: 10,
                output_tokens: 0,
                cache_read_input_tokens: 3,
                cache_creation_input_tokens: 2,
            },
        },
    });
    event("content_block_start", { index: 0, content_block: content });
    event("content_block_delta", {
        index: 0,
        delta: name
            ? { type: "input_json_delta", partial_json: JSON.stringify(args) }
            : { type: "text_delta", text: "Fixture complete." },
    });
    event("content_block_stop", { index: 0 });
    event("message_delta", {
        delta: { stop_reason: name ? "tool_use" : "end_turn" },
        usage: { output_tokens: 5 },
    });
    event("message_stop", {});
    res.end();
}

http.createServer((req, res) => {
    if (req.url === "/health") {
        res.end("ok");
        return;
    }
    let raw = "";
    req.on("data", (chunk) => { raw += chunk; });
    req.on("end", () => {
        try {
            const body = JSON.parse(raw);
            const first = JSON.stringify(body.messages[0]);
            if (first.includes("SWARM_PI_ERROR")) {
                res.writeHead(401, { "Content-Type": "application/json" });
                res.end(JSON.stringify({
                    type: "error",
                    error: {
                        type: "authentication_error",
                        message: "Pi fixture rejected the credential",
                    },
                }));
                return;
            }
            const post = first.includes("SWARM_PI_POST");
            const file = post
                ? "test-results/pi-post.txt" : "test-results/pi.txt";
            const marker = post ? "PI_POST_DONE" : "PI_MAIN_DONE";
            const results = body.messages.flatMap((m) =>
                Array.isArray(m.content)
                    ? m.content.filter((c) => c.type === "tool_result") : []);
            const call = (name, args) => {
                const tool = body.tools.find((t) =>
                    t.name.toLowerCase() === name);
                if (!tool) { throw new Error(`Missing tool: ${name}`); }
                reply(res, tool.name, args);
            };
            // A new harness session sees the committed marker and idles.
            if (results.length > 0 &&
                    JSON.stringify(results[0].content).includes(marker)) {
                reply(res);
                return;
            }
            switch (results.length) {
                case 0:
                    call("read", { path: file });
                    break;
                case 1:
                    call("write", { path: file, content: "DRAFT\n" });
                    break;
                case 2:
                    call("edit", {
                        path: file, oldText: "DRAFT", newText: marker,
                    });
                    break;
                case 3:
                    call("bash", {
                        command: `git add ${file} && ` +
                            `git commit -m 'Record ${marker}'`,
                    });
                    break;
                default:
                    reply(res);
            }
        } catch (error) {
            res.writeHead(500);
            res.end(String(error));
        }
    });
}).listen(8080, "0.0.0.0");
