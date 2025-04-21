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
        stream<drive:File> documentStream = check retrieveAllDocuments();
        log:printInfo("Documents retrieved from Google Drive");

        // Declare a variable to hold the results
        ProcessingResult[] results = [];

        // Iterate over each file in the stream
        log:printInfo("Processing documents from Google Drive");
        foreach drive:File driveFile in documentStream {

            // Extract metadata
            log:printInfo(`Extracting metadata from file: ${driveFile.id}`);
            DocumentMetadata metadata = check extractMetadata(driveFile);
            log:printInfo(`Metadata extracted from file: ${metadata.fileId}`);

            // Initialize result record
            ProcessingResult result = {
                fileId: metadata.fileId,
                fileName: metadata.fileName,
                fileLink: metadata.webViewLink,
                success: false,
                errorMessage: ()
            };

            // Extract file content
            log:printInfo(`Extracting content from file: ${metadata.fileId}`);
            string extractedContent = check extractContent(metadata.fileId, metadata.fileName);
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
                        chunk.metadata.webViewLink,
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

        // Create a response object
        json response = {
            message: "Documents processed successfully",
            results: results
        };

        // Return the response
        return response;
    }
}

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

