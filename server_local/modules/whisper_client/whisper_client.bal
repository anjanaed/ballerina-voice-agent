import ballerina/http;
import ballerina/os;

final string whisperUrl = os:getEnv("WHISPER_URL") != "" ? os:getEnv("WHISPER_URL") : "http://localhost:8000";
final http:Client whisperClient = check new (whisperUrl);

public isolated function transcribeWithLocalWhisper(byte[] data) returns string|error {
    http:Response response = check whisperClient->post("/transcribe", data);
    int status = response.statusCode;
    if status != 200 {
        string|error bodyResult = response.getTextPayload();
        string responseBody = bodyResult is string ? bodyResult : string `Unable to read response body: ${bodyResult.message()}`;
        return error(string `Failed to transcribe. Status: ${status}, response: ${responseBody}`);
    }
    json respJson = check response.getJsonPayload();
    if respJson is map<json> && respJson.hasKey("transcription") && respJson["transcription"] is string {
        return <string>respJson["transcription"];
    }
    return error("No transcription in response");
}
