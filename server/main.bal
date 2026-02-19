import ballerina/ai;
import ballerina/http;
import ballerina/io;
import ballerina/websocket;
import ballerinax/openai.audio;

configurable string openaiToken = ?;

final audio:Client audioClient = check new ({auth: {token: openaiToken}});
final ai:ModelProvider model = check ai:getDefaultModelProvider();

service /ws on new websocket:Listener(8001) {
    resource function get .(http:Request req) returns websocket:Service|websocket:UpgradeError {
        return new WsService();
    }
}

isolated service class WsService {
    *websocket:Service;

    remote isolated function onMessage(websocket:Caller caller, byte[] data) returns websocket:Error? {
        byte[]|error response = voiceAgent(data);
        if response is byte[] {
            check caller->writeMessage(response);
        } else {
            io:println("Error processing voice agent request: ", response.message());
            // Optionally notify the client of the error, but don't close the connection
        }
    }
}

isolated function SpeechToText(string fileName) returns string|error {
    byte[] fileContent = check io:fileReadBytes(fileName);
    audio:CreateTranscriptionRequest request = {
        model: "whisper-1",
        file: {fileContent, fileName}
    };

    audio:CreateTranscriptionResponse response = check audioClient->/audio/transcriptions.post(request);
    io:println("STT Done: ", response.text);
    return response.text;
}

isolated function llmCall(string transcript) returns string|error {
    string response = check model->generate(`Assume that you are on conversation and reply to this with verbal language transcript. return only the response: ${transcript}`);
    io:println("LLM call Done: ", response);

    return response;
}

isolated function textToSpeech(string text) returns byte[]|error {
    audio:CreateSpeechRequest request = {
        model: "tts-1",
        input: text,
        voice: "alloy"
    };

    byte[] audioBytes = check audioClient->/audio/speech.post(request);
    io:println("TSS  Done");

    check io:fileWriteBytes("response.mp3", audioBytes);
    return audioBytes;
}

isolated function voiceAgent(byte[] data) returns byte[]|error {
    check io:fileWriteBytes("request.wav", data);
    string chat = check SpeechToText("request.wav");
    string response = check llmCall(chat);
    byte[] file = check textToSpeech(response);
    return file;
}

public function main() returns error? {
    io:println("WebSocket server listening on ws://localhost:8001/ws");

}

