// Copyright (c) 2024, WSO2 LLC. (http://www.wso2.org) All Rights Reserved.

import ballerina/http;
import ballerinax/googleapis.drive as drive;
// import ballerinax/postgresql;

import wso2/pgvector;

// Initialize Google Drive client with OAuth2 credentials
final drive:Client driveClient = check new ({
    auth: {
        refreshUrl: refreshUrl,
        refreshToken: refreshToken,
        clientId: clientId,
        clientSecret: clientSecret
    }
});
final http:Client embeddings = check new (azureOpenaiUrl);

final pgvector:VectorStore vectorStore = check new ({
        host: driveDbHostname,
        user: driveDbUsername,
        password: driveDbPassword,
        database: driveDbDatabaseName,
        port: driveDbPort
    },
    vectorDimension = embeddingSize, connectionPool = {maxOpenConnections: maxOpenConnections}
    // options = {
    //     ssl: {
    //         mode: postgresql:DISABLE
    //     }
    // }
);
