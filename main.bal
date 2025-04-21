// Copyright (c) 2024, WSO2 LLC. (http://www.wso2.org) All Rights Reserved.

import ballerina/http;
import ballerina/io;
import ballerina/log;
import ballerinax/googleapis.drive as drive;

listener http:Listener httpDefaultListener = http:getDefaultListener();

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
        do {

            // Declare a variable to hold the results
            ProcessingResult[] results = [];

            string lastToken = check getToken();

            stream<drive:Change> changes = check driveClient->listChanges(lastToken);

            drive:Change[] changesList = from drive:Change ch in changes
                select ch;

            if changesList.length() == 0 {
                log:printInfo("No changes found in Google Drive");
                return {message: "No changes found"};
            }

            foreach drive:Change ch in changesList {
                DocumentMetadata metadata = {
                    fileId: ch.fileId ?: ""
                };
                if (ch.removed == true) {
                    // Handle file removal
                    int deletedCount = check deleteExistingVectors(metadata, driveCollectionName);
                    log:printInfo(`Deleted vectors for removed file: ${ch.fileId} count: ${deletedCount}`);
                } else {
                    // Extract metadata
                    log:printInfo(`Extracting metadata from file: ${ch.fileId}`);
                    DocumentMetadata fileMetadata = check extractMetadata(ch.fileId ?: "");
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

}

//temporary function to get the start page token
service /changes on httpDefaultListener {

    resource function get list(string pageToken) returns error|json {
        do {
            io:println("Listing changes from Google Drive", pageToken);
            stream<drive:Change> changes = check driveClient->listChanges(pageToken);

            foreach drive:Change ch in changes {

                io:println("Changed file id: ", ch.fileId, " removed: ", ch.removed);
            }

        } on fail error err {
            // handle error
            return error(err.message(), err);
        }
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

