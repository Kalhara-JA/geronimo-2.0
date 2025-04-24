// Copyright (c) 2024, WSO2 LLC. (http://www.wso2.org) All Rights Reserved.

import geronimo_2_0.db;

import ballerina/http;
import ballerina/io;
import ballerina/log;
import ballerina/task;
import ballerina/time;
import ballerinax/googleapis.drive as drive;

listener http:Listener httpDefaultListener = http:getDefaultListener();

class Job {
    *task:Job;

    public function execute() {
        // Execute the job logic here
        log:printInfo("Executing job...");
        // Declare a variable to hold the results
        ProcessingResult[] results = [];

        db:Token|error lastToken = getToken();
        if (lastToken is error) {
            log:printError("Error retrieving last token: " + lastToken.message());
            return;
        }

        stream<drive:Change>|error changes = driveClient->listChanges(lastToken.token);

        if (changes is error) {
            log:printError("Error retrieving changes: " + changes.message());
            return;
        }

        drive:Change[] changesList = from drive:Change ch in changes
            select ch;

        if changesList.length() == 0 {
            log:printInfo("No changes found in Google Drive");
            // return {message: "No changes found"};

        }

        foreach drive:Change ch in changesList {
            DocumentMetadata metadata = {
                fileId: ch.fileId ?: ""
            };
            if (ch.removed == true) {
                // Handle file removal
                int|error deletedCount = deleteExistingVectors(metadata, driveCollectionName);
                if (deletedCount is error) {
                    log:printError("Error deleting vectors for removed file: " + deletedCount.message());
                } else {
                    log:printInfo(`Deleted vectors for removed file: ${ch.fileId} count: ${deletedCount}`);
                }

            } else {
                // Extract metadata
                log:printInfo(`Extracting metadata from file: ${ch.fileId}`);
                DocumentMetadata|error fileMetadata = extractMetadata(ch.fileId ?: "");
                if (fileMetadata is error) {
                    log:printError("Error extracting metadata: " + fileMetadata.message());
                    continue;
                }
                log:printInfo(`Metadata extracted from file: ${metadata.fileId}`);

                // Initialize result record
                ProcessingResult result = {
                    fileId: fileMetadata.fileId,
                    fileName: fileMetadata.fileName ?: "",
                    fileLink: fileMetadata.webViewLink ?: "",
                    success: false,
                    errorMessage: ()
                };

                // Extract file content
                log:printInfo(`Extracting content from file: ${fileMetadata.fileId}`);
                string|error extractedContent = extractContent(fileMetadata.fileId, fileMetadata.fileName ?: "");
                if (extractedContent is error) {
                    log:printError("Error extracting content: " + extractedContent.message());
                    result.errorMessage = extractedContent.message();
                    results.push(result);
                    continue;
                }
                log:printInfo(`Content extracted from file: ${fileMetadata.fileId}`);

                // Chunk the extracted content
                log:printInfo(`Chunking content from file: ${fileMetadata.fileId}`);
                MarkdownChunk[] chunks = chunkMarkdownText(extractedContent, fileMetadata, maxTokens = 400, overlapTokens = 50);
                log:printInfo(`Content chunked from file: ${fileMetadata.fileId}`);

                //check vectorstore if the file already exists and delete if it does
                log:printInfo(`Checking for existing vectors for file: ${fileMetadata.fileId}`);
                VectorDataWithId[]|error existing = fetchExistingVectors(fileMetadata, driveCollectionName);
                if (existing is error) {
                    log:printError("Error fetching existing vectors: " + existing.message());
                    result.errorMessage = existing.message();
                    results.push(result);
                    continue;
                }
                if existing.length() > 0 {
                    int|error deletedCount = deleteExistingVectors(fileMetadata, driveCollectionName);
                    if (deletedCount is error) {
                        log:printError("Error deleting existing vectors: " + deletedCount.message());
                        result.errorMessage = deletedCount.message();
                        results.push(result);
                        continue;
                    }
                    log:printInfo(`Deleted ${deletedCount} existing vectors for file: ${fileMetadata.fileId}`);
                }

                // Iterate over each chunk and get embeddings
                log:printInfo(`Processing chunks from file: ${fileMetadata.fileId}`);
                foreach MarkdownChunk chunk in chunks {
                    // Get embeddings for each chunk
                    float[]|error embeddings = getEmbedding(chunk.content);
                    if (embeddings is error) {
                        log:printError("Error getting embeddings: " + embeddings.message());
                        result.errorMessage = embeddings.message();
                        results.push(result);
                        continue;
                    }

                    // Store in vector store
                    VectorDataWithId|error vectorEntry = addVectorEntry(
                                    embeddings,
                            chunk.metadata.webViewLink ?: "",
                            fileMetadata,
                            driveCollectionName
                            );

                    if (vectorEntry is error) {
                        log:printError("Error adding vector entry: " + vectorEntry.message());
                        result.errorMessage = vectorEntry.message();
                        results.push(result);
                        continue;
                    }
                }
                log:printInfo(`Chunks processed from file: ${fileMetadata.fileId}`);
                // Update result record
                result.success = true;
                results.push(result);
            }
        }

        if results.every(result => result.success) {
            log:printInfo("All documents processed successfully");
            string|error token = driveClient->getStartPageToken();
            if (token is error) {
                log:printError("Error retrieving start page token: " + token.message());
                return;
            }
            string|error updatedToken = updateToken(token);
            if (updatedToken is error) {
                log:printError("Error updating token: " + updatedToken.message());
                return;
            }
            log:printInfo(`Token updated successfully: ${updatedToken}`);
        } else {
            log:printError("Some documents failed to process. Check results for details.");
        }

        log:printInfo("Job executed successfully.");
    }
}

// // Schedule the job to run every 7 days
// public function main() returns error? {
//     log:printInfo("Starting Google Drive Updated Document Processing Service...");
//     task:JobId jobId = check task:scheduleJobRecurByFrequency(new Job(), jobInterval);
//     log:printInfo(`Scheduled job with ID: ${jobId}`);
// }

service /vectorize on httpDefaultListener {

    resource function post init() returns error|json {

        // Retrieve all documents from Google Drive
        log:printInfo("Retrieving documents from Google Drive");
        stream<drive:File> documentStream = check retrieveAllDocuments(["attendees", "Invited"]);
        log:printInfo("Documents retrieved from Google Drive");

        // Declare a variable to hold the results
        ProcessingResult[] results = [];

        // Iterate over each file in the stream
        // log:printInfo("Processing documents from Google Drive");
        foreach drive:File driveFile in documentStream {

            // Extract metadata
            log:printInfo(`Extracting metadata from file: ${driveFile.id}`);
            DocumentMetadata metadata = check extractMetadata(driveFile.id ?: "");
            log:printInfo(`Metadata extracted from file: ${metadata.fileId}`);

            // Initialize result record
            ProcessingResult result = {
                fileId: metadata.fileId,
                fileName: metadata.fileName ?: "",
                fileLink: metadata.webViewLink ?: "",
                success: false,
                errorMessage: ()
            };

            // Extract file content
            log:printInfo(`Extracting content from file: ${metadata.fileId}`);
            string extractedContent = check extractContent(metadata.fileId, metadata.fileName ?: "");
            log:printInfo(`Content extracted from file: ${metadata.fileId}`);

            // Chunk the extracted content
            log:printInfo(`Chunking content from file: ${metadata.fileId}`);
            MarkdownChunk[] chunks = chunkMarkdownText(extractedContent, metadata, maxTokens = 400, overlapTokens = 50);
            log:printInfo(`Content chunked from file: ${metadata.fileId}`);

            //check vectorstore if the file already exists and delete if it does
            log:printInfo(`Checking for existing vectors for file: ${metadata.fileId}`);
            VectorDataWithId[] existing = check fetchExistingVectors(metadata, driveCollectionName);
            if existing.length() > 0 {
                int deletedCount = check deleteExistingVectors(metadata, driveCollectionName);
                log:printInfo(`Deleted ${deletedCount} existing vectors for file: ${metadata.fileId}`);
            }

            // Iterate over each chunk and get embeddings
            log:printInfo(`Processing chunks from file: ${metadata.fileId}`);
            foreach MarkdownChunk chunk in chunks {
                // Get embeddings for each chunk
                float[] embeddings = check getEmbedding(chunk.content);

                // Store in vector store
                _ = check addVectorEntry(
                        embeddings,
                        chunk.metadata.webViewLink ?: "",
                        metadata,
                        driveCollectionName
                );

            }
            log:printInfo(`Chunks processed from file: ${metadata.fileId}`);
            // Update result record
            result.success = true;
            results.push(result);
        }

        log:printInfo("Documents processed successfully");

        string token = check driveClient->getStartPageToken();
        int saveTokenResult = check saveToken(token);
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

        stream<drive:File> documentStream = check retriveUpdatedDocuments(["attendees", "Invited"]);
        log:printInfo("Documents retrieved from Google Drive");

        // Declare a variable to hold the results
        ProcessingResult[] results = [];

        // db:Token lastToken = check getToken();
        // stream<drive:Change> changes = check driveClient->listChanges(lastToken.token);

        // drive:Change[] changesList = from drive:Change ch in changes
        //     select ch;
        drive:File[] changesList = from drive:File ch in documentStream
            select ch;

        io:println("Changes list: ", changesList.toJsonString());

        if changesList.length() == 0 {
            log:printInfo("No changes found in Google Drive");
            return {message: "No changes found"};
        }

        foreach drive:File ch in changesList {
            io:println("Changed file id: ", ch.id);
            DocumentMetadata metadata = {
                fileId: ch.id ?: ""
            };
            if (ch.trashed == true) {
                // Handle file removal
                int deletedCount = check deleteExistingVectors(metadata, driveCollectionName);
                log:printInfo(`Deleted vectors for removed file: ${ch.id} count: ${deletedCount}`);
            } else {
                // Extract metadata
                log:printInfo(`Extracting metadata from file: ${ch.id}`);
                DocumentMetadata fileMetadata = check extractMetadata(ch.id ?: "");
                log:printInfo(`Metadata extracted from file: ${metadata.fileId}`);

                if fileMetadata.mimeType != "application/vnd.google-apps.document" {
                    log:printInfo(`Skipping file: ${fileMetadata.fileId} as it is not a Google Doc`);
                    continue;
                }

                // Initialize result record
                ProcessingResult result = {
                    fileId: fileMetadata.fileId,
                    fileName: fileMetadata.fileName ?: "",
                    fileLink: fileMetadata.webViewLink ?: "",
                    success: false,
                    errorMessage: ()
                };

                // Extract file content
                log:printInfo(`Extracting content from file: ${fileMetadata.fileId}`);
                string extractedContent = check extractContent(fileMetadata.fileId, fileMetadata.fileName ?: "");
                log:printInfo(`Content extracted from file: ${fileMetadata.fileId}`);

                // Chunk the extracted content
                log:printInfo(`Chunking content from file: ${fileMetadata.fileId}`);
                MarkdownChunk[] chunks = chunkMarkdownText(extractedContent, fileMetadata, maxTokens = 400, overlapTokens = 50);
                log:printInfo(`Content chunked from file: ${fileMetadata.fileId}`);

                //check vectorstore if the file already exists and delete if it does
                log:printInfo(`Checking for existing vectors for file: ${fileMetadata.fileId}`);
                VectorDataWithId[] existing = check fetchExistingVectors(fileMetadata, driveCollectionName);
                if existing.length() > 0 {
                    int deletedCount = check deleteExistingVectors(fileMetadata, driveCollectionName);
                    log:printInfo(`Deleted ${deletedCount} existing vectors for file: ${fileMetadata.fileId}`);
                }

                // Iterate over each chunk and get embeddings
                log:printInfo(`Processing chunks from file: ${fileMetadata.fileId}`);
                foreach MarkdownChunk chunk in chunks {
                    // Get embeddings for each chunk
                    float[] embeddings = check getEmbedding(chunk.content);

                    // Store in vector store
                    _ = check addVectorEntry(
                                    embeddings,
                            chunk.metadata.webViewLink ?: "",
                            fileMetadata,
                            driveCollectionName
                            );

                }
                log:printInfo(`Chunks processed from file: ${fileMetadata.fileId}`);
                // Update result record
                result.success = true;
                results.push(result);
            }
        }

        // Update the last token
        string token = check driveClient->getStartPageToken();
        string updatedToken = check updateToken(token);
        log:printInfo(`Token updated successfully: ${updatedToken}`);

        // Create a response object
        json response = {
            message: "Documents processed successfully",
            results: results
        };

        // Return the response
        return response;
    }
}

//temporary function to get the start page token
service /changes on httpDefaultListener {

    resource function get list() returns error|json {
        time:Utc utc = time:utcNow();
        time:Civil civil = time:utcToCivil(utc);

        time:Zone systemZone = check new time:TimeZone();
        time:Utc utcToCivil = check systemZone.utcFromCivil(civil);
        io:println("Current UTC to Civil time: ", time:utcToString(utcToCivil));

        return {};
    }

    resource function get token() returns error|json {
        do {
            string token = check driveClient->getStartPageToken();
            // handle error
            return token;
        } on fail error err {
            // handle error
            return error("unhandled error", err);
        }
    }
}

