import ballerina/persist as _;
import ballerina/time;
import ballerinax/persist.sql;

# Description.
#
# + id - field description
# + collectionName - field description
# + document - field description
# + createdAt - field description
# + updatedAt - field description
@sql:Name {value: "vector_store"}
public type VectorStore record {|
    @sql:Generated
    readonly int id;
    @sql:Name {value: "collection_name"}
    @sql:Index {name: "ix_vector_store_collection"}
    string collectionName;
    string document;
    //Unsupported[JSONB] metadata;
    @sql:Name {value: "created_at"}
    time:Utc? createdAt;
    @sql:Name {value: "updated_at"}
    time:Utc? updatedAt;
    //Unsupported[VECTOR(1536)] embedding;
|};

# Description.
#
# + id - field description
# + token - field description
# + createdAt - field description
# + updatedAt - field description
@sql:Name {value: "tokens"}
public type Token record {|
    @sql:Generated
    readonly int id;
    string token;
    @sql:Name {value: "created_at"}
    time:Utc? createdAt;
    @sql:Name {value: "updated_at"}
    time:Utc updatedAt;
|};

@sql:Name {value: "file_status"}
public type FileProcessingStatus record {|

    @sql:Name {value: "file_id"}
    readonly string fileId;

    string status; // processing | success | error

    @sql:Name {value: "error_message"}
    string? errorMessage;

    @sql:Name {value: "created_at"}
    time:Utc? createdAt;

    @sql:Name {value: "updated_at"}
    time:Utc updatedAt;
|};

