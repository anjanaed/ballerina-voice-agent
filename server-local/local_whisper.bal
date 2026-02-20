
import ballerina/http;
final http:Client whisperClient = check new("http://localhost:8000");

isolated function transcribeWithLocalWhisper(string fileName) returns string|error {
    string endpoint = "/transcribe?file_path=" + fileName;
    http:Response response = check whisperClient->post(endpoint, ());
    int status = response.statusCode;
    if status != 200 {
        string responseBody = "";
        string|error bodyResult = response.getTextPayload();
        if bodyResult is string {
            responseBody = bodyResult;
        } else {
            responseBody = string `Unable to read response body: ${bodyResult.message()}`;
        }
        return error(string `Failed to transcribe. Status: ${status}, endpoint: ${endpoint}, response: ${responseBody}`);
    }
    json respJson = check response.getJsonPayload();
    if respJson is map<json> && respJson.hasKey("transcription") && respJson["transcription"] is string {
        return <string>respJson["transcription"];
    } else {
        return error("No transcription in response");
    }
}
