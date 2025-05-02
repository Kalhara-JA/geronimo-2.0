import ballerina/http;
import ballerina/log;
import ballerina/task;
import ballerinax/googleapis.drive as drive;

listener http:Listener httpDefaultListener = http:getDefaultListener();

class Job {
    *task:Job;

    public function execute() {
        stream<drive:File>|error documentStream = retrieveUpdatedDocuments(["attendees", "Invited"]);
        if (documentStream is error) {
            log:printError("Error retrieving documents from Google Drive", documentStream);
            return;
        }
        ProcessingResult[]|error results = processDocuments(documentStream);
        if (results is error) {
            log:printError("Error processing documents", results);
            return;
        }
        log:printInfo("Documents processed successfully");
    }
}

// Schedule the job to run every 7 days
public function main() returns error? {
    // log:printInfo("Starting Google Drive Updated Document Processing Service...");
    // task:JobId jobId = check task:scheduleJobRecurByFrequency(new Job(), jobInterval);
    // log:printInfo(`Scheduled job with ID: ${jobId}`);
}

service /vectorize on httpDefaultListener {

    resource function post init() returns error|json {
        // Retrieve all documents from Google Drive
        log:printInfo("Retrieving documents from Google Drive");
        stream<drive:File> documentStream = check retrieveAllDocuments(["attendees", "Invited"]);
        log:printInfo("Documents retrieved from Google Drive");

        ProcessingResult[]|error results = processDocuments(documentStream);
        if (results is error) {
            log:printError("Error processing documents", results);
            return error("Failed to process documents");
        }
        log:printInfo("Documents processed successfully");

        int saveTokenResult = check saveInitialToken();
        log:printInfo(`Token saved successfully: ${saveTokenResult}`);

        // Create a response object
        json response = {
            message: "Documents processed successfully",
            results: results
        };

        // Return the response
        return response;
    }

    resource function post changes() returns error|json {
        stream<drive:File>|error documentStream = retrieveUpdatedDocuments(["attendees", "Invited"]);
        if (documentStream is error) {
            log:printError("Error retrieving documents from Google Drive", documentStream);
            return error("Failed to retrieve documents");
        }
        
        ProcessingResult[]|error results = processDocuments(documentStream);
        if (results is error) {
            log:printError("Error processing documents", results);
            return;
        }
        
        // Update the last token
        string|error updatedToken = updateToken();
        if (updatedToken is error) {
            log:printError("Error updating token", updatedToken);
            return error("Failed to update token");
        }
        log:printInfo(`Token updated successfully: ${updatedToken}`);

        json response = {
            message: "Documents processed successfully",
            results: results
        };
        return response;
    }
}
