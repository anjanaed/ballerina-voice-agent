import ballerina/ai;
import ballerina/http;
import ballerina/io;
import ballerina/lang.array;
import ballerina/lang.value as value;
import ballerina/time;
import ballerina/uuid;
import ballerina/websocket;
import ballerinax/ai.openai;

configurable string openaiToken = ?;

const string OPENAI_REALTIME_URL = "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview";

final ai:Agent voiceAgent = check new ({
    systemPrompt: {
        role: "Voice Assistant",
        instructions: "You are a helpful, friendly voice assistant. Keep responses concise and conversational (1-3 sentences). Return only the spoken response — no markdown, no lists."
    },
    model: check new openai:ModelProvider(openaiToken, openai:GPT_4O)
});


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


final ai:Agent taskAssistantAgent = check new ({
    systemPrompt: {
        role: "Task Assistant",
        instructions: string `You are a helpful assistant for managing a to-do list.
            You can manage tasks and help a user plan their schedule.
            Keep responses concise and conversational.`
    },
    tools: [addTask, listTasks, getCurrentDate],
    model: check new openai:ModelProvider(openaiToken, openai:GPT_4O)
});

# WebSocket listener on port 8010
@websocket:ServiceConfig {
    maxFrameSize: 104857600
}
service /ws on new websocket:Listener(8010) {

    # Upgrades the HTTP request to a WebSocket connection.
    # + req - The incoming HTTP upgrade request
    # + return - The WebSocket service or an upgrade error
    resource function get .(http:Request req) returns websocket:Service|websocket:UpgradeError {
        return new RealtimeWsService();
    }
}

service class RealtimeWsService {
    *websocket:Service;

    private final string sessionId = uuid:createRandomUuid();
    private websocket:Client? openaiWs = ();
    private boolean audioBuffered = false;
    private byte[] pcmOutputBuffer = [];

    # Connects to the OpenAI Realtime API and sends the session.update
    # event to configure voice, audio formats, and available tool calls.
    remote function onOpen(websocket:Caller caller) returns error? {
        io:println(string `[${self.sessionId}] Client connected — connecting to OpenAI Realtime API...`);

        websocket:Client oaiWs = check new (OPENAI_REALTIME_URL, {
            customHeaders: {
                "Authorization": "Bearer " + openaiToken,
                "OpenAI-Beta": "realtime=v1"
            }
        });
        self.openaiWs = oaiWs;

        # Configure the Realtime session: audio formats, VAD, instructions, and tool calls.
        json sessionUpdateEvent = {
            "type": "session.update",
            "session": {
                "modalities": ["text", "audio"],
                "instructions": "You are a helpful, friendly voice assistant. Keep responses concise and conversational (1-3 sentences). Avoid markdown and lists — respond as natural spoken language.",
                "voice": "alloy",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": {
                    "model": "whisper-1"
                },
                "turn_detection": {
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 800,
                    "create_response": true
                },
                "tools": [
                    {
                        "type": "function",
                        "name": "get_current_time",
                        "description": "Returns the current UTC date and time.",
                        "parameters": {
                            "type": "object",
                            "properties": {},
                            "required": []
                        }
                    },
                    {
                        "type": "function",
                        "name": "add_task",
                        "description": "Add a new task to the to-do list with an optional due date.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "description": {
                                    "type": "string",
                                    "description": "A brief description of the task."
                                },
                                "due_by": {
                                    "type": "object",
                                    "description": "Optional due date for the task.",
                                    "properties": {
                                        "year": {"type": "integer"},
                                        "month": {"type": "integer", "minimum": 1, "maximum": 12},
                                        "day": {"type": "integer", "minimum": 1, "maximum": 31}
                                    },
                                    "required": ["year", "month", "day"]
                                }
                            },
                            "required": ["description"]
                        }
                    },
                    {
                        "type": "function",
                        "name": "list_tasks",
                        "description": "Return all tasks in the to-do list as a JSON array.",
                        "parameters": {
                            "type": "object",
                            "properties": {},
                            "required": []
                        }
                    },
                    {
                        "type": "function",
                        "name": "get_current_date",
                        "description": "Returns today's date (year, month, day) in UTC.",
                        "parameters": {
                            "type": "object",
                            "properties": {},
                            "required": []
                        }
                    }
                ],
                "tool_choice": "auto"
            }
        };
        check oaiWs->writeMessage(value:toJsonString(sessionUpdateEvent));
        io:println(string `[${self.sessionId}] session.update sent to OpenAI Realtime API`);

        // Spawn a background strand to relay OpenAI server events back to the client
        _ = start self.relayOpenAIEvents(caller, oaiWs);
    }

    # Called when the client sends a binary message (raw PCM-16 audio chunks).
    # Encodes the audio as Base64 and appends it to the OpenAI input audio buffer.
    remote function onBinaryMessage(websocket:Caller caller, byte[] data) {
        websocket:Client? oaiWs = self.openaiWs;
        if oaiWs is () {
            return;
        }
        string base64Audio = array:toBase64(data);
        json appendEvent = {
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        };
        websocket:Error? err = oaiWs->writeMessage(value:toJsonString(appendEvent));
        if err is websocket:Error {
            io:println(string `[${self.sessionId}] Error forwarding audio to OpenAI: `, err.message());
        } else {
            self.audioBuffered = true;
        }
    }

    # Called when the client sends a text (JSON) control message.
    # when the client is operating in push-to-talk / streaming mode.
    remote function onTextMessage(websocket:Caller caller, string data) {
        json|error parsed = data.fromJsonString();
        if parsed is error {
            return;
        }
        if parsed is map<json> {
            json? msgType = parsed["type"];
            if msgType is string {
                match msgType {
                    "stream_end" => {
                        websocket:Client? oaiWs = self.openaiWs;
                        if oaiWs is websocket:Client && self.audioBuffered {
                            json commitEvent = {"type": "input_audio_buffer.commit"};
                            websocket:Error? err1 = oaiWs->writeMessage(value:toJsonString(commitEvent));
                            if err1 is websocket:Error {
                                io:println(string `[${self.sessionId}] Error sending commit: `, err1.message());
                            }
                            
                            json responseEvent = {"type": "response.create"};
                            websocket:Error? err2 = oaiWs->writeMessage(value:toJsonString(responseEvent));
                            if err2 is websocket:Error {
                                io:println(string `[${self.sessionId}] Error sending response.create: `, err2.message());
                            }
                            
                            self.audioBuffered = false;
                            io:println(string `[${self.sessionId}] stream_end received — manual commit sent`);
                        } else {
                            io:println(string `[${self.sessionId}] stream_end ignored — no audio buffered`);
                        }
                    }
                    "trace_marker" => {
                        json? traceId = parsed["trace_id"];
                        if traceId is string {
                            sendText(caller, string `PONG:${traceId}`);
                        }
                    }
                    _ => {
                        io:println(string `[${self.sessionId}] Ignoring unknown client message type: ${msgType}`);
                    }
                }
            }
        }
    }

    # Called when the client WebSocket connection is closed.
    remote function onClose(websocket:Caller caller, int statusCode, string reason) {
        io:println(string `[${self.sessionId}] Client disconnected: ${statusCode} — ${reason}`);
        websocket:Client? oaiWs = self.openaiWs;
        if oaiWs is websocket:Client {
            websocket:Error? err = oaiWs->close(1000, "Client disconnected");
            if err is websocket:Error {
                io:println("Error closing OpenAI WebSocket: ", err.message());
            }
        }
    }

    # Called on an unexpected client-side WebSocket error.
    remote function onError(websocket:Caller caller, error err) {
        io:println(string `[${self.sessionId}] Client error: `, err.message());
    }


    private function relayOpenAIEvents(websocket:Caller caller, websocket:Client oaiWs) {
        do {
            while true {
                string|error raw = oaiWs->readMessage();
                if raw is error {
                    io:println(string `[${self.sessionId}] OpenAI WebSocket closed: `, raw.message());
                    break;
                }
                json|error ev = raw.fromJsonString();
                if ev is error {
                    continue;
                }
                if ev is map<json> {
                    json? evType = ev["type"];
                    if evType is string {
                        error? handleErr = self.handleOpenAIEvent(caller, oaiWs, evType, ev);
                        if handleErr is error {
                            io:println(string `[${self.sessionId}] Event handler error (${evType}): `, handleErr.message());
                        }
                    }
                }
            }
        } on fail error e {
            io:println(string `[${self.sessionId}] relayOpenAIEvents fatal: `, e.message());
        }
    }

    private function handleOpenAIEvent(websocket:Caller caller, websocket:Client oaiWs,
            string evType, map<json> ev) returns error? {
        match evType {
            "response.output_audio.delta" => {
                json? delta = ev["delta"];
                if delta is string {
                    byte[]|error audioBytes = array:fromBase64(delta);
                    if audioBytes is byte[] {
                        self.pcmOutputBuffer.push(...audioBytes);
                    }
                }
            }

            "response.output_audio.done" => {
                if self.pcmOutputBuffer.length() > 0 {
                    byte[] wav = wrapPcmAsWav(self.pcmOutputBuffer, 24000);
                    self.pcmOutputBuffer = [];
                    websocket:Error? err = caller->writeMessage(wav);
                    if err is websocket:Error {
                        io:println("Failed to send WAV audio to client: ", err.message());
                    }
                }
            }
            "response.output_audio_transcript.delta" => {
                json? delta = ev["delta"];
                if delta is string {
                    sendText(caller, string `TRANSCRIPT_DELTA:${delta}`);
                }
            }
            "conversation.item.input_audio_transcription.completed" => {
                json? transcript = ev["transcript"];
                if transcript is string {
                    sendText(caller, string `TRANSCRIPT:${transcript}`);
                }
            }

            "response.done" => {
                json? response = ev["response"];
                if response is map<json> {
                    json? output = response["output"];
                    if output is json[] {
                        foreach json item in output {
                            if item is map<json> {
                                json? itemType = item["type"];
                                if itemType is string && itemType == "function_call" {
                                    check self.handleFunctionCall(caller, oaiWs, item);
                                }
                            }
                        }
                    }
                }
                sendText(caller, "MARK:RESPONSE_DONE");
            }

            "input_audio_buffer.speech_started" => {
                sendText(caller, "MARK:SPEECH_STARTED");
            }
            "input_audio_buffer.speech_stopped" => {
                sendText(caller, "MARK:SPEECH_STOPPED");
            }

            "session.created" => {
                io:println(string `[${self.sessionId}] OpenAI Realtime session created`);
                sendText(caller, "MARK:SESSION_READY");
            }
            "session.updated" => {
                io:println(string `[${self.sessionId}] OpenAI Realtime session configured with tools`);
            }

            "response.cancelled" => {
                self.pcmOutputBuffer = [];
                sendText(caller, "MARK:RESPONSE_CANCELLED");
            }

            "error" => {
                json? errDetail = ev["error"];
                string errMsg = value:toJsonString(errDetail ?: ev);
                io:println(string `[${self.sessionId}] OpenAI error: `, errMsg);
                sendText(caller, string `ERROR:${errMsg}`);
            }
        }
    }

    # Execute a function call requested by the Realtime model, then return the result
    private function handleFunctionCall(websocket:Caller caller, websocket:Client oaiWs,
            map<json> item) returns error? {
        json? nameJson = item["name"];
        json? callIdJson = item["call_id"];
        json? argsJson = item["arguments"];

        if !(nameJson is string && callIdJson is string) {
            return;
        }
        string funcName = nameJson;
        string callId = callIdJson;
        string resultOutput = "";

        match funcName {

            "invoke_agent" => {
                string queryStr = "";
                if argsJson is string {
                    json|error args = argsJson.fromJsonString();
                    if args is map<json> {
                        json? q = args["query"];
                        if q is string {
                            queryStr = q;
                        }
                    }
                }
                io:println(string `[${self.sessionId}] Invoking Ballerina agent with query: "${queryStr}"`);
                string|error agentResult = voiceAgent.run(queryStr, self.sessionId);
                if agentResult is string {
                    resultOutput = agentResult;
                } else {
                    resultOutput = string `Agent error: ${agentResult.message()}`;
                }
                sendText(caller, string `AGENT_RESPONSE:${resultOutput}`);
            }

            "get_current_time" => {
                time:Utc now = time:utcNow();
                resultOutput = string `Current UTC time: ${time:utcToString(now)}`;
            }

            "add_task" => {
                string description = "";
                time:Date? dueBy = ();
                if argsJson is string {
                    json|error args = argsJson.fromJsonString();
                    if args is map<json> {
                        json? desc = args["description"];
                        if desc is string {
                            description = desc;
                        }
                        json? due = args["due_by"];
                        if due is map<json> {
                            json? y = due["year"];
                            json? mo = due["month"];
                            json? d = due["day"];
                            if y is int && mo is int && d is int {
                                dueBy = {year: y, month: mo, day: d};
                            }
                        }
                    }
                }
                error? addErr = addTask(description, dueBy);
                if addErr is error {
                    resultOutput = string `Failed to add task: ${addErr.message()}`;
                } else {
                    resultOutput = string `Task added successfully: "${description}"`;
                }
            }

            "list_tasks" => {
                resultOutput = value:toJsonString(listTasks());
            }

            "get_current_date" => {
                time:Date today = getCurrentDate();
                resultOutput = string `Today's date: ${today.year}-${today.month}-${today.day}`;
            }

            _ => {
                resultOutput = string `Unknown function: ${funcName}`;
            }
        }

        # Send the function result back to the Realtime model
        json functionOutputEvent = {
            "type": "conversation.item.create",
            "item": {
                "type": "function_call_output",
                "call_id": callId,
                "output": resultOutput
            }
        };
        check oaiWs->writeMessage(value:toJsonString(functionOutputEvent));

        check oaiWs->writeMessage(value:toJsonString({"type": "response.create"}));
    }
}

# Wraps raw PCM-16 (Int16 LE, mono) bytes into a valid WAV buffer.
# + pcmData - Raw PCM-16 little-endian mono bytes
# + sampleRate - Sample rate in Hz (24000 for OpenAI Realtime output)
# + return - Complete WAV file bytes ready for playback
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

# Utility: send a text frame to the client WebSocket, logging failures.
isolated function sendText(websocket:Caller caller, string msg) {
    websocket:Error? err = caller->writeMessage(msg);
    if err is websocket:Error {
        io:println("sendText error: ", err.message());
    }
}

public function main() returns error? {
    io:println("OpenAI Realtime Voice Agent — WebSocket listening on ws://localhost:8010/ws");
    io:println("Model: gpt-4o-realtime-preview | Tools: get_current_time, add_task, list_tasks, get_current_date");
}