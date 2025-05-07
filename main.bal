// main.bal

import ballerina/http;
import ballerina/log;
import ballerina/task;
import ballerinax/googleapis.drive as drive;

listener http:Listener httpDefaultListener = http:getDefaultListener();

class Job {
    *task:Job;

    public function execute() {
        log:printInfo("Job: Starting scheduled document processing");
        stream<drive:File>|error documentStream = retrieveUpdatedDocuments(["attendees", "Invited"]);
        if (documentStream is error) {
            log:printError("Job: Error retrieving documents from Google Drive", documentStream);
            return;
        }
        log:printInfo("Job: Retrieved updated documents from Google Drive");
        ProcessingResult[]|error results = processDocuments(documentStream);
        if (results is error) {
            log:printError("Job: Error processing documents", results);
            return;
        }
        log:printInfo(`Job: Documents processed successfully. Results count: ${results.length()}`);
    }
}

// Schedule the job to run every 7 days
public function main() returns error? {
    // log:printInfo("Main: Starting Google Drive Updated Document Processing Service...");
    // task:JobId jobId = check task:scheduleJobRecurByFrequency(new Job(), jobInterval);
    // log:printInfo(`Main: Scheduled job with ID: ${jobId}`);
}

service /vectorize on httpDefaultListener {

    resource function post init() returns error|json {
        log:printInfo("POST /vectorize/init: Retrieving all documents from Google Drive");
        stream<drive:File> documentStream = check retrieveAllDocuments(["attendees", "Invited"]);
        log:printInfo("POST /vectorize/init: Documents retrieved from Google Drive");

        ProcessingResult[]|error results = processDocuments(documentStream);
        if (results is error) {
            log:printError("POST /vectorize/init: Error processing documents", results);
            return error("Failed to process documents");
        }
        log:printInfo(`POST /vectorize/init: Documents processed successfully. Results count: ${results.length()}`);

        int saveTokenResult = check saveInitialToken();
        log:printInfo(`POST /vectorize/init: Token saved successfully: ${saveTokenResult}`);

        json response = {
            message: "Documents processed successfully",
            results: results
        };

        return response;
    }

    resource function post changes() returns error|json {
        log:printInfo("POST /vectorize/changes: Retrieving updated documents from Google Drive");
        stream<drive:File>|error documentStream = retrieveUpdatedDocuments(["attendees", "Invited"]);
        if (documentStream is error) {
            log:printError("POST /vectorize/changes: Error retrieving documents from Google Drive", documentStream);
            return error("Failed to retrieve documents");
        }
        log:printInfo("POST /vectorize/changes: Documents retrieved from Google Drive");

        ProcessingResult[]|error results = processDocuments(documentStream);
        if (results is error) {
            log:printError("POST /vectorize/changes: Error processing documents", results);
            return;
        }
        log:printInfo(`POST /vectorize/changes: Documents processed successfully. Results count: ${results.length()}`);

        string|error updatedToken = updateToken();
        if (updatedToken is error) {
            log:printError("POST /vectorize/changes: Error updating token", updatedToken);
            return error("Failed to update token");
        }
        log:printInfo(`POST /vectorize/changes: Token updated successfully: ${updatedToken}`);

        json response = {
            message: "Documents processed successfully",
            results: results
        };
        return response;
    }
}
