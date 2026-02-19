import ballerina/ai;
import ballerina/file;
import ballerina/http;
import ballerina/io;
import ballerina/uuid;
import ballerina/websocket;
import ballerinax/openai.audio;

configurable string openaiToken = ?;

final audio:Client audioClient = check new ({auth: {token: openaiToken}});
final ai:ModelProvider model = check ai:getDefaultModelProvider();

# Maximum number of exchanges (user + assistant pairs) to keep in history.
const int MAX_HISTORY_PAIRS = 5;

service /ws on new websocket:Listener(8001) {
    resource function get .(http:Request req) returns websocket:Service|websocket:UpgradeError {
        return new WsService();
    }
}

isolated service class WsService {
    *websocket:Service;

    # Per-connection conversation history: [[role, content], ...]
    # Stored as tuples of ("user"|"assistant", text).
    # Capped at MAX_HISTORY_PAIRS * 2 entries so the LLM prompt stays bounded.
    private [string, string][] history = [];

    # Handles an incoming binary audio message from the browser client.
    # Never returns websocket:Error — all errors handled locally so the
    # connection is never closed by a pipeline failure or failed write.
    remote isolated function onMessage(websocket:Caller caller, byte[] data) {

        // Speech-to-Text (STT) Processing
        string requestId = uuid:createRandomUuid();
        string requestFile = string `request_${requestId}.wav`;

        io:println("Received audio: ", data.length(), " bytes");

        error? writeFileErr = io:fileWriteBytes(requestFile, data);
        if writeFileErr is error {
            io:println("Failed to write WAV: ", writeFileErr.message());
            sendText(caller, "ERROR: could not save audio");
            return;
        }

        string|error transcriptResult = SpeechToText(requestFile);

        // Best-effort temp file cleanup
        file:Error? removeErr = file:remove(requestFile);
        if removeErr is file:Error {
            io:println("Warning: could not remove '", requestFile, "': ", removeErr.message());
        }

        if transcriptResult is error {
            io:println("STT error: ", transcriptResult.message());
            sendText(caller, "ERROR: transcription failed — " + transcriptResult.message());
            return;
        }

        string transcript = transcriptResult;
        io:println("STT: ", transcript);

        // Send transcript to frontend immediately
        sendText(caller, "TRANSCRIPT:" + transcript);

        // Build prompt with conversation history context
        string prompt;
        lock {
            string ctx = "";
            foreach [string, string] msg in self.history {
                string roleLabel = msg[0] == "user" ? "User" : "Assistant";
                ctx = ctx + roleLabel + ": " + msg[1] + "\n";
            }

            string historyBlock = ctx.length() > 0
                ? "Previous conversation:\n" + ctx + "\n"
                : "";

            prompt = "You are a helpful, friendly voice assistant. Keep responses concise and conversational (1-3 sentences). Return only the spoken response — no markdown, no lists.\n\n"
                + historyBlock
                + "User: " + transcript + "\nAssistant:";
        }

        // Language Model (LLM) Processing
        string|error llmResult = llmCall(prompt);
        if llmResult is error {
            io:println("LLM error: ", llmResult.message());
            sendText(caller, "ERROR: LLM failed — " + llmResult.message());
            return;
        }

        string llmResponse = llmResult;
        io:println("LLM: ", llmResponse);

        // Update conversation history (capped at MAX_HISTORY_PAIRS exchanges)
        lock {
            self.history.push(["user", transcript]);
            self.history.push(["assistant", llmResponse]);

            // Each pair = 2 entries; keep only the last MAX_HISTORY_PAIRS pairs
            int maxEntries = MAX_HISTORY_PAIRS * 2;
            if self.history.length() > maxEntries {
                self.history = self.history.slice(self.history.length() - maxEntries);
            }

            io:println("History length: ", self.history.length() / 2, " / ", MAX_HISTORY_PAIRS, " pairs");
        }

        // Send the LLM response text back to client
        sendText(caller, "RESPONSE:" + llmResponse);

        // Text-to-Speech (TTS) Processing
        byte[]|error audioResult = textToSpeech(llmResponse);
        if audioResult is error {
            io:println("TTS error: ", audioResult.message());
            sendText(caller, "ERROR: TTS failed — " + audioResult.message());
            return;
        }

        websocket:Error? audioErr = caller->writeMessage(audioResult);
        if audioErr is websocket:Error {
            io:println("Failed to send audio to client: ", audioErr.message());
        }
    }
}

# Sends a plain-text WebSocket frame. Errors are logged, never propagated.
isolated function sendText(websocket:Caller caller, string msg) {
    websocket:Error? err = caller->writeMessage(msg);
    if err is websocket:Error {
        io:println("sendText failed: ", err.message());
    }
}

isolated function SpeechToText(string fileName) returns string|error {
    byte[] fileContent = check io:fileReadBytes(fileName);
    audio:CreateTranscriptionRequest request = {
        model: "whisper-1",
        file: {fileContent, fileName}
    };
    audio:CreateTranscriptionResponse response = check audioClient->/audio/transcriptions.post(request);
    return response.text;
}

# Accepts a fully-formed prompt string (including history context) and
# calls the LLM. Wrapping in a backtick template satisfies the ai:Prompt type
# that model->generate() requires — plain strings are not accepted directly.
isolated function llmCall(string prompt) returns string|error {
    string response = check model->generate(`${prompt}`);
    return response;
}

isolated function textToSpeech(string text) returns byte[]|error {
    audio:CreateSpeechRequest request = {
        model: "tts-1",
        input: text,
        voice: "alloy"
    };
    byte[] audioBytes = check audioClient->/audio/speech.post(request);
    return audioBytes;
}

public function main() returns error? {
    io:println("WebSocket server listening on ws://localhost:8001/ws");
}
