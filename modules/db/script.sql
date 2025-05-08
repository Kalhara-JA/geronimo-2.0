-- AUTO-GENERATED FILE.

-- This file is an auto-generated file by Ballerina persistence layer for model.
-- Please verify the generated scripts and execute them against the target DB server.

DROP TABLE IF EXISTS "file_status";
DROP TABLE IF EXISTS "tokens";

CREATE TABLE "tokens" (
	"id"  SERIAL,
	"token" VARCHAR(191) NOT NULL,
	"created_at" TIMESTAMP,
	"updated_at" TIMESTAMP NOT NULL,
	PRIMARY KEY("id")
);

CREATE TABLE "file_status" (
	"file_id" VARCHAR(191) NOT NULL,
	"status" VARCHAR(191) NOT NULL,
	"error_message" VARCHAR(191),
	"created_at" TIMESTAMP,
	"updated_at" TIMESTAMP NOT NULL,
	PRIMARY KEY("file_id")
);


CREATE INDEX "ix_vector_store_collection" ON "vector_store" ("collection_name");
