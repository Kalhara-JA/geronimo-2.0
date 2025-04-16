// Copyright (c) 2024, WSO2 LLC. (http://www.wso2.org) All Rights Reserved.

import ballerinax/azure.openai.embeddings;
import ballerinax/googleapis.drive as drive;

// Initialize Google Drive client with OAuth2 credentials
final drive:Client driveClient = check new ({
    auth: {
        refreshUrl: refreshUrl,
        refreshToken: refreshToken,
        clientId: clientId,
        clientSecret: clientSecret
    }
});
final embeddings:Client embeddingsClient = check new ({
    auth: {
        apiKey: azureOpenAiEmbeddingsApiKey
    }
});
