import ballerina/http;
import ballerina/io;
import ballerina/uuid;
import ballerina/websocket;

@websocket:ServiceConfig {
	maxFrameSize: 104857600
}
service /ws on new websocket:Listener(websocketPort) {
	resource function get .(http:Request _) returns websocket:Service|websocket:UpgradeError {
		return new WsService();
	}
}

service class WsService {
	*websocket:Service;

	private final string sessionId = uuid:createRandomUuid();

	remote function onTextMessage(websocket:Caller caller, string data) {
		json|error parsed = data.fromJsonString();

		if parsed is error {
			self.processTextPrompt(caller, data);
			return;
		}

		if parsed is string {
			self.processTextPrompt(caller, parsed);
			return;
		}

		if parsed is map<json> {
			json? prompt = parsed.get("prompt");
			if prompt is string {
				self.processTextPrompt(caller, prompt);
				return;
			}

			sendText(caller, "ERROR: unsupported JSON message format");
			return;
		}

		sendText(caller, "ERROR: unsupported text message format");
	}

	private function processTextPrompt(websocket:Caller caller, string prompt) {
		string cleanedPrompt = prompt.trim();

		if cleanedPrompt.length() == 0 {
			sendText(caller, "ERROR: empty prompt");
			return;
		}

		io:println(string `[${self.sessionId}] Prompt: ${cleanedPrompt}`);

		string|error agentResult = runSelectedAgent(cleanedPrompt, self.sessionId);
		if agentResult is error {
			io:println(string `[${self.sessionId}] Agent error: ${agentResult.message()}`);
			sendText(caller, string `ERROR: ${agentResult.message()}`);
			return;
		}

		io:println(string `[${self.sessionId}] Response: ${agentResult}`);
		sendText(caller, agentResult);
	}
}
