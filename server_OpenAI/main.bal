import ballerina/ai;
import ballerina/http;
import ballerina/io;
import ballerina/uuid;
import ballerina/websocket;
import ballerinax/ai.openai;
import ballerinax/openai.audio;

# The OpenAI token for accessing the GPT model.
configurable string openaiToken = ?;

# The audio client for OpenAI text-to-speech and speech-to-text.
final audio:Client audioClient = check new ({auth: {token: openaiToken}});

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
service /ws on new websocket:Listener(8001) {

    # Upgrades the HTTP request to a WebSocket connection.
    #
    # + req - The HTTP request
    # + return - The WebSocket service or an upgrade error
    resource function get .(http:Request req) returns websocket:Service|websocket:UpgradeError {
        return new WsService();
    }
}

# Represents the WebSocket service for the OpenAI voice agent.
isolated service class WsService {
    *websocket:Service;

    # Unique session ID per connection — the agent uses this to isolate history.
    private final string sessionId = uuid:createRandomUuid();

    # Triggered when a binary message (audio) is received from the client.
    # Performs speech-to-text, queries the voice agent, and returns text-to-speech audio.
    #
    # + caller - The WebSocket caller
    # + data - The audio data received as a byte array
    remote isolated function onBinaryMessage(websocket:Caller caller, byte[] data) {

        string|error transcriptResult = speechToText(data);
        if transcriptResult is error {
            io:println("STT error: ", transcriptResult.message());
            sendText(caller, string `ERROR: transcription failed — ${transcriptResult.message()}`);
            return;
        }

        string transcript = transcriptResult;
        io:println("STT: ", transcript);
        sendText(caller, string `TRANSCRIPT:${transcript}`);

        string|error agentResult = voiceAgent.run(transcript, self.sessionId);
        if agentResult is error {
            io:println("Agent error: ", agentResult.message());
            sendText(caller, string `ERROR: Agent failed — ${agentResult.message()}`);
            return;
        }

        string llmResponse = agentResult;
        io:println("Agent: ", llmResponse);
        sendText(caller, string `RESPONSE:${llmResponse}`);

        byte[]|error audioResult = textToSpeech(llmResponse);
        if audioResult is error {
            io:println("TTS error: ", audioResult.message());
            sendText(caller, string `ERROR: TTS failed — ${audioResult.message()}`);
            return;
        }

        websocket:Error? audioErr = caller->writeMessage(audioResult);
        if audioErr is websocket:Error {
            io:println("Failed to send audio to client: ", audioErr.message());
        }
    }
}

# Sends a plain-text WebSocket frame. Errors are logged, never propagated.
#
# + caller - The WebSocket caller
# + msg - The text message to send
isolated function sendText(websocket:Caller caller, string msg) {
    websocket:Error? err = caller->writeMessage(msg);
    if err is websocket:Error {
        io:println("sendText failed: ", err.message());
    }
}

# Transcribes raw audio bytes via OpenAI Whisper.
#
# + data - The audio data received as a byte array
# + return - The transcribed text or an error
isolated function speechToText(byte[] data) returns string|error {
    audio:CreateTranscriptionRequest request = {
        model: "whisper-1",
        file: {fileContent: data, fileName: "input.wav"}
    };
    audio:CreateTranscriptionResponse response = check audioClient->/audio/transcriptions.post(request);
    return response.text;
}

# Converts text to speech audio via OpenAI TTS.
#
# + text - The text to convert to speech
# + return - The audio data as a byte array or an error
isolated function textToSpeech(string text) returns byte[]|error {
    audio:CreateSpeechRequest request = {
        model: "tts-1",
        input: text,
        voice: "alloy"
    };
    return check audioClient->/audio/speech.post(request);
}

# The main function that starts the server.
#
# + return - Returns an error if the server fails to start
public function main() returns error? {
    io:println("WebSocket server listening on ws://localhost:8001/ws");
}
