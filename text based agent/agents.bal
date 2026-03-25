import ballerina/ai;
import ballerina/time;
import ballerina/uuid;

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
		instructions: string `You are a helpful assistant for
			managing a to-do list. You can manage tasks and
			help a user plan their schedule.`
	},
	tools: [addTask, listTasks, getCurrentDate],
	model: check ai:getDefaultModelProvider()
});

isolated function runSelectedAgent(string prompt, string sessionId) returns string|error {
	return taskAssistantAgent.run(prompt, sessionId);
}
