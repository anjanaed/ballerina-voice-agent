// Application configuration

// OpenAI API token for authentication
// Must be provided via Config.toml or environment variable
configurable string openaiToken = ?;

// WebSocket server port for client connections
// Default: 8001
configurable int websocketPort = 8001;

