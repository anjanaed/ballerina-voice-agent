import ballerina/io;

public function main() returns error? {
	io:println("Task Assistant Agent running on ws://localhost:", websocketPort, "/ws");
}
