import server_local.kokoro_client;
import server_local.whisper_client;

import ballerina/ai;
import ballerina/http;
import ballerina/io;
import ballerina/uuid;
import ballerina/websocket;
import ballerinax/ai.openai;

configurable string openaiToken = ?;

final ai:ModelProvider model = check new openai:ModelProvider(openaiToken, openai:GPT_4O);

final ai:Agent voiceAgent = check new ({
    systemPrompt: {
        role: "Voice Assistant",
        instructions: "You are a helpful, friendly voice assistant. Keep responses concise and conversational (1-3 sentences). Return only the spoken response — no markdown, no lists."
    },
    model: check new openai:ModelProvider(openaiToken, openai:GPT_4O)
});

# The WebSocket service listener.
@websocket:ServiceConfig {
    maxFrameSize: 104857600
}
service /ws on new websocket:Listener(8002) {

    # + req - The HTTP request
    # + return - The WebSocket service or an upgrade error
    resource function get .(http:Request req) returns websocket:Service|websocket:UpgradeError {
        return new WsService();
    }
}

isolated service class WsService {
    *websocket:Service;

    # The unique session ID for the connection.
    private final string sessionId = uuid:createRandomUuid();

    # Triggered when a binary message (audio) is received from the client.
    # Performs speech-to-text, queries the local voice agent, and returns text-to-speech audio.
    # + caller - The WebSocket caller
    # + data - The audio data received as a byte array
    remote isolated function onBinaryMessage(websocket:Caller caller, byte[] data) {

        string|error transcriptResult = whisper_client:transcribeWithLocalWhisper(data);

        if transcriptResult is error {
            io:println("STT error: ", transcriptResult.message());
            sendText(caller, string `ERROR: transcription failed — ${transcriptResult.message()}`);
            return;
        }

        string transcript = transcriptResult;
        io:println("[STT] ", transcript);

        sendText(caller, string `TRANSCRIPT:${transcript}`);

        string|error agentResult = voiceAgent.run(transcript, self.sessionId);

        if agentResult is error {
            io:println("Agent error: ", agentResult.message());
            sendText(caller, string `ERROR: Agent failed — ${agentResult.message()}`);
            return;
        }

        string llmResponse = agentResult;
        io:println("Agent: ", llmResponse);

        byte[]|error audioResult = kokoro_client:ttsWithKokoro(llmResponse);

        if audioResult is error {
            io:println("TTS error: ", audioResult.message());
            sendText(caller, string `ERROR: TTS failed — ${audioResult.message()}`);
            return;
        }

        websocket:Error? audioErr = caller->writeMessage(audioResult);
        if audioErr is websocket:Error {
            io:println("Failed to send audio: ", audioErr.message());
        }
        sendText(caller, string `RESPONSE:${llmResponse}`);

    }
}

# Sends a text message to the WebSocket caller.
#
# + caller - The WebSocket caller
# + msg - The text message to send
isolated function sendText(websocket:Caller caller, string msg) {
    websocket:Error? err = caller->writeMessage(msg);
    if err is websocket:Error {
        io:println("sendText failed: ", err.message());
    }
}

# + return - Returns an error if the server fails to start
public function main() returns error? {
    io:println("Local Voice Agent - WebSocket server listening on ws://localhost:8002/ws");
}

