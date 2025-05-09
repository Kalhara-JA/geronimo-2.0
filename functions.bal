import geronimo_2_0.db;

import ballerina/lang.runtime;
import ballerina/lang.value;
import ballerina/log;
import ballerina/persist;
import ballerina/regex;
import ballerina/time;
import ballerinax/googleapis.drive as drive;

const int LATEST_TOKEN_ID = 2;
const int MAX_TOKENS = 400;
const int OVERLAP_TOKENS = 50;

public const string STATUS_PROCESSING = "processing";
public const string STATUS_SUCCESS = "success";
public const string STATUS_ERROR = "error";

public const int EMBEDDING_BATCH_SIZE = 100;

# Processes a stream of Google Drive files, extracting content, chunking, embedding, and storing vectors.
#
# + documentStream - Stream of Google Drive files to process.
# + force - Flag to force processing even if already processed.
# + return - Array of ProcessingResult for each processed file, or error if processing fails.
public function processDocuments(stream<drive:File> documentStream, boolean force) returns ProcessingResult[]|error {
    log:printInfo("processDocuments: Start processing document stream");

    ProcessingResult[] results = [];
    // drive:File? file = documentStream.next();
    int count = 0;
    foreach drive:File file in documentStream {
        count += 1;
        ProcessingResult|error res = processSingleDocument(file, force);
        if res is error {
            check markProcessingError(file.id ?: "", res.message());
            results.push({
                fileId: file.id ?: "",
                fileName: file.name ?: "",
                fileLink: file.webViewLink ?: "",
                success: false,
                errorMessage: res.message()
            });
        } else {
            results.push(res);
        }
        // file = documentStream.next();
    }
    log:printDebug(`processDocuments: Retrieved ${count} files from stream`);
    if results.length() > 0 {
        log:printInfo(`processDocuments: Finished with ${results.length()} successful results`);
        return results;
    } else {
        log:printWarn("processDocuments: No results were successfully processed");
        return error("No results found");
    }
}

# Processes a single Google Drive file, extracting content, chunking, embedding, and storing vectors.
#
# + ch - Google Drive file to process.
# + force - Flag to force processing even if already processed.
# + return - ProcessingResult for the processed file, or error if processing fails.
public function processSingleDocument(drive:File ch, boolean force) returns ProcessingResult|error {
    DocumentMetadata metadata = {fileId: ch.id ?: ""};
    log:printInfo(`processSingleDocument: Handling file ${metadata.fileId}`);

    db:FileProcessingStatus|()|error prev = getFileStatus(metadata.fileId);
    if !force && prev is db:FileProcessingStatus && prev.status == STATUS_SUCCESS {
        log:printInfo(`processSingleDocument: File ${metadata.fileId} has already been processed successfully`);
        return {
            fileId: metadata.fileId,
            fileName: ch.name ?: "",
            fileLink: ch.webViewLink ?: "",
            success: true,
            errorMessage: ()
        };
    }

    check markProcessingStart(metadata.fileId);

    if ch.trashed == true {
        log:printWarn(`processSingleDocument: File ${metadata.fileId} is trashed. Deleting vectors.`);
        int|error deletedCount = deleteExistingVectors(metadata, driveCollectionName);
        if deletedCount is error {
            log:printError(`processSingleDocument: Error deleting vectors for removed file ${metadata.fileId}`);
            return error("Failed to delete vectors for removed file");
        }
        log:printInfo(`processSingleDocument: Deleted ${deletedCount} vectors for removed file ${metadata.fileId}`);
        return {
            fileId: metadata.fileId,
            fileName: ch.name ?: "",
            fileLink: ch.webViewLink ?: "",
            success: true,
            errorMessage: ()
        };
    } else {
        log:printInfo(`processSingleDocument: Extracting metadata for file ${metadata.fileId}`);
        DocumentMetadata|error fileMetadata = extractMetadata(metadata.fileId);
        if fileMetadata is error {
            log:printError(`processSingleDocument: Error extracting metadata for file ${metadata.fileId}`);
            return error("Failed to extract metadata");
        }
        log:printDebug(`processSingleDocument: Metadata: ${fileMetadata.toJsonString()}`);

        ProcessingResult result = {
            fileId: fileMetadata.fileId,
            fileName: fileMetadata.fileName ?: "",
            fileLink: fileMetadata.webViewLink ?: "",
            success: false,
            errorMessage: ()
        };

        if fileMetadata.mimeType != mimeType {
            log:printInfo(`processSingleDocument: Skipping non-Google-Doc file ${fileMetadata.fileId}`);
            return error("File is not a Google Doc");
        }

        log:printInfo(`processSingleDocument: Extracting content for file ${fileMetadata.fileId}`);
        string|error extractedContent = extractContent(fileMetadata.fileId, fileMetadata.fileName ?: "");
        if extractedContent is error {
            log:printError(`processSingleDocument: Error extracting content for file ${fileMetadata.fileId}`);
            return error("Failed to extract content");
        }
        log:printDebug(`processSingleDocument: Extracted content length ${extractedContent.length()} for file ${fileMetadata.fileId}`);
        log:printInfo(`processSingleDocument: Chunking content for file ${fileMetadata.fileId}`);
        MarkdownChunk[] chunks = chunkMarkdownText(extractedContent, fileMetadata, MAX_TOKENS, OVERLAP_TOKENS);
        log:printInfo(`processSingleDocument: Created ${chunks.length()} chunks for file ${fileMetadata.fileId}`);

        string[] contents = [];
        foreach MarkdownChunk chunk in chunks {
            contents.push(chunk.content);
        }

        log:printInfo(`processSingleDocument: Retrieving embeddings for file ${fileMetadata.fileId}`);
        float[][]|error allEmbeddings = getEmbeddingsBatched(contents);
        if allEmbeddings is error {
            log:printError(`processSingleDocument: Error getting embeddings for file ${fileMetadata.fileId}`);
            return error("Failed to get embeddings");
        }
        log:printInfo(`processSingleDocument: Embeddings retrieved for file ${fileMetadata.fileId}`);

        log:printInfo(`processSingleDocument: Fetching existing vectors for file ${fileMetadata.fileId}`);
        VectorDataWithId[]|error existing = fetchExistingVectors(fileMetadata, driveCollectionName);
        if existing is error {
            log:printError(`processSingleDocument: Error fetching existing vectors for file ${fileMetadata.fileId}`);
            return error("Failed to fetch existing vectors");
        }

        if existing.length() > 0 {
            log:printWarn(`processSingleDocument: Found ${existing.length()} existing vectors. Deleting.`);
            int|error deletedCount2 = deleteExistingVectors(fileMetadata, driveCollectionName);
            if deletedCount2 is error {
                log:printError(`processSingleDocument: Error deleting existing vectors for file ${fileMetadata.fileId}`);
                return error("Failed to delete existing vectors");
            }
            log:printInfo(`processSingleDocument: Deleted ${deletedCount2} existing vectors for file ${fileMetadata.fileId}`);
        }

        foreach MarkdownChunk chunk in chunks {
            VectorDataWithId|error vectors = addVectorEntry(
                    allEmbeddings[chunk.chunkIndex],
                    chunk.metadata.webViewLink ?: "",
                    chunk,
                    driveCollectionName
            );
            if vectors is error {
                log:printError(`processSingleDocument: Error adding vector for chunk ${chunk.chunkIndex} of file ${fileMetadata.fileId}`);
                return error("Failed to add vector entry");
            }
        }

        log:printInfo(`processSingleDocument: Completed processing file ${fileMetadata.fileId}`);

        result.success = true;
        check markProcessingSuccess(fileMetadata.fileId);
        return result;
    }
}

# Retrieves all Google Drive documents matching the given search terms.
#
# + searchTerms - Array of search terms to filter documents.
# + return - Stream of Google Drive files matching the search criteria, or error.
public function retrieveAllDocuments(string[] searchTerms) returns stream<drive:File>|error {
    log:printInfo(`retrieveAllDocuments: Building search filter for terms ${searchTerms.toString()}`);

    string[] searchFilters = searchTerms.map(term => "fullText contains '" + term + "'");
    string searchFilter = string `${string:'join(" or ", ...searchFilters)}`;
    string filterString = "'" + folderId + "' in parents and " + searchFilter + " and mimeType = '" + mimeType + "'";
    log:printInfo(`retrieveAllDocuments: Filter string: ${filterString}`);

    log:printDebug(`retrieveAllDocuments: Filter string: ${filterString}`);
    return driveClient->getAllFiles(filterString);
}

# Retrieves updated Google Drive documents since the last token, filtered by search terms.
#
# + searchTerms - Array of search terms to filter documents.
# + return - Stream of updated Google Drive files, or error.
public function retrieveUpdatedDocuments(string[] searchTerms) returns stream<drive:File>|error {
    log:printInfo("retrieveUpdatedDocuments: Checking token for updated documents");
    db:Token|error latestToken = getToken();
    if latestToken is error {
        log:printError("retrieveUpdatedDocuments: Failed to retrieve token");
        return error("Failed to retrieve token");
    }
    time:Zone systemZone = check new time:TimeZone();
    time:Civil utcCivil = systemZone.utcToCivil(latestToken.updatedAt);
    string modifiedAfter = check time:civilToString(utcCivil);
    modifiedAfter = modifiedAfter.substring(0, 19) + "Z";
    log:printDebug(`retrieveUpdatedDocuments: Modified after ${modifiedAfter}`);

    string[] searchFilters = searchTerms.map(term => "fullText contains '" + term + "'");
    string searchFilter = string `${string:'join(" or ", ...searchFilters)}`;
    string timeFilter = "modifiedTime > '" + modifiedAfter + "'";
    string filterString = "'" + folderId + "' in parents and (" + searchFilter + ") and mimeType = '" + mimeType + "' and " + timeFilter;

    log:printDebug(`retrieveUpdatedDocuments: Filter string: ${filterString}`);
    return driveClient->getAllFiles(filterString);
}

# Extracts metadata for a given Google Drive file ID.
#
# + fileId - The ID of the file to extract metadata for.
# + return - DocumentMetadata object or error if extraction fails.
public function extractMetadata(string fileId) returns DocumentMetadata|error {
    log:printInfo(`extractMetadata: Retrieving metadata for file ${fileId}`);
    drive:File|error file = driveClient->getFile(fileId, fields = "id,name,mimeType,createdTime,webViewLink");
    if file is error {
        log:printError(`extractMetadata: Failed to retrieve file ${fileId}`);
        return error("Failed to retrieve file: " + fileId);
    }
    DocumentMetadata metadata = {
        fileId: file.id ?: "",
        fileName: file.name ?: "",
        mimeType: file.mimeType ?: "",
        createdTime: file.createdTime ?: "",
        webViewLink: file.webViewLink ?: ""
    };
    log:printDebug(`extractMetadata: Metadata object ${metadata.toJsonString()}`);
    return metadata;
}

# Extracts the content of a Google Drive file as markdown.
#
# + fileId - The ID of the file to extract content from.
# + fileName - The name of the file (for logging/debugging).
# + return - Extracted markdown content as string, or error.
public function extractContent(string fileId, string fileName) returns string|error {
    log:printInfo(`extractContent: Exporting file ${fileId} as markdown`);
    drive:FileContent|error content = driveClient->exportFile(fileId, mimeType = "text/markdown");
    if content is error {
        log:printError(`extractContent: Failed export for file ${fileId}`);
        return error("Failed to extract content");
    }
    string contentString = check string:fromBytes(content.content);
    log:printDebug(`extractContent: Extracted content length ${contentString.length()}`);
    return contentString;
}

# Chunks markdown text into smaller sections for embedding.
#
# + markdownText - The markdown text to chunk.
# + metadata - Metadata of the document.
# + maxTokens - Maximum tokens per chunk (default 400).
# + overlapTokens - Number of overlapping tokens between chunks (default 50).
# + return - Array of MarkdownChunk objects.
public function chunkMarkdownText(string markdownText, DocumentMetadata metadata, int maxTokens, int overlapTokens) returns MarkdownChunk[] {
    log:printInfo(`chunkMarkdownText: Starting chunking for file ${metadata.fileId}`);

    string regex1 = "!\\[.*?\\]\\[.*?\\]";
    string regex2 = "\\[image\\d+\\]:\\s*<data:[^>]*>";
    string markdowntext1 = regex:replaceAll(markdownText, regex1, "");
    string markdownText2 = regex:replaceAll(markdowntext1, regex2, "");

    string[] lines = regex:split(markdownText2, "\n");
    MarkdownSection[] sections = gatherSections(lines);
    log:printDebug(`chunkMarkdownText: Found ${sections.length()} sections`);
    MarkdownChunk[] allChunks = [];
    int chunkIndex = 0;
    foreach MarkdownSection section in sections {
        string fullText = string:'join("\n", ...section.contentLines);
        string[] rawParagraphs = regex:split(fullText, "\n\n");
        string[] paragraphs = [];
        foreach string para in rawParagraphs {
            string trimmedPara = para.trim();
            if trimmedPara != "" {
                paragraphs.push(trimmedPara);
            }
        }
        MarkdownChunk[] subChunks = createSubChunks(metadata, paragraphs, section.headingText, section.headingLevel, maxTokens, overlapTokens);
        foreach MarkdownChunk c in subChunks {
            c.chunkIndex = chunkIndex;
            chunkIndex += 1;
        }
        allChunks.push(...subChunks);
    }
    log:printInfo(`chunkMarkdownText: Created ${allChunks.length()} total chunks for file ${metadata.fileId}`);
    return allChunks;
}

# Gathers sections from markdown lines based on headings.
#
# + lines - Array of markdown lines.
# + return - Array of MarkdownSection objects.
function gatherSections(string[] lines) returns MarkdownSection[] {
    log:printDebug(`gatherSections: Scanning ${lines.length()} lines for headings`);
    MarkdownSection[] sections = [];
    MarkdownSection currentSection = {headingLevel: (), headingText: "Preamble", contentLines: []};
    foreach string line in lines {
        [boolean, int, string] headingInfo = extractHeading(line);
        if headingInfo[0] {
            if currentSection.contentLines.length() > 0 {
                sections.push(currentSection);
            }
            currentSection = {headingLevel: headingInfo[1], headingText: headingInfo[2], contentLines: []};
        } else {
            currentSection.contentLines.push(line);
        }
    }
    if currentSection.contentLines.length() > 0 {
        sections.push(currentSection);
    }
    log:printDebug(`gatherSections: Identified ${sections.length()} sections`);
    return sections;
}

# Creates sub-chunks from paragraphs within a section.
#
# + metadata - Document metadata.
# + paragraphs - Array of paragraph strings.
# + headingText - Heading text for the section.
# + headingLevel - Heading level (optional).
# + maxTokens - Maximum tokens per chunk.
# + overlapTokens - Number of overlapping tokens between chunks.
# + return - Array of MarkdownChunk objects.
function createSubChunks(DocumentMetadata metadata, string[] paragraphs, string headingText, int? headingLevel, int maxTokens, int overlapTokens) returns MarkdownChunk[] {
    log:printDebug(`createSubChunks: Chunking section '${headingText}' with ${paragraphs.length()} paragraphs`);
    MarkdownChunk[] chunks = [];
    string[] currentWords = [];
    int currentWordCount = 0;

    foreach string paragraph in paragraphs {
        string[] paragraphWords = regex:split(paragraph, "\\s+");
        int paragraphLen = paragraphWords.length();
        if currentWordCount + paragraphLen > maxTokens {
            string chunkText = string:'join("\n", ...currentWords).trim();
            if chunkText != "" {
                chunks.push({heading: headingText, headingLevel: headingLevel, content: chunkText, metadata: metadata, chunkIndex: 0});
            }
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
    if currentWords.length() > 0 {
        chunks.push({heading: headingText, headingLevel: headingLevel, content: string:'join("\n", ...currentWords).trim(), metadata: metadata, chunkIndex: 0});
    }
    log:printDebug(`createSubChunks: Created ${chunks.length()} subchunks for heading '${headingText}'`);
    return chunks;
}

# Extracts heading information from a markdown line.
#
# + line - The markdown line to check.
# + return - Tuple [isHeading, headingLevel, headingText].
function extractHeading(string line) returns [boolean, int, string] {
    string trimmedLine = line.trim();
    if trimmedLine.startsWith("#") {
        int level = 0;
        foreach string char in trimmedLine {
            if char != "#" {
                break;
            }
            level += 1;
        }
        if level > 0 && level <= 6 {
            string headingText = trimmedLine.substring(level).trim();
            return [true, level, headingText];
        }
    }
    return [false, 0, ""];
}

# Gets embeddings for an array of text chunks.
#
# + chunks - Array of text chunks to embed.
# + return - 2D array of floats representing embeddings, or error.
public function getEmbeddings(string[] chunks) returns float[][]|error {
    log:printInfo(`getEmbeddings: Requesting embeddings for ${chunks.length()} chunks`);
    EmbeddingResponse response = check embeddings->post(string `/deployments/${azureOpenaiEmbeddingName}/embeddings?api-version=${azureOpenaiApiVersion}`, {"input": chunks}, {"api-key": azureOpenaiApiKey});
    float[][] allEmbeddings = [];
    foreach var d in response.data {
        allEmbeddings.push(d.embedding);
    }
    log:printInfo(`getEmbeddings: Received embeddings for ${allEmbeddings.length()} chunks`);
    return allEmbeddings;
}

# Gets embeddings for an array of text chunks in batches.
#
# + allContents - Array of text chunks to embed.
# + return - 2D array of floats representing embeddings, or error.
function getEmbeddingsBatched(string[] allContents)
        returns float[][]|error {

    float[][] embeddings = [];
    int i = 0;
    while i < allContents.length() {
        int end = i + EMBEDDING_BATCH_SIZE < allContents.length() ? i + EMBEDDING_BATCH_SIZE : allContents.length();
        float[][]|error batch = getEmbeddings(allContents.slice(i, end));
        if batch is error {
            return batch;
        }
        embeddings.push(...batch);
        i = end;
        runtime:sleep(1);
    }
    return embeddings;
}

# Fetches existing vectors for a document from the vector store.
#
# + metadata - Document metadata.
# + collectionName - Name of the vector collection.
# + return - Array of VectorDataWithId or error.
public function fetchExistingVectors(DocumentMetadata metadata, string collectionName) returns VectorDataWithId[]|error {
    log:printDebug(`fetchExistingVectors: Fetching vectors for file ${metadata.fileId}`);
    return vectorStore.fetchVectorByMetadata({fileId: metadata.fileId}, collectionName);
}

# Deletes existing vectors for a document from the vector store.
#
# + metadata - Document metadata.
# + collectionName - Name of the vector collection.
# + return - Number of deleted vectors or error.
public function deleteExistingVectors(DocumentMetadata metadata, string collectionName) returns int|error {
    log:printDebug(`deleteExistingVectors: Deleting vectors for file ${metadata.fileId}`);
    int deleted = check vectorStore.deleteVectorsByMetadata({fileId: metadata.fileId}, collectionName);
    log:printInfo(`deleteExistingVectors: Deleted ${deleted} vectors for file ${metadata.fileId}`);
    return deleted;
}

# Sanitizes a JSON value, removing invalid characters and values.
#
# + input - The JSON value to sanitize.
# + return - Sanitized JSON or error.
public function sanitizeJson(json input) returns json|error {
    log:printDebug("sanitizeJson: Sanitizing JSON input");
    if input is string {
        string:RegExp regex1 = re `\\(.)`;
        string cleaned = regex1.replaceAll(input, "");
        json|error parsed = value:fromJsonString(cleaned);
        if parsed is map<json> || parsed is json[] {
            return sanitizeJson(parsed);
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
        if input == 1.0 / 0.0 || input == -1.0 / 0.0 || input != input {
            return null;
        }
        return input;
    }
    return input;
}

# Sanitizes a metadata map by cleaning its JSON values.
#
# + rawMetadata - The raw metadata map.
# + return - Sanitized metadata map or error.
public function sanitizeMetadata(map<json> rawMetadata) returns map<json>|error {
    log:printDebug("sanitizeMetadata: Sanitizing metadata map");
    json cleaned = check sanitizeJson(rawMetadata);
    map<json> parsedMap = check cleaned.cloneWithType();
    return parsedMap;
}

# Adds a vector entry to the vector store for a document chunk.
#
# + embedding - Embedding vector for the chunk.
# + documentLink - Link to the document.
# + chunk - The MarkdownChunk object.
# + collectionName - Name of the vector collection.
# + return - VectorDataWithId object or error.
public function addVectorEntry(float[] embedding, string documentLink, MarkdownChunk chunk, string collectionName) returns VectorDataWithId|error {
    log:printInfo(`addVectorEntry: Adding vector for chunk ${chunk.chunkIndex} of file ${chunk.metadata.fileId}`);
    map<json> chunkMetadata = {
        heading: chunk.heading.toString(),
        headingLevel: chunk.headingLevel,
        fileId: chunk.metadata.fileId,
        fileName: chunk.metadata.fileName,
        webViewLink: documentLink,
        createdTime: chunk.metadata.createdTime,
        chunkIndex: chunk.chunkIndex
    };
    return vectorStore.addVector({embedding: embedding, document: chunk.content, metadata: check sanitizeMetadata(chunkMetadata)}, collectionName);
}

# Saves the initial Google Drive start page token to the database.
#
# + return - ID of the saved token or error.
public function saveInitialToken() returns int|error {
    log:printInfo("saveInitialToken: Retrieving start page token");
    string token = check driveClient->getStartPageToken();
    db:TokenInsert tokenInsert = {token: token, createdAt: time:utcNow(), updatedAt: time:utcNow()};
    int[] result = check dbClient->/tokens.post([tokenInsert, tokenInsert]);
    if result.length() > 0 {
        log:printInfo(`saveInitialToken: Token saved with ID ${result[0]}`);
        return result[0];
    } else {
        log:printError("saveInitialToken: Failed to save token");
        return error("Failed to save token");
    }
}

# Retrieves the latest Google Drive token from the database.
#
# + return - Token object or error.
public function getToken() returns db:Token|error {
    log:printInfo("getToken: Retrieving latest token record");
    db:Token|error token = dbClient->/tokens/[LATEST_TOKEN_ID].get();
    if token is error {
        log:printError(`getToken: Failed to retrieve token with ID ${LATEST_TOKEN_ID}`);
        return error("Failed to retrieve token");
    }
    return token;
}

# Updates the Google Drive start page token in the database.
#
# + return - The updated token string or error.
public function updateToken() returns string|error {
    log:printInfo("updateToken: Updating drive start page token");
    string token = check driveClient->getStartPageToken();
    db:Token existingToken = check dbClient->/tokens/[LATEST_TOKEN_ID].get();
    db:TokenUpdate previousToken = {token: existingToken.token, updatedAt: time:utcNow()};
    log:printInfo(`updateToken: Archiving previous token (ID ${LATEST_TOKEN_ID - 1})`);
    db:Token _ = check dbClient->/tokens/[LATEST_TOKEN_ID - 1].put(previousToken);
    db:TokenUpdate latestToken = {token: token, updatedAt: time:utcNow()};
    log:printInfo(`updateToken: Saving new token (ID ${LATEST_TOKEN_ID})`);
    db:Token updatedLatestToken = check dbClient->/tokens/[LATEST_TOKEN_ID].put(latestToken);
    return updatedLatestToken.token;
}

// ──────────────────────────────────────────────────────────────────────────────
//  Idempotent processing‑state helpers
// ──────────────────────────────────────────────────────────────────────────────

# Retrieves processing status for a single file. Returns () if the file has
# never been seen before.
#
# + fileId - parameter description
# + return - return value description
public function getFileStatus(string fileId) returns db:FileProcessingStatus|()|error {

    db:FileProcessingStatus|error st = dbClient->/fileprocessingstatuses/[fileId]();
    if st is error {
        // A 404 means "not found" – treat as unseen file, not as failure
        if st.message().startsWith("404") {
            return ();
        }
        return st; // real DB error
    }
    return st;
}

# Inserts or updates a status row in a single DB call (PostgreSQL `UPSERT`).
#
# + st - The file processing status to upsert.
# + return - error if the upsert fails.
public function upsertFileStatus(db:FileProcessingStatus st) returns error? {
    log:printInfo(`upsertFileStatus: Upserting file processing status for file ${st.fileId}`);
    db:FileProcessingStatusUpdate upd = {
        status: st.status,
        errorMessage: st.errorMessage,
        updatedAt: st.updatedAt,
        createdAt: st.createdAt // will be ignored by UPDATE branch
    };

    // 1️⃣  Attempt to UPDATE (PUT) first
    db:FileProcessingStatus|persist:Error putErr = dbClient->/fileprocessingstatuses/[st.fileId].put(upd);

    if putErr is persist:NotFoundError {
        // 404 means row not found – switch to INSERT
        db:FileProcessingStatusInsert ins = {
                fileId: st.fileId,
                status: st.status,
                errorMessage: st.errorMessage,
                createdAt: st.createdAt,
                updatedAt: st.updatedAt
            };

        // 2️⃣  INSERT (POST) will create the row
        _ = check dbClient->/fileprocessingstatuses.post([ins]);
        return;
    }

    return (); // success via UPDATE branch
}

// Convenience wrappers --------------------------------------------------------
# Description.
#
# + fileId - parameter description
# + return - return value description
public function markProcessingStart(string fileId) returns ()|error {
    log:printInfo(`markProcessingStart: Marking file ${fileId} as processing`);
    db:FileProcessingStatus st = {
        fileId: fileId,
        status: STATUS_PROCESSING,
        errorMessage: "",
        createdAt: time:utcNow(),
        updatedAt: time:utcNow()
    };
    return upsertFileStatus(st);
}

public function markProcessingSuccess(string fileId) returns ()|error {
    db:FileProcessingStatus st = {
        fileId: fileId,
        status: STATUS_SUCCESS,
        errorMessage: "",
        updatedAt: time:utcNow(),
        createdAt: time:utcNow()};
    return upsertFileStatus(st);
}

# Description.
#
# + fileId - parameter description  
# + msg - parameter description
# + return - return value description
public function markProcessingError(string fileId, string msg) returns ()|error {
    db:FileProcessingStatus st = {
        fileId: fileId,
        status: STATUS_ERROR,
        errorMessage: msg,
        updatedAt: time:utcNow(),
        createdAt: time:utcNow()
    };
    return upsertFileStatus(st);
}
