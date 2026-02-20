import ballerina/ai;
import ballerina/http;
import ballerina/io;
import ballerina/uuid;
import ballerina/websocket;
import ballerinax/openai.audio;
import ballerinax/ai.openai;

configurable string openaiToken = ?;

final audio:Client audioClient = check new ({auth: {token: openaiToken}});

// Module-level agent: shared across connections, history isolated per sessionId.
final ai:Agent voiceAgent = check new ({
    systemPrompt: {
        role: "Voice Assistant",
        instructions: "You are a helpful, friendly voice assistant. Keep responses concise and conversational (1-3 sentences). Return only the spoken response — no markdown, no lists."
    },
    model: check new openai:ModelProvider(openaiToken, openai:GPT_4O)
});

service /ws on new websocket:Listener(8001) {
    resource function get .(http:Request req) returns websocket:Service|websocket:UpgradeError {
        return new WsService();
    }
}

isolated service class WsService {
    *websocket:Service;

    // Unique session ID per connection — the agent uses this to isolate history.
    private final string sessionId = uuid:createRandomUuid();

    remote isolated function onMessage(websocket:Caller caller, byte[] data) {

        // Speech-to-Text
        string|error transcriptResult = speechToText(data);
        if transcriptResult is error {
            io:println("STT error: ", transcriptResult.message());
            sendText(caller, "ERROR: transcription failed — " + transcriptResult.message());
            return;
        }

        string transcript = transcriptResult;
        io:println("STT: ", transcript);
        sendText(caller, "TRANSCRIPT:" + transcript);

        // Run agent — conversation history is managed internally per sessionId.
        string|error agentResult = voiceAgent.run(transcript, self.sessionId);
        if agentResult is error {
            io:println("Agent error: ", agentResult.message());
            sendText(caller, "ERROR: Agent failed — " + agentResult.message());
            return;
        }

        string llmResponse = agentResult;
        io:println("Agent: ", llmResponse);
        sendText(caller, "RESPONSE:" + llmResponse);

        // Text-to-Speech
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

/// Sends a plain-text WebSocket frame. Errors are logged, never propagated.
isolated function sendText(websocket:Caller caller, string msg) {
    websocket:Error? err = caller->writeMessage(msg);
    if err is websocket:Error {
        io:println("sendText failed: ", err.message());
    }
}

/// Transcribes raw audio bytes via OpenAI Whisper.
isolated function speechToText(byte[] data) returns string|error {
    audio:CreateTranscriptionRequest request = {
        model: "whisper-1",
        file: {fileContent: data, fileName: "input.wav"}
    };
    audio:CreateTranscriptionResponse response = check audioClient->/audio/transcriptions.post(request);
    return response.text;
}

/// Converts text to speech audio via OpenAI TTS.
isolated function textToSpeech(string text) returns byte[]|error {
    audio:CreateSpeechRequest request = {
        model: "tts-1",
        input: text,
        voice: "alloy"
    };
    return check audioClient->/audio/speech.post(request);
}

public function main() returns error? {
    io:println("WebSocket server listening on ws://localhost:8001/ws");
}