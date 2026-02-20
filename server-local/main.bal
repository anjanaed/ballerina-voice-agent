import ballerina/io;
import ballerina/ai;
import ballerina/websocket;
import ballerina/http;
import ballerina/file;
import ballerina/uuid;
import ballerina/os;

final ai:ModelProvider model = check ai:getDefaultModelProvider();

service /ws on new websocket:Listener(8002) {
    resource function get .(http:Request req) returns websocket:Service|websocket:UpgradeError {
        return new WsService();
    }
}

isolated service class WsService {
    *websocket:Service;

    # Per-connection conversation history: [[role, content], ...]
    # No cap — running fully local so memory is not a concern.
    private [string, string][] history = [];

    remote isolated function onMessage(websocket:Caller caller, byte[] data) {

        // Speech-to-Text
        string requestId = uuid:createRandomUuid();
        string tempDir = os:getEnv("TEMP");
        string requestFile = string `${tempDir}\\request_${requestId}.wav`;

        error? writeErr = io:fileWriteBytes(requestFile, data);
        if writeErr is error {
            io:println("Failed to write WAV: ", writeErr.message());
            sendText(caller, "ERROR: could not save audio");
            return;
        }

        string|error transcriptResult = transcribeWithLocalWhisper(requestFile);

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
        io:println("[STT] ", transcript);

        // Send transcript to frontend immediately
        sendText(caller, "TRANSCRIPT:" + transcript);

        // Build prompt with full conversation history
        string ctx = "";
        lock {
            foreach [string, string] msg in self.history {
                string roleLabel = msg[0] == "user" ? "User" : "Assistant";
                ctx = ctx + roleLabel + ": " + msg[1] + "\n";
            }
        }

        string historyBlock = ctx.length() > 0
            ? "Previous conversation:\n" + ctx + "\n"
            : "";

        string prompt = "You are a helpful, friendly voice assistant. Keep responses concise and conversational (1-3 sentences). Return only the spoken response — no markdown, no lists.\n\n"
            + historyBlock
            + "User: " + transcript + "\nAssistant:";

        // LLM call
        string|error llmResult = model->generate(`${prompt}`);
        if llmResult is error {
            io:println("LLM error: ", llmResult.message());
            sendText(caller, "ERROR: LLM failed — " + llmResult.message());
            return;
        }

        string llmResponse = llmResult;
        io:println("[LLM] ", llmResponse);

        // Update conversation history
        lock {
            self.history.push(["user", transcript]);
            self.history.push(["assistant", llmResponse]);
            io:println("[History] ", self.history.length() / 2, " exchanges");
        }

        // Send response text to frontend
        sendText(caller, "RESPONSE:" + llmResponse);

        // Text-to-Speech
        byte[]|error audioResult = TtsWithKokoro(llmResponse);
        if audioResult is error {
            io:println("TTS error: ", audioResult.message());
            sendText(caller, "ERROR: TTS failed — " + audioResult.message());
            return;
        }

        websocket:Error? audioErr = caller->writeMessage(audioResult);
        if audioErr is websocket:Error {
            io:println("Failed to send audio: ", audioErr.message());
        }
    }
}

isolated function sendText(websocket:Caller caller, string msg) {
    websocket:Error? err = caller->writeMessage(msg);
    if err is websocket:Error {
        io:println("sendText failed: ", err.message());
    }
}

public function main() returns error? {
    io:println("Local Voice Agent - WebSocket server listening on ws://localhost:8002/ws");
}


