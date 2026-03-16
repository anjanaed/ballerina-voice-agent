import ballerina/http;
import ballerina/os;

final string kokoroUrl = os:getEnv("KOKORO_URL") != "" ? os:getEnv("KOKORO_URL") : "http://localhost:8005";
final http:Client kokoroClient = check new (kokoroUrl);

public isolated function ttsWithKokoro(string text) returns byte[]|error {
    json requestBody = {
        text: text
    };
    http:Response response = check kokoroClient->post("/synthesize", requestBody);
    int status = response.statusCode;
    if status != 200 {
        return error(string `Failed to synthesize. Status: ${status}`);
    }
    return check response.getBinaryPayload();
}
