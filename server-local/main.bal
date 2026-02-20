import ballerina/io;
import ballerina/ai;
import ballerina/websocket;
import ballerina/http;
import ballerina/uuid;
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

service /ws on new websocket:Listener(8002) {
    resource function get .(http:Request req) returns websocket:Service|websocket:UpgradeError {
        return new WsService();
    }
}

isolated service class WsService {
    *websocket:Service;
    private final string sessionId = uuid:createRandomUuid();

    # Per-connection conversation history: [[role, content], ...]
    # No cap — running fully local so memory is not a concern.

    remote isolated function onMessage(websocket:Caller caller, byte[] data) {

        // Speech-to-Text
        // string requestId = uuid:createRandomUuid();
        // string tempDir = os:getEnv("TEMP");
        // string requestFile = string `${tempDir}\\request_${requestId}.wav`;

        // error? writeErr = io:fileWriteBytes(requestFile, data);
        // if writeErr is error {
        //     io:println("Failed to write WAV: ", writeErr.message());
        //     sendText(caller, "ERROR: could not save audio");
        //     return;
        // }

        string|error transcriptResult = transcribeWithLocalWhisper(data);

        // file:Error? removeErr = file:remove(requestFile);
        // if removeErr is file:Error {
        //     io:println("Warning: could not remove '", requestFile, "': ", removeErr.message());
        // }

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
        string|error agentResult = voiceAgent.run(transcript, self.sessionId);
        if agentResult is error {
            io:println("Agent error: ", agentResult.message());
            sendText(caller, "ERROR: Agent failed — " + agentResult.message());
            return;
        }


        // LLM call
        string llmResponse = agentResult;
        io:println("Agent: ", llmResponse);
        sendText(caller, "RESPONSE:" + llmResponse);


    
        // Text-to-Speech
        byte[]|error audioResult = ttsWithKokoro(llmResponse);
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


