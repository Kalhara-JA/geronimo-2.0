// Copyright (c) 2024, WSO2 LLC. (http://www.wso2.org) All Rights Reserved.

import geronimo_2_0.db;

import ballerina/io;
import ballerina/lang.value;
import ballerina/log;
import ballerina/regex;
import ballerina/time;
import ballerinax/googleapis.drive as drive;

// function withRetry(function () returns error|json operation, int maxAttempts) returns error|json {
//     int attempt = 0;
//     while attempt < maxAttempts {
//         error|json result = operation();
//         if (result is json) {
//             return result;
//         } else {
//             log:printError("Operation failed, retrying...", result);
//             attempt += 1;
//             time:sleep(time:Seconds(2));
//         }
//     }
//     return error("Max attempts reached");
// }

# Retrieves all documents from Google Drive based on specific criteria
#
# + searchTerms - parameter description
# + return - Stream of Google Drive files or error if retrieval fails
public function retrieveAllDocuments(string[] searchTerms) returns stream<drive:File>|error {
    string folderId = "1QtYURKBwGsJHoyBh5dLXOZ1ifYXODuTq";
    string mimeType = "application/vnd.google-apps.document";

    // Build the fullText filter using 'or' between each term
    string[] searchFilters = searchTerms.map(term => "fullText contains '" + term + "'");
    string searchFilter = string `${string:'join(" or ", ...searchFilters)}`;

    // Final filter string with folder and mime type constraints
    string filterString = "'" + folderId + "' in parents and " + searchFilter + " and mimeType = '" + mimeType + "'";
    io:println("Filter String: ", filterString);

    return driveClient->getAllFiles(filterString);
}

public function retrieveUpdatedDocuments(string[] searchTerms) returns stream<drive:File>|error {
    string folderId = "1QtYURKBwGsJHoyBh5dLXOZ1ifYXODuTq";
    string mimeType = "application/vnd.google-apps.document";

    db:Token|error latestToken = check getToken();
    if latestToken is error {
        return error("Failed to retrieve token");
    }
    time:Zone systemZone = check new time:TimeZone();
    time:Civil utcCivil = systemZone.utcToCivil(latestToken?.updatedAt);
    string modifiedAfter = check time:civilToString(utcCivil);
    modifiedAfter = modifiedAfter.substring(0, 19) + "Z";

    // Build the fullText filter using 'or' between each term
    string[] searchFilters = searchTerms.map(term => "fullText contains '" + term + "'");
    string searchFilter = string `${string:'join(" or ", ...searchFilters)}`;

    // Add the filter for modified time
    string timeFilter = "modifiedTime > '" + modifiedAfter + "'";

    // Final filter string with folder, search, mime type, and modified time constraints
    string filterString = "'" + folderId + "' in parents and (" + searchFilter +
                        ") and mimeType = '" + mimeType + "' and " + timeFilter;

    io:println("Filter String: ", filterString);

    return driveClient->getAllFiles(filterString);
}

# Description.
#
# + documentStream - parameter description
# + return - return value description
public function processDocuments(stream<drive:File> documentStream) returns ProcessingResult[]|error {

    log:printInfo("Documents retrieved from Google Drive");

    ProcessingResult[] results = [];
    drive:File[] changesList = from drive:File ch in documentStream
        select ch;

    if changesList.length() == 0 {
        log:printInfo("No changes found in Google Drive");
        return results;
    }

    foreach drive:File ch in changesList {
        io:println("Changed file id: ", ch.id);
        DocumentMetadata metadata = {
                fileId: ch.id ?: ""
            };
        if (ch.trashed == true) {
            // Handle file removal
            int|error deletedCount = deleteExistingVectors(metadata, driveCollectionName);
            if (deletedCount is error) {
                log:printError("Error deleting vectors for removed file", deletedCount);
                return error("Failed to delete vectors for removed file");
            }
            log:printInfo(`Deleted vectors for removed file: ${ch.id} count: ${deletedCount}`);
        } else {
            // Extract metadata
            log:printInfo(`Extracting metadata from file: ${ch.id}`);
            DocumentMetadata|error fileMetadata = extractMetadata(ch.id ?: "");
            if (fileMetadata is error) {
                log:printError("Error extracting metadata", fileMetadata);
                return error("Failed to extract metadata");
            }
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
            string|error extractedContent = extractContent(fileMetadata.fileId, fileMetadata.fileName ?: "");
            if (extractedContent is error) {
                log:printError("Error extracting content", extractedContent);
                return error("Failed to extract content");
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
                log:printError("Error fetching existing vectors", existing);
                return error("Failed to fetch existing vectors");
            }
            if existing.length() > 0 {
                int|error deletedCount = deleteExistingVectors(fileMetadata, driveCollectionName);
                if (deletedCount is error) {
                    log:printError("Error deleting existing vectors", deletedCount);
                    return error("Failed to delete existing vectors");
                }
                log:printInfo(`Deleted ${deletedCount} existing vectors for file: ${fileMetadata.fileId}`);
            }

            // Iterate over each chunk and get embeddings
            log:printInfo(`Processing chunks from file: ${fileMetadata.fileId}`);
            foreach MarkdownChunk chunk in chunks {
                // Get embeddings for each chunk
                float[]|error embeddings = getEmbedding(chunk.content);

                if (embeddings is error) {
                    log:printError("Error getting embeddings", embeddings);
                    return error("Failed to get embeddings");
                }

                // Store in vector store
                VectorDataWithId|error vectors = addVectorEntry(
                                    embeddings,
                        chunk.metadata.webViewLink ?: "",
                        chunk,
                        driveCollectionName
                            );

                if (vectors is error) {
                    log:printError("Error adding vector entry", vectors);
                    return error("Failed to add vector entry");
                }

            }
            log:printInfo(`Chunks processed from file: ${fileMetadata.fileId}`);
            // Update result record
            result.success = true;
            results.push(result);
        }
    }
    // Return the results
    if results.length() > 0 {
        return results;
    } else {
        return error("No results found");
    }
}

# extracts metadata from a Google Drive file
# + fileId - ID of the file to extract metadata from
# + return - DocumentMetadata record or error if extraction fails
public function extractMetadata(string fileId) returns DocumentMetadata|error {
    // Extract metadata from the drive file
    drive:File|error file = check driveClient->getFile(fileId, fields = "id,name,mimeType,createdTime,webViewLink");
    if (file is error) {
        return error("Failed to retrieve file: " + fileId);
    }

    // Define metadata record
    DocumentMetadata metadata = {
        fileId: file.id ?: "",
        fileName: file.name ?: "",
        mimeType: file.mimeType ?: "",
        createdTime: file.createdTime ?: "",
        webViewLink: file.webViewLink ?: ""
    };

    return metadata;
}

# Extracts content from a Google Drive file and saves it as markdown
# + fileId - ID of the file to extract content from
# + fileName - Name of the file to save content as
# + return - File content or error if extraction fails
public function extractContent(string fileId, string fileName) returns string|error {
    io:println("Extracting content for file ID: ", fileId);

    // Export file as markdown
    drive:FileContent content = check driveClient->exportFile(fileId, mimeType = "text/markdown");

    // Convert content to string
    string contentString = check string:fromBytes(content.content);

    // Define output file path
    string filePath = string `markdown_files/${fileName}.md`;

    // Save content to file
    check io:fileWriteString(filePath, contentString);

    io:println("Saved markdown content to: ", filePath);
    io:println(" ----- ");

    return contentString;
}

# Splits a Markdown string by headings and chunks each section
# + markdownText - The full Markdown document as a string
# + metadata - Metadata for the document
# + maxTokens - Maximum number of words allowed in each chunk
# + overlapTokens - Number of words to overlap between chunks
# + return - Array of MarkdownChunk records
public function chunkMarkdownText(string markdownText, DocumentMetadata metadata, int maxTokens = 400, int overlapTokens = 50) returns MarkdownChunk[] {
    // Split the input text into lines
    string[] lines = regex:split(markdownText, "\n");

    // Gather sections by headings
    MarkdownSection[] sections = gatherSections(lines);

    // Process each section into chunks
    MarkdownChunk[] allChunks = [];
    foreach MarkdownSection section in sections {
        // Join content lines and split into paragraphs
        string fullText = string:'join("\n", ...section.contentLines);
        string[] rawParagraphs = regex:split(fullText, "\n\n");

        // Filter and trim paragraphs
        string[] paragraphs = [];
        foreach string para in rawParagraphs {
            string trimmedPara = para.trim();
            if trimmedPara != "" {
                paragraphs.push(trimmedPara);
            }
        }

        // Create sub-chunks for this section
        MarkdownChunk[] subChunks = createSubChunks(
                metadata,
                paragraphs,
                section.headingText,
                section.headingLevel,
                maxTokens,
                overlapTokens
        );

        allChunks.push(...subChunks);
    }

    //assign chunkIndexes
    int chunkIndex = 0;
    foreach MarkdownChunk chunk in allChunks {
        chunk.chunkIndex = chunkIndex;
        chunkIndex += 1;
    }

    return allChunks;
}

# Gathers sections from markdown lines
# + lines - Array of markdown lines
# + return - Array of MarkdownSection records
function gatherSections(string[] lines) returns MarkdownSection[] {
    MarkdownSection[] sections = [];
    MarkdownSection currentSection = {
        headingLevel: (),
        headingText: "Preamble",
        contentLines: []
    };

    foreach string line in lines {
        [boolean, int, string] headingInfo = extractHeading(line);
        boolean isHeading = headingInfo[0];

        if isHeading {
            // Store current section if it has content
            if currentSection.contentLines.length() > 0 {
                sections.push(currentSection);
            }

            // Start new section
            currentSection = {
                headingLevel: headingInfo[1],
                headingText: headingInfo[2],
                contentLines: []
            };
        } else {
            currentSection.contentLines.push(line);
        }
    }

    // Add the last section if it has content
    if currentSection.contentLines.length() > 0 {
        sections.push(currentSection);
    }

    return sections;
}

# Creates sub-chunks from paragraphs
# + metadata - Document metadata
# + paragraphs - Array of paragraph strings
# + headingText - Heading text for the section
# + headingLevel - Heading level
# + maxTokens - Maximum tokens per chunk
# + overlapTokens - Number of tokens to overlap
# + return - Array of MarkdownChunk records
function createSubChunks(DocumentMetadata metadata, string[] paragraphs, string headingText, int? headingLevel, int maxTokens, int overlapTokens) returns MarkdownChunk[] {
    MarkdownChunk[] chunks = [];
    string[] currentWords = [];
    int currentWordCount = 0;
    int chunkIndex = 0;

    foreach string paragraph in paragraphs {
        string[] paragraphWords = regex:split(paragraph, "\\s+");
        int paragraphLen = paragraphWords.length();

        if (currentWordCount + paragraphLen) > maxTokens {
            // Finalize current chunk
            string chunkText = string:'join(" ", ...currentWords).trim();
            if chunkText != "" {
                chunks.push({
                    heading: headingText,
                    headingLevel: headingLevel,
                    content: chunkText,
                    metadata,
                    chunkIndex: chunkIndex
                });
                chunkIndex += 1;
            }

            // Start new chunk with overlap
            string[] overlapSlice = [];
            if overlapTokens > 0 && currentWords.length() > overlapTokens {
                int startIdx = currentWords.length() - overlapTokens;
                overlapSlice = currentWords.slice(startIdx);
            }

            currentWords = [...overlapSlice, ...paragraphWords];
            currentWordCount = currentWords.length();
        } else {
            currentWords.push(...paragraphWords);
            currentWordCount += paragraphLen;
        }
    }

    // Add final chunk if anything remains
    if currentWords.length() > 0 {
        string finalChunkText = string:'join(" ", ...currentWords).trim();
        chunks.push({
            heading: headingText,
            headingLevel: headingLevel,
            content: finalChunkText,
            metadata,
            chunkIndex: chunkIndex
        });
    }

    return chunks;
}

# Extracts heading information from a line
# + line - Input line
# + return - Tuple of [isHeading, headingLevel, headingText]
function extractHeading(string line) returns [boolean, int, string] {
    string trimmedLine = line.trim();
    if trimmedLine.startsWith("#") {
        int headingLevel = 0;
        foreach string char in trimmedLine {
            if char != "#" {
                break;
            }
            headingLevel += 1;
        }

        if headingLevel > 0 && headingLevel <= 6 {
            string headingText = trimmedLine.substring(headingLevel).trim();
            return [true, headingLevel, headingText];
        }
    }
    return [false, 0, ""];
}

# Retrieves embeddings for a given text chunk
# + chunk - Text chunk to get embeddings for
# + return - Array of float embeddings or error if retrieval fails
function getEmbedding(string chunk) returns float[]|error {
    EmbeddingResponse response = check embeddings->post(
        string `/deployments/${azureOpenaiEmbeddingName}/embeddings?api-version=${azureOpenaiApiVersion}`,
        {"input": chunk},
        {"api-key": azureOpenaiApiKey}
    );
    return response.data[0].embedding;
}

# Fetch existing vectors based on metadata
#
# + metadata - parameter description
# + collectionName - parameter description
# + return - return value description
public function fetchExistingVectors(DocumentMetadata metadata, string collectionName)
    returns VectorDataWithId[]|error
{
    return vectorStore.fetchVectorByMetadata(metadata, collectionName);
}

# Delete existing vectors based on metadata
#
# + metadata - parameter description
# + collectionName - parameter description
# + return - return value description
public function deleteExistingVectors(DocumentMetadata metadata, string collectionName)
    returns int|error
{
    return vectorStore.deleteVectorsByMetadata(metadata, collectionName);
}

/// Recursively sanitizes any json object to make it safe for PostgreSQL JSON column.
public function sanitizeJson(json input) returns json|error {
    if input is string {
        // Remove invalid backslashes (e.g., \-, \a) and control characters
        string:RegExp regex1 = re `\\(.)`;
        string cleaned = regex1.replaceAll(input, "");

        // Try to parse stringified JSON inside a string field (e.g. metadata = "{\"fileId\":\"abc\"}")
        json|error parsed = value:fromJsonString(cleaned);
        if parsed is map<json> || parsed is json[] {
            return sanitizeJson(parsed); // Recursively clean parsed structure
        }
        return cleaned;
    } else if input is map<json> {
        map<json> result = {};
        foreach var [k, v] in input.entries() {
            result[k] = check sanitizeJson(v);
        }
        return result;
    } else if input is json[] {
        json[] result = [];
        foreach json item in input {
            result.push(check sanitizeJson(item));
        }
        return result;
    } else if input is float {
        // Remove NaN or Infinity — fallback to null or 0
        if input == 1.0 / 0.0 || input == -1.0 / 0.0 || input != input {
            return null;
        }
        return input;
    }

    return input;
}

/// Sanitizes any map<json> metadata to ensure it's safely JSON-parsable and PostgreSQL-compatible.
///
/// + rawMetadata - The raw metadata map (possibly with nested records or strings)
/// + return - A clean `map<json>` ready for insertion
public function sanitizeMetadata(map<json> rawMetadata) returns map<json>|error {
    json cleaned = check sanitizeJson(rawMetadata);
    map<json> parsedMap = check cleaned.cloneWithType();
    return parsedMap;
}

# Add a vector entry to the vector store
#
# + embedding - parameter description
# + documentLink - parameter description
# + chunk - parameter description
# + collectionName - parameter description
# + return - return value description
public function addVectorEntry(float[] embedding, string documentLink, MarkdownChunk chunk,
        string collectionName)
    returns VectorDataWithId|error
    {
    map<json> chunkMetadata = {
        heading: chunk.heading.toString(),
        headingLevel: chunk.headingLevel,
        metadata: chunk.metadata,
        chunkIndex: chunk.chunkIndex
    };

    io:println("Chunk Metadata: ", chunkMetadata);

    return vectorStore.addVector({
            embedding: embedding,
            document: chunk.content,
            metadata: check sanitizeMetadata(chunkMetadata)
    }, collectionName);
}

# Description.
# + return - return value description
public function saveInitialToken() returns int|error {

    string token = check driveClient->getStartPageToken();

    db:TokenInsert tokenInsert = {
        token: token,
        createdAt: time:utcNow(),
        updatedAt: time:utcNow()
    };
    int[] result = check dbClient->/tokens.post(
        [tokenInsert, tokenInsert]
    );
    if result.length() > 0 {
        return result[0];
    } else {
        return error("Failed to save token");
    }
}

# Description.
# + return - return value description
public function getToken() returns db:Token|error {
    int id = 2;
    db:Token|error token = check dbClient->/tokens/[id].get();
    if token is error {
        return error("Failed to retrieve token");
    }
    return token;
}

# Description.
#
# + token - parameter description
# + return - return value description
public function updateToken() returns string|error {

    string token = check driveClient->getStartPageToken();

    int latestTokenId = 2;
    int previousTokenId = 1;

    db:Token existingToken = check dbClient->/tokens/[latestTokenId].get();

    db:TokenUpdate previousToken = {
        token: existingToken.token,
        updatedAt: time:utcNow()
    };

    io:println("Previous token: ", time:utcToString(time:utcNow()));

    db:Token _ = check dbClient->/tokens/[previousTokenId].put(previousToken);

    db:TokenUpdate latestToken = {
        token: token,
        updatedAt: time:utcNow()
    };

    io:println("Latest token: ", latestToken?.updatedAt);
    db:Token updatedLatestToken = check dbClient->/tokens/[latestTokenId].put(latestToken);

    return updatedLatestToken.token;
}
