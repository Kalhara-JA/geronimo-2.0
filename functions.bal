// Copyright (c) 2024, WSO2 LLC. (http://www.wso2.org) All Rights Reserved.

import geronimo_2_0.db;

import ballerina/io;
import ballerina/regex;
import ballerina/time;
import ballerinax/googleapis.drive as drive;

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

public function retriveUpdatedDocuments(string[] searchTerms) returns stream<drive:File>|error {
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

# Processes a single Google Drive document(Temporary for testing)
# + driveFile - Google Drive file to process
# + return - Processing result containing success status and error details if any
public function processDocument(drive:File driveFile) returns ProcessingResult|error {
    io:println("Processing file: ", driveFile);
    string fileId = driveFile.id ?: "";
    string fileName = driveFile.name ?: "";

    // Initialize result record
    ProcessingResult result = {
        fileId: fileId,
        fileName: fileName,
        fileLink: driveFile.webViewLink ?: "",
        success: false,
        errorMessage: ()
    };

    do {
        // Extract metadata
        DocumentMetadata metadata = check extractMetadata(driveFile.id ?: "");
        io:println("File Metadata: ", metadata);

        // Extract and save content
        string extractedContent = check extractContent(fileId, fileName);

        // Chunk the extracted content
        // Define chunking parameters
        MarkdownChunk[] chunks = chunkMarkdownText(extractedContent, metadata, maxTokens = 400, overlapTokens = 50);

        // Save chunks to file(temporary)
        string chunkFilePath = string `markdown_files/${fileName}_chunks.md`;
        string chunkContent = "";
        foreach MarkdownChunk chunk in chunks {
            chunkContent += string `## ${chunk.heading} (Level: ${chunk.headingLevel ?: 0})\n${chunk.content}\n\n${chunk.metadata.toString()}\n\n `;
        }
        do {
            check io:fileWriteString(chunkFilePath, chunkContent);
        } on fail var e {
            result.errorMessage = e.message();
            return result;
        }
        io:println("Saved chunks to: ", chunkFilePath);

        // Get embeddings for each chunk
        foreach MarkdownChunk chunk in chunks {
            float[] embeddings = check getEmbedding(chunk.content);
            // Save the embedding to the database (not implemented here)
            io:println("Chunk Index: ", chunk.chunkIndex);
            _ = check vectorStore.addVector({
                            embedding: embeddings,
                            document: chunk.content,
                            metadata: chunk
                            }, driveCollectionName);

        }

        result.success = true;
    }

on fail var e {
        result.errorMessage = e.message();
    }

    return result;

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
        heading: chunk.heading,
        headingLevel: chunk.headingLevel,
        metadata: chunk.metadata,
        chunkIndex: chunk.chunkIndex
    };

    return vectorStore.addVector({
            embedding: embedding,
            document: chunk.content,
            metadata: chunkMetadata
    }, collectionName);
}

# Description.
#
# + token - parameter description
# + return - return value description
public function saveToken(string token) returns int|error {
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
    io:println("Token: ", token?.token);
    io:println("Token ID: ", token?.id);
    io:println("Token Created At: ", token?.createdAt);
    io:println("Token Updated At: ", token?.updatedAt);
    io:println("Token Updated At (UTC): ", time:utcToString(token?.updatedAt));
    io:println("Token Created At (UTC): ", time:utcToString(token.createdAt ?: time:utcNow()));

    time:Zone systemZone = check new time:TimeZone();
    time:Civil utcCivil = systemZone.utcToCivil(token?.updatedAt);
    io:println("Token Updated At (Civil): ", utcCivil);
    io:println("Token Updated At (UTC): ", time:civilToString(utcCivil));

    return token;
}

# Description.
#
# + token - parameter description
# + return - return value description
public function updateToken(string token) returns string|error {
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
