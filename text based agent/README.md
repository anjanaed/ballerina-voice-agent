# Voice Agent - Ballerina AI Application

A production-ready voice-enabled AI agent built with Ballerina, featuring speech-to-text, text-to-speech, and intelligent task management capabilities.

## Features

- **🎤 Voice Interaction**: Real-time speech-to-text and text-to-speech using OpenAI's Whisper and TTS
- **💬 Text Chat**: Direct text-based interaction with AI agents
- **📋 Task Management**: Dedicated AI agent for managing to-do lists with intelligent scheduling
- **🔄 Multi-Agent System**: Route requests to specialized agents based on context
- **🌐 WebSocket Protocol**: High-performance real-time communication
- **🔒 Thread-Safe**: Isolated functions and proper concurrency handling

## Architecture

### Agents

1. **Voice Assistant** (Default)
   - General conversational AI
   - Optimized for voice interactions
   - Concise, natural responses (1-3 sentences)

2. **Task Assistant** (Prefix: `task:`)
   - Task creation and management
   - Due date tracking
   - Task completion and deletion
   - Date/time awareness

### Agent Tools

The Task Assistant includes the following tools:

- `addTask(description, dueBy)` - Add new tasks with optional due dates
- `listTasks()` - View all tasks
- `completeTask(taskId)` - Mark tasks as completed
- `deleteTask(taskId)` - Remove tasks
- `getCurrentDateTime()` - Get current date and time

## Project Structure

```
Voice Agent/
├── main.bal              # WebSocket service and message handling
├── agents.bal            # AI agents and agent tools
├── connections.bal       # OpenAI client initialization
├── functions.bal         # Audio processing functions
├── types.bal             # Type definitions
├── config.bal            # Configuration parameters
├── automation.bal        # Application entry point
├── Ballerina.toml        # Project manifest
└── Config.toml           # Configuration values (not tracked)
```

## Prerequisites

- Ballerina 2201.13.1 or later
- OpenAI API key

## Installation

1. Clone the repository:
```bash
cd "Voice Agent"
```

2. Create a `Config.toml` file with your OpenAI API key:
```toml
openaiToken = "sk-your-openai-api-key-here"
websocketPort = 8001
```

3. Build the project:
```bash
bal build
```

## Usage

### Run the Server

```bash
bal run
```

The server will start on `ws://localhost:8001/ws`

### WebSocket Protocol

#### Text Messages

Send plain text or JSON:

**Plain text:**
```
Hello, how are you?
```

**JSON format:**
```json
{
  "type": "prompt",
  "prompt": "What's the weather like?"
}
```

**Task management:**
```
task: add a task to buy groceries by tomorrow
```

#### Audio Messages

Send binary data in WAV format:
- Sample rate: 16000 Hz (recommended)
- Channels: Mono
- Bits per sample: 16-bit

For streaming audio:
1. Send raw PCM chunks as binary frames
2. Send `{"type": "stream_end"}` to process

#### Server Responses

- `TRANSCRIPT:<text>` - Speech recognition result
- `RESPONSE:<text>` - AI agent response
- `ERROR:<message>` - Error notification
- Binary audio data (WAV format) - TTS response

## Development

### Adding New Agent Tools

1. Define an isolated function with `@ai:AgentTool` annotation:

```ballerina
@ai:AgentTool
isolated function myTool(string param) returns string|error {
    // Implementation
    return "Result";
}
```

2. Add the function to the agent's tools array:

```ballerina
final ai:Agent myAgent = check new ({
    systemPrompt: {...},
    tools: [myTool, otherTool],
    model: model
});
```

### Best Practices

- Always use `isolated` functions for agent tools
- Return descriptive strings to help the agent understand results
- Use proper error handling with `returns string|error`
- Document tool parameters clearly - they become the function signature for the LLM
- Keep agent responses concise for voice output

## Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `openaiToken` | string | required | OpenAI API key |
| `websocketPort` | int | 8001 | WebSocket server port |

## API Reference

### Agent Tools (Task Assistant)

#### addTask
```ballerina
@ai:AgentTool
isolated function addTask(
    string description,
    time:Civil? dueBy = ()
) returns string
```
Adds a new task with optional due date.

#### listTasks
```ballerina
@ai:AgentTool
isolated function listTasks() returns Task[]
```
Returns all tasks (completed and pending).

#### completeTask
```ballerina
@ai:AgentTool
isolated function completeTask(string taskId) returns string|error
```
Marks a task as completed.

#### deleteTask
```ballerina
@ai:AgentTool
isolated function deleteTask(string taskId) returns string|error
```
Removes a task from the list.

#### getCurrentDateTime
```ballerina
@ai:AgentTool
isolated function getCurrentDateTime() returns string
```
Returns current date and time in readable format.

## Examples

### Task Management

```
User: "task: remind me to call mom tomorrow at 2pm"
Agent: Task added successfully: "Call mom" due by 2026-03-26 14:00

User: "task: what are my tasks?"
Agent: You have 1 task:
       1. Call mom - Due by 2026-03-26 14:00

User: "task: mark the first task as done"
Agent: Task "Call mom" marked as completed
```

### Voice Assistant

```
User: [Audio: "What is the capital of France?"]
Agent: [Audio: "The capital of France is Paris."]
```

## Technical Details

### Concurrency

- All agent tools use `isolated` functions for thread safety
- Task storage uses `lock` blocks for concurrent access
- WebSocket connections are independent per session

### Audio Processing

- Accepts WAV files (complete) or PCM streams (chunked)
- Automatic WAV header detection
- PCM-to-WAV conversion for streaming audio
- 16kHz sample rate recommended for best results

### Error Handling

- Graceful error messages sent to clients
- Server-side logging for debugging
- Session ID tracking for request correlation

## License

Copyright (c) 2026 Anjana Ed

## Support

For issues and questions:
- Check Ballerina documentation: https://ballerina.io
- Ballerina AI module: https://central.ballerina.io/ballerina/ai
- OpenAI API docs: https://platform.openai.com/docs
