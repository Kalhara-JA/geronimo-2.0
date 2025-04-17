// Copyright (c) 2024, WSO2 LLC. (http://www.wso2.org) All Rights Reserved.

import ballerina/http;
import ballerinax/googleapis.drive as drive;

listener http:Listener httpDefaultListener = http:getDefaultListener();

service /vectorize on httpDefaultListener {

    resource function post init() returns error|json {

        // Retrieve all documents from Google Drive
        stream<drive:File> documentStream = check retrieveAllDocuments();

        // Declare a variable to hold the results
        ProcessingResult[] results = [];

        // Iterate over each file in the stream
        foreach drive:File driveFile in documentStream {

            // Extract metadata
            DocumentMetadata metadata = check extractMetadata(driveFile);

            // Initialize result record
            ProcessingResult result = {
                fileId: metadata.fileId,
                fileName: metadata.fileName,
                fileLink: metadata.webViewLink,
                success: false,
                errorMessage: ()
            };

            // Extract file content
            string extractedContent = check extractContent(metadata.fileId, metadata.fileName);

            // Chunk the extracted content
            MarkdownChunk[] chunks = chunkMarkdownText(extractedContent, metadata, maxTokens = 400, overlapTokens = 50);

            // Iterate over each chunk and get embeddings
            foreach MarkdownChunk chunk in chunks {
                // Get embeddings for each chunk
                float[] embeddings = check getEmbedding(chunk.content);

                // Store in vector store
                _ = check vectorStore.addVector({
                    embedding: embeddings,
                    document: chunk.metadata.webViewLink,
                    metadata
                }, chunk.metadata.fileId);

            }
            // Update result record
            result.success = true;
        }

        // Create a response object
        json response = {
            message: "Documents processed successfully",
            results: results
        };

        // Return the response
        return response;
    }
}
