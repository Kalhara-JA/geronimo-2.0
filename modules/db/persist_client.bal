// AUTO-GENERATED FILE. DO NOT MODIFY.

// This file is an auto-generated file by Ballerina persistence layer for model.
// It should not be modified by hand.

import ballerina/jballerina.java;
import ballerina/persist;
import ballerina/sql;
import ballerinax/persist.sql as psql;
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;

const TOKEN = "tokens";
const FILE_PROCESSING_STATUS = "fileprocessingstatuses";

public isolated client class Client {
    *persist:AbstractPersistClient;

    private final postgresql:Client dbClient;

    private final map<psql:SQLClient> persistClients;

    private final record {|psql:SQLMetadata...;|} metadata = {
        [TOKEN]: {
            entityName: "Token",
            tableName: "tokens",
            fieldMetadata: {
                id: {columnName: "id", dbGenerated: true},
                token: {columnName: "token"},
                createdAt: {columnName: "created_at"},
                updatedAt: {columnName: "updated_at"}
            },
            keyFields: ["id"]
        },
        [FILE_PROCESSING_STATUS]: {
            entityName: "FileProcessingStatus",
            tableName: "file_status",
            fieldMetadata: {
                fileId: {columnName: "file_id"},
                status: {columnName: "status"},
                errorMessage: {columnName: "error_message"},
                createdAt: {columnName: "created_at"},
                updatedAt: {columnName: "updated_at"}
            },
            keyFields: ["fileId"]
        }
    };

    public isolated function init() returns persist:Error? {
        postgresql:Client|error dbClient = new (host = host, username = user, password = password, database = database, port = port, options = connectionOptions);
        if dbClient is error {
            return <persist:Error>error(dbClient.message());
        }
        self.dbClient = dbClient;
        if defaultSchema != () {
            lock {
                foreach string key in self.metadata.keys() {
                    psql:SQLMetadata metadata = self.metadata.get(key);
                    if metadata.schemaName == () {
                        metadata.schemaName = defaultSchema;
                    }
                    map<psql:JoinMetadata>? joinMetadataMap = metadata.joinMetadata;
                    if joinMetadataMap == () {
                        continue;
                    }
                    foreach [string, psql:JoinMetadata] [_, joinMetadata] in joinMetadataMap.entries() {
                        if joinMetadata.refSchema == () {
                            joinMetadata.refSchema = defaultSchema;
                        }
                    }
                }
            }
        }
        self.persistClients = {
            [TOKEN]: check new (dbClient, self.metadata.get(TOKEN).cloneReadOnly(), psql:POSTGRESQL_SPECIFICS),
            [FILE_PROCESSING_STATUS]: check new (dbClient, self.metadata.get(FILE_PROCESSING_STATUS).cloneReadOnly(), psql:POSTGRESQL_SPECIFICS)
        };
    }

    isolated resource function get tokens(TokenTargetType targetType = <>, sql:ParameterizedQuery whereClause = ``, sql:ParameterizedQuery orderByClause = ``, sql:ParameterizedQuery limitClause = ``, sql:ParameterizedQuery groupByClause = ``) returns stream<targetType, persist:Error?> = @java:Method {
        'class: "io.ballerina.stdlib.persist.sql.datastore.PostgreSQLProcessor",
        name: "query"
    } external;

    isolated resource function get tokens/[int id](TokenTargetType targetType = <>) returns targetType|persist:Error = @java:Method {
        'class: "io.ballerina.stdlib.persist.sql.datastore.PostgreSQLProcessor",
        name: "queryOne"
    } external;

    isolated resource function post tokens(TokenInsert[] data) returns int[]|persist:Error {
        psql:SQLClient sqlClient;
        lock {
            sqlClient = self.persistClients.get(TOKEN);
        }
        sql:ExecutionResult[] result = check sqlClient.runBatchInsertQuery(data);
        return from sql:ExecutionResult inserted in result
            where inserted.lastInsertId != ()
            select <int>inserted.lastInsertId;
    }

    isolated resource function put tokens/[int id](TokenUpdate value) returns Token|persist:Error {
        psql:SQLClient sqlClient;
        lock {
            sqlClient = self.persistClients.get(TOKEN);
        }
        _ = check sqlClient.runUpdateQuery(id, value);
        return self->/tokens/[id].get();
    }

    isolated resource function delete tokens/[int id]() returns Token|persist:Error {
        Token result = check self->/tokens/[id].get();
        psql:SQLClient sqlClient;
        lock {
            sqlClient = self.persistClients.get(TOKEN);
        }
        _ = check sqlClient.runDeleteQuery(id);
        return result;
    }

    isolated resource function get fileprocessingstatuses(FileProcessingStatusTargetType targetType = <>, sql:ParameterizedQuery whereClause = ``, sql:ParameterizedQuery orderByClause = ``, sql:ParameterizedQuery limitClause = ``, sql:ParameterizedQuery groupByClause = ``) returns stream<targetType, persist:Error?> = @java:Method {
        'class: "io.ballerina.stdlib.persist.sql.datastore.PostgreSQLProcessor",
        name: "query"
    } external;

    isolated resource function get fileprocessingstatuses/[string fileId](FileProcessingStatusTargetType targetType = <>) returns targetType|persist:Error = @java:Method {
        'class: "io.ballerina.stdlib.persist.sql.datastore.PostgreSQLProcessor",
        name: "queryOne"
    } external;

    isolated resource function post fileprocessingstatuses(FileProcessingStatusInsert[] data) returns string[]|persist:Error {
        psql:SQLClient sqlClient;
        lock {
            sqlClient = self.persistClients.get(FILE_PROCESSING_STATUS);
        }
        _ = check sqlClient.runBatchInsertQuery(data);
        return from FileProcessingStatusInsert inserted in data
            select inserted.fileId;
    }

    isolated resource function put fileprocessingstatuses/[string fileId](FileProcessingStatusUpdate value) returns FileProcessingStatus|persist:Error {
        psql:SQLClient sqlClient;
        lock {
            sqlClient = self.persistClients.get(FILE_PROCESSING_STATUS);
        }
        _ = check sqlClient.runUpdateQuery(fileId, value);
        return self->/fileprocessingstatuses/[fileId].get();
    }

    isolated resource function delete fileprocessingstatuses/[string fileId]() returns FileProcessingStatus|persist:Error {
        FileProcessingStatus result = check self->/fileprocessingstatuses/[fileId].get();
        psql:SQLClient sqlClient;
        lock {
            sqlClient = self.persistClients.get(FILE_PROCESSING_STATUS);
        }
        _ = check sqlClient.runDeleteQuery(fileId);
        return result;
    }

    remote isolated function queryNativeSQL(sql:ParameterizedQuery sqlQuery, typedesc<record {}> rowType = <>) returns stream<rowType, persist:Error?> = @java:Method {
        'class: "io.ballerina.stdlib.persist.sql.datastore.PostgreSQLProcessor"
    } external;

    remote isolated function executeNativeSQL(sql:ParameterizedQuery sqlQuery) returns psql:ExecutionResult|persist:Error = @java:Method {
        'class: "io.ballerina.stdlib.persist.sql.datastore.PostgreSQLProcessor"
    } external;

    public isolated function close() returns persist:Error? {
        error? result = self.dbClient.close();
        if result is error {
            return <persist:Error>error(result.message());
        }
        return result;
    }
}

