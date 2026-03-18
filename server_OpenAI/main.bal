import ballerina/ai;
import ballerina/http;
import ballerina/io;
import ballerina/time;
import ballerina/uuid;
import ballerina/websocket;
import ballerina/lang.value as value;
import ballerinax/ai.openai;
import ballerinax/openai.audio;

configurable string openaiToken = ?;

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

    # + req - The HTTP request
    # + return - The WebSocket service or an upgrade error
    resource function get .(http:Request req) returns websocket:Service|websocket:UpgradeError {
        return new WsService();
    }
}

# WebSocket service for the OpenAI voice agent.
service class WsService {
    *websocket:Service;

    private final string sessionId = uuid:createRandomUuid();
    # Accumulated streaming PCM-16 chunks (Int16 LE, mono, 16kHz)
    private byte[] streamBuffer = [];
    private boolean isStreaming = false;

    remote function onTextMessage(websocket:Caller caller, string data) {
        json|error parsed = data.fromJsonString();
        if parsed is error {
            return;
        }

        if parsed is map<json> {
            json? msgType = parsed.get("type");
            if msgType is string && msgType == "stream_end" {
                // Streaming complete — wrap accumulated PCM into WAV and process
                if self.streamBuffer.length() > 0 {
                    byte[] wavData = wrapPcmAsWav(self.streamBuffer, 16000);
                    self.streamBuffer = [];
                    self.isStreaming = false;
                    self.processAudioPipeline(caller, wavData);
                } else {
                    self.isStreaming = false;
                }
            }
        }
    }

    # Triggered when a binary message (audio) is received from the client.
    # In streaming mode: accumulates PCM chunks. In non-streaming mode: processes full WAV.
    # + caller - The WebSocket caller
    # + data - The audio data received as a byte array
    remote function onBinaryMessage(websocket:Caller caller, byte[] data) {
        // Check if this looks like a WAV file (starts with RIFF header)
        if data.length() >= 44 && data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46 {
            // Full WAV received (non-streaming / legacy path)
            self.processAudioPipeline(caller, data);
        } else {
            // Streaming PCM-16 chunk — accumulate
            self.isStreaming = true;
            self.streamBuffer.push(...data);
        }
    }

    # Runs the full STT → LLM → TTS pipeline on a complete WAV/audio buffer.
    private function processAudioPipeline(websocket:Caller caller, byte[] data) {
        string|error transcriptResult = speechToText(data);
        if transcriptResult is error {
            io:println("STT error: ", transcriptResult.message());
            sendText(caller, string `ERROR: transcription failed — ${transcriptResult.message()}`);
            return;
        }

        string transcript = transcriptResult;
        sendText(caller, string `TRANSCRIPT:${transcript}`);

        string|error agentResult = voiceAgent.run(transcript, self.sessionId);
        if agentResult is error {
            io:println("Agent error: ", agentResult.message());
            sendText(caller, string `ERROR: Agent failed — ${agentResult.message()}`);
            return;
        }

        string llmResponse = agentResult;

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
        sendText(caller, string `RESPONSE:${llmResponse}`);
    }
}

# Wraps raw PCM-16 (Int16 LE, mono) bytes into a valid WAV buffer.
isolated function wrapPcmAsWav(byte[] pcmData, int sampleRate) returns byte[] {
    int dataLen = pcmData.length();
    int fileLen = 36 + dataLen;
    int byteRate = sampleRate * 2;

    byte[] header = [
        0x52, 0x49, 0x46, 0x46,
        <byte>(fileLen & 0xFF), <byte>((fileLen >> 8) & 0xFF),
        <byte>((fileLen >> 16) & 0xFF), <byte>((fileLen >> 24) & 0xFF),
        0x57, 0x41, 0x56, 0x45,
        0x66, 0x6D, 0x74, 0x20,
        0x10, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x01, 0x00,
        <byte>(sampleRate & 0xFF), <byte>((sampleRate >> 8) & 0xFF),
        <byte>((sampleRate >> 16) & 0xFF), <byte>((sampleRate >> 24) & 0xFF),
        <byte>(byteRate & 0xFF), <byte>((byteRate >> 8) & 0xFF),
        <byte>((byteRate >> 16) & 0xFF), <byte>((byteRate >> 24) & 0xFF),
        0x02, 0x00,
        0x10, 0x00,
        0x64, 0x61, 0x74, 0x61,
        <byte>(dataLen & 0xFF), <byte>((dataLen >> 8) & 0xFF),
        <byte>((dataLen >> 16) & 0xFF), <byte>((dataLen >> 24) & 0xFF)
    ];

    header.push(...pcmData);
    return header;
}


# Sends a plain-text WebSocket frame.
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


# + return - Returns an error if the server fails to start
public function main() returns error? {
    io:println("WebSocket server listening on ws://localhost:8001/ws");
}
