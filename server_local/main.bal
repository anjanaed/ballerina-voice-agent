import server_local.kokoro_client;
import server_local.whisper_client;

import ballerina/ai;
import ballerina/http;
import ballerina/io;
import ballerina/time;
import ballerina/uuid;
import ballerina/websocket;
import ballerina/lang.value as value;
import ballerinax/ai.openai;

configurable string openaiToken = ?;

final ai:ModelProvider model = check new openai:ModelProvider(openaiToken, openai:GPT_4O);

type Task record {| 
    string description;
    time:Date dueBy?;
    time:Date createdAt = time:utcToCivil(time:utcNow());
    time:Date completedAt?;
    boolean completed = false;
|};

isolated map<Task> tasks = {
    "a2af0faa-3b73-4184-9be1-87b29a963be6": {
        description: "Buy groceries",
        dueBy: time:utcToCivil(time:utcAddSeconds(time:utcNow(), 60 * 5))
    }
};

@ai:AgentTool
isolated function addTask(string description, time:Date? dueBy) returns error? {
    lock {
        tasks[uuid:createRandomUuid()] = {description, dueBy: dueBy.clone()};
    }
}

@ai:AgentTool
isolated function listTasks() returns Task[] {
    lock {
        return tasks.toArray().clone();
    }
}

@ai:AgentTool
isolated function getCurrentDate() returns time:Date {
    time:Civil {year, month, day} = time:utcToCivil(time:utcNow());
    return {year, month, day};
}

final ai:Agent voiceAgent = check new ({
    systemPrompt: {
        role: "Voice Assistant",
        instructions: "You are a helpful, friendly voice assistant. Keep responses concise and conversational (1-3 sentences). Return only the spoken response — no markdown, no lists. You can also manage a to-do list by adding tasks, listing tasks, and checking today's date when the user asks."
    },
    tools: [addTask, listTasks, getCurrentDate],
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

service class WsService {
    *websocket:Service;

    # The unique session ID for the connection.
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

    # Runs the full STT → LLM → TTS pipeline on a complete WAV buffer.
    private function processAudioPipeline(websocket:Caller caller, byte[] data) {
        string|error transcriptResult = whisper_client:transcribeWithLocalWhisper(data);

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

# Wraps raw PCM-16 (Int16 LE, mono) bytes into a valid WAV buffer.
isolated function wrapPcmAsWav(byte[] pcmData, int sampleRate) returns byte[] {
    int dataLen = pcmData.length();
    int fileLen = 36 + dataLen; // total file size minus 8 bytes for RIFF header
    int byteRate = sampleRate * 2; // mono * 16-bit

    // 44-byte WAV header
    byte[] header = [
        // RIFF
        0x52, 0x49, 0x46, 0x46,
        // file length (little-endian)
        <byte>(fileLen & 0xFF), <byte>((fileLen >> 8) & 0xFF),
        <byte>((fileLen >> 16) & 0xFF), <byte>((fileLen >> 24) & 0xFF),
        // WAVE
        0x57, 0x41, 0x56, 0x45,
        // fmt 
        0x66, 0x6D, 0x74, 0x20,
        // fmt chunk size = 16
        0x10, 0x00, 0x00, 0x00,
        // PCM format = 1
        0x01, 0x00,
        // channels = 1
        0x01, 0x00,
        // sample rate (little-endian)
        <byte>(sampleRate & 0xFF), <byte>((sampleRate >> 8) & 0xFF),
        <byte>((sampleRate >> 16) & 0xFF), <byte>((sampleRate >> 24) & 0xFF),
        // byte rate (little-endian)
        <byte>(byteRate & 0xFF), <byte>((byteRate >> 8) & 0xFF),
        <byte>((byteRate >> 16) & 0xFF), <byte>((byteRate >> 24) & 0xFF),
        // block align = 2
        0x02, 0x00,
        // bits per sample = 16
        0x10, 0x00,
        // data
        0x64, 0x61, 0x74, 0x61,
        // data length (little-endian)
        <byte>(dataLen & 0xFF), <byte>((dataLen >> 8) & 0xFF),
        <byte>((dataLen >> 16) & 0xFF), <byte>((dataLen >> 24) & 0xFF)
    ];

    // Concatenate header + PCM data
    header.push(...pcmData);
    return header;
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

