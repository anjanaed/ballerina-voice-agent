import ballerina/io;
import ballerina/websocket;

isolated function sendText(websocket:Caller caller, string msg) {
	websocket:Error? err = caller->writeMessage(msg);
	if err is websocket:Error {
		io:println(string `sendText failed: ${err.message()}`);
	}
}
