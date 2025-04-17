// Copyright (c) 2024, WSO2 LLC. (http://www.wso2.org) All Rights Reserved.

// Records and types used in the Google Drive document processing pipeline

// Represents metadata of a document extracted from Google Drive
# Description.
#
# + fileId - field description
# + fileName - field description
# + mimeType - field description
# + createdTime - field description
# + webViewLink - field description
# + size - field description
public type DocumentMetadata record {|
    // Unique identifier of the file in Google Drive
    string fileId;
    // Name of the file
    string fileName;
    // MIME type of the file
    string mimeType;
    // Creation timestamp of the file
    string createdTime;
    // Web view link to access the file
    string webViewLink;
    // Size of the file in bytes
    int size?;
|};

// Represents a chunk of text from a document with metadata
type DocumentChunk record {|
    // Unique identifier for the chunk
    string chunkId;
    // Text content of the chunk
    string content;
    // Starting index of the chunk in the original text
    int startIndex;
    // Ending index of the chunk in the original text
    int endIndex;
    // Size of overlap with the next chunk
    int overlapSize;
|};

// Represents the result of processing a document
public type ProcessingResult record {|
    // ID of the processed file
    string fileId;
    // Name of the processed file
    string fileName;
    //WebViewLink
    string fileLink;
    // Whether the processing was successful
    boolean success;
    // Error message if processing failed
    string? errorMessage;
|};

// Represents a section in the markdown document
public type MarkdownSection record {|
    // Heading level (1-6, null if no heading)
    int? headingLevel;
    // Heading text
    string headingText;
    // Content lines in the section
    string[] contentLines;
|};

// Represents a chunk of markdown content
public type MarkdownChunk record {|
    // Heading text of the section
    string heading;
    // Heading level (1-6, null if no heading)
    int? headingLevel;
    // Content of the chunk
    string content;
    // Additional metadata
    DocumentMetadata metadata;
|};

# Represents an embedding response from the Azure OpenAI API
#
# + data - field description
type EmbeddingResponse record {
    EmebeddingData[] data;
};

# Represents the data structure for embedding response
#
# + index - field description
# + embedding - field description
type EmebeddingData record {
    int index;
    float[] embedding;
};
