// Copyright (c) 2024, WSO2 LLC. (http://www.wso2.org) All Rights Reserved.

import ballerina/io;
import ballerinax/googleapis.drive as drive;

# Main function to execute the document processing pipeline
# + return - Error if processing fails
public function main() returns error? {
    // Retrieve all documents from Google Drive
    stream<drive:File> documentStream = check retrieveAllDocuments();

    // Process each document and collect results
    ProcessingResult[] results = [];
    from drive:File driveFile in documentStream
    do {
        io:println("Processing file: ", driveFile);
        //process each file
        ProcessingResult|error result = processDocument(driveFile);
        if (result is error) {
            io:println("Error processing file: ", driveFile.name, " Error: ", result);
            return result;
        }
        results.push(result);
    };

    // Print processing results
    foreach ProcessingResult result in results {
        if result.success {
            io:println("Successfully processed: ", result.fileName);
        } else {
            io:println("Failed to process: ", result.fileName, " Error: ", result.errorMessage);
        }
    }
}
