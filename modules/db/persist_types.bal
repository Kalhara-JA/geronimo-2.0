// AUTO-GENERATED FILE. DO NOT MODIFY.

// This file is an auto-generated file by Ballerina persistence layer for model.
// It should not be modified by hand.

import ballerina/time;

public type VectorStore record {|
    readonly int id;
    string collectionName;
    string document;
    time:Utc? createdAt;
    time:Utc? updatedAt;
|};

public type VectorStoreOptionalized record {|
    int id?;
    string collectionName?;
    string document?;
    time:Utc? createdAt?;
    time:Utc? updatedAt?;
|};

public type VectorStoreTargetType typedesc<VectorStoreOptionalized>;

public type VectorStoreInsert record {|
    string collectionName;
    string document;
    time:Utc? createdAt;
    time:Utc? updatedAt;
|};

public type VectorStoreUpdate record {|
    string collectionName?;
    string document?;
    time:Utc? createdAt?;
    time:Utc? updatedAt?;
|};

public type Token record {|
    readonly int id;
    string token;
    time:Utc? createdAt;
    time:Utc updatedAt;
|};

public type TokenOptionalized record {|
    int id?;
    string token?;
    time:Utc? createdAt?;
    time:Utc? updatedAt?;
|};

public type TokenTargetType typedesc<TokenOptionalized>;

public type TokenInsert record {|
    string token;
    time:Utc? createdAt;
    time:Utc updatedAt;
|};

public type TokenUpdate record {|
    string token?;
    time:Utc? createdAt?;
    time:Utc updatedAt?;
|};

