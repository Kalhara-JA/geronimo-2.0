-- AUTO-GENERATED FILE.

-- This file is an auto-generated file by Ballerina persistence layer for model.
-- Please verify the generated scripts and execute them against the target DB server.

DROP TABLE IF EXISTS "tokens";

CREATE TABLE "tokens" (
	"id"  SERIAL,
	"token" VARCHAR(191) NOT NULL,
	"created_at" TIMESTAMP,
	"updated_at" TIMESTAMP,
	PRIMARY KEY("id")
);


CREATE INDEX "ix_vector_store_collection" ON "vector_store" ("collection_name");
